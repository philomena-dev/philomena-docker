#!/bin/sh
# Renders an nginx configuration template and starts OpenResty.
#
# Usage: entrypoint.sh <template> <variable>...
#
# Every ${VARIABLE} named on the command line is replaced with its value
# from the environment. A variable that is not set is an error, so a
# misconfigured container fails immediately instead of serving a broken
# configuration.

set -eu

template=$1
shift

output=/usr/local/openresty/nginx/conf/nginx.conf
script=

for name in "$@"; do
  if ! value=$(printenv "$name") || [ -z "$value" ]; then
    echo "entrypoint: $name is not set" >&2
    exit 1
  fi

  # Escape the characters that are special in a sed replacement.
  value=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')
  script="${script}s|\${$name}|$value|g
"
done

sed -e "$script" "$template" > "$output"

exec /usr/local/openresty/bin/openresty -g 'daemon off;'
