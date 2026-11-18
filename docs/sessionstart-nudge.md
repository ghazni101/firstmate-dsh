# Native session-start delivery

This doc is for operators who need to know how the firstmate session-start digest reaches model context when a dsh session opens.
AGENTS.md section 3 is the authoritative behavioral contract for session start.
This file owns the dsh-native delivery path, the nudge fallback, and the compatibility limits of each.

One term recurs throughout:

- The digest is the ordered startup report that `bin/fm-session-start.sh` prints.

## Find a topic

| Question | Section |
| --- | --- |
| What dsh runs when a session opens | [Session-open tiers](#session-open-tiers) |
| What each session-open source triggers | [Source routing](#source-routing) |
| How long the digest may block and what happens when it runs out of time | [Runtime bound](#runtime-bound) |
| When the wrappers stay silent and which exit codes they use | [Shared wrapper and safety](#shared-wrapper-and-safety) |
| How the dsh primary wires its session-open path | [Harness transports](#harness-transports) |
| Which tests prove each guarantee | [Regression coverage](#regression-coverage) |

## Session-open tiers

dsh is the only firstmate primary runtime.
There are no other session-open adapters and no other primary-harness tiers.

| Tier | What the adapter does | Used by |
| --- | --- | --- |
| Native | The dsh plugin exposes a read-only native session-start tool for this session's home: identity, inbox readiness, fleet/backlog summary, held task leases, and queued durable wakes. It does not run `bin/fm-session-start.sh` or mutate state. | dsh |
| Nudge | Asks the agent to run the digest through the tracked session-start instruction, for setup paths that cannot carry a native tool result into model context. | dsh homes without the plugin enabled |

Both tiers end in the same `bin/fm-session-start.sh`; the nudge is not a second contract.
The digest must be present in model context before the first turn, so an operator confirms it and runs the command themselves when the surface shows only a nudge.

### Tier by harness

| Harness surface | Tier | Details |
| --- | --- | --- |
| dsh with `config/dsh-native` | Native | [dsh](#dsh) |
| dsh without the plugin enabled | Nudge | [Nudge fallback](#nudge-fallback) |

### Why the native tier exists

A nudge can only ask.
An agent can defer an instruction, including when a first-command skill has its own read-only path.
The dsh plugin's native tool gives the model the same identity and fleet facts without a separate process, so the first command has the home state it needs.

The nudge tier remains the floor for a home that has not enabled the plugin.
It never changes the digest itself.

## Source routing

`bin/fm-sessionstart-run.sh` is the single owner of what a session-open source means.
Because of that, no harness matcher string has to encode that policy.
The run wrapper learns the source in one of two ways:

- It takes `--source <name>` when the adapter knows the source natively.
- Otherwise it reads the `source` field from a hook-shaped JSON payload on stdin.

A re-emit (`--reemit`) reprints the digest for a process that already has the helm and lost only its context.

| Source | Action | Why |
| --- | --- | --- |
| `dsh` | Run the digest through the native source | The plugin provides the session identity and the digest command is tracked |
| unset or unknown | Nudge | The caller has not proved a native source |

### Change from the previous nudge matcher

The source field, not a harness-specific matcher string, decides the route.
A new primary surface would enter here with its own source name and its own transport section; no other primary surface is supported today.

### Completion interlock

The digest records its completion before the first turn so a later re-emit or restart can tell whether the ordered report already ran.
A nudge that was never acted on does not count as completion.

### Nudge wrapper on a native source

When a native source is present, the nudge wrapper stays silent.
Printing a second instruction after the digest would only reintroduce the discretion the native path removes.

### Re-emit mechanics

A re-emit prints the digest again without rerunning bootstrap or the wake drain.
It is for context loss after compaction, not for a session that never ran the digest.

## Runtime bound

The digest runs on the blocking session-open path, so it is bounded and never waits on the network.

### Network work stays off the blocking path

`bin/fm-startup-network.sh` runs its checks off the blocking path and publishes a report the digest reads.
A check still in progress is never reported as passed.

### Digest timeout

The digest is bounded by a hard timeout.
A timeout leaves a durable record rather than a partial context that looks complete.

### When the child stops early

If the child command stops before the digest is complete, the wrapper reports the short read instead of presenting a truncated report as the digest.

## Shared wrapper and safety

The wrappers are silent on ordinary success and print only the instruction needed to reach the digest.
They use an ancestry check so a child process cannot claim the primary session's identity.

### Nudge payload

The nudge payload is a short instruction to run the digest command.
It names no harness-specific surface.

### Nudge wrapper startup check

Before printing a nudge, the wrapper checks that it is running in a primary session and that the digest command exists.
A helper-chain process never receives a primary nudge.

### Exit codes

The wrapper exits zero when it delivered a nudge or found the digest already complete.
It exits non-zero only on an unusable source or a missing digest command.

## Harness transports

### dsh

The dsh plugin owns the native session-start tool.
It reads the home's identity, inbox readiness, fleet and backlog summary, held leases, and queued wakes without running `bin/fm-session-start.sh` and without taking a fleet lock.
The agent runs the tracked digest command as the session's first action.

### Nudge fallback

A dsh home without the plugin enabled uses the tracked nudge wrapper.
The wrapper prints the digest instruction once, and the agent runs `bin/fm-session-start.sh` itself.

## Regression coverage

### Wrapper and shared-safety suite

`tests/fm-sessionstart-nudge.test.sh` exercises the nudge decision through the wrapper's public interface, and `tests/fm-sessionstart-run.test.sh` covers source routing and re-emit behavior.

### Runtime bound test

`tests/fm-session-start.test.sh` covers the digest bound and the short-read path.

### Native dsh tests

`dsh-plugin/test/` covers the native session-start tool's read-only contract, home resolution, and lease reads against a real dsh-shaped home.

### Guard, monitoring, and away-mode tests

`tests/fm-guard.test.sh`, `tests/fm-wake-queue.test.sh`, and `tests/fm-afk-return.test.sh` cover the supervision surrounding session start.

### Transport evidence

`docs/verification/supervision.md` records the dated results for the session-start paths that remain in active use.
