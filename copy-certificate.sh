#!/bin/bash

if [ -z "$SSL_CERT_PATH" ]; then
  export $(cat .env | xargs)
fi

cp $(readlink -f $SSL_CERT_PATH/fullchain.pem) ./certs/fullchain.pem
cp $(readlink -f $SSL_CERT_PATH/privkey.pem) ./certs/privkey.pem
