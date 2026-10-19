#!/usr/bin/env bash
# Regenerates config/caddy/realip/cloudflare.caddy from the address ranges
# Cloudflare publishes. Run it when Cloudflare announces a change; the CI
# workflow fails when the checked-in file is out of date.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ranges=$(
  curl --fail --silent --show-error --location --retry 5 https://www.cloudflare.com/ips-v4
  echo
  curl --fail --silent --show-error --location --retry 5 https://www.cloudflare.com/ips-v6
)

{
  cat << 'HEADER'
# Selected with CLIENT_IP_SOURCE=cloudflare in .env.
#
# For a site behind Cloudflare: connections that arrive from Cloudflare's
# network carry the visitor's address in the CF-Connecting-IP header.
# Connections from anywhere else are taken at face value, so the header
# cannot be used to fake an address.
#
# The ranges below come from https://www.cloudflare.com/ips-v4 and
# https://www.cloudflare.com/ips-v6; `scripts/dev/update-cloudflare-ips.sh`
# regenerates this file.

HEADER

  printf 'trusted_proxies static'

  for range in $ranges; do
    printf ' %s' "$range"
  done

  echo
  echo "client_ip_headers CF-Connecting-IP"
} > config/caddy/realip/cloudflare.caddy
