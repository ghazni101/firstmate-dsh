# Firstmate native supervisor (DSH plugin)

The DSH-native Firstmate supervisor layer: session and home identity, per-task leases, a
lease-guarded command channel, a per-home reconciliation loop, and a native startup path — all
without the fleet-wide session lock. Worker execution stays with the existing engine
(`bin/fm-spawn.sh`, `bin/fm-control.sh`, `bin/fm-send.sh`) and the herdr/other harnesses.

The contract is [`docs/dsh-native-architecture.md`](../docs/dsh-native-architecture.md), with
the twelve settled decisions in
[`docs/plans/2026-11-16-dsh-native-overhaul-handoff.md`](../docs/plans/2026-11-16-dsh-native-overhaul-handoff.md).

## What it provides

- **Identity.** A root DSH session whose working directory resolves to a Firstmate home gets a
  session identity (`SessionHeader` + home). Subagents and directories outside a home are
  ignored. No process-ancestry sniffing, no fleet lock.
- **Task leases.** `src/lease.js` plus `bin/fm-lease.mjs`: atomic acquire, TTL, heartbeat,
  fencing tokens, stale-lease reaping, cross-home refusal. `lib/fm-lease2-lib.sh` is the bash
  adapter; `bin/fm-native-lib.sh` is the engine seam.
- **Tools.** Read-only fleet tools (`firstmate_native_status`, `firstmate_native_tasks`, `firstmate_native_inbox`),
  lease control (`firstmate_native_lease`), a lease-guarded command channel (`firstmate_native_run`), one
  reconciliation tick (`firstmate_native_reconcile`), a lock-free native startup input
  (`firstmate_native_start`), and per-PR delivery decisions (`firstmate_native_delivery`).
- **Reconciliation loop.** `src/reconcile.js` and `bin/fm-reconcile.mjs --once|--loop`: reap,
  observe, select from home-authored rules, lease-then-act, report. Merge rules are gated by
  the resolved delivery decision for that PR/task: a durable per-PR record first, then a
  per-task record, then the project registry ([delivery decisions](../docs/delivery-decisions.md)).
  Rules may use `{delivery_mode}`, `{yolo}`, and `{delivery_source}` placeholders.
- **Native engine guard.** When a home carries `config/dsh-native-lease`,
  `bin/fm-lease-lib.sh` routes `fm_lease_guard` / `fm_lease_forbid_branch` to
  `bin/fm-native-lib.sh`, so the existing mutating entrypoints enforce the DSH lease instead
  of the fleet lock. A mutation without a live token/session is refused.
- **Native startup.** `firstmate_native_start` composes identity, readiness, backlog, lease,
  and wake-queue state without running `fm-session-start.sh` and without reading `state/.lock`.

## Wiring a native home

```text
<home>/config/dsh-native            # opt in to the plugin surface
<home>/config/dsh-native-lease      # opt in to lease enforcement in bin/ entrypoints
<home>/config/native-plugin-dir     # one line: this plugin package root, for bin/ callers
<home>/config/native-loop.json      # the loop's authored rules (see below)
```

The plugin exports `FM_NATIVE_PLUGIN_DIR` to every script it runs, so `native-plugin-dir` is
only needed when the engine is invoked directly from a shell.

Example loop configuration:

```json
{
  "tick_ms": 15000,
  "max_actions_per_tick": 3,
  "rules": [
    {
      "id": "dispatch",
      "when": "queued",
      "kind": "ship",
      "script": "fm-spawn.sh",
      "vars": { "project": "demo", "mode": "direct-PR", "yolo": "off" },
      "args": ["{id}", "{project}", "--mode", "{mode}", "--yolo", "{yolo}"]
    }
  ]
}
```

A rule never names a supervisor-lifecycle script. Merge rules (`fm-pr-merge.sh`,
`fm-merge-local.sh`) additionally need `vars.project` and run only when the resolved delivery
decision reads yolo and the matching mode; a per-PR record can turn that on or off for one
PR without touching the project registry.

The per-PR switch itself lives in the engine and is shared with every harness:

```sh
bin/fm-delivery.sh set --pr <url> --pipeline off --reason "docs-only"
bin/fm-delivery.sh resolve --pr <url> --project <name>
```

## Headless loop

```sh
node bin/fm-reconcile.mjs --home "$FM_HOME" --once            # report one tick
node bin/fm-reconcile.mjs --home "$FM_HOME" --once --apply    # execute one tick
node bin/fm-reconcile.mjs --home "$FM_HOME" --loop --apply    # headless supervisor engine
```

The loop writes `state/.native-loop-beat` each tick and stops on SIGINT/SIGTERM. Several loops
in one home are safe: every action runs under the task lease, so a second loop contends
instead of double-acting, and a loop that loses its lease stops writing.

## Feature flags

| Flag | Default | Effect |
| --- | --- | --- |
| Loader row `config.enabled` | `false` | Registers nothing. |
| `<home>/config/dsh-native` | absent | Enables tools and the native surface for that home. |
| `<home>/config/dsh-native-lease` | absent | Enforces the native lease in `bin/` entrypoints. |

## Tests

```sh
cd dsh-plugin
node --test test/*.test.mjs
```

Every test runs against temporary homes: lease protocol, bash adapter, native engine guard,
tool surface, reconciliation loop, and the end-to-end chain (tick or channel → lease → real
engine guard seam → mutation, including the holding lease session the channel exports),
including concurrency, crash recovery, posture gating, and cross-home refusal. No live fleet,
no network.

## Engine compatibility

- A home without `config/dsh-native-lease` is byte-for-byte unchanged; the existing lease
  tests and `tests/fm-send-inbox.test.sh` / `tests/fm-approval-failover.test.sh` still pass.
- The native path never reads or writes `state/.lock`; tests assert the file stays absent.
- The two-actor `main`/`branch` lease and its `bin/fm-lease.sh` command surface are retired; the
  native guard requires `FM_LEASE_TOKEN` + `FM_LEASE_SESSION` (and the matching
  `FM_LEASE_TASK`) from the plugin channel or the loop; a direct shell mutation without them
  refuses with exit 6.
- Expiry only fences writes: it never kills a worker, discards unlanded work, or marks a task
  done.

## Installation status

Linked in the `web` profile as a second bundle. The native surface uses a distinct
`firstmate_native_*` tool namespace, so enabling it alongside the prior bundle
(`@local/dsh-plugin-firstmate` v0.3.0) does not shadow that bundle's tools. Sessions in a home
without `config/dsh-native` see the native tools and get a clear refusal; the prior bundle's
tools keep their current behavior. The phase-3 swap removes the prior bundle once every home
is native.
