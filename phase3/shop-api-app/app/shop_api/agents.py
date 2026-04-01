import warnings

warnings.simplefilter("ignore", UserWarning)

import io, json, struct

from fastavro import validate, parse_schema, schemaless_writer
import requests
from faust import StreamT
from typing import AsyncIterable

from .app import app, SSL_CONFIG, SCHEMA_REGISTRY_URL
from .models import BlockWordMessage
from .goods_filtered_sink import GoodsFilteredBatchSink
from .tables import block_words_table
from .topics import (
    blocked_words_topic, dlq_topic,
    filtered_schema_val_name, filtered_topic_name,
    prohibited_schema_val_name, prohibited_topic_name,
    raw_topic
)


# Faust требует, чтобы у сериализатора были методы dumps/loads
class AvroSerializer:
    def __init__(self, schema_str, schema_id):
        self.schema = parse_schema(
            json.loads(schema_str)
            if isinstance(schema_str, str)
            else schema_str
        )
        self.schema_id = schema_id

    def dumps(self, value):
        if value is None:
            return None
        out = io.BytesIO()
        # Confluent Wire Format: Magic Byte (0) + 4 bytes Schema ID
        out.write(struct.pack('>bI', 0, self.schema_id))
        schemaless_writer(out, self.schema, value)
        return out.getvalue()

    def loads(self, value):
        # Нам не надо десериализовывать Avro в этом случае, 
        # но Faust может вызвать этот метод.
        return value


def _schema_registry_get_latest(subject: str) -> tuple[dict, int]:
    url_schema = f"{SCHEMA_REGISTRY_URL}/subjects/{subject}/versions/latest"
    r = requests.get(
        url_schema,
        cert=(SSL_CONFIG['cert'], SSL_CONFIG['key']),
        verify=SSL_CONFIG['ca'],
        timeout=5,
    )
    r.raise_for_status()
    res_json = r.json()
    schema_dict = json.loads(res_json["schema"])
    schema_id = res_json["id"]
    return schema_dict, schema_id


def _has_stop_words_in_name(name: str) -> tuple[bool, list[str]]:
    """
    Проверяем, что name содержит (подстрокой, case-insensitive) любое стоп-слово.
    Возвращаем (есть_ли, список_совпавших_слов_как_в_таблице).
    """
    if not isinstance(name, str) or not name:
        return False, []
    name_l = name.lower()
    matched: list[str] = []
    for w in block_words_table.keys():
        if not w:
            continue
        try:
            w_l = w.lower()
        except Exception:
            continue
        if w_l and w_l in name_l:
            matched.append(w)
    return (len(matched) > 0), matched


@app.agent(raw_topic)
async def validator_agent(stream):
    # 1. Получаем схемы и их ID из Schema Registry
    try:
        filtered_schema_dict, filtered_schema_id = _schema_registry_get_latest(
            filtered_schema_val_name
        )
        prohibited_schema_dict, prohibited_schema_id = _schema_registry_get_latest(
            prohibited_schema_val_name
        )

        filtered_parsed_schema = parse_schema(filtered_schema_dict)
        prohibited_parsed_schema = parse_schema(prohibited_schema_dict)
        
        # Создаём сериализатор для валидных данных
        filtered_avro_encode = AvroSerializer(
            filtered_schema_dict, filtered_schema_id
        )
        prohibited_avro_encode = AvroSerializer(
            prohibited_schema_dict, prohibited_schema_id
        )
        
        # Топик для валидных даных с кастомным сериализатором
        filtered_topic = app.topic(
            filtered_topic_name,
            value_serializer=filtered_avro_encode
        )
        prohibited_topic = app.topic(
            prohibited_topic_name,
            value_serializer=prohibited_avro_encode
        )
        
        app.logger.info(
            f"Схема '{filtered_schema_val_name}' (ID: {filtered_schema_id}) загружена"
        )
        app.logger.info(
            f"Схема '{prohibited_schema_val_name}' (ID: {prohibited_schema_id}) загружена"
        )
    except Exception as e:
        app.logger.critical(f"Невозможно загрузить схему: {e}")
        return

    pg_sink = GoodsFilteredBatchSink(app.logger)
    await pg_sink.start()
    try:
        async for msg_bytes in stream:
            try:
                # Пробуем прочитать JSON из raw топика
                data = json.loads(msg_bytes)

                # 2. Валидация по Avro-схеме filtered (fastavro)
                if not validate(data, filtered_parsed_schema, raise_errors=False):
                    app.logger.warning(f"SCHEMA MISMATCH (filtered): {data}")
                    await dlq_topic.send(
                        value={"reason": "schema_mismatch_filtered", "payload": data}
                    )
                    continue

                # 3. Проверка имени на стоп-слова (case-insensitive substring)
                has_stop_words, matched_words = _has_stop_words_in_name(
                    data.get("name")
                )

                if has_stop_words:
                    # Топик goods-prohibited тоже связан со схемой: валидируем отдельно
                    if not validate(data, prohibited_parsed_schema, raise_errors=False):
                        app.logger.warning(f"SCHEMA MISMATCH (prohibited): {data}")
                        await dlq_topic.send(
                            value={
                                "reason": "schema_mismatch_prohibited",
                                "payload": data,
                                "matched_words": matched_words,
                            }
                        )
                        continue

                    await prohibited_topic.send(value=data)
                    app.logger.info(
                        f"SENT TO PROHIBITED: {data.get('product_id', 'unknown')} "
                        f"(matched_words={matched_words})"
                    )
                else:
                    await filtered_topic.send(value=data)
                    await pg_sink.enqueue_filtered_product(data)
                    app.logger.info(
                        f"SENT TO FILTERED: {data.get('product_id', 'unknown')}"
                    )

            except json.JSONDecodeError:
                # Если в goods-raw пришёл даже не JSON
                app.logger.error(f"INVALID JSON: {msg_bytes}")
                await dlq_topic.send(value={
                    'reason': 'invalid_json',
                    'raw_hex': msg_bytes.hex()
                })
            except Exception as e:
                app.logger.error(f"AGENT ERROR: {e}")
    finally:
        await pg_sink.stop()

@app.agent(
    blocked_words_topic
)
async def persist_block_words(
        messages: StreamT[BlockWordMessage]) -> AsyncIterable[str]:
    """
    поток сообщений-команд о блокировке/разблокировке слов
    агрегирует в таблицу, где ключ - слово,
    значение - bool
    """
    msg: BlockWordMessage
    # TODO: schema с определением и key_type, и value_type, в качестве key
    # использовать word, value_type=bool, тогда поток не надо
    # репартиционировать через group_by
    async for msg in messages.group_by(BlockWordMessage.word):
        if msg.block:
            block_words_table[msg.word] = True
        else:
            block_words_table.pop(msg.word, False)
        # тут yield нужен для ответа на ask() извне например
        yield msg.word + ': ' + str(block_words_table.get(msg.word, False))
