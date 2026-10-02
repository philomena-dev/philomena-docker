#!/bin/sh
# Runs inside the `scheduler` container: the periodic jobs of the
# application, without a crontab on the host.
#
#   run-cron        every five minutes
#   run-cron-daily  once a day, during the hour CRON_DAILY_HOUR (UTC)
#
# A job that fails is logged and tried again on its next turn.

set -u

interval=300
daily_hour=$(printf '%02d' "${CRON_DAILY_HOUR:-8}")
last_daily=

trap 'exit 0' TERM INT

log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') scheduler: $*"
}

log "started, daily jobs run at ${daily_hour}:00 UTC"

while true; do
  started=$(date +%s)

  if run-cron; then
    log "run-cron finished"
  else
    log "run-cron failed with status $?"
  fi

  today=$(date -u '+%Y-%m-%d')

  if [ "$(date -u '+%H')" = "$daily_hour" ] && [ "$last_daily" != "$today" ]; then
    if run-cron-daily; then
      log "run-cron-daily finished"
      last_daily=$today
    else
      log "run-cron-daily failed with status $?"
    fi
  fi

  elapsed=$(($(date +%s) - started))

  if [ "$elapsed" -lt "$interval" ]; then
    # Sleep in the background so that the trap fires without delay.
    sleep $((interval - elapsed)) &
    wait $!
  fi
done
