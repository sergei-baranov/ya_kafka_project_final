#!/bin/bash

mkdir tmp
cd ./tmp

env $(sed 's/#.*//g; /^\s*$/d' ../.env.example | xargs) envsubst < ../kafka.cnf.template > kafka.cnf

openssl req -new -nodes -x509 -days 365 -newkey rsa:2048 \
-keyout ca.key -out ca.crt -config ../ca.cnf

keytool -import \
    -file ca.crt \
    -alias ca \
    -keystore kafka.truststore.jks \
    -storepass my-truststore-password \
    -noprompt

openssl req -new \
    -newkey rsa:2048 \
    -keyout kafka.key \
    -out kafka.csr \
    -config kafka.cnf \
    -nodes

openssl x509 -req \
    -days 3650 \
    -in kafka.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out kafka.crt \
    -extfile kafka.cnf \
    -extensions v3_req

cat ca.crt ca.key > ca.pem

openssl pkcs12 -export \
    -in kafka.crt \
    -inkey kafka.key \
    -chain \
    -CAfile ca.pem \
    -name kafka \
    -out kafka.p12 \
    -password pass:my-keystore-password

keytool -importkeystore \
    -deststorepass my-keystore-password \
    -destkeystore kafka.keystore.pkcs12 \
    -srckeystore kafka.p12 \
    -deststoretype PKCS12  \
    -srcstoretype PKCS12 \
    -noprompt \
    -srcstorepass my-keystore-password

cp ./kafka.keystore.pkcs12 ../etc-kafka-secrets/

cp ./kafka.truststore.jks ../etc-kafka-secrets/

cd ..
rm -R ./tmp
