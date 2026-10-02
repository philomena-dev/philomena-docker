#!/usr/bin/env bash
# Installs a single-server deployment in this checkout and exercises it end
# to end: install, serve, back up, update, restore. Used by the CI workflow;
# it needs ports 80 and 443, and leaves nothing running.
#
# Do not run this in a checkout that holds a real deployment.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if [[ -e .env ]]; then
  echo "This checkout already has a .env file, refusing to touch it." >&2
  exit 1
fi

site=philomena.test
cdn=cdn.philomena.test
ext=ext.philomena.test
resolve=(--resolve "$site:443:127.0.0.1" --resolve "$cdn:443:127.0.0.1" --resolve "$ext:443:127.0.0.1")

function cleanup {
  local status=$?

  if [[ $status -ne 0 ]]; then
    docker compose ps --all || true
    docker compose logs --tail 80 || true
  fi

  docker compose down --volumes --remove-orphans || true
  exit "$status"
}

trap cleanup EXIT

# Print the status code of a request.
function status_of {
  curl --silent --insecure "${resolve[@]}" --output /dev/null --write-out '%{http_code}' "$@"
}

function expect {
  local expected=$1 description=$2 actual
  shift 2
  actual=$(status_of "$@")

  if [[ $actual != "$expected" ]]; then
    echo "FAIL: $description: expected $expected, got $actual" >&2
    exit 1
  fi

  echo "ok: $description"
}

function set_env {
  sed -i.bak -E "s|^$1=.*|$1=$2|" .env
  rm -f .env.bak
}

echo "== prepare"

ROLE=single STORAGE=local \
  SITE_DOMAIN=$site CDN_DOMAIN=$cdn EXT_DOMAIN=$ext \
  ADMIN_USERNAME=Administrator ADMIN_EMAIL=admin@$site \
  ./philomena.sh prepare < /dev/null

if ./philomena.sh check; then
  echo "FAIL: check passed with settings that still read CHANGE_THIS" >&2
  exit 1
fi

set_env SMTP_RELAY mail.$site
set_env SMTP_USERNAME noreply@$site
set_env SMTP_PASSWORD unused
set_env TUMBLR_API_KEY unused
# hCaptcha's published test keys, which accept every answer.
set_env HCAPTCHA_SITE_KEY 10000000-ffff-ffff-ffff-000000000001
set_env HCAPTCHA_SECRET_KEY 0x0000000000000000000000000000000000000000
set_env OPENSEARCH_HEAP 1g

echo "== setup"

./philomena.sh setup < /dev/null

echo "== serve"

expect 200 "front page" "https://$site/"
expect 200 "search" "https://$site/search?q=safe"
expect 200 "API" "https://$site/api/v1/json/search/images?q=*"
expect 200 "static asset" "https://$site/favicon.ico"
expect 301 "redirect to HTTPS" --resolve "$site:80:127.0.0.1" "http://$site/"
expect 403 "image proxy rejects unsigned URLs" "https://$ext/abc/def"
expect 404 "missing file on the CDN" "https://$cdn/img/2020/1/1/1/full.png"

# A file stored through the application has to come back out through the CDN.
docker compose exec -T app sh -c "
  printf 'smoke test' > /tmp/smoke.png
  philomena eval 'Application.ensure_all_started(:philomena); :ok = PhilomenaMedia.Objects.put(\"images/2024/1/2/3/full.png\", \"/tmp/smoke.png\")'
"

expect 200 "stored file on the CDN" "https://$cdn/img/2024/1/2/3/full.png"
expect 200 "stored file by its view URL" "https://$cdn/img/view/2024/1/2/3__safe.png"
expect 206 "partial request" --header 'Range: bytes=0-4' "https://$cdn/img/2024/1/2/3/full.png"

if [[ $(curl --silent --insecure "${resolve[@]}" "https://$cdn/img/2024/1/2/3/full.png") != 'smoke test' ]]; then
  echo "FAIL: the CDN returned different contents than were stored" >&2
  exit 1
fi

# The address of the visitor has to arrive at the application's web server,
# and headers sent by the visitor must not be able to replace it.
curl --silent --insecure "${resolve[@]}" --output /dev/null \
  --header 'X-Forwarded-For: 203.0.113.99' --header 'CF-Connecting-IP: 203.0.113.99' \
  "https://$site/tags?smoke-test"
sleep 2

gateway=$(docker compose exec -T web sh -c "ip route | awk '/default/ { print \$3 }'")
client_ip=$(docker compose exec -T caddy grep 'smoke-test' /var/log/caddy/access.log |
  tail -n 1 | sed -E 's/.*"client_ip":"([^"]+)".*/\1/')

if [[ $client_ip != "$gateway" ]]; then
  echo "FAIL: the application saw the visitor as $client_ip, expected $gateway" >&2
  exit 1
fi

echo "ok: visitor address"

echo "== backup"

./philomena.sh backup
backup=$(find backups -name 'database_*.pgdump' | sort | tail -n 1)
[[ -s $backup ]]

echo "== update"

./philomena.sh update --yes --no-pull < /dev/null
expect 200 "front page after update" "https://$site/"

echo "== restore"

./philomena.sh restore --yes "$backup" < /dev/null
expect 200 "front page after restore" "https://$site/"

./philomena.sh status

echo "== all good"
