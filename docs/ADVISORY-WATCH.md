# Advisory watch — served stack

The pinned base (`Dockerfile:10`, `FROM vllm/vllm-openai:v0.30.0`) and our patch set checked against
upstream advisories and releases. This file records the state of that watch; a version bump is an owner
decision (root `AGENTS.md`, Boundaries). Report only — nothing here was installed, upgraded, or restarted.

Scan of 2026-10-18 (baseline `1cb2db2`): last_verified_utc `2026-10-18T19:00Z` · verified_by `cp-hermes-01`
· verification_method `cross-check` (GitHub advisory database + upstream release diffs, commands below).

## Advisories published against `vllm` and applicability to the served configuration

Sources: `gh api "repos/vllm-project/vllm/security-advisories?per_page=100"` (100 records, queried
2026-10-18) and each advisory's detail page via `gh api repos/vllm-project/vllm/security-advisories/GHSA-…`.

| advisory | sev | range stated | affects 0.30.0? | applicability to this repo's served config |
|---|---|---|---|---|
| GHSA-6cxc-2vcg-w5qc | low | ≤ 0.30.0 | **yes** | Serving-layer output-integrity bug: `InputBatch.condense()` can leak one request's `allowed_token_ids` mask onto another client's request under concurrent batching. Needs guided/`allowed_token_ids` traffic and slot-reuse timing — whether that traffic reaches our endpoint is host-dependent (Unknown from repo evidence). Fix vllm#43931 merged 2026-09-27, ships in v0.31.0 (verified by `gh api repos/vllm-project/vllm/compare/v0.30.0...v0.31.0` commit list). |
| GHSA-4xqp-c3mv-qff7 | medium | < 0.31.0 | range yes | **Not mounted in our config.** Single-request DoS through `/inference/v1/generate`. On v0.30.0 that route registers only with `--enable-scale-out` or `--tokens-only` — both default `False` (upstream `vllm/entrypoints/launchers/cli_args.py:179,184` at tag v0.30.0) — and `scripts/serve.sh` passes neither (grep `scale_out|tokens.only|tokens-only` over `scripts/serve.sh`: no matches). |
| GHSA-rhcx-5729-88vg | high | ≥ v0.8.5 | range yes | Not applicable: needs a `KVConnectorBase_V1` subclass (LMCache/NIXL/…). `scripts/serve.sh` configures no kv-transfer connector (grep `kv.transfer|connector`: no matches). |
| GHSA-h3rc-6mm3-gc2m | high | ≥ 0.7.3 | range yes | Not applicable: needs `--trust-remote-code` and a multimodal `auto_map` processor. Neither is used here (grep `trust.remote|trust_remote` over `scripts/serve.sh` and `flash`: no matches; text-only checkpoint). |
| GHSA-rh6f-3x46-j33q | medium | < 0.31.0 (field) | — | Conflicting data: the advisory's own description says confirmed on ≤ 0.25.1. Site B is a prefix-cache block-hash collision (LoRA name vs `cache_salt`) and prefix caching is on here (`PREFIX_CACHE=1` default), but no LoRA or `cache_salt` use is configured; the structured range field and the description disagree — reported as-found, not adjudicated. Fix (#51899, #59335) is in v0.31.0. |
| GHSA-p92p-rxj5-7p2x, GHSA-4m6g-h9mv-wqjc | med/high | < 0.31.0 | range yes | Multimodal (image/video) paths; not applicable to this text-only serving recipe. |

Advisories patched at or below 0.30.0 (GHSA-85xf…, GHSA-2823…, GHSA-25q3…, GHSA-wpww…, GHSA-v5gm…,
etc.) are already fixed in the pinned base and are not findings.

`v0.32.0` (2026-10-18) lists GHSA-4hhp…, GHSA-q97c…, GHSA-frvg… fixes plus a CORS default change;
GHSA-frvg (P2P ZMQ) needs multi-node/P2P connectors — not our config. The CORS change (#61009) is
behavioral for anyone fronting the API; noted for the bump decision, not a finding on its own.

## Upstream fixes for defects this repository recorded (registry condition: fix for a recorded defect)

Both landed in **v0.31.0** (2026-10-05). Verified by the v0.30.0→v0.31.0 commit list
(`gh api repos/vllm-project/vllm/compare/v0.30.0...v0.31.0`) and by the file diff below:

- **Patch 7 (fp8 KV on the QSA path, issue #6)** is upstream as vllm#55557 ("Qwen4Exp: fp8_e4m3 main
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
becomes adaptive (#57951, #58459) — re-measure the profile's `EXTRA` value on any bump.

## Profile-drift check (published vs served)

`profiles/published.env` parses as valid `serve.sh` variables (`MODE=nvfp4`, `YARN=1`, `CTX=500000`) and
is consistent with the README profile table and `serve.sh` defaults except for its `# desc` decode figure
(~28 tok/s) against the README table's ~26 tok/s — already tracked on the open issue titled
"[SEV4] profiles/published.env desc quotes … tok/s … where the README table says …". The *served* profile
on the GPU host is not inspectable from here (role file: host access none), so host-side drift is
**Unknown** from repo evidence, not measured clean.

## What would change this file

Any owner decision to move the base image, or a new advisory whose range covers 0.30.0 and whose
configuration conditions match `scripts/serve.sh`. Re-run: `python3 scripts/version-watch.py
--repo qwen3.8-Flash-DGX --dir <clone> --advisories` plus the commands cited above.

---
— cp-hermes-01 · 2026-10-18T19:10Z
