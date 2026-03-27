# yakafka_project_final

## Содержание

- [Общее описание](#general_descr)
- [Быстрая проверка](#fast_assignment_review)
- [Разработка: Первая итерация: Два Kafka-кластера в репликации ведущий-ведомый. Mirror Maker.](#dev_proc_iteration_1)
- [Разработка: Вторая итерация: SHOP API. Kafka Connect, Schema Registry, Faust.](#dev_proc_iteration_2)
  - [Kafka connect, source-коннектор shop-api-stage-reader (SpoolDirSchemaLessJsonSourceConnector)](#dev_proc_iteration_2_1)
  - [Schema Registry, Faust-приложение](#dev_proc_iteration_2_2)

## <a name="general_descr">Общее описание</a>

...

### Зависимости сервисов

- Сначала надо развернуть два кафка-кластера
- Затем надо запустить сервис, который создаст необходимые топики, в частности служебные для разных сервисов, и выставит ACL-ы (завершается после выполнения задания) (завершается после выполнения задания) (завершается после выполнения задания). Это позволит нам сузить права некоторым сервисам, не давая им слишком много прав для создания ими служебных тоиков и т.п.
- Далее следует поднять Schema Registry,
- А вслед за ним - сервис, который зарегистрирует в Schema Registry необходимые для работы прочих сервисов схемы под необходимые топики (завершается после выполнения задания).
- После этого можно запускать Mirror Maker 1, за ним Kafka Connect, сервисы приложений и т.п.

### <a name="general_assignment_review">Как проверять проект</a>

- Чтобы просто проверить исполнение - смотрим код в файлах и исполняемся по инструкциям в разделе **"Быстрая проверка"**,
- чтобы проверить ход выполнения проекта - читаем следующие за ним разделы.

## <a name="fast_assignment_review">Быстрая проверка</a>

...

## <a name="dev_proc_iteration_1">Разработка: Первая итерация: Два Kafka-кластера в репликации ведущий-ведомый. Mirror Maker.</a>

### Узлы (сервисы в компоузере)

- два кафка-кластера, каждый в своей докер-сети, `KRaft`, в каждом кластере три контроллера и три брокера, SSL(TLS)/SASL/ACL
- `kafka-ui`, в двух сетях, настройка на два кластера, ACL даёт "много прав" (для упрощения)
- служебный узел для автосоздания топика, в двух сетях, отрабатывает и умирает
- узел для запуска `Mirror Maker 1`, в двух сетях, репликация одного топика из ведущего кластера в ведомый

### Ограничения первой фазы

- **Сертификаты** - подготавливаем руками до разворачивания проекта (есть bash-скрипт, см. его код перед зхапуском), прокидываем volume-ами
- **Настройка ACL** - bash-скриптами, запускаемыми руками на брокере каждого из двух кластеров. Предварительно же обозначаем трёх суперпользователей в каждом кластере.
- Без узлов серверов приложений, без кафка коннекта, без схема реджистри
- Ограничения ресурсов контейнеров через deploy-секции compose: минимальный ресурс, для запуска на одной машине
- Конфигурирование через `env`-файл: насколько возможно, при изменении конфига требуются так же небольшие изменения в `bash`-скриптах, `entrypoint`-ах сервисов компоузера, пересоздание сертификатов и т.п., в зависимости от изменений

### Файлы первой итерации (для версионирования по фазам процесса разработки)

```bash
tree -a phase1

phase1
├── ca.cnf
├── compose.yaml
├── .env.example
├── etc-kafka-secrets
│   ├── setup-acls-mart.sh
│   └── setup-acls-stage.sh
├── kafka.cnf.template
└── make-certs.sh
```

### Что проверяем после итерации

Что у нас есть два кластера, которые запускаются и не падают, и что сообщения из определённого топика реплицируются из одного в другой.

Так же убеждаемся, что работают ACL (в части пользователя Кафка юи), делая ошибки в сертификатах (в SAN) так же убеждаемся, что работает SSL(TLS)+SASL.

### Запускаемся после перфой фазы и проверяемся

Копируем содержимое директории `phase1` в директорию проета на хостовой машине, идём по шагам:

#### 1. Ничего не будем менять в .env.example и соотв. нигде

Но если надо, то например `SAN`-ы меняем/добавляем в `[alt_names]` в `kafka.cnf.template` и `.env.example`, ограничения ресурсов в `.env.example`, если меняли названия хостов контейнеров, то кроме `compose.yaml` надо поменять `setup-acls-mart.sh` и `setup-acls-stage.sh`, и т.д.

#### 2. Генерируем сертификаты

Скрипт `make-certs.sh`

- создаст `tmp`-директорию,
- в ней сгенерит `kafka.cnf` из `kafka.cnf.template` и `.env.example`,
- на основе `ca.cnf` и `kafka.cnf` за несколько шагов создаст `kafka.keystore.pkcs12` и `kafka.truststore.jks`,
- поместит их в `etc-kafka-secrets`,
- `tmp`-директорию с промежуточными файлами удалит.

```bash
chmod +x make-certs.sh
make-certs.sh
```

#### 3. Разворачиваемся, убеждаемся в общей работоспособности проекта

**Разворачиваем проект:**

```bash
# это просто посмотреть, что 100500 переменных окружения отработали
sudo docker compose --env-file .env.example config
...
sudo docker compose --env-file .env.example up -d
...
sudo docker ps -a
...
# можно посмотреть topic-creation, mirror-maker, оба первых брокера, допустим
sudo docker logs ...
# мы заморочились с лимитированием ресурсов - посмотрим на них :)
sudo docker stats --no-stream
```

**И идём в веб UI:**

`http://localhost:8070/` на хостовой машине (удалённо у меня она же `http://192.168.100.225:8070/`) - видим два наших кластера и по нолю топиков в каждом кластере, но у нас (у пользователя `kafka_ui`) пока и нет прав (поэтому мы топики и не видим).

**Дадим права пользователю `kafka_ui`:**

Два разных немножко bash-скрипта запустим один на брокере `stage`-кластера, второй - `mart`-кластера.

**stage-broker-1:**

```bash
tesla@tesla:/.../ya_kafka_project_final$ sudo docker exec -it stage-broker-1 bash

[root@stage-broker-1 appuser]# chmod +x /etc/kafka/secrets/setup-acls-stage.sh

[root@stage-broker-1 appuser]# /etc/kafka/secrets/setup-acls-stage.sh

--- 1. Очистка старых ACL ---
--- 2. Создание топиков ---
--- 3. Ожидание готовности топиков ---
--- 4. Настройка прав для kafka_ui ---
...
--- Настройка завершена! ---
Current ACLs for resource `ResourcePattern(resourceType=GROUP, name=*, patternType=LITERAL)`:

    (principal=User:kafka_ui, host=*, operation=READ, permissionType=ALLOW)
    (principal=User:kafka_ui, host=*, operation=DESCRIBE, permissionType=ALLOW) 
...

[root@stage-broker-1 appuser]# exit
exit
```

**mart-broker-1:**

```bash
tesla@tesla:/.../ya_kafka_project_final$ sudo docker exec -it mart-broker-1 bash

[root@mart-broker-1 appuser]# chmod +x /etc/kafka/secrets/setup-acls-mart.sh

[root@mart-broker-1 appuser]# /etc/kafka/secrets/setup-acls-mart.sh

--- 1. Очистка старых ACL ---
--- 2. Создание топиков ---
--- 3. Ожидание готовности топиков ---
--- 4. Настройка прав для kafka_ui ---
...
--- Настройка завершена! ---
Current ACLs for resource `ResourcePattern(resourceType=GROUP, name=*, patternType=LITERAL)`:

    (principal=User:kafka_ui, host=*, operation=READ, permissionType=ALLOW)
    (principal=User:kafka_ui, host=*, operation=DESCRIBE, permissionType=ALLOW) 
...

[root@mart-broker-1 appuser]# exit
exit
tesla@tesla:/media/tesla/NETAC_4T/VCS/ya_kafka_project_final$
```

**И идём в веб UI:**

`http://localhost:8070/` (`http://192.168.100.225:8070/`) - теперь видим кол-во топиков в каждом кластере.

Это подтверждает работоспособность наших настроек SSL/SASL/ACL.

Видим, что топик `goods-filtered` создан на обоих кластерах.

**Напишем что-то в этот топик, и он реплицируется между кластерами**

Пойдём напишем что-то в него в кластере `stage` и если всё хорошо с нашим `Mirror Maker 1` - увидим сообщение в кластере `mart`.

**ДА, ВСЁ РАБОТАЕТ, УРА.**

### План на Итерацию 2

**Теперь надо реализовать `SHOP API`**, для этого

- присовокупить к сервисам `Kafka Connect`
- и `Schema Registry`,
- сервис с приложением на `Faust-streaming`,
- source-коннектор файловый,
- залить в `Schema Registry` avro-схему,
- создать топики, необходимые для работы фауст-приложения,
- научить то приложение фильтровать топик,
- а так же приделать ендпойнты на управление стоп-словами в названиях товаров (и реализовать),
- нагенерить несколько файлов-источников товаров,
- придумать, как они будут попадать в source-директорию для коннектора,
- и т.п.

Как-то так (предварительно).

---

`goods-raw`, `goods-filtered`, `goods-dlq`, `goods-prohibited`

- `goods-raw`: сюда пишет Kafka Connect
- `goods-dlq`: `dead letter queue` - сюда Faust-воркер отправляет соолбщения, не прошедшие по схеме
- `goods-prohibited`

Во втором кластере только топик `goods-filtered`, который получает данные из топика первого кластера через MirrorMaker 1.

Топик `goods-raw` получает данные через т. наз. `SHOP API`: разворачиваем `Kafka Connect`, в нём коннектор чтения файлов из директории `shop_api_stage`.

Как файлы попадают в эту директорию: `bash`- или `python`- скрипт `shop_api_emulator` имитирует поступление файлов в эту эмуляцию API, копируя их из директории `shop_api_fixtures` с какой-то периодичностью, "пара штук" файлов. Файлы предсозданы, лежат у нас в проекте в git, директория подключается `volume`-ом.

Faust-приложение фильтрует сообщения из `goods-raw`, хорошие отправляет в `goods-filtered`, остальные - в `goods-dlq` (развернуть Schema Registry и залить в него схему товаров) и `goods-prohibited` (прочитались, но не прошли `prohibited`-фильтр).

Фауст будет запускать приложение "резидентом" и поддерживать работоспособность (+ superviserd), мы так делали в уроке про стоп-слова или что-то такое. И добавить интерфейс чтения списка и добавления/удаления запрещённых товаров, как в той же домашке...

Faust-приложение для CLIENT API - это про другое, про следующую итерацию.

Нужен ли уже сейчас ksqldb? не обязательно. Как стыковать ksqldb с TLS/SASL/ACL? Продумать...

Мониторинг: на следующих итерациях.

Тестирование и отладка: Продумать...

Чего нам надо добиться на этом этапе: `goods-filtered` на втором кластере, заполнен из файлов, по авро-схеме...

### Третья итерация: CLIENT API

...

### Четвёртая ...

## <a name="dev_proc_iteration_2">Разработка: Вторая итерация: SHOP API. Kafka Connect, Schema Registry, Faust.</a>

### <a name="dev_proc_iteration_2_1">Kafka connect, source-коннектор shop-api-stage-reader (SpoolDirSchemaLessJsonSourceConnector)</a>

Файлы из директории `shop_api_stage` Kafka-коннектором `SpoolDirSchemaLessJsonSourceConnector` будут писаться в топик `goods-raw` без схемы.

Файлы после успешной переброски будут удаляться. При ошибках - перемещаться в директорию `shop_api_error`.

Работа со схемой будет реализована на следующем этапе - python-приложением, которое будет фильтровать сообщения из топика `goods-raw` в топики `goods-filtered`, `goods-dlq`, `goods-prohibited`.

Настройка коннекта под jmx-метрики - так же на следующих итерациях.

Для этого нам надо добавить узел `kafka-connect` в проект, добавить его в `SAN`-ы сертификата, в сервис создания топиков добавить создание топика `goods-raw` на `stage`-кластере, настроить коннектор работать от пользователя `connect_user`, которого внести в права на необходимые (в том числе служебные) топики, группы и т.п. (`./etc-kafka-secrets/setup-acls-stage.sh`) и т.д.

Плагин берём отсюда: https://hub-downloads.confluent.io/api/plugins/confluentinc/kafka-connect-spooldir/versions/2.0.71/confluentinc-kafka-connect-spooldir-2.0.71.zip, и помещаем в контейнер при сборке (чтобы не вызывать `confluent-hub install` каждый раз).

Источниками данных будем рассматривать любые `.json`-файлы в директории, предполагая, что в каждом файле могут размещаться один и более json-объектов один за другим без обрамления в общий массив. Объекты pretty-форматированные, и друг от друга отделённые простыми переносами строк (Concatenated/Streaming JSON).

После запуска проекта надо установить коннектор через конфиг в файле `./kafka-connect/shop_api.conf.json`.

Так же надо раздать права пользователшю кафка-коннет, и выставить права на лиректории с файлами, приаттаченные фольюмом.

После этого кидаем файлы в директорию, они должны исчезать, а товары из них появляться в топике.

#### Сначала проверяем работу системы с пользователем admin в kafka-connect:

1. запускаемся

```bash
sudo docker compose --env-file .env.example up -d
...
sudo docker ps -a
...
sudo docker logs topic-creation
...
Created topic goods-filtered.
Created topic goods-filtered.
...
sudo docker stats --no-stream
...
```

Всё хорошо.

2. директории для работы коннекта - ставим владельца и права

на хостовой машине (директории расшарены как volume)

```bash
tesla@tesla:.../ya_kafka_project_final$ ls -lah kafka-connect/data
...
drwxr-xr-x 2 root  root  4.0K Mar 22 10:14 shop_api_error
drwxr-xr-x 2 root  root  4.0K Mar 22 10:14 shop_api_stage

tesla@tesla:.../ya_kafka_project_final$ sudo chown -R 1000:1000 kafka-connect/data
tesla@tesla:.../ya_kafka_project_final$ sudo chmod -R 775 kafka-connect/data
tesla@tesla:.../ya_kafka_project_final$ ls -lah kafka-connect/data
...
drwxrwxr-x 2 tesla tesla 4.0K Mar 22 10:14 shop_api_error
drwxrwxr-x 2 tesla tesla 4.0K Mar 22 10:14 shop_api_stage

```

3. проверим rest api кафка-коннект-а

```bash
# порт для рест апи мы обозначили как 8083, а наружу светим его как 8073
tesla@tesla:.../ya_kafka_project_final$ curl -s http://localhost:8073/connectors | jq
[]
```

Пустой массив в ответ - всё работает.

4. Отправим наш конфиг (`./kafka-connect/shop_api.conf.json`) для создания коннектора `shop-api-stage-reader`

```bash
# 8073, connectors, "name": "shop-api-stage-reader"
curl -sX POST -H 'Content-Type: application/json' --data @./kafka-connect/shop_api.conf.json http://localhost:8073/connectors | jq

tesla@tesla:.../ya_kafka_project_final$ curl -sX POST -H 'Content-Type: application/json' --data @./kafka-connect/shop_api.conf.json http://localhost:8073/connectors | jq
{
  "name": "shop-api-stage-reader",
  "config": {
    "connector.class": "com.github.jcustenborder.kafka.connect.spooldir.SpoolDirSchemaLessJsonSourceConnector",
    "tasks.max": "1",
    "input.path": "/data/shop_api_stage",
    "error.path": "/data/shop_api_error",
    "input.file.pattern": "^.*\\.json$",
    "cleanup.policy": "DELETE",
    "halt.on.error": "false",
    "topic": "goods-raw",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "name": "shop-api-stage-reader"
  },
  "tasks": [],
  "type": "source"
}

tesla@tesla:.../ya_kafka_project_final$ curl -s http://localhost:8073/connectors | jq
[
  "shop-api-stage-reader"
]

curl -s http://localhost:8073/connectors/shop-api-stage-reader | jq
...

curl -s http://localhost:8073/connectors/shop-api-stage-reader/config | jq
...

tesla@tesla:.../ya_kafka_project_final$ curl -s http://localhost:8073/connectors/shop-api-stage-reader/status | jq
{
  "name": "shop-api-stage-reader",
  "connector": {
    "state": "RUNNING",
    "worker_id": "kafka-connect:8083"
  },
  "tasks": [
    {
      "id": 0,
      "state": "RUNNING",
      "worker_id": "kafka-connect:8083"
    }
  ],
  "type": "source"
}

```

Вроде всё норм.

5. Теперь посмотрим логи коннектора и брокера

Добиваемся, чтобы не было ошибок. Например ниже ошибка, причина которой в том, что для сервиса `kafka-connect` проекта мы забыли прописать `CONNECT_PRODUCER_SSL_`-переменные окружения рядом с `CONNECT_SSL_`-переменными.

```bash
...$ sudo docker logs -n 20 kafka-connect
...
[2026-03-22 10:12:15,802] ERROR [Producer clientId=connector-producer-shop-api-stage-reader-0] Connection to node -1 (stage-broker-1/172.18.0.2:1092) failed authentication due to: SSL handshake failed (org.apache.kafka.clients.NetworkClient)
...

...$ sudo docker logs -n 20 stage-broker-1
...
[2026-03-22 10:14:01,679] INFO [SocketServer listenerType=BROKER, nodeId=1000] Failed authentication with /172.18.0.11 (channelId=172.18.0.2:1092-172.18.0.11:43870-165) (SSL handshake failed) (org.apache.kafka.common.network.Selector)
...
```

После всех правок - всё работает (пока мы ещё не кидали никакие файлы в директорию):

```bash
...
[2026-03-22 11:29:13,534] INFO No files matching input.file.pattern were found in /data/shop_api_stage (com.github.jcustenborder.kafka.connect.spooldir.InputFileDequeue)
[2026-03-22 11:29:14,034] INFO No files matching input.file.pattern were found in /data/shop_api_stage (com.github.jcustenborder.kafka.connect.spooldir.InputFileDequeue)
[2026-03-22 11:29:14,534] INFO No files matching input.file.pattern were found in /data/shop_api_stage (com.github.jcustenborder.kafka.connect.spooldir.InputFileDequeue)
...
```

6. Отправим файлы в директорию `/data/shop_api_stage` и узрим сообщения в топике.

Сначала раздрадим права (для кафка-коннекта мы пока что указали работать под admin-ом, но для kafka_ui права надо выдять явно)

```bash
tesla@tesla:.../ya_kafka_project_final$ sudo docker exec -it stage-broker-1 bash
[sudo] password for tesla: 
[root@stage-broker-1 appuser]# chmod +x /etc/kafka/secrets/setup-acls-stage.sh
[root@stage-broker-1 appuser]# /etc/kafka/secrets/setup-acls-stage.sh
...
--- 4. Настройка прав для kafka_ui ---
...
```

Теперь мы увидим глазами сообщения в топике `goods-raw` как только они появятся.

Файлы просто скопируем в диреторию руками.

```bash
.../ya_kafka_project_final$ cp ./shop_api_fixtures/boo.json ./kafka-connect/data/shop_api_stage
.../ya_kafka_project_final$ ls ./kafka-connect/data/shop_api_stage
.../ya_kafka_project_final$ ls ./kafka-connect/data/shop_api_error

.../ya_kafka_project_final$ cp ./shop_api_fixtures/moo.json ./kafka-connect/data/shop_api_stage
.../ya_kafka_project_final$ ls ./kafka-connect/data/shop_api_stage
.../ya_kafka_project_final$ ls ./kafka-connect/data/shop_api_error
```

В shop_api_stage файлы исчезли, в shop_api_error не появились - подозреваем, что всё прошло хорошо.

Идём в UI и видим, что в нашем целевом топике 6 сообщений

`http://192.168.100.225:8070/ui/clusters/stage/all-topics?perPage=25`

| Topic Name | Partitions | Out of sync replicas | Replication Factor | Number of messages | Size |
|------------|------------|----------------------|--------------------|--------------------|------|
| goods-filtered | 3 | 0 | 3 | 0 | 0 Bytes |
| goods-raw | 3 | 0 | 3 | 6 | 5 KB |

Файлы мы на этой итерации просто накидали "от барабана":

`boo.json`:

```
{
    "prop1": "boo1",
    "prop2": "zoo1"
}

{
    "prop1": "boo2",
    "prop2": "zoo2"
}

{
    "prop1": "boo3",
    "prop2": "zoo3"
}

```

`moo.json`:

```
{
    "prop1": "moo1",
    "prop2": "zoo1"
}

{
    "prop1": "moo2",
    "prop2": "zoo2"
}

{
    "prop1": "moo3",
    "prop2": "zoo3"
}

```

Идём в сообщения:

`http://192.168.100.225:8070/ui/clusters/stage/all-topics/goods-raw/messages`

| Offset | Partition | Timestamp | KeyPreview | ValuePreview |
|--------|-----------|-----------|------------|--------------|
| 0 | 0 | 3/22/2026, 16:34:14 |  | "{\"prop1\":\"boo1\",\"prop2\":\"zoo1\"}" |
| 1 | 0 | 3/22/2026, 16:34:14 | "{\"prop1\":\"boo2\",\"prop2\":\"zoo2\"}" |
| 2 | 0 | 3/22/2026, 16:34:14 | "{\"prop1\":\"boo3\",\"prop2\":\"zoo3\"}" |
| 3 | 0 | 3/22/2026, 16:34:51 | "{\"prop1\":\"moo1\",\"prop2\":\"zoo1\"}" |
| 4 | 0 | 3/22/2026, 16:34:51 | "{\"prop1\":\"moo2\",\"prop2\":\"zoo2\"}" |
| 5 | 0 | 3/22/2026, 16:34:51 | "{\"prop1\":\"moo3\",\"prop2\":\"zoo3\"}" |

Видим 6 сообщений, соответствующих нашим файлам.

Ну и сходим в логи коннектора например вот так:

```bash
tesla@tesla:...$ sudo docker logs kafka-connect | grep "INFO Removing processing flag"
...
[2026-03-22 13:34:14,207] INFO Removing processing flag /data/shop_api_stage/boo.json.PROCESSING (com.github.jcustenborder.kafka.connect.spooldir.InputFile)
[2026-03-22 13:34:51,226] INFO Removing processing flag /data/shop_api_stage/moo.json.PROCESSING (com.github.jcustenborder.kafka.connect.spooldir.InputFile)

```

Что мы имеем: Кафка-коннект работает коннектором `shop-api-stage-reader` класса `SpoolDirSchemaLessJsonSourceConnector`, пишет товары в топик `goods-raw`. Ура, но: он работает под пользователем `admin`.

#### Провернём всё то же, но под пользователем `connect_user`.

1. **Делаем следующее:**

- вносим изменения в `CONNECT_PRODUCER_SASL_JAAS_CONFIG` и `CONNECT_SASL_JAAS_CONFIG` сервиса `kafka-connect` в `compose.yaml`
- и в `broker.sasl.jaas.conf` там же в `compose.yaml`, в `x-broker-entry-write-secrets` (вносим пользователя `connect_user)
- даём этому пользователю "прям много" (см. ниже, какие именно) прав во `stage`-кластере через скрипт `./etc-kafka-secrets/setup-acls-stage.sh`
- в этом же скрипте добавляем изменения, чтобы служебные топики получали политику удаления `compact`, и количество партиций строго определённое согласно требованиям Kafka Connect (например `connect-configs` должен иметь строго одлну партицию)
- вызов скриптов раздачи прав теперь не будем делать руками, а встроим в контейнер `topic-creation`: он подключён к двум сетям, делает топики, входит в зависимости контейнеров `kafka-ui` и `kafka-connect` с условием `service_completed_successfully`, пускай и создаёт топики, и делает ACL-ы на оба кластера.
- комментируем лимиты на cpu у сервисов (создание топиков и прав становится быстрее)
- `kafka-connect` система отрубает по памяти (в логах пусто, см. `sudo dmesg | grep -i oom`, `sudo docker inspect kafka-connect --format='{{.State.OOMKilled}}'`). Подбираем ограничения для контейнера: вводим в него переменную окружения `KAFKA_HEAP_OPTS` согласовываем её значение со значениями лимитов на память контейнера (всё выносим в `.env`-файл; лимитов контейнера долдно быть больше, чем heap opts)
- комментируем (можно и удалить) `CONNECT_INTERNAL_`-переменные в сервисе `kafka-connect` (эти настройки deprecated)
- выставляем опцию `CONNECT_PLUGIN_DISCOVERY: "only_scan"` (SpoolDir "старенький", просто чтобы не мельтешило в логах `kafka-connect`-а)
- перезапускаем проект, смотрим логи, создаём коннектор, кидаем файлы в директорию для потребления коннектором, видм исчезающие файлы и появляющиеся сообщения в топике

2. **Какие права нужны этому пользователю, чтобы вся наша затея работала:**

(see `./etc-kafka-secrets/setup-acls-stage.sh`)

- `DescribeConfigs`, `Describe`, `Read`, `Write` на служебные топики, которым мы задали имена `connect-configs`, `connect-offsets`, `connect-status` (в сервисе в `compose.yaml` переменныфе `CONNECT_CONFIG_STORAGE_TOPIC` и т.д.)

- `Describe`, `Write` на целевой топик `goods-raw`

- `Describe`, `Read` на группу консьюмеров, которой мы присвоили имя `kafka-connect`, взяв из имени контейнера (`CONNECT_GROUP_ID: '${SERVICE_KAFKA_CONNECT_NAME}'`)

- `Describe`, `Write` на транзакции (на группу `kafka-connect`)

- `Create` на кластер (давать... не давать... **попробуем не дать**, сами создадим все топики в двух местах (в сервисе `topic-creation` и в скрипте `setup-acls-stage.sh`))

3. **Делаем все шаги по разворачиванию:**

```bash
sudo docker compose --env-file .env.example down -v
...
sudo docker compose --env-file .env.example up -d
...
# topic-creation Waiting будет относительно долго: создание топиков и ACL-ов
Container topic-creation                              Waiting
...
sudo docker ps -a
...
sudo docker logs topic-creation
...
sudo docker logs kafka-connect
...
sudo docker stats --no-stream
...
ls -lah kafka-connect/data
sudo chown -R 1000:1000 kafka-connect/data
sudo chmod -R 775 kafka-connect/data
ls -lah kafka-connect/data

curl -s http://localhost:8073/connectors | jq
[]

curl -sX POST -H 'Content-Type: application/json' --data @./kafka-connect/shop_api.conf.json http://localhost:8073/connectors | jq
{
  "name": "shop-api-stage-reader",
  "config": {
    "connector.class": "com.github.jcustenborder.kafka.connect.spooldir.SpoolDirSchemaLessJsonSourceConnector",
    "tasks.max": "1",
    "input.path": "/data/shop_api_stage",
    "error.path": "/data/shop_api_error",
    "input.file.pattern": "^.*\\.json$",
    "cleanup.policy": "DELETE",
    "halt.on.error": "false",
    "topic": "goods-raw",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "name": "shop-api-stage-reader"
  },
  "tasks": [],
  "type": "source"
}

curl -s http://localhost:8073/connectors/shop-api-stage-reader/status | jq
{
  "name": "shop-api-stage-reader",
  "connector": {
    "state": "RUNNING",
    "worker_id": "kafka-connect:8083"
  },
  "tasks": [
    {
      "id": 0,
      "state": "RUNNING",
      "worker_id": "kafka-connect:8083"
    }
  ],
  "type": "source"
}

cp ./shop_api_fixtures/boo.json ./kafka-connect/data/shop_api_stage
ls ./kafka-connect/data/shop_api_stage
ls ./kafka-connect/data/shop_api_error

cp ./shop_api_fixtures/moo.json ./kafka-connect/data/shop_api_stage
ls ./kafka-connect/data/shop_api_stage
ls ./kafka-connect/data/shop_api_error

http://192.168.100.225:8070/ui/clusters/stage/all-topics/goods-raw ,
http://192.168.100.225:8070/ui/clusters/stage/all-topics/goods-raw/messages

6 сообщений

sudo docker logs kafka-connect | grep "oo.json"
```

**Всё прекрасно.**

4. Проверим, не сломали ли `Mirror Maker 1`

Отправляем "Буу" в топик `goods-filtered` на `stage`-кластере, читаем в том же топике на `mart`-кластере (всё через web UI).

**Всё прекрасно опять.**


### <a name="dev_proc_iteration_2_2">Schema Registry, Faust-приложение</a>

На данный момент `Kafka Connect` перемещает товары от магазинов из дректории с файлами в формате `Streaming JSON` в топик `goods-raw` на `stage`-кластере Kafka, а `Mirror Maker 1` реплицирует топик `goods-filtered` со `stage`-кластера в `mart`-кластер.

Теперь надо сделать приложение, которое будет перекладывать товары из топика `goods-raw` в топик `goods-filtered` на `stage`-кластере, отбраковывая не проходящие по схеме, а так же не проходящие чёрный список товаров по имени.

Коннектор `Kafka Connect` мы создали как schemaless, чтобы не терять сообщения (для разбора ошибок использования SHOP API и т.п.) и не создавать лишнюю точку отказа.

Сообщения в топике `goods-filtered` уже должны будут соответствовать схеме, а для этого будем вводить в проект узел `Schema Registry` и регистрировать в нём схему для `goods-filtered`.

Python-приложение должно читать сообщения из топика `goods-raw`, проверять на соответствие схемы, не соответствующие - отправлять в топик `goods-dlq`, соответствующие - фильтровать по названию товара, оставляя только прошедшие фильтр по чёрному списку, отправлять их в топик `goods-filtered`, а не прошедшие - в топик `goods-prohibited`. Соотв. топик `goods-prohibited` тоже можно связать со схемой в `Schema Registry`.

Так же pyhon-приложение должно предоставить консольное api для управления чёрным списком названий товаров: просмотр, добвавление, удаление названия. Список будем хранить тоже в Кафке, в топике `prohibition-list`.

Сначала сформируем схему и фикстуры товаров для демо-проекта.

Схему строим на основе прмиера товара из ТЗ. Обязательными полями делаем `product_id`, `name`, `price`, `stock`, `sku`, `store_id`, `created_at`, `updated_at`.

Хранить её будем в файле `./etc-kafka-secrets/product.avsc`:

```json
{
  "type": "record",
  "name": "Product",
  "namespace": "com.shop.inventory",
  "fields": [
    { "name": "product_id", "type": "string" },
    { "name": "name", "type": "string" },
    {
      "name": "price",
      "type": {
        "type": "record",
        "name": "Price",
        "fields": [
          { "name": "amount", "type": "double" },
          { "name": "currency", "type": "string" }
        ]
      }
    },
    {
      "name": "stock",
      "type": {
        "type": "record",
        "name": "Stock",
        "fields": [
          { "name": "available", "type": "int" },
          { "name": "reserved", "type": "int" }
        ]
      }
    },
    { "name": "sku", "type": "string" },
    { "name": "store_id", "type": "string" },
    { "name": "created_at", "type": "string" },
    { "name": "updated_at", "type": "string" },
    { "name": "description", "type": ["null", "string"], "default": null },
    { "name": "category", "type": ["null", "string"], "default": null },
    { "name": "brand", "type": ["null", "string"], "default": null },
    { 
      "name": "tags", 
      "type": ["null", { "type": "array", "items": "string" }], 
      "default": null 
    },
    { 
      "name": "images", 
      "type": ["null", { 
        "type": "array", 
        "items": {
          "type": "record",
          "name": "Image",
          "fields": [
            { "name": "url", "type": "string" },
            { "name": "alt", "type": "string" }
          ]
        }
      }], 
      "default": null 
    },
    { 
      "name": "specifications", 
      "type": ["null", { "type": "map", "values": "string" }], 
      "default": null 
    },
    { "name": "index", "type": ["null", "string"], "default": null }
  ]
}
```

Почему в `etc-kafka-secrets`? Потому что схему надо залить в Schema Registry, делать это мы поручим сервису `schemas-registrator`, а эту директорию мы прокидываем во все наши контейнеры volume-ом, соотв. удобно в неё и ещё что-то размещать нужное (по-хорошему позже надо сделать отдельные директории и volume-ы (TODO)).

Сервис (`topic-creation`) у нас уже используется для создания топиков и для раздачи ACL-правил, а сервис `schemas-registrator` зарегистрирует схему на два топика.

Между запусками этих двух сервисов запустится `schema-registry`, работающий от пользователя, которому `topic-creation` дал права на им же созданные служебные топики.

Для этого нам надо в проект добавить сам сервис `schema-registry`, и для работы Faust-воркеров и апи нам надо добавить сервис `shop-api-app`.

Сервис `schema-registry` настроим на SSL на вход, в виде mTLS (`SCHEMA_REGISTRY_SSL_CLIENT_AUTH: "required"`).

Как следствие, надо добавить SAN-ы в сертификат, надо добавить хосты в SASL, ну и про ACL мы только что написали.

Служебным топиком для Schema Registry явно выставим тот же, что идёт по-умолчанию: `_schemas`.

~~Так же должен быть создан топик `__transaction_state` с определёнными характеристиками, но ACL на него давать никому не надо (брокеры будут писать в него системным процессом, а предсоздать его надо, чтобы Schema Registry мог запуститься, так как мы отключили автосоздание топиков и т.п.).~~

Пользователя, под которым будет в Кафку ходить Schema Registry, назовём `schema_registry_user`.

Группа консьюмеров, которую обозначает Schema Registry при работе с Кафка, называется так же, как и служебный топик (`SCHEMA_REGISTRY_KAFKASTORE_TOPIC`), либо задаётся переменной `SCHEMA_REGISTRY_KAFKASTORE_GROUP_ID`. Мы попробуем задать кастомное имя группы: `schema_registry_group`.

~~Так же кастомно зададим `SCHEMA_REGISTRY_KAFKASTORE_TRANSACTIONAL_ID` как `schema-registry-tx` (если нет, то права надо давать на `schema-registry-*` (вроде бы)).~~

NB: в процессе, борьба за транзакционность, идемпотентность и `exactly one` понавставляли всякого, например  для брокеров:
```
KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 3
KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 2
KAFKA_TRANSACTION_STATE_LOG_NUM_PARTITIONS: 50
KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS: 50
```
, и т.п., поэтому: **рабочая конфигурация - см. код (фиксация по итерациям в директориях phaseN), в этом readme больше поэтапка расписана, чем все конкретные трудности и решения**

**NB: транзакционность и идемпотентность для продьюсера Schema Registry включить не удалось**

**Всё эти имена стараемся через env-файл проводить.**

**ACL-ы в Кафке, которые понадобятся:**

- пользователю `schema_registry_user` дадим `DESCRIBE_CONFIGS`, `READ`, `WRITE`, `CREATE`, `DESCRIBE` на топик `_schemas`
- дать `READ` группе `schema_registry_group`
- дать `DESCRIBE` на кластер
- ~~`DESCRIBE`, `WRITE` на транзакции~~

**Где что добавляем/правим:**

- `setup-acls-stage.sh`: создание служебного топика (в `compact`-списке), `ACL`-ы;
- Хосты для `SSL` (`mTLS`) прописываем в cnf для сертификата (`./kafka.cnf.template`);
- `SASL`-пользователей вносим в `compose.yaml` (ищи где динамически формируем секцию `KafkaServer` в `broker.sasl.jaas.conf`);
- всё стараемся провести через `.env.example`, когда получается малой кровью (`compose.yaml`, `kafka.cnf.template`)
- сервис `schemas-registrator`, который запускает скрипт `setup-schemas.sh`, который регистрирует схему из файла `product.avsc`

**Mirror Maker 1:**

Надо прописать (у нас это в `compose.yaml`)

- в `producer.properties`

```
key.serializer=org.apache.kafka.common.serialization.ByteArraySerializer
value.serializer=org.apache.kafka.common.serialization.ByteArraySerializer
```

- и в `consumer.properties`

```
key.deserializer=org.apache.kafka.common.serialization.ByteArrayDeserializer
value.deserializer=org.apache.kafka.common.serialization.ByteArrayDeserializer
```

Можно для начала проверить проект, не запуская сервис `shop-api-app` (Faust-приложение для фильтрации товаров по чёрному списку), просто посмотреть, всё ли запустилось, зарегистрировалась ли avro-схема в реестре.

```bash
# генерируем сертификат
chmod +x make-certs.sh
./make-certs.sh ./.env.example

# разворачиваем проект
sudo docker compose --env-file .env.example up -d
# NB: topic-creation будет работать относительно долго

# проверяем в целом
sudo docker ps -a
...

# topic-creation
sudo docker logs topic-creation
--- 1. Очистка старых ACL ---
--- 2. Создание топиков ---
Создаём топик connect-configs cleanup.policy=compact с 1 партициями...
Created topic connect-configs.
...
Current ACLs for resource `ResourcePattern(resourceType=GROUP, name=*, patternType=LITERAL)`: 
    (principal=User:kafka_ui, host=*, operation=READ, permissionType=ALLOW)
    (principal=User:kafka_ui, host=*, operation=DESCRIBE, permissionType=ALLOW)

# schemas-registrator
sudo docker logs schemas-registrator
Ждём готовности Schema Registry на https://schema-registry:8081...
--- 1. Регистрируем avro-схему из product.avsc для топиков goods-filtered, goods-prohibited ---
--- Работа с goods-filtered-value ---
Установка режима FULL...
Результат: {"compatibility":"FULL"}
CHECK_RESULT (/compatibility/subjects/goods-filtered-value/versions/latest): {"is_compatible":true}
IS_COMPATIBLE: True
Схема прошла проверку FULL.
Зарегістрована! ID: 1
--- Работа с goods-prohibited-value ---
Установка режима FULL...
Результат: {"compatibility":"FULL"}
CHECK_RESULT (/compatibility/subjects/goods-prohibited-value/versions/latest): {"is_compatible":true}
IS_COMPATIBLE: True
Схема прошла проверку FULL.
Зарегістрована! ID: 1
--- Настройка завершена! ---

# schema-registry
sudo docker logs schema-registry
...
[2026-03-27 12:49:48,046] INFO 172.19.0.9 - - [27/Mar/2026:12:49:48 +0000] "POST /subjects/goods-prohibited-value/versions HTTP/2.0" 200 8 "-" "curl/7.61.1" 11 (io.confluent.rest-utils.requests)

# kafka connect TODO: создать ещё контейнер, чтобы конфиг коннекту регил
curl -sX POST -H 'Content-Type: application/json' --data @./kafka-connect/shop_api.conf.json http://localhost:8073/connectors | jq
...

curl -s http://localhost:8073/connectors/shop-api-stage-reader/status | jq
...

cp ./shop_api_fixtures/boo.json ./kafka-connect/data/shop_api_stage
ls ./kafka-connect/data/shop_api_stage
ls ./kafka-connect/data/shop_api_error

cp ./shop_api_fixtures/moo.json ./kafka-connect/data/shop_api_stage
ls ./kafka-connect/data/shop_api_stage
ls ./kafka-connect/data/shop_api_error

# http://192.168.100.225:8070/ui/clusters/stage/all-topics/goods-raw
# видим 6 сообщений: работает kafka-connect, работает kafka-ui

# Mirror Maker 1
# пишем что угодно в топик goods-filtered на stage-кластере,
# видим то же на mart-кластере (через UI)
# (проверил)

# ну посмотрим ещё наличие схемы по REST API в schema-registry
ENV_FILE="./.env.example"
set -a
source $ENV_FILE
set +a
curl -s \
  --request GET \
  --url 'https://localhost:8081/schemas' \
  --user producer:prod_pass \
  --header 'Accept: application/vnd.schemaregistry.v1+json' \
  --cacert <(keytool -exportcert -rfc -keystore "./etc-kafka-secrets/kafka.truststore.jks" -storepass "${KAFKA_TRUSTSTORE_CREDS}" -alias "${KAFKA_TRUSTSTORE_ROOT_CA_ALIAS}") \
  --cert-type P12 \
  --cert "./etc-kafka-secrets/kafka.keystore.pkcs12:${KAFKA_KEYSTORE_CREDS}" \
| jq
[
  {
    "subject": "goods-filtered-value",
    "version": 1,
    "id": 1,
    "schema": "{\"type\":\"record\",\"name\":\"Product\",\"namespace\":\"com.shop.inventory\",\"fields\":[{\"name\":\"product_id\",\"type\":\"string\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"price\",\"type\":{\"type\":\"record\",\"name\":\"Price\",\"fields\":[{\"name\":\"amount\",\"type\":\"double\"},{\"name\":\"currency\",\"type\":\"string\"}]}},{\"name\":\"stock\",\"type\":{\"type\":\"record\",\"name\":\"Stock\",\"fields\":[{\"name\":\"available\",\"type\":\"int\"},{\"name\":\"reserved\",\"type\":\"int\"}]}},{\"name\":\"sku\",\"type\":\"string\"},{\"name\":\"store_id\",\"type\":\"string\"},{\"name\":\"created_at\",\"type\":\"string\"},{\"name\":\"updated_at\",\"type\":\"string\"},{\"name\":\"description\",\"type\":[\"null\",\"string\"],\"default\":null},{\"name\":\"category\",\"type\":[\"null\",\"string\"],\"default\":null},{\"name\":\"brand\",\"type\":[\"null\",\"string\"],\"default\":null},{\"name\":\"tags\",\"type\":[\"null\",{\"type\":\"array\",\"items\":\"string\"}],\"default\":null},{\"name\":\"images\",\"type\":[\"null\",{\"type\":\"array\",\"items\":{\"type\":\"record\",\"name\":\"Image\",\"fields\":[{\"name\":\"url\",\"type\":\"string\"},{\"name\":\"alt\",\"type\":\"string\"}]}}],\"default\":null},{\"name\":\"specifications\",\"type\":[\"null\",{\"type\":\"map\",\"values\":\"string\"}],\"default\":null},{\"name\":\"index\",\"type\":[\"null\",\"string\"],\"default\":null}]}"
  },
  {
    "subject": "goods-prohibited-value",
    "version": 1,
    "id": 1,
    "schema": "{\"type\":\"record\",\"name\":\"Product\",\"namespace\":\"com.shop.inventory\",\"fields\":[{\"name\":\"product_id\",\"type\":\"string\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"price\",\"type\":{\"type\":\"record\",\"name\":\"Price\",\"fields\":[{\"name\":\"amount\",\"type\":\"double\"},{\"name\":\"currency\",\"type\":\"string\"}]}},{\"name\":\"stock\",\"type\":{\"type\":\"record\",\"name\":\"Stock\",\"fields\":[{\"name\":\"available\",\"type\":\"int\"},{\"name\":\"reserved\",\"type\":\"int\"}]}},{\"name\":\"sku\",\"type\":\"string\"},{\"name\":\"store_id\",\"type\":\"string\"},{\"name\":\"created_at\",\"type\":\"string\"},{\"name\":\"updated_at\",\"type\":\"string\"},{\"name\":\"description\",\"type\":[\"null\",\"string\"],\"default\":null},{\"name\":\"category\",\"type\":[\"null\",\"string\"],\"default\":null},{\"name\":\"brand\",\"type\":[\"null\",\"string\"],\"default\":null},{\"name\":\"tags\",\"type\":[\"null\",{\"type\":\"array\",\"items\":\"string\"}],\"default\":null},{\"name\":\"images\",\"type\":[\"null\",{\"type\":\"array\",\"items\":{\"type\":\"record\",\"name\":\"Image\",\"fields\":[{\"name\":\"url\",\"type\":\"string\"},{\"name\":\"alt\",\"type\":\"string\"}]}}],\"default\":null},{\"name\":\"specifications\",\"type\":[\"null\",{\"type\":\"map\",\"values\":\"string\"}],\"default\":null},{\"name\":\"index\",\"type\":[\"null\",\"string\"],\"default\":null}]}"
  }
]
```

Всё работает, можно делать Faust-приложение.
