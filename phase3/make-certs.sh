#!/bin/bash

ENV_FILE="${1:-./.env.example}"

echo "source env ${ENV_FILE}"
set -a
source $ENV_FILE
set +a

echo "going to tmp dir"

mkdir tmp
cd ./tmp

echo "kafka.cnf.template env replacement"
envsubst < ../kafka.cnf.template > kafka.cnf
# env $(sed 's/#.*//g; /^\s*$/d' $ENV_FILE | xargs) envsubst < ../kafka.cnf.template > kafka.cnf

cat kafka.cnf

echo "make ca.key, ca.crt"

openssl req -new -nodes -x509 -days 365 -newkey rsa:2048 \
-keyout ca.key -out ca.crt -config ../ca.cnf

echo "make kafka.truststore.jks"

keytool -import \
    -file ca.crt \
    -alias ca \
    -keystore kafka.truststore.jks \
    -storepass my-truststore-password \
    -noprompt

echo "make kafka.key, kafka.csr"

openssl req -new \
    -newkey rsa:2048 \
    -keyout kafka.key \
    -out kafka.csr \
    -config kafka.cnf \
    -nodes

echo "make kafka.crt"

openssl x509 -req \
    -days 3650 \
    -in kafka.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out kafka.crt \
    -extfile kafka.cnf \
    -extensions v3_req

echo "make ca.pem"

cat ca.crt ca.key > ca.pem

echo "make kafka.p12"

openssl pkcs12 -export \
    -in kafka.crt \
    -inkey kafka.key \
    -chain \
    -CAfile ca.pem \
    -name kafka \
    -out kafka.p12 \
    -password pass:my-keystore-password

echo "make kafka.keystore.pkcs12"

keytool -importkeystore \
    -deststorepass my-keystore-password \
    -destkeystore kafka.keystore.pkcs12 \
    -srckeystore kafka.p12 \
    -deststoretype PKCS12  \
    -srcstoretype PKCS12 \
    -noprompt \
    -srcstorepass my-keystore-password

echo "copy keystore and truststore to the etc-kafka-secrets"

cp ./kafka.keystore.pkcs12 ../etc-kafka-secrets/
cp ./kafka.truststore.jks ../etc-kafka-secrets/

echo "remove tmp dir"

cd ..
rm -R ./tmp
