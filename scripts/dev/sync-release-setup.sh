#!/usr/bin/env bash
# Copies `setup-production` and the release migrations from a checkout of
# Philomena into compat/release-setup, which is what images that were built
# without them are given instead.
#
# Usage: scripts/dev/sync-release-setup.sh <path to a Philomena checkout>

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

source=${1:-}

if [[ ! -f $source/docker/production/setup-production || ! -d $source/priv/release-migrations ]]; then
  echo "Usage: scripts/dev/sync-release-setup.sh <path to a Philomena checkout>" >&2
  exit 1
fi

rm -rf compat/release-setup
mkdir -p compat/release-setup

cp "$source/docker/production/setup-production" compat/release-setup/
cp -R "$source/priv/release-migrations" compat/release-setup/

git status --short compat
