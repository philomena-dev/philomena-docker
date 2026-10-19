#!/usr/bin/env bash
# Builds the Caddy image and validates every combination of the Caddy
# configurations in config/caddy, with throwaway certificates.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

image=philomena-docker-caddy:validate
certs=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$certs'" EXIT

docker build --quiet --tag "$image" images/caddy > /dev/null

function self_signed {
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$1" \
    -addext "subjectAltName=DNS:$1" -keyout "$2-key.pem" -out "$2.pem" 2> /dev/null
}

mkdir "$certs/internal"
self_signed philomena.test "$certs/public"
mv "$certs/public.pem" "$certs/fullchain.pem"
mv "$certs/public-key.pem" "$certs/privkey.pem"
self_signed origin.internal "$certs/internal/origin"
self_signed edge.internal "$certs/internal/edge"
cp "$certs/internal/origin.pem" "$certs/internal/ca.pem"
chmod -R a+rX "$certs"

function validate {
  local description=$1 config=$2
  shift 2

  if ! output=$(docker run --rm \
    -v "$PWD/config/caddy:/etc/philomena:ro" \
    -v "$certs:/etc/philomena-certs:ro" \
    -e SITE_DOMAIN=philomena.test \
    -e CDN_DOMAIN=cdn.philomena.test \
    -e EXT_DOMAIN=ext.philomena.test \
    -e ORIGIN_URL=http://caddy:80 \
    -e CDN_SOURCE=storage \
    -e CDN_CACHE_SIZE=1g \
    -e CDN_CACHE_MEMORY=64m \
    -e CLIENT_IP_SOURCE=direct \
    -e EDGE_LINK=none \
    -e S3_ENDPOINT=http://files:80 \
    -e S3_REGION=auto \
    -e S3_BUCKET=philomena \
    -e AWS_ACCESS_KEY_ID=test \
    -e AWS_SECRET_ACCESS_KEY=test \
    -e PROXY_SERVER=proxy.test \
    -e SCRAPER_LINK_PORT=3129 \
    "$@" "$image" caddy validate --config "/etc/philomena/$config" --adapter caddyfile 2>&1); then
    echo "$output" >&2
    echo "FAIL: $description" >&2
    exit 1
  fi

  echo "ok: $description"
}

validate "single server" edge.Caddyfile
validate "single server behind Cloudflare" edge.Caddyfile -e CLIENT_IP_SOURCE=cloudflare
validate "proxy server" edge.Caddyfile -e EDGE_LINK=proxy -e ORIGIN_URL=https://app.test:8443
validate "proxy server, files on the app server" edge.Caddyfile \
  -e EDGE_LINK=proxy -e ORIGIN_URL=https://app.test:8443 -e CDN_SOURCE=origin
validate "app server" link.Caddyfile
