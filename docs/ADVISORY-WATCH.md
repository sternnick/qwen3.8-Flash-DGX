# Advisory watch — served stack

BASELINE 1cb2db2eb4fa19f2836a652460b2ba862002fdba 2026-10-18T14:43:59Z

The pinned base (`Dockerfile:10`, `FROM vllm/vllm-openai:v0.30.0`) and our patch set checked against
upstream advisories and releases. This file records the state of that watch; a version bump is an owner
decision (root `AGENTS.md`, Boundaries). Report only — nothing here was installed, upgraded, or restarted.

Scan of 2026-10-18: last_verified_utc `2026-10-18T19:00Z` · verified_by `cp-hermes-01`
· verification_method `cross-check` (GitHub advisory database + upstream release diffs, commands below).

Evidence: every claim below names the command that produced it; the commands are in the text and
re-runnable as-is.

## Advisories published against `vllm` and applicability to the served configuration

Sources: `gh api "repos/vllm-project/vllm/security-advisories?per_page=100"` (100 records, queried
2026-10-18) and each advisory's detail page via `gh api repos/vllm-project/vllm/security-advisories/GHSA-…`.

| advisory | sev | range stated | affects 0.30.0? | applicability to this repo's served config |
|---|---|---|---|---|
| GHSA-6cxc-2vcg-w5qc | low | ≤ 0.30.0 | **yes** | Serving-layer output-integrity bug: `InputBatch.condense()` can leak one request's `allowed_token_ids` mask onto another client's request under concurrent batching. Needs guided/`allowed_token_ids` traffic and slot-reuse timing — whether that traffic reaches our endpoint is host-dependent (Unknown from repo evidence). Fix vllm#43931 merged 2026-09-27, ships in v0.31.0 (verified by `gh api repos/vllm-project/vllm/compare/v0.30.0...v0.31.0` commit list). |
| GHSA-4xqp-c3mv-qff7 | medium | < 0.31.0 | range yes | **Not mounted in our config.** Single-request DoS through `/inference/v1/generate`. On v0.30.0 that route registers only with `--enable-scale-out` or `--tokens-only` — both default `False` (upstream `vllm/entrypoints/launchers/cli_args.py:179,184` at tag v0.30.0) — and `scripts/serve.sh` passes neither (grep `scale_out|tokens.only|tokens-only` over `scripts/serve.sh`: no matches). |
| GHSA-rhcx-5729-88vg | high | ≥ v0.8.5 | range yes | Not applicable: needs a `KVConnectorBase_V1` subclass (LMCache/NIXL/…). `scripts/serve.sh` configures no kv-transfer connector (grep `kv.transfer|connector`: no matches). |
| GHSA-h3rc-6mm3-gc2m | high | ≥ 0.7.3 | range yes | Not applicable: needs `--trust-remote-code` and a multimodal `auto_map` processor. Neither is used here (grep `trust.remote|trust_remote` over `scripts/serve.sh` and `flash`: no matches; text-only checkpoint). |
| GHSA-rh6f-3x46-j33q | medium | < 0.31.0 (field) | — | Conflicting data: the advisory's own description says confirmed on ≤ 0.25.1. Site B is a prefix-cache block-hash collision (LoRA name vs `cache_salt`) and prefix caching is on here (`PREFIX_CACHE=1` default), but no LoRA or `cache_salt` use is configured; the structured range field and the description disagree — reported as-found, not adjudicated. Fix (vllm PR titled "Tag prefix-cache extra keys by source" / "Include the LoRA path in the block hash", both listed in the v0.31.0 release notes) is in v0.31.0. |
| GHSA-p92p-rxj5-7p2x, GHSA-4m6g-h9mv-wqjc | med/high | < 0.31.0 | range yes | Multimodal (image/video) paths; not applicable to this text-only serving recipe. |

Advisories patched at or below 0.30.0 (GHSA-85xf…, GHSA-2823…, GHSA-25q3…, GHSA-wpww…, GHSA-v5gm…,
etc.) are already fixed in the pinned base and are not findings.

`v0.32.0` (2026-10-18) lists GHSA-4hhp…, GHSA-q97c…, GHSA-frvg… fixes plus a CORS default change;
GHSA-frvg (P2P ZMQ) needs multi-node/P2P connectors — not our config. The CORS change (vllm PR
titled "Restrict default CORS origins", listed in the v0.32.0 release notes) is
behavioral for anyone fronting the API; noted for the bump decision, not a finding on its own.

## Upstream fixes for defects this repository recorded (registry condition: fix for a recorded defect)

Both landed in **v0.31.0** (2026-10-05). Verified by the v0.30.0→v0.31.0 commit list
(`gh api repos/vllm-project/vllm/compare/v0.30.0...v0.31.0`) and by the file diff below:

- **Patch 7 (fp8 KV on the QSA path, the @Nanetnounou contribution recorded in docs/HISTORY.md)** is upstream as vllm#55557 ("Qwen4Exp: fp8_e4m3 main
  KV cache on the QSA path", merged 2026-09-16). On the v0.31.0 tree `vllm/models/qwen4_exp/nvidia/ops/qsa.py`
  already carries `_cast_kv_tile` / `kv_quant_mode` (23 matching lines); the v0.30.0 tree carries none
  (`curl …/raw/v0.3{0,1}.0/.../ops/qsa.py | grep -c '_cast_kv_tile|kv_quant_mode|fp8'` → 0 vs 23).
  **Cost if we ever bump:** our patch 7 (`src/patch_qsa_fp8_kv.py`, `Dockerfile` §7) targets the pre-fix
  file and would collide or double-patch — it must be dropped or re-scoped on a v0.31+ base.
- **Patch 16 (indexed expert-name matching in weight loading)** is upstream as vllm#58720 ("Index
  expert mapping lookups in RoutedExperts.load_weights"; release notes: ~25 s saved on DGX Spark).
  Overlaps our patch 16 on a v0.31+ base.
- **Patch 8 (deterministic top-k, vllm#55122) is NOT fixed upstream** — that PR is still open
  (`gh api repos/vllm-project/vllm/pulls/55122` → state open, no merge date) as of this scan.
  The bundled deterministic kernel remains required on any base.

v0.31.0 also carries a scheduler change relevant to the `shared` profile: `--long-prefill-token-threshold`
becomes adaptive (vllm PRs titled "Soften Long Prefill Tokens Threshhold" and "Tune
--long-prefill-token-threshold adaptiveness", listed in the v0.31.0 release notes) — re-measure
the profile's `EXTRA` value on any bump.

## Profile-drift check (published vs served)

`profiles/published.env` parses as valid `serve.sh` variables (`MODE=nvfp4`, `YARN=1`, `CTX=500000`) and
is consistent with the README profile table and `serve.sh` defaults except for its `# desc` decode figure
(~28 tok/s) against the README table's ~26 tok/s — already tracked on the open issue titled
"[SEV4] profiles/published.env desc quotes … tok/s … where the README table says …". The *served* profile
on the GPU host is not inspectable from here (role file: host access none), so host-side drift is
**Unknown** from repo evidence, not measured clean.

## Scan of 2026-10-23 (delta to the scan above)

last_verified_utc `2026-10-23T23:45Z` · verified_by `cp-hermes-01` · verification_method `cross-check`
(GitHub advisory database + release commit lists, commands below). Report only — nothing installed,
upgraded or restarted; a version bump is an owner decision.

### Advisories published since the last scan that reach our pinned base

Three advisories were published 2026-10-20 (batch disclosure alongside v0.32.0) and meet this
repository's finding condition ("an advisory in the HTTP layer", role file, Version and upstream
watch). All three are fixed in **v0.32.0** — verified by the v0.30.0→v0.32.0 commit list, where each
fix commit title appears, and their absence from the v0.30.0→v0.31.0 list. Command (per tag, paginated):

```
$ for pg in 1 2 3 4 5 6; do gh api "repos/vllm-project/vllm/compare/v0.30.0...v0.32.0?page=$pg" \
    --jq '.commits[]? | .sha[:9]+" "+(.commit.message|split("\n")[0])'; done \
  | grep -iE 'Restrict Pillow|chat template resource|Restrict default CORS'
```

| advisory | sev | stated range | reaches 0.30.0? | applicability to this repo's served config |
|---|---|---|---|---|
| GHSA-vvpg-rrww-wpmh | low | All versions (default config) | **yes** | Permissive default CORS origins on the OpenAI HTTP server — the formalization of the CORS default change already noted for v0.32.0 in the scan above (fix commit titled "Restrict default CORS origins"). The served endpoint has no API key (open issue titled "serve.sh binds 0.0.0.0 with no API key"), so any browser origin that can reach the LAN port can drive it cross-origin. |
| GHSA-542m-9234-8gvf | medium | >= 0.19.0 (no upper bound stated) | **yes** | Unbounded Jinja2 `chat_template` render on the renderer thread pool (default 1 worker) — one short request permanently wedges every chat-style endpoint until process restart, or OOM-kills the API server (string-multiplication variant). The advisory states the remote vector works in default `vllm serve` config via a `/v1/responses` gate omission (its own text cross-references a companion advisory). Our endpoint is unauthenticated (same open issue as above), so "authenticated client" = anyone who can reach the LAN port. Fix commit titled "Fix chat template resource-exhaustion DoS", v0.32.0. |
| GHSA-h3rc-j82p-2c3h | **high** | 0.30.0 (the advisory claims only this version) | **yes** | `ImageMediaIO` passes untrusted bytes to Pillow format autodetection with no format allowlist; an EPS payload labeled `image/png` reaches host Ghostscript — command execution if the host Ghostscript is vulnerable to CVE-2024-29510 (a 2024 N-day; Ghostscript fixed in 10.03.1). Preconditions per the advisory: an image-capable request path, a caller able to reach it, and a vulnerable host Ghostscript build. Our checkpoint is text-only, but the multimodal request parser runs in the entrypoint layer on 0.30.0 regardless of the model; whether the base image ships Ghostscript and which Pillow it carries are **Unknown from repo evidence** (not inspected — host access none, image not pulled). Fix commit titled "Restrict Pillow image formats on untrusted media paths", v0.32.0. |

### Published since the last scan but NOT findings

- GHSA-q97c-p368-75c4 (medium, `<= 0.30.0`): out-of-vocabulary token id crash. The advisory's own
  applicability text limits it to models whose vocab is an exact multiple of 64 with no padding
  headroom (it names the Llama-2 family and says Qwen2.5 is not affected). Inferred — not measured:
  the served checkpoint is Qwen-family, and its tokenizer/config were not read this run
  (`gh api repos/vllm-project/vllm/security-advisories/GHSA-q97c-p368-75c4` description).
- GHSA-823j-m4cj-hmjf (high, `> 0.24.0, < 0.31.0`): MOSS-Audio processor cache — different model
  family, not served here. Range hits; condition does not.
- GHSA-8c65-hq7q-r7jm (`>= 0.11.1, < 0.18.0`), GHSA-w9r6-29q4-pvpr (`>= 0.20.1, < 0.29.0`),
  GHSA-x567-49g5-p4cf (`>= 0.16.0, <= 0.23.0`), GHSA-6757-hggm-hp2w (`<= 0.25.1`): fixed at or below
  0.29.0 — ranges do not cover the pinned base. Command: per-advisory
  `gh api repos/vllm-project/vllm/security-advisories/GHSA-… --jq '.vulnerabilities'`.

### Release state and recorded-defect re-check

Measured: `gh api repos/vllm-project/vllm/releases` (2026-10-23) — newest release is still **v0.32.0**
(2026-10-18); no release since the last scan. Patch 8 re-check: `gh api
repos/vllm-project/vllm/pulls/55122` → `state=open merged=null` — the deterministic top-k fix is still
NOT upstream; the bundled kernel remains required, unchanged from the scan above. Pinned base
unchanged: `grep -nE 'ARG VLLM|FROM vllm' Dockerfile` → `FROM vllm/vllm-openai:v0.30.0`. What the
v0.31.0 patch-collision analysis above says still holds and now also applies to v0.32.0.

### Profile drift (published vs served)

`git diff --stat <prior-baseline>..origin/main -- profiles/` (prior-baseline = the BASELINE sha of the
scan above) → empty; nothing under `profiles/` changed since the scan above, and `profiles/published.env` still parses as before
(`grep -c . profiles/published.env`). The decode-figure mismatch against the README table remains
tracked on the open issue titled "profiles/published.env desc quotes … tok/s … where the README
table says …". The *served* profile on the GPU host remains not inspectable from here (role file:
host access none) — host-side drift is **Unknown**, not measured clean. No new drift finding.

## What would change this file

Any owner decision to move the base image, or a new advisory whose range covers 0.30.0 and whose
configuration conditions match `scripts/serve.sh`. Re-run: `python3 scripts/version-watch.py
--repo qwen3.8-Flash-DGX --dir <clone> --advisories` plus the commands cited above.

---

FINDINGS_REPORTED

— cp-hermes-01 · 2026-10-18T19:10Z
