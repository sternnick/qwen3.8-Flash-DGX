# ops/ — operational notes and tooling

Supporting material for running this recipe on a single DGX Spark host. It is deliberately
**additive**: no upstream file is modified, and the deployment clone stays a clean checkout, so
`git merge --ff-only origin/main` keeps working.

Nothing in here changes serving behaviour, and no service was stopped or started to produce it.
All measurements were taken on the host (container and image inspection, engine and kernel logs,
`/proc`) or from upstream registries and issue trackers.

## Contents

| path | what it is |
|---|---|
| `docs/01-serving-audit.md` | the configuration under audit, measured behaviour, determinism and multimodal results, memory headroom, and this deployment's exposure to each known issue |
| `docs/02-update-runbook.md` | how to update: the four detection axes, patch inventory and their build-time guards, start/rollback procedure, post-update verification, baselines to compare against |
| `docs/03-dependency-drift.md` | a snapshot of every consumed repository and artifact, plus the method notes for checking them without false positives |
| `docs/04-options-evaluated.md` | options measured and rejected, with the numbers, and a list of retracted claims so they do not resurface |
| `scripts/update-check.sh` | read-only drift detector for the four axes; writes `drift=0\|1` |
| `scripts/memwatch.sh` | host memory monitor; monitor-only unless deliberately enabled |
| `scripts/rollback.sh` | container rollback; read-only by default, renames instead of deleting, restores service if the attempt fails |
| `scripts/vision-probe.sh` | single- and two-image request probe |
| `scripts/ttft-probe.sh` | multi-turn time-to-first-token probe |

## Configuration

Every script takes its environment from variables rather than hard-coded paths:
`REPO_DIR`, `LOG_DIR`, `HF_CACHE`, `CONTAINER`, `API_PORT`, `CHECKPOINT`, `KPIN_BASE`
(derived from `Dockerfile` when unset). Run them from a checkout, or point `REPO_DIR` at one.

Two safety properties are intentional and should be preserved when editing:

- `update-check.sh` performs no `git fetch`, no build and no container operation.
- `memwatch.sh` can only stop a container if **both** `ENFORCE=1` is set in its environment and
  the marker file `LOG_DIR/ENFORCING` exists. Out of the box it logs and does nothing else.
  `rollback.sh` defaults to `--check`; `--yes` is required to act, and it renames the container it
  replaces rather than removing it.

Scheduling is a local decision; a conservative pairing is one daily `update-check.sh` and a
five-minute `memwatch.sh`, both writing under `logs/`.

## Licensing

Apache-2.0, in line with the upstream repository. External projects are cited for comparison
and none of their code is copied here; in particular the only AGPL-3.0 component in one of the
surveyed variants is explicitly excluded from any porting discussion (see
`docs/02-update-runbook.md` §2).

## Note on branch placement

This directory is developed on a working branch so that `main` in this fork remains an exact copy
of upstream and continues to fast-forward. Merging it into `main` is a one-command decision, but
it trades away that property.
