#!/usr/bin/env bash
# This file is meant to be sourced by `philomena.sh`, not executed directly.
# It creates the settings file and the certificates of a new deployment.

. scripts/cert.sh

function random_hex {
  openssl rand -hex "$1"
}

# A quarter of the memory available to Docker, between 1 and 16 GB.
function suggested_heap {
  local total gigabytes
  total=$(docker info --format '{{.MemTotal}}' 2> /dev/null || echo 0)
  gigabytes=$((total / 1024 / 1024 / 1024 / 4))

  if ((gigabytes < 1)); then
    echo 1g
  elif ((gigabytes > 16)); then
    echo 16g
  else
    echo "${gigabytes}g"
  fi
}

function prepare_public_certificate {
  echo >&2
  echo "The web server needs a TLS certificate that covers all three domains." >&2
  echo "Enter the directory that contains fullchain.pem and privkey.pem (for" >&2
  echo "certbot: /etc/letsencrypt/live/<domain>), or leave this empty to create" >&2
  echo "a self-signed certificate for testing." >&2
  ask TLS_CERT_PATH "Certificate directory" ''

  if [[ -n $TLS_CERT_PATH ]]; then
    cert_install "$TLS_CERT_PATH"
  else
    cert_self_signed
  fi
}

function prepare_app {
  local storage_default=local

  echo "This creates the settings of a new Philomena deployment." >&2
  echo >&2
  echo "Deployment type:" >&2
  echo "  single  everything runs on this server" >&2
  echo "  app     this is the app server; a separate proxy server faces the internet" >&2
  ask ROLE "Deployment type" single

  case "$ROLE" in
    single | app) ;;
    *) die "The deployment type must be 'single' or 'app'." ;;
  esac

  ask SITE_DOMAIN "Site domain" philomena.local
  ask CDN_DOMAIN "CDN domain" "cdn.$SITE_DOMAIN"
  ask EXT_DOMAIN "Domain for proxied external images" "ext.$SITE_DOMAIN"

  echo >&2
  echo "Uploaded files are kept in:" >&2
  echo "  local  a directory on this server" >&2
  echo "  s3     an S3-compatible object storage service" >&2
  ask STORAGE "Storage" "$storage_default"

  case "$STORAGE" in
    local | s3) ;;
    *) die "The storage must be 'local' or 's3'." ;;
  esac

  if [[ $ROLE == app ]]; then
    echo >&2
    echo "The two servers talk to each other over two ports: the proxy server" >&2
    echo "connects to port 8443 of this server, and this server connects to" >&2
    echo "port 3129 of the proxy server." >&2
    ask ORIGIN_ADDRESS "Address of this server, as reachable from the proxy server" ''
    ask PROXY_SERVER "Address of the proxy server, as reachable from this server" ''

    [[ -n $ORIGIN_ADDRESS && -n $PROXY_SERVER ]] || die "Both addresses are required."
  fi

  echo >&2
  ask ADMIN_USERNAME "Name of the first administrator account" Administrator
  ask ADMIN_EMAIL "Email address of that account" "admin@$SITE_DOMAIN"

  (
    umask 077
    cp templates/app.env "$env_file"
  )

  env_set ROLE "$ROLE"
  env_set HOST_UID "$(id -u)"
  env_set HOST_GID "$(id -g)"

  env_set SITE_DOMAIN "$SITE_DOMAIN"
  env_set CDN_DOMAIN "$CDN_DOMAIN"
  env_set EXT_DOMAIN "$EXT_DOMAIN"
  env_set MAILER_ADDRESS "noreply@$SITE_DOMAIN"

  env_set SECRET_KEY_BASE "$(random_hex 64)"
  env_set ANONYMOUS_NAME_SALT "$(random_hex 64)"
  env_set PASSWORD_PEPPER "$(random_hex 64)"
  env_set OTP_SECRET_KEY "$(random_hex 64)"
  env_set CAMO_KEY "$(random_hex 64)"
  env_set POSTGRES_PASSWORD "$(random_hex 24)"

  env_set OPENSEARCH_HEAP "$(suggested_heap)"

  if [[ $STORAGE == local ]]; then
    env_set COMPOSE_PROFILES local-storage
    env_set S3_SCHEME http
    env_set S3_HOST files
    env_set S3_PORT 80
    env_set S3_REGION us-east-1
    env_set S3_BUCKET philomena
    env_set AWS_ACCESS_KEY_ID "$(random_hex 16)"
    env_set AWS_SECRET_ACCESS_KEY "$(random_hex 32)"
  fi

  if [[ $ROLE == single ]]; then
    env_set COMPOSE_FILE docker-compose.yml:docker-compose.edge.yml
    prepare_public_certificate
  else
    env_set COMPOSE_FILE docker-compose.yml:docker-compose.link-app.yml

    {
      echo
      echo "## Link to the proxy server"
      echo
      echo "# Address of this server, as reachable from the proxy server, and the port"
      echo "# the proxy server connects to."
      echo "ORIGIN_ADDRESS=$ORIGIN_ADDRESS"
      echo "ORIGIN_PORT=8443"
      echo
      echo "# Address of the proxy server, as reachable from this server, and the port"
      echo "# this server connects to."
      echo "PROXY_SERVER=$PROXY_SERVER"
      echo "SCRAPER_LINK_PORT=3129"
      echo
      echo "# The scraper reaches its outgoing proxy through the link."
      echo "PROXY_HOST=http://link:3128"
    } >> "$env_file"

    cert_link
  fi

  (
    umask 077
    {
      echo "ADMIN_USERNAME=$ADMIN_USERNAME"
      echo "ADMIN_EMAIL=$ADMIN_EMAIL"
      echo "ADMIN_PASSWORD=$(random_hex 16)"
    } > .admin
  )

  mkdir -p volumes/acme backups logs

  echo >&2
  info "Created $env_file."
  echo >&2
  echo "Next steps:" >&2
  echo "  1. Open $env_file and fill in every value that reads CHANGE_THIS." >&2
  echo "  2. Run './philomena.sh check' to verify the settings." >&2
  echo "  3. Run './philomena.sh setup' to create the database and start the site." >&2

  if [[ $ROLE == app ]]; then
    echo "  4. Run './philomena.sh proxy-bundle' and set up the proxy server with it." >&2
  fi

  echo >&2
  echo "The first administrator account:" >&2
  echo "  Email:    $ADMIN_EMAIL" >&2
  echo "  Password: $(env_get ADMIN_PASSWORD .admin)" >&2
  echo "These are kept in the file .admin until 'setup' has run. Change the" >&2
  echo "password after logging in for the first time." >&2
}

function prepare_proxy {
  local bundle=$1 staging

  [[ -r $bundle ]] || die "Cannot read $bundle"

  staging=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" EXIT

  tar -xzf "$bundle" -C "$staging"

  [[ -f $staging/proxy.env && -f $staging/internal/ca.pem ]] ||
    die "$bundle is not a bundle made by './philomena.sh proxy-bundle'."

  mkdir -p certs/internal volumes/acme logs
  chmod 700 certs/internal

  (
    umask 077
    cp "$staging/proxy.env" "$env_file"
    cp "$staging"/internal/*.pem certs/internal/
  )

  prepare_public_certificate

  echo >&2
  info "Created $env_file."
  echo >&2
  echo "Next steps:" >&2
  echo "  1. Run './philomena.sh check' to verify the settings." >&2
  echo "  2. Run './philomena.sh up' to start the proxy server." >&2
  echo "  3. Delete $bundle; it contains credentials." >&2
}

function cmd_prepare {
  local bundle=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proxy)
        bundle=${2:-}
        [[ -n $bundle ]] || die "Usage: ./philomena.sh prepare --proxy <bundle>"
        shift
        ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done

  if [[ -e $env_file ]]; then
    die "$env_file already exists. It holds the secrets of this deployment; replacing it on a live site locks every user out. Move it away first if you really want to start over."
  fi

  require_command openssl
  require_docker

  if [[ -n $bundle ]]; then
    prepare_proxy "$bundle"
  else
    prepare_app
  fi
}
