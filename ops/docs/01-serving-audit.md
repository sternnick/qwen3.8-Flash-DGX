# Serving audit — Qwen3.8-Flash-Next on a single DGX Spark host

**Date:** 2026-09-11 · **Scope:** the deployment of this recipe on one GB10 host
**Method:** every value below was read from the running host (container inspection, engine
logs, kernel log, `/proc`), from the container image filesystem, or from upstream registries
and issue trackers. Where a number could not be reproduced it is marked *unverified* and is
not used in any conclusion.

---

## 1. Configuration under audit

| item | value |
|---|---|
| recipe | `blazux/qwen3.8-Flash-DGX` at `bd60fcb` |
| image | built from that tree, 2026-09-09 |
| vLLM in image | `0.1.dev20073+g08e685d198` (aarch64, CUDA 13.0) |
| base image | `vllm/vllm-openai:qwen38-flash-next@sha256:fc120ece…05bf8` |
| checkpoint | `RadixArk/Qwen3.8-Flash-Next-NVFP4`, snapshot `7b719225242a…`, fp8-hybrid variant |
| mode | `MODE=hybrid` (NVFP4 routed experts + blockwise-FP8 side layers) |
| speculative | `mtp`, `num_speculative_tokens: 2`, draft vocabulary 65,536 |
| KV cache | `auto` → bf16; pool 647,394 tokens = 2.47× a 262,144-token request |
| context | 262,144 native, no rope scaling (YaRN off) |
| graphs | `cudagraph_mode=PIECEWISE`, PLE lookup registered as a splitting op |
| caching | prefix caching enabled; deterministic top-k enabled (`VLLM_QSA_DET_TOPK=1`); `EXACT_TOPK=0` |
| scheduling | `max_num_seqs=8`, chunked prefill 8192 |
| memory | `--gpu-memory-utilization 0.80` |
| host | kernel 6.17.0-1032-nvidia, driver 580.173.02, Docker 29.2.1 |
| uptime | 21 h at audit time, container restart count 0 |

## 2. Measured runtime behaviour

| metric | observed |
|---|---|
| prefix cache hit rate | 91.4–91.9%, stable over 20 min |
| speculative acceptance length | 1.7–3.0, typical ~2.1 |
| per-position draft acceptance | position 1 ≈ 0.64, position 2 ≈ 0.44 |
| decode throughput | 29–54 tok/s single stream; ~25 tok/s/stream at two concurrent requests |
| prefill throughput | 15.9k tok/s on a cache-warm prompt, 0.87–3.0k tok/s cold |
| GPU KV utilisation | 0–67% (peak at two long concurrent requests) |
| PLE table gather, decode batches | 1.5–5.7 ms/op |
| PLE table gather, prefill batches | 190–334 ms/op, i.e. several seconds per long prompt |
| xgrammar FSM errors | 1 in 6 h, non-fatal (one request retried) |
| kernel allocation refusals | 3 × `NV_ERR_NO_MEMORY` on 2026-09-10; 0 in the 6 h preceding the audit |

Interpretation: the box is latency-bound on **prefill** (dominated by the PLE table gather on
long prompts), not on decode. Prefix caching is doing most of the heavy lifting for repeated
agent prompts.

## 3. Deterministic decoding

The deterministic top-k path (`VLLM_QSA_DET_TOPK=1`, built from a pinned out-of-tree kernel)
was tested with a greedy probe: three prompts × six runs at `temperature=0`, comparing
`prompt_token_ids` and `prompt_logprobs`.

*Result:* all six runs per prompt returned byte-identical token ids and identical first-token
logprob. The upstream non-deterministic top-k defect (vllm#51782) is therefore genuinely fixed
here, not merely hidden.

## 4. Multimodal capability

The README states that vision was not exercised, but the served chat template is the
`qwen3_vl`-shaped one and vision requests work in practice:

| test | result |
|---|---|
| synthetic 2-image request, "what's in the image?" | correct: "a red square and a blue circle" |
| synthetic 1-image request | correct colour |
| two images in one request | fails — `Invalid piece of image length 2708` (mm processor), and the traceback is misclassified as `ValueError`, which hides the real cause |

Conclusion: single-image input is functional; multi-image input is not. Worth an upstream
issue about the error classification.

## 5. Sampling parameters

The engine logs that `generation_config.json` overrides the defaults to
`temperature=1.0, top_k=20, top_p=0.95`. Those are exactly the values the model publisher
recommends for **thinking mode** (non-thinking mode is documented as `temperature=0.7`,
`top_p=0.80`, `presence_penalty=1.5`), and this deployment serves thinking mode: the served
chat template defaults `enable_thinking` to true, the reasoning parser is `qwen3`, and a
thinking budget is configured. The server defaults are therefore correct as-is.

Residual, narrow: a client that sends `enable_thinking: false` **without** sampling parameters
inherits thinking-mode sampling instead of the non-thinking recommendation. Handle per request
if such traffic ever matters; a global pin would move the default configuration off the
publisher's recommendation.

## 6. Host memory headroom

| sample | value |
|---|---|
| `MemAvailable` during serving | oscillates 2.8–3.7 GiB (recovered on its own between samples) |
| zram | 8.5–9.1 GiB used |
| swapped engine pages | ≈2.2 GiB (`VmSwap`) |
| kernel refusals | 3 × `NV_ERR_NO_MEMORY` on 2026-09-10, no OOM kill |

At `gpu-memory-utilization 0.80` there is no host-side reserve floor and no watchdog: under a
burst the driver can refuse allocations rather than the OOM killer acting. This is the single
largest remaining risk to availability on this configuration, and it is invisible in engine
logs — it has to be watched at the host level (`scripts/memwatch.sh`).

## 7. Known issues and this deployment's exposure

**Open upstream, mitigated by what we run**

| defect | mitigation in place |
|---|---|
| vllm#51782 non-deterministic, candidate-dropping top-k | deterministic kernel, verified above |
| vllm#54129 / #53899 / #54371 / #54070 PLE table offload variants all unmerged | in-tree mmap-from-NVMe patch |
| vllm#54173 GDN + prefix caching crash (`precopy_mamba_align_fused_kernel`) | block-size fix + guarded mamba state copy; prefix caching has run 21 h at a 91.6% hit rate without faulting |
| `torch.compile` duplicating the PLE op (~50 GiB) | avoided: piecewise graphs with the lookup as a splitting op |
| FlashInfer CUTLASS NVFP4 MoE has no path for blockwise-FP8 experts | avoided: triton/marlin grouped MoE |
| driver 590.x CUDA-graph deadlock on unified memory | host runs the 580.x line |

**Open upstream, accepted**

- vllm#55122 (the deterministic top-k kernel) is still unmerged — the fix is out-of-tree, so a
  future vLLM will not absorb it; a vLLM bump re-derives it.
- vllm#54846 (FP8 KV with QSA) unmerged — irrelevant here, bf16 KV is deliberate.

**Not applicable to this configuration**

- vllm#54629 long-prefill hang at TP4 + expert parallel (single GPU here).
- The ModelOpt MTP index and `FP8_BLOCK_SCALES` problems reported by other recipes apply only
  to checkpoints that quantise the MTP path; in this checkpoint `mtp.*` stays bf16.

**Fixed upstream:** vllm#50729 (Mamba overlapping state-copy race) is merged, which makes one
guard in this recipe partly redundant. Harmless.

**Chat template:** the reported truncation bug (vllm#52775, fixed in #50223) does not affect
this deployment — the served template was inspected and is complete, and long prompts are
processed without truncation.

## 8. Conclusions

1. The configuration is at the highest scoring point of the recipe's own evaluation
   (deterministic kernel + reduced draft vocabulary) and behaves as advertised.
2. Decode speed is not the constraint; long-prompt prefill and host memory headroom are.
3. Two operational gaps remain, both outside the model: no host memory reserve/watchdog
   (mitigated in monitoring only), and a vLLM version bump that is a re-port rather than an
   upgrade (see `03-dependency-drift.md`).

## Appendix — commands used

```bash
# configuration
docker inspect <container> --format '{{join .Args " "}}'
docker inspect <container> --format '{{range .Config.Env}}{{println .}}{{end}}'
# behaviour
docker logs --since 6h <container> 2>&1 | grep -E "Prefix cache hit rate|SpecDecoding metrics"
docker logs <container> 2>&1 | grep -m1 "GPU KV cache size"
# kernel-level allocation refusals
journalctl -k --since -48h | grep -c NV_ERR_NO_MEMORY
# memory headroom
grep MemAvailable /proc/meminfo; swapon --show; awk '/VmSwap/{print}' /proc/<pid>/status
# determinism probe
scripts/greedy-probe.sh                 # 6 runs per prompt, compares ids and logprobs
```
