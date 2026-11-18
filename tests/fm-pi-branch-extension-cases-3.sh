# shellcheck shell=bash
# Test cases for fm-pi-branch-extension, split out of tests/fm-pi-branch-extension.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-pi-branch-extension.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


test_secondary_session_stays_inert() {
  local repo home out status foreign_pid
  repo="$TMP_ROOT/secondary-root"
  home="$TMP_ROOT/secondary-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  # The fleet lock is owned by ANOTHER live process that is NOT in the
  # driver's ancestry (a sibling sleeper), so the driver is a secondary
  # session: it must accept nothing and write no marker.
  sleep 60 &
  foreign_pid=$!
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_SKIP_LOCK=1 FM_TEST_LOCK_PID=$foreign_pid DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, home }; })()`);
const { dispatch, home } = globalThis.__t;
import { existsSync, writeFileSync } from "node:fs";
writeFileSync(`${home}/state/.lock`, `${process.env.FM_TEST_LOCK_PID}\n`);
if (dispatch("signal: secondary probe").accepted) throw new Error("secondary session accepted a wake it does not own");
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("secondary session wrote the primary's marker");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  kill "$foreign_pid" 2>/dev/null || true
  expect_code 0 "$status" "a secondary session must stay inert: $out"
  pass "a Pi session that does not own the lock accepts nothing and mutates no branch state"
}

test_rebind_remirrors_undelivered_dialog_from_durable_cursor() {
  local repo home out status
  repo="$TMP_ROOT/rebind-root"
  home="$TMP_ROOT/rebind-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, home }; })()`);
const { fire, home } = globalThis.__t;
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// Instance A collects dialog at turn_end while no branch exists yet (nothing
// delivered, durable cursor unmoved), then the extension instance is replaced
// (/new, /resume, reload). The replacement must reconstruct exclusively from
// the durable cursor and re-mirror the undelivered dialog - never drop it.
const entries = [
  { type: "message", message: { role: "user", content: "standing order: never merge task-7" } },
];
const ctx = {
  sessionManager: { getSessionFile: () => `${home}/main-1.jsonl`, getEntries: () => entries },
};
await fire("turn_end", {}, ctx);
await fire("session_shutdown", {});

// Replacement instance: fresh import simulates Pi rebinding the extension.
const replacementHandlers = new Map();
const replacementBus = {
  on(channel, handler) {
    replacementHandlers.set(channel, [...(replacementHandlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of replacementHandlers.get(channel) ?? []) handler(data);
  },
};
const replacementPiHandlers = new Map();
const replacementPi = {
  events: replacementBus,
  on(event, handler) {
    replacementPiHandlers.set(event, [...(replacementPiHandlers.get(event) ?? []), handler]);
  },
  registerTool() {},
  registerCommand() {},
  registerMessageRenderer() {},
  sendMessage() {},
  sendUserMessage() {},
};
const replacement = await import(`${pathToFileURL(process.env.PLUGIN).href}?rebind=1`);
replacement.default(replacementPi);
for (const handler of replacementPiHandlers.get("session_start") ?? []) handler({}, ctx);
for (const handler of replacementPiHandlers.get("turn_end") ?? []) handler({}, ctx);
writeFileSync(`${home}/state/.wake-queue`, "1\t1\tsignal\tbranch-driver.status\tsignal: after rebind\n");
const offer = {
  message: "signal: after rebind",
  projects: [`${home}/projects/approved`],
  heartbeat: false,
  eligible: true,
  accepted: false,
  settlement: Promise.resolve(),
  accept(settlement = Promise.resolve()) {
    offer.accepted = true;
    offer.settlement = settlement;
  },
};
replacementBus.emit("fm-branch-supervision:dispatch", offer);
if (!offer.accepted) throw new Error("replacement instance refused the wake");
for (let i = 0; i < 250; i += 1) {
  const mirrors = (globalThis.__fmMirrors ?? []).map((m) => m.content);
  if (mirrors.includes("[captain] standing order: never merge task-7")) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const mirrors = (globalThis.__fmMirrors ?? []).map((m) => m.content);
if (!mirrors.includes("[captain] standing order: never merge task-7")) {
  throw new Error(`replacement dropped undelivered dialog: ${JSON.stringify(mirrors)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "rebind must re-mirror undelivered dialog from the durable cursor: $out"
  pass "an extension rebind re-mirrors undelivered dialog instead of dropping it"
}

# Direct unit coverage of fm-branch-dispatch.ts's classification, independent
# of the Pi SDK stub: every legitimately main-only class (docs/pi-supervision-
# branch.md) stays excluded from eligibleSeqs no matter its check-kind key,
# a mixed queue keeps its task-local rows eligible without those main-only
# rows vetoing the scan, and the eligible-row snapshot writer names exactly
# the eligible set.
test_branch_dispatch_classifies_main_only_rows_and_writes_the_eligible_snapshot() {
  local repo home out status
  repo="$TMP_ROOT/dispatch-classify-root"
  home="$TMP_ROOT/dispatch-classify-home"
  mkdir -p "$repo/.pi/extensions/lib" "$home/state" "$home/projects/approved"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  printf 'project=%s/projects/approved\nwindow=fm-window\n' "$home" > "$home/state/task-a.meta"
  LIB="$repo/.pi/extensions/lib/fm-branch-dispatch.ts" FM_HOME="$home" GRANT="$ROOT/bin/fm-wake-grant.sh" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { syncBuiltinESMExports } from "node:module";
import fs, { readFileSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";

const originalReadFileSync = fs.readFileSync;
let countedStatusPath = "";
let countedStatusReads = 0;
fs.readFileSync = function(path, ...args) {
  if (String(path) === countedStatusPath) countedStatusReads += 1;
  return originalReadFileSync.call(this, path, ...args);
};
syncBuiltinESMExports();

const { activateEligibleRowsOwner, scopeForUnreadWake, writeEligibleRowsSnapshot, releaseEligibleRowsSnapshot, BRANCH_ELIGIBLE_ROWS_FILE } =
  await import(pathToFileURL(process.env.LIB).href);
const state = `${process.env.FM_HOME}/state`;
const project = `${process.env.FM_HOME}/projects/approved`;

// Every legitimately main-only class is a check-kind row under a different
// key; classification never looks at the key, only the kind, so one
// representative per named class is sufficient coverage.
const mainOnlyRows = [
  "1\t1\tcheck\tx-inbox\tcheck: pending x mention",
  "1\t1\tcheck\tsome-poll.check.sh\tcheck: some-poll.check.sh: merged",
  "1\t1\tcheck\tunauthenticated-state-checks\tcheck: rejected unauthenticated state checks",
];
for (const row of mainOnlyRows) {
  writeFileSync(`${state}/.wake-queue`, row);
  const scope = scopeForUnreadWake(state, false);
  if (scope.eligible || scope.eligibleSeqs.length !== 0) {
    throw new Error(`a main-only class was offered to the branch: ${row} -> ${JSON.stringify(scope)}`);
  }
  if (scope.corrupted) throw new Error(`an ordinary main-only row must not read as corrupted: ${row}`);
}

// A needs-decision signal row is a main-only class too, marked by payload
// rather than kind (docs/pi-supervision-branch.md "Autonomy"): it is excluded
// from eligibleSeqs and named in needsDecisionKeys. A later stale row under the
// task's window alias remains individually claimable, while task-identity
// precedence keeps its complete wake on main until the decision row is read.
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status",
    "1\t2\tstale\tfm-window\tstale: later routine reminder",
  ].join("\n"),
);
const needsDecisionMixed = scopeForUnreadWake(state, false);
if (!needsDecisionMixed.eligible) {
  throw new Error(`an unread needs-decision row must not erase a later stale row: ${JSON.stringify(needsDecisionMixed)}`);
}
if (needsDecisionMixed.eligibleSeqs.join(",") !== "2") {
  throw new Error(`a needs-decision row must be excluded from eligibleSeqs: ${JSON.stringify(needsDecisionMixed)}`);
}
if (needsDecisionMixed.needsDecisionKeys.join(",") !== "task-a.status") {
  throw new Error(`needsDecisionKeys must name the excluded row: ${JSON.stringify(needsDecisionMixed)}`);
}
if (needsDecisionMixed.taskByWakeKey["task-a.status"] !== "task-a" ||
  needsDecisionMixed.taskByWakeKey["fm-window"] !== "task-a") {
  throw new Error(`status and stale aliases did not resolve to one task: ${JSON.stringify(needsDecisionMixed)}`);
}
if (needsDecisionMixed.corrupted) {
  throw new Error(`a needs-decision row must not read as corrupted: ${JSON.stringify(needsDecisionMixed)}`);
}

// A queue holding only a needs-decision row is ordinary main-only absence,
// exactly like a queue holding only a check row.
writeFileSync(`${state}/.wake-queue`, "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status");
const needsDecisionOnly = scopeForUnreadWake(state, false);
if (needsDecisionOnly.eligible || needsDecisionOnly.eligibleSeqs.length !== 0 || needsDecisionOnly.corrupted) {
  throw new Error(`a needs-decision-only queue must be ordinary main-only absence: ${JSON.stringify(needsDecisionOnly)}`);
}

// A captain-held task's bounded stale recheck is itself a decision wake. It is
// excluded while an unrelated routine row remains independently branch-owned.
writeFileSync(`${state}/task-a.status`, "captain-held [key=route]: awaiting the captain\n \t \n");
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tstale\tfm-window\tstale: fm-window (awaiting the captain)",
    "1\t2\tsignal\ttask-a.status\tsignal: routine follow-up",
  ].join("\n"),
);
const captainHeldMixed = scopeForUnreadWake(state, false);
if (!captainHeldMixed.eligible || captainHeldMixed.eligibleSeqs.join(",") !== "2") {
  throw new Error(`a captain-held stale row was offered to the branch: ${JSON.stringify(captainHeldMixed)}`);
}
if (captainHeldMixed.needsDecisionKeys.join(",") !== "fm-window") {
  throw new Error(`the captain-held stale key was not marked main-owned: ${JSON.stringify(captainHeldMixed)}`);
}

writeFileSync(`${state}/task-a.status`, "captain-held [key=route]: awaiting a second captain reminder\n \n");
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tstale\tfm-window\tstale: fm-window (first reminder)",
    "1\t2\tstale\tfm-window\tstale: fm-window (second reminder)",
    "1\t3\tsignal\ttask-a.status\tsignal: routine follow-up",
  ].join("\n"),
);
countedStatusPath = `${state}/task-a.status`;
countedStatusReads = 0;
const repeatedCaptainHeld = scopeForUnreadWake(state, false);
if (countedStatusReads !== 1) {
  throw new Error(`one status was read ${countedStatusReads} times for repeated stale rows`);
}
if (!repeatedCaptainHeld.eligible || repeatedCaptainHeld.eligibleSeqs.join(",") !== "3" ||
  repeatedCaptainHeld.needsDecisionKeys.join(",") !== "fm-window,fm-window") {
  throw new Error(`repeated stale reminders changed classification: ${JSON.stringify(repeatedCaptainHeld)}`);
}
const repeatedCaptainHeldNextScan = scopeForUnreadWake(state, false);
if (countedStatusReads !== 1 || repeatedCaptainHeldNextScan.needsDecisionKeys.join(",") !== "fm-window,fm-window") {
  throw new Error(`an unchanged status was not reused across scans: reads=${countedStatusReads} scope=${JSON.stringify(repeatedCaptainHeldNextScan)}`);
}
writeFileSync(`${state}/task-a.status`, "captain-held [key=route]: awaiting the captain\nworking: resumed after answer\n");
const changedCaptainHeld = scopeForUnreadWake(state, false);
if (countedStatusReads !== 2 || changedCaptainHeld.eligibleSeqs.join(",") !== "1,2,3" ||
  changedCaptainHeld.needsDecisionKeys.length !== 0) {
  throw new Error(`a changed status did not invalidate its cached decision: reads=${countedStatusReads} scope=${JSON.stringify(changedCaptainHeld)}`);
}
countedStatusPath = "";
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tstale\tfm-window\tstale: fm-window (awaiting the captain)",
    "1\t2\tsignal\ttask-a.status\tsignal: routine follow-up",
  ].join("\n"),
);

// A later unrelated status does not mask a still-open durable decision. The
// stale row remains main-owned while the routine signal stays branch-owned.
writeFileSync(
  `${state}/task-a.status`,
  "needs-decision [key=cleanup]: choose destructive cleanup\nworking: routine follow-up\n",
);
const openDecisionMixed = scopeForUnreadWake(state, false);
if (!openDecisionMixed.eligible || openDecisionMixed.eligibleSeqs.join(",") !== "2") {
  throw new Error(`an open-decision stale row was offered to the branch: ${JSON.stringify(openDecisionMixed)}`);
}
if (openDecisionMixed.needsDecisionKeys.join(",") !== "fm-window") {
  throw new Error(`the open-decision stale key was not marked main-owned: ${JSON.stringify(openDecisionMixed)}`);
}

process.env.FM_CLASSIFY_RESOLVE_VERB = "answered";
writeFileSync(
  `${state}/task-a.status`,
  "needs-decision [key=cleanup]: choose destructive cleanup\nanswered [key=cleanup]: remove generated files\n",
);
const customResolved = scopeForUnreadWake(state, false);
if (!customResolved.eligible || customResolved.eligibleSeqs.slice().sort().join(",") !== "1,2" ||
  customResolved.needsDecisionKeys.length !== 0) {
  throw new Error(`a custom resolution verb left the stale decision open: ${JSON.stringify(customResolved)}`);
}

process.env.FM_CLASSIFY_CAPTAIN_HELD_VERB = "awaiting-captain";
writeFileSync(`${state}/task-a.status`, "awaiting-captain [key=cleanup]: awaiting the captain\n");
const customHeld = scopeForUnreadWake(state, false);
if (!customHeld.eligible || customHeld.eligibleSeqs.join(",") !== "2" ||
  customHeld.needsDecisionKeys.join(",") !== "fm-window") {
  throw new Error(`a custom captain-held verb was offered to the branch: ${JSON.stringify(customHeld)}`);
}
delete process.env.FM_CLASSIFY_RESOLVE_VERB;
delete process.env.FM_CLASSIFY_CAPTAIN_HELD_VERB;

process.env.FM_CLASSIFY_RESERVED_KEY_PREFIXES = "secret-";
writeFileSync(
  `${state}/task-a.status`,
  "needs-decision [key=pending-reply-x]: choose destructive cleanup\nworking: routine follow-up\n",
);
const customReservedPrefixes = scopeForUnreadWake(state, false);
if (!customReservedPrefixes.eligible || customReservedPrefixes.eligibleSeqs.join(",") !== "2" ||
  customReservedPrefixes.needsDecisionKeys.join(",") !== "fm-window") {
  throw new Error(`configured reserved prefixes lost an open stale decision: ${JSON.stringify(customReservedPrefixes)}`);
}
delete process.env.FM_CLASSIFY_RESERVED_KEY_PREFIXES;

writeFileSync(`${state}/symlink-target.status`, "needs-decision: external choice\n");
unlinkSync(`${state}/task-a.status`);
symlinkSync(`${state}/symlink-target.status`, `${state}/task-a.status`);
const symlinkedStatus = scopeForUnreadWake(state, false);
if (!symlinkedStatus.corrupted || symlinkedStatus.eligible || symlinkedStatus.needsDecisionKeys.length !== 0) {
  throw new Error(`a symlinked status file influenced stale routing: ${JSON.stringify(symlinkedStatus)}`);
}
unlinkSync(`${state}/task-a.status`);
writeFileSync(`${state}/task-a.status`, "working: routine work\n");

writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tcheck\tx-inbox",
    "1\t2\tsignal\ttask-a.status\tsignal: task-a.status",
  ].join("\n"),
);
const truncated = scopeForUnreadWake(state, false);
if (!truncated.corrupted || truncated.eligible || truncated.eligibleSeqs.length !== 0) {
  throw new Error(`a four-field queue row was not classified as corruption: ${JSON.stringify(truncated)}`);
}

// A mixed queue: the main-only row (seq 1) never vetoes the task-local rows
// (seq 2, 3) - the reproduction from the task.
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tcheck\tx-inbox\tcheck: pending x mention",
    "1\t2\tsignal\ttask-a.status\tsignal: task-a.status",
    "1\t3\tstale\tfm-window\tstale: fm-window",
  ].join("\n"),
);
const mixed = scopeForUnreadWake(state, false);
if (!mixed.eligible) throw new Error(`mixed queue with eligible task-local rows must stay eligible: ${JSON.stringify(mixed)}`);
if (mixed.eligibleSeqs.slice().sort().join(",") !== "2,3") {
  throw new Error(`eligibleSeqs must name exactly the task-local rows: ${JSON.stringify(mixed)}`);
}
if (!mixed.projects.includes(project)) {
  throw new Error(`eligible project context lost: ${JSON.stringify(mixed.projects)}`);
}

if (!(await activateEligibleRowsOwner(state, process.env.GRANT, process.pid, "fixture"))) {
  throw new Error("branch owner activation failed");
}
if ((await writeEligibleRowsSnapshot(state, mixed.eligibleSeqs, process.env.GRANT, "fixture")) !== "published") {
  throw new Error("snapshot write reported failure");
}
const snapshot = readFileSync(`${state}/${BRANCH_ELIGIBLE_ROWS_FILE}`, "utf8").trim().split("\n");
if (snapshot.join(",") !== "2,3") throw new Error(`snapshot did not name exactly the eligible rows: ${snapshot}`);

// An empty eligible set is refused rather than clearing the snapshot to
// nothing - a caller must never overwrite a live snapshot with an empty one.
if ((await writeEligibleRowsSnapshot(state, [], process.env.GRANT, "fixture")) !== "error") {
  throw new Error("an empty eligible set must not be written");
}
if (!(await releaseEligibleRowsSnapshot(state, process.env.GRANT, "fixture"))) throw new Error("snapshot release failed");
writeFileSync(`${state}/.main-eligible-rows`, "2\n");
if ((await writeEligibleRowsSnapshot(state, ["2"], process.env.GRANT, "fixture")) !== "main-owned") {
  throw new Error("a row already claimed by main was not reported as main-owned");
}

// A heartbeat is not vetoed or ridden into main by a co-present check row.
// The check row is permanently main-owned in every mode, so it is excluded
// from the claim rather than deferring a fleet review that has nothing to do
// with it - the captain's reproduction.
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\tcheck\tx-inbox\tcheck: pending x mention",
    "1\t2\theartbeat\theartbeat\theartbeat",
    "1\t3\tsignal\ttask-a.status\tsignal: task-a.status",
  ].join("\n"),
);
const heartbeatMixed = scopeForUnreadWake(state, true);
if (!heartbeatMixed.eligible || heartbeatMixed.corrupted) {
  throw new Error(`a co-present check row rode a heartbeat into main: ${JSON.stringify(heartbeatMixed)}`);
}
if (heartbeatMixed.eligibleSeqs.slice().sort().join(",") !== "2,3") {
  throw new Error(`a heartbeat claim must cover every branch-ownable row and no check row: ${JSON.stringify(heartbeatMixed)}`);
}

// All-or-nothing is unchanged in what it actually guarantees: a heartbeat
// review takes every branch-ownable row or none of them, so a row this scan
// cannot resolve still defers the whole review to main.
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\theartbeat\theartbeat\theartbeat",
    "1\t2\tsignal\tno-such-task.status\tsignal: no-such-task.status",
  ].join("\n"),
);
const heartbeatUnresolvable = scopeForUnreadWake(state, true);
if (heartbeatUnresolvable.eligible || !heartbeatUnresolvable.corrupted) {
  throw new Error(`an unresolvable row must still defer a heartbeat review: ${JSON.stringify(heartbeatUnresolvable)}`);
}
writeFileSync(
  `${state}/.wake-queue`,
  [
    "1\t1\theartbeat\theartbeat\theartbeat",
    "1\t2\tinvented\tsomething\tinvented: not a kind fm_wake_append emits",
  ].join("\n"),
);
const heartbeatUnknownKind = scopeForUnreadWake(state, true);
if (heartbeatUnknownKind.eligible || !heartbeatUnknownKind.corrupted) {
  throw new Error(`an unknown row kind must still defer a heartbeat review: ${JSON.stringify(heartbeatUnknownKind)}`);
}

// A queue holding nothing but main-only rows leaves a heartbeat with nothing
// to hand over, so it is not offered rather than granted an empty claim.
writeFileSync(`${state}/.wake-queue`, "1\t1\tcheck\tx-inbox\tcheck: pending x mention");
const heartbeatNothingOwnable = scopeForUnreadWake(state, true);
if (heartbeatNothingOwnable.eligible || heartbeatNothingOwnable.eligibleSeqs.length !== 0) {
  throw new Error(`a heartbeat was offered with no branch-ownable row: ${JSON.stringify(heartbeatNothingOwnable)}`);
}
if (heartbeatNothingOwnable.corrupted) {
  throw new Error(`a purely main-only queue is ordinary absence, not a fault: ${JSON.stringify(heartbeatNothingOwnable)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "main-only classification and eligible-row snapshot contract must hold: $out"
  pass "scopeForUnreadWake excludes every main-only class without vetoing eligible task-local rows, and writes the eligible snapshot"
}

# An Orca task's stale rows are keyed by its terminal handle, not a window
# (bin/fm-watch.sh keys Orca endpoints by terminal=). The dispatcher must
# resolve that terminal key to its task, so a terminal-keyed stale row queued
# alongside another eligible row stays branch-owned instead of sending the
# whole wake to main.
test_branch_dispatch_resolves_terminal_keyed_orca_stale_row() {
  local repo home out status
  repo="$TMP_ROOT/dispatch-terminal-root"
  home="$TMP_ROOT/dispatch-terminal-home"
  mkdir -p "$repo/.pi/extensions/lib" "$home/state" "$home/projects/approved"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  printf 'project=%s/projects/approved\nterminal=orca-term-1\n' "$home" > "$home/state/orca-task.meta"
  LIB="$repo/.pi/extensions/lib/fm-branch-dispatch.ts" FM_HOME="$home" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

const { scopeForUnreadWake } = await import(pathToFileURL(process.env.LIB).href);
const state = `${process.env.FM_HOME}/state`;
const project = `${process.env.FM_HOME}/projects/approved`;

for (const heartbeat of [false, true]) {
  const queue = heartbeat
    ? ["1\t1\theartbeat\theartbeat\theartbeat", "1\t2\tstale\torca-term-1\tstale: orca-term-1"]
    : ["1\t1\tsignal\torca-task.status\tsignal: orca-task.status", "1\t2\tstale\torca-term-1\tstale: orca-term-1"];
  writeFileSync(`${state}/.wake-queue`, queue.join("\n"));
  const scope = scopeForUnreadWake(state, heartbeat);
  if (!scope.eligible || scope.corrupted || scope.eligibleSeqs.slice().sort().join(",") !== "1,2") {
    throw new Error(`a terminal-keyed stale row was not branch-owned (heartbeat=${heartbeat}): ${JSON.stringify(scope)}`);
  }
  if (scope.taskByWakeKey["orca-term-1"] !== "orca-task") {
    throw new Error(`the terminal key did not resolve to its task: ${JSON.stringify(scope)}`);
  }
  if (!scope.projects.includes(project)) {
    throw new Error(`the terminal-keyed task lost its project context: ${JSON.stringify(scope.projects)}`);
  }
}
// A terminal must never silently change owners, including collisions with
// another task's window or canonical task key. Exercise both record orders.
for (const owner of ["a-owner", "z-owner"]) {
  for (const field of ["terminal", "window", "task"]) {
    for (const ownerProject of [`project=${project}\n`, "", "project=\n"]) {
      const terminal = field === "task" ? owner : "orca-term-1";
      writeFileSync(`${state}/orca-task.meta`, `project=${project}\nterminal=${terminal}\n`);
      writeFileSync(`${state}/${owner}.meta`, `${ownerProject}${field === "task" ? "" : `${field}=${terminal}\n`}`);
      writeFileSync(`${state}/${owner}.status`, "needs-decision: choose owner\n");
      writeFileSync(`${state}/.wake-queue`, `1\t1\tsignal\torca-task.status\tsignal: orca-task.status\n1\t2\tstale\t${terminal}\tstale: ${terminal}`);
      const scope = scopeForUnreadWake(state, false);
      if (scope.eligible || !scope.corrupted || scope.eligibleSeqs.length !== 0) {
        throw new Error(`conflicting ${field} ownership must leave the whole wake to MAIN (${owner}, project=${JSON.stringify(ownerProject)}): ${JSON.stringify(scope)}`);
      }
      // The empty record retains its task key but no endpoint claim.
      writeFileSync(`${state}/${owner}.meta`, "");
    }
  }
}
for (const projectField of ["", "project=\n"]) {
  writeFileSync(`${state}/orca-task.meta`, `${projectField}terminal=orca-term-1\n`);
  writeFileSync(`${state}/orca-task.status`, "needs-decision: choose owner\n");
  writeFileSync(`${state}/.wake-queue`, "1\t1\tstale\torca-term-1\tstale: orca-term-1");
  const scope = scopeForUnreadWake(state, false);
  if (scope.eligible || !scope.corrupted) {
    throw new Error(`a unique projectless owner must remain unmappable: ${JSON.stringify(scope)}`);
  }
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a terminal-keyed Orca stale row must resolve to its task: $out"
  pass "scopeForUnreadWake resolves unique Orca terminal owners and refuses conflicting aliases alongside another eligible row"
}


test_branch_dispatch_keeps_project_with_canonical_owner() {
  local out status
  ROOT="$ROOT" CASE_ROOT="$TMP_ROOT/canonical-owner" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import assert from "node:assert/strict";
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const { scopeForUnreadWake, branchOfferForWake } = await import(pathToFileURL(`${process.env.ROOT}/.pi/extensions/lib/fm-branch-dispatch.ts`).href);
const originalReaddir = fs.readdirSync;
let fixture = 0;
for (const reverse of [false, true]) {
  const preload = `import fs from "node:fs"; import { syncBuiltinESMExports } from "node:module";
    const original = fs.readdirSync;
    fs.readdirSync = (...args) => { const names = original(...args).sort(); return ${reverse} ? names.reverse() : names; };
    syncBuiltinESMExports();`;
  fs.readdirSync = (...args) => {
    const names = originalReaddir(...args).sort();
    return reverse ? names.reverse() : names;
  };
  syncBuiltinESMExports();
  for (const field of ["window", "terminal"]) {
    for (const project of ["", "project=\n", "project=/owner\n"]) {
      for (const key of ["fm-window", "fm-fm-window"]) {
        const state = `${process.env.CASE_ROOT}/${fixture++}`;
        fs.mkdirSync(state, { recursive: true });
        fs.writeFileSync(`${state}/a.meta`, `${project}${field}=fm-window\n`);
        fs.writeFileSync(`${state}/window.meta`, "project=/approved\n");
        fs.writeFileSync(`${state}/window.status`, "needs-decision: choose owner\n");
        fs.writeFileSync(`${state}/.wake-queue`, `1\t1\tstale\t${key}\tstale: ${key}\n`);
        const check = (eligible, corrupted) => {
          for (const afk of [false, true]) {
            const scope = scopeForUnreadWake(state, false, afk);
            assert.equal(scope.eligible, eligible, JSON.stringify({ reverse, field, project, key, scope }));
            assert.equal(scope.corrupted, corrupted);
            if (eligible) {
              assert.deepEqual(scope.eligibleTasks, ["a"]);
              assert.deepEqual(scope.projects, ["/owner"]);
            }
            assert.equal(branchOfferForWake(state, `stale: ${key}`, afk).eligible, eligible);
            const cli = spawnSync(process.execPath, ["--import", `data:text/javascript,${encodeURIComponent(preload)}`,
              `${process.env.ROOT}/bin/fm-branch-dispatch.mjs`, "offer", ...(afk ? ["--afk"] : [])], {
              env: { ...process.env, FM_STATE_OVERRIDE: state }, input: `stale: ${key}\n`, encoding: "utf8",
            });
            assert.equal(cli.status, 0, cli.stderr);
            const result = Object.fromEntries(cli.stdout.trim().split("\n").map((line) => line.split("=")));
            assert.equal(result.eligible, eligible ? "1" : "0", cli.stdout);
            assert.equal(result.corrupted, corrupted ? "1" : "0", cli.stdout);
          }
        };
        check(Boolean(project.includes("/owner")), !project.includes("/owner"));
        fs.writeFileSync(`${state}/window.meta`, `project=/approved\n${field}=fm-window\n`);
        check(false, true);
      }
    }
  }
}
fs.readdirSync = originalReaddir;
syncBuiltinESMExports();
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "canonical ownership must govern scope and CLI offers: $out"
  pass "scope and CLI keep projects with canonical owners in both discovery orders"
}

# A second mate's status log is one shared channel for many independently keyed
# decisions, so its signal rows are judged by the span presented since the last
# drain (bounded by bin/fm-classify-lib.sh's own presentation-cursor writer),
# not by every decision still open anywhere in that log. Single-task crewmate
# logs keep their previous rule on both the Pi and the attended-host path.
test_branch_dispatch_routes_secondmate_signal_by_new_span() {
  local repo home out status
  repo="$TMP_ROOT/dispatch-span-root"
  home="$TMP_ROOT/dispatch-span-home"
  mkdir -p "$repo/.pi/extensions/lib" "$home/state" "$home/projects/approved"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  printf 'project=%s/projects/approved\nwindow=mate-window\nkind=secondmate\n' "$home" > "$home/state/mate.meta"
  printf 'project=%s/projects/approved\nwindow=crew-window\nkind=ship\n' "$home" > "$home/state/crew.meta"
  LIB="$repo/.pi/extensions/lib/fm-branch-dispatch.ts" FM_HOME="$home" CLASSIFY_LIB="$ROOT/bin/fm-classify-lib.sh" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import { appendFileSync, rmSync, writeFileSync } from "node:fs";

const { branchOfferForWake, scopeForUnreadWake } = await import(pathToFileURL(process.env.LIB).href);
const state = `${process.env.FM_HOME}/state`;
const signalRow = (task) => `1\t1\tsignal\t${task}.status\tsignal: ${task}.status`;

// Write the already-presented history, commit the presentation cursor at its
// end through the real writer, then append the unread span a new wake covers.
function stage(task, presented, span) {
  const path = `${state}/${task}.status`;
  writeFileSync(path, presented);
  execFileSync("bash", ["-c",
    'set -e; . "$1"; ident=$(_fm_open_decisions_file_ident "$2/$3.status"); ' +
    'status_commit_presentation_snapshot "$2" "$(printf "%s\\t%s\\t%s" "$3" "$4" "$ident")"',
    "_", process.env.CLASSIFY_LIB, state, task, String(Buffer.byteLength(presented))]);
  appendFileSync(path, span);
  writeFileSync(`${state}/.wake-queue`, signalRow(task));
}

// Both routing paths: the Pi dispatcher and the attended supervision host.
function verdicts() {
  return [false, true].map((attendedHost) => scopeForUnreadWake(state, false, false, attendedHost).eligibleSeqs.includes("1"));
}

function expectRoute(label, presented, span, toBranch) {
  stage("mate", presented, span);
  const [pi, host] = verdicts();
  if (pi !== toBranch || host !== toBranch) {
    throw new Error(`${label}: expected ${toBranch ? "branch" : "main"}, got pi=${pi} host=${host}`);
  }
}

const hold = "needs-decision [at=1790000000] [key=old-hold]: deferred captain call\n";
expectRoute("unrelated open hold plus a routine merged line", hold,
  "done [at=1790000100]: sample-a PR merged\n", true);
expectRoute("unrelated open hold stamped with a readable time", "needs-decision [at=10:00] [key=old-hold]: waiting\n",
  "done: sample-a PR merged\n", true);
expectRoute("routine note that only mentions an open key in prose", hold,
  "done: sample-a merged, unrelated to [key=old-hold]\n", true);
expectRoute("mixed routine and decision span", hold,
  "done: sample-b PR merged\nneeds-decision [key=new-call]: pick an option\n", false);
expectRoute("same-key update to an open decision", hold,
  "working [key=old-hold]: still gathering evidence\n", false);
expectRoute("same-key update behind a readable time stamp", hold,
  "working [at=10:30] [key=old-hold]: still gathering evidence\n", false);
expectRoute("key-less blocked line", hold, "blocked: cannot reach the forge\n", false);
expectRoute("resolution of an open decision", hold, "resolved [key=old-hold]: answered\n", false);
expectRoute("key-less resolution beside an unrelated open hold", hold, "resolved: routine follow-up\n", true);
expectRoute("key-less resolution of an open unkeyed decision", "needs-decision: pick an option\n",
  "resolved: answered\n", false);
expectRoute("keyed resolution of a never-open key", hold, "resolved [key=never-open]: nothing to close\n", true);
expectRoute("resolution after a bare resolved word left the unkeyed decision open",
  "needs-decision: choose\nresolved\n", "resolved: answered\n", false);
expectRoute("captain-held declaration", "working: history\n", "captain-held [key=parked]: deferred to Monday\n", false);

// The host decides the whole close through the offer rule, which must agree.
stage("mate", hold, "done: sample-c PR merged\n");
if (!branchOfferForWake(state, `signal: ${state}/mate.status`, false, true).eligible) {
  throw new Error("the attended-host offer kept a routine second-mate close on main behind an unrelated hold");
}

// Without a readable cursor the whole log is the span, so routing falls back
// toward main rather than guessing.
stage("mate", hold, "done: sample-d PR merged\n");
rmSync(`${state}/.status-presentation-cursor`);
if (verdicts().some(Boolean)) throw new Error("a missing presentation cursor did not fall back to the whole log");

// A stale row stays a whole-log liveness check, and a co-queued signal row for
// the same second mate keeps its own verdict in either order.
for (const [order, queue, signalSeq, staleSeq] of [
  ["stale first", "1\t1\tstale\tmate\tstale: mate\n1\t2\tsignal\tmate.status\tsignal: mate.status", "2", "1"],
  ["signal first", "1\t1\tsignal\tmate.status\tsignal: mate.status\n1\t2\tstale\tmate\tstale: mate", "1", "2"],
]) {
  stage("mate", hold, "done: sample-e PR merged\n");
  writeFileSync(`${state}/.wake-queue`, queue);
  for (const attendedHost of [false, true]) {
    const scope = scopeForUnreadWake(state, false, false, attendedHost);
    if (!scope.eligibleSeqs.includes(signalSeq) || scope.eligibleSeqs.includes(staleSeq)) {
      throw new Error(`${order}: signal and stale rows for one second mate shared a verdict: ${JSON.stringify(scope)}`);
    }
  }
}

// Single-task crewmate logs are unchanged: Pi judges only the row payload, and
// the attended host keeps its whole-log rule.
stage("crew", hold, "done: routine follow-up\n");
const [crewPi, crewHost] = verdicts();
if (!crewPi || crewHost) throw new Error(`crewmate signal routing changed: pi=${crewPi} host=${crewHost}`);
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "second-mate signal rows must be routed by their new span: $out"
  pass "second-mate signal rows route by their new span while crewmate and stale routing stay unchanged"
}

# The model picker's bounded scrolling and its search ranking are Pi's own
# SelectList and fuzzyFilter, so the guarantee only holds while the installed
# Pi still exports them and still bounds what it renders. Stubs cannot answer
# that, so this runs against the real package and skips when it is absent.
test_real_pi_picker_primitives_stay_bounded_and_searchable() {
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for the Pi picker primitives test"
    return
  fi
  local package_dir fixture original_dir out status
  package_dir=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
  if [ ! -f "$package_dir/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return
  fi
  fixture="$TMP_ROOT/real-picker-primitives"
  mkdir -p "$fixture/lib" "$fixture/node_modules/@earendil-works"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$fixture/lib/fm-branch-model-picker.ts"
  ln -s "$package_dir" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$package_dir/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  original_dir=$PWD
  cd "$fixture" || fail "could not enter the Pi picker primitives fixture"
  LIB="$fixture/lib/fm-branch-model-picker.ts" PI_VERSION_FILE="$package_dir/package.json" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";

const version = JSON.parse(readFileSync(process.env.PI_VERSION_FILE, "utf8")).version;
const { Input, SelectList, fuzzyFilter } = await import("@earendil-works/pi-tui");
const { DynamicBorder } = await import("@earendil-works/pi-coding-agent");
for (const [name, value] of [
  ["Input", Input],
  ["SelectList", SelectList],
  ["fuzzyFilter", fuzzyFilter],
  ["DynamicBorder", DynamicBorder],
]) {
  if (typeof value !== "function") {
    throw new Error(`installed pi ${version} no longer exports ${name}, which the supervision model picker renders through`);
  }
}

const { buildBranchModelItems, filterBranchPickerItems, BRANCH_PICKER_MAX_VISIBLE } = await import(
  pathToFileURL(process.env.LIB).href
);
const labels = Array.from({ length: 40 }, (_, i) => `anthropic/bulk-model-${i + 1}`);
labels.push("openai-codex/cheap-oauth");
const items = buildBranchModelItems("Follow main (anthropic/main-model)", labels, null);

// Pi's own list renders a bounded window plus at most one scroll indicator,
// which is what keeps a long catalog inside the dialog.
const passthrough = (text) => text;
const list = new SelectList(items, BRANCH_PICKER_MAX_VISIBLE, {
  selectedPrefix: passthrough,
  selectedText: passthrough,
  description: passthrough,
  scrollInfo: passthrough,
  noMatch: passthrough,
});
const lines = list.render(80);
if (lines.length > BRANCH_PICKER_MAX_VISIBLE + 1) {
  throw new Error(`installed pi ${version} rendered ${lines.length} rows for ${items.length} models instead of a bounded window`);
}
if (!lines[0].includes("Follow main")) {
  throw new Error(`installed pi ${version} did not render the first row the picker opens on`);
}

// Pi's own fuzzy ranking drives the search box, and following main stays first.
const searched = filterBranchPickerItems(items, "cheap", fuzzyFilter);
if (searched.length !== 1 || searched[0].value !== "openai-codex/cheap-oauth") {
  throw new Error(`installed pi ${version} fuzzy search did not narrow the catalog: ${JSON.stringify(searched)}`);
}
const mainSearch = filterBranchPickerItems(items, "main", fuzzyFilter);
if (mainSearch.length === 0 || mainSearch[0].label !== "Follow main (anthropic/main-model)") {
  throw new Error(`installed pi ${version} fuzzy ranking moved following main out of first place`);
}

// The search box is Pi's own single-line input.
const input = new Input();
input.handleInput("c");
input.handleInput("h");
if (input.getValue() !== "ch") {
  throw new Error(`installed pi ${version} Input no longer accumulates typed characters for the picker's search box`);
}
JS
  status=$?
  cd "$original_dir" || fail "could not leave the Pi picker primitives fixture"
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the installed Pi must still provide the picker's bounded searchable primitives: $out"
  [ -z "$out" ] || fail "Pi picker primitives test printed output: $out"
  pass "the installed Pi still bounds the picker's list and ranks its search"
}

# Pi's stock call header gained arguments in 0.99: before it, the header is
# the bold title alone; from 0.99 a collapsed call appends `key=json` and an
# expanded call lists `key: value` under the title. Both supervision tools
# must match the header of whichever Pi version loaded them.
test_outcomes_tool_call_headers_follow_the_loaded_pi_version() {
  local repo version status out
  repo="$TMP_ROOT/call-header-versions"
  install_pi_branch_extension_fixture "$repo"
  for version in 0.87.0 0.99.0; do
    FM_STUB_PI_VERSION="$version" EXT="$repo/.pi/extensions/fm-branch-supervision.ts" \
      node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const version = process.env.FM_STUB_PI_VERSION;
const tools = [];
const pi = {
  events: { on() {}, emit() {} },
  on() {},
  registerCommand() {},
  registerMessageRenderer() {},
  registerTool(tool) { tools.push(tool); },
  sendMessage() {},
  sendUserMessage() {},
};
const extension = await import(pathToFileURL(process.env.EXT).href);
extension.default(pi);
const theme = {
  fg(color, text) { return `<${color}>${text}</${color}>`; },
  bg(_color, text) { return text; },
  bold(text) { return `**${text}**`; },
};
const showsArgs = version === "0.99.0";
for (const [name, key, value] of [["fm_branch_outcomes", "recent", 2], ["fm_branch_processed", "through", 1]]) {
  const tool = tools.find((candidate) => candidate.name === name);
  if (!tool) throw new Error(`${name} was not registered`);
  const title = `<toolTitle>**${name}**</toolTitle>`;
  for (const expanded of [false, true]) {
    const stock = !showsArgs
      ? title
      : expanded
        ? `${title}\n<muted>  ${key}: ${value}</muted>`
        : `${title} <muted>${key}=${value}</muted>`;
    const shell = tool.renderCall({ [key]: value }, theme, { state: {}, expanded, isError: false, isPartial: false });
    const header = shell.children[0]?.text;
    if (header !== stock) {
      throw new Error(`Pi ${version} ${expanded ? "expanded" : "collapsed"} ${name} header ${JSON.stringify(header)} is not stock ${JSON.stringify(stock)}`);
    }
  }
}
JS
    status=$?
    out=$(cat "$TMP_ROOT/node-output")
    expect_code 0 "$status" "Pi $version supervision tool call headers must match that version's stock header: $out"
    [ -z "$out" ] || fail "Pi $version call header test printed output: $out"
  done
  pass "fm_branch_outcomes and fm_branch_processed call headers match stock on Pi before and from 0.99"
}

test_outcomes_tool_uses_stock_execution_and_export_consumers() {
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for Pi outcomes rendering test"
    return
  fi
  local package_dir package_version fixture out status
  package_dir=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
  if [ ! -f "$package_dir/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return
  fi
  # This case compares the extension's own renderers against Pi's stock
  # rendering, so its verdict is only meaningful against the vendor contract
  # those renderers target: since Pi 0.84.4 the stock renderer no longer
  # supplies an implicit reset at multiline boundaries, and the extension
  # emits that reset itself. An older installed Pi still supplies it, so the
  # two legitimately differ there and a comparison would report a defect that
  # is really a version skew. Name the version and skip rather than degrade
  # quietly; a package whose version cannot be read at all is still a failure.
  package_version=$(node -p 'require(process.argv[1]).version || ""' "$package_dir/package.json" 2>/dev/null || printf '')
  [ -n "$package_version" ] \
    || fail "installed @earendil-works/pi-coding-agent has no readable version at $package_dir"
  if ! pi_version_at_least "$package_version" "$PI_STOCK_RENDER_FLOOR"; then
    echo "skip: installed Pi $package_version predates the stock renderer contract $PI_STOCK_RENDER_FLOOR this case compares against"
    return
  fi
  fixture="$TMP_ROOT/stock-render-consumers"
  mkdir -p "$fixture/.pi/extensions/lib" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/.pi/extensions/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$fixture/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$fixture/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$fixture/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$fixture/.pi/extensions/lib/fm-branch-model-picker.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$fixture/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/.pi/extensions/lib/fm-operational-input.ts"
  ln -s "$package_dir" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$package_dir/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  ln -s "$package_dir/node_modules/@earendil-works/pi-ai" "$fixture/node_modules/@earendil-works/pi-ai"
  ln -s "$package_dir/node_modules/typebox" "$fixture/node_modules/typebox"

  out=$(cd "$fixture" && EXT="$fixture/.pi/extensions/fm-branch-supervision.ts" PI_PACKAGE_DIR="$package_dir" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ ToolExecutionComponent }, { createToolHtmlRenderer }, { initTheme, theme }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/tool-execution.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/core/export-html/tool-renderer.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
]);
initTheme("dark");

const listeners = new Map();
const tools = [];
const pi = {
  events: {
    on(name, listener) {
      listeners.set(name, [...(listeners.get(name) ?? []), listener]);
    },
    emit(name, data) {
      for (const listener of listeners.get(name) ?? []) listener(data);
    },
  },
  on() {},
  registerCommand() {},
  registerMessageRenderer() {},
  registerTool(tool) { tools.push(tool); },
  sendMessage() {},
  sendUserMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?consumer=${Date.now()}`);
extension.default(pi);
const actualDefinition = tools.find((tool) => tool.name === "fm_branch_outcomes");
if (!actualDefinition) throw new Error("fm_branch_outcomes was not registered");
const stockDefinition = { ...actualDefinition };
delete stockDefinition.renderShell;
delete stockDefinition.renderCall;
delete stockDefinition.renderResult;

const args = { recent: 2 };
const result = {
  content: [{
    type: "text",
    text: [
      "\x1b[31mOUTCOME_ONE\x1b[0m",
      "OUT\u0000COME_TWO\uFFF9",
      "OUTCOME_THREE",
      "OUTCOME_FOUR",
      "OUTCOME_FIVE",
      "OUTCOME_SIX",
      "OUTCOME_SEVEN",
      "OUTCOME_EIGHT",
      "OUTCOME_NINE",
      "OUTCOME_TEN",
      "OUTCOME_ELEVEN",
      "OUTCOME_TWELVE",
    ].join("\r\n"),
  }],
  details: { ok: true },
  isError: false,
};
const ui = { requestRender() {} };
const stockRow = new ToolExecutionComponent("fm_branch_outcomes", "stock", args, { showImages: false }, stockDefinition, ui, process.cwd());
const actualRow = new ToolExecutionComponent("fm_branch_outcomes", "actual", args, { showImages: false }, actualDefinition, ui, process.cwd());
for (const row of [stockRow, actualRow]) {
  row.markExecutionStarted();
  row.setArgsComplete();
  row.updateResult(result);
}
const collapsedStock = stockRow.render(100);
const collapsedActual = actualRow.render(100);
if (JSON.stringify(collapsedActual) !== JSON.stringify(collapsedStock)) {
  throw new Error("Calm-off ToolExecutionComponent rendering differs from Pi stock");
}
const collapsedText = collapsedStock.join("\n");
if (collapsedText.includes("OUTCOME_TWELVE") || !collapsedText.includes("more lines") || !collapsedText.includes("to expand")) {
  throw new Error("stock rendering fixture did not exercise its collapsed preview and expansion hint");
}
stockRow.setExpanded(true);
actualRow.setExpanded(true);
const expandedStock = stockRow.render(100);
const expandedActual = actualRow.render(100);
if (JSON.stringify(expandedActual) !== JSON.stringify(expandedStock)) {
  throw new Error("expanded Calm-off ToolExecutionComponent rendering differs from Pi stock");
}
if (!expandedStock.join("\n").includes("OUTCOME_TWELVE") || JSON.stringify(expandedStock) === JSON.stringify(collapsedStock)) {
  throw new Error("stock rendering fixture did not exercise expanded output");
}
const processedDefinition = tools.find((tool) => tool.name === "fm_branch_processed");
if (!processedDefinition) throw new Error("fm_branch_processed was not registered");
const stockProcessedDefinition = { ...processedDefinition };
delete stockProcessedDefinition.renderShell;
delete stockProcessedDefinition.renderCall;
delete stockProcessedDefinition.renderResult;
const processedArgs = { through: 1 };
const processedResult = { content: [{ type: "text", text: "acknowledged through 1" }], details: undefined, isError: false };
const stockProcessed = new ToolExecutionComponent("fm_branch_processed", "stock-processed", processedArgs, { showImages: false }, stockProcessedDefinition, ui, process.cwd());
const actualProcessed = new ToolExecutionComponent("fm_branch_processed", "actual-processed", processedArgs, { showImages: false }, processedDefinition, ui, process.cwd());
for (const row of [stockProcessed, actualProcessed]) {
  row.markExecutionStarted();
  row.setArgsComplete();
  row.updateResult(processedResult);
}
for (const expanded of [false, true]) {
  stockProcessed.setExpanded(expanded);
  actualProcessed.setExpanded(expanded);
  if (JSON.stringify(actualProcessed.render(100)) !== JSON.stringify(stockProcessed.render(100))) {
    throw new Error(`${expanded ? "expanded" : "collapsed"} Calm-off fm_branch_processed rendering differs from Pi stock`);
  }
}
pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: false });
actualRow.invalidate();
if (actualRow.render(100).length !== 0) {
  throw new Error("Calm-on ToolExecutionComponent row remained visible");
}
pi.events.emit("firstmate:calm-presentation", { active: false, stockExportRendering: false });
actualRow.invalidate();
if (JSON.stringify(actualRow.render(100)) !== JSON.stringify(stockRow.render(100))) {
  throw new Error("ToolExecutionComponent rendering did not restore after live toggle");
}

pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: true });
const stockHtml = createToolHtmlRenderer({ getToolDefinition: () => stockDefinition, theme, cwd: process.cwd() });
const actualHtml = createToolHtmlRenderer({ getToolDefinition: () => actualDefinition, theme, cwd: process.cwd() });
const stockCall = stockHtml.renderCall("stock-html", "fm_branch_outcomes", args);
const actualCall = actualHtml.renderCall("actual-html", "fm_branch_outcomes", args);
const stockResult = stockHtml.renderResult("stock-html", "fm_branch_outcomes", result.content, result.details, false);
const actualResult = actualHtml.renderResult("actual-html", "fm_branch_outcomes", result.content, result.details, false);
if (actualCall !== undefined || actualResult !== undefined || stockCall !== undefined || stockResult !== undefined) {
  throw new Error("stock export rendering did not delegate to Pi's structured fallback");
}
JS
  )
  status=$?
  expect_code 0 "$status" "Pi outcomes rendering consumers must preserve stock behavior: $out"
  [ -z "$out" ] || fail "Pi outcomes rendering consumer test printed output: $out"
  pass "fm_branch_outcomes hides through ToolExecutionComponent while Calm-off and HTML export stay stock"
}

# The delivery path runs on Pi's single JS thread, so a delivery that blocks
# it is a delivery the captain sees as a frozen TUI. These three cover what
# moving that work off the thread must not cost: responsiveness during a
# delivery, and the ordering, exactly-once, and cancellation guarantees that
# the single thread used to provide for free.
test_delivery_keeps_the_event_loop_live_and_ordered() {
  local repo home out status
  repo="$TMP_ROOT/delivery-responsiveness-root"
  home="$TMP_ROOT/delivery-responsiveness-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx }; })()`);
const { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx } = globalThis.__t;

await fire("session_start", {}, defaultSessionCtx);
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
const offer = dispatch("signal: branch-driver working");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const report = globalThis.__fmSessions[0].options.customTools.find((tool) => tool.name === "fm_branch_report");

// A repeating timer is the event loop's own liveness: it cannot tick while
// the single JS thread is blocked, which is exactly what the TUI's repaint
// and key echo cannot do either. Ticks observed WHILE one outcome is being
// delivered are therefore the responsiveness this delivery preserves.
function loopProbe(intervalMs) {
  let ticks = 0;
  let worstGapMs = 0;
  let last = process.hrtime.bigint();
  const timer = setInterval(() => {
    const now = process.hrtime.bigint();
    const gap = Number(now - last) / 1e6;
    if (gap > worstGapMs) worstGapMs = gap;
    last = now;
    ticks += 1;
  }, intervalMs);
  return {
    reset() { ticks = 0; worstGapMs = 0; last = process.hrtime.bigint(); },
    stop() { clearInterval(timer); },
    get ticks() { return ticks; },
    get worstGapMs() { return worstGapMs; },
  };
}

const probe = loopProbe(5);
await new Promise((resolve) => setTimeout(resolve, 40));
probe.reset();
const idleStart = process.hrtime.bigint();
await new Promise((resolve) => setTimeout(resolve, 120));
const idleWallMs = Number(process.hrtime.bigint() - idleStart) / 1e6;
const idleWorstGapMs = probe.worstGapMs;

async function timedDelivery(callId, params) {
  probe.reset();
  const started = process.hrtime.bigint();
  const result = await report.execute(callId, params, undefined, undefined, {});
  const wallMs = Number(process.hrtime.bigint() - started) / 1e6;
  return { result, wallMs, ticks: probe.ticks, worstGapMs: probe.worstGapMs };
}

const routine = await timedDelivery("live-routine", { task: "branch-driver", verdict: "routine", summary: "routine outcome during a live loop" });
if (routine.result.isError) throw new Error(`routine delivery failed: ${JSON.stringify(routine.result)}`);
const captain = await timedDelivery("live-captain", { task: "branch-driver", verdict: "captain", summary: "captain outcome during a live loop" });
if (captain.result.isError) throw new Error(`captain delivery failed: ${JSON.stringify(captain.result)}`);
probe.stop();

// Two independent signals, so neither a fast machine nor a slow one can make
// this vacuous. First: the loop must actually run during the delivery. A
// delivery built on synchronous subprocesses ticks zero times no matter how
// fast the host is, because nothing else can run at all.
for (const [label, measured] of [["routine", routine], ["captain", captain]]) {
  if (measured.ticks < 4) {
    throw new Error(`${label} delivery blocked the event loop: ${measured.ticks} ticks in ${measured.wallMs.toFixed(1)} ms`);
  }
  // Second: the longest single stall must be a MINORITY of the delivery it
  // happens inside. Stated as a fraction rather than a millisecond budget on
  // purpose - a loaded machine that descheduled this process would inflate an
  // absolute budget into a false failure, while it inflates the delivery's own
  // wall time too, so the fraction stays meaningful. A delivery built on
  // synchronous subprocesses sits near 1.0 here whatever the load.
  const stallBudgetMs = Math.max(measured.wallMs * 0.5, idleWorstGapMs * 4);
  if (measured.worstGapMs > stallBudgetMs) {
    throw new Error(
      `${label} delivery stalled the event loop for ${measured.worstGapMs.toFixed(1)} ms of its own ${measured.wallMs.toFixed(1)} ms (budget ${stallBudgetMs.toFixed(1)} ms, idle jitter ${idleWorstGapMs.toFixed(1)} ms over ${idleWallMs.toFixed(0)} ms)`,
    );
  }
}

// Interleaving: six outcomes reported without waiting for each other must
// still reach the store and main in sequence order, each exactly once. The
// captain rows also prove the visible entries land in the same order.
const many = await Promise.all(
  Array.from({ length: 6 }, (_, index) => report.execute(
    `interleaved-${index}`,
    {
      task: "branch-driver",
      verdict: index % 2 === 0 ? "routine" : "captain",
      summary: `interleaved outcome ${index}`,
    },
    undefined,
    undefined,
    {},
  )),
);
finishWakePrompt();
await offer.settlement;
for (const [index, result] of many.entries()) {
  if (result.isError) throw new Error(`interleaved delivery ${index} failed: ${JSON.stringify(result)}`);
}

const stored = outcomeScript(["list", "--recent", "50"]).split("\n").filter(Boolean).map((line) => JSON.parse(line));
const interleaved = stored.filter((row) => row.summary.startsWith("interleaved outcome "));
if (interleaved.length !== 6) {
  throw new Error(`interleaved deliveries did not store exactly six rows: ${JSON.stringify(interleaved.map((row) => row.summary))}`);
}
const seqs = interleaved.map((row) => row.seq);
if (seqs.slice().sort((a, b) => a - b).join(",") !== seqs.join(",")) {
  throw new Error(`stored sequences are not monotonic: ${seqs}`);
}
if (new Set(seqs).size !== seqs.length) throw new Error(`a sequence was reused: ${seqs}`);

const deliveredRoutine = sentToMain
  .filter((sent) => sent.message.customType === "fm-branch-merge" && sent.message.content.includes("interleaved outcome "))
  .map((sent) => sent.message.content);
const routineSummaries = interleaved.filter((row) => row.verdict === "routine").map((row) => `⛵ branch-driver: ${row.summary}`);
if (deliveredRoutine.join("|") !== routineSummaries.join("|")) {
  throw new Error(`routine notes lost, duplicated, or reordered: ${JSON.stringify(deliveredRoutine)} vs ${JSON.stringify(routineSummaries)}`);
}
const deliveredCaptain = mainEntries
  .filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.summary.startsWith("interleaved outcome "))
  .map((entry) => entry.data.seq);
const captainSeqs = interleaved.filter((row) => row.verdict === "captain").map((row) => row.seq);
if (deliveredCaptain.join(",") !== captainSeqs.join(",")) {
  throw new Error(`captain entries lost, duplicated, or reordered: ${deliveredCaptain} vs ${captainSeqs}`);
}
// Everything delivered is recorded as read, so a later reconciliation cannot
// deliver any of it a second time.
if (outcomeScript(["unread"]) !== "") throw new Error("delivered outcomes were left unread");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "delivery must keep the event loop live and stay ordered: $out"
  pass "outcome delivery keeps the event loop running and interleaved reports stay ordered and exactly once"
}

test_session_replacement_during_delivery_neither_loses_nor_duplicates() {
  local repo home fakebin out status real_ps
  repo="$TMP_ROOT/delivery-replacement-root"
  home="$TMP_ROOT/delivery-replacement-home"
  fakebin="$home/fakebin"
  real_ps=$(command -v ps)
  mkdir -p "$home/state" "$home/config" "$fakebin"
  install_pi_branch_extension_fixture "$repo"
  cat > "$fakebin/ps" <<'SH'
#!/bin/sh
if [ -f "$FM_TEST_PS_ARM" ]; then
  rm -f "$FM_TEST_PS_ARM"
  : > "$FM_TEST_PS_ENTERED"
  while [ ! -f "$FM_TEST_PS_RELEASE" ]; do sleep 0.01; done
fi
exec "$FM_TEST_REAL_PS" "$@"
SH
  chmod +x "$fakebin/ps"
  PATH="$fakebin:$PATH" PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REAL_PS="$real_ps" FM_TEST_PS_ARM="$home/state/ps-arm" \
    FM_TEST_PS_ENTERED="$home/state/ps-entered" FM_TEST_PS_RELEASE="$home/state/ps-release" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, home }; })()`);
const { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, home } = globalThis.__t;
import { existsSync, writeFileSync } from "node:fs";

const firstEntries = [];
const firstCtx = {
  sessionManager: { getSessionFile: () => `${home}/first.jsonl`, getEntries: () => firstEntries },
};
const secondEntries = [];
const secondCtx = {
  sessionManager: { getSessionFile: () => `${home}/second.jsonl`, getEntries: () => secondEntries },
};

// Use the live parent as lock owner so each ownership check must traverse at
// least one real ps subprocess; a self-owned lock would return before the
// asynchronous boundary this regression needs to hold open.
writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);
await fire("session_start", {}, firstCtx);
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
const offer = dispatch("signal: branch-driver working");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const report = globalThis.__fmSessions[0].options.customTools.find((tool) => tool.name === "fm_branch_report");
const toolGeneration = 1;

// A delivery that is still in flight when the captain replaces the session
// (/new, /resume, /fork, reload) must stop acting into the replaced session.
writeFileSync(process.env.FM_TEST_PS_ARM, "");
const inFlight = report.execute(
  "replaced-mid-delivery",
  { task: "branch-driver", verdict: "captain", summary: "reported as the session was replaced" },
  undefined,
  undefined,
  {},
);
await settle(() => existsSync(process.env.FM_TEST_PS_ENTERED), "in-flight ownership subprocess");
await fire("session_shutdown", {});
const replacementStart = fire("session_start", {}, secondCtx);
writeFileSync(process.env.FM_TEST_PS_RELEASE, "");
await replacementStart;
const replaced = await inFlight;
if (!replaced.isError) {
  throw new Error(`a report from the replaced session was accepted: ${JSON.stringify(replaced)}`);
}

// Nothing was delivered into either session's transcript by that refused
// report, and nothing was stored for it either: the refusal happened before
// the durable append, so there is no orphan row.
const storedAfter = outcomeScript(["list", "--recent", "50"]).split("\n").filter(Boolean).map((line) => JSON.parse(line));
if (storedAfter.some((row) => row.summary === "reported as the session was replaced")) {
  throw new Error("a report refused for a replaced session still reached the durable store");
}
if (firstEntries.length !== 0 || secondEntries.length !== 0 || sentToMain.length !== 0) {
  throw new Error("a report refused for a replaced session still delivered something visible");
}
finishWakePrompt();
await offer.settlement.then(() => null, () => null);

// A row that WAS stored but not yet delivered when the session was replaced
// is not lost: the new session's own reconciliation delivers it exactly once,
// into the new transcript, and advances the cursor past it.
const orphanSeq = Number(outcomeScript(["append", "--task", "branch-driver", "--verdict", "captain", "--summary", "stored before the replacement"]));
await fire("session_shutdown", {});
const thirdEntries = [];
await fire("session_start", {}, {
  sessionManager: { getSessionFile: () => `${home}/third.jsonl`, getEntries: () => thirdEntries },
});
const recovered = thirdEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
if (recovered.length !== 1 || recovered[0].data.seq !== orphanSeq) {
  throw new Error(`the replacement session did not deliver the stored row exactly once: ${JSON.stringify(recovered)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("the replacement session did not advance the read cursor");

// Reconciling again delivers nothing further: the cursor, not the transcript,
// is what stops a second delivery.
await fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/third.jsonl`, getEntries: () => thirdEntries },
});
if (thirdEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome").length !== 1) {
  throw new Error("a later reconciliation delivered the same captain outcome twice");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a session replaced mid-delivery must neither lose nor duplicate an outcome: $out"
  pass "a session replaced mid-delivery cancels cleanly and the stored outcome still arrives exactly once"
}

test_store_failure_during_delivery_neither_loses_nor_duplicates() {
  local repo home fakebin out status real_bash
  repo="$TMP_ROOT/delivery-store-failure-root"
  home="$TMP_ROOT/delivery-store-failure-home"
  fakebin="$home/fakebin"
  real_bash=$(command -v bash)
  mkdir -p "$home/state" "$home/config" "$fakebin"
  install_pi_branch_extension_fixture "$repo"
  # Fails exactly the store subcommand the arming file names, once, so the
  # delivery meets a real failing script rather than a stubbed return value.
  # The driver arms it through that file because the extension snapshots its
  # child environment when it loads.
  cat > "$fakebin/bash" <<'SH'
#!/bin/sh
armed=$(cat "$FM_TEST_FAIL_ARM" 2>/dev/null || printf '')
if [ -n "$armed" ] && [ "$1" = "$FM_TEST_OUTCOME_SCRIPT" ] && [ "$2" = "$armed" ]; then
  : > "$FM_TEST_FAIL_ARM"
  echo "injected store failure" >&2
  exit 9
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
  chmod +x "$fakebin/bash"
  PATH="$fakebin:$PATH" PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REAL_BASH="$real_bash" FM_TEST_OUTCOME_SCRIPT="$ROOT/bin/fm-branch-outcome.sh" \
    FM_TEST_FAIL_ARM="$home/state/store-fail-arm" DRIVER_PRELUDE="$DRIVER_PRELUDE" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx }; })()`);
const { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx } = globalThis.__t;
import { writeFileSync } from "node:fs";

const failArm = process.env.FM_TEST_FAIL_ARM;
const armStoreFailure = (subcommand) => writeFileSync(failArm, subcommand);
await fire("session_start", {}, defaultSessionCtx);
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
const offer = dispatch("signal: branch-driver working");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const report = globalThis.__fmSessions[0].options.customTools.find((tool) => tool.name === "fm_branch_report");

// 1. The durable append fails: the failure surfaces to the branch, and
// nothing is delivered, because nothing was ever stored.
armStoreFailure("append");
const appendFailed = await report.execute("append-fails", { task: "branch-driver", verdict: "routine", summary: "append must fail" }, undefined, undefined, {});
if (!appendFailed.isError || !appendFailed.content[0].text.includes("outcome store append failed")) {
  throw new Error(`a failed append did not surface as an error: ${JSON.stringify(appendFailed)}`);
}
if (sentToMain.length !== 0 || mainEntries.length !== 0) throw new Error("a failed append still delivered something visible");
if (outcomeScript(["list", "--recent", "50"]) !== "") throw new Error("a failed append still left a stored row");

// 2. The cursor advance fails AFTER the row is durable and delivered. The
// branch is told, the row stays in the store exactly once, and the next
// reconciliation completes the delivery rather than losing it.
armStoreFailure("mark-read");
const markFailed = await report.execute("mark-read-fails", { task: "branch-driver", verdict: "captain", summary: "cursor advance must fail" }, undefined, undefined, {});
if (!markFailed.isError || !markFailed.content[0].text.includes("visible delivery or cursor advancement failed")) {
  throw new Error(`a failed cursor advance did not surface as an error: ${JSON.stringify(markFailed)}`);
}
const afterFailure = outcomeScript(["list", "--recent", "50"]).split("\n").filter(Boolean).map((line) => JSON.parse(line));
if (afterFailure.length !== 1 || afterFailure[0].summary !== "cursor advance must fail") {
  throw new Error(`the durable row was lost or duplicated by the failed cursor advance: ${JSON.stringify(afterFailure)}`);
}
const failedSeq = afterFailure[0].seq;
if (outcomeScript(["unread"]) === "") throw new Error("a failed cursor advance still marked the row read");

// 3. Recovery: the same row is delivered exactly once and the cursor now
// advances, so nothing is lost and nothing is doubled.
armStoreFailure("");
await fire("turn_end", {}, defaultSessionCtx);
const visible = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === failedSeq);
if (visible.length !== 1) {
  throw new Error(`the recovered captain outcome is not present exactly once: ${JSON.stringify(visible)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("recovery did not advance the read cursor");
await fire("turn_end", {}, defaultSessionCtx);
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === failedSeq).length !== 1) {
  throw new Error("a later reconciliation delivered the recovered outcome a second time");
}
finishWakePrompt();
await offer.settlement.then(() => null, () => null);
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a store failure during delivery must neither lose nor duplicate an outcome: $out"
  pass "a failing store script surfaces to the branch and its outcome is neither lost nor delivered twice"
}

# The failure boundary the async conversion had to leave exactly as it found
# it: a routine note is delivered and then its cursor write fails. Routine
# notes carry no sequence key, so the next reconciliation delivers the same
# note again - a KNOWN PRE-EXISTING limitation of the routine delivery
# representation, tracked as fm-pi-routine-delivery-idempotency-followup-r1,
# not something moving the work off Pi's render thread introduced. This pins
# the exact shape (one re-delivery, never more, nothing lost) so a future
# change cannot quietly worsen it, and pins the captain row's sequence-keyed
# deduplication that makes the two paths differ.
test_mark_read_failure_keeps_routine_redelivery_and_captain_deduplication() {
  local repo home fakebin out status real_bash
  repo="$TMP_ROOT/mark-read-failure-shape-root"
  home="$TMP_ROOT/mark-read-failure-shape-home"
  fakebin="$home/fakebin"
  real_bash=$(command -v bash)
  mkdir -p "$home/state" "$home/config" "$fakebin"
  install_pi_branch_extension_fixture "$repo"
  cat > "$fakebin/bash" <<'SH'
#!/bin/sh
armed=$(cat "$FM_TEST_FAIL_ARM" 2>/dev/null || printf '')
if [ -n "$armed" ] && [ "$1" = "$FM_TEST_OUTCOME_SCRIPT" ] && [ "$2" = "$armed" ]; then
  : > "$FM_TEST_FAIL_ARM"
  echo "injected store failure" >&2
  exit 9
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
  chmod +x "$fakebin/bash"
  PATH="$fakebin:$PATH" PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REAL_BASH="$real_bash" FM_TEST_OUTCOME_SCRIPT="$ROOT/bin/fm-branch-outcome.sh" \
    FM_TEST_FAIL_ARM="$home/state/store-fail-arm" DRIVER_PRELUDE="$DRIVER_PRELUDE" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx }; })()`);
const { fire, dispatch, settle, outcomeScript, sentToMain, mainEntries, defaultSessionCtx } = globalThis.__t;
import { writeFileSync } from "node:fs";

const failArm = process.env.FM_TEST_FAIL_ARM;
const armStoreFailure = (subcommand) => writeFileSync(failArm, subcommand);
const storedRows = () => outcomeScript(["list", "--recent", "50"]).split("\n").filter(Boolean).map((line) => JSON.parse(line));
const routineCopies = (summary) => sentToMain.filter(
  (sent) => sent.message.customType === "fm-branch-merge" && sent.message.content.includes(summary),
).length;
const captainCopies = (seq) => mainEntries.filter(
  (entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === seq,
).length;

await fire("session_start", {}, defaultSessionCtx);
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
const offer = dispatch("signal: branch-driver working");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const report = globalThis.__fmSessions[0].options.customTools.find((tool) => tool.name === "fm_branch_report");

// A routine note is delivered, then its cursor write fails.
const routineSummary = "routine note whose cursor write fails";
armStoreFailure("mark-read");
const routineFailed = await report.execute("routine-mark-read-fails", { task: "branch-driver", verdict: "routine", summary: routineSummary }, undefined, undefined, {});
if (!routineFailed.isError || !routineFailed.content[0].text.includes("visible delivery or cursor advancement failed")) {
  throw new Error(`a failed routine cursor advance did not surface as an error: ${JSON.stringify(routineFailed)}`);
}
if (routineCopies(routineSummary) !== 1) {
  throw new Error(`the routine note was not delivered exactly once before the cursor failure: ${routineCopies(routineSummary)}`);
}
let stored = storedRows();
if (stored.length !== 1) throw new Error(`the failed cursor write changed the store: ${JSON.stringify(stored)}`);
if (outcomeScript(["unread"]) === "") throw new Error("a failed cursor write still marked the routine row read");

// The next reconciliation re-delivers it, because a routine note has no
// sequence-keyed record to recognize. That second copy is the pre-existing
// limitation; what must hold is that it is exactly one more, and that the
// store and cursor recover.
armStoreFailure("");
await fire("turn_end", {}, defaultSessionCtx);
if (routineCopies(routineSummary) !== 2) {
  throw new Error(`recovery did not re-deliver the routine note exactly once: ${routineCopies(routineSummary)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("recovery did not advance the cursor past the routine row");
stored = storedRows();
if (stored.length !== 1) throw new Error(`recovery changed the stored routine row: ${JSON.stringify(stored)}`);

// Once the cursor is past it, no further reconciliation delivers it again:
// the duplication window is the failed write, not an unbounded repeat.
await fire("turn_end", {}, defaultSessionCtx);
if (routineCopies(routineSummary) !== 2) {
  throw new Error(`the routine note kept being re-delivered after the cursor advanced: ${routineCopies(routineSummary)}`);
}

// The same failure on a captain row does NOT duplicate: its visible entry is
// keyed by store sequence, so the re-run recognizes its own earlier write.
const captainSummary = "captain outcome whose cursor write fails";
armStoreFailure("mark-read");
const captainFailed = await report.execute("captain-mark-read-fails", { task: "branch-driver", verdict: "captain", summary: captainSummary }, undefined, undefined, {});
if (!captainFailed.isError) throw new Error(`a failed captain cursor advance did not surface as an error: ${JSON.stringify(captainFailed)}`);
const captainSeq = storedRows().find((row) => row.summary === captainSummary).seq;
if (captainCopies(captainSeq) !== 1) throw new Error(`the captain entry was not written exactly once: ${captainCopies(captainSeq)}`);
armStoreFailure("");
await fire("turn_end", {}, defaultSessionCtx);
if (captainCopies(captainSeq) !== 1) {
  throw new Error(`recovery duplicated the captain entry: ${captainCopies(captainSeq)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("recovery did not advance the cursor past the captain row");
if (storedRows().length !== 2) throw new Error(`the store lost or duplicated a row across both failures: ${JSON.stringify(storedRows())}`);

// The durable cursor, not this session, is what closes both windows: a new
// main session reconciles and re-delivers neither of them.
finishWakePrompt();
await offer.settlement.then(() => null, () => null);
await fire("session_start", {}, defaultSessionCtx);
if (routineCopies(routineSummary) !== 2 || captainCopies(captainSeq) !== 1) {
  throw new Error(`a new session re-delivered an already-read outcome: routine=${routineCopies(routineSummary)} captain=${captainCopies(captainSeq)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a failed cursor write must keep the routine re-delivery shape and the captain deduplication: $out"
  pass "a failed cursor write re-delivers a routine note exactly once more while a captain outcome stays deduplicated"
}

test_extension_registered_provider_resolves_in_the_branch() {
  local repo home out status
  repo="$TMP_ROOT/extprov-root"
  home="$TMP_ROOT/extprov-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, uiSelections, uiPrompts, notices, commands, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, uiSelections, uiPrompts, notices, commands, home } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

// An extension-registered provider exists only in main's registry, never in
// the isolated branch runtime's static catalog. Registering its config on
// main's registry is what makes it resolvable for the branch.
registryModels.push(
  { provider: "anthropic", id: "main-model" },
  // Available in main's registry but absent from the branch runtime's static
  // catalog, exactly like a provider an extension registered at runtime.
  { provider: "devin", id: "swe-1-7", branchAvailable: false },
);
globalThis.__fmExtensionProviderConfigs = new Map([
  [
    "devin",
    {
      name: "Devin (Cognition)",
      api: "devin-cloud",
      baseUrl: "https://server.codeium.com",
      models: [{ id: "swe-1-7", name: "SWE 1.7", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 8192 }],
      oauth: { name: "Devin (Cognition / Windsurf)", login: async () => ({}), refreshToken: async (c) => c, getApiKey: (c) => c.access },
      streamSimple: () => {},
    },
  ],
]);

await fire("session_start", {}, makeCtx());

// The picker must offer the extension-registered model: it is available in
// main's registry and resolvable in the branch runtime once its registration
// is copied across.
const command = commands.get("supervision-model");
if (!command) throw new Error("the supervision-model command was not registered");
uiSelections.push("devin/swe-1-7");
await command.handler("", makeCtx());
const offered = uiPrompts[0];
if (!offered.options.includes("devin/swe-1-7")) {
  throw new Error(`the picker must offer an extension-registered provider the branch can run: ${JSON.stringify(offered.options)}`);
}
if (readFileSync(`${home}/config/supervision-branch-model`, "utf8") !== "devin/swe-1-7\n") {
  throw new Error("the extension-registered pick was not persisted");
}
dispatch("signal: extension provider pin");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "pinned extension-provider branch build");
const pinned = globalThis.__fmSessions[0].options.model;
if (!pinned || pinned.provider !== "devin" || pinned.id !== "swe-1-7") {
  throw new Error(`the extension-registered pin did not bind the branch: ${JSON.stringify(pinned)}`);
}
// Copying the provider registration must not loosen the branch's isolation:
// the devin-pinned session still loads no extensions, skills, or context files.
const pinnedLoader = globalThis.__fmLoaders.at(-1);
for (const key of ["noExtensions", "noSkills", "noContextFiles"]) {
  if (pinnedLoader.options[key] !== true) throw new Error(`devin-pinned branch loader must keep ${key}`);
}

// Without the registration, the same pin is unavailable and the branch
// refuses to build rather than silently downgrading.
globalThis.__fmExtensionProviderConfigs = new Map();
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
const unregisteredOffer = dispatch("signal: unregistered provider pin");
if (!unregisteredOffer.accepted) throw new Error("unregistered-pin wake was not initially accepted");
const unregisteredFailure = await unregisteredOffer.settlement.then(
  () => null,
  (error) => error,
);
if (
  !(unregisteredFailure instanceof Error) ||
  !unregisteredFailure.message.includes("devin/swe-1-7") ||
  !unregisteredFailure.message.includes("supervision model pin")
) {
  throw new Error(`the unregistered pin did not reject with its own name: ${String(unregisteredFailure)}`);
}
if ((globalThis.__fmSessions ?? []).length !== 1) throw new Error("an unregistered pin must not build a second branch session");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an extension-registered provider must resolve in the isolated branch runtime: $out"
  pass "an extension-registered provider resolves in the isolated branch runtime"
}
