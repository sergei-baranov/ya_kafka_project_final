BOOTSTRAP="mart-broker-1:7092"
CONFIG="/etc/kafka/secrets/admin-client.properties"
COMMON_ARGS="--bootstrap-server $BOOTSTRAP --command-config $CONFIG"

TOPICS=()
USERS=("User:kafka_ui")

echo "--- 1. Очистка старых ACL ---"
for USER in "${USERS[@]}"; do
  kafka-acls $COMMON_ARGS --remove --force --allow-principal "$USER" --topic "*"
  kafka-acls $COMMON_ARGS --remove --force --allow-principal "$USER" --group "*"
  # Удаляем права на кластер, если они были (только для kafka_ui)
  if [ "$USER" == "User:kafka_ui" ]; then
    kafka-acls $COMMON_ARGS --remove --force --allow-principal "$USER" --cluster
  fi
done

echo "--- 2. Создание топиков ---"
for TOPIC in "${TOPICS[@]}"; do
  kafka-topics $COMMON_ARGS --create --topic "$TOPIC" --partitions 3 --replication-factor 3 --if-not-exists
done

echo "--- 3. Ожидание готовности топиков ---"
for TOPIC in "${TOPICS[@]}"; do
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
kafka-acls $COMMON_ARGS --add --allow-principal User:kafka_ui --operation Describe --operation Read --operation Write --topic "*"
kafka-acls $COMMON_ARGS --add --allow-principal User:kafka_ui --operation Describe --operation Read --group "*"
# Права на описание состояния всего кластера
kafka-acls $COMMON_ARGS --add --allow-principal User:kafka_ui --operation Describe --operation Create --cluster

# ...

echo "--- Настройка завершена! ---"
kafka-acls $COMMON_ARGS --list
