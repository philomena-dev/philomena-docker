#!/usr/bin/env bash
# The entrypoint CLI of this deployment. Run it without arguments for the
# list of commands.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"

function usage {
  cat >&2 << 'USAGE'
Usage: ./philomena.sh <command>

Installing:
  prepare                 Create the settings of a new deployment
  prepare --proxy <file>  Create the settings of a proxy server from a bundle
  check                   Verify the server and the settings
  setup                   Create the database and start the site
  proxy-bundle            Package the settings for the proxy server
  wireguard [bundle]      Put the link between the two servers in a WireGuard
                          tunnel (strongly recommended)

Running:
  up                      Start everything
  down                    Stop everything
  restart [service...]    Restart everything, or some services
  status                  Show what is running, and the state of the backups
  logs [service...]       Follow the logs
  update                  Update this repository and Philomena

Maintaining:
  backup                  Back up the database now
  restore <file>          Replace the database with a backup
  reindex                 Rebuild the search indexes from the database
  cert install [dir]      Install the public certificate from a directory
  cert self-signed        Create a self-signed public certificate
  cert link               Recreate the certificates of the server link
  psql                    Open a database console
  console                 Open an Elixir console in the running application
  eval <expression>       Evaluate an Elixir expression in a new container

Options of `restore`:
  -y, --yes               Do not ask for confirmation
  --no-reindex            Do not rebuild the search indexes afterwards
  -e NAME=value           Pass a setting to the release's upgrade steps

Options of `update`:
  -y, --yes               Do not ask before taking the site down
  --no-pull               Do not update this repository first
  --no-image-pull         Use the images that are already on this server
  --skip-backup           Do not back up the database first
  --branch <name>         Move to the next major version
  -e NAME=value           Pass a setting to the release's upgrade steps
USAGE
}

function status {
  local newest age

  step compose ps --all

  has_app || return 0

  newest=$(find backups -maxdepth 1 -name 'database_*.pgdump' 2> /dev/null | sort | tail -n 1)

  if [[ -z $newest ]]; then
    warn "There are no database backups in ./backups yet."
    return 0
  fi

  age=$((($(date +%s) - $(stat -c %Y "$newest" 2> /dev/null || stat -f %m "$newest")) / 3600))

  if ((age > 48)); then
    warn "The newest database backup is $age hours old: $newest. Check './philomena.sh logs backup'."
  else
    info "Newest database backup: $newest ($age hours old)"
  fi
}

function main {
  local command=${1:-} owner
  shift || true

  # Files created by root in a deployment that belongs to someone else would
  # lock that user out. Installing a renewed certificate is the one thing
  # root is expected to do here.
  owner=$(stat -c %u "$repo_root" 2> /dev/null || stat -f %u "$repo_root")

  if [[ $EUID -eq 0 && $owner -ne 0 && $command != cert ]]; then
    die "This deployment belongs to $(id -un "$owner" 2> /dev/null || echo "user $owner"). Run this command as that user, not as root."
  fi

  case "$command" in
    prepare)
      . scripts/prepare.sh
      cmd_prepare "$@"
      ;;

    check)
      . scripts/check.sh
      cmd_check
      ;;

    setup)
      . scripts/release.sh
      cmd_setup
      ;;

    update)
      . scripts/release.sh
      cmd_update "$@"
      ;;

    backup)
      . scripts/backup.sh
      cmd_backup
      ;;

    restore)
      . scripts/backup.sh
      cmd_restore "$@"
      ;;

    proxy-bundle)
      . scripts/backup.sh
      cmd_proxy_bundle
      ;;

    wireguard)
      . scripts/wireguard.sh
      cmd_wireguard "$@"
      ;;

    cert)
      . scripts/cert.sh
      cmd_cert "$@"
      ;;

    up)
      require_config
      require_docker
      [[ ! -f .admin ]] || die "This deployment has not been set up yet. Run './philomena.sh setup'."
      [[ ! -f $incomplete_marker ]] || die "An update did not finish, and the database may be partly upgraded. Run './philomena.sh update --no-pull' to finish it, or restore the backup it made with './philomena.sh restore'."
      prepare_volumes
      step compose up -d --remove-orphans --wait
      ;;

    down)
      require_config
      step compose down --remove-orphans
      ;;

    restart)
      require_config
      step compose restart "$@"
      ;;

    status)
      require_config
      status
      ;;

    logs)
      require_config
      compose logs --follow --tail 100 "$@"
      ;;

    psql)
      require_config
      has_app || die "The database lives on the app server."
      compose exec postgres psql -U philomena philomena "$@"
      ;;

    console)
      require_config
      has_app || die "The application runs on the app server."
      compose exec -e RELEASE_NODE=philomena_app_0 app philomena remote
      ;;

    eval)
      require_config
      has_app || die "The application runs on the app server."
      [[ $# -eq 1 ]] || die "Usage: ./philomena.sh eval '<expression>'"
      compose run --rm app philomena eval "$1"
      ;;

    reindex)
      require_config
      has_app || die "The application runs on the app server."
      warn "Search results are incomplete until this has finished."
      step compose run --rm app philomena eval \
        'Application.ensure_all_started(:philomena); Philomena.SearchIndexer.recreate_reindex_all_destructive!()'
      ;;

    '' | help | -h | --help)
      usage
      ;;

    *)
      error "Unknown command: $command"
      usage
      exit 1
      ;;
  esac
}

main "$@"
