#!/usr/bin/env bash
# Multi-turn time-to-first-token probe. Turn 1 carries a long prompt to make the first prefill
# expensive; later turns should be prefix-cache hits. A slow turn 2 means prefix caching is off,
# mis-keyed, or the block-size fix has stopped applying.
#
#   API        host:port (default 127.0.0.1:18300)
#   MODEL      model name (default qwen3.8-flash-next)
#   TURNS      number of turns (default 4)
#   PAD_TOKENS approximate padding tokens on turn 1 (default 20000)
set -uo pipefail
API=${API:-127.0.0.1:18300}
MODEL=${MODEL:-qwen3.8-flash-next}
TURNS=${TURNS:-4}
PAD_TOKENS=${PAD_TOKENS:-20000}

python3 - "$API" "$MODEL" "$TURNS" "$PAD_TOKENS" <<'PY'
import json, sys, time, urllib.request
api, model = sys.argv[1], sys.argv[2]
turns, pad = int(sys.argv[3]), int(sys.argv[4])
pad_text = "Please confirm you are awake. " * max(0, pad // 5)
msgs = []
worst = 0.0
for turn in range(turns):
    msgs.append({"role": "user",
                 "content": ("Say OK." if turn else pad_text + " Now say OK.")})
    payload = {"model": model, "messages": msgs, "max_tokens": 8, "temperature": 0}
    req = urllib.request.Request(f"http://{api}/v1/chat/completions",
                                data=json.dumps(payload).encode(),
                                headers={"Content-Type": "application/json"})
    t = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            json.load(r)
    except Exception as e:
        print(f"turn {turn+1}: FAIL {type(e).__name__}: {e}")
        break
    dt = time.perf_counter() - t
    worst = max(worst, dt)
    print(f"turn {turn+1}: TTFT {dt:6.2f} s" + ("   (first prefill)" if turn == 0 else ""))
    msgs.append({"role": "assistant", "content": "OK"})
if worst:
    print("expectation: turn 1 pays prefill; later turns ~1.5 s. "
          "A late turn 2 means the prefix cache is not being hit.")
PY
