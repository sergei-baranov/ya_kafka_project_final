CONFIG="/etc/kafka/secrets/admin-client.properties"
COMMON_ARGS="--bootstrap-server ${SB_1_NAME}:${SB_1_PORT_92} --command-config ${CONFIG}"

# "название:кол-во партиций"
# не менять (в д. сл.; служебные топики кафка коннект и т.п.) !!!
TOPICS_CLEANUP_POLICY_COMPACT=(
  "${TOPIC_CONNECT_CONFIG_STORAGE}:1"
  "${TOPIC_CONNECT_OFFSET_STORAGE}:25"
  "${TOPIC_CONNECT_STATUS_STORAGE}:5"
  "${SERVICE_SCHEMA_REGISTRY_KAFKASTORE_TOPIC}:1"
)
# "название:кол-во партиций"
TOPICS_CLEANUP_POLICY_DELETE=(
  "${TOPIC_GOODS_RAW}:3"
  "${TOPIC_GOODS_FILTERED}:3"
  "${TOPIC_GOODS_DLQ}:1"
  "${TOPIC_GOODS_PROHOBITED}:1"
  "${TOPIC_GOODS_PROHOBITION_LIST}:1"
)

USER_KAFKA_CONNECT="User:${SASL_UNAME_KAFKA_CONNECT}"
USER_SCHEMA_REGISTRY="User:${SASL_UNAME_SCHEMA_REGISTRY}"
USER_KAFKA_UI="User:${SASL_UNAME_KAFKA_UI}"
USERS=(
  $USER_KAFKA_UI
  $USER_KAFKA_CONNECT
  $USER_SCHEMA_REGISTRY
  "User:producer"
  "User:consumer"
)


echo "--- 1. Очистка старых ACL ---"

for USER in "${USERS[@]}"; do
  kafka-acls $COMMON_ARGS --remove --force --allow-principal "$USER" --topic "*"
  kafka-acls $COMMON_ARGS --remove --force --allow-principal "$USER" --group "*"
  # Удаляем права на кластер, если они были (только для kafka_ui)
  if [[ "$USER" == "$USER_KAFKA_UI" || "$USER" == "xxx$USER_SCHEMA_REGISTRY" ]]; then
    kafka-acls $COMMON_ARGS --remove --force --allow-principal "$USER" --cluster "$CLUSTER_ID_STAGE"
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
  kafka-topics $COMMON_ARGS \
    --create --if-not-exists --topic "$TOPIC" \
    --partitions "$PARTITIONS" \
    --replication-factor 3 \
    --config cleanup.policy=delete
done

#echo "Создаём топик __transaction_state на ${TRANSACTION_STATE_PARTITIONS} партиций..."
#kafka-topics $COMMON_ARGS \
#  --create  --if-not-exists --topic "__transaction_state" \
#  --partitions ${TRANSACTION_STATE_PARTITIONS} \
#  --replication-factor 3 \
#  --config min.insync.replicas=2 \
#  --config cleanup.policy=compact \
#  --config segment.bytes=104857600


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

TOPIC="__transaction_state"
echo -n "Ожидание топика $TOPIC..."
ITER=0; MAX_RETRIES=10
while [ $ITER -lt $MAX_RETRIES ]; do
  STATUS=$(kafka-topics $COMMON_ARGS --describe --topic "$TOPIC" 2>/dev/null)
  if [[ ! -z "$STATUS" && ! "$STATUS" =~ "UnderReplicated" ]]; then echo " Готов!"; break; fi
  echo -n "."; sleep 2; ((ITER++))
done


echo "--- 4. Настройка прав для ${USER_KAFKA_UI} ---"

kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_UI \
  --operation Describe --operation Read --operation Write \
  --topic "*"

kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_UI \
  --operation Describe --operation Read \
  --group "*"

kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_UI \
  --operation Describe --operation Create \
  --cluster "$CLUSTER_ID_STAGE"


echo "--- 5. Настройка прав для ${USER_KAFKA_CONNECT} ---"

for TOPIC in "connect-configs" "connect-offsets" "connect-status"; do
  kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_CONNECT --operation DescribeConfigs --operation Read --operation Write --operation Describe --topic "$TOPIC"
done

kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_CONNECT \
  --operation Write --operation Describe \
  --topic "goods-raw"

kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_CONNECT \
  --operation Describe --operation Read \
  --group kafka-connect

kafka-acls $COMMON_ARGS --add --allow-principal $USER_KAFKA_CONNECT \
  --operation Write --operation Describe \
  --transactional-id kafka-connect


echo "--- 6. Настройка прав для ${USER_SCHEMA_REGISTRY} ---"

# schema_registry_user _schemas schema_registry_group schema-registry-tx

kafka-acls $COMMON_ARGS --add --allow-principal $USER_SCHEMA_REGISTRY \
  --operation DescribeConfigs --operation Read --operation Write --operation Create --operation Describe \
  --topic _schemas

kafka-acls $COMMON_ARGS --add --allow-principal $USER_SCHEMA_REGISTRY \
  --operation Read \
  --group schema_registry_group

kafka-acls $COMMON_ARGS --add --allow-principal $USER_SCHEMA_REGISTRY \
  --operation Read \
  --group schema-registry

#kafka-acls $COMMON_ARGS --add --allow-principal $USER_SCHEMA_REGISTRY \
#  --operation Write --operation Describe \
#  --transactional-id schema-registry-tx

#kafka-acls $COMMON_ARGS --add --allow-principal $USER_SCHEMA_REGISTRY \
#  --operation Write --operation Describe \
#  --transactional-id "schema-registry-" \
#  --resource-pattern-type prefixed

kafka-acls $COMMON_ARGS --add --allow-principal $USER_SCHEMA_REGISTRY \
  --operation Describe \
  --cluster "$CLUSTER_ID_STAGE"


echo "--- Настройка завершена! ---"
kafka-acls $COMMON_ARGS --list
