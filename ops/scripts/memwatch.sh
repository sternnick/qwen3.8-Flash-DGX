#!/usr/bin/env bash
# Host memory monitor for the model container. Monitor-only by default: it appends a line to a
# log and never touches a container.
#
# Acting requires BOTH of these, so an accidental edit of one of them cannot stop a service:
#   ENFORCE=1                                     in the environment
#   an action-enabled marker file                 $ACTION_FILE, default <log dir>/ENFORCING
#
#   CONTAINER          container name (default qwen38-flash)
#   MIN_AVAIL_GIB      threshold for the host reserve (default 6)
#   LOG_DIR            log location (default <repo>/ops/logs)
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
C=${CONTAINER:-qwen38-flash}
MIN_AVAIL_GIB=${MIN_AVAIL_GIB:-6}
LOGD=${LOG_DIR:-$HERE/../logs}
LOG="$LOGD/memwatch.log"
ACTION_FILE=${ACTION_FILE:-$LOGD/ENFORCING}
mkdir -p "$LOGD"

AV=$(( $(grep MemAvailable /proc/meminfo | tr -dc '0-9') / 1048576 ))
ZR=$(LANG=C swapon --show=used --bytes --noheadings 2>/dev/null | awk '{s+=$1} END{print s+0}')
NV=$(journalctl -k --since -1h 2>/dev/null | grep -c NV_ERR_NO_MEMORY)
ST=$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null || echo absent)
MSG="$(date -u +%FT%TZ) avail_gib=$AV zram_used_bytes=${ZR:-0} nv_err_1h=${NV:-0} container=$ST"

if [ "$AV" -lt "$MIN_AVAIL_GIB" ] || [ "${NV:-0}" -gt 0 ]; then
  if [ "${ENFORCE:-0}" = 1 ] && [ -f "$ACTION_FILE" ] && [ "$ST" = running ]; then
    echo "$MSG action=stop reserve_breached" >> "$LOG"; docker stop "$C" >> "$LOG" 2>&1
  else
    echo "$MSG action=none monitor_only" >> "$LOG"
  fi
else
  echo "$MSG ok" >> "$LOG"
fi

tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
