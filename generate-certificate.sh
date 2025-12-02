#!/bin/bash

if [ -z "$SITE_DOMAIN" ]; then
  export $(cat .env | xargs)
fi

rm ./certs/*.pem
rm ./certs/*.csr
rm ./certs/*.srl
rm ./certs/*.cnf

openssl genrsa -out certs/root-ca-key.pem 4096
openssl req -x509 -new -nodes -key certs/root-ca-key.pem -days 365 -out certs/root-ca-cert.pem -outform PEM -subj "/CN=philomena-ca"
openssl genrsa -out certs/privkey.pem 4096
openssl req -new -key certs/privkey.pem -out certs/server.csr -subj "/CN=${SITE_DOMAIN}"
echo subjectAltName = IP:127.0.0.1,DNS:${SITE_DOMAIN},DNS:${CDN_DOMAIN},DNS:${EXT_DOMAIN} > certs/extfile.cnf
openssl x509 \
  -req \
  -in certs/server.csr \
  -CA certs/root-ca-cert.pem \
  -CAkey certs/root-ca-key.pem \
  -CAcreateserial \
  -out certs/fullchain.pem \
  -days 365 \
  -extfile certs/extfile.cnf
