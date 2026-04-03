#!/usr/bin/env bash
# Разовая инициализация ksqlDB при docker compose up (stream + CTAS для client-recommendations).
# Идемпотентно: при уже существующей таблице CTAS не выполняется.
set -euo pipefail

KSQL_HTTP="http://${SERVICE_KSQLDB_SERVER_NAME:?}:${SERVICE_KSQLDB_SERVER_PORT:?}"
TOPIC="${TOPIC_CLIENT_RECOMMENDATIONS:?}"

post_ksql() {
  local sql="$1"
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"ksql": sys.argv[1], "streamsProperties": {}}))' "$sql")"
  local resp
  resp="$(curl -sS -X POST "${KSQL_HTTP}/ksql" \
    -H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
    -H "Accept: application/vnd.ksql.v1+json" \
    -d "$body")"
  if echo "$resp" | grep -qi 'statement_error'; then
    echo "ksqlDB statement_error:"
    echo "$resp"
    exit 1
  fi
  if ! echo "$resp" | grep -qE '"status":"SUCCESS"|"status":"EXECUTING"'; then
    echo "ksqlDB ответ (ожидали SUCCESS/EXECUTING):"
    echo "$resp"
    exit 1
  fi
  echo "OK: $(echo "$sql" | tr '\n' ' ' | cut -c1-120)..."
}

echo "Ожидание REST ksqlDB: ${KSQL_HTTP} ..."
until curl -sSf "${KSQL_HTTP}/info" >/dev/null 2>&1; do
  echo "ksqlDB ещё не отвечает, ждём 2 с..."
  sleep 2
done

echo "Проверка: таблица CLIENT_RECOMMENDATIONS_LATEST уже есть?"
tables_json="$(curl -sS -X POST "${KSQL_HTTP}/ksql" \
  -H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
  -d "$(python3 -c 'import json; print(json.dumps({"ksql": "SHOW TABLES;", "streamsProperties": {}}))')")"

NEED_CTAS=0
if echo "$tables_json" | grep -q 'CLIENT_RECOMMENDATIONS_LATEST'; then
  echo "Таблица уже существует — CTAS пропускаем."
else
  NEED_CTAS=1
fi

echo "CREATE STREAM IF NOT EXISTS (ключ Avro record → STRUCT) ..."
post_ksql "CREATE STREAM IF NOT EXISTS client_recommendations_s (
  K STRUCT<client INT> KEY,
  generated_at STRING,
  top_words ARRAY<STRUCT<word STRING, count BIGINT>>
) WITH (
  KAFKA_TOPIC='${TOPIC}',
  KEY_FORMAT='AVRO',
  VALUE_FORMAT='AVRO'
);"

if [[ "$NEED_CTAS" -eq 1 ]]; then
  echo "CREATE TABLE ... AS SELECT (persistent query) ..."
  post_ksql "CREATE TABLE client_recommendations_latest AS SELECT K->client AS client, LATEST_BY_OFFSET(generated_at) AS generated_at, LATEST_BY_OFFSET(top_words) AS top_words FROM client_recommendations_s GROUP BY K->client EMIT CHANGES;"
fi

echo "ksqlDB bootstrap завершён."
