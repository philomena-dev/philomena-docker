#!/bin/bash

if [ -f .env ] || [ -f .env-web ]; then
    echo "ERROR: .env or .env-web already exists. Overwriting existing files may cause catastrophic data loss. Save a copy and delete before re-running this script."
    exit 1
fi

export SECRET_KEY_BASE=$(openssl rand -hex 128)
export ANONYMOUS_NAME_SALT=$(openssl rand -hex 128)
export PASSWORD_PEPPER=$(openssl rand -hex 128)
export OTP_SECRET_KEY=$(openssl rand -hex 128)
export CAMO_KEY=$(openssl rand -hex 64)

read -p "Use HTTPS? (default: yes): " USE_HTTPS

if [ -z "$USE_HTTPS" ]; then
  read -p "SSL certificate path (folder containing fullchain.pem and privkey.pem): " SSL_CERT_PATH

  if [ -z "$SSL_CERT_PATH" ]; then
    echo "SSL certificate path cannot be empty when HTTPS is enabled."
    exit 1
  fi

  export SSL_CERT_PATH=${SSL_CERT_PATH%/}
fi

read -p "Enter site domain (default: philomena.local): " SITE_DOMAIN
read -p "Enter CDN domain (default: cdn.philomena.local): " CDN_DOMAIN
read -p "Enter external content domain (default: ext.philomena.local): " EXT_DOMAIN

export SITE_DOMAIN=${SITE_DOMAIN:-philomena.local}
export CDN_DOMAIN=${CDN_DOMAIN:-cdn.philomena.local}
export EXT_DOMAIN=${EXT_DOMAIN:-ext.philomena.local}

if [ "$USE_HTTPS" = "no" ] || [ "$USE_HTTPS" = "n" ]; then
  export PROTOCOL="http"

  envsubst '$SITE_DOMAIN $CDN_DOMAIN $EXT_DOMAIN $SSL_CERT_PATH' < templates/nginx.conf > nginx.conf
else
  export PROTOCOL="https"

  envsubst '$SITE_DOMAIN $CDN_DOMAIN $EXT_DOMAIN $SSL_CERT_PATH' < templates/nginx-ssl.conf > nginx.conf
fi

export SITE_ORIGIN="$PROTOCOL://$SITE_DOMAIN"

envsubst < templates/.env > .env
envsubst < templates/.env-web > .env-web

mkdir ./volumes/opensearch
chmod -R 0777 ./volumes/opensearch

echo "==============================="
echo "Created .env and .env-web files, please open them and fill in any remaining values (marked as CHANGE_THIS)."
echo "Note: the .env-web should have read-only credentials for S3."
echo "When finished, you can use the 'check.sh' script to verify your configuration."
echo "This script also created the nginx configuration file. You don't need to edit it manually unless you have special requirements."
echo "==============================="
