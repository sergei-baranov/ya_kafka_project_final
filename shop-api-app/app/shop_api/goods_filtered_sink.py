import asyncio
import json
import logging
import os
import time
from typing import Any
from datetime import datetime, timezone

import psycopg
from psycopg import errors as pg_errors
from psycopg.types.json import Json
from psycopg_pool import AsyncConnectionPool

UPSERT_SQL = """
INSERT INTO goods_filtered (product_id, product_data)
VALUES (%(product_id)s, %(product_data)s::jsonb)
ON CONFLICT (product_id) DO UPDATE SET
    product_data = EXCLUDED.product_data,
    updated_at = NOW()
WHERE
    -- Не падаем на невалидных датах:
    -- 1) если updated_at в EXCLUDED невалидный/пустой → не обновляем
    -- (считаем самым старым)
    -- 2) если текущий updated_at невалидный/пустой → обновляем
    -- валидным EXCLUDED
    -- 3) если оба валидны → обновляем только если EXCLUDED >= текущего
    (
      CASE
        WHEN (EXCLUDED.product_data ->> 'updated_at') ~
             '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
        THEN (EXCLUDED.product_data ->> 'updated_at')::timestamptz
        ELSE NULL
      END
    ) IS NOT NULL
    AND (
      (
        CASE
          WHEN (goods_filtered.product_data ->> 'updated_at') ~
               '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
          THEN (goods_filtered.product_data ->> 'updated_at')::timestamptz
          ELSE NULL
        END
      ) IS NULL
      OR
      (
        CASE
          WHEN (EXCLUDED.product_data ->> 'updated_at') ~
               '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
          THEN (EXCLUDED.product_data ->> 'updated_at')::timestamptz
          ELSE NULL
        END
      )
      >=
      (
        CASE
          WHEN (goods_filtered.product_data ->> 'updated_at') ~
               '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
          THEN (goods_filtered.product_data ->> 'updated_at')::timestamptz
          ELSE NULL
        END
      )
    )
"""


def _conninfo_from_env() -> str | None:
    host = (os.getenv("SHOP_API_POSTGRES_HOST") or "").strip() or (
        os.getenv("SERVICE_POSTGRES_NAME") or ""
    ).strip()
    if not host:
        return None
    port = (os.getenv("SHOP_API_POSTGRES_PORT") or "").strip() or (
        os.getenv("SERVICE_POSTGRES_PORT") or "5432"
    ).strip()
    user = (os.getenv("SHOP_API_POSTGRES_USER") or "").strip() or (
        os.getenv("SERVICE_POSTGRES_USER") or ""
    ).strip()
    password = (os.getenv("SHOP_API_POSTGRES_PASSWORD") or "").strip() or (
        os.getenv("SERVICE_POSTGRES_PASSWORD") or ""
    ).strip()
    dbname = (os.getenv("SHOP_API_POSTGRES_DB") or "").strip() or (
        os.getenv("SERVICE_POSTGRES_DB") or ""
    ).strip()
    if not user or not dbname:
        return None
    return (
        f"host={host} port={port} dbname={dbname} user={user} "
        f"password={password}"
    )


def _is_transient(exc: BaseException) -> bool:
    if isinstance(exc, (TimeoutError, ConnectionError, OSError)):
        return True
    if isinstance(exc, (psycopg.OperationalError, psycopg.InterfaceError)):
        return True
    if isinstance(exc, pg_errors.TooManyConnections):
        return True
    if isinstance(exc, pg_errors.QueryCanceled):
        return True
    return False


def _parse_updated_at(updated_at: Any) -> datetime | None:
    """
    Парсим updated_at вида 2023-11-11T15:30:00Z / 2023-10-01T09:09:09+00:00.
    Политика: если не парсится → None (считаем самым старым).
    """
    if not isinstance(updated_at, str) or not updated_at:
        return None
    try:
        s = updated_at.strip()
        # fromisoformat не понимает 'Z'
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None


class GoodsFilteredBatchSink:
    """
    Микро-батч UPSERT в goods_filtered: дедуп по product_id в рамках батча,
    флуш по числу записей и/или интервалу с последнего флуша.
    """

    def __init__(self, logger: logging.Logger) -> None:
        self._log = logger
        self._conninfo = _conninfo_from_env()
        self._pool: AsyncConnectionPool | None = None
        self._lock = asyncio.Lock()
        self._pending: dict[str, dict[str, Any]] = {}
        self._last_flush = time.monotonic()
        self._batch_max = max(
            1, int(os.getenv("GOODS_FILTERED_BATCH_MAX", "25")))
        self._flush_interval_s = max(
            0.05,
            float(
                os.getenv("GOODS_FILTERED_FLUSH_INTERVAL_MS", "150")) / 1000.0
        )
        self._max_retries = max(
            0, int(os.getenv("GOODS_FILTERED_DB_MAX_RETRIES", "3")))
        self._backoff_base = float(
            os.getenv("GOODS_FILTERED_DB_BACKOFF_SEC", "0.5"))
        self._flush_task: asyncio.Task | None = None

    async def start(self) -> None:
        if not self._conninfo:
            self._log.info(
                "Postgres goods_filtered sink: выключен (нет host/conninfo)")
            return
        try:
            self._pool = AsyncConnectionPool(
                conninfo=self._conninfo,
                min_size=1,
                max_size=int(os.getenv("SHOP_API_POSTGRES_POOL_MAX", "5")),
                open=False,
                timeout=float(
                    os.getenv("SHOP_API_POSTGRES_POOL_TIMEOUT", "30")),
            )
            await self._pool.open()
        except Exception as e:
            self._log.critical(
                "Postgres pool не открылся, "
                "запись в goods_filtered отключена: %s", e
            )
            self._pool = None
            return
        self._last_flush = time.monotonic()
        self._log.info(
            "Postgres goods_filtered sink: batch_max=%s flush_interval_ms=%s",
            self._batch_max,
            int(self._flush_interval_s * 1000),
        )
        self._flush_task = asyncio.create_task(self._flush_loop())

    async def stop(self) -> None:
        if self._pool:
            if self._flush_task:
                self._flush_task.cancel()
                try:
                    await self._flush_task
                except asyncio.CancelledError:
                    pass
                finally:
                    self._flush_task = None
            await self.flush_all()
            await self._pool.close()
            self._pool = None
            self._log.info("Postgres goods_filtered sink остановлен")

    async def _flush_loop(self) -> None:
        """
        Фоновый таймерный флуш. Нужен, чтобы батч писался в Postgres
        даже при отсутствии новых сообщений в Kafka.
        """
        try:
            while True:
                await asyncio.sleep(self._flush_interval_s)
                if not self._pool:
                    return
                await self.flush_all()
        except asyncio.CancelledError:
            # stop() вызывает финальный flush_all()
            raise

    async def enqueue_filtered_product(self, data: dict[str, Any]) -> None:
        if not self._pool:
            return
        pid = data.get("product_id")
        if not isinstance(pid, str) or not pid:
            self._log.warning(
                "Postgres sink: пропуск, нет product_id в записи")
            return
        snapshot: dict[str, Any] = json.loads(json.dumps(data))
        snapshot_ts = _parse_updated_at(snapshot.get("updated_at"))
        to_write: dict[str, dict[str, Any]] | None = None
        async with self._lock:
            existing = self._pending.get(pid)
            if existing is None:
                self._pending[pid] = snapshot
            else:
                existing_ts = _parse_updated_at(existing.get("updated_at"))
                # Если новая дата валиднее/позже — заменяем.
                # Если даты равны
                # (включая None==None) — побеждает последнее пришедшее.
                if existing_ts is None and snapshot_ts is None:
                    self._pending[pid] = snapshot
                elif existing_ts is None and snapshot_ts is not None:
                    self._pending[pid] = snapshot
                elif existing_ts is not None and snapshot_ts is None:
                    pass
                else:
                    # обе не None
                    if snapshot_ts >= existing_ts:  # равенство → последнее
                        self._pending[pid] = snapshot

            now = time.monotonic()
            if len(self._pending) >= self._batch_max:
                self._log.debug(
                    "goods_filtered: флуш по размеру (%s/%s)",
                    len(self._pending),
                    self._batch_max,
                )
                to_write = self._pending
                self._pending = {}
                self._last_flush = now
            elif (
                self._pending
                and (now - self._last_flush) >= self._flush_interval_s
            ):
                self._log.debug(
                    "goods_filtered: флуш по таймеру (%s шт, interval_ms=%s)",
                    len(self._pending),
                    int(self._flush_interval_s * 1000),
                )
                to_write = self._pending
                self._pending = {}
                self._last_flush = now
        if to_write:
            await self._write_batch_with_retries(to_write)

    async def flush_all(self) -> None:
        if not self._pool:
            return
        async with self._lock:
            if not self._pending:
                return
            to_write = self._pending
            self._pending = {}
            self._last_flush = time.monotonic()
        await self._write_batch_with_retries(to_write)

    async def _write_batch_with_retries(
        self, batch: dict[str, dict[str, Any]]
    ) -> None:
        if not batch or not self._pool:
            return
        rows = [
            {"product_id": pid, "product_data": Json(rec)}
            for pid, rec in batch.items()
        ]
        delay = self._backoff_base
        for attempt in range(self._max_retries + 1):
            try:
                t0 = time.monotonic()
                async with self._pool.connection() as conn:
                    async with conn.transaction():
                        async with conn.cursor() as cur:
                            await cur.executemany(UPSERT_SQL, rows)
                dt_ms = int((time.monotonic() - t0) * 1000)
                self._log.info(
                    "goods_filtered: flush ok (%s строк, %s ms)",
                    len(rows),
                    dt_ms,
                )
                return
            except Exception as e:
                transient = _is_transient(e)
                last_attempt = attempt >= self._max_retries
                if not transient or last_attempt:
                    self._log.warning(
                        "goods_filtered: батч сброшен (%s строк), ошибка: %s "
                        "(transient=%s, attempts=%s)",
                        len(rows),
                        e,
                        transient,
                        attempt + 1,
                    )
                    return
                self._log.debug(
                    "goods_filtered: повтор записи батча %s/%s: %s",
                    attempt + 1,
                    self._max_retries,
                    e,
                )
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30.0)
