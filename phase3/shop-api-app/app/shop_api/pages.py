import asyncio
import os

from psycopg_pool import AsyncConnectionPool

from .agents import AvroSerializer, _schema_registry_get_latest
from .app import app
from .goods_filtered_sink import _conninfo_from_env
from .tables import block_words_table


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
        return web.json(result)
    except Exception as e:
        return web.json({'error': str(e)}, status=500)
