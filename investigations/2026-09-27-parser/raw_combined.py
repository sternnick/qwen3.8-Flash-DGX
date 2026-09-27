import json, os, urllib.request
from types import SimpleNamespace
from transformers import AutoTokenizer as AT

SNAP = "/hf/hub/models--RadixArk--Qwen3.8-Flash-Next-NVFP4/snapshots/7b719225242aacd3dbd3f9407468c2ee9a9d2594-fp8hybrid"
tok = AT.from_pretrained(SNAP, local_files_only=True)
LT = chr(60); GT = chr(62)
TC = LT + "tool_call" + GT
FUN = LT + "function=example" + GT
FENCED = ("Print, inside one fenced code block opened with three backticks and tagged xml, "
          "the exact literal text of a Qwen tool-call wrapper containing " + TC + " and " +
          FUN + " . After the closing fence, write in prose the single word DONE.")
TOOLS = [{"type": "function", "function": {
    "name": "example", "description": "Example tool",
    "parameters": {"type": "object", "properties": {"q": {"type": "string"}},
                   "required": ["q"]}}}]
OUT = "/out"


def complete(thinking):
    prompt = tok.apply_chat_template([{"role": "user", "content": FENCED}],
                                     tokenize=False, add_generation_prompt=True,
                                     enable_thinking=thinking)
    body = {"model": "qwen3.8-flash-next", "prompt": prompt,
            "max_tokens": 2000, "temperature": 0}
    req = urllib.request.Request("http://localhost:18300/v1/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=280))
    return r["choices"][0]["text"], {"fr": r["choices"][0]["finish_reason"], "usage": r.get("usage")}


raw_on, meta_on = complete(True)
raw_off, meta_off = complete(False)
open(os.path.join(OUT, "RAW-C-thinking-on.txt"), "w").write(raw_on)
open(os.path.join(OUT, "RAW-C-thinking-off.txt"), "w").write(raw_off)

# instrument the guard
from vllm.parser import ParserManager
from vllm.parser.engine.streaming_parser_engine import StreamingParserEngine
ParserCls = ParserManager.get_parser("qwen3_coder", "qwen3", enable_auto_tools=True)
LOG = []
_om = StreamingParserEngine._marker_is_literal


def _marker(self, terminal):
    r = _om(self, terminal)
    LOG.append({"terminal": terminal, "literal": bool(r),
                "fence_open_run": getattr(self, "_fence_open_run", None),
                "state": self.state.name})
    return r


StreamingParserEngine._marker_is_literal = _marker


def run(mode, text, thinking):
    LOG.clear()
    p = ParserCls(tok, TOOLS, chat_template_kwargs={"enable_thinking": thinking}, model_config=None)
    req = SimpleNamespace(tools=TOOLS, tool_choice="auto", include_reasoning=True)
    if mode == "parse":
        reasoning, content, tcs = p.parse(text, req, enable_auto_tools=True)
        calls = [(t.name, t.arguments) for t in (tcs or [])]
        return {"calls": calls, "content_len": len(content or ""),
                "reasoning_len": len(reasoning or ""), "DONE": "DONE" in (content or ""),
                "marker_log": list(LOG)}
    allc = []
    for i in range(0, len(text), 7):
        dm = p.parse_delta(text[i:i + 7], [], req, prompt_token_ids=[],
                           finished=(i + 7 >= len(text)))
        if dm and dm.tool_calls:
            allc += [(t.function.name, t.function.arguments) for t in dm.tool_calls]
    return {"calls": allc, "n_tool_calls": len(allc), "marker_log": list(LOG)}


report = {
    "server_parser_cls": ParserCls.__module__ + "." + ParserCls.__name__,
    "guard": ParserCls(tok, TOOLS, chat_template_kwargs={"enable_thinking": True},
                       model_config=None).parser_engine_config.guard_literal_tool_markers,
    "raw_on": {"len": len(raw_on), "has_fence": "```" in raw_on,
               "bare_marker_outside_fence": None, "meta": meta_on},
    "raw_off": {"len": len(raw_off), "has_fence": "```" in raw_off, "meta": meta_off},
    "PARSER on raw_on (thinking=True)": {"parse": run("parse", raw_on, True),
                                         "parse_delta": run("parse_delta", raw_on, True)},
    "PARSER on raw_off (thinking=False)": {"parse": run("parse", raw_off, False),
                                           "parse_delta": run("parse_delta", raw_off, False)},
}

# count bare vs fenced markers in the raw text
import re
for tag, txt in (("on", raw_on), ("off", raw_off)):
    reasoning = txt.split("</think>")[0] if "</think>" in txt else txt
    content = txt.split("</think>", 1)[1] if "</think>" in txt else ""
    report["raw_" + tag]["n_tool_call_markers"] = txt.count("<tool_call>")
    report["raw_" + tag]["n_markers_in_reasoning"] = reasoning.count("<tool_call>")
    report["raw_" + tag]["n_markers_in_content"] = content.count("<tool_call>")
    report["raw_" + tag]["reasoning_len"] = len(reasoning)
    report["raw_" + tag]["content_len"] = len(content)

print(json.dumps(report, indent=1, default=str))
