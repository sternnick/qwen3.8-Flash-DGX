# Is the guard active in the live streaming path? — offline verification (candidate image)

Method: built the parser the **exact way the server does** (CPU, real tokenizer), instrumented
`StreamingParserEngine._marker_is_literal` / `_track_literal_text`, and fed the same fenced
text through both server entry points. No image modifications (runtime monkeypatch only).

## 1. Does the streaming path use a different parser class?

No. `ParserManager.get_parser("qwen3_coder", "qwen3", enable_auto_tools=True)` collapses the two
adapters back onto the shared engine (parser_manager.py: `if reasoning_engine_cls is
tool_engine_cls: return reasoning_engine_cls`) and returns:

```
server parser_cls = vllm.parser.qwen3.Qwen3Parser      # the ParserEngine, not an adapter
```

The server then constructs it exactly as:
`parser_cls(tokenizer, request.tools, chat_template_kwargs=…, model_config=…)`
(serving.py:251 non-streaming, serving.py:473 streaming). Both `parse()` (full generator) and
`parse_delta()` (stream generator) are methods on that one `Qwen3Parser` and both feed the same
`StreamingParserEngine`.

## 2/3/4. Is the guard applied on that instance, in both paths?

Yes — instrumented runs (guard consulted, and what it decided):

| path | input | `marker_is_literal` | fence_open_run | result |
|---|---|---|---|---|
| `parse()` non-streaming, thinking=True | fenced after `</think>` | TOOL_START → **True**, FUNC_PREFIX → **True** | 3 | **0** tool calls, `DONE` present, content 140 |
| `parse()` non-streaming, thinking=False | fenced | **True** ×2 | 3 | **0** calls, `DONE` present, content 154 |
| `parse_delta()` streaming, thinking=True | fenced (7-char deltas) | **True** ×2 | 3 | **0** calls |
| `parse_delta()` streaming, thinking=False | fenced (7-char deltas) | **True** ×2 | 3 | **0** calls |
| `parse()` thinking=True | **bare** marker in reasoning | TOOL_START → **False** | 0 | **1** call |
| `parse_delta()` thinking=True | bare marker in reasoning | **False** | 0 | call opened |

`guard_literal_tool_markers = True` on the server's `Qwen3Parser` instance in every case.
`_track_literal_text` ran 28× in the streaming path, i.e. fence state is tracked **across deltas**
(`initialize_streaming` is idempotent — `if not self._streaming_initialized` — so it is not reset
per delta). The test's config and the server's config are identical:
`qwen3_config(thinking=…, name="qwen3")`.

## Conclusion

**The guard is really active in the live path — there is no gap between the class-level test and
the server.** Same class, same instance config, guard consulted and returning `True` for fenced
markers in both `parse()` and `parse_delta()`.

The only input that still yields a fabricated call is a **bare** `<tool_call>` with no open fence
(`marker_is_literal → False`, `fence_open_run = 0`) — the grammar's legitimate implicit
reasoning-end. So if the candidate live result really is 6 calls with the guard active, the cause
cannot be guard wiring; it must be the model's raw output placing the marker **outside any fence**
(bare, or in a form the CommonMark fence tracker does not see as an open fence).

Next decisive step (needs the candidate live or its raw generated text): capture the raw output
(`include_reasoning`, no `tools[]`) for the failing prompt and feed that exact text through this
instrumented `Qwen3Parser`. That will show, per marker, whether `marker_is_literal` returned
True/False on the real output.
