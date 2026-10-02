#!/usr/bin/env bash
# Points this repository at a release of Philomena.
#
# Usage: scripts/dev/bump-philomena.sh <version>
#
# The application, web server and media processor images are always used at
# the same version, so the default tag of all of them is replaced.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

version=${1:-}

if [[ ! $version =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "Usage: scripts/dev/bump-philomena.sh <version>" >&2
  exit 1
fi

for image in philomena philomena-web mediaproc; do
  if ! docker manifest inspect "ghcr.io/philomena-dev/$image:$version" > /dev/null 2>&1; then
    echo "ghcr.io/philomena-dev/$image:$version does not exist." >&2
    exit 1
  fi
done

sed -i.bak -E "s/(\$\{PHILOMENA_VERSION:-)[^}]+\}/\1$version}/" docker-compose.yml
rm -f docker-compose.yml.bak

echo "docker-compose.yml now defaults to Philomena $version:"
grep -n 'PHILOMENA_VERSION' docker-compose.yml
