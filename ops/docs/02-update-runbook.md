# Update and rollback runbook

**Applies to:** this recipe serving Qwen3.8-Flash-Next on one GB10 host
**Last verified:** 2026-09-11
**Design rule:** never rebuild on a hunch. Update only when one of the four detection axes in
§1 reports drift.

---

## 1. Detection — four axes, all read-only

Run `scripts/update-check.sh` (safe, no mutation), or the commands below by hand.

### 1.1 Repository

```bash
git rev-parse HEAD
git ls-remote origin -h refs/heads/main
```

Equal → nothing upstream. Unequal → read the new commits before rebuilding; in this project the
default commit only *adds optional switches*, so a new commit is not by itself a reason to move.

Also check the tree is clean: `git status --porcelain` must be empty.

### 1.2 Base image

```bash
grep '^FROM' Dockerfile
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:vllm/vllm-openai:pull" \
        | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -D - -o /dev/null -H "Authorization: Bearer $TOKEN" \
     -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
     https://registry-1.docker.io/v2/vllm/vllm-openai/manifests/<tag> | grep -i docker-content-digest
```

- Compare the registry digest with the digest pinned in `Dockerfile`. Equal → the base has not
  moved, whatever the tag's *date* suggests.
- Resolve the manifest list before trusting a tag name: the index children are
  `-arm64-cu130` and `-amd64-cu130` under the plain tag, plus a standalone `-arm64-cu129`.
  Confirm which child your architecture actually pulls.
- Do not infer drift from `RepoTags` on a local image — that is a local artifact.
- `docker manifest inspect` fails with 401 without an explicit bearer token; use the curl form.

### 1.3 Externally pinned kernel files

The deterministic top-k kernel and the M%4 padding tool are fetched at build time from a
third-party repository at two pinned commits (`ARG KDET_SHA`, `ARG KM4_SHA` in `Dockerfile`).

**Compare file content, never commit dates:**

```bash
pin=$(grep -m1 'ARG KDET_SHA=' Dockerfile | cut -d= -f2)
for f in patches/kernel-det/topk_det.cu patches/kernel-det/persistent_topk.cuh \
         patches/kernel-det/build_det.py patches/kernel-det/bindings_det.cpp \
         patches/kernel-det/torch_utils.h tools/determinism/qsadet_patch.py; do
  a=$(curl -sL "…/$pin/$f"   | sha256sum | cut -c1-12)
  b=$(curl -sL "…/main/$f"   | sha256sum | cut -c1-12)
  printf '%-44s %s\n' "$f" "$([ "$a" = "$b" ] && echo same || echo "DRIFT $a $b")"
done
```

A pin can be months old, sit byte-identical to the branch tip, and need no change — while the
hosting repository shows heavy daily activity in unrelated directories. Only a content mismatch
is actionable.

### 1.4 Served checkpoint

```bash
curl -s https://huggingface.co/api/models/RadixArk/Qwen3.8-Flash-Next-NVFP4 | tr ',' '\n' | sed -n 's/.*"sha":"\([0-9a-f]*\)".*/\1/p'
```

Compare against the local snapshot directory name. Derived snapshots carry a suffix
(`<sha>-fp8hybrid`); strip the suffix before comparing. A `NOT_FOUND` from the API means an
unauthenticated request, not a deleted repository.

---

## 2. Build mechanics

**Cost:** `docker build -t <repo>:candidate .` ≈ 1–2 min with a warm cache; first build downloads
a ~20 GB base image. Boot is the expensive part: **12–15 min** (§4).

**Fail-loud property.** Each patch is guarded — an exact-match substitution with the target
literal, a regex that must match, a pinned commit hash, a content assertion, or
`python3 -c "import ast; ast.parse(...)"` after editing. If an upstream vLLM stops matching, the
build fails rather than producing an image that silently mis-serves. That property is what makes
rebuilding on a newer base survivable. Expect **10 failures**, one per patch, each requiring a
re-derivation rather than a re-run.

**Patch inventory and durability**

| # | patch | kind | survives a vLLM bump? |
|---|---|---|---|
| 1 | PLE table from NVMe (`mmap`) | custom op + splitting op | only if vllm#54129 merges first |
| 2 | GB10 FLA fixes (smem gate, `num_warps`) | substitution | likely |
| 3 | prefix-cache state restore fix | substitutions, guarded by marker | maybe, if still needed |
| 4 | QSA ops + prefix-caching flag plumbing | multi-hunk | low |
| 5 | QSA top-k routing | substitution | no, if #55122 merged |
| 6 | MTP split + draft vocabulary | `__init__` injection + rewrite | low |
| 7 | FP8 hybrid side layers | config overlay + loader guard | medium |
| 8 | deterministic top-k kernel | external pin + source patch + `.so` build | no |
| 9 | GEMM M%4 padding | external pin + overlay | medium |
| 10 | reduced draft vocabulary | `__all__` insertion + loader guard | low |

**Never copy** `lanes/sglang-tp2/community-fix/sm121_varlen.py` from any AGPL-licensed variant
of this recipe: this repository is Apache-2.0 and that file is the one AGPL component in the
tree. Clean-room re-implementation only.

**Candidate discipline.** Build with an explicit tag (`:candidate`), boot it only inside a
declared window (§4), and promote to `:latest` only after §5 passes.

---

## 3. Update decision rules

| trigger | action | expected benefit | risk |
|---|---|---|---|
| repo commit moved, patches intact | rebuild, restart in a window | small; read the commits first | low |
| base image digest moved | re-derive the 10 patches, full §5 | the fix that motivated the check | medium-high |
| pinned kernel files differ | bump the pin, rebuild | behaviour fix or upstream sync | medium |
| checkpoint re-published | re-download, re-run `prepare-hybrid.sh`, full §5 | possibly quality | high — re-run the probe |
| nothing moved | do nothing | none | — |

Two structural facts that make a "latest vLLM" update expensive rather than routine:

1. Upstream `main` exposes this model as `vllm/models/qwen4_exp/…`, while the model-specific
   base image used here exposes it as `vllm/models/qwen3_8_flash_next/…`. Every patch in this
   recipe targets the latter path, so a base bump is a **port**, not a re-run.
2. The defects these patches work around are still open upstream (#55122, #54129, #54173,
   #54846), so a newer vLLM does not contain the fixes and the patches cannot be dropped.

---

## 4. Starting, restarting, rolling back

### 4.1 The trap

`scripts/serve.sh` contains `docker rm -f "$NAME"` (`NAME` defaults to `qwen38-flash`). Running
it destroys the current container **including the one you intended to keep as a rollback
target**. Retain it first — rename, then stop:

```bash
docker rename qwen38-flash qwen38-flash-pre-<label>   # keep the container, and with it the
                                                     # exact env, args and mounts
docker stop qwen38-flash
```

### 4.2 Roll back

```bash
scripts/rollback.sh --check        # read-only report: targets, images, flags, snapshots, free disk
scripts/rollback.sh --yes          # tag current image, stop, memory gate, rename, start, health
```

Behaviour: the previous container is **renamed, never deleted**; if host memory does not recover
after the stop, the original container is restarted and the attempt aborts; every failure path
prints an executable reverse command and the live container names.

**Measured cost:** 12 min 21 s for `docker start` of an existing container, 14 min 59 s for a full
recreate. Weight loading alone is 576–641 s from NVMe; there is no shortcut. Plan on a 13–15
minute service window.

### 4.3 Asset retention

- Tag every image you might roll back to (`docker images` shows `<none>` for images that are
  only reachable from a stopped container — those are one `docker container prune` away from
  being gone).
- A rollback target that lost its image needs a rebuild, which is a different, slower operation.
- Never delete the renamed `-pre-*` / `-bad-*` container until a soak has passed.

---

## 5. Post-update verification — the quality gates

| check | command | pass condition |
|---|---|---|
| greedy determinism | `scripts/greedy-probe.sh` | 6 runs per prompt with identical ids and `prompt_logprobs` |
| multimodal single image | `scripts/vision-probe.sh` | correct answer; the two-image variant may fail |
| multi-turn latency | `scripts/ttft-probe.sh` | turns 2+ ≈ 1.5 s; a 10–15 s turn 2 means caching is off or mis-keyed |
| throughput | client of choice | within ~10% of §6 |
| prefill speed | long-prompt run | near the §6 figure — the cheapest early warning for a broken mmap gather |
| acceptance length | `docker logs -f` | > 1.5; near zero means the draft model is broken |
| KV pool | log line `GPU KV cache size: N tokens` | compare with §6 |
| smoke | `scripts/smoke-test.sh` | all steps |
| memory trend | `docker exec <c> grep VmSwap /proc/1/status` | not climbing monotonically |
| kernel refusals | `journalctl -k --since -1h \| grep -c NV_ERR_NO_MEMORY` | 0 |

Any failure → roll back (§4.2); do not debug a misbehaving image while it serves production.

---

## 6. Baselines to compare a rebuild against

Recorded from the running deployment (single GB10 host, hybrid, MTP=2, prefix caching, 262k
context, `gpu-memory-utilization 0.80`):

| metric | value |
|---|---|
| engine KV cache size | 647,394 tokens (2.47× at 262,144/request) |
| prefix cache hit rate | 91.6% |
| mean acceptance length | 1.7–3.0, typical ~2.1 |
| per-position acceptance | ~0.64 / ~0.44 |
| decode, single stream | 29–54 tok/s |
| decode, two streams | ~25 tok/s per stream |
| prefill, cache-warm | 15.9k tok/s |
| PLE gather, decode batches | 1.5–5.7 ms/op |
| PLE gather, prefill batches | 190–334 ms/op |
| greedy probe | identical ids and logprobs over 6 runs |
| boot time | 12–15 min |
| host `MemAvailable` under load | 2.8–3.7 GiB |
| kernel allocation refusals | 3 on 2026-09-10, 0 in the following 24 h |

---

## 7. Upstream changes to watch

| item | why it matters |
|---|---|
| vllm#55122 deterministic `persistent_topk` | if merged, patch 8 can become a version pin |
| vllm#54129 mmap PLE table | if merged, patch 1 becomes upstream |
| vllm#54173 GDN + prefix caching | currently mitigated; a regression would resurface the crash |
| vllm#54846 FP8 KV with QSA | would double the KV pool, at the documented quality cost |
| the model-specific base image digest | the only axis that forces patch re-derivation |
| new GB10 performance work (tile-union prefill, MoE finalize switch) | prefill is the measured bottleneck here |

`scripts/update-check.sh` on a daily schedule covers the first, second and last of these.

---

## Appendix A — reading the numbers in §6

Two measurements deserve their procedure spelled out, because both are easy to get wrong.

**Throughput.** Measure decode speed only after the first 20 generated tokens: the first tokens
of a turn include prefill and, with speculative decoding, a low acceptance rate. Report the
median of at least five runs, not the mean, and state whether prefix caching was warm — a
cache-warm run can be several times faster than a cold one and the two are not comparable.

**Prefill and the PLE gather.** The engine logs PLE statistics every ~30 s:

```
docker logs <container> 2>&1 | grep 'PLE mmap stats' | tail
```

Two operating points appear and must not be averaged together: decode-sized batches (a few
milliseconds per operation) and prefill batches (one to two orders of magnitude slower per
operation, but far fewer operations). A regression in the mmap gather shows up first in the
prefill line, and long-prompt prefill speed is the cheapest single early warning for it.

**Memory.** `MemAvailable` is reported in kB. Watch its trend across a whole cycle, not a single
sample, and cross-check `VmSwap` of the engine process and `NV_ERR_NO_MEMORY` in the kernel log
(`journalctl -k`) — the kernel log is where an allocation refusal appears, not in engine logs.
