import asyncio
import json
import os

import requests
from prometheus_client import Counter, generate_latest

# aiohttp (Faust web) не принимает charset внутри content_type для Response
_PROM_METRICS_CT = "text/plain; version=0.0.4"
from psycopg_pool import AsyncConnectionPool

from .agents import AvroSerializer, _schema_registry_get_latest
from .app import app
from .goods_filtered_sink import _conninfo_from_env
from .tables import block_words_table


SHOP_API_SEARCH_GOOD_BY_NAME_TOTAL = Counter(
    "shop_api_search_good_by_name_total",
    "Вызовы HTTP /search-good-by-name/* (успешные ответы 200)",
)


_pg_pool: AsyncConnectionPool | None = None
_pg_pool_lock = asyncio.Lock()

_client_api_search_topic = None
_client_api_search_topic_lock = asyncio.Lock()


async def _get_pg_pool() -> AsyncConnectionPool | None:
    global _pg_pool
    if _pg_pool is not None:
        return _pg_pool
    async with _pg_pool_lock:
        if _pg_pool is not None:
            return _pg_pool
        conninfo = _conninfo_from_env()
        if not conninfo:
            return None
        pool = AsyncConnectionPool(conninfo=conninfo, min_size=1, max_size=5, open=False)
        await pool.open()
        _pg_pool = pool
        return _pg_pool


def _escape_like(term: str, escape: str = "\\") -> str:
    # Экранируем спецсимволы LIKE: %, _, и сам escape
    return (
        term.replace(escape, escape + escape)
        .replace("%", escape + "%")
        .replace("_", escape + "_")
    )


async def _ensure_client_api_search_topic():
    global _client_api_search_topic
    topic_name = (os.getenv("TOPIC_CLIENT_API_SEARCH") or "").strip()
    if not topic_name:
        return None
    if _client_api_search_topic is not None:
        return _client_api_search_topic
    async with _client_api_search_topic_lock:
        if _client_api_search_topic is not None:
            return _client_api_search_topic
        subject = f"{topic_name}-value"
        schema_dict, schema_id = await asyncio.to_thread(
            _schema_registry_get_latest, subject
        )
        enc = AvroSerializer(schema_dict, schema_id)
        _client_api_search_topic = app.topic(topic_name, value_serializer=enc)
        return _client_api_search_topic


async def _publish_client_api_search(client: int, word: str) -> None:
    try:
        topic = await _ensure_client_api_search_topic()
        if topic is None:
            return
        await topic.send(value={"client": int(client), "word": word})
    except Exception as e:
        app.logger.warning("client-api-search: не удалось отправить в Kafka: %s", e)


def _ksqldb_rest_base() -> str:
    """HTTP REST ksqlDB (сеть Docker), не SASL к брокеру — только pull query."""
    url = (os.getenv("KSQLDB_REST_URL") or "").strip().rstrip("/")
    if url:
        return url
    host = os.getenv("SERVICE_KSQLDB_SERVER_NAME", "ksqldb-server")
    port = os.getenv("SERVICE_KSQLDB_SERVER_PORT", "8088")
    return f"http://{host}:{port}"


def _iter_ksql_query_json_objects(body: str):
    """Тело ответа POST /query: несколько JSON-подряд (часто pretty-printed, не «одна строка = один JSON»)."""
    decoder = json.JSONDecoder()
    idx = 0
    n = len(body)
    while idx < n:
        while idx < n and body[idx].isspace():
            idx += 1
        if idx >= n:
            break
        obj, end = decoder.raw_decode(body, idx)
        yield obj
        idx = end
    while idx < n and body[idx].isspace():
        idx += 1
    if idx < n:
        raise json.JSONDecodeError("trailing data after ksql JSON stream", body, idx)


def _iter_ksql_query_frames(body: str):
    """Один или несколько JSON-сегментов; сегмент может быть dict или list[dict] (формат pull в части версий)."""
    for top in _iter_ksql_query_json_objects(body):
        if isinstance(top, dict):
            yield top
        elif isinstance(top, list):
            for item in top:
                if isinstance(item, dict):
                    yield item


def _ksqldb_pull_recommendations_sync(client_id: int) -> dict | None:
    """Синхронный POST /query; pull-ответ — последовательность JSON (header, row, finalMessage)."""
    sql = (
        "SELECT client, generated_at, top_words "
        f"FROM CLIENT_RECOMMENDATIONS_LATEST WHERE client = {int(client_id)} LIMIT 1;"
    )
    url = f"{_ksqldb_rest_base()}/query"
    resp = requests.post(
        url,
        json={"ksql": sql, "streamsProperties": {}},
        headers={
            "Accept": "application/vnd.ksql.v1+json",
            "Content-Type": "application/vnd.ksql.v1+json",
        },
        timeout=60,
    )
    resp.raise_for_status()
    body = resp.text
    if not body.strip():
        raise json.JSONDecodeError("empty body", body, 0)

    keys = ("client", "generated_at", "top_words")
    row_out: dict | None = None
    for chunk in _iter_ksql_query_frames(body):
        err_msg = chunk.get("errorMessage")
        if not err_msg and chunk.get("@type") == "generic_error":
            err_msg = chunk.get("message")
        if err_msg:
            raise RuntimeError(err_msg)
        row_obj = chunk.get("row")
        if row_obj and not row_obj.get("tombstone"):
            cols = row_obj.get("columns")
            if cols is not None:
                row_out = dict(zip(keys, cols, strict=True))
        if chunk.get("finalMessage"):
            break
    return row_out


@app.page('/metrics')
async def prometheus_metrics(web, request):
    # Faust ожидает web.bytes; content_type без charset — см. aiohttp Response
    return web.bytes(generate_latest(), content_type=_PROM_METRICS_CT)


@app.page('/get-recommendations/{client}')
async def get_recommendations(web, request, client: int):
    try:
        client_id = int(client)
    except (TypeError, ValueError):
        return web.json({"error": "client must be an integer"}, status=400)
    if client_id < 0:
        return web.json({"error": "client must be non-negative"}, status=400)
    try:
        row = await asyncio.to_thread(_ksqldb_pull_recommendations_sync, client_id)
    except requests.RequestException as e:
        app.logger.exception("ksqlDB pull query HTTP error: %s", e)
        return web.json({"error": "ksqlDB request failed", "detail": str(e)}, status=502)
    except RuntimeError as e:
        app.logger.warning("ksqlDB pull query: %s", e)
        return web.json({"error": str(e)}, status=502)
    except json.JSONDecodeError as e:
        return web.json({"error": "invalid ksqlDB response", "detail": str(e)}, status=502)
    if row is None:
        return web.json({"error": "no recommendations for this client"}, status=404)
    return web.json(row)


@app.page('/get-block-words/')
async def get_block_words(web, request):
    try:
        words_list = []
        for word in block_words_table.keys():
            words_list.append({word: block_words_table[word]})
        return web.json(words_list)
    except Exception as e:
        return web.json({
            'error': str(e)
        }, status=500)


@app.page('/get-block-word/{word}')
async def get_block_word(web, request, word: str):
    try:
        block = block_words_table[word]
        if block is None:
            return web.json({
                'word': word,
                'block': None,
            })
        return web.json({
            'word': word,
            'block': block,
        })
    except Exception as e:
        return web.json({
            'error': str(e),
            'word': word
        }, status=500)


@app.page('/search-good-by-name/{client}/{word}')
async def search_good_by_name(web, request, client: int, word: str):
    try:
        # Сегмент URL может прийти строкой; Avro int и psycopg ждут int
        try:
            client_id = int(client)
        except (TypeError, ValueError):
            return web.json({'error': 'client must be an integer'}, status=400)

        word = (word or "").strip()
        if len(word) < 2:
            return web.json({'error': 'word must be at least 2 characters'}, status=400)
        if len(word) > 64:
            return web.json({'error': 'word must be at most 64 characters'}, status=400)

        pool = await _get_pg_pool()
        if pool is None:
            return web.json({'error': 'postgres is not configured'}, status=500)

        word_esc = _escape_like(word)
        pattern = f"%{word_esc}%"
        prefix = f"{word_esc}%"

        async with pool.connection() as conn:
            async with conn.transaction():
                # статистика запросов (upsert)
                await conn.execute(
                    """
                    INSERT INTO client_api_search (client, word, request_counter)
                    VALUES (%s, %s, 1)
                    ON CONFLICT (client, word)
                    DO UPDATE SET request_counter = client_api_search.request_counter + 1
                    """,
                    (client_id, word),
                )

                # поиск товаров
                async with conn.cursor() as cur:
                    await cur.execute(
                        """
                        SELECT
                          product_id as product_id,
                          product_data ->> 'name' as product_name
                        FROM
                          goods_filtered
                        WHERE
                          product_data ->> 'name' ILIKE %s ESCAPE '\\'
                        ORDER BY
                          (product_data ->> 'name' ILIKE %s ESCAPE '\\') DESC,
                          product_data ->> 'name' ASC
                        """,
                        (pattern, prefix),
                    )
                    rows = await cur.fetchall()

        result = [{'product_id': pid, 'product_name': name} for (pid, name) in rows]
        await _publish_client_api_search(client_id, word)
        SHOP_API_SEARCH_GOOD_BY_NAME_TOTAL.inc()
        return web.json(result)
    except Exception as e:
        return web.json({'error': str(e)}, status=500)
