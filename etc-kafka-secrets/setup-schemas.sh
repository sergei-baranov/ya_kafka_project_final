echo "--- 1. Регистрируем avro-схему из product.avsc для топиков ${TOPIC_GOODS_FILTERED}, ${TOPIC_GOODS_PROHOBITED} ---"

do_schema_registry_rest_curl() {
  local method=$1
  local path=$2
  local data=$3

  curl -s -X "$method" "${SCHEMA_REGISTRY_REST_URL_INNER}$path" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "$data" \
    --cacert <(keytool -exportcert -rfc -keystore "${CONTAINER_PATH_TRUSTSTORE}" -storepass "${KAFKA_TRUSTSTORE_CREDS}" -alias "${KAFKA_TRUSTSTORE_ROOT_CA_ALIAS}") \
    --cert-type P12 --cert "${CONTAINER_PATH_KEYSTORE}:${KAFKA_KEYSTORE_CREDS}"
}

SUBJECTS=("${TOPIC_GOODS_FILTERED}-value" "${TOPIC_GOODS_PROHOBITED}-value")
COMPATIBILITY_LEVEL="FULL"
# CLEAN_SCHEMA=$(cat "${CONTAINER_PATH_SECRETS}/${PRODUCT_AVRO_SCHEMA_FILE_NAME}" | jq -Rs .)
CLEAN_SCHEMA=$(cat "${CONTAINER_PATH_SECRETS}/${PRODUCT_AVRO_SCHEMA_FILE_NAME}" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))")
JSON_BODY="{\"schema\": $CLEAN_SCHEMA}"
CONFIG_BODY="{\"compatibility\": \"$COMPATIBILITY_LEVEL\"}"

for SUBJECT in "${SUBJECTS[@]}"; do
  echo "--- Работа с $SUBJECT ---"

  echo "Установка режима $COMPATIBILITY_LEVEL..."
  CONF_RESULT=$(do_schema_registry_rest_curl PUT "/config/$SUBJECT" "$CONFIG_BODY")
  echo "Результат: $CONF_RESULT"

  # Проверка совместимости (latest)
  CHECK_RESULT=$(do_schema_registry_rest_curl POST "/compatibility/subjects/$SUBJECT/versions/latest" "$JSON_BODY")
  
  echo "CHECK_RESULT (/compatibility/subjects/${SUBJECT}/versions/latest): ${CHECK_RESULT}"

  # Если субъект новый (404), то is_compatible будет true
  # IS_COMPATIBLE=$(echo "$CHECK_RESULT" | jq -r '.is_compatible // true')
  IS_COMPATIBLE=$(echo "$CHECK_RESULT" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('is_compatible', True))")

  echo "IS_COMPATIBLE: ${IS_COMPATIBLE}"

  # ,, - это lowercase
  if [[ "${IS_COMPATIBLE,,}" == "true" ]]; then
    echo "Схема прошла проверку $COMPATIBILITY_LEVEL."
    
    # 4. Регистрацыя
    REG_RESULT=$(do_schema_registry_rest_curl POST "/subjects/$SUBJECT/versions" "$JSON_BODY")
    # NEW_ID=$(echo "$REG_RESULT" | jq -r '.id')
    NEW_ID=$(echo "$REG_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', 'error'))")
    echo "Зарегістрована! ID: $NEW_ID"
  else
    echo "ОШИБКА: Схема не соответствует требованиям $COMPATIBILITY_LEVEL compatibility level"
    echo "Детали: $CHECK_RESULT"
    exit 1
  fi
done


echo "--- Настройка завершена! ---"