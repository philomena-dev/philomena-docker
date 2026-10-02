#!/usr/bin/env bash
# This file is meant to be sourced by `philomena.sh`, not executed directly.
# It contains the helper functions shared by all commands of `philomena.sh`.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root" || exit 1

# The settings file of this deployment.
env_file=.env

# Exists while an upgrade of the database has started but not finished.
incomplete_marker=.update-incomplete

# Set by the commands that accept --yes: questions are answered with yes.
assume_yes=false

# The layout of the settings file this version of the scripts understands.
# Bump it together with a migration in `migrate_config` when a release
# renames or restructures settings.
config_version=1

if [[ -t 2 ]]; then
  color_info=$'\033[32;1m' color_warn=$'\033[33;1m' color_error=$'\033[31;1m'
  color_dim=$'\033[2m' color_reset=$'\033[0m'
else
  color_info='' color_warn='' color_error='' color_dim='' color_reset=''
fi

# Log a message at the info level
function info {
  echo "${color_info}[INFO]${color_reset} $1" >&2
}

# Log a message at the warn level
function warn {
  echo "${color_warn}[WARN]${color_reset} $1" >&2
}

# Log a message at the error level
function error {
  echo "${color_error}[ERROR]${color_reset} $1" >&2
}

# Log a message at the error level and exit with a non-zero status
function die {
  error "$1"
  exit 1
}

# Log the command and execute it
function step {
  echo "${color_info}❱${color_reset} ${color_dim}$*${color_reset}" >&2
  "$@"
}

# Execute a command, showing its output only if it fails
function quiet {
  local output

  if ! output=$("$@" 2>&1); then
    error "Command failed: $*"
    echo "$output" >&2
    return 1
  fi
}

# Print the value of a key in a dotenv file, or nothing if it is missing.
# Surrounding quotes and trailing comments are removed, the same way Docker
# Compose reads the file.
function env_get {
  local key=$1 file=${2:-$env_file} line value

  [[ -f $file ]] || return 0

  line=$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 || true)
  [[ -n $line ]] || return 0

  value=${line#*=}
  value=${value%$'\r'}

  case "$value" in
    \"*\")
      value=${value#\"}
      value=${value%\"}
      ;;
    \'*\')
      value=${value#\'}
      value=${value%\'}
      ;;
    *)
      value=${value%%[[:space:]]#*}
      value=${value%"${value##*[![:space:]]}"}
      ;;
  esac

  printf '%s' "$value"
}

# Set a key in a dotenv file, replacing an existing line or appending one.
function env_set {
  local key=$1 value=$2 file=${3:-$env_file} tmp

  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
    tmp=$(mktemp "$file.XXXXXX")

    # The first line that sets the key (commented out or not) is replaced,
    # any further ones are dropped.
    KEY="$key" VALUE="$value" awk '
      $0 ~ "^[[:space:]]*#?[[:space:]]*" ENVIRON["KEY"] "=" {
        if (!done) print ENVIRON["KEY"] "=" ENVIRON["VALUE"]
        done = 1
        next
      }
      { print }
    ' "$file" > "$tmp"

    # Written in place, so that the owner and the mode of the file are kept.
    cat "$tmp" > "$file"
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# The role of this server: `single`, `app` or `proxy`.
function role {
  env_get ROLE
}

# Whether this server runs the application (as opposed to only the proxy).
function has_app {
  [[ $(role) != proxy ]]
}

# Whether this server runs the public-facing web server.
function has_edge {
  [[ $(role) != app ]]
}

function uses_local_storage {
  [[ ,$(env_get COMPOSE_PROFILES), == *,local-storage,* ]]
}

function require_config {
  [[ -f $env_file ]] || die "No $env_file file found. Run './philomena.sh prepare' first."

  case "$(role)" in
    single | app | proxy) ;;
    *) die "ROLE in $env_file must be one of: single, app, proxy." ;;
  esac

  migrate_config
}

# Bring a settings file written by an older version of this repository up to
# date. Each migration moves the file forward by one version.
function migrate_config {
  local current
  current=$(env_get CONFIG_VERSION)
  current=${current:-1}

  [[ $current =~ ^[0-9]+$ ]] || die "CONFIG_VERSION in $env_file is not a number."

  if ((current > config_version)); then
    die "$env_file was written by a newer version of this repository (settings version $current, this checkout understands $config_version). Update the checkout with 'git pull'."
  fi

  while ((current < config_version)); do
    current=$((current + 1))
    info "Updating $env_file to settings version $current"
    cp -p "$env_file" "$env_file.v$((current - 1)).bak"
    "migrate_config_to_$current"
    env_set CONFIG_VERSION "$current"
  done
}

function require_command {
  command -v "$1" > /dev/null 2>&1 || die "'$1' is required but not installed."
}

function require_docker {
  require_command docker
  docker info > /dev/null 2>&1 || die "Cannot talk to the Docker daemon. Is it running, and is $(id -un) in the 'docker' group?"
  docker compose version > /dev/null 2>&1 || die "The Docker Compose plugin is required ('docker compose')."
}

function compose {
  docker compose "$@"
}

# The image a service is configured to run (not necessarily pulled yet).
function service_image {
  compose config 2> /dev/null | awk -v service="$1" '
    $0 ~ "^  " service ":$" { inside = 1; next }
    inside && /^  [^ ]/ { inside = 0 }
    inside && /^    image: / { print $2; exit }
  '
}

# The ID of the running container of a service, or nothing.
function container_of {
  compose ps --quiet --status running "$1" 2> /dev/null | head -n 1
}

function is_running {
  [[ -n $(container_of "$1") ]]
}

# Ask a question. An answer already present in the environment is used as
# is, which makes every command usable without a terminal:
#
#   ask SITE_DOMAIN "Site domain" philomena.local
function ask {
  local name=$1 prompt=$2 default=${3:-} answer

  if [[ -n ${!name:-} ]]; then
    return 0
  fi

  if [[ -t 0 ]]; then
    read -r -p "$prompt${default:+ [$default]}: " answer
  else
    answer=
  fi

  printf -v "$name" '%s' "${answer:-$default}"
}

# Ask a yes/no question. `--yes` given to the command, or a missing
# terminal, answers with the default.
function confirm {
  local prompt=$1 default=${2:-n} answer

  if [[ $assume_yes == true ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    [[ $default == y ]]
    return
  fi

  if [[ $default == y ]]; then
    read -r -p "$prompt [Y/n]: " answer
  else
    read -r -p "$prompt [y/N]: " answer
  fi

  case "${answer:-$default}" in
    y | Y | yes | Yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Make sure only one state-changing command runs at a time. The scheduler
# and backup containers are stopped by the commands themselves; this guards
# against two operators, or an operator and a cron job.
function acquire_lock {
  local lock=.philomena.lock pid

  if ! mkdir "$lock" 2> /dev/null; then
    pid=$(cat "$lock/pid" 2> /dev/null || true)

    # `update` replaces itself with the new version of the scripts, which
    # then finds its own lock.
    if [[ $pid != "$$" ]]; then
      if [[ -n $pid ]] && kill -0 "$pid" 2> /dev/null; then
        die "Another philomena.sh command is running (PID $pid)."
      fi

      warn "Removing the lock left behind by a command that did not finish."
      rm -rf "$lock"
      mkdir "$lock"
    fi
  fi

  echo $$ > "$lock/pid"
  # shellcheck disable=SC2064
  trap "rm -rf '$repo_root/$lock'" EXIT
}

# When run by root on behalf of another user (a certificate renewal hook),
# hand the files that were written back to the owner of this directory.
function match_owner {
  if [[ $EUID -eq 0 ]]; then
    chown "$(stat -c %u:%g "$repo_root" 2> /dev/null || stat -f %u:%g "$repo_root")" "$@"
  fi
}

# Directories that are mounted into containers running as a different user.
function prepare_volumes {
  mkdir -p volumes/acme backups logs certs

  if has_app; then
    mkdir -p volumes/opensearch

    # OpenSearch runs as UID 1000 and does not fix up its data directory.
    if [[ $(stat -c %u volumes/opensearch 2> /dev/null || stat -f %u volumes/opensearch) != 1000 ]]; then
      step compose run --rm --no-deps --user root --entrypoint chown opensearch \
        -R 1000:1000 /usr/share/opensearch/data
    fi
  fi
}

# Days until a certificate expires (negative if it already has).
function cert_days_left {
  local end now
  end=$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)
  now=$(date +%s)

  # GNU date first, BSD date second.
  end=$(date -d "$end" +%s 2> /dev/null || date -j -f '%b %e %T %Y %Z' "$end" +%s)

  echo $(((end - now) / 86400))
}
