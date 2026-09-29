#!/usr/bin/env bash
# Read-only drift detector for the blazux serving stack. Changes nothing: no fetch, no build.
set -uo pipefail
R=/home/aiadmin/projects/qwen38-flash-dgx/qwen3.8-Flash-DGX
CACHE=/home/aiadmin/.cache/huggingface
LOGD=/home/aiadmin/projects/qwen38-flash-dgx/logs
J=https://raw.githubusercontent.com/jschmied/qwen38-flash-next-gb10
DRIFT=0; OUT=""
say(){ OUT+="$1"$'\n'; }
# http_fetch URL DEST -> writes the body to DEST and prints the HTTP status code.
# Separating status from content is the whole point of this helper: a patch that upstream has
# RETIRED answers 404, and the body "404: Not Found" hashes to a stable value
# (sha256 -> d5558cd419c8...), so the old hash-only comparison reported a removed patch as a
# silent content DRIFT forever. Status first, hash second.
http_fetch(){ timeout 25 curl -sL -m 20 -o "$2" -w '%{http_code}' "$1" 2>/dev/null; }
LOCAL=$(cd "$R" && git rev-parse HEAD)
REMOTE=$(cd "$R" && timeout 30 git ls-remote origin -h refs/heads/main | cut -f1)
if [ "$LOCAL" = "$REMOTE" ]; then say "repo       : no drift (${LOCAL:0:8})"
else say "repo       : DRIFT local=${LOCAL:0:8} origin=${REMOTE:0:8}"; DRIFT=1; fi
DIRTY=$(cd "$R" && git status --porcelain | wc -l)
[ "$DIRTY" = 0 ] || say "repo       : NOTE $DIRTY locally modified files"
FROM=$(grep -m1 '^FROM' "$R/Dockerfile")
PIN=$(printf '%s' "$FROM" | sed -n 's|^FROM .*@sha256:\([0-9a-f]*\).*|\1|p')
TAG=$(printf '%s' "$FROM" | sed -n 's|^FROM vllm/vllm-openai:\([^@ ]*\)@.*|\1|p')
TOK=$(timeout 20 curl -s -m 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:vllm/vllm-openai:pull" | sed -n 's|.*"token":"\([^"]*\)".*|\1|p')
LIVE=$(timeout 25 curl -s -m 20 -D - -o /dev/null -H "Authorization: Bearer $TOK" \
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://registry-1.docker.io/v2/vllm/vllm-openai/manifests/$TAG" | tr -d '\r' \
  | sed -n 's|^[Dd]ocker-[Cc]ontent-[Dd]igest: sha256:\([0-9a-f]*\).*|\1|p')
if [ -z "$LIVE" ]; then say "base image : UNKNOWN (registry unreachable or no digest pin)"
elif [ "$PIN" = "$LIVE" ]; then say "base image : no drift (${PIN:0:12})"
else say "base image : DRIFT pinned=${PIN:0:12} registry=${LIVE:0:12}"; DRIFT=1; fi
for spec in "KDET_SHA:patches/kernel-det/topk_det.cu" "KDET_SHA:patches/kernel-det/persistent_topk.cuh" \
            "KDET_SHA:patches/kernel-det/build_det.py" "KDET_SHA:patches/kernel-det/bindings_det.cpp" \
            "KDET_SHA:patches/kernel-det/torch_utils.h" "KDET_SHA:tools/determinism/qsadet_patch.py" \
            "KM4_SHA:tools/main/fp8_m4pad_patch.py"; do
  k=${spec%%:*}; f=${spec#*:}; sha=$(grep -m1 "ARG $k=" "$R/Dockerfile" | cut -d= -f2)
  PF=$(mktemp); MF=$(mktemp)
  SP=$(http_fetch "$J/$sha/$f" "$PF"); SM=$(http_fetch "$J/main/$f" "$MF")
  case "$SP:$SM" in
    # our own pin is unreachable -> a rebuild would fail. Always a real problem, even if
    # main is also 404 (the path moved), so this branch is tested first.
    404:*) say "pin ${f##*/} : BROKEN  our pin ${sha:0:12} returns 404 — rebuild would fail"; DRIFT=1 ;;
    # upstream deleted the patch: the fix landed in the base image, nothing to port.
    *:404) say "pin ${f##*/} : RETIRED  gone from upstream main — patch no longer needed" ;;
    # a transport failure is not evidence of drift; say so instead of comparing bodies.
    200:200)
      a=$(sha256sum < "$PF" | cut -c1-12); b=$(sha256sum < "$MF" | cut -c1-12)
      if [ "$a" = "$b" ]; then say "pin ${f##*/} : no drift"
      else say "pin ${f##*/} : DRIFT pinned=$a main=$b"; DRIFT=1; fi ;;
    *) say "pin ${f##*/} : UNKNOWN  http pinned=$SP main=$SM (not compared)" ;;
  esac
  rm -f "$PF" "$MF"
done
APISHA=$(timeout 25 curl -s -m 20 "https://huggingface.co/api/models/RadixArk/Qwen3.8-Flash-Next-NVFP4" \
  | tr ',' '\n' | sed -n 's|.*"sha":"\([0-9a-f]*\)".*|\1|p' | head -1)
LOCALSNAP=$(ls -d "$CACHE"/models--RadixArk--Qwen3.8-Flash-Next-NVFP4/snapshots/*/ 2>/dev/null \
  | sed 's|/*$||; s|.*/||' | grep -v -- '-fp8' | head -1 | tr -d ' ')
if [ -z "$APISHA" ] || [ -z "$LOCALSNAP" ]; then say "checkpoint : UNKNOWN"
elif [ "${APISHA:0:12}" = "${LOCALSNAP:0:12}" ]; then say "checkpoint : no drift (${LOCALSNAP:0:12})"
else say "checkpoint : DRIFT local=${LOCALSNAP:0:12} hf=${APISHA:0:12}"; DRIFT=1; fi
{ printf '%s' "$OUT"; printf '%s DRIFT=%s\n' "$(date -u +%FT%TZ)" "$DRIFT"; } >> "$LOGD/update-check.log"
printf '%s drift=%s\n' "$(date -u +%FT%TZ)" "$DRIFT" > "$LOGD/update-check.status"
printf '%s' "$OUT"
[ "$DRIFT" = 0 ] && echo "-> nothing to update" || echo "-> DRIFT DETECTED: read UPDATE-RUNBOOK.md before rebuilding"
