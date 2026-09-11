#!/usr/bin/env bash
# Roll the serving container back to a previous container, or fail loudly.
# Default mode is read-only (--check); --yes performs the swap. Nothing is ever deleted: the
# container being replaced is renamed and kept.
#
#   CURRENT              name of the running container (default qwen38-flash)
#   API_PORT             published port of the server (default 18300, this recipe's default)
#   MIN_FREE_GIB         host memory that must be free before starting a second engine (default 40)
#   GATE_WAIT_S          how long to wait for the driver to return memory (default 180)
#   READY_TIMEOUT_S      how long to wait for /health after start (default 1500)
#   LOG_DIR              log location (default <repo>/ops/logs)
#   SMOKE                path of a smoke test to run once healthy (optional)
#
# Note: this repository's scripts/serve.sh runs `docker rm -f "$NAME"`. Do not run serve.sh while
# a rollback is under soak — it would delete the container this script just started.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CURRENT=${CURRENT:-qwen38-flash}
API_PORT=${API_PORT:-18300}
MIN_FREE_GIB=${MIN_FREE_GIB:-40}
GATE_WAIT_S=${GATE_WAIT_S:-180}
READY_TIMEOUT_S=${READY_TIMEOUT_S:-1500}
LOGD=${LOG_DIR:-$HERE/../logs}
SMOKE=${SMOKE:-}

MODE=check; TARGET=""
for a in "$@"; do case "$a" in
  --check) MODE=check ;;
  --yes)   MODE=go ;;
  -*) echo "unknown flag $a" >&2; exit 2 ;;
  *)  TARGET="$a" ;;
esac; done

TS=$(date +%Y%m%d-%H%M%S); mkdir -p "$LOGD"; LOG="$LOGD/rollback-$TS.log"
say(){ printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
names(){ say "containers now: $(docker ps -a --format '{{.Names}}[{{.State.Status}}]' | grep -E "^${CURRENT}" | tr '\n' ' ')"; }
die(){ say "ABORT: $*"; names; exit 1; }

[ -n "$TARGET" ] || TARGET=$(docker ps -a --filter status=exited --format '{{.Names}}' \
  | grep -E "^${CURRENT}-(pre|old|bad)" | while read -r n; do
      printf '%s %s\n' "$(docker inspect -f '{{.Created}}' "$n")" "$n"; done \
    | sort -r | head -1 | cut -d' ' -f2-)
[ -n "$TARGET" ] || die "no candidate container (${CURRENT}-pre|old|bad) found"
[ "$TARGET" != "$CURRENT" ] || die "target equals the running container"
IMG=$(docker inspect -f '{{.Image}}' "$TARGET") || die "container $TARGET not found"
STATE=$(docker inspect -f '{{.State.Status}}' "$TARGET")
[ "$STATE" != running ] || die "target $TARGET is already running; refusing"
TAGS=$(docker image inspect -f '{{join .RepoTags ", "}}' "$IMG" 2>/dev/null) \
  || die "target image $IMG is gone: this needs a rebuild, not a rollback"
PORT=$(docker inspect -f '{{range $p,$b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}' "$TARGET")
SRC=$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$TARGET")

say "target    = $TARGET ($STATE) image $IMG tags: ${TAGS:-<none>, protected only while this container exists}"
say "port map  = ${PORT:-none} (proxy expects $API_PORT)"
for s in $SRC; do [ -d "$s" ] || die "mount source missing: $s"; done
for d in $SRC/models--*/; do
  [ -d "$d/snapshots" ] || continue
  p=$(find "$d/snapshots" -maxdepth 2 -name .prepared 2>/dev/null | head -1)
  [ -n "$p" ] && say "snapshot  = $(basename "$d") prepared variant $(basename "$(dirname "$p")")"
done
for c in CURRENT TARGET; do
  n=$(eval echo "\$$c")
  say "flags($c) = $(docker inspect -f '{{join .Args " "}}' "$n" | tr ' ' '\n' \
      | grep -A1 -E 'gpu-memory-utilization|max-model-len|max-num-seqs|kv-cache-dtype|prefix-caching|speculative-config' | tr '\n' ' ')"
  say "env($c)   = $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$n" \
      | grep -E 'VLLM_FP8_HYBRID|VLLM_QSA_DET_TOPK|VLLM_MTP_DRAFT_VOCAB|VLLM_PLE_MMAP' | tr '\n' ' ')"
done
FREEG=$(( $(df -BG --output=avail / | tail -1 | tr -dc '0-9') ))
[ "$FREEG" -ge 20 ] || die "only ${FREEG}G free on /"
echo "$PORT" | grep -qw "$API_PORT" || say "WARN: target publishes ${PORT:-nothing}, not $API_PORT - the proxy will not reach it as-is"

[ "$MODE" = go ] || { say "CHECK ONLY - nothing changed. Re-run with --yes to perform the swap."; exit 0; }

say "=== performing rollback (log $LOG) ==="
docker tag "$(docker inspect -f '{{.Image}}' "$CURRENT")" "qwen38-flash-dgx:rolledback-from-$TS" 2>>"$LOG" \
  && say "current image tagged qwen38-flash-dgx:rolledback-from-$TS"
docker stop "$CURRENT" >>"$LOG" 2>&1 || die "stop failed; service is down - start it manually: docker start $CURRENT"

for i in $(seq 1 $((GATE_WAIT_S/5))); do
  AV=$(( $(grep MemAvailable /proc/meminfo | tr -dc '0-9') / 1048576 ))
  [ "$AV" -ge "$MIN_FREE_GIB" ] && { say "MemAvailable ${AV}G >= ${MIN_FREE_GIB}G after stop"; break; }
  sleep 5
  if [ "$i" = $((GATE_WAIT_S/5)) ]; then
    say "memory gate: MemAvailable still ${AV}G after ${GATE_WAIT_S}s (driver has not returned it)"
    docker start "$CURRENT" >>"$LOG" 2>&1 && say "recovered: restarted the original container, nothing was renamed"
    die "rollback skipped; service restored as it was"
  fi
done

docker rename "$CURRENT" "${CURRENT}-bad-$TS" || die "rename of current failed; start it again: docker start $CURRENT"
say "renamed $CURRENT -> ${CURRENT}-bad-$TS (kept, not deleted)"
docker rename "$TARGET" "$CURRENT" || die "rename of target failed; reverse now: docker rename ${CURRENT}-bad-$TS $CURRENT && docker start $CURRENT"
say "renamed $TARGET -> $CURRENT"
docker start "$CURRENT" >>"$LOG" 2>&1 \
  || die "start failed; reverse now: docker rename $CURRENT ${TARGET}-failed && docker rename ${CURRENT}-bad-$TS $CURRENT && docker start $CURRENT"

for i in $(seq 1 $((READY_TIMEOUT_S/10))); do
  sleep 10
  if curl -sf -m 5 "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1; then
    say "health OK after $((i*10))s"
    [ -n "$SMOKE" ] && [ -x "$SMOKE" ] && "$SMOKE" 2>&1 | tee -a "$LOG"
    say "done. The replaced container is kept as ${CURRENT}-bad-$TS - delete nothing until a soak passes."
    names; exit 0
  fi
done
say "not ready after ${READY_TIMEOUT_S}s. Inspect: docker logs $CURRENT"
say "reverse: docker stop $CURRENT && docker rename $CURRENT ${TARGET}-failed && docker rename ${CURRENT}-bad-$TS $CURRENT && docker start $CURRENT"
names; exit 1
