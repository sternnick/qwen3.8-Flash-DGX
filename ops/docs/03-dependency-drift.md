# Dependency drift — every artifact this recipe consumes

**Snapshot:** 2026-09-11 · all values read directly, none inferred
**Purpose:** a reference point to diff the next check against, and the evidence that the
"rebuild everything to latest" question has a specific, testable answer.

---

## 1. Status table

| dependency | pinned as | upstream at check time | drift |
|---|---|---|---|
| `blazux/qwen3.8-Flash-DGX` | `bd60fcb` | `bd60fcb1b…` (`origin/main`) | none |
| `vllm/vllm-openai:qwen38-flash-next` | digest `fc120ece…05bf8` (`Dockerfile`) | registry `docker-content-digest` identical; tag last published 2026-08-26 | none |
| deterministic top-k kernel, 6 files | `ARG KDET_SHA=e0ef69d4…` | all 6 files byte-identical to the branch tip | none (content) |
| GEMM M%4 padding tool | `ARG KM4_SHA=d9705bde…` | byte-identical to the branch tip | none (content) |
| `RadixArk/Qwen3.8-Flash-Next-NVFP4` | snapshot `7b719225242a…` | api `sha` = `7b71922524…`, `lastModified` 2026-08-26, 419 files, 135,253,622,894 B | none |
| `Inferact/Qwen3.8-Flash-Next-NVFP4` (hybrid-mtp donor) | via `prepare-mtp-graft.sh` | 2026-08-26, 34 files, 182.8 GB | none |
| `Qwen/Qwen3.8-Flash-Next` (base weights) | reference only | 2026-08-27, 144 files, 360 GB | none |
| host GPU driver | 580.173.02 | the 580.x line is what the README recommends (590.x has a unified-memory CUDA-graph deadlock) | compliant |

**Verdict at check time: no drift on any axis.** A rebuild performed today would produce the
same software.

---

## 2. Why "latest everything" is not a version bump

The decisive asymmetry:

| | path inside the tree |
|---|---|
| vLLM `main` today | `vllm/models/qwen4_exp/nvidia/ple_layer.py` — present |
| this recipe's base image | `vllm/models/qwen3_8_flash_next/nvidia/ple_layer.py` — present |
| `qwen3_8_flash_next/…` on `main` | **absent** |

Every patch in `Dockerfile` targets the second path. The model-specific image is therefore not
"an older vLLM" but a differently-shaped tree, and moving to a general release (0.29.0) or to a
current nightly means re-deriving all ten patches and both kernel pins against a renamed model
implementation — a port, with its own verification cycle.

Meanwhile the defects these patches compensate for are **all still open upstream**, so a newer
vLLM contains none of the fixes and none of the patches can be dropped.

| referenced by this recipe | status on 2026-09-11 |
|---|---|
| vllm#55122 deterministic `persistent_topk` | open |
| vllm#54129 disk-backed PLE table | open |
| vllm#54173 GDN + prefix caching crash | open |
| vllm#54846 FP8 KV with QSA | open |
| vllm#50729 Mamba state-copy race | merged (one local guard now partly redundant) |

## 3. Checkpoint metadata, for the record

| checkpoint | quantisation declared | PLE table | MTP path | size |
|---|---|---|---|---|
| `RadixArk/…NVFP4` (served here) | `NVFP4`, experts quantised; `self_attn`, `linear_attn`, `shared_expert`, `ple*` excluded | FP8 rows (`float8_e4m3fn`), 47.7 GiB | bf16, from the base weights | 135.2 GB |
| `nvidia/…NVFP4` (other recipes) | `MIXED_PRECISION`, `group_size: 16`, `FP8_PB_WO` + `FP8_BLOCK_SCALES` | FP8, same class | FP8 block scales | 141.6 GB |

Both keep attention and the shared expert out of quantisation and both keep the n-gram table in
FP8; the difference is in the MTP path and the quantisation bookkeeping format, not in the
precision of the layers that produce the answer. Claims of a PLE precision advantage for either
side are not supported by the metadata.

## 4. Method notes (so the next check does not repeat these mistakes)

1. **Content over dates.** Compare hashes of the files at the pinned commit against the branch
   tip. A pin that is byte-identical to `main` needs no change even if the hosting repository
   has commits from today — those are almost always in notes/analysis directories.
2. A per-path commit listing returns the commits *touching that path*; treating the second entry
   as "latest" produces false drift reports. Query the branch tip directly.
3. Never conclude "repository deleted" from an API error without authenticating first.
4. Never conclude image drift from `RepoTags` on a local image.
5. In `awk`/`sed` one-liners over mount paths, `s|/-$||` is a regex mistake (`-` is literal):
   use `s|/*$||`. Both mistakes silently reported "unknown" in an earlier pass of this check.
6. `MemAvailable` is in kB; a GiB conversion divides by 1048576, not by 2³⁰ bytes.

## 5. Reproducing this table

`scripts/update-check.sh` performs axes 1, 2, 3 and 4 read-only and writes
`drift=0|1` plus a per-axis log line. It performs no `git fetch`, no build and no container
operation, and is safe to run from a daily schedule.
