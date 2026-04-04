#!/usr/bin/env bash
set -euo pipefail

TRUST="${CONTAINER_PATH_TRUSTSTORE:?}"
KEYS="${CONTAINER_PATH_KEYSTORE:?}"

keytool -exportcert -rfc \
  -keystore "$TRUST" \
  -storepass "${KAFKA_TRUSTSTORE_CREDS:?}" \
  -alias "${KAFKA_TRUSTSTORE_ROOT_CA_ALIAS:-ca}" \
  -noprompt > /tmp/kafka-exporter-ca.pem

openssl pkcs12 -in "$KEYS" -clcerts -nokeys \
  -passin "pass:${KAFKA_KEYSTORE_CREDS:?}" \
  -out /tmp/kafka-exporter-client.crt
openssl pkcs12 -in "$KEYS" -nocerts -nodes \
  -passin "pass:${KAFKA_KEYSTORE_CREDS}" \
  -out /tmp/kafka-exporter-client.key

# Брокер может поднять сокет позже «стартed» контейнера; без ожидания — FATAL и рестарт-луп.
_BOOT="${KAFKA_EXPORTER_BOOTSTRAP%%,*}"
_BOOT="${_BOOT// /}"
WAIT_HOST="${_BOOT%%:*}"
WAIT_PORT="${_BOOT##*:}"
echo "kafka-exporter: ждём TCP ${WAIT_HOST}:${WAIT_PORT} (до ~3 мин)..."
for _i in $(seq 1 90); do
  if timeout 1 bash -c "echo >/dev/tcp/${WAIT_HOST}/${WAIT_PORT}" 2>/dev/null; then
    echo "kafka-exporter: порт доступен."
    break
  fi
  if [[ "$_i" -ge 90 ]]; then
    echo "kafka-exporter: таймаут ожидания ${WAIT_HOST}:${WAIT_PORT}" >&2
    exit 1
  fi
  sleep 2
done

ARGS=(kafka_exporter
  --web.listen-address=:9308
  --log.level=info
  --tls.enabled
  --tls.ca-file=/tmp/kafka-exporter-ca.pem
  --tls.cert-file=/tmp/kafka-exporter-client.crt
  --tls.key-file=/tmp/kafka-exporter-client.key
  --tls.insecure-skip-tls-verify
  --sasl.enabled
  --sasl.mechanism=plain
  --sasl.username="${SASL_UNAME_KAFKA_UI:?}"
  --sasl.password="${SASL_PWD_KAFKA_UI:?}"
)

IFS=',' read -r -a SERVERS <<< "${KAFKA_EXPORTER_BOOTSTRAP:?}"
for s in "${SERVERS[@]}"; do
  s="${s// /}"
  [[ -z "$s" ]] && continue
  ARGS+=(--kafka.server="$s")
done

exec "${ARGS[@]}"
