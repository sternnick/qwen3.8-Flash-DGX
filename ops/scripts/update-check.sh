#!/usr/bin/env bash
# Read-only drift detector for this deployment. Performs no fetch, no build and no container
# operation. Reports on four axes and writes a one-line status.
#
#   REPO_DIR         path to the deployment clone (default: the repository containing this file)
#   LOG_DIR          where to write logs (default: <repo>/ops/logs)
#   HF_CACHE         Hugging Face cache root (default: $HF_HOME or ~/.cache/huggingface)
#   KPIN_BASE        raw-file base URL of the repository holding the pinned kernel sources
#   CHECKPOINT       HF model id whose current sha is compared against the local snapshot
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=${REPO_DIR:-$(cd "$HERE/../.." && pwd)}
LOGD=${LOG_DIR:-$REPO/ops/logs}
CACHE=${HF_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}}
# The base URL the pinned files are fetched from is taken from the Dockerfile itself, so this
# script never hard-codes a third-party repository; override with KPIN_BASE if needed.
KPIN_BASE=${KPIN_BASE:-$(grep -oE 'https://raw\.githubusercontent\.com/[^/ ]+/[^/ ]+' "$REPO/Dockerfile" | head -1)}
CHECKPOINT=${CHECKPOINT:-RadixArk/Qwen3.8-Flash-Next-NVFP4}
CKPT_DIR="models--$(printf '%s' "$CHECKPOINT" | sed 's|/|--|g')"   # HF cache naming

mkdir -p "$LOGD"
DRIFT=0; OUT=""
say(){ OUT+="$1"$'\n'; }

# 1. repository ------------------------------------------------------------
LOCAL=$(cd "$REPO" && git rev-parse HEAD)
REMOTE=$(cd "$REPO" && timeout 30 git ls-remote origin -h refs/heads/main | cut -f1)
if [ "$LOCAL" = "$REMOTE" ]; then say "repo        : no drift (${LOCAL:0:8})"
else say "repo        : DRIFT local=${LOCAL:0:8} origin=${REMOTE:0:8}"; DRIFT=1; fi
DIRTY=$(cd "$REPO" && git status --porcelain | wc -l)
[ "$DIRTY" = 0 ] || say "repo        : NOTE $DIRTY locally modified files"

# 2. base image ------------------------------------------------------------
FROM=$(grep -m1 '^FROM' "$REPO/Dockerfile")
PIN=$(printf '%s' "$FROM" | sed -n 's|^FROM .*@sha256:\([0-9a-f]*\).*|\1|p')
TAG=$(printf '%s' "$FROM" | sed -n 's|^FROM vllm/vllm-openai:\([^@ ]*\)@.*|\1|p')
if [ -z "$PIN" ]; then
  say "base image  : NOTE no digest pinned in Dockerfile, nothing to compare"
else
  TOK=$(timeout 20 curl -s -m 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:vllm/vllm-openai:pull" \
        | sed -n 's|.*"token":"\([^"]*\)".*|\1|p')
  LIVE=$(timeout 25 curl -s -m 20 -D - -o /dev/null -H "Authorization: Bearer $TOK" \
          -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
          "https://registry-1.docker.io/v2/vllm/vllm-openai/manifests/$TAG" | tr -d '\r' \
        | sed -n 's|^[Dd]ocker-[Cc]ontent-[Dd]igest: sha256:\([0-9a-f]*\).*|\1|p')
  if [ -z "$LIVE" ]; then say "base image  : UNKNOWN (registry unreachable)"
  elif [ "$PIN" = "$LIVE" ]; then say "base image  : no drift (${PIN:0:12})"
  else say "base image  : DRIFT pinned=${PIN:0:12} registry=${LIVE:0:12}"; DRIFT=1; fi
fi

# 3. externally pinned kernel files (content, not dates) -------------------
for spec in "KDET_SHA:patches/kernel-det/topk_det.cu" "KDET_SHA:patches/kernel-det/persistent_topk.cuh" \
            "KDET_SHA:patches/kernel-det/build_det.py" "KDET_SHA:patches/kernel-det/bindings_det.cpp" \
            "KDET_SHA:patches/kernel-det/torch_utils.h" "KDET_SHA:tools/determinism/qsadet_patch.py" \
            "KM4_SHA:tools/main/fp8_m4pad_patch.py"; do
  k=${spec%%:*}; f=${spec#*:}
  sha=$(grep -m1 "ARG $k=" "$REPO/Dockerfile" | cut -d= -f2)
  [ -n "$sha" ] || { say "pin ${f##*/}  : NOTE $k not present in Dockerfile"; continue; }
  if [ -z "$KPIN_BASE" ]; then say "pin ${f##*/}  : UNKNOWN (no raw base URL; set KPIN_BASE)"; continue; fi
  # Compare bytes and check the HTTP status. Hashing fetched output is not enough: a failed
  # request hashes to the same value on both sides and looks like "no drift".
  pa=$(mktemp); pb=$(mktemp)
  ca=$(timeout 25 curl -sL -m 20 -o "$pa" -w '%{http_code}' "$KPIN_BASE/$sha/$f")
  cb=$(timeout 25 curl -sL -m 20 -o "$pb" -w '%{http_code}' "$KPIN_BASE/main/$f")
  if [ "$ca" != 200 ] || [ "$cb" != 200 ]; then
    say "pin ${f##*/}  : UNKNOWN (http $ca / $cb - wrong base URL, or the path moved)"
  elif cmp -s "$pa" "$pb"; then say "pin ${f##*/}  : no drift"
  else say "pin ${f##*/}  : DRIFT pinned=$(sha256sum <"$pa" | cut -c1-12) branch=$(sha256sum <"$pb" | cut -c1-12)"; DRIFT=1; fi
  rm -f "$pa" "$pb"
  continue
done

# 4. served checkpoint -----------------------------------------------------
APISHA=$(timeout 25 curl -s -m 20 "https://huggingface.co/api/models/$CHECKPOINT" \
          | tr ',' '\n' | sed -n 's|.*"sha":"\([0-9a-f]*\)".*|\1|p' | head -1)
LOCALSNAP=$(ls -d "$CACHE/$CKPT_DIR/snapshots/"*/ 2>/dev/null | sed 's|/*$||; s|.*/||' \
             | grep -v -- '-' | head -1 | tr -d ' ')
if [ -z "$APISHA" ] || [ -z "$LOCALSNAP" ]; then say "checkpoint  : UNKNOWN (offline, or snapshot not present)"
elif [ "${APISHA:0:12}" = "${LOCALSNAP:0:12}" ]; then say "checkpoint  : no drift (${LOCALSNAP:0:12})"
else say "checkpoint  : DRIFT local=${LOCALSNAP:0:12} api=${APISHA:0:12}"; DRIFT=1; fi

{ printf '%s' "$OUT"; printf '%s drift=%s\n' "$(date -u +%FT%TZ)" "$DRIFT"; } >> "$LOGD/update-check.log"
printf '%s drift=%s\n' "$(date -u +%FT%TZ)" "$DRIFT" > "$LOGD/update-check.status"
printf '%s' "$OUT"
[ "$DRIFT" = 0 ] && echo "-> nothing to update" || echo "-> DRIFT DETECTED: read docs/02-update-runbook.md before rebuilding"
exit "$DRIFT"
