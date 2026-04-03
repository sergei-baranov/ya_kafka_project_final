ARG IMAGE_SPARK=docker.io/bitnamilegacy/spark:3.5.3

FROM ${IMAGE_SPARK}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl gosu \
    && rm -rf /var/lib/apt/lists/*

RUN /opt/bitnami/python/bin/pip install --no-cache-dir "kafka-python>=2.0,<3" "fastavro>=1.9" "requests>=2.31"

# spark-submit (Ivy → FileSystem.get) дергает UnixLoginModule для UID процесса — без passwd для 1001: UnixPrincipal(null)
RUN set -eux; \
  name="$(awk -F: '$3==1001 {print $1; exit}' /etc/passwd)"; \
  if [ -z "${name:-}" ]; then \
    echo 'spark:x:1001:1001:spark:/tmp/spark-user:/bin/bash' >> /etc/passwd; \
  fi

COPY entrypoint.sh /opt/bitnami/spark/work/entrypoint.sh
COPY recommendations_job.py /opt/bitnami/spark/work/recommendations_job.py
RUN chmod 755 /opt/bitnami/spark/work/entrypoint.sh

# entrypoint стартует от root: chown тома checkpoint + PEM, затем gosu 1001 → spark-submit
USER root
ENTRYPOINT ["/opt/bitnami/spark/work/entrypoint.sh"]
