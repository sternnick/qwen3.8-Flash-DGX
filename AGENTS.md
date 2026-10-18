# AGENTS.md — sternnick/qwen3.8-Flash-DGX

Agent-facing map for this repository. Human-facing prose stays in `README.md`.

**Automated and scheduled agents:** the governing document is the cross-repository contract at
`docs/agents/HERMES-CONTRACT.md` in `sternnick/pi-agent`, version `1.3.0`. Read it at the start of
every run. This file is a map plus hard boundaries; it deliberately does not restate the contract,
because a second copy of a rule is the copy that goes stale.

## Repository map

- `Dockerfile` + `profiles/*.env` — the served configuration; the published profile is the contract
- `scripts/` — serve, smoke-test, weight download, probe
- `src/`, `flash/` — the serving wrapper and its patches
- `docs/HISTORY.md` — what was measured and when; a decision record, not current state

## Read before editing

- `docs/agents/hermes.md` — this repository's Hermes role delta
- `docs/HOW-IT-WORKS.md` — named by this repository as authority
- `docs/HISTORY.md` — named by this repository as authority
- `profiles/published.env` — named by this repository as authority

- If a nested `AGENTS.md` exists closer to the file you are changing, that file wins over this one.

## Authoritative commands

Read-only, safe to run, and the only accepted evidence for a claim about this repository. If one of
them cannot run, that is a finding — do not substitute an invented command.

- **script syntax** — `for f in scripts/*.sh; do bash -n $f || exit 1; done`
- **pinned upstream version** — `grep -nE 'ARG VLLM|FROM vllm' Dockerfile`
- **published profile present** — `test -f profiles/published.env && grep -c . profiles/published.env`

## Boundaries

- This repository is PUBLIC: never commit or quote a hostname, token, or private-infrastructure fact
- You do not serve, restart, pull weights, or touch the GPU: report what to build and hand it to the owner
- A version bump here is an owner decision; you report the advisory or the fixed defect and stop

## Artifacts this repository excludes from automated work (§3a R14)

Read this before skipping anything. If you must not touch an artifact, it is listed here or
it is not a directive — §15a.

_no exclusions are declared for this repository. If you find yourself skipping an artifact because someone said so, that is a finding against the registry and §16 — not a reason to stay quiet._

## Work Unit Rule

Every scheduled run that touches a repository delivers exactly one bounded work unit. A work unit
is one item from a queue (one row, one issue, one file) OR one atomic change-set (one behavior, one
fix, one docs change). A run completes within 30 minutes. If a unit cannot complete in 30 minutes,
split it further. The artifact is a PR; a run without a PR is a failed run. Never bundle multiple
units into one run. Queue IDs are claimed at run start from `origin/main` AND all open PRs on the
repository — any ID present in either is taken. GitHub open PRs are the claim ledger; no merge is
required for a claim to be visible. Before starting, the run lists open PRs
(`gh pr list --state open --json title,headRefName`) and skips any ID already claimed. Merge cadence
is the owner's decision and does not block production. Never merge. Never push to main.

## Signature Rule

Every artifact this agent produces carries a signature so the owner can filter what it produced
versus what it reviewed:

- **PR body:** first line is `### cp-hermes-01 · YYYY-MM-DD · <queue-id>` (or `<task-id>` when no
  queue id applies).
- **Commit message:** last line is `Signed-off-by: cp-hermes-01 <cp-hermes-01@sterniotis.com>`.
- **Journal, report, or issue comment:** last line is `— cp-hermes-01 · <ISO-8601 UTC timestamp>`.

The commit author remains the owner's GitHub identity; the trailer is the agent's signature.
No artifact without a signature is posted.

## Fact Provenance Rule

Every factual claim, in any repository, that a scan or run touches carries three fields, regardless of
the file format that holds it:

- **`last_verified_utc`** — ISO-8601 UTC of the most recent confirmation.
- **`verified_by`** — the identity that confirmed it.
- **`verification_method`** — `url-fetch`, `primary-source`, `cross-check`, or `inherited`.

A run that does not re-verify a fact must not update `last_verified_utc`; it may only mark the fact
stale, with the date it was found stale. A run that re-verifies updates all three. No artifact is
posted without these fields on every fact it touches. The field names and values are fixed by this
rule; the column, key, or inline form each repository uses is the repository's own choice.

## Review Rule

Every pull request opened or updated in any fleet repository is eligible for review. A review run
reads the diff, the linked issue, and the touched files; researches whether the change breaks
anything, whether tests are present, whether documentation is updated, and whether it violates any
fleet rule; and posts one review comment with findings and suggestions. If the review finds a
concrete fix, it opens a separate PR against `main` with the proposed change — it never
modifies the original PR's branch. It never merges, never force-pushes, never writes to
`main`. Every review comment carries the Signature Rule and the Fact Provenance Rule on
every factual claim. A review without evidence is not posted. A repository without branch protection
on its default branch is not review-eligible — open a finding against the repository instead.

## Protected Domain Rule

Certain directories, services, and subsystems are off-limits to the agent — no read, no execute,
no investigation, no comment. The owner declares them. The protected list lives in
`docs/agents/protected-domains.json` in this repo. Before any read or command, the agent checks the
list. A finding that touches a protected domain is filed as one stub issue: `OUT OF SCOPE —
protected domain: <path>`, with no investigation. A violation is a gate failure.

## Completion contract

- Every claim names a command that ran in this session, the target it ran against, and its output.
- Run the checks above before and after any change, and report both results, not just the last one.
- Delivery is a branch plus an open pull request. **Never merge. Never push `main`.**
- Every artifact you write ends with the signature line the contract requires.
- Write mode for scheduled runs in this repository: `branch_pr`.

<!-- generated by scripts/hermes-governor.py from docs/agents/hermes-fleet.json — do not hand-edit -->
