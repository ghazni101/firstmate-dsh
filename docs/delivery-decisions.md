# Per-PR delivery decisions

How Firstmate decides whether a pull request must go through **no-mistakes** or may be
delivered directly, and how to change that decision for one PR.

A project's registered posture ([`bin/fm-project-mode.sh`](../bin/fm-project-mode.sh) over
`data/projects.md`) answers the default. This page owns the durable, PR-scoped override that
sits above it, so "gate this PR" or "skip the pipeline for this one" is a recorded decision
rather than a chat instruction.

The delivery decision is **not** pipeline execution. `bin/fm-nm-run-lib.sh` and the
[no-mistakes agent skill](https://kunchenguid.github.io/no-mistakes/) own running, driving, and
reading a no-mistakes run; this layer only decides which delivery path is required.

## What the switch decides

| Decision | Meaning |
| --- | --- |
| `no-mistakes` | The task's change is delivered through the gate: push the task branch to the `no-mistakes` remote, let the pipeline validate it, and let the pipeline open the PR. |
| `direct-PR` | The change is pushed and a PR is opened directly, without the pipeline. |
| `local-only` | The change lands locally with no remote push and no PR. |

`yolo` is separate: it is merge authority, never the delivery path. `yolo=inherit` keeps the
project registry's merge authority while overriding only the delivery path.

## Resolution order

First match wins; the losing more-specific record is reported as `shadowed`, never hidden.

1. **PR record** — keyed by the canonical pull/merge-request identity.
2. **Task record** — keyed by the task id.
3. **Project registry** — `bin/fm-project-mode.sh <project>` over `data/projects.md`.
4. **Unregistered default** — no-mistakes, yolo off (project-mode's own fallback).

A record names a delivery path, optionally a `yolo` value, and optionally the project used to
look up the merge posture. An unknown project still resolves through project-mode's default,
so removing the registry entry changes the fallback, never the record.

## Where the decision is stored

```text
<home>/data/delivery/task-<task-id>.record
<home>/data/delivery/pr-<host>_<owner>_<repo>_<number>.record
```

One flat `key=value` record each (no `jq` dependency), written atomically:

```text
fm-delivery-v1
version=fm-delivery-v1
key=pr-github.com_example_repo_12
kind=pr
task=fm-example
pr_url=https://github.com/example/repo/pull/12
branch=fm/fm-example
project=example
delivery=direct-PR
yolo=inherit
reason=skip the pipeline for this one
decided_at=2026-11-16T12:00:00Z
supersedes=previous:no-mistakes inherit
previous=no-mistakes inherit
```

A changed decision supersedes the old one and keeps the previous value; history is never
rewritten in place. The record is durable intent: a forge label, a chat message, or a PR
comment is not a decision until it is written here (a label importer is a deliberate future
extension, and it would write this record rather than bypass it).

## Command surface

```sh
bin/fm-delivery.sh resolve --task <id> [--pr <url>] [--project <name>] [--words]
bin/fm-delivery.sh get (--task <id> | --pr <url>)
bin/fm-delivery.sh set (--task <id> | --pr <url>) --mode <mode> [--yolo on|off|inherit] \
    [--pipeline on|off] [--reason <text>] [--project <name>]
bin/fm-delivery.sh clear (--task <id> | --pr <url>)
bin/fm-delivery.sh list
bin/fm-delivery.sh enforce-task <id> <mode> <yolo>
```

`--pipeline on` is shorthand for `--mode no-mistakes`, `--pipeline off` for
`--mode direct-PR`. `clear --task` also removes the task's PR record when the task metadata
names a PR, so the fallback is immediate. Exit codes: `0` ok, `1` no record, `2`
usage/invalid, `6` decision conflict.

The native supervisor exposes the same surface as the `firstmate_native_delivery` tool
(`resolve`, `get`, `set`, `clear`, `list`); a task-scoped write takes that task's lease, so two
sessions cannot race the decision.

## Enforcement points

The switch is not advisory:

- **Dispatch.** `bin/fm-spawn.sh` calls `fm-delivery.sh enforce-task` after validating
  `--mode`/`--yolo`. A fresh ship whose explicit values contradict an existing task or PR
  record is refused before any backend or worktree work, with the recorded decision named.
  Registry and default postures stay intake inputs, so ordinary dispatch is unchanged.
- **Merge.** The native reconciliation loop resolves the decision for the task/PR before a
  merge action. A per-PR `direct-PR` decision on a gated project skips the merge action; a
  per-PR `no-mistakes` decision on a direct-PR project still requires yolo before the loop
  touches it. The project registry remains the fallback when the decision layer is absent
  (for example, a checkout older than this feature).
- **Delivery instructions.** The brief renders its Definition-of-done block from the resolved
  mode, so the worker sees the same path the record demands.

## What is not enforced (yet)

A merge action can require *evidence* that the gate actually validated the PR, not just the
recorded intent. That evidence already exists in the engine
(`bin/fm-nm-run-lib.sh`, run attribution in `bin/fm-crew-state.sh`), but tying it to the merge
gate is a separate change: it must decide what proves a run validated the exact head being
merged and what to do for a PR validated outside this home. Until then, `no-mistakes` is
enforced as the required delivery path, and merge authority remains the recorded yolo posture
plus the existing check/route guards.

## Turning it on or off for one PR

```sh
# Skip the pipeline for one PR, keeping the project's merge authority.
bin/fm-delivery.sh set --pr https://github.com/example/repo/pull/12 --pipeline off --reason "docs-only change"

# Require the pipeline for one PR on a direct-PR project.
bin/fm-delivery.sh set --pr https://github.com/example/repo/pull/13 --mode no-mistakes --yolo inherit

# Back to the project registry.
bin/fm-delivery.sh clear --pr https://github.com/example/repo/pull/12

# What applies right now?
bin/fm-delivery.sh resolve --pr https://github.com/example/repo/pull/12 --project example
```

The next dispatch of that task or the next merge tick reads the new decision. The record is
home-local: a secondmate home makes its own decision, and a cross-home handoff must carry the
decision as part of the handoff record rather than writing another home's `data/`.
