CONFIG="/etc/kafka/secrets/admin-client.properties"
COMMON_ARGS="--bootstrap-server ${SB_1_NAME}:${SB_1_PORT_92} --command-config ${CONFIG}"

# Соответствует .env.example / shop_api.app (если в окружении не задано)
: "${TOPIC_FAUST_REPLY:=f-reply-shop-api-app-rpc}"

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
  "${TOPIC_GOODS_PROHIBITED}:1"
  "${TOPIC_GOODS_PROHIBITION_LIST}:1"
  "${TOPIC_FAUST_REPLY}:1"
)

USER_KAFKA_CONNECT="User:${SASL_UNAME_KAFKA_CONNECT}"
USER_SCHEMA_REGISTRY="User:${SASL_UNAME_SCHEMA_REGISTRY}"
USER_KAFKA_UI="User:${SASL_UNAME_KAFKA_UI}"
USER_SHOP_API="User:${SASL_UNAME_SHOP_API}"
USERS=(
  $USER_KAFKA_UI
  $USER_KAFKA_CONNECT
  $USER_SCHEMA_REGISTRY
  $USER_SHOP_API
  "User:producer"
  "User:consumer"
)

SHOP_API_APP_NAME="shop_api_app"
SHOP_API_TOPICS=(
  $TOPIC_GOODS_RAW
  $TOPIC_GOODS_FILTERED
  $TOPIC_GOODS_DLQ
  $TOPIC_GOODS_PROHIBITED
  $TOPIC_GOODS_PROHIBITION_LIST
  $TOPIC_FAUST_REPLY
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


echo "--- 7. Настройка прав для ${USER_SHOP_API} ---"

for TOPIC in "${SHOP_API_TOPICS[@]}"; do
  kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
    --operation DescribeConfigs --operation Describe --operation Read \
    --operation Write --operation Create \
    --topic $TOPIC
done

kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
  --operation DescribeConfigs --operation Describe --operation Read \
  --operation Write --operation Create \
  --topic $SHOP_API_APP_NAME

kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
  --operation DescribeConfigs --operation Describe --operation Read \
  --operation Write --operation Create \
  --topic "${SHOP_API_APP_NAME}-" \
  --resource-pattern-type prefixed

# Это мы уже выяснили на репартиционировании в процессе (group_by):
# Префикс faust.App(..., origin='shop_api'): repartition/changelog и др. дают имена вида
# shop_api.agents.<agent>-<topic>-...-repartition (см. лог воркера).
kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
  --operation DescribeConfigs --operation Describe --operation Read \
  --operation Write --operation Create \
  --topic "shop_api." \
  --resource-pattern-type prefixed

# тут такая штука: мы вызываем агента через ask(), и  этот метод,
# похоже, использует топики, наверное временные, для реализации
# этого функционала, и ему нужны соотв. такие вот права:
# Reply-топики для agent.ask() / ReplyConsumer (в т.ч. CLI): f-reply-<uuid>
kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
  --operation DescribeConfigs --operation Describe --operation Read \
  --operation Write --operation Create \
  --topic "f-reply-" \
  --resource-pattern-type prefixed

kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
  --operation Read --operation Describe \
  --group $SHOP_API_APP_NAME

kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
  --operation Read --operation Describe \
  --group "${SHOP_API_APP_NAME}-" \
  --resource-pattern-type prefixed

# Metadata / создание топиков через клиента иногда требует Describe на кластер
# (см. также секцию для schema_registry_user выше).
kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
  --operation Describe \
  --cluster "$CLUSTER_ID_STAGE"

#kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
#  --operation Write --operation Describe \
#  --transactional-id $SHOP_API_APP_NAME

#kafka-acls $COMMON_ARGS --add --allow-principal $USER_SHOP_API \
#  --operation Write --operation Describe \
#  --transactional-id "${SHOP_API_APP_NAME}-" \
#  --resource-pattern-type prefixed

echo "--- Настройка завершена! ---"
kafka-acls $COMMON_ARGS --list
