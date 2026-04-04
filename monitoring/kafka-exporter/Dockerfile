FROM eclipse-temurin:21-jre-alpine

RUN apk add --no-cache bash openssl curl ca-certificates \
    && curl -fsSL "https://github.com/danielqsj/kafka_exporter/releases/download/v1.9.0/kafka_exporter-1.9.0.linux-amd64.tar.gz" \
    | tar -xz -C /tmp \
    && mv /tmp/kafka_exporter-1.9.0.linux-amd64/kafka_exporter /usr/local/bin/kafka_exporter \
    && rm -rf /tmp/kafka_exporter-1.9.0.linux-amd64

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9308
ENTRYPOINT ["/entrypoint.sh"]
