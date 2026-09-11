# Options evaluated and not adopted

Every entry was measured on this hardware by this project or by an external report reproduced
here, then rejected on evidence. Recorded so the same three questions are not re-litigated.

| option | measured effect | decision |
|---|---|---|
| `MTP=3` | +7% decode (38.5 → 41.2 tok/s), tournament 44/51 vs 45/51 | **not adopted** — quality-first posture; see the acceptance analysis below |
| `MODE=hybrid-mtp` | KV pool +22%, weights −3.9 GiB; the source calls decode "unchanged" in one place and lists 33.0 tok/s against 38.5 in another | **not adopted** — the source's two statements disagree, and KV headroom is not the constraint here (peak use 52–67% of a pool already at 2.47×) |
| pure `nvfp4` (drop hybrid) | −19% decode, marginal quality edge in external reports | **not adopted** — hybrid is the recommended default and scores identically |
| FP8 KV cache | ~×1.9 KV pool, −10% decode, −30% prefill, one scenario lost | **not adopted** — precision first; the recipe's own note is that it is not worth it |
| staged gather + `FULL_DECODE_ONLY` graphs | ~+15% single-stream, ~0% aggregate | **not adopted** — see analysis below |
| rebuild everything to "latest" | no measurable change available | **not adopted** — see `03-dependency-drift.md` |
| YaRN to 500k context | more context, less concurrency | **not adopted** — workloads here fit 262k and concurrency matters more |

---

## MTP=3 — the analysis that settled it

Observed draft acceptance on live traffic: position 1 ≈ 0.64, position 2 ≈ 0.44. A third draft
position decays again (≈0.28), which adds roughly `0.64 × 0.44 × 0.29 ≈ 0.08` accepted tokens
per step on top of an acceptance length of ~2.1 — i.e. about +7%, matching the recipe's measured
figure, or **+2–3 tok/s** on a 35–45 tok/s stream.

Decisive detail: this deployment's measured cost centre is **prefill**, where the PLE table
gather costs 190–334 ms per operation on long prompts. A speculative-decoding knob cannot touch
that phase. A 13-minute service window plus a full verification cycle for +2–3 tok/s in the
phase that is not the bottleneck is not a good trade.

Speculative decoding is output-preserving by construction — every drafted token is verified by
the target model — so this was never a quality question, only a value question.

## Staged gather + FULL CUDA graphs — why the advertised gain does not apply

External measurements report a large gain from a "staged gather" that reads PLE rows into a
fixed GPU buffer so decode can run under full CUDA graphs. Two findings make that inapplicable
here:

1. **The staging is already implemented in this recipe.** The in-tree mmap module documents and
   implements "CPU dedup → persistent pinned staging buffer → async H2D → GPU-side inverse
   expansion, plus a no-threadpool fast path for decode-sized batches", and the live engine
   reports 1.5–5.7 ms/op on decode-sized batches, which is what a working staging path looks
   like. The external variant differs in *placement* (model input preparation rather than a
   custom op registered as a splitting op), not in whether the work is staged.
2. **The remaining half of their gain is graph replay, which is latency-only.** Their own load
   measurements show aggregate throughput unchanged. A fan-out workload — several concurrent
   agents — sees the aggregate, not the single-stream number.

The port would additionally require removing the PLE lookup from the splitting-op list (full
graphs and splitting ops are incompatible by design), re-deriving a hook written against a
different vLLM build, and asking full graph capture to absorb the deterministic top-k extension,
the hybrid FP8 path, speculative decoding and prefix caching simultaneously. Determinism — the
property this configuration is chosen for — is the first thing at risk, and the acceptance gate
for it costs a boot per attempt.

## Retracted claims

Kept so they do not return as "known facts".

| claim | status |
|---|---|
| "Server defaults leak `temperature=1.0`, an accuracy hazard" | **retracted.** Those are the publisher's recommended *thinking-mode* values, and this deployment serves thinking mode. The only residual is a client that disables thinking without setting sampling parameters. |
| "Port the staged PLE gather for +35% decode" | **retracted.** The staging is already shipped; the remainder is latency-only. See above. |
| "One recipe's checkpoint keeps the n-gram table at higher precision" | **not supported.** Both checkpoints keep the PLE table in FP8; the difference is in the MTP path and quantisation bookkeeping. |
| "One approach is just the official image plus a handful of patches" | **incorrect characterisation** of a source that was summarised rather than read. The comparison that matters is the one in the audit. |

## Figures deliberately excluded

Two documented third-party numbers were examined and not reproduced — a tool-use accuracy
percentage from a discussion thread and an independent reproduction that could not be
re-confirmed from its published notes. Both are plausible but unverifiable from this position,
and neither is load-bearing for any decision above; a decision that needed one would require a
measured run instead.
