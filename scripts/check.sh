#!/usr/bin/env bash
# This file is meant to be sourced by `philomena.sh`, not executed directly.
# It verifies the server and the settings before anything is started.

. scripts/cert.sh

check_failures=0
check_warnings=0

function fail {
  error "$1"
  check_failures=$((check_failures + 1))
}

function caution {
  warn "$1"
  check_warnings=$((check_warnings + 1))
}

# Compare two dotted version numbers: is $1 >= $2?
function version_at_least {
  [[ $(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1) == "$2" ]]
}

# Convert a size such as 512m or 4g to megabytes.
function megabytes {
  local size=$1

  case "$size" in
    *g) echo $((${size%g} * 1024)) ;;
    *m) echo "${size%m}" ;;
    *) echo 0 ;;
  esac
}

function file_mode {
  stat -c %a "$1" 2> /dev/null || stat -f %Lp "$1"
}

function check_host {
  local version arch memory heap free max_map_count

  version=$(docker compose version --short 2> /dev/null || echo 0)
  version=${version#v}

  if ! version_at_least "${version%%[-+]*}" 2.24.0; then
    fail "Docker Compose $version is too old, 2.24 or newer is required."
  fi

  arch=$(docker info --format '{{.Architecture}}')

  case "$arch" in
    x86_64 | amd64 | aarch64 | arm64) ;;
    *) fail "Images are only published for x86_64 and arm64, this server is $arch." ;;
  esac

  free=$(df -Pk . | awk 'NR == 2 { print int($4 / 1024 / 1024) }')

  if ((free < 20)); then
    caution "Only $free GB of disk space is free in $repo_root."
  fi

  has_app || return 0

  memory=$(($(docker info --format '{{.MemTotal}}') / 1024 / 1024))
  heap=$(megabytes "$(env_get OPENSEARCH_HEAP)")

  if ((heap > memory / 2)); then
    fail "OPENSEARCH_HEAP ($(env_get OPENSEARCH_HEAP)) is more than half of the server's memory ($((memory / 1024)) GB)."
  fi

  if ((memory < 7500)); then
    caution "This server has $((memory / 1024)) GB of memory. Expect trouble below 8 GB; 16 GB is recommended."
  fi

  if [[ -r /proc/sys/vm/max_map_count ]]; then
    max_map_count=$(< /proc/sys/vm/max_map_count)

    if ((max_map_count < 262144)); then
      fail "vm.max_map_count is $max_map_count, the search engine needs at least 262144. As root, run:
        echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-philomena.conf && sysctl --system"
    fi
  fi
}

# Every setting in the template of this role has to be present, so that a
# setting introduced by a newer version of this repository is noticed.
function check_settings_present {
  local template=$1 key value
  shift

  # The remaining arguments are the settings that may be left empty.
  local optional=" $* "

  while IFS= read -r key; do
    if ! grep -qE "^[[:space:]]*${key}=" "$env_file"; then
      fail "$key is missing from $env_file. See $template for what it is for."
      continue
    fi

    value=$(env_get "$key")

    if [[ -z $value && $optional != *" $key "* ]]; then
      fail "$key is empty."
    fi
  done < <(sed -n -E 's/^([A-Z][A-Z0-9_]*)=.*/\1/p' "$template")
}

function check_file_syntax {
  local line key value number=0 seen=' '

  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))

    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue

    if [[ ! $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      fail "$env_file line $number is not of the form KEY=value."
      continue
    fi

    key=${line%%=*}
    value=${line#*=}

    if [[ $seen == *" $key "* ]]; then
      caution "$key is set more than once in $env_file; the last value wins."
    fi

    seen+="$key "

    if [[ $value == CHANGE_THIS ]]; then
      fail "$key still reads CHANGE_THIS."
    fi

    if [[ $value != \'*\' && $value == *\$* ]]; then
      fail "The value of $key contains a \$ and has to be wrapped in 'single quotes'."
    fi
  done < "$env_file"

  if [[ $(file_mode "$env_file") != [67]00 ]]; then
    fail "$env_file is readable by other users. Run: chmod 600 $env_file"
  fi
}

function check_domains {
  local key value site cdn ext
  site=$(env_get SITE_DOMAIN)
  cdn=$(env_get CDN_DOMAIN)
  ext=$(env_get EXT_DOMAIN)

  for key in SITE_DOMAIN CDN_DOMAIN EXT_DOMAIN; do
    value=$(env_get "$key")

    if [[ -n $value && ! $value =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
      fail "$key ($value) is not a domain name. Use lower case, without a scheme or a path."
    fi
  done

  if [[ $site == "$cdn" || $site == "$ext" || $cdn == "$ext" ]]; then
    fail "SITE_DOMAIN, CDN_DOMAIN and EXT_DOMAIN have to be three different domains."
  fi
}

function check_storage {
  local key set=0 unset=0 scheme port

  scheme=$(env_get S3_SCHEME)
  port=$(env_get S3_PORT)

  if [[ -n $scheme && $scheme != http && $scheme != https ]]; then
    fail "S3_SCHEME must be http or https."
  fi

  if [[ -n $port && ! $port =~ ^[0-9]+$ ]]; then
    fail "S3_PORT must be a number."
  fi

  if has_app; then
    if uses_local_storage && [[ $(env_get S3_HOST) != files ]]; then
      fail "COMPOSE_PROFILES enables local storage, but S3_HOST is not 'files'."
    elif ! uses_local_storage && [[ $(env_get S3_HOST) == files ]]; then
      fail "S3_HOST is 'files', but COMPOSE_PROFILES does not enable local-storage."
    fi

    for key in ALT_S3_SCHEME ALT_S3_HOST ALT_S3_PORT ALT_S3_BUCKET ALT_AWS_ACCESS_KEY_ID ALT_AWS_SECRET_ACCESS_KEY; do
      if [[ -n $(env_get "$key") ]]; then
        set=$((set + 1))
      else
        unset=$((unset + 1))
      fi
    done

    if ((set > 0 && unset > 0)); then
      fail "The second bucket is only partly configured. Set all ALT_ settings or none."
    fi

    if [[ -n $(env_get WEB_AWS_ACCESS_KEY_ID) && -z $(env_get WEB_AWS_SECRET_ACCESS_KEY) ]] ||
      [[ -z $(env_get WEB_AWS_ACCESS_KEY_ID) && -n $(env_get WEB_AWS_SECRET_ACCESS_KEY) ]]; then
      fail "Set both WEB_AWS_ACCESS_KEY_ID and WEB_AWS_SECRET_ACCESS_KEY, or neither."
    fi
  fi
}

function check_settings {
  local key value expected

  check_file_syntax

  case "$(role)" in
    single | app)
      check_settings_present templates/app.env COMPOSE_PROFILES TLS_CERT_PATH

      for key in SECRET_KEY_BASE ANONYMOUS_NAME_SALT PASSWORD_PEPPER OTP_SECRET_KEY; do
        value=$(env_get "$key")

        if ((${#value} > 0 && ${#value} < 64)); then
          fail "$key is too short, it has to be at least 64 characters."
        fi
      done

      if [[ ! $(env_get POSTGRES_PASSWORD) =~ ^[A-Za-z0-9]*$ ]]; then
        fail "POSTGRES_PASSWORD may only contain letters and digits."
      fi

      if [[ ! $(env_get OPENSEARCH_HEAP) =~ ^[0-9]+[mg]$ ]]; then
        fail "OPENSEARCH_HEAP must be a number followed by m or g, such as 4g."
      fi

      if [[ ! $(env_get SMTP_PORT) =~ ^[0-9]+$ ]]; then
        fail "SMTP_PORT must be a number."
      fi

      if [[ $(env_get MAILER_ADDRESS) != *@* ]]; then
        fail "MAILER_ADDRESS must be an email address."
      fi

      for key in CRON_DAILY_HOUR BACKUP_HOUR; do
        value=$(env_get "$key")

        if [[ ! $value =~ ^[0-9]+$ ]] || ((value > 23)); then
          fail "$key must be an hour between 0 and 23."
        fi
      done

      if [[ ! $(env_get BACKUP_KEEP_DAYS) =~ ^[1-9][0-9]*$ ]]; then
        fail "BACKUP_KEEP_DAYS must be a number of days, at least 1."
      fi
      ;;

    proxy)
      if [[ $(env_get CDN_SOURCE) == origin ]]; then
        check_settings_present templates/proxy.env TLS_CERT_PATH \
          S3_SCHEME S3_HOST S3_PORT S3_REGION S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
      else
        check_settings_present templates/proxy.env TLS_CERT_PATH S3_REGION
      fi

      if [[ ! $(env_get ORIGIN_URL) =~ ^https://[^/]+$ ]]; then
        fail "ORIGIN_URL must look like https://<address>:<port>, without a path."
      fi
      ;;
  esac

  case "$(role)" in
    single) expected=docker-compose.yml:docker-compose.edge.yml ;;
    app) expected=docker-compose.yml:docker-compose.link-app.yml ;;
    proxy) expected=docker-compose.edge.yml:docker-compose.link-proxy.yml ;;
  esac

  if [[ $(env_get COMPOSE_FILE) != "$expected"* ]]; then
    fail "COMPOSE_FILE must start with $expected for ROLE=$(role)."
  fi

  if [[ $(role) == app ]]; then
    for key in ORIGIN_ADDRESS PROXY_SERVER; do
      [[ -n $(env_get "$key") ]] || fail "$key is not set."
    done
  fi

  if has_edge; then
    for key in CLIENT_IP_SOURCE:realip CDN_SOURCE:cdn; do
      value=$(env_get "${key%%:*}")

      if [[ -n $value && ! -f config/nginx/${key##*:}/$value.conf ]]; then
        fail "${key%%:*} is '$value', but config/nginx/${key##*:}/$value.conf does not exist."
      fi
    done

    if [[ ! $(env_get CDN_CACHE_SIZE) =~ ^[0-9]+[mg]$ ]]; then
      fail "CDN_CACHE_SIZE must be a number followed by m or g, such as 8g."
    fi
  fi

  check_domains
  check_storage
}

# Whether a certificate is valid for a domain, taking wildcards into account.
function cert_covers {
  local names=$1 domain=$2 name

  for name in $names; do
    if [[ $name == "$domain" ]]; then
      return 0
    fi

    if [[ $name == \*.* && $domain == *.* && ${domain#*.} == "${name#\*.}" ]]; then
      return 0
    fi
  done

  return 1
}

function check_certificate_dates {
  local file=$1 days
  days=$(cert_days_left "$file")

  if ((days < 0)); then
    fail "The certificate in $file expired $((-days)) days ago."
  elif ((days < 14)); then
    caution "The certificate in $file expires in $days days."
  fi
}

function check_certificates {
  local names key name

  if has_edge; then
    if [[ ! -f certs/fullchain.pem || ! -f certs/privkey.pem ]]; then
      fail "certs/fullchain.pem or certs/privkey.pem is missing. Run './philomena.sh cert install <directory>' or './philomena.sh cert self-signed'."
    elif ! openssl x509 -in certs/fullchain.pem -noout 2> /dev/null; then
      fail "certs/fullchain.pem is not a certificate."
    else
      if [[ $(public_key_hash cert certs/fullchain.pem) != "$(public_key_hash key certs/privkey.pem)" ]]; then
        fail "certs/privkey.pem is not the key of the certificate in certs/fullchain.pem."
      fi

      check_certificate_dates certs/fullchain.pem

      names=$(openssl x509 -in certs/fullchain.pem -noout -text |
        grep -A1 'Subject Alternative Name' | tail -n 1 | tr ',' '\n' | sed -n 's/^ *DNS://p')

      for key in SITE_DOMAIN CDN_DOMAIN EXT_DOMAIN; do
        if ! cert_covers "$names" "$(env_get "$key")"; then
          fail "The certificate in certs/fullchain.pem is not valid for $(env_get "$key") ($key)."
        fi
      done
    fi
  fi

  case "$(role)" in
    app) names='origin' ;;
    proxy) names='edge' ;;
    *) return 0 ;;
  esac

  for name in $names; do
    if [[ ! -f certs/internal/ca.pem || ! -f certs/internal/$name.pem || ! -f certs/internal/$name-key.pem ]]; then
      fail "The link certificates in certs/internal are incomplete."
    elif ! openssl verify -CAfile certs/internal/ca.pem "certs/internal/$name.pem" > /dev/null 2>&1; then
      fail "certs/internal/$name.pem was not issued by certs/internal/ca.pem, or has expired."
    else
      check_certificate_dates "certs/internal/$name.pem"
    fi
  done
}

function check_compose {
  local output

  if ! output=$(compose config --quiet 2>&1); then
    fail "Docker Compose rejects the configuration:
$output"
  fi
}

function cmd_check {
  require_config
  require_docker
  require_command openssl

  check_failures=0
  check_warnings=0

  check_host
  check_settings
  check_certificates
  check_compose

  if ((check_failures > 0)); then
    error "$check_failures problems have to be fixed before continuing."
    return 1
  fi

  if ((check_warnings > 0)); then
    info "The settings are usable, with $check_warnings warnings."
  else
    info "Everything looks good."
  fi
}
