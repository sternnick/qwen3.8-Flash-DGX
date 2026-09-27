# Qwen3.8-Flash-Next parser investigation — 2026-09-27

Host: aiadmin@192.168.11.15 (gx10-444d). Repo: /home/aiadmin/projects/qwen38-flash-dgx/qwen3.8-Flash-DGX.
Fork: github.com/sternnick/qwen3.8-Flash-DGX. Production untouched.

## 0. State (verified 2026-09-27 ~11:00 UTC)

| item | value |
|---|---|
| production `qwen38-flash` | **Up**, image `qwen38-flash-dgx` (`0a693ef0a127`, old bd60fcb line), `/health` HTTP 200 |
| production flags | `--tool-call-parser qwen3_coder --reasoning-parser qwen3 --enable-auto-tool-choice` (no `--chat-template`) |
| candidate image | `qwen38-flash-dgx:candidate` = `ef3c3379d95d` (built from 9248c9d, patches 12+13 + 14–18) — **present** |
| candidate container | `qwen38-flash-candidate-failed` — **exited 0** (graceful shutdown 10:20:04 UTC) |
| candidate flags | same parsers **plus** `--chat-template /qwen38/chat_template.jinja` (mounted from host) |
| GPU | GB10, `VLLM::EngineCore` holds **99,878 MiB**; production is the only text model. A second boot is impossible (memory record 16e60a1c: parallel boot would OOM/swap). |

## 1. Parser comparison [experiment 2] — DONE (offline, CPU)

`vllm/tool_parsers/__init__.py`: only two Qwen tool-parser keys exist —
`qwen3_coder` (line 173) and `qwen3_xml` (line 177) — **both map to
`qwen3_engine_tool_parser.Qwen3EngineToolParser`**. A bare `--tool-call-parser qwen3`
is **not registered** (no config-only workaround; eugr's solo recipe uses `qwen3_xml`
and is the same path).

Instantiated the real adapter with the real tokenizer inside the candidate image:

```
Qwen3EngineToolParser.__mro__ = [Qwen3EngineToolParser, Qwen3ParserToolAdapter,
                                 ParserEngineToolAdapter, ToolParser, object]
CONFIG_NAME in own __dict__ = False            # inherits from Qwen3Parser
engine = Qwen3Parser, Qwen3Parser.CONFIG_NAME = "qwen3"
config: name="qwen3" guard_literal_tool_markers=True validate_tool_preamble=True
```

**Conclusion: switching `qwen3_coder` ↔ `qwen3_xml` is not a workaround (same class), and
`guard_literal_tool_markers` is ENABLED on the served path** (it keys off
`Qwen3Parser.CONFIG_NAME == "qwen3"`, not off the `--tool-call-parser` value).
The earlier draft claim "patch 13 never reaches the qwen3_coder path" is **wrong** — do not post it.

## 2. Patch-13 authoritative tests [offline, candidate image] — 30/30 PASS

Reconstructed `tests/parser/engine/test_qwen3_literal_markers.py` from
`src/patches/qwen-tool-marker-guard-tests.patch` and ran it inside candidate image
(`pytest`, chunk sizes 1 / 7 / 10000):

```
30 passed in 7.43s
```

Covered: fenced doc in content, **fenced doc inside reasoning**, bare `<function=` mid-line,
real call, call after a closed fence, nested fences, 4-space indent, channel change
`</think><tool_call>`, unclosed-fence trade-off, inline quoted marker.

## 3. The actual leak — bare (unfenced) `<tool_call>` in reasoning [offline]

Supplemental probe through the same engine (`thinking=True`):

| case | TOOL_CALL_START |
|---|---|
| bare `<tool_call>` inside reasoning | **1** (opens a real call) |
| bare call on its own line in reasoning | **1** |
| **fenced** doc inside reasoning | 0 ✅ |
| **fenced** doc after `</think>` | 0 ✅, `DONE` present |
| genuine call after reasoning | 1 ✅ |

This is by design: the grammar has `(REASONING, TOOL_START) → TOOL_PREAMBLE` (implicit
reasoning end). The guard only suppresses a marker it can prove is *quoted* (inside a fence /
wrapper-less mid-line). A **bare** marker is indistinguishable from a real call — it opens one.
Patch 13 is complete for what it claims; this case is the documented "Illustrative `<tool_call>`
XML written in reasoning outside a fence still opens a call".

## 4. Experiment [1] prediction (thinking OFF) — offline

Same fenced-doc text, `thinking=False` (initial state CONTENT): **0 calls, content_len 131,
`DONE` present**. So if the model actually emits the fenced block, the candidate should pass
experiment [1]. The live failure therefore requires the model to emit a **bare** marker during
reasoning (or outside a fence) — which only the live model can confirm.

## 5. Experiments [1], [3], [4] — NOT RUN: need a GPU window

All three need a live candidate endpoint. Production occupies the GPU; the candidate cannot
co-run (99.9 GB held), so a candidate boot **requires stopping production** — forbidden by the
mission without explicit authorisation. See `LIVE-EXPERIMENTS.md`.

- [1] thinking OFF: not run against `9248c9d` (prior session only ran it on the old image).
- [3] reasoning_effort sweep: **impossible on the old image** (HTTP 400 for `high`); the candidate
  has `EFFORT_ALIAS=1` supporting `xhigh` (default) / `medium` / `low` only.
- [4] unfenced description: model-behaviour test; offline we proved a bare marker opens a call,
  so the missing datum is purely whether the live model emits one.
