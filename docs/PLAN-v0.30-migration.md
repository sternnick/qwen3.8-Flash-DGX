# Plan: migrate the serving image to the vLLM v0.30 base

**Status: PLAN ONLY — do not execute.** Written 2026-09-29. Every measurement below was taken on
the live host (`gx10-444d`, `aiadmin@192.168.11.15`) on 2026-09-29, not copied from upstream docs.

---

## a) Current state

| | Value |
|---|---|
| Production checkout | `/home/aiadmin/projects/qwen38-flash-dgx/qwen3.8-Flash-DGX` |
| Checked-out branch | `preview/zero-risk-wins-20260929` @ `370256d` (based on `9248c9d`) |
| Base commit `9248c9d` | 2026-09-26, "Merge pull request #41 from ryandorey/served-model-name" |
| Running container | `qwen38-flash`, image `qwen38-flash-dgx:candidate` |
| Image base label | **`qwen38.base=preview`** |
| Distance from upstream | **4 commits behind** `blazux/main` = `b05e146` (2026-09-27) |
| Running vLLM | `0.1.dev20073+g8e685d198` (the preview tag `vllm/vllm-openai:qwen38-flash-next`, digest `fc120ece0a38`, still current in the registry — no drift) |

The container has been up since 2026-09-27 11:18 UTC and holds the GPU pool at `gpu-mem 0.80`.

## b) Target

`b05e14681325f3cc5bd22e7f48537feeeb0bf266` — "vLLM v0.30 is the only base", the tip of
`blazux/main`, already present on our fork as `fork/main`. Four commits ahead of what we run:

| commit | change |
|---|---|
| `b130be782` | Expose prompt cache token details (PR #43) — **already applied to production**, see below |
| `66f3b8110` | README: patch 12/13 guards cover `qwen3_coder` and `qwen3_xml` |
| `2ba2d776e` | Merge PR #43 |
| `b05e14681` | vLLM v0.30 is the only base |

Net diff `9248c9d..b05e146`:

```
+47/-137  Dockerfile                     (now FROM vllm/vllm-openai:v0.30.0 + LABEL qwen38.base=v0.30)
removed   Dockerfile.v0.29
removed   Dockerfile.v0.30
+58/-428  README.md
+564/-0   docs/HISTORY.md                (the per-base history moves here)
+71/-250  docs/HOW-IT-WORKS.md
+19/-21   flash
removed   profiles/v0.29.env  profiles/v0.30.env
    -1    profiles/{context-1m,context,default,native,published,speed}.env
+18/-39   scripts/serve.sh
   1/-1   scripts/{download-weights,prepare-hybrid,prepare-mtp-graft}.sh
```

**Why it is worth doing:** three local patches are retired because the fixes are now *in* the base —
patch 3 (`vllm#50729`), patch 9 (`vllm#52775`), patch 11 (`vllm#55513`). Also removed: `PAD_M4`, the
`qwen38.fp8kv` image-label gate, the per-base splitting-op lists, `src/vllm_ple_mmap.py` keeping only
the v0.30 path. Each retired patch is a thing we no longer carry, rebuild, or drift-check.

**Already banked — do not re-do these.** Two preview-base changes are live on production now and must
survive the migration:

1. `COMPILE_CACHE` now defaults to `$HOME/.cache/vllm-compile`.
   **This one is NOT in v0.30** (`fork/main`'s `serve.sh` still has `COMPILE_CACHE="${COMPILE_CACHE:-}"`)
   → **re-apply the one-line default after switching base.** ~79 s of init engine per boot.
2. `--enable-prompt-tokens-details` — cherry-picked from `b130be782`. This one **is already in v0.30**
   (`fork/main:scripts/serve.sh` line 270) → the cherry-pick becomes a no-op, expect a trivial or
   empty conflict.

## c) Prerequisites

1. **A `/models`-class check is not needed; a disk check is.** Headroom measured 2026-09-29:
   `/` = 1.8 T, **337 G free (81% used)** — down from 371 G earlier the same day. A v0.30 build is a
   new ~21 GB image plus build cache; `docker system df` reported **168 GB of reclaimable images** if
   space gets tight (`docker image prune -a` — read the list first, it would also drop the rollback
   tags named in (e)).
2. **Freeze the rollback artifact first** (see (e)) — before any build.
3. **Switch the checkout** from `preview/zero-risk-wins-20260929` to `fork/main`, then re-apply the
   `COMPILE_CACHE` one-liner (b.1) and push. Do not merge `fork/main` into the preview branch: the
   `serve.sh` conflicts are exactly the label gate and the `BASE` plumbing.
4. **Rebuild with `./flash setup`** (or `docker build -t <tag> .`) and confirm the label:
   ```
   docker image inspect -f '{{index .Config.Labels "qwen38.base"}}' <tag>   # must print: v0.30
   ```
5. **Do not touch NVIDIA system packages or the driver.** Unrelated to this migration and explicitly
   out of scope; `docs-service` already carries a separate, documented driver-pin hazard.
6. Detector hygiene: the daily `update-check.sh` will keep printing `pin fp8_m4pad_patch.py : RETIRED`
   after the base moves — that is correct and expected (the patch is gone upstream). It must not be
   read as a blocker.

## d) Risk — the label gate

```bash
# fork/main:scripts/serve.sh lines 180-185
BASE="$(docker image inspect -f '{{index .Config.Labels "qwen38.base"}}' "$IMAGE" 2>/dev/null || true)"
if [ "$BASE" != "v0.30" ]; then
  echo "!! $IMAGE is ${BASE:+a '$BASE'-base build, }${BASE:-missing or unlabeled}; \
this recipe needs the v0.30 image: docker build -t $IMAGE .  (or ./flash setup)"; exit 1
fi
```

`flash` and `serve.sh` **refuse to start an image whose label is not `v0.30`**. Consequences:

- Pulling `fork/main` without rebuilding is not a partial upgrade — it is a **dead service**. The
  label gate is the *only* thing standing between "new script, old image" and a working boot, and it
  is deliberately a hard failure rather than a silent half-work.
- Both entry points recreate the container (`docker rm -f` then `docker run`), so the refusal happens
  at the moment of a restart, i.e. the next reboot or manual launch.

### The image inventory is thinner than it looks

Measured on the host — **only `candidate` carries the `preview` label**:

| tag | `qwen38.base` | used by |
|---|---|---|
| `qwen38-flash-dgx:candidate` | **`preview`** | **the running container** |
| `qwen38-flash-dgx:latest` | *(none)* | container `qwen38-flash-rollback` (Exited 0) |
| `qwen38-flash-dgx:pre-update-20260927` | *(none)* | — |
| `qwen38-flash-dgx:rollback-20260904` | *(none)* | — |
| `qwen38-flash-dgx:pre-detopk-20260903` | *(none)* | — |

The label-less tags came from a Dockerfile that predates the label, so on the **preview** base they
still run (that `serve.sh` reads the label only to pick a splitting-op list, and accepts
`BASE=preview|v0.29` as an override — it has **no gate**). But the *running production image and its
only rollback copy are the same tag*. A build that reuses the `candidate` tag therefore destroys the
rollback path, which is what (e) prevents.

## e) Rollback

**Before building anything**, freeze the current image under a new immutable tag:

```bash
docker tag qwen38-flash-dgx:candidate qwen38-flash-dgx:preview-20260929
docker image inspect -f '{{index .Config.Labels "qwen38.base"}} {{.Id}}' qwen38-flash-dgx:preview-20260929
# expect: preview sha256:<same id as the running container>
```

Rollback is then two moves — image **and** script together, never one alone:

```bash
docker stop qwen38-flash && docker rename qwen38-flash qwen38-flash-v030-failed
docker rename qwen38-flash-rollback qwen38-flash && docker start qwen38-flash   # pre-v0.30 container
cd <checkout> && git checkout preview/zero-risk-wins-20260929                   # pre-v0.30 serve.sh
```

Because the v0.30 `serve.sh` refuses a `preview` image, **restoring the code without restoring the
image (or the reverse) leaves the service down.** Keep the pair in one step.

### Recommended verification order (production untouched until the last step)

1. Build under a **new tag** — never `qwen38-flash-dgx:candidate`:
   `docker build -t qwen38-flash-dgx:v030-20260929 .`
2. Smoke-test with a **different container name and port**, so the gate and the
   `docker rm -f` cannot touch the live container:
   `NAME=qwen38-flash-v030 IMAGE=qwen38-flash-dgx:v030-20260929 PORT=18301 scripts/serve.sh`
3. Confirm on the test instance: health 200, a real completion through LiteLLM, KV-cache and
   context numbers comparable to the current boot, `prompt_tokens_details` present in `usage`.
4. Only then switch production: stop, rename, start with the v0.30 image and the `fork/main` checkout.
5. Re-run `update-check.sh` afterwards; the only expected line change is
   `repo : no drift (b05e1468)`.

## Out of scope / do not do in this migration

- Do not `git push` to `blazux` — the fork is the only writable remote, and its push URL is
  intentionally disabled for `origin` in the workstation clone.
- Do not restart `qwen38-flash` before the reviewed steps above; it owns the GPU pool at
  `gpu-mem 0.80` and its restart is the single most disruptive action available on this host.
- Do not treat `pin fp8_m4pad_patch.py : RETIRED` as a blocker (c.6).
