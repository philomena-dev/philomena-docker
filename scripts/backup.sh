#!/usr/bin/env bash
# This file is meant to be sourced by `philomena.sh`, not executed directly.
# It contains the commands that deal with database backups, and the bundle
# that carries settings to the proxy server.

. scripts/release.sh

function cmd_backup {
  require_config
  has_app || die "The database lives on the app server."

  is_running postgres || die "The database is not running. Start it with './philomena.sh up'."

  step compose run --rm --no-deps backup once
}

function cmd_restore {
  local file='' reindex=true name setup_env=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes | -y) assume_yes=true ;;
      --no-reindex) reindex=false ;;
      -e)
        [[ ${2:-} == *=* ]] || die "-e needs an argument of the form NAME=value."
        setup_env+=(-e "$2")
        shift
        ;;
      -*) die "Unknown option: $1" ;;
      *) file=$1 ;;
    esac
    shift
  done

  require_config
  has_app || die "The database lives on the app server."

  [[ -n $file ]] || die "Usage: ./philomena.sh restore [--yes] [--no-reindex] [-e NAME=value] backups/<file>.pgdump"
  [[ -f $file ]] || die "$file does not exist."

  name=$(basename "$file")
  [[ -f backups/$name && backups/$name -ef $file ]] || die "The file has to be in the backups directory of this deployment."

  warn "This replaces the whole database of this deployment with the contents of $name."
  warn "Everything that was written to the database since that backup is lost."
  confirm "Restore $name?" || exit 1

  acquire_lock
  prepare_volumes

  step compose stop "${app_services[@]}"
  start_infrastructure

  # The dump is checked before anything is dropped.
  info "Replacing the database with $name..."
  # shellcheck disable=SC2016
  compose run --rm --no-deps --entrypoint /bin/sh backup -ec '
    pg_restore --list "/backups/$1" > /dev/null
    psql -X -q -v ON_ERROR_STOP=1 -d postgres \
      -c "DROP DATABASE IF EXISTS philomena WITH (FORCE)" \
      -c "CREATE DATABASE philomena"
    pg_restore --no-owner --exit-on-error --jobs 4 --dbname philomena "/backups/$1"
  ' restore "$name"

  # Brings a backup made by an older release up to date with the installed one.
  if ! run_setup_production ${setup_env[@]+"${setup_env[@]}"} --; then
    error "The backup was restored, but it could not be brought up to date with the installed release. The application has been left stopped."
    error "Deal with what is reported above, then run the restore again. Options the release asks for are passed with -e."
    exit 1
  fi

  if [[ $reindex == true ]]; then
    info "Rebuilding the search indexes from the restored database. This can take a long time on a large site."
    step compose run --rm app philomena eval \
      'Application.ensure_all_started(:philomena); Philomena.SearchIndexer.recreate_reindex_all_destructive!()'
  else
    warn "The search indexes were not rebuilt and may not match the database. Run './philomena.sh reindex' when convenient."
  fi

  rm -f "$incomplete_marker"

  step compose up -d --remove-orphans --wait

  info "Restored $name."
}

# Package what the proxy server needs to know: its settings, and its end of
# the link certificates.
function cmd_proxy_bundle {
  local output=proxy-bundle.tar.gz staging key cdn_source

  require_config
  [[ $(role) == app ]] || die "The bundle is made on the app server of a two-server deployment."
  [[ -f certs/internal/edge.pem ]] || die "The link certificates are missing. Run './philomena.sh cert link'."

  staging=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" EXIT

  mkdir "$staging/internal"
  cp templates/proxy.env "$staging/proxy.env"
  cp certs/internal/ca.pem certs/internal/edge.pem certs/internal/edge-key.pem "$staging/internal/"

  for key in SITE_DOMAIN CDN_DOMAIN EXT_DOMAIN CAMO_KEY SCRAPER_LINK_PORT; do
    env_set "$key" "$(env_get "$key")" "$staging/proxy.env"
  done

  env_set ORIGIN_URL "https://$(env_get ORIGIN_ADDRESS):$(env_get ORIGIN_PORT)" "$staging/proxy.env"

  # Files kept on the app server cannot be read by the proxy server directly,
  # so it asks the app server for them. An object storage service can.
  if uses_local_storage; then
    cdn_source=origin
  else
    cdn_source=storage

    for key in S3_SCHEME S3_HOST S3_PORT S3_REGION S3_BUCKET; do
      env_set "$key" "$(env_get "$key")" "$staging/proxy.env"
    done

    if [[ -n $(env_get WEB_AWS_ACCESS_KEY_ID) ]]; then
      env_set AWS_ACCESS_KEY_ID "$(env_get WEB_AWS_ACCESS_KEY_ID)" "$staging/proxy.env"
      env_set AWS_SECRET_ACCESS_KEY "$(env_get WEB_AWS_SECRET_ACCESS_KEY)" "$staging/proxy.env"
    else
      warn "The proxy server is given the same storage credentials as the application, which can write. Set WEB_AWS_ACCESS_KEY_ID and WEB_AWS_SECRET_ACCESS_KEY in $env_file to give it read-only credentials instead."
      env_set AWS_ACCESS_KEY_ID "$(env_get AWS_ACCESS_KEY_ID)" "$staging/proxy.env"
      env_set AWS_SECRET_ACCESS_KEY "$(env_get AWS_SECRET_ACCESS_KEY)" "$staging/proxy.env"
    fi
  fi

  env_set CDN_SOURCE "$cdn_source" "$staging/proxy.env"

  (
    umask 077
    tar -czf "$output" -C "$staging" proxy.env internal
  )

  info "Wrote $output."
  echo >&2
  echo "On the proxy server:" >&2
  echo "  1. Clone this repository and copy $output into it." >&2
  echo "  2. Run './philomena.sh prepare --proxy $output'." >&2
  echo "  3. Run './philomena.sh check' and './philomena.sh up'." >&2
  echo >&2
  echo "The bundle contains credentials. Delete it from both servers afterwards." >&2
}
