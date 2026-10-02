#!/bin/sh
# Starts Caddy with the configuration shipped in the philomena-web image.
#
# Images up to 1.3.0-rc1 do not trust the proxy in front of them, which
# makes every visitor appear to come from that proxy's address: rate limits
# are shared by everyone and the application records the wrong address.
# For those images the missing setting is added here. Images that already
# have it are started unchanged.

set -eu

config=/etc/caddy/Caddyfile

if ! grep -q trusted_proxies "$config"; then
  patched=/tmp/Caddyfile

  awk '
    { print }
    /^\tservers \{$/ { print "\t\ttrusted_proxies static private_ranges" }
  ' "$config" > "$patched"

  if ! grep -q trusted_proxies "$patched"; then
    echo "caddy-entrypoint: could not add trusted_proxies to $config" >&2
    exit 1
  fi

  config=$patched
fi

exec caddy run --config "$config" --adapter caddyfile
