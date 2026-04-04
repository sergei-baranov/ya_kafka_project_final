ARG IMAGE_KAFKA_CONNECT=confluentinc/cp-kafka-connect:7.9.5

FROM ${IMAGE_KAFKA_CONNECT}

USER root

RUN mkdir -p /opt/jmx \
    && curl -fsSL "https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar" \
    -o /opt/jmx/jmx_prometheus_javaagent.jar

COPY ./jmx/kafka-connect-jmx.yml /opt/jmx/kafka-connect-jmx.yml

RUN mkdir -p /usr/share/confluent-hub-components/kafka-connect-spooldir
COPY ./plugins/kafka-connect-spooldir/ /usr/share/confluent-hub-components/kafka-connect-spooldir/
USER appuser
