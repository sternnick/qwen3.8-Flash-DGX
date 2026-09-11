#!/usr/bin/env bash
# Single-image request probe. Vision is not advertised by the recipe, so this is the check that
# shows whether the mm processor and the chat template still work after a base image bump.
# Needs Pillow to synthesise the image, or set IMG_B64 yourself.
#
#   API   host:port of the server (default 127.0.0.1:18300)
#   MODEL model name (default qwen3.8-flash-next)
set -uo pipefail
API=${API:-127.0.0.1:18300}
MODEL=${MODEL:-qwen3.8-flash-next}

python3 - "$API" "$MODEL" <<'PY'
import base64, io, json, sys, urllib.request
api, model = sys.argv[1], sys.argv[2]
b64 = ""
try:
    b64 = __import__("os").environ.get("IMG_B64", "")
    if not b64:
        from PIL import Image
        img = Image.new("RGB", (640, 480), (240, 240, 240))
        for x in range(80, 320):                      # a red square
            for y in range(80, 320):
                img.putpixel((x, y), (210, 40, 40))
        for x in range(360, 560):                     # a blue circle
            for y in range(120, 320):
                if (x-460)**2 + (y-220)**2 < 90**2:
                    img.putpixel((x, y), (40, 70, 210))
        buf = io.BytesIO(); img.save(buf, "PNG"); b64 = base64.b64encode(buf.getvalue()).decode()
except ImportError:
    raise SystemExit("needs Pillow, or export IMG_B64 with a base64 PNG")

def ask(images, text):
    content = [{"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}}
               for _ in range(images)]
    content.append({"type": "text", "text": text})
    payload = {"model": model, "max_tokens": 64, "temperature": 0,
               "messages": [{"role": "user", "content": content}]}
    req = urllib.request.Request(f"http://{api}/v1/chat/completions",
                                data=json.dumps(payload).encode(),
                                headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return "OK: " + json.load(r)["choices"][0]["message"]["content"].strip()
    except Exception as e:
        return f"FAIL: {type(e).__name__}: {e}"

one = ask(1, "Describe the image in one short sentence.")
two = ask(2, "Describe the image in one short sentence.")
print(f"single image : {one}")
print(f"two images   : {two}   (failure here is a known upstream limitation)")
PY
