# Two-session coordinator verification

Date: 2026-11-19.
Version: `@deepseek-ai/dsh` 0.2.2-rc.2, `@local/dsh-plugin-firstmate-native` 0.2.0, Node v26.13.0.

This record owns the current empirical facts for the two-session supervision
engine. The contract it checks lives in
[`dsh-plugin/README.md`](../../dsh-plugin/README.md#supervision-engine); this
file records the commands and their observed output, not a second copy of the
contract.

## What the two layers prove

- `dsh-plugin/test/e2e-multisession.test.mjs` is the fast, token-free layer. It
  composes the plugin's `EngineHost` with the installed DSH runtime's real
  `Session` objects for both interactive parents and the real in-process fork
  provider for the child seed. It asserts, in order: one coordinator record and
  one `firstmate-coordinator` catalog child per parent with a seed ending at the
  parent's last completed turn; routine batches containing only the owner's
  task with no parent event or message change; one escalation delivered to one
  parent only; one lease winner and one contention refusal on a shared task;
  terminal close releasing only that parent's coordinator and leases; a resumed
  parent forking fresh; and a quiet tick writing no batch or model wake.
- `tests/fm-dsh-multisession-coordinator-live-e2e.test.sh` is the opt-in live
  layer. It boots a disposable DSH web Host from a profile copy under a private
  `DSH_HOME` and loopback port, and drives `session/create`, `session/prompt`,
  and `session/events` through the authenticated `/api` bridge the GUI uses.
  It asserts real completed turns, real fork catalog children, matching seed
  boundaries, and no parent message from routine traffic.

## Coverage gap, stated precisely

The live layer seeds each parent's durable engine record before creating the
session, because the plugin starts supervision from the lease tool call and the
disposable Home has no model credential to make that tool call. It therefore
does not assert the lazy `firstmate_native_lease` trigger inside the live Host;
the fast layer asserts that trigger through the real plugin tool surface. The
live layer also does not drive the coordinator's decision turn: a coordinator
model turn without credentials settles as an error, so escalation and
contention decisions are asserted in the fast layer with controllable seams.
No product code was changed to make either layer possible.

## Commands and observed output

Fast suite, from the repository root:

```sh
( cd dsh-plugin && node --test test/*.test.mjs )
```

```text
ℹ tests 134
ℹ pass 134
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ duration_ms 3552.437998
```

New composition test alone:

```sh
( cd dsh-plugin && node --test test/e2e-multisession.test.mjs )
```

```text
✔ two real sessions keep one coordinator each, isolated traffic, and one lease winner
ℹ tests 1
ℹ pass 1
ℹ fail 0
```

Live layer, opt-in:

```sh
FM_DSH_MULTISESSION_LIVE=1 tests/fm-dsh-multisession-coordinator-live-e2e.test.sh
```

```text
ok - disposable DSH Host listens on a private loopback port
ok - two real sessions completed their prompt turns with a real turn/end boundary
ok - two real fork coordinators appear in their own parent catalogs
ok - routine traffic produced no parent message
```

The Host URL and disposable plugin path are printed as the last `ok` line. The
guard refuses a pass with no Host, no completed turns, or no fork catalog
children.

## Short manual smoke

Use a scratch copy of the web profile; never point `DSH_HOME` at the live one.

```sh
SCRATCH=$(mktemp -d /tmp/fm-two-session.XXXXXX)
cp -a "$HOME/.dsh/profiles/web" "$SCRATCH/profile-web"
mkdir -p "$SCRATCH/home/profiles"
mv "$SCRATCH/profile-web" "$SCRATCH/home/profiles/web"
ln -sfn "$PWD/dsh-plugin" \
  "$SCRATCH/home/profiles/web/node_modules/@local/dsh-plugin-firstmate-native"
DSH_HOME="$SCRATCH/home" dsh --profile web --host 127.0.0.1 --port 0 --no-open
```

Expected: the process prints `dsh web: http://127.0.0.1:<port>/?token=...`.
Open that URL in the browser.

In each of two sidebar sessions, prompt enough to complete one turn, then open
the session's subagents menu. Select `firstmate-coordinator`. Expected: it opens
as a conversation in that session's own subagent tree, with its seeded history
ending at the session's last completed turn. Repeat in the second session;
each list contains only its own coordinator.

Append ordinary progress to a task owned by the first session, using that
home's `fm-fleet-snapshot.sh` fixture, and wait for one engine tick. Expected:
the coordinator's conversation shows a new traffic batch, and the parent
session shows no new message and no settlement notice. Append a captain-class
blocker for the first session only. Expected: one tagged escalation message
appears in that parent and none in the second.

Clean up by stopping only the Host started above and removing `$SCRATCH`.

## Harness-dependent check policy

This is a harness-dependent proof (it reads DSH's real fork provider and Host
API), so a fake alone cannot carry it. The portable test pins the logic; the
live guard exercises the installed Host. Per the coding guidelines, refresh
this record after a DSH or plugin upgrade by running both commands and copying
their current output.
