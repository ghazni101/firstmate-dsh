# DSH-native Firstmate overhaul — handoff

**Date:** 2026-11-16
**Workspace:** `/home/ghazni/ttttt/firstmate-dsh`
**Status:** 12 design decisions settled; no implementation started.
**Read first:** `AGENTS.md`, `docs/architecture.md`, `docs/configuration.md`, then this page.

## Goal

Make Firstmate's supervisor layer DSH-native while worker agents stay on herdr and the other harnesses. Replace the single fleet owner with task-scoped ownership. Preserve the existing safety boundaries: no unlanded work torn down, no merge outside the task's project posture, no captain-facing noise.

## Twelve settled decisions

| # | Axis | Decision |
|---|------|----------|
| 1 | DSH-native form | A DSH plugin bundle; DSH is the only supervisor runtime. Workers remain on herdr/other harnesses. |
| 2 | Ownership | Task-scoped: any session may claim any queued task in its own home. No fleet-wide owner. |
| 3 | Conflict control | Per-task lease with TTL, heartbeat, and a fencing token. |
| 4 | Durable truth | Flat files under `data/` and `state/`; the plugin is a typed layer over them. |
| 5 | Supervision | Per-home reconciliation loop with event hints; durable files remain cross-process truth. |
| 6 | Run posture | Hybrid: one headless supervisor per home plus interactive DSH sessions. |
| 7 | Sub-homes | Keep them as independent scopes; no main/child hierarchy. |
| 8 | Merge authority | The task's project posture, enforced on the current lease holder. |
| 9 | Migration | Incremental strangler in place; old paths keep working during each step. |
| 10 | Claim scope | A session claims only from its own sub-home's task pool. Cross-home work moves by explicit handoff. |
| 11 | Headless role | Peer owner plus stale-lease reaper; no special authority. |
| 12 | Sub-home form | A directory scope with its own `FM_HOME`; one DSH profile serves many homes. |

## Derived rules (not separate decisions)

- The fleet-wide session lock disappears. A narrow **maintenance lease** remains only for operations that genuinely need one writer: bootstrap network, fleet sync, self-update, capacity allocation.
- Lease expiry never kills a worker and never discards unlanded work. It fences the stale owner's writes; a new owner reconciles.
- The headless supervisor merges only tasks it holds, under that task's project posture. It has no fleet-wide merge authority.
- Merge authority follows the task's project, not the session's identity.
- The DSH plugin does not replace herdr. It calls the existing spawn/control layer for worker execution.
- A session never claims into another home's pool.
- Event hints are latency only. Cross-process coordination uses lease/status files.
- DSH session identity replaces harness process-ancestry sniffing. This is what removes the current read-only lock failure.

## Starting assets

**Existing DSH plugin** — `@local/dsh-plugin-firstmate` v0.3.0, source at `/home/ghazni/projects/firstmate/dsh-plugin` (tracked in that firstmate checkout, linked into `~/.dsh/profiles/web`). It currently provides session-start digest injection, a hosted supervisor daemon with quiet/away posture, a `bin/fm-*.sh` command channel, lock-ownership gating, typed supervisor tools, and the DSH harness marker. It is explicitly built around the single-owner lock ("the plugin owns only DSH transport; Firstmate's scripts own posture, classification, the wake queue, gating, merges, and policy"). That division is the philosophy being replaced. Inspect it for reusable transport and home-resolution code; do not preserve its lock gating.

**Existing lease library** — `bin/fm-lease-lib.sh` already implements a per-task lease, but for exactly two actors (`main`/`branch`) whose staleness is tied to the session-lock holder pid. It is a useful atomic-file reference; the new design needs N task-scoped owners, explicit fencing tokens, TTL/heartbeat renewal, and stale-lease reaping independent of a home-wide lock.

## First increment

A DSH plugin skeleton that provides:

1. Session identity and home resolution (`FM_HOME` from session context; skip subagents and directories outside a home).
2. Read-only fleet tools (`status`, `tasks`, `inbox`).
3. A per-task lease library with atomic acquire/renew/release, fencing tokens, TTL, and stale-lease reaping.
4. The existing engine still authoritative behind it.

Do not start with a GUI, a watcher rewrite, or an AGENTS.md rewrite. Identity plus leases are the foundation; every later phase composes on them.

## Constraints and context

- The current session is read-only because `bin/fm-session-start.sh` cannot locate a harness process in DSH's ancestry, so `bin/fm-lock.sh` is unverified. Treat this as the first bug that native plugin identity removes, not as a reason to keep patching process-name matching.
- Preserve hard safety rules from `AGENTS.md`: no unlanded work teardown, no merge without authority, crewmates never address the captain.
- The repo is a template; `data/`, `state/`, `config/`, and `projects/` are private and gitignored.
- Existing plugin tests encode the old single-owner philosophy; use them for transport behavior, not as the new contract.
- The twelve decisions above are the contract. Do not reopen them without a concrete conflict; record any new decision here.

## Next actions

1. Classify what is reusable in the existing plugin: home detection, tool registration, runtime-context injection, follow-up transport.
2. Write `docs/dsh-native-architecture.md`: lease protocol, home resolution, plugin tool surface, reconciliation loop, and strangler phases.
3. Implement the first increment behind a feature flag; keep the current supervisor path usable.
4. Add tests for lease acquire/contention/expiry/fencing and cross-home claim refusal.

## Decision log (appended during phase 0)

The twelve settled decisions are unchanged. Implementing phase 0 required five derived
choices; each is recorded here so a later phase inherits one answer instead of re-deciding.
The architecture page is the owner of the mechanism: `docs/dsh-native-architecture.md`.

1. **Lease record format is JSON** (`state/leases/<task>.lease`), not TSV, so Node and a
   bash `jq` caller read one shape and the record can carry purpose, times, and TTL.
2. **The per-task mutex is a `mkdir` directory** with a 5 s staleness bound, not a file lock,
   because `mkdir` is atomic on every supported filesystem and a crashed critical section
   recovers by age.
3. **`pid` in a lease record is diagnostic only.** TTL is the sole staleness contract, so a
   lease held by a session on another host or through a transient process is still judged
   by its heartbeat, never by `kill -0`.
4. **Home anchors drop `bin/fm-watch-arm.sh`.** Identity requires `AGENTS.md` +
   `bin/fm-session-start.sh` + `bin/fm-spawn.sh`, so retiring the watcher in phase 3 cannot
   invalidate identity.
5. **The bundle ships inert.** The plugin row defaults to `enabled: false` and each home
   additionally needs `config/dsh-native`; the prior bundle stays linked in the `web` profile
   until phase 1. No profile change was made in this increment.

Also recorded: the maintenance lease reuses the task record under the reserved id
`maintenance`, rather than a differently shaped file.

## Landing notes from phase 0

- `docs/dsh-native-architecture.md` and `dsh-plugin/README.md` are new tracked prose
  surfaces. When they are committed, add both to `docs/documentation-audiences.json`
  (`maintainer-architecture` and `operator-current` respectively); until they are tracked,
  the inventory check treats them as out of scope.
- `bin/fm-doc-audience-check.sh` currently fails before any of this work for an unrelated
  reason: `CONTRIBUTING.md` still links `.github/workflows/ci.yml`, which the latest commit
  removed. Do not read that failure as a regression from this increment.
- Phase 1 starts by promoting `dsh-plugin/bin/fm-lease.mjs` to the bash adapter behind
  `config/dsh-native-lease`; the prior bundle and the shell supervisor stay untouched until
  then.

## Phase 1 status (built, tested, linked disabled)

- `dsh-plugin/lib/fm-lease2-lib.sh` is the bash adapter
  (`fm_lease2_acquire/renew/release/inspect/reap/guard/check/live_token`), pinned to one holder
  identity per shell so an acquire inside `$(...)` matches its later guard.
- `firstmate_lease` (acquire/renew/release/inspect/reap) and `firstmate_run` (read-only scripts
  direct; mutating scripts under the task's lease) are registered behind the same flags.
- Test suite: `cd dsh-plugin && node --test test/*.test.mjs` - 62 passing, all against
  temporary homes.
- Profile: the bundle is linked into the `web` profile as a second bundle with its row config
  `enabled: false`; the prior bundle remains the active transport. Enabling the new row while
  the old bundle is active shadows the overlapping tool names, so the phase-3 swap disables the
  old row at the same time.
- No `bin/` script sources the adapter yet; that is phase 2 behind `config/dsh-native-lease`.

## Phases 2-5 status (built end to end, profile still disabled)

Phase 2 (mutating `bin` entrypoints): one seam instead of six edits. `bin/fm-lease-lib.sh`
routes `fm_lease_guard` / `fm_lease_forbid_branch` to `bin/fm-native-lib.sh` when
`config/dsh-native-lease` exists. A native mutation must present `FM_LEASE_TOKEN` and
`FM_LEASE_SESSION` (and the matching `FM_LEASE_TASK`); it refuses otherwise, never reads
`state/.lock`, and treats the branch partition as a no-op. Legacy homes are unchanged;
`tests/fm-send-inbox.test.sh` and `tests/fm-approval-failover.test.sh` still pass.

Phase 3 (loop): `dsh-plugin/src/reconcile.js`, `dsh-plugin/bin/fm-reconcile.mjs`, and the
`firstmate_reconcile` tool. Selection is rule-driven from `config/native-loop.json`; merge
rules are gated by `bin/fm-project-mode.sh` posture; every action runs under the task lease.
End-to-end tests drive the real native guard seam with fake workers, prove one winner between
concurrent ticks, recover a crashed holder by expiry with a higher token, and refuse a
cross-home tick.

Phase 4 (identity): `firstmate_native_start` composes startup input without session-start and
without the fleet lock; tests assert `state/.lock` stays absent. Ancestry code remains for
non-native homes.

Phase 5 (retirement): the native path is complete and lock-free. Physical deletion of the
single-owner machinery is deliberately deferred: every un-migrated home and the prior bundle
still use it, and deletion cannot be verified here. Recorded as the residual.

Decisions added during phases 2-5:

6. The engine seam is the two lease functions the entrypoints already call, not six per-script
   edits; a native mutation requires a presented token rather than acquiring one implicitly,
   because the plugin channel and the loop are the only actors that take leases.
7. Loop selection is home-authored JSON rules with placeholders, not project policy in code;
   merge actions require a posture read and skip when it is not yolo.
8. The profile row stays `enabled: false`: enabling it while the prior bundle is active
   shadows `firstmate_status`/`firstmate_run` profile-wide, which would degrade un-migrated
   homes. Enabling is the phase-3 swap and must disable the prior row at the same time.
