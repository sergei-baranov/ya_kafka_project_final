"""
Structured Streaming: mart Kafka (client-api-search) -> топ-5 слов на клиента
-> топик client-recommendations (Confluent Avro, key=client).
"""
from __future__ import annotations

import io
import json
import logging
import os
import struct
import sys
from collections import Counter
from datetime import datetime, timezone
from typing import Any

import fastavro
import requests
from kafka import KafkaProducer
from pyspark.sql import SparkSession

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("recommendations_job")

CONFLUENT_MAGIC = 0


def _bootstrap_mart() -> str:
    return ",".join(
        [
            f"{os.environ['MB_1_NAME']}:{os.environ['MB_1_PORT_92']}",
            f"{os.environ['MB_2_NAME']}:{os.environ['MB_2_PORT_92']}",
            f"{os.environ['MB_3_NAME']}:{os.environ['MB_3_PORT_92']}",
        ]
    )


def _jaas(username: str, password: str) -> str:
    return (
        "org.apache.kafka.common.security.plain.PlainLoginModule required "
        f'username="{username}" password="{password}";'
    )


def _sr_session() -> requests.Session:
    s = requests.Session()
    s.verify = os.environ["SR_CA_PEM"]
    s.cert = (os.environ["SR_CLIENT_CERT"], os.environ["SR_CLIENT_KEY"])
    return s


def _sr_get_json(sess: requests.Session, path: str) -> dict[str, Any]:
    base = os.environ["SCHEMA_REGISTRY_REST_URL_INNER"].rstrip("/")
    r = sess.get(f"{base}{path}", timeout=30)
    r.raise_for_status()
    return r.json()


def _latest_schema_id(sess: requests.Session, subject: str) -> int:
    data = _sr_get_json(sess, f"/subjects/{subject}/versions/latest")
    return int(data["id"])


def _schema_for_id(sess: requests.Session, schema_id: int) -> dict[str, Any]:
    data = _sr_get_json(sess, f"/schemas/ids/{schema_id}")
    return json.loads(data["schema"])


def _decode_confluent_avro(sess: requests.Session, buf: bytes, cache: dict[int, dict]) -> dict[str, Any]:
    if not buf:
        return {}
    if buf[0] != CONFLUENT_MAGIC:
        raise ValueError("not Confluent wire format")
    schema_id = struct.unpack(">I", buf[1:5])[0]
    if schema_id not in cache:
        cache[schema_id] = _schema_for_id(sess, schema_id)
    schema = cache[schema_id]
    bio = io.BytesIO(buf[5:])
    return fastavro.schemaless_reader(bio, schema)


def _encode_confluent_avro(schema: dict[str, Any], schema_id: int, record: dict[str, Any]) -> bytes:
    bio = io.BytesIO()
    fastavro.schemaless_writer(bio, schema, record)
    payload = bio.getvalue()
    return bytes([CONFLUENT_MAGIC]) + struct.pack(">I", schema_id) + payload


def _load_avsc(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _load_state(path: str) -> dict[str, Counter]:
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    return {k: Counter(v) for k, v in raw.items()}


def _save_state(path: str, state: dict[str, Counter]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    out = {c: dict(cnt) for c, cnt in state.items()}
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f)
    os.replace(tmp, path)


def main() -> None:
    topic_search = os.environ["TOPIC_CLIENT_API_SEARCH"]
    topic_out = os.environ["TOPIC_CLIENT_RECOMMENDATIONS"]
    group = os.environ.get("KAFKA_SPARK_CONSUMER_GROUP", "spark-recommendations")
    checkpoint = os.environ.get("SPARK_CHECKPOINT_DIR", "/checkpoint/recommendations")
    state_path = os.path.join(checkpoint, "word_state.json")

    secrets = os.environ["CONTAINER_PATH_SECRETS"]
    def _env_file(name: str) -> str:
        return os.environ[name].strip().strip('"').strip("'")

    key_avsc_path = os.path.join(secrets, _env_file("CLIENT_RECOMMENDATIONS_KEY_AVRO_SCHEMA_FILE_NAME"))
    val_avsc_path = os.path.join(secrets, _env_file("CLIENT_RECOMMENDATIONS_VALUE_AVRO_SCHEMA_FILE_NAME"))
    key_schema_encode = _load_avsc(key_avsc_path)
    val_schema_encode = _load_avsc(val_avsc_path)

    sess = _sr_session()
    key_schema_id = _latest_schema_id(sess, f"{topic_out}-key")
    val_schema_id = _latest_schema_id(sess, f"{topic_out}-value")
    decode_cache: dict[int, dict] = {}

    bootstrap = _bootstrap_mart()
    jaas_c = _jaas(os.environ["SASL_UNAME_CONSUMER"], os.environ["SASL_PWD_CONSUMER"])

    trust = os.environ["CONTAINER_PATH_TRUSTSTORE"]
    kstore = os.environ["CONTAINER_PATH_KEYSTORE"]
    tspw = os.environ["KAFKA_TRUSTSTORE_CREDS"]
    kspw = os.environ["KAFKA_KEYSTORE_CREDS"]
    keypw = os.environ["KAFKA_SSLKEY_CREDS"]

    producer = KafkaProducer(
        bootstrap_servers=bootstrap.split(","),
        security_protocol="SASL_SSL",
        sasl_mechanism="PLAIN",
        sasl_plain_username=os.environ["SASL_UNAME_PRODUCER"],
        sasl_plain_password=os.environ["SASL_PWD_PRODUCER"],
        ssl_cafile=os.environ["SR_CA_PEM"],
        ssl_certfile=os.environ["SR_CLIENT_CERT"],
        ssl_keyfile=os.environ["SR_CLIENT_KEY"],
        acks="all",
        retries=5,
    )

    spark = SparkSession.builder.appName("client-recommendations").getOrCreate()

    state_holder: dict[str, Counter] = _load_state(state_path)

    kafka_opts = {
        "kafka.bootstrap.servers": bootstrap,
        "subscribe": topic_search,
        "startingOffsets": os.environ.get("SPARK_KAFKA_STARTING_OFFSETS", "earliest"),
        "maxOffsetsPerTrigger": os.environ.get("SPARK_KAFKA_MAX_OFFSETS", "2000"),
        "failOnDataLoss": "false",
        # Офсеты только в Spark checkpoint; auto.commit в Kafka source не поддерживается.
        # Фиксированный group — под ACL (mart); один запрос на group id.
        "kafka.group.id": group,
        "kafka.security.protocol": "SASL_SSL",
        "kafka.sasl.mechanism": "PLAIN",
        "kafka.sasl.jaas.config": jaas_c,
        "kafka.ssl.truststore.location": trust,
        "kafka.ssl.truststore.password": tspw,
        "kafka.ssl.keystore.type": os.environ.get("KEYSTORE_TYPE", "PKCS12"),
        "kafka.ssl.keystore.location": kstore,
        "kafka.ssl.keystore.password": kspw,
        "kafka.ssl.key.password": keypw,
    }

    raw = spark.readStream.format("kafka").options(**kafka_opts).load()

    def foreach_batch(df, _epoch_id: int) -> None:
        nonlocal state_holder
        if df.limit(1).count() == 0:
            return
        rows = df.select("value").collect()
        touched: set[str] = set()
        search_seen = 0
        for row in rows:
            search_seen += 1
            try:
                rec = _decode_confluent_avro(sess, bytes(row.value), decode_cache)
            except Exception as e:
                log.warning("skip search message decode: %s", e)
                continue
            client = int(rec["client"])
            word = str(rec["word"])
            ck = str(client)
            if ck not in state_holder:
                state_holder[ck] = Counter()
            state_holder[ck][word] += 1
            touched.add(ck)
        if not touched:
            return
        now = datetime.now(timezone.utc).isoformat()
        for ck in touched:
            top = state_holder[ck].most_common(5)
            client = int(ck)
            val_rec = {
                "client": client,
                "generated_at": now,
                "top_words": [{"word": w, "count": int(c)} for w, c in top],
            }
            key_rec = {"client": client}
            kbytes = _encode_confluent_avro(key_schema_encode, key_schema_id, key_rec)
            vbytes = _encode_confluent_avro(val_schema_encode, val_schema_id, val_rec)
            producer.send(topic_out, key=kbytes, value=vbytes)
        producer.flush()
        _save_state(state_path, state_holder)
        log.info(
            "flush ok: search_in_batch=%s clients_updated=%s",
            search_seen,
            len(touched),
        )

    q = (
        raw.writeStream.foreachBatch(foreach_batch)
        .option("checkpointLocation", checkpoint)
        .trigger(processingTime=os.environ.get("SPARK_TRIGGER_INTERVAL", "10 seconds"))
        .start()
    )
    q.awaitTermination()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
