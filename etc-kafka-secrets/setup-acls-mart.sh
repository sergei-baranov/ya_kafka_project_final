CONFIG="/etc/kafka/secrets/admin-client.properties"
COMMON_ARGS="--bootstrap-server ${MB_1_NAME}:${MB_1_PORT_92} --command-config ${CONFIG}"

# Топики только compact (без delete)
TOPICS_CLEANUP_POLICY_COMPACT=()

# compact + delete + короткий retention (снимок рекомендаций по ключу client)
TOPICS_COMPACT_DELETE_RETENTION=(
  "${TOPIC_CLIENT_RECOMMENDATIONS}:3"
)

# "название:кол-во партиций" — cleanup.policy=delete
TOPICS_CLEANUP_POLICY_DELETE=(
  "${TOPIC_GOODS_FILTERED}:3"
  "${TOPIC_CLIENT_API_SEARCH}:3"
)

USER_KAFKA_UI="User:${SASL_UNAME_KAFKA_UI}"
USER_CONSUMER="User:${SASL_UNAME_CONSUMER}"
USER_PRODUCER="User:${SASL_UNAME_PRODUCER}"

USERS=(
  $USER_KAFKA_UI
)

echo "--- 1. Очистка старых ACL ---"
for USER in "${USERS[@]}"; do
  kafka-acls $COMMON_ARGS --remove --force --allow-principal "$USER" --topic "*"
  kafka-acls $COMMON_ARGS --remove --force --allow-principal "$USER" --group "*"
  # Удаляем права на кластер, если они были (только для kafka_ui)
  if [ "$USER" == "$USER_KAFKA_UI" ]; then
    kafka-acls $COMMON_ARGS --remove --force --allow-principal "$USER" --cluster "$CLUSTER_ID_MART"
  fi
done

echo "--- 2. Создание топиков ---"
for ENTRY in "${TOPICS_CLEANUP_POLICY_COMPACT[@]}"; do
  TOPIC="${ENTRY%%:*}"
  PARTITIONS="${ENTRY##*:}"
  echo "Создаём топик $TOPIC cleanup.policy=compact с $PARTITIONS партициями..."
  kafka-topics $COMMON_ARGS \
    --create --if-not-exists --topic "$TOPIC" \
    --partitions "$PARTITIONS" \
    --replication-factor 3 \
    --config cleanup.policy=compact
done

for ENTRY in "${TOPICS_COMPACT_DELETE_RETENTION[@]}"; do
  TOPIC="${ENTRY%%:*}"
  PARTITIONS="${ENTRY##*:}"
  echo "Создаём топик $TOPIC cleanup.policy=compact,delete с $PARTITIONS партициями..."
  kafka-topics $COMMON_ARGS \
    --create --if-not-exists --topic "$TOPIC" \
    --partitions "$PARTITIONS" \
    --replication-factor 3 \
    --config cleanup.policy=compact,delete \
    --config retention.ms=604800000 \
    --config delete.retention.ms=60000
done

for ENTRY in "${TOPICS_CLEANUP_POLICY_DELETE[@]}"; do
  TOPIC="${ENTRY%%:*}"
  PARTITIONS="${ENTRY##*:}"
  echo "Создаём топик $TOPIC cleanup.policy=delete с $PARTITIONS партициями..."
  kafka-topics $COMMON_ARGS \
    --create --if-not-exists --topic "$TOPIC" \
    --partitions "$PARTITIONS" \
    --replication-factor 3 \
    --config cleanup.policy=delete
done

echo "--- 3. Ожидание готовности топиков ---"
ALL_TOPICS=("${TOPICS_CLEANUP_POLICY_COMPACT[@]}" "${TOPICS_COMPACT_DELETE_RETENTION[@]}" "${TOPICS_CLEANUP_POLICY_DELETE[@]}")
for ENTRY in "${ALL_TOPICS[@]}"; do
  TOPIC="${ENTRY%%:*}"
  echo -n "Ожидание топика $TOPIC..."
  ITER=0; MAX_RETRIES=10
  while [ $ITER -lt $MAX_RETRIES ]; do
    STATUS=$(kafka-topics $COMMON_ARGS --describe --topic "$TOPIC" 2>/dev/null)
    if [[ ! -z "$STATUS" && ! "$STATUS" =~ "UnderReplicated" ]]; then echo " Готов!"; break; fi
    echo -n "."; sleep 2; ((ITER++))
  done
done

echo "--- 4. Настройка прав для kafka_ui ---"
kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_UI --operation Describe --operation Read --operation Write --topic "*"
kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_UI --operation Describe --operation Read --group "*"
kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_UI --operation Describe --operation Create --cluster "$CLUSTER_ID_MART"

echo "--- 5. Права consumer / producer для Spark (mart) ---"
# Spark: client-api-search + свой выход (client-recommendations); метаданные кластера
kafka-acls $COMMON_ARGS --add --allow-principal "$USER_CONSUMER" \
  --operation Read --operation Describe \
  --topic "${TOPIC_CLIENT_API_SEARCH}" \
  --topic "${TOPIC_CLIENT_RECOMMENDATIONS}"

kafka-acls $COMMON_ARGS --add --allow-principal "$USER_CONSUMER" \
  --operation Read --operation Describe \
  --group "${KAFKA_SPARK_CONSUMER_GROUP:-spark-recommendations}"

kafka-acls $COMMON_ARGS --add --allow-principal "$USER_CONSUMER" \
  --operation Describe --cluster "$CLUSTER_ID_MART"

kafka-acls $COMMON_ARGS --add --allow-principal "$USER_PRODUCER" \
  --operation Write --operation Describe \
  --topic "${TOPIC_CLIENT_RECOMMENDATIONS}"

echo "--- Настройка завершена! ---"
kafka-acls $COMMON_ARGS --list
