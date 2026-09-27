import json, urllib.request

EP = "http://localhost:18300/v1/chat/completions"
MODEL = "qwen3.8-flash-next"
LT = chr(60); GT = chr(62)
TC = LT + "tool_call" + GT
TCC = LT + "/tool_call" + GT
FUN = LT + "function=example" + GT
FUNC = LT + "/function" + GT
PAR = LT + "parameter=q" + GT
PARC = LT + "/parameter" + GT

FENCED = ("Print, inside one fenced code block opened with three backticks and tagged xml, "
          "the exact literal text of a Qwen tool-call wrapper containing " + TC + " and " +
          FUN + " . After the closing fence, write in prose the single word DONE.")

DESCRIBE = ("Describe in prose, with thinking enabled, how a Qwen tool call looks. "
            "Do not use any code fences. Then say DONE.")

TOOLS = [{"type": "function", "function": {
    "name": "example", "description": "Example tool",
    "parameters": {"type": "object", "properties": {"q": {"type": "string"}},
                   "required": ["q"]}}}]


def call(name, prompt, thinking, max_tokens, tools):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
            "temperature": 0, "max_tokens": max_tokens,
            "chat_template_kwargs": {"enable_thinking": thinking}}
    if tools:
        body["tools"] = TOOLS
        body["tool_choice"] = "auto"
    req = urllib.request.Request(EP, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    out = {"case": name, "thinking": thinking, "tools": bool(tools), "max_tokens": max_tokens}
    try:
        r = json.load(urllib.request.urlopen(req, timeout=280))
    except urllib.error.HTTPError as e:
        out["http_status"] = e.code
        out["http_body"] = e.read().decode()[:300]
        return out
    out["http_status"] = 200
    ch = r["choices"][0]
    msg = ch["message"]
    content = msg.get("content") or ""
    reasoning = msg.get("reasoning_content") or ""
    calls = msg.get("tool_calls") or []
    out["finish_reason"] = ch.get("finish_reason")
    out["content_len"] = len(content)
    out["reasoning_len"] = len(reasoning)
    out["n_tool_calls"] = len(calls)
    out["tool_names"] = [c["function"]["name"] for c in calls]
    out["tool_args"] = [c["function"]["arguments"][:120] for c in calls]
    out["DONE_in_content"] = "DONE" in content
    out["DONE_in_reasoning"] = "DONE" in reasoning
    out["bare_marker_in_reasoning"] = TC in reasoning
    out["bare_marker_in_content"] = TC in content
    out["fence_in_reasoning"] = "```" in reasoning
    out["fence_in_content"] = "```" in content
    out["content_tail"] = content[-160:]
    out["reasoning_head"] = reasoning[:160]
    out["reasoning_tail"] = reasoning[-160:]
    out["usage"] = r.get("usage")
    return out


results = [
    call("EXP1_THINKING_OFF_FENCED_TOOLS", FENCED, False, 2000, True),
    call("EXP4_THINKING_ON_DESCRIBE_TOOLS", DESCRIBE, True, 2000, True),
    call("EXP4_RAW_THINKING_ON_DESCRIBE_NOTOOLS", DESCRIBE, True, 2000, False),
]
print(json.dumps(results, indent=1))
