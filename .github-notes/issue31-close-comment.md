# Proposed closing comment — issue #31 (reasoning + tool calling: empty responses)

> Note: this repo checkout has no GitHub credentials (`gh` is not installed and `git remote` is
> empty), so the issue cannot be closed directly. The text below is ready to paste into
> https://github.com/blazux/qwen3.8-Flash-DGX/issues/31.

## What the issue was

With tools enabled, the model sometimes writes a literal `<tool_call>` marker *inside its reasoning*
(e.g. when planning or documenting the tool format). The parser then treats it as the start of a
real call, consumes the rest of the turn as tool-call syntax, and the answer after `</think>` is
discarded — the client sees an empty response / `content: null`. Reproduced on three checkpoints,
so the trigger is base-model behavior, not our quantization or the mmap path.

## What we shipped (patches 12 + 13, issues #20/#29/#42)

- **Patch 12** buffers the `<tool_call>` marker and keeps it as plain text when ordinary prose
  follows, instead of switching into a tool preamble and dropping the remainder.
- **Patch 13** adds fence-awareness: inside a fenced code block `<tool_call>` and `<function=>` stay
  text; a wrapper-less `<function=>` header only opens a call at line start; fence state is
  re-synced at the reasoning -> answer transition so an open fence in reasoning never swallows
  the final answer.

Together these eliminated the reported empty-response failures in the agentic tournament.

## Deliberately NOT covered (this issue's remaining scope)

An illustrative `<tool_call>...<function=>...</tool_call>` written in reasoning *outside* a fence still
opens a call. Suppressing that would mean dropping the legitimate reasoning -> tool-call
transition, which this model uses heavily; deciding from text alone cannot separate "documenting
the format" from "emitting a call" in that position. A well-formed function header after a marker
is, by protocol, a tool call.

## Why we are closing rather than fixing further

The residual case is model-side confabulation of its own emission protocol. The two candidate
server-side fixes were evaluated and rejected for now:

1. **EOS guard (<|im_end|> masked until `</think>`)** — an opt-in `REASONING_EOS_GUARD` idea from
   the #18 discussion. It does stop premature termination, but it also blocks the early-exit path
   the tournament relies on and changes sampling semantics mid-decode; under the quality-first
   gate it did not earn its keep.
2. **Chat-template mitigation** (rewording the tools section so the model stops writing raw
   markers in reasoning) — template edits are byte-level behavior changes; every variant must
   re-pass the full agentic tournament, and none beat the status quo enough to justify shipping.

Upstream equivalents (vllm-project/vllm#55420, #55562) remain open; if upstream lands a
protocol-level fix (e.g. structured tool-call channels that cannot fire during reasoning), we
will adopt it and reopen.

## Client-side workaround (recommended today)

If you hit the residual case: ask the model to describe tool syntax in prose or inside a fenced
block (both are guarded), or strip/re-send without the offending turn. Prefix-caching off does
not help; this is decode-time parsing, not cache state.

**Disposition: close as completed** — the failure mode reported in #31 (empty responses) is fixed
by patches 12+13; the remaining illustrative-marker edge is documented above as wontfix-unless-
upstream, consistent with the README "Not covered, both deliberate" section.
