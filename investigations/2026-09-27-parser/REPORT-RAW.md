# REPORT-RAW — raw model output fed to the instrumented parser

2026-09-27. Production untouched (read-only). Raw capture had to use `/v1/completions`
because the chat path on the deployed image **swallows** the text (content and reasoning both
empty; see below). Parser side: `Qwen3Parser` via `ParserManager`, `guard_literal_tool_markers=True`,
instrumented `_marker_is_literal`.

## Raw capture (production :18300, temperature 0, max_tokens 2000)

| capture | path | thinking | tokens | raw length | `<tool_call>` markers | fenced? |
|---|---|---|---|---|---|---|
| RAW-C-thinking-on | `/v1/completions` (templated prompt) | on | 1109 | 4858 | **28** (27 in reasoning, 1 in content) | yes, 1 in content |
| RAW-C-thinking-off | `/v1/completions` (templated prompt) | off | 21 | 71 | 1 (in content) | yes |
| chat, no tools | `/v1/chat/completions` | on | 1109 | **0 returned** | — | server swallowed all text |
| chat, tools | `/v1/chat/completions` | on | 290 | **0 returned** | 4 tool calls extracted | server swallowed text |

Files: `raw/RAW-C-thinking-on.txt` (4858 B), `raw/RAW-C-thinking-off.txt` (71 B).

The thinking-ON reasoning is full of **bare, unfenced** `<tool_call>` snippets — the model is
"trying out" the syntax as it thinks, e.g. `...<tool_call>\n<function=example>\n</function>\n</tool_call>...`.
The final answer after `</think>` is the correct fenced block + `DONE`.

## Feeding the exact captured text to the instrumented server parser

| input text | thinking | `parse()` calls | guarded (literal=True) | not guarded (literal=False) | content | DONE |
|---|---|---|---|---|---|---|
| `RAW-C-thinking-on` | on | **12** | 3 (all `fence_open_run=3`) | **many** (`fence_open_run=0`, state REASONING then CONTENT) | 0 | false |
| `RAW-C-thinking-off` | off | **0** | 2 (`fence_open_run=3`) | 0 | 71 | **true** |

`parse_delta()` (streaming) on `RAW-C-thinking-on` opened 30 streaming call fragments — same
`literal=False` markers, same result (0 for the thinking-OFF text).

## Table requested

| prompt | tools? | raw has fence? | raw has bare marker? | parser calls |
|---|---|---|---|---|
| fenced ```xml doc, thinking ON | no (completions raw) | yes (1, in content) | **YES — 27 in reasoning** | **12** |
| fenced ```xml doc, thinking OFF | no (completions raw) | yes | no | **0** (DONE present) |
| fenced ```xml doc, thinking ON | yes (live chat) | not capturable (swallowed) | n/a | **4** (live) |

## Conclusion (one line)

The fabricated calls come from **bare `<tool_call>` markers the model emits inside its own
reasoning** — the guard is active and does exactly the right thing (fenced → literal/guarded,
bare → opens a call), so this is **model-side reasoning bleed, not a parser-wiring gap**.

## Verdict

**Is the 6-call explained by a bare marker? YES.** The guard is active in the live path
(verified on the server's own parser instance); the failing prompt makes the model reason about
the tool-call syntax and emit bare `<tool_call>` snippets while thinking, which are
indistinguishable from real calls and are therefore (correctly) opened. Thinking OFF removes the
reasoning entirely and the same prompt parses cleanly (0 calls, `DONE` present).

Note: the exact call count is generation-dependent (12 from the no-tools 1109-token raw, 4 from
the live with-tools 290-token generation, "6" reported earlier) — all the same root cause.
