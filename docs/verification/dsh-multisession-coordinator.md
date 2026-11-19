# Two-session coordinator verification

Date: 2026-11-19.
Version: `@deepseek-ai/dsh` 0.2.2-rc.2, `@local/dsh-plugin-firstmate-native` 0.2.0, Node v26.13.0.

This record owns the current empirical facts for the two-session supervision
engine. The contract it checks lives in
[`dsh-plugin/README.md`](../../dsh-plugin/README.md#supervision-engine); this
file records the commands and their observed output, not a second copy of the
contract.

## What the layers prove

- `dsh-plugin/test/e2e-multisession.test.mjs` is the fast token-free layer. It
  composes the plugin's `EngineHost` with the installed DSH runtime's real
  `Session` objects for both interactive parents and the real in-process fork
  provider for the child seed. It asserts one coordinator record and one
  `firstmate-coordinator` catalog child per parent, routine batches containing
  only the owner's task with no parent message, one escalation delivered to one
  parent only, one lease winner on a shared task, terminal close releasing only
  that parent's coordinator, a resumed parent forking fresh, and a quiet tick
  writing no batch or model wake.
- `dsh-plugin/test/escalation-residency.test.mjs` is the delivery regression.
  It creates a coordinator through `startActivation`, settles its first turn,
  wakes it through `agents.resume` as a same-id replacement, then calls
  `firstmate_native_escalate`. Its subagent seam enforces DSH's real `rootOf`
  refusal, so the pre-fix `subagents.sendMessage` delivery fails. It asserts
  the woken coordinator is refused by that seam, that delivery bypasses it, and
  that the parent receives exactly one tagged escalation with a user source and
  no settlement notice. Running it against the pre-fix `index.js` produced
  `delivered: false` and a failed assertion.
- `tests/fm-dsh-multisession-coordinator-live-e2e.test.sh` is the opt-in live
  layer. It boots a disposable DSH web Host from a profile copy under a private
  `DSH_HOME` and loopback port, and drives `session/create`, `session/prompt`,
  and `session/events` through the authenticated `/api` bridge the GUI uses.
  The disposable plugin copy registers a credential-free scripted provider that
  emits one `firstmate_native_escalate` tool call for a captain-class traffic
  batch, so the guard drives a real coordinator escalation turn and asserts real
  completed turns, real fork catalog children, no parent message from routine
  traffic, and exactly one tagged escalation in the owning parent with none in
  the second and no settlement notice.

## Coverage gap, stated precisely

The live layer seeds each parent's durable engine record before creating the
session, because the disposable Home has no model credential to make the
`firstmate_native_lease` call itself. It therefore does not assert the lazy
lease trigger inside the live Host; the fast layer asserts that trigger through
the real plugin tool surface. The live layer's scripted provider replaces only
the model's decision to escalate, not the tool call, the delivery, the durable
record, or the DSH session writes, all of which run unmodified. No product code
was changed to make either layer possible.

## Commands and observed output

Fast suite, from the repository root:

```sh
( cd dsh-plugin && node --test test/*.test.mjs )
```

```text
ℹ tests 135
ℹ suites 0
ℹ pass 135
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 3434.835292
```

Residency regression alone:

```sh
( cd dsh-plugin && node --test test/escalation-residency.test.mjs )
```

```text
ℹ tests 1
ℹ suites 0
ℹ pass 1
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 67.517043
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
ok - a real coordinator escalation turn delivered one tagged message to its own parent only
ok - http://127.0.0.1:44927 /home/ghazni/.treehouse/firstmate-dsh-fcfcb2/1/firstmate-dsh/dsh-plugin
```

The Host URL and disposable plugin path are printed as the last `ok` line. The
guard refuses a pass with no Host, no completed turns, no fork catalog children,
or no tagged escalation in the owning parent.

## Interactive inspection

The guard above is the executed proof. For manual inspection only, start a Host
from a scratch profile copy; never point `DSH_HOME` at the live one:

```sh
SCRATCH=$(mktemp -d /tmp/fm-two-session.XXXXXX)
cp -a "$HOME/.dsh/profiles/web" "$SCRATCH/profile-web"
mkdir -p "$SCRATCH/home/profiles"
mv "$SCRATCH/profile-web" "$SCRATCH/home/profiles/web"
ln -sfn "$PWD/dsh-plugin" \
  "$SCRATCH/home/profiles/web/node_modules/@local/dsh-plugin-firstmate-native"
DSH_HOME="$SCRATCH/home" dsh --profile web --host 127.0.0.1 --port 0 --no-open
```

Stop only the Host started above and remove `$SCRATCH` when done. The scripted
provider and the assertions that make this check reproducible live in the
live guard, which is the command to run for a fresh result.

## Harness-dependent check policy

This is a harness-dependent proof (it reads DSH's real fork provider and Host
API), so a fake alone cannot carry it. The portable tests pin the logic; the
live guard exercises the installed Host. Per the coding guidelines, refresh
this record after a DSH or plugin upgrade by running both commands and copying
their current output.
