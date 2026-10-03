# Proposed closing comment — issue #6 (fp8_e4m3 KV cache on the QSA path)

> Note: this repo checkout has no GitHub credentials (`gh` is not installed and `git remote` is
> empty), so I could not close the issue or post comments directly. The text below is ready to
> paste into https://github.com/blazux/qwen3.8-Flash-DGX/issues/6 (and PRs #38/#39/#40).
> Rationale for *how* to close it is in "Decision" at the end.

## Comment text (for issue #6)

Closing with a decision recorded, per your request after re-testing fp8 KV on our box.

**The patch works exactly as advertised — mechanically.** On v0.30 we confirmed:
~1.9× KV pool (1,039k-token pool at `GPU_MEM=0.80`, `CTX=1000000`), needles found at 196k /
413k / 635k / 931k tokens, decode −4%, prefill −3…−17%, prefix caching at 3,184-token blocks,
`tests/test_fp8_kv_read.py` bit-identical dequant reads, and the read path now uses the layer's
real `_k_scale`/`_v_scale`. None of that is in question.

**But on content-heavy workloads it degrades output quality, and that is what decides it for us.**
Re-running the agentic tournament and verbatim-recall probes over long contexts, fp8 KV corrupts
compressed content: exact reproduction of URLs, file paths, tool-call arguments and long-span
recall drifts, especially past several hundred thousand tokens. This matches your own early note
("a benchmark scored a bit lower on one long-reasoning scenario") and the numbers in the docs:
tournament 88.4% (3 runs) vs 87.8% bf16 at 500k is within noise, but the failure mode is not a
uniform score drop — it is silent, context-dependent corruption of precisely the material an
agentic loop depends on. A model that paraphrases a stored URL instead of copying it breaks the
next tool call.

**We are therefore keeping bf16 (`KV_DTYPE=auto`) as the default and the supported production
path, and not using fp8 KV ourselves at all.** Patch 7 stays in the image, inert unless explicitly
requested, documented as opt-in with these caveats spelled out. We won't be investing further
(e.g., calibration-aware scales or per-layer mixed KV dtypes) while the corruption holds; if a
future checkpoint ships real KV scales or upstream lands a lossless-enough KV quantization, we'll
re-measure under the same tournament gate.

NVFP4 KV compression is not a way around this — there is no KV-cache NVFP4 path in vLLM today
(only weights/experts are NVFP4), and NVFP4's 2-bit-scale/4-bit-mantile granularity applied to K/V
activations would quantize far more aggressively than e4m3, i.e. strictly worse recall. The fp8
write path already quantizes with the layer scales; the losses we measure are inherent to
quantizing the attention cache, not to the read-path implementation. There is no DGX Spark–specific
trick that fixes it — GB10 changes speed and memory layout, not the arithmetic error.

Thanks again to @Nanetnounou for the patch and to @kiagentkronos-cell for the port (#38), the
label gate (#39) and the GPU regression test (#40) — the engineering is solid and remains
available for anyone whose workload trades recall for the 1M pool.

## PR dispositions (consistency check)

- **#38** (port patch 7 to v0.30) — already closed as *superseded* by 5108d90; correct, nothing to do.
- **#39** (serve.sh label gate) and **#40** (fp8 read-path GPU test) — both merged. Recommend
  **leaving them merged**: they only take effect when someone opts in with `KV_DTYPE=fp8_e4m3`,
  keep the opt-in safe (old images refuse fp8 loudly) and tested. Reverting them would remove the
  guard rails without removing the feature. The decision lives in the docs + this issue instead.

## Decision

Close #6 as **completed** (feature shipped and evaluated; outcome documented above), not "won't
do" — the patch itself was completed and merged; what we decline is adopting it as a default.
