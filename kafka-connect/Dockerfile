ARG IMAGE_KAFKA_CONNECT=confluentinc/cp-kafka-connect:7.9.5

FROM ${IMAGE_KAFKA_CONNECT}

USER root
RUN mkdir -p /usr/share/confluent-hub-components/kafka-connect-spooldir
COPY ./plugins/kafka-connect-spooldir/ /usr/share/confluent-hub-components/kafka-connect-spooldir/
USER appuser
