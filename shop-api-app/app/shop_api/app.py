import warnings

warnings.simplefilter("ignore", UserWarning)

import os
import ssl
import subprocess
import tempfile

import faust
import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import pkcs12
from fastavro import parse_schema, schemaless_writer, validate
from faust.auth import SASLCredentials

SCHEMA_REGISTRY_URL = os.getenv(
    'SCHEMA_REGISTRY_REST_URL_INNER', 'https://schema-registry:8081')

JKS_PATH = os.getenv('CONTAINER_PATH_TRUSTSTORE')
P12_PATH = os.getenv('CONTAINER_PATH_KEYSTORE')
TRUSTSTORE_PASS = os.getenv('KAFKA_TRUSTSTORE_CREDS')
KEYSTORE_PASS = os.getenv('KAFKA_KEYSTORE_CREDS')
CA_ALIAS = os.getenv('KAFKA_TRUSTSTORE_ROOT_CA_ALIAS', 'ca')

SASL_USERNAME = os.getenv('SASL_UNAME_SHOP_API')
SASL_PASSWORD = os.getenv('SASL_PWD_SHOP_API')
# Error: ValueError('3.9.0'), то же с 3.0.0
# видимо жёстко зашиты версии, актуальные на момент релиза
KAFKA_API_VERSION = '2.5.0'  # os.getenv('KAFKA_VERSION_STR')

SB_HOSTS = []
for i in range(1, 4):
    name = os.getenv(f'SB_{i}_NAME')
    port = os.getenv(f'SB_{i}_PORT_92')
    if name and port:
        SB_HOSTS.append(f'{name}:{port}')
if not SB_HOSTS:
    raise RuntimeError(
        "CRITICAL: No bootstrap servers found in environment variables!"
    )

# Соответствие RF кластера (у Faust по умолчанию 1 — на стенде с RF=3
# это ломает CreateTopics/metadata).
FAUST_TOPIC_RF = int(os.getenv('TOPIC_REPLICATION_FACTOR', '3'))
# Число партиций для внутренних топиков Faust (repartition, changelog таблиц).
# Должно совпадать с предсозданием changelog в setup-acls-stage.sh.
FAUST_TOPIC_PARTITIONS = int(os.getenv('FAUST_TOPIC_PARTITIONS', '8'))
# Фиксированный reply_to из env (TOPIC_FAUST_REPLY): один топик для ask(),
# совпадает с предсозданием в setup-acls-stage.sh.
FAUST_REPLY_TOPIC = os.getenv('TOPIC_FAUST_REPLY', '').strip()


def get_ca_pem(jks_path, password, alias):
    # Keytool, т.к. cryptography не читает JKS
    cmd = [
        "keytool",
        "-exportcert",
        "-rfc",
        "-keystore",
        jks_path,
        "-storepass",
        password,
        "-alias",
        alias,
        "-noprompt"
    ]
    return subprocess.run(
        cmd, capture_output=True, check=True, text=True
    ).stdout.encode()


def get_client_pem(p12_path, password):
    with open(p12_path, "rb") as f:
        # cryptography для PKCS12
        p_key, cert, _ = pkcs12.load_key_and_certificates(
            f.read(), password.encode())

    key_pem = p_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption()
    )
    cert_pem = cert.public_bytes(serialization.Encoding.PEM)
    return key_pem, cert_pem


ca_data = get_ca_pem(JKS_PATH, TRUSTSTORE_PASS, CA_ALIAS)
key_data, cert_data = get_client_pem(P12_PATH, KEYSTORE_PASS)


def create_tmp_file(data):
    f = tempfile.NamedTemporaryFile(delete=False)
    f.write(data)
    f.close()
    return f.name


ca_f_path = create_tmp_file(ca_data)
key_f_path = create_tmp_file(key_data)
cert_f_path = create_tmp_file(cert_data)

# строка с запятыми: иначе yarl/url теряют нестандартные порты
broker_url = ",".join([f"kafka://{host}" for host in SB_HOSTS])

ssl_ctx = ssl.create_default_context(cafile=ca_f_path)
ssl_ctx.load_cert_chain(certfile=cert_f_path, keyfile=key_f_path)
ssl_ctx.check_hostname = True
ssl_ctx.verify_mode = ssl.CERT_REQUIRED

# Брокер: SASL_SSL (mTLS + PLAIN).
# Для aiokafka Faust собирает параметры из SASLCredentials,
# а не из сырого SSLContext и не из ключей вида sasl.username
# (это не kwargs aiokafka).
_app_kwargs = dict(
    broker=broker_url,
    broker_credentials=SASLCredentials(
        username=SASL_USERNAME,
        password=SASL_PASSWORD,
        ssl_context=ssl_ctx,
    ),
    ssl_context=ssl_ctx,
    broker_options={
        'api_version': KAFKA_API_VERSION,
    },
    consumer_api_version=KAFKA_API_VERSION,
    producer_api_version=KAFKA_API_VERSION,
    topic_replication_factor=FAUST_TOPIC_RF,
    topic_partitions=FAUST_TOPIC_PARTITIONS,
    store='rocksdb://',
    autodiscover=True,
    origin='shop_api',
    web_bind='0.0.0.0',
    web_port=int(os.getenv('SHOP_API_WEB_PORT', '6077')),
    # processing_guarantee='exactly_once',
)
if FAUST_REPLY_TOPIC:
    _app_kwargs['reply_to'] = FAUST_REPLY_TOPIC

app = faust.App('shop_api_app', **_app_kwargs)

SSL_CONFIG = {
    'ca': ca_f_path,
    'cert': cert_f_path,
    'key': key_f_path,
    'url': os.getenv(
        'SCHEMA_REGISTRY_REST_URL_INNER', 'https://schema-registry:8081')
}

from . import pages  # noqa: E402,F401 — регистрация /metrics и HTTP view
