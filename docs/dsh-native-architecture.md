# DSH-native supervisor architecture

How Firstmate's supervisor layer becomes native to DeepSeek Harness (DSH) while worker
agents stay on herdr and the other existing harnesses.

This page is the implementation contract for the twelve settled decisions in
[`docs/plans/2026-11-16-dsh-native-overhaul-handoff.md`](plans/2026-11-16-dsh-native-overhaul-handoff.md).
It replaces the single fleet owner described by [`docs/architecture.md`](architecture.md) with
task-scoped ownership, and it is deliberately incremental: the current shell supervisor keeps
working while each phase lands.

Current behavior of the shell engine remains owned by [`docs/architecture.md`](architecture.md)
and [`docs/configuration.md`](configuration.md). Where this page and those disagree about a
path that phase 0 has not migrated yet, the existing page still owns the live behavior.

## 1. Scope and non-goals

In scope:

- What identifies a DSH session, and how it resolves the Firstmate home it may act in.
- The per-task lease: the only ownership primitive below the home.
- The plugin's tool surface and runtime-context contribution.
- The per-home reconciliation loop and where merge authority comes from.
- The incremental migration order and its rollback points.

Explicit non-goals:

- Replacing worker execution. Workers keep running on herdr and the other harnesses through
  `bin/fm-spawn.sh`, `bin/fm-control.sh`, `bin/fm-send.sh`, and the existing backends.
- A fleet-wide owner, a fleet-wide queue, or a fleet-wide merge authority.
- A GUI. Nothing in this plan starts with a browser surface.
- A watcher rewrite as the first step. Watchers keep running, unchanged, until phase 3.
- Re-litigating the twelve decisions. New decisions are appended to the handoff page's
  decision log.

## 2. Tenancy model

There are three levels, and only the middle one grants authority.

| Level | What it is | Authority |
| --- | --- | --- |
| Fleet | Every home on every host | None. No process, session, or record owns a fleet. |
| Home (`FM_HOME`) | One operational scope: `data/`, `state/`, `config/`, `projects/` | A task pool and a maintenance scope. No single owner. |
| Task | One backlog item inside one home | Exactly one lease holder at a time. |

Rules that follow:

- A session may claim only from the task pool of the home it resolved for itself
  (section 3.3). It never claims into another home.
- Cross-home work moves by **explicit handoff**: a durable record is written in the source
  home, and the target home's own session claims it there. No session writes another home's
  task state.
- Two sessions in the same home are peers. They may work different tasks concurrently, and
  they may contend for the same task, which the lease resolves.
- Sub-homes stay independent scopes (decision 7). There is no main/child hierarchy in the
  supervisor layer; the existing secondmate registry remains a routing convenience, not an
  authority chain.

The fleet-wide session lock (`state/.lock`) is retired. In native homes it is replaced by:

- the per-task lease for task work, and
- the narrow **maintenance lease** for the four operations that genuinely need one writer in
  a home: bootstrap network, fleet sync, self-update, and capacity allocation (section 4.8).

## 3. DSH session identity and home resolution

### 3.1 Identity

A supervisor identity is derived from the DSH session itself, not from process ancestry, not
from environment markers, and not from a lock file:

```text
identity = {
  session_id,      # SessionHeader.id (branded SessionId, string form)
  agent_id,        # Agent.id, equal to session_id for Materialized agents
  home,            # absolute canonical home this session may act in
  cwd,             # SessionHeader.cwd
  preset,          # SessionHeader.agentPreset, diagnostic only
  owner_label,     # "dsh:<session_id>", the lease owner string
}
```

Verification used by the first increment, from the installed DSH contract
(`@deepseek-ai/dsh-session` `SessionHeader`):

- `id`, `cwd`, `parentSession`, `origin: 'subagent'`, `delegationDepth`, `agentPreset`.
- `parentSession` alone does **not** classify a session as a subagent; historical forks
  retain it. Classification uses `origin === 'subagent'` or `delegationDepth > 0`.
- `Agent.id` and `Session.id` are the same value for a normal agent.

A session is a **supervisor candidate** only when it is a root session (`origin` is not
`subagent`, `delegationDepth` absent or 0) whose `cwd` resolves to a home. Subagent sessions
never register tools, never inject supervisor context, and never acquire leases. This is the
whole reason the current read-only failure disappears: `bin/fm-lock.sh` proving a harness
process in the shell's ancestry is no longer part of identity.

The plugin publishes the existing `FM_HARNESS_DSH=1` marker for its children only so the
shell engine still reports `dsh` from `bin/fm-harness.sh`. That marker is a compatibility
declaration, not authority.

### 3.2 Home resolution

Resolution order, first match wins, every candidate canonicalized with `realpath`:

1. `config.home` on the plugin row, when it names a home.
2. The closest ancestor of `SessionHeader.cwd` that is a home.
3. `FM_HOME`, when it is itself a home (never walk upward from it).
4. The closest ancestor of the plugin process's working directory that is a home.

A candidate is a home only when all of these exist (the "home anchors"):

```text
<dir>/AGENTS.md
<dir>/bin/fm-session-start.sh
<dir>/bin/fm-spawn.sh
```

`bin/fm-watch-arm.sh` is intentionally not an anchor, so retiring the watcher in phase 3
cannot invalidate identity. A directory that contains none of the anchors above it resolves
to **no home**, and the plugin stays inert in that directory.

The Firstmate home is resolved per session, not per process: one DSH process may serve
several homes (decision 12), so the configured home is a fallback and the session `cwd` is
the primary signal.

### 3.3 Acting outside the session's home is a refusal

Every tool and lease call takes the identity's `home` as the only home it may touch. A call
naming another home is refused with the `cross-home` code before any file is read or written.
This is enforced in two places:

- `assertSameHome(identity, home)` compares canonical paths and refuses.
- The lease record carries its own `home`; renewing, releasing, or guarding a record whose
  `home` differs from the caller's canonical home is a `cross-home` refusal even if the file
  was copied in.

### 3.4 Native opt-in per home

Identity is not opt-in; the mutation and tool surface is. A home opts in by creating:

```text
<home>/config/dsh-native        # presence enables the native plugin surface for that home
```

The plugin row's `config.enabled` gates registration for the whole profile; the home marker
gates use for one home. With `enabled: false` (the default) `apply()` registers nothing, so
linking the bundle cannot change behavior for any existing home.

## 4. The per-task lease

The lease is the only task ownership record. It is a small file in the home, read and written
by the plugin and by `bin` scripts through one CLI. It replaces the two-actor
`state/.lease-<task>` contract in [`bin/fm-lease-lib.sh`](../bin/fm-lease-lib.sh), which
stays available unchanged for the old path until phase 4.

### 4.1 Files

```text
$FM_HOME/state/leases/<task>.lease        # one JSON record, atomically replaced
$FM_HOME/state/leases/.<task>.lock/       # mkdir mutex, held for microseconds
```

`<task>` is validated as `^[A-Za-z0-9][A-Za-z0-9._-]*$`. A leading `.` is refused so the
mutex namespace and the record namespace cannot collide, and `maintenance` is reserved for
the maintenance lease (section 4.8). The leases directory and the records are home-local
operational state; they are not replicated and are safe to lose only at teardown of the task
they describe.

### 4.2 Record

```json
{
  "v": 1,
  "task": "fm-demo",
  "state": "held",
  "token": 7,
  "owner": "dsh:01J9Z6K3W8",
  "session": "01J9Z6K3W8",
  "home": "/home/example/firstmate",
  "pid": 48211,
  "purpose": "land PR",
  "acquired_at": 1764000000000,
  "renewed_at": 1764000030000,
  "ttl": 120000,
  "released_at": null
}
```

Fields:

| Field | Meaning |
| --- | --- |
| `v` | Record format version. Readers refuse an unknown major version. |
| `state` | `held` or `free`. Records are never deleted while the task exists. |
| `token` | Fencing token. Monotonic per task record, `0` while never claimed. |
| `owner` | The holder identity label (`dsh:<session>`). |
| `session` | Session id spelled separately for diagnostics and audit. |
| `home` | Canonical home that owns this record. |
| `pid` | Diagnostic only; never used for staleness. |
| `purpose` | Free label naming the operation, shown in refusal text. |
| `acquired_at` / `renewed_at` | Epoch milliseconds of the current hold. |
| `ttl` | Hold validity in milliseconds, chosen by the acquirer. |
| `released_at` | Epoch milliseconds of the last release, or null. |

A record that fails to parse is treated as **free with token 0** by `acquire` (which replaces
it and reports a warning) and as an error by renew, release, and guard; the reaper leaves it
alone. An unreadable record must not grant anything, and must not permanently wedge a task
either. Readers that do not take the mutex may observe a previous or a new complete
record, never a torn one.

### 4.3 Mutex

All transitions happen under `mkdir` on `$FM_HOME/state/leases/.<task>.lock`, with the
holder's pid and start time written inside. The mutex is a microseconds-scale critical
section:

- Acquire: `mkdir`; on `EEXIST`, if the lock directory's age exceeds `lockStaleMs` (5000),
  remove it and retry; otherwise sleep 10 ms and retry until `lockWaitMs` (2000) is
  spent, then fail with `busy`. Both bounds are measured on the wall clock against the
  directory's filesystem mtime, never on an injected lease clock (`now`).
- Release: remove the directory; failure to remove is logged and ignored because the
  `lockStaleMs` bound recovers it.
- The mutex is not the lease. It never outlives one transition, and its age is the only
  staleness signal.

Atomic record replacement: write `.<task>.lease.tmp.<pid>.<rand>` in the same directory,
then `rename` over the record. `rename` within one directory is atomic on POSIX and on
Windows (`fs.renameSync` replaces).

### 4.4 Operations

All operations are synchronous. Times may be injected for tests (`now`), and the CLI/plugin
always passes the real clock.

**acquire(home, task, identity, purpose, ttl) -> record**

1. Validate `task`, canonicalize `home`, `assertSameHome`.
2. Take the mutex.
3. Read the record, or treat it as `{state:'free', token:0}`.
4. If `state === 'held'`:
   - `live = now - renewed_at < ttl_record`;
   - same owner and session: refresh `renewed_at`, keep `token`, return (idempotent
     re-acquire; this is how a session re-enters a task it already holds);
   - live and a different owner: fail `contention`, naming the holder and the remaining TTL;
   - not live: transition to `free` with `reaped_at = now`, keep `token`, continue.
5. `token = record.token + 1`; write `state:'held'` with the new owner, times, `ttl`, and
   `purpose`; return the record.
6. Release the mutex.

**renew(home, task, identity, token, ttl?) -> record**

1. Validate and `assertSameHome`; take the mutex.
2. Unreadable record: fail `invalid-record`. No record or `state !== 'held'`: fail `not-held`.
3. `record.token !== token`: fail `fenced`, naming the live token (this is the stale holder).
4. Owner or session mismatch: fail `fenced`.
5. `now - renewed_at >= ttl`: mark `free` with `reaped_at`, fail `expired` (the caller is
   fenced by time even if nobody reaped it yet).
6. Update `renewed_at`, and `ttl` when supplied; write; return.

**release(home, task, identity, token) -> record**

1. Validate and `assertSameHome`; take the mutex.
2. No record or already free: succeed idempotently (retry-safe).
3. `token` mismatch or owner mismatch: fail `fenced`; a stale holder never frees the new
   holder's lease.
4. Write `state:'free'`, `released_at = now`; return.

**inspect(home, task) -> record | null**

Lock-free read. Reports `live`, `remaining_ms`, and `holder`. Used by diagnostics and by
read-only tools. Never mutates.

**reap(home, now) -> reaped[]**

Scan `state/leases/*.lease`; for each `held` record past its TTL, take the mutex, re-read,
and transition to `free` with `reaped_at`. It never deletes a record and never touches a live
one. It runs at the top of every reconciliation tick (section 6) and before a claim.

**guard / withLease(home, task, identity, purpose, fn)**

`withLease` = acquire, start a heartbeat, run `fn(handle)`, stop the heartbeat, release.
The heartbeat renews at `max(5000, floor(ttl / 3))`. If a renewal fails with `fenced` or
`expired`, the handle records that refusal as `fenced` and the operation must stop before its
next durable write; the plugin surfaces the fence in the result instead of pretending the write succeeded.
A fenced holder never continues on optimism: the fencing token exists so a later writer is
the only writer.

### 4.5 Fencing

The token is the write-lease. A mutation is authorized only when the actor presents the
current token, and the token increments on every claim of the record, including a claim that
follows expiry or reaping. Consequences:

- A holder that stalled past its TTL cannot renew, release, or mutate through the guard; its
  next token-bearing call fails `fenced`.
- A new holder always writes with a strictly greater token, so a durable effect that records
  its token (a status line, a merge record, a backlog transition note) can be reconciled:
  effects carrying a stale token are the ones to inspect and, if unlanded, to redo, not to
  delete.
- Fencing is cooperative within one uid. The threat model is the same
  confused-agent-grade boundary the existing engine documents: guards stop accidental
  concurrent writes, not a deliberately forging shell.

### 4.6 Expiry never kills work

Lease expiry is a write fence, not a lifecycle action. It never:

- kills, signals, interrupts, or relaunches a worker;
- tears down a worktree;
- deletes unlanded work;
- marks a task done, failed, or cancelled;
- rewrites a status log or a backlog transition.

Expiry means "this holder may no longer write". A new holder reconciles the durable state
first (section 6.3) and only then acts. The existing teardown refusal for unlanded work
([`bin/fm-teardown.sh`](../bin/fm-teardown.sh)) remains the only teardown gate and is not
weakened by a lease.

### 4.7 Cross-home claims and handoff

- The lease API and CLI refuse `home !== identity.home` with `cross-home` (exit 6).
- Handoff is a durable record in the source home and a later claim in the target home
  (`bin/fm-backlog-handoff.sh` / `bin/fm-backlog-receive.sh` remain the owners of the record).
  The supervisor never moves a lease file between homes.
- A lease record's `home` field is authoritative for that record. A record found in the
  wrong home is an integrity error, not a claim.

### 4.8 The maintenance lease

The only remaining home-wide mutual exclusion, and it is deliberately narrow:

```text
$FM_HOME/state/leases/maintenance.lease    # same record format, reserved task id
```

`maintenance` is a reserved lease id (section 4.1) and cannot be claimed as a task.
Reserved purposes: `bootstrap-network`, `fleet-sync`, `self-update`, `capacity-allocate`.
Default TTL 300000 ms. `acquireMaintenanceLease` is the only way to take it: an ordinary
acquire of the `maintenance` id (lease tool, run channel, or CLI) is refused with `usage`, and
a purpose outside the reserved four is refused too. It is meant to be acquired by the
operation that needs it, released immediately after, and never held across a worker's task
work. No `bin/` operation acquires it yet; the four operations above still run without it. It
does not grant task authority: a maintenance holder may not claim, steer, merge, or teardown a
task.

### 4.9 What the lease does not own

Not the lease's business: project posture, delivery-mode rigor, merge authority, backlog
schema, status semantics, worker liveness, teardown eligibility, or the wake queue. Those
stay with their current owners in [`bin/`](../bin/) and the skills. The lease answers exactly
one question: "may this actor mutate this task now, and with which token?"

### 4.10 Command surface

`dsh-plugin/bin/fm-lease.mjs` is the one CLI, usable by bash callers and by tools:

```text
fm-lease.mjs acquire --home <dir> --task <id> [--purpose <text>] [--ttl-ms <n>]
fm-lease.mjs renew   --home <dir> --task <id> --token <n>
fm-lease.mjs release --home <dir> --task <id> --token <n>
fm-lease.mjs inspect --home <dir> --task <id>
fm-lease.mjs reap    --home <dir>
fm-lease.mjs guard   --home <dir> --task <id> --token <n> -- <command> [args...]
```

The identity's home comes from `--home` and must equal `FM_HOME` when `FM_HOME` is set, so a
bash caller cannot claim with a mismatched environment. Output is one JSON object on stdout.
Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 2 | Usage, invalid task id, or a home that is not a home. |
| 3 | Not held, expired, or an unreadable record that grants nothing. |
| 4 | Fenced: the presented token is stale. |
| 5 | Contention: a live holder owns the task. |
| 6 | Cross-home refusal. |
| 7 | Mutex busy past `lockWaitMs`. |

A bash caller keeps its `bin/fm-lease-lib.sh` path until phase 2; the CLI script `fm-lease.mjs`
is the adapter that phase 2 wires in behind `config/dsh-native`.

### 4.11 Which mutating entrypoints enforce the lease

In a home that records `config/dsh-native-lease`, `fm_lease_guard`
([`bin/fm-lease-lib.sh`](../bin/fm-lease-lib.sh) routing to
[`bin/fm-native-lib.sh`](../bin/fm-native-lib.sh)) refuses with exit 6 unless the caller
presents `FM_LEASE_TOKEN` and `FM_LEASE_SESSION` for a live lease on that exact task (and a
matching `FM_LEASE_TASK` when set), verified through `fm-lease.mjs guard`. A task id that
cannot name a lease record is refused too. Without the marker the guard is inert.

| Entrypoint | Lease-enforced |
| --- | --- |
| `bin/fm-send.sh` (steer to a task) | Yes |
| `bin/fm-control.sh` (interrupt, exit, relaunch) | Yes |
| `bin/fm-teardown.sh` | Yes |
| `bin/fm-approval-failover.sh` | Yes |
| `bin/fm-pr-merge.sh` | Yes |
| `bin/fm-merge-local.sh` | Yes |
| `bin/fm-spawn.sh` (fresh spawn) | No: exempt |

A fresh spawn is exempt because it creates the task row it would need a lease for: no lease
can exist for a task that does not exist yet. It keeps its existing fencing through the
per-task spawn lock and the backlog transition it performs, and `fm_lease_forbid_branch`
still applies to it outside a native home. The plugin channel and the reconciliation loop
export the lease variables for every script they run under a lease, so those paths satisfy
the guard; a direct shell invocation of an enforced entrypoint must present a live lease
the same way.

## 5. Plugin surface

### 5.1 Bundle and feature flags

```text
dsh-plugin/
  package.json          @local/dsh-plugin-firstmate-native, version 0.2.0
  cordis.patch.yml      row id firstmate-native, config { enabled: false }
  index.js              apply(ctx, config)
  src/home.js           home anchors, resolution, canonicalization
  src/identity.js       DSH session identity and per-agent registry
  src/lease.js          the protocol in section 4
  src/scripts.js        bound script runner (FM_HOME pinned, marker set, timeouts)
  src/transport.js      follow-up delivery helper
  src/reconcile.js      one reconciliation tick (observe, select, lease-then-act)
  src/delivery.js       typed per-PR/per-task delivery decision caller
  src/engine-records.js durable engine records, routing batches, escalation store
  src/engine.js         per-session engine host (fork, ticks, wake, close)
  src/errors.js         one refusal/exit-code space for the lease and the CLI
  bin/fm-lease.mjs      the lease CLI
  bin/fm-reconcile.mjs  the per-home loop CLI (--once / --loop)
  lib/fm-lease2-lib.sh  the bash adapter
  test/*.test.mjs       node --test, temporary FM_HOME fixtures
```

Feature flags:

| Flag | Default | Effect |
| --- | --- | --- |
| plugin row `config.enabled` | `false` | Registers nothing; the plugin is inert. |
| `<home>/config/dsh-native` | absent | Enables tools and native lease use for that home. |
| `<home>/config/dsh-native-lease` | absent | Phase 2: enforces lease guards inside `bin` scripts. |
| `<home>/config/dsh-engine` | absent | Enables the per-interactive-session supervision engine (section 6.8). |

The prior bundle `@local/dsh-plugin-firstmate` v0.3.0 stays installed and linked until phase 3
replaces its transport. Both bundles are installed in the `web` profile. The native surface
registers under a distinct `firstmate_native_*` tool namespace, so enabling the native row
alongside the prior bundle cannot shadow that bundle's tools; a session in a home without
`config/dsh-native` gets a clear refusal from the native tools while the prior bundle keeps
its behavior. The phase-3 swap removes the prior bundle once every home is native.

### 5.2 Identity listener and runtime context

On `agent/created` with source `startup` (and `resume`/`clear`/`compact` for re-entry) the
plugin:

1. Resolves the identity (section 3). If there is no root session or no home, it does
   nothing at all.
2. Records the identity in a per-agent map used by tools. Tool calls from an agent that was
   never registered re-resolve from `exec.agent.session.header`, so a tool call is never
   blocked merely because the agent predates plugin activation.
3. When the home is opted in, contributes one static runtime-context section:

```text
Firstmate native session for home <home> (session <id>).
Ownership: one task at a time through that task's lease; no fleet-wide owner exists.
Cross-home work must be handed off; this session cannot claim another home's task.
Read-only fleet tools are available; task mutations require holding that task's lease.
```

The contribution is registered through `agent.ctx.systemPrompt.context({ name:
'firstmate:native-identity', order: 130, interpolate: false, text })` and its disposer is
kept. Text must be static: the Harness resolves a context provider twice per step, so a
one-shot function returns nothing on the admitted pass.

No session-start digest is injected in phase 0. The digest, the reconciliation loop, and the
turn-end arming remain the old plugin's and the shell engine's job until phase 3.

### 5.3 Read-only tools

Registered only when `enabled: true`; each refuses when the resolved home is not opted in or
when the call names a home other than the session's. None takes a lease, because none writes.

| Tool | Engine command | Notes |
| --- | --- | --- |
| `firstmate_native_status` | `fm-bearings-snapshot.sh --json` | Optional `include_prs` for live forge discovery. Bounded output; never mutates. |
| `firstmate_native_tasks` | `fm-tasks-axi.sh list ...` | Optional `state`, `limit`, `fields`, `blocked`. Passes the home's own backlog backend through. |
| `firstmate_native_inbox` | `fm-inbox.sh ready` \| `list` \| `receipts --all-pending --json` | Readiness, human note list, and pending receipts. |
| `firstmate_native_lease` | (in-process lease library) | `acquire`, `renew`, `release`, `inspect`, `reap` one task lease. The returned token is the fencing token. |
| `firstmate_native_run` | one allowlisted `bin/fm-*.sh` | Read-only scripts run directly; a mutating script requires a `task` and runs under that task's lease (taken for the call, or the caller's held `token`), exporting `FM_LEASE_HOME/TASK/TOKEN/SESSION/OWNER`. Session-lifecycle scripts are refused. |
| `firstmate_native_reconcile` | (in-process loop tick) | One reconciliation tick; dry-run by default, `apply` executes authored rules under leases, `hint` delivers a follow-up when captain attention is needed. |
| `firstmate_native_start` | `fm-fleet-snapshot.sh`, `fm-inbox.sh`, lease directory | Read-only native startup input: identity, readiness, backlog/task summary, held leases, and queued durable wakes. Never runs session-start and never mutates anything. |
| `firstmate_native_delivery` | `fm-delivery.sh` | Resolve, read, write, clear, or list a per-PR/per-task delivery decision (no-mistakes vs direct delivery). Task-scoped writes hold the task lease. Owned by [`delivery-decisions.md`](delivery-decisions.md). |
| `firstmate_native_engine_inbox` | (engine records) | **Engine only.** Read and acknowledge this engine's durable traffic batches. |
| `firstmate_native_escalate` | (engine record + `ctx.subagents.sendMessage`) | **Engine only.** Record and deliver one captain-relevant outcome into its own parent session (section 6.11). |

A supervision engine child (section 6.8) resolves the read-only fleet tools, the lease, the
guarded command channel, the reconciliation tick, its inbox, and escalation. Ordinary subagents,
deeper subagent forks, and unmatched children are refused. `firstmate_native_start` and
`firstmate_native_delivery` remain interactive-session-only.

Shape of every result:

```json
{ "ok": true, "home": "...", "tool": "firstmate_native_status", "format": "json" | "text",
  "data": {}, "text": "...", "truncated": false, "exit_code": 0 }
```

Output is capped (48000 characters) with `truncated: true` rather than dropped. A tool never
runs a script outside its fixed allowlist, and no tool takes a script name from the model.

The command channel (`firstmate_native_run`, arbitrary `bin/fm-*.sh`) is deliberately **not** part of
phase 0: it is the surface that carried the old lock gating, and it returns in phase 2 with
lease-based classification instead of lock-based classification.

### 5.4 Follow-up transport

The reusable transport from the old plugin is kept:

- Build a `UserMessage`: `{ id: randomUUID(), role: 'user', content: [{ type: 'text', text }],
  source: { kind: 'user' } }`.
- Deliver with `agent.followup(message)`, which wakes the agent, unlike `agent.inject()`
  which only queues context.
- Mark internal input by wrapping it through `bin/fm-operational-input.sh encode
  away-supervisor` when that owner is present; otherwise prefix the text with the
  supervisor tag.
- Deduplicate unread hand-backs by message id, and clear the entry on
  `agent/inbox/claimed` / `agent/inbox/discarded`.

In the native design this transport is **latency only** (decision: event hints are not
truth). It is used from phase 3 to nudge a session that a lease was released or a task became
actionable; every decision is re-derived from durable files.

### 5.5 What the plugin must not do

- Read `state/.lock`, prove ownership by pid, or gate anything on lock ownership. Those are
  the single-owner concepts being removed.
- Arm or host the watcher, the supervisor daemon, or the supervision host as an authority.
- Enter a quiet or away posture itself.
- Write posture records, wake queues, status logs, or backlog transitions directly.
- Register a session-start digest in phase 0.
- Kill, signal, interrupt, or tear down anything.

## 6. Per-home reconciliation loop

### 6.1 Actors

A home may run any combination of:

- **Interactive sessions**: captain-facing DSH sessions in the home. They claim tasks when
  the captain asks for work.
- **A headless supervisor**: one DSH session per home running a preset whose only job is the
  reconciliation loop. It is a peer owner (decision 11): it claims queued tasks exactly like
  an interactive session, under the same leases, with the same merge-authority rules, plus
  stale-lease reaping. It has no special authority and no fleet-wide scope.

Two loops in one home are safe: every mutation sits behind a per-task lease, and every
reconciler re-reads durable state rather than trusting memory.

### 6.2 Tick

Selection is rule-driven from a home-local `config/native-loop.json`. A rule names
`when` (`queued`, `in_flight`, or `any`), an optional `kind`, one allowlisted
`bin/fm-*.sh` script, its `args` with `{id}`/`{kind}`/`{repo}`/`{pr_url}`/`{state}`
placeholders, optional static `vars` (such as `project`), and a `timeout_ms`.
Rules never name a supervisor-lifecycle script. Blocked queued rows are reported as
skipped, not acted on. Merge rules (`fm-pr-merge.sh`, `fm-merge-local.sh`) additionally
require `vars.project` and are skipped unless `bin/fm-project-mode.sh` reads a yolo
posture compatible with the rule (PR merge: `no-mistakes`/`direct-PR`; local landing:
`local-only`). The loop never invents project policy.

The engine implements the tick both in-process (`firstmate_native_reconcile`, and
`dsh-plugin/src/reconcile.js`) and as `dsh-plugin/bin/fm-reconcile.mjs --once|--loop`,
which is the headless supervisor's engine: it writes `state/.native-loop-beat` per tick,
runs until SIGTERM, and needs no fleet lock.


One tick, default every 15000 ms and additionally on an event hint:

1. **Reap**: `reap(home)` for expired held leases; release nothing else.
2. **Observe**: read durable state only — `state/*.meta`, `state/*.status` tails, backlog
   rows, inbox notes, recorded PR/landing records, registered checks. Use the existing
   current-state readers (`bin/fm-crew-state.sh`, `bin/fm-fleet-snapshot.sh`) rather than
   adding another parser.
3. **Classify**: reuse the existing classification libraries and scripts; the loop does not
   reimplement status verbs, waits, or merge outcomes.
4. **Select**: actionable items for this home only, ordered by (a) captain-held decisions
   waiting on this home, (b) failed/blocked work, (c) PR ready / landing, (d) queued work
   whose dependencies and project capacity allow dispatch.
5. **Lease-then-act**: for each selected task, `acquire(home, task, identity, purpose, ttl)`;
   on `contention` skip and retry next tick; on success re-read the home and act only when
   the same rule still selects the task (otherwise report it `stale`), check merge authority,
   run the action, then `release`.
6. **Publish**: append the durable record the action owns (status line, transition, merge
   record) carrying the lease token where that owner supports it. Deliver one follow-up hint
   only when a captain-relevant outcome needs an interactive session.
7. **Sleep** until the next tick or an event hint.

### 6.3 Lease-then-act, always reconcile first

The order is fixed:

1. Acquire (fencing token).
2. Reconcile the task's durable state from disk, through the existing readers.
3. Act only on that read.
4. Release.

A new holder that acquires after a crashed or expired holder must assume the previous holder
may have written half an operation: it inspects the task's status log, backlog row, worktree
state, PR record, and merge record before doing anything. It never "rolls back" by deleting
records or discarding unlanded work; it completes, or it reports.

### 6.4 Merge authority

Merge authority comes from the **resolved delivery decision** for the task/PR, checked while
holding that task's lease:

- `bin/fm-delivery.sh resolve` supplies the effective mode and `yolo`: a per-PR record, then a
  per-task record, then `bin/fm-project-mode.sh` over `data/projects.md` ([the full order and
  record format](delivery-decisions.md)).
- A per-PR decision can require the pipeline for one PR on a direct project, or skip it for one
  PR on a gated project; the merge action follows the resolved decision, not the registry
  alone.
- A lease holder may merge only the task it holds, only when that task's recorded delivery
  mode and posture allow it, and only through the guarded merge scripts
  (`bin/fm-pr-merge.sh`, `bin/fm-merge-local.sh`).
- A lease never grants merge authority by itself, and being the headless supervisor grants
  nothing extra.
- A red or missing required check is still refused. Only a current explicit instruction that
  names the check and the PR can waive it.
- Destructive, irreversible, and security-sensitive merges still escalate.

### 6.5 Event hints

Event hints are latency only:

- `agent/inbox/*` events, status-file mtime ticks, and lease release notifications may wake
  the loop early.
- A hint never carries authority and is never the source of truth. If a hint is lost,
  duplicated, or arrives out of order, the next tick recomputes the same decision from
  durable files.
- Hints are home-local. A hint from another home is ignored except through the handoff
  record.

### 6.6 Crash recovery

- A crashed loop leaves held leases that expire by TTL; the next loop or the next interactive
  session reaps them.
- A crashed loop's in-flight operation is reconciled from durable state by the next holder.
- A session that resumes (`resume`/`clear`/`compact`) re-resolves identity and does not
  resume its old leases: they are expired or released, and it re-acquires by token.
- Wake queues remain durable and idempotent; their internal short locks remain home-local
  implementation detail, not ownership.

### 6.7 Invariants the loop must preserve

1. No unlanded work is torn down.
2. No merge outside the task's project posture.
3. Workers never address the user; only the supervisor relays outcomes.
4. Lease expiry never kills a worker or discards work.
5. A session never claims into another home.
6. No fleet-wide owner exists; no loop waits on a fleet-wide lock.
7. Every durable write that belongs to a task happens under that task's lease token.
8. Expired, fenced, or unreadable lease state fails toward "do not write", not toward
   "assume it is mine".

### 6.8 Engine session per interactive session

An interactive root session can carry one headless **engine**: a durable DSH child session whose
only job is to absorb routine supervision traffic so the interactive conversation only receives
captain-relevant outcomes. It is the native equivalent of the Claude Code home's separate
supervision host.

- **One engine per root session, at most.** The plugin writes one durable engine record per
  parent session. A second host for the same session adopts or replaces that record; it never
  runs two live engines for one parent.
- **Exact lineage.** The engine is created through `ctx.subagents.startActivation` with the
  in-process `fork` provider, `delivery: 'caller'`, and the interactive agent as `parent`. The
  child's header therefore carries `origin: 'subagent'`, `delegationDepth: 1`, and
  `parentSession` equal to that interactive session. The composition must register the
  in-process fork backend under the provider name `fork`; if it is missing, creation records
  an actionable failure and never touches the parent.
- **Seeded once.** The `fork` provider seeds the child with the parent's completed-turn prefix
  through the last `turn/end`; the in-flight turn is never seeded. The prefix is captured at
  creation and becomes part of the child's own durable transcript, so a later cold resume
  replays that prefix instead of re-forking newer parent history. A resumed interactive
  session (`resume`/`clear`/`compact`) marks its old engine superseded and gets a fresh engine
  forked from its then-completed turns on the next tick.
- **Lazy.** Creation waits for the session's first supervision need: a task it claims through
  the lease tool or dispatches through the guarded run channel. The first tick after that need
  creates the fork, so the dispatch turn is already completed and available to the seed. A
  quiet session with no engine creates none and costs nothing.
- **Marker.** DSH exposes no plugin-writable custom session metadata. The explicit marker is
  the plugin's durable record, written with status `creating` immediately before the child is
  started and matched against the child's own lineage. Ordinary subagents, deeper
  subagent-forked sessions, and children whose id does not match a live record stay refused.
- **Gating and route.** `<home>/config/dsh-engine` opts the home in; absent means off. The
  engine's model and effort come from the home's own `config/crew-dispatch.json` `default`
  profile, translated to DSH `agentOptions` (`provider`, `model`, `reasoningEffort`); with no
  default profile declared, the fork inherits the interactive session's route. A malformed
  dispatch default is an actionable tick error, never a silent parent-route fallback.

Records live under the home's state:

```text
$FM_HOME/state/engines/<parent>.json               engine identity, status, model, last seen map
$FM_HOME/state/engines/<parent>.inbox.json         routine traffic batches routed to the engine
$FM_HOME/state/engines/<parent>.escalations.json   engine-to-parent escalations and delivery state
```

### 6.9 Engine tool surface

The engine sees only the engine surface:

| Tool | Engine use |
| --- | --- |
| `firstmate_native_status`, `firstmate_native_tasks`, `firstmate_native_inbox` | Read durable fleet state. |
| `firstmate_native_lease` | Acquire, renew, release, inspect, or reap task leases under the engine's own owner label. |
| `firstmate_native_run` | The guarded command channel; a mutating run holds that task's lease. |
| `firstmate_native_reconcile` | One authored reconciliation tick under task leases. |
| `firstmate_native_engine_inbox` | Read and acknowledge this engine's durable traffic batches. |
| `firstmate_native_escalate` | Record and deliver one captain-relevant outcome into its own parent session. |

`firstmate_native_start` and `firstmate_native_delivery` stay interactive-session-only. Engine
tools never address the captain: an escalation is the only channel into the interactive
session, and it is wrapped by the plugin rather than authored as captain chat. An engine may
mutate a task only while holding that task's lease; contention with its own parent session or
another session's engine is a normal refusal, not an error.

### 6.10 Notification routing and cost

The plugin runs one deterministic loop per engine host:

1. **Tick inputs.** An interval tick plus a debounced `fs.watch` signal on the home's
   `state/` directory for `.status` and `.meta` appends. Signal delivery is latency only.
2. **Observe.** `fm-fleet-snapshot.sh --json` through the existing reader. Its task rows already
   carry the classification output of `bin/fm-classify-lib.sh`: `pending_decision`,
   `blocked_event`, `open_decisions`, the classified last verb, and the captain-hold projection.
3. **Classify coarsely.** Only those existing fields are read; the plugin never re-implements
   status verbs or hold policy. An event is tagged `captain` when a reader already marked it
   pending, blocked, open, captain-actionable, or a terminal outcome; otherwise `routine`.
4. **Diff.** The engine record stores the last task-signature map. Only added or changed tasks
   become a batch; an unchanged fleet produces no message.
5. **Route.** One batch per tick is appended to the engine inbox, then delivered with
   `ctx.subagents.sendMessage(parentAgent, engineSession, …)`, which wakes a live engine or
   cold-resumes a dormant one. When the engine is being created, the batch is written before
   the fork starts and the creation prompt points at it, so the bootstrap turn can never race
   an empty inbox.

A tick consumes **no model turn**. The engine wakes only for an actual batch or a due
escalation retry, so a quiet fleet costs nothing. The engine's own turn is where judgment
happens; it re-derives every decision from durable records rather than trusting the batch text.

### 6.11 Escalation record and delivery

`firstmate_native_escalate` is the engine's only path into captain-facing conversation:

1. The plugin writes a durable escalation record under
   `state/engines/<parent>.escalations.json` **before** attempting delivery.
2. It delivers with `ctx.subagents.sendMessage(engineAgent, parentSessionId, …)`, the same-tree
   cross-session steer an engine is allowed to use toward its own parent. The message is
   wrapped in a stable engine-escalation tag; the engine's outcome is the body.
3. Identical outcomes deduplicate: the id is derived from the parent session and an explicit
   `key`, or from the task and outcome text. A duplicate that is still undelivered retries
   delivery instead of appending a second record.
4. Delivery failure is recorded with a bounded exponential backoff. The next deterministic
   tick includes due, un-nudged escalations in the next batch and instructs the engine to
   retry them by `retry_id`. A nudge throttle (one window per escalation) prevents a wake loop
   when an engine repeatedly fails to deliver. A lost wake therefore recovers from durable
   state, and a flapping engine does not wake itself forever.
5. An engine can only target its own `parent_session`; the tool takes no target argument.

### 6.12 Engine lifecycle and failure

- **Creation failure** writes a `crashed` record with the error and never touches the parent;
  the next tick retries.
- **Crash detection.** The host follows its activation's result. A settled turn is normal
  (the manager releases the activation and a later `sendMessage` cold-resumes it). A failed
  turn or a rejected wake marks the record `crashed` and releases any live activation.
- **Recovery.** The next tick sees a non-live record and creates a fresh fork from the
  parent's then-completed turns. The parent session, its leases, and every worker are
  untouched.
- **Parent end.** `agent/disposed` on the interactive session stops the tick and marks the
  engine record `closed`; the engine is disposed if it is still live. The parent is never
  disposed, reset, or steered by engine cleanup.
- **Resume.** A resumed interactive session supersedes its previous engine record before the
  host starts, so the next fork reflects the resumed history.
- **Foreign owner.** If a record still names a live different process, the tick skips it
  rather than forking a second engine for that session.
- **Plugin unload.** Timers and watchers stop and live activations are disposed without marking
  the record terminal, so an in-process reload adopts the same durable engine.

### 6.13 Parallel-session invariants

1. N interactive sessions in one home may each run their own engine. Engines are peers under
   the unchanged per-task lease; none holds fleet-wide authority.
2. Every task mutation stays behind that task's lease. Two engines contending for one task
   produce exactly one winner; the loser sees an ordinary contention refusal.
3. An engine may never take a task its own interactive session holds, or one another session's
   engine holds. The owner label is the engine session id, so the lease resolves it.
4. Duplicate observation is safe. Each engine may read the same fleet snapshot; every decision
   is re-derived from durable records, so a second engine's identical read changes nothing.
5. An engine observes for its own parent only and escalates only into that parent's session.
   There is no cross-parent escalation channel.
6. Engines never address the captain and never appear as backlog owners or fleet-wide actors.
7. Merge authority and delivery rigor are still resolved per task; being an engine grants
   nothing extra.
8. Engine records, inboxes, and escalation stores are per parent, so one session's engine
   cannot read or corrupt another's traffic.
9. The deterministic tick is model-free; the engine model wakes only for judgment or an
   escalation retry. A quiet fleet costs no turns.
10. Retirement of the single-owner machinery remains gated as in phase 5; this mechanism adds
    no fleet-wide owner and no new shared lock.

## 7. Strangler phases

Each phase is independently shippable, keeps the old path working, and has a rollback (the
feature flag or the old bundle).

### Phase 0 — Foundation (this increment)

Deliverables: this page; `dsh-plugin/` skeleton with identity, home resolution, read-only
tools, follow-up helper, the N-owner lease library and CLI; tests with temporary `FM_HOME`
fixtures. Nothing is installed, the profile is unchanged, no `bin/` script changes, the old
bundle keeps running.

Exit criteria:

- `cd dsh-plugin && node --test test/*.test.mjs` passes.
- A temporary home fixture proves acquire, contention, expiry, fencing, cross-home refusal,
  and reaping without a live fleet.
- With `enabled: false`, the plugin registers no tools and touches no files.
- The existing shell supervisor path is byte-for-byte unchanged.

Rollback: nothing to roll back; the bundle is not linked.

### Phase 1 — Lease adapter and guarded mutations (built)

Built as `dsh-plugin/lib/fm-lease2-lib.sh` (the bash adapter, shipped under the plugin):

- `fm_lease2_acquire/renew/release/inspect/reap/guard/check/live_token` wrap the one CLI and
  pin one holder identity per shell so an acquire inside `$(...)` matches its later guard.
- The plugin's command channel returns as `firstmate_native_run`, with read/write classification
  derived from a fixed allowlist and a task lease instead of lock ownership.
- Mutating runs take that task's lease inside the call (`withLease`, with heartbeat) and
  release it after, unless the caller already holds a token.
- Task-scoped tools: `firstmate_native_lease` (acquire/renew/release/inspect/reap) and the guarded
  `firstmate_native_run`.

Exit criteria: a session that holds no lock can still mutate a task it leases; a second
session gets a clean contention refusal; killing the holder mid-operation leaves the task
recoverable after TTL.

Rollback: remove `config/dsh-native-lease` from the home.

### Phase 2 — Mutating `bin` entrypoints honor the lease (built)

The mutating entrypoints call `fm_lease_guard` / `fm_lease_forbid_branch`, so the
integration seam is one library instead of one edit per entrypoint: `bin/fm-lease-lib.sh`
routes those two calls to `bin/fm-native-lib.sh` when `config/dsh-native-lease` exists. A
native mutation through a lease-enforced entrypoint (section 4.11) must present
`FM_LEASE_TOKEN` and `FM_LEASE_SESSION` (and the matching `FM_LEASE_TASK`) from the plugin
channel or the loop; otherwise it refuses with exit 6. A fresh spawn is exempt. The
native path never reads `state/.lock`, and the branch actor partition is a no-op because the
native design has none. A home without the marker keeps the two-actor path byte for byte.

The maintenance lease is the library's reserved `maintenance` record (section 4.8); no `bin/`
operation acquires it yet. `tests/fm-send-inbox.test.sh` and
`tests/fm-approval-failover.test.sh` (the legacy lease consumers) still pass unchanged.

Rollback: remove the marker; scripts fall back to the lock path.

### Phase 3 — Per-home reconciliation loop (built)

`dsh-plugin/src/reconcile.js` plus `bin/fm-reconcile.mjs --once|--loop` and the
`firstmate_native_reconcile` tool implement the tick of section 6.2: reap, observe through
`fm-fleet-snapshot.sh --json`, select from the home-authored rules, lease-then-act through
the real `bin/` scripts, and report. Event hints ride the plugin follow-up transport; they are
latency only. The watcher and daemon remain the fallback for non-native homes and for a native
home that opts out. End-to-end evidence: a fake engine mutation driven by a tick passes the
real native guard seam; two concurrent ticks act once; a crashed holder is recovered by
expiry with a higher token; cross-home ticks refuse.

Rollback: stop the loop; re-arm the watcher.

### Phase 4 — Remove ancestry identity from the native path (built)

A native session's identity comes only from the DSH session header, and
`firstmate_native_start` composes the startup input from durable records without running
`fm-session-start.sh` and without touching `state/.lock`. The native guard verifies tokens
through the CLI alone, so no native mutation needs `bin/fm-lock.sh`. Tests assert that a
native mutation and a native start leave `state/.lock` absent.

Residual decision: the ancestry code remains for non-native homes, so it is not deleted from
the tree here; deleting it requires every registered home to be native.

### Phase 5 — Retire the single-owner machinery (residual)

The native path is complete and lock-free, which is the strangler's terminal behavior for a
native home. This repository deliberately does not delete the single-owner machinery yet: the
engine, the prior bundle, and every un-migrated home still use it, and deleting it here would
break them while the native path has no field history. Retirement is therefore a deletion
phase gated on every registered home reporting native, not a code change this increment can
verify. The invariants that make it safe are already enforced and tested: no native code reads
or writes `state/.lock`, no native path uses the two-actor `main`/`branch` lease, and native
ownership is the per-task fencing lease plus the narrow maintenance lease.

## 8. Old-to-new map

| Old (single owner) | New (task-scoped) |
| --- | --- |
| `state/.lock` fleet session lock | Removed. Per-task leases; narrow maintenance lease. |
| `bin/fm-session-lock-lib.sh` ancestry proof | DSH session identity (`SessionHeader` + home resolution). |
| `bin/fm-lease-lib.sh` `main`/`branch` two actors | N owners, token, TTL, heartbeat, reaping (`src/lease.js`). |
| `state/.lease-<task>` one line `<actor>\t<pid>\t<epoch>` | `state/leases/<task>.lease` JSON record with token. |
| One supervision host / daemon per home | Any number of peer sessions; one optional headless loop. |
| Lock ownership gates mutating tools | Task lease token gates task mutations; read-only tools ungated. |
| Project registry alone decides pipeline vs direct | Project registry is the default; a durable per-PR/per-task record overrides it ([delivery-decisions.md](delivery-decisions.md)). |
| Watcher wake queue as the only supervision driver | Durable files; loop ticks; event hints are latency only. |
| `fm_watch_*` arm owner | Phase 3 loop; watcher remains fallback. |

## 9. Testing strategy

Unit and contract tests live in `dsh-plugin/test/` and run with `node --test` against a
temporary home created by `mkdtemp`:

- Lease: acquire, idempotent re-acquire, contention, expiry, fencing, release, reap,
  malformed record, mutex contention across processes.
- Cross-home: `identity.home !== target` refused with exit 6 and no file written.
- Identity: home anchors, resolution precedence, canonicalization, subagent skip, opt-in
  marker, no-home inertness.
- Tools: registration gated by `enabled`, refusal outside an opted-in home, fixed allowlist,
  bounded output, JSON shaping.
- Transport: message shape, dedupe, claim/discard clearing.
- Engine: completed-turn seed boundary, durable record marker and lineage gating, tool-surface
  gating for an engine versus an ordinary subagent, inbox batching, escalation delivery and
  dedupe, tick-driven retry, two-engine contention, crash recreation, parent-end close, and a
  quiet tick creating nothing.

Integration tests (phase 1+) mint a disposable home with `bin/fm-lab-home.sh` and never touch
the real fleet. The gate-refusal library keeps lab enforcement separate from the live fleet.

## 10. Open items for the decision log

These are implementation choices this page makes; none reopens a settled decision:

1. Lease record format is JSON (not TSV) so both Node and bash (`jq`) read one shape.
2. Mutex is a `mkdir` directory with a 5 s staleness bound, not a file lock.
3. `pid` is diagnostic only; TTL is the sole staleness contract.
4. Home anchors drop `bin/fm-watch-arm.sh` so retiring the watcher cannot invalidate
   identity.
5. The plugin ships inert (`enabled: false` plus a per-home marker) rather than replacing
   the old bundle by default.
6. The engine child's explicit marker is the plugin's durable engine record matched against the
   child's `origin`/`delegationDepth`/`parentSession`, because DSH exposes no plugin-writable
   custom session metadata. The record is written with status `creating` before the child
   exists, so its first tool call already resolves the engine surface.

If any of these should be decided differently, record it in the handoff page's decision log
before the phase that depends on it.
