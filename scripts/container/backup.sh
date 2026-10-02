#!/bin/sh
# Runs inside the `backup` container.
#
# Usage: backup.sh once      write one database dump to /backups
#        backup.sh schedule  write one every day, during the hour BACKUP_HOUR
#                            (UTC), and remove the ones older than
#                            BACKUP_KEEP_DAYS days
#
# A dump is written under a temporary name and only given its final name
# once it has been read back successfully, so an interrupted or failed
# backup never looks like a good one. Old dumps are only removed after a new
# one has been written.

set -eu

umask 077

dir=/backups
keep_days=${BACKUP_KEEP_DAYS:-14}

log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') backup: $*"
}

backup() {
  name=database_$(date -u '+%Y_%m_%d-%H-%M').pgdump
  partial=$dir/.$name.partial

  rm -f "$dir"/.*.partial

  if ! pg_dump --format=custom --no-owner --file="$partial"; then
    log "pg_dump failed"
    rm -f "$partial"
    return 1
  fi

  if ! pg_restore --list "$partial" > /dev/null; then
    log "the dump could not be read back"
    rm -f "$partial"
    return 1
  fi

  mv "$partial" "$dir/$name"
  log "wrote $name ($(du -h "$dir/$name" | cut -f1))"
}

prune() {
  find "$dir" -maxdepth 1 -type f -name 'database_*.pgdump' -mtime "+$keep_days" -print -delete |
    while read -r file; do
      log "removed $(basename "$file")"
    done
}

case "${1:-}" in
  once)
    backup
    ;;

  schedule)
    hour=$(printf '%02d' "${BACKUP_HOUR:-2}")
    last=

    trap 'exit 0' TERM INT

    log "started, backups run at ${hour}:00 UTC and are kept for $keep_days days"

    while true; do
      today=$(date -u '+%Y-%m-%d')

      if [ "$(date -u '+%H')" = "$hour" ] && [ "$last" != "$today" ]; then
        if backup; then
          last=$today
          prune
        fi
      fi

      # Sleep in the background so that the trap fires without delay.
      sleep 300 &
      wait $!
    done
    ;;

  *)
    echo "Usage: backup.sh once|schedule" >&2
    exit 2
    ;;
esac
