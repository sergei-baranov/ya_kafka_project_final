#!/bin/bash
set -euo pipefail

keytool -exportcert -rfc \
  -keystore "${CONTAINER_PATH_TRUSTSTORE}" \
  -storepass "${KAFKA_TRUSTSTORE_CREDS}" \
  -alias "${KAFKA_TRUSTSTORE_ROOT_CA_ALIAS}" \
  -file /tmp/sr-ca.pem

openssl pkcs12 -in "${CONTAINER_PATH_KEYSTORE}" \
  -passin "pass:${KAFKA_KEYSTORE_CREDS}" \
  -clcerts -nokeys -out /tmp/kafka-client.crt

openssl pkcs12 -in "${CONTAINER_PATH_KEYSTORE}" \
  -passin "pass:${KAFKA_KEYSTORE_CREDS}" \
  -nocerts -nodes -out /tmp/kafka-client.key

chmod 600 /tmp/kafka-client.key

# Том checkpoint с Docker создаётся от root; job читает PEM при работе от UID 1001
SPARK_UID=1001
SPARK_GID=1001
chown "${SPARK_UID}:${SPARK_GID}" /tmp/sr-ca.pem /tmp/kafka-client.crt /tmp/kafka-client.key

export SR_CA_PEM=/tmp/sr-ca.pem
export SR_CLIENT_CERT=/tmp/kafka-client.crt
export SR_CLIENT_KEY=/tmp/kafka-client.key

# Ivy (скачивание JAR для --packages) требует абсолютный HOME; у USER 1001 HOME бывает пустым → "?/.ivy2/local"
export HOME=/tmp/spark-user
CHECKPOINT="${SPARK_CHECKPOINT_DIR:-/checkpoint/recommendations}"
mkdir -p "${HOME}/.ivy2" "${HOME}/.cache" "$CHECKPOINT"
chown -R "${SPARK_UID}:${SPARK_GID}" "${HOME}" "$CHECKPOINT"

# Hadoop UGI: у UID 1001 в образе часто нет строки в /etc/passwd → UnixPrincipal(name=null)
export HADOOP_USER_NAME="${HADOOP_USER_NAME:-spark}"
export USER="${USER:-spark}"
export LOGNAME="${LOGNAME:-$USER}"

# -DHADOOP_USER_NAME: Hadoop читает и из env, и из system properties до полной инициализации UGI
export SPARK_SUBMIT_OPTS="${SPARK_SUBMIT_OPTS:-} -Duser.home=${HOME} -Dhadoop.security.authentication=simple -DHADOOP_USER_NAME=${HADOOP_USER_NAME}"
export JAVA_TOOL_OPTIONS="-DHADOOP_USER_NAME=${HADOOP_USER_NAME}${JAVA_TOOL_OPTIONS:+ ${JAVA_TOOL_OPTIONS}}"

SPARK_PKG_VERSION="${SPARK_KAFKA_CONNECTOR_VERSION:-3.5.3}"

# Client mode: драйвер в этом контейнере — worker'ы должны достучаться до хоста по Docker DNS
DRIVER_HOST="${SERVICE_SPARK_JOB_NAME:?SERVICE_SPARK_JOB_NAME not set}"

exec gosu "${SPARK_UID}:${SPARK_GID}" /opt/bitnami/spark/bin/spark-submit \
  --master "spark://${SERVICE_SPARK_MASTER_NAME}:7077" \
  --packages "org.apache.spark:spark-sql-kafka-0-10_2.12:${SPARK_PKG_VERSION}" \
  --conf "spark.driver.host=${DRIVER_HOST}" \
  --conf spark.driver.bindAddress=0.0.0.0 \
  --conf spark.sql.shuffle.partitions=4 \
  --executor-memory 512m \
  /opt/bitnami/spark/work/recommendations_job.py
