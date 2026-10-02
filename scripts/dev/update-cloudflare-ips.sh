#!/usr/bin/env bash
# Regenerates config/nginx/realip/cloudflare.conf from the address ranges
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

  for range in $ranges; do
    echo "set_real_ip_from $range;"
  done

  echo
  echo "real_ip_header CF-Connecting-IP;"
} > config/nginx/realip/cloudflare.conf
