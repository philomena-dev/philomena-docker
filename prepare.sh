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

read -p "Enter site domain (default: philomena.local): " SITE_DOMAIN
read -p "Enter CDN domain (default: cdn.philomena.local): " CDN_DOMAIN
read -p "Enter external content domain (default: ext.philomena.local): " EXT_DOMAIN

export SITE_DOMAIN=${SITE_DOMAIN:-philomena.local}
export CDN_DOMAIN=${CDN_DOMAIN:-cdn.philomena.local}
export EXT_DOMAIN=${EXT_DOMAIN:-ext.philomena.local}
export SITE_ORIGIN="https://$SITE_DOMAIN"

read -p "Use a self-signed SSL certificate? (default: yes): " USE_SELF_SIGNED_CERT

if [ "$USE_SELF_SIGNED_CERT" = "no" ] || [ "$USE_SELF_SIGNED_CERT" = "n" ]; then
  read -p "SSL certificate path (folder containing fullchain.pem and privkey.pem): " SSL_CERT_PATH

  if [ -z "$SSL_CERT_PATH" ]; then
    echo "SSL certificate path cannot be empty."
    exit 1
  fi

  echo "Note: You will have to run 'copy-certificate.sh' again when the certificates are renewed."

  export SSL_CERT_PATH=${SSL_CERT_PATH%/}

  ./copy-certificate.sh
else
  ./generate-certificate.sh
fi

read -p "Enter the admin username (default: Administrator): " ADMIN_USERNAME
read -p "Enter the admin email (default: admin@example.com): " ADMIN_EMAIL

export ADMIN_USERNAME=${ADMIN_USERNAME:-Administrator}
export ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}
export ADMIN_PASSWORD=$(openssl rand -hex 16)

envsubst < templates/.env > .env
envsubst < templates/.env-web > .env-web
envsubst < templates/.admin > .admin
envsubst '$SITE_DOMAIN $CDN_DOMAIN $EXT_DOMAIN' < templates/nginx.conf > nginx.conf

mkdir ./volumes/opensearch
chmod -R 0777 ./volumes/opensearch

echo "==============================="
echo "Created .env and .env-web files, please open them and fill in any remaining values (marked as CHANGE_THIS)."
echo "Note: the .env-web should have read-only credentials for S3."
echo "When finished, you can use the 'check.sh' script to verify your configuration."
echo "This script also created the nginx configuration file. You don't need to edit it manually unless you have special requirements."
echo " "
echo "Initial Administrator Credentials:"
echo "Username: $ADMIN_USERNAME"
echo "Email: $ADMIN_EMAIL"
echo "Password: $ADMIN_PASSWORD"
echo "==============================="
