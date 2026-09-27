### Correction to my earlier report — re-measured, data only

I need to retract the root cause from my first message before anyone spends time on it. My claim that patch 13's guard does not reach the `--tool-call-parser qwen3_coder` path is **wrong**. Everything below is re-measured so the numbers stand on their own, and I've labelled which image each measurement came from.

Thanks again for patches 12–18 — the load-time change here (633 s → 111 s) is a real improvement.

---

#### Correction: the guard is active on both qwen3 tool-parser paths

Measured inside a self-built image from `main@9248c9d` (real tokenizer, CPU):

- `vllm/tool_parsers/__init__.py` registers only two Qwen tool parsers — `qwen3_coder` (line 173) and `qwen3_xml` (line 177) — and **both map to `qwen3_engine_tool_parser.Qwen3EngineToolParser`**. A bare `--tool-call-parser qwen3` is not registered.
- `Qwen3EngineToolParser` does not define `CONFIG_NAME`; it inherits `Qwen3Parser.CONFIG_NAME == "qwen3"`. Instantiating it with the real tokenizer:

```
parser_engine_config.name                 = "qwen3"
guard_literal_tool_markers                = True
validate_tool_preamble                    = True
```

- The 10 tests from `src/patches/qwen-tool-marker-guard-tests.patch` pass **30/30** (chunk sizes 1 / 7 / 10000), including *fenced marker inside reasoning*.

So the `name == "qwen3"` gate is not the cause, and switching `qwen3_xml` ↔ `qwen3_coder` is not a workaround — they are the same class.

---

#### Served behaviour (read-only probes)

All probes: `temperature 0`, `max_tokens 2000`, one `tools[]` entry (`example`), model `qwen3.8-flash-next`. These ran against my **pre-patch-13** deployment (`bd60fcb` line) because I could not boot the patched image; they therefore show the unguarded path, not the patched one.

**Experiment [1] — fenced ```xml prompt, `enable_thinking=false`, tools present**

| field | value |
|---|---|
| finish_reason | `tool_calls` |
| content_len | 6 (`"```xml"`) |
| n_tool_calls | **1** (`example`, args `{}`) |
| DONE present | **False** |
| completion_tokens | 21 |

Interpretation: on this image, thinking OFF does **not** yield 0 calls + DONE — the fenced block is still consumed as a real call.

**Experiment [4] — “describe in prose, no code fences”, `enable_thinking=true`, tools present**

| field | value |
|---|---|
| finish_reason | `stop` |
| content_len | **654** |
| n_tool_calls | **0** |
| DONE present | **True** |
| reasoning_tokens | 451 |
| bare `<tool_call>` in reasoning | **False** |

Interpretation: the model did **not** emit a bare `<tool_call>` while thinking; it answered in prose and said DONE. (A no-`tools[]` raw variant was identical: 0 calls, DONE present.) The “bare marker leaks from reasoning” hypothesis is **not supported** by this probe.

**Supplementary probes (same endpoint)**

| probe | finish_reason | content_len | n_tool_calls | notes |
|---|---|---|---|---|
| thinking ON, fenced, tools | `tool_calls` | 0 | **4** (`example` ×3, `function_name` ×1) | placeholder args (`{}`, `{"q":"..."}`, …) |
| thinking ON, fenced, **no tools** | `stop` | 0 | 0 | 1109 tokens generated, **all text swallowed** (content and reasoning both empty) |

Taken together with [1] (same fenced prompt, thinking OFF → 1 call), the fenced case fails with **either** thinking setting on this image → the defect is parser-side, not reasoning-side.

---

#### Engine-level behaviour (offline, patched image)

Feeding representative raw output through the patched `Qwen3Parser` config (real tokenizer, CPU):

| raw output | `TOOL_CALL_START` |
|---|---|
| fenced `<tool_call>` after `</think>` | 0 ✅ (content intact, `DONE` present) |
| fenced `<tool_call>` inside reasoning | 0 ✅ |
| **bare (unfenced) `<tool_call>` inside reasoning** | **1** |
| genuine unfenced call after reasoning | 1 ✅ |

The bare-in-reasoning row is the grammar's `(REASONING, TOOL_START) → TOOL_PREAMBLE` implicit-reasoning-end; it is by design indistinguishable from a real call, and is the documented “illustrative `<tool_call>` outside a fence still opens a call”.

---

#### Summary of what I have and haven't verified

- Guard is enabled on `qwen3_coder`/`qwen3_xml`; patch-13 tests pass 30/30 offline.
- On the **pre-patch** image, the fenced block is swallowed into calls even with thinking OFF and even with no `tools[]`; thinking OFF is not a workaround.
- The reasoning-leak hypothesis is not supported by the served [4] probe.
- I have **not** been able to verify the patched image end-to-end against a served request.

---

#### Question

**Is there a streaming-path difference that the class-level test doesn't cover?**

Concretely: the serving layer keeps a separate reasoning adapter and tool adapter, and the tool adapter's non-streaming entry (`ParserEngineToolAdapter.extract_tool_calls`) calls `extract_tool_calls_from_content(..., initial_state=CONTENT)`. If the fence state is tracked per `StreamingParserEngine` instance, is there a served path where the tool adapter never sees the opening fence (so `_fence_open_run` stays 0) but still sees the marker — which the class-level test would not exercise? I'm happy to run one live probe against a patched build and report either way.
