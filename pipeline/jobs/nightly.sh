#!/bin/sh
set -eu

AT="${NIGHTLY_AT:-03:00}"

while true; do
    now=$(date +%s)
    next=$(date -d "today $AT" +%s)
    [ "$next" -le "$now" ] && next=$(date -d "tomorrow $AT" +%s)

    echo "nightly_sync: next run at $(date -d "@$next" -Is)"
    sleep $((next - now))

    echo "nightly_sync: starting at $(date -Is)"
    if python -m jobs.nightly_sync; then
        echo "nightly_sync: finished at $(date -Is)"
    else
        echo "nightly_sync: FAILED with exit $? at $(date -Is)"
    fi
done
