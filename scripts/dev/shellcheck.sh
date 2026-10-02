#!/usr/bin/env bash
# Runs shellcheck on every shell script in the repository, including the
# ones without a file extension.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# The files that `philomena.sh` sources are checked through it, where the
# variables and functions they share are known.
files=$(
  {
    git ls-files --cached --others --exclude-standard '*.sh'
    git grep --untracked --files-with-matches -E '^#!/(usr/)?bin/(env )?(ba)?sh'
  } | sort -u | xargs grep -L 'meant to be sourced by'
)

# shellcheck disable=SC2086
shellcheck --external-sources --source-path SCRIPTDIR --source-path . $files
