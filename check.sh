#!/bin/bash

function check_if_set() {
    VAR=$(printenv "$1")

    if [ -z "$VAR" ]; then
        echo "Error: $1 is not set in the environment."
        MISSING_VARS=true
    fi
}

function check_if_changeme() {
    VAR=$(printenv "$1")

    if [ "$VAR" = "CHANGE_THIS" ]; then
        echo "Error: $1 is set to CHANGE_THIS, please update it."
        MISSING_VARS=true
    fi
}

function run_checks() {
    if [ ! -f "$1" ]; then
        echo "Error: $1 file not found."
        echo "Please run 'prepare.sh' first to create the .env files."
        exit 1
    fi

    export $(cat $1 | xargs)

    echo "Checking $1 for required environment variables..."

    check_if_set "DATABASE_URL"
    check_if_set "APP_ORIGIN"
    check_if_set "IMAGE_URL_ROOT"
    check_if_set "AVATAR_URL_ROOT"
    check_if_set "ADVERT_URL_ROOT"
    check_if_set "BADGE_URL_ROOT"
    check_if_set "TAG_URL_ROOT"
    check_if_set "CHANNEL_URL_ROOT"
    check_if_set "ANONYMOUS_NAME_SALT"
    check_if_set "PASSWORD_PEPPER"
    check_if_set "OTP_SECRET_KEY"
    check_if_set "SECRET_KEY_BASE"
    check_if_set "CAMO_KEY"
    check_if_set "SMTP_RELAY"
    check_if_set "SMTP_PASSWORD"
    check_if_set "TUMBLR_API_KEY"
    check_if_set "HCAPTCHA_SITE_KEY"
    check_if_set "HCAPTCHA_SECRET_KEY"
    check_if_set "S3_SCHEME"
    check_if_set "S3_HOST"
    check_if_set "S3_PORT"
    check_if_set "S3_BUCKET"
    check_if_set "AWS_ACCESS_KEY_ID"
    check_if_set "AWS_SECRET_ACCESS_KEY"
    check_if_set "REDIS_HOST"
    check_if_set "OPENSEARCH_URL"
    check_if_set "MEDIAPROC_ADDR"
    check_if_set "ADVERT_FILE_ROOT"
    check_if_set "AVATAR_FILE_ROOT"
    check_if_set "BADGE_FILE_ROOT"
    check_if_set "TAG_FILE_ROOT"
    check_if_set "IMAGE_FILE_ROOT"
    check_if_set "CAMO_HOST"
    check_if_set "CDN_HOST"
    check_if_set "APP_IP"
    check_if_set "PORT"
    check_if_set "APP_ADDRESS"
    check_if_set "SITE_DOMAIN"
    check_if_set "CDN_DOMAIN"
    check_if_set "APP_URL"
    check_if_set "CDN_URL"
    check_if_set "PROXY_HOST"
    check_if_set "PGDATABASE"
    check_if_set "PGHOST"
    check_if_set "PGUSER"
    check_if_set "NODENAME"
    check_if_set "RELEASE_NODE"
    check_if_set "SMTP_DOMAIN"
    check_if_set "SMTP_USERNAME"
    check_if_set "MAILER_ADDRESS"
    check_if_changeme "SMTP_RELAY"
    check_if_changeme "SMTP_PASSWORD"
    check_if_changeme "TUMBLR_API_KEY"
    check_if_changeme "HCAPTCHA_SITE_KEY"
    check_if_changeme "HCAPTCHA_SECRET_KEY"
    check_if_changeme "S3_REGION"
    check_if_changeme "S3_SCHEME"
    check_if_changeme "S3_HOST"
    check_if_changeme "S3_PORT"
    check_if_changeme "S3_BUCKET"
    check_if_changeme "AWS_ACCESS_KEY_ID"
    check_if_changeme "AWS_SECRET_ACCESS_KEY"
    check_if_changeme "ALT_S3_REGION"
    check_if_changeme "ALT_S3_SCHEME"
    check_if_changeme "ALT_S3_HOST"
    check_if_changeme "ALT_S3_PORT"
    check_if_changeme "ALT_S3_BUCKET"
    check_if_changeme "ALT_AWS_ACCESS_KEY_ID"
    check_if_changeme "ALT_AWS_SECRET_ACCESS_KEY"
}

run_checks ".env"
run_checks ".env-web"

echo "=============================="
echo "Configuration status:"

if [ "$MISSING_VARS" = true ]; then
    echo "FAIL!"
    echo "One or more of the required environment variables are missing. Please open the .env and .env-web files and fill in the missing values."
    echo "=============================="
    exit 1
else
    echo "PASS!"
    echo "=============================="
fi
