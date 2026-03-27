CONFIG="/etc/kafka/secrets/admin-client.properties"
COMMON_ARGS="--bootstrap-server ${MB_1_NAME}:${MB_1_PORT_92} --command-config ${CONFIG}"

# "название:кол-во партиций"
TOPICS_CLEANUP_POLICY_COMPACT=()
# "название:кол-во партиций"
TOPICS_CLEANUP_POLICY_DELETE=(
  "${TOPIC_GOODS_FILTERED}:3"
)
USER_KAFKA_UI="User:${SASL_UNAME_KAFKA_UI}"
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

for ENTRY in "${TOPICS_CLEANUP_POLICY_DELETE[@]}"; do
  TOPIC="${ENTRY%%:*}"
  PARTITIONS="${ENTRY##*:}"
  echo "Создаём топик $TOPIC cleanup.policy=delete с $PARTITIONS партициями..."
  kafka-topics $COMMON_ARGS --create --topic "$TOPIC" --partitions 3 --replication-factor 3 --if-not-exists
  kafka-topics $COMMON_ARGS \
    --create --if-not-exists --topic "$TOPIC" \
    --partitions "$PARTITIONS" \
    --replication-factor 3 \
    --config cleanup.policy=delete
done

echo "--- 3. Ожидание готовности топиков ---"
for ENTRY in "${TOPICS_CLEANUP_POLICY_COMPACT[@]}"; do
  TOPIC="${ENTRY%%:*}"
  echo -n "Ожидание топика $TOPIC..."
  ITER=0; MAX_RETRIES=10
  while [ $ITER -lt $MAX_RETRIES ]; do
    STATUS=$(kafka-topics $COMMON_ARGS --describe --topic "$TOPIC" 2>/dev/null)
    if [[ ! -z "$STATUS" && ! "$STATUS" =~ "UnderReplicated" ]]; then echo " Готов!"; break; fi
    echo -n "."; sleep 2; ((ITER++))
  done
done

for ENTRY in "${TOPICS_CLEANUP_POLICY_DELETE[@]}"; do
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
# Права на все топики и группы
kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_UI --operation Describe --operation Read --operation Write --topic "*"
kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_UI --operation Describe --operation Read --group "*"
# Права на описание состояния всего кластера
kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_UI --operation Describe --operation Create --cluster "$CLUSTER_ID_MART"

# ...

echo "--- Настройка завершена! ---"
kafka-acls $COMMON_ARGS --list
