import json
from types import SimpleNamespace
from transformers import AutoTokenizer as AT

SNAP = "/hf/hub/models--RadixArk--Qwen3.8-Flash-Next-NVFP4/snapshots/7b719225242aacd3dbd3f9407468c2ee9a9d2594-fp8hybrid"
tok = AT.from_pretrained(SNAP, local_files_only=True)

TOOLS = [{"type": "function", "function": {
    "name": "example", "description": "Example tool",
    "parameters": {"type": "object", "properties": {"q": {"type": "string"}},
                   "required": ["q"]}}}]

TC = "<tool_call>"; ENDT = "</tool_call>"
FN = "<function=example>"; FE = "</function>"
PS = "<parameter=q>"; PE = "</parameter>"
REAL = f"{TC}\n{FN}\n{PS}hi{PE}\n{FE}\n{ENDT}"
FENCED_AFTER = f"Short thought.</think>\n\nHere is the XML:\n\n```xml\n{REAL}\n```\n\nThat is the format. DONE"
BARE_IN_REASONING = f"I show a call: {REAL}\n</think>\n\nDone."

# --- build parser EXACTLY as the server does ---
from vllm.parser import ParserManager
ParserCls = ParserManager.get_parser("qwen3_coder", "qwen3", enable_auto_tools=True)
print("server parser_cls        :", ParserCls.__module__ + "." + ParserCls.__name__)

# --- instrument the guard ---
from vllm.parser.engine.streaming_parser_engine import StreamingParserEngine
LOG = []
_orig_marker = StreamingParserEngine._marker_is_literal
_orig_track = StreamingParserEngine._track_literal_text


def _marker(self, terminal):
    r = _orig_marker(self, terminal)
    LOG.append({"ev": "marker_is_literal", "terminal": terminal, "literal": bool(r),
                "fence_open_run": getattr(self, "_fence_open_run", None),
                "state": self.state.name})
    return r


def _track(self, text):
    LOG.append({"ev": "track", "len": len(text),
                "fence_open_run": getattr(self, "_fence_open_run", None),
                "state": self.state.name})
    return _orig_track(self, text)


StreamingParserEngine._marker_is_literal = _marker
StreamingParserEngine._track_literal_text = _track


def build(thinking):
    p = ParserCls(tok, TOOLS, chat_template_kwargs={"enable_thinking": thinking}, model_config=None)
    cfg = p.parser_engine_config
    return p, cfg


def names_of(res):
    tc = getattr(res, "tool_calls", None) or []
    return [c.function.name if hasattr(c, "function") else c.name for c in tc]


def run(mode, text, thinking):
    LOG.clear()
    p, cfg = build(thinking)
    req = SimpleNamespace(tools=TOOLS, tool_choice="auto", include_reasoning=True,
                          model_config=None)
    if mode == "parse":
        reasoning, content, tool_calls = p.parse(text, req, enable_auto_tools=True)
        res = {"reasoning_len": len(reasoning or ""), "content_len": len(content or ""),
               "n_tool_calls": len(tool_calls or []),
               "tool_names": [tc.name for tc in (tool_calls or [])],
               "DONE": "DONE" in (content or "")}
    else:
        last = None
        for i in range(0, len(text), 7):
            last = p.parse_delta(text[i:i + 7], [], req, prompt_token_ids=[],
                                 finished=(i + 7 >= len(text)))
        dm = last
        res = {"content_len": len((dm.content or "") if dm else ""),
               "n_tool_calls": len((dm.tool_calls or []) if dm else []),
               "tool_names": [tc.function.name for tc in (dm.tool_calls or [])] if dm else [],
               "DONE": "DONE" in ((dm.content or "") if dm else "")}
    return {"mode": mode, "thinking": thinking, "guard": cfg.guard_literal_tool_markers,
            "marker_calls": [x for x in LOG if x["ev"] == "marker_is_literal"],
            "track_calls": len([x for x in LOG if x["ev"] == "track"]), **res}


out = []
for mode in ("parse", "parse_delta"):
    out.append(run(mode, FENCED_AFTER, True))
    out.append(run(mode, FENCED_AFTER, False))
    out.append(run(mode, BARE_IN_REASONING, True))
print(json.dumps(out, indent=1))
