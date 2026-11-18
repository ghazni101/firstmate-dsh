# shellcheck shell=bash
# Test cases for fm-pi-branch-extension, split out of tests/fm-pi-branch-extension.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-pi-branch-extension.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


test_away_only_wake_rejects_when_record_is_archived_before_drain() {
  local repo home out status
  repo="$TMP_ROOT/away-only-recheck-root"
  home="$TMP_ROOT/away-only-recheck-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, home, realRoot, bus, makeOffer, mainUserMessages, approvedProject }; })()`);
const { fire, home, realRoot, bus, makeOffer, mainUserMessages, approvedProject } = globalThis.__t;
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const contract = (args) => {
  const result = spawnSync("bash", [`${realRoot}/bin/fm-afk-contract.sh`, ...args], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state` },
  });
  if (result.status !== 0) throw new Error(`fm-afk-contract.sh ${args.join(" ")} failed: ${result.stderr}`);
  return result.stdout || "";
};

await fire("session_start", {});
contract(["enter"]);
writeFileSync(`${home}/state/.wake-queue`, "1\t1\tcheck\tmain-only\tcheck: task-d.check.sh: PR merged\n");
contract(["archive"]);
const offer = makeOffer("check: task-d.check.sh: PR merged", [], false, true, true);
bus.emit("fm-branch-supervision:dispatch", offer);
if (!offer.accepted) throw new Error("the away check-only wake was refused at accept");
const failure = await offer.settlement.then(() => null, (error) => error);
if (!(failure instanceof Error) || !failure.message.includes("no longer branch-eligible")) {
  throw new Error(`an away-only wake archived before accept quiet-no-op'd: ${String(failure)}`);
}
if ((globalThis.__fmPrompts ?? []).length !== 0) {
  throw new Error(`the archived away-only wake still prompted the branch: ${JSON.stringify(globalThis.__fmPrompts)}`);
}
if (mainUserMessages.length !== 0) {
  throw new Error("the rejected settlement leaked a main user message from the branch");
}

contract(["enter"]);
writeFileSync(`${home}/state/.wake-queue`, "1\t1\tsignal\tbranch-driver.status\tsignal: branch-driver.status\n");
const taskLocal = makeOffer("signal: branch-driver.status", [approvedProject], false, true);
bus.emit("fm-branch-supervision:dispatch", taskLocal);
if (!taskLocal.accepted) throw new Error("the attended-eligible away wake was refused at accept");
writeFileSync(`${home}/state/.wake-queue`, "");
const quiet = await taskLocal.settlement.then(() => null, (error) => error);
if (quiet instanceof Error) {
  throw new Error(`an attended-eligible wake threw after it was drained: ${quiet.message}`);
}
if ((globalThis.__fmPrompts ?? []).length !== 0) {
  throw new Error(`a drained task-local wake prompted the branch: ${JSON.stringify(globalThis.__fmPrompts)}`);
}
if (mainUserMessages.length !== 0) {
  throw new Error("a drained task-local wake opened a redundant main turn");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an accepted away-only wake must reject after archive: $out"
  pass "an accepted away-only wake rejects after archive, while a drained task-local wake stays a quiet no-op"
}

test_away_claimed_heartbeat_on_a_task_wake_lifts_task_scoping() {
  local repo home out status
  repo="$TMP_ROOT/away-heartbeat-scope-root"
  home="$TMP_ROOT/away-heartbeat-scope-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, settle, home, realRoot, bus, makeOffer, approvedProject, defaultSessionCtx }; })()`);
const { fire, settle, home, realRoot, bus, makeOffer, approvedProject, defaultSessionCtx } = globalThis.__t;
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const contract = (args) => {
  const result = spawnSync("bash", [`${realRoot}/bin/fm-afk-contract.sh`, ...args], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state` },
  });
  if (result.status !== 0) throw new Error(`fm-afk-contract.sh ${args.join(" ")} failed: ${result.stderr}`);
  return result.stdout || "";
};

await fire("session_start", {}, defaultSessionCtx);
contract(["enter"]);
writeFileSync(
  `${home}/state/.wake-queue`,
  "1\t1\tsignal\tbranch-driver.status\tsignal: branch-driver.status\n2\t2\theartbeat\theartbeat\theartbeat\n",
);
let finishPrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishPrompt = resolve; });
const offer = makeOffer("signal: branch-driver.status", [approvedProject], false, true);
bus.emit("fm-branch-supervision:dispatch", offer);
if (!offer.accepted) throw new Error("the mixed away wake was refused");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "mixed away branch prompt");
const snapshot = readFileSync(`${home}/state/.branch-eligible-rows`, "utf8").trim().split("\n").join(",");
if (snapshot !== "1,2") throw new Error(`the mixed away wake claimed rows ${snapshot}, not signal+heartbeat`);
const session = globalThis.__fmSessions[0];
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
const fleet = await report.execute("fleet", { task: "fleet", verdict: "routine", summary: "fleet heartbeat under a task wake" }, undefined, undefined, {});
if (fleet.isError) throw new Error(`a claimed heartbeat on a task wake still scoped the report: ${JSON.stringify(fleet)}`);
finishPrompt();
await offer.settlement;
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a claimed heartbeat on a non-heartbeat wake must lift task scoping: $out"
  pass "a claimed heartbeat row on a non-heartbeat away wake lifts task scoping for the fleet report"
}

test_branch_predrain_recheck_keeps_a_heartbeat_a_co_present_check_arrives_under() {
  local repo home out status
  repo="$TMP_ROOT/predrain-recheck-root"
  home="$TMP_ROOT/predrain-recheck-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, mainUserMessages }; })()`);
const { dispatch, fire, home, mainUserMessages } = globalThis.__t;
import { appendFileSync, readFileSync } from "node:fs";

await fire("session_start", {});
let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
const offer = dispatch("heartbeat", [], true, true);
if (!offer.accepted) throw new Error("eligible heartbeat offer was not accepted");
// A main-only notice arrives between offer acceptance and the branch's own
// drain. It must not carry the fleet review into the captain's chat.
appendFileSync(`${home}/state/.wake-queue`, "2\t2\tcheck\tx-inbox\tcheck: pending x mention\n");
for (let i = 0; i < 250 && !globalThis.__fmPromptStarted && mainUserMessages.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (mainUserMessages.length !== 0) {
  throw new Error(`a co-present check row rode the heartbeat into main: ${JSON.stringify(mainUserMessages)}`);
}
if (!globalThis.__fmPromptStarted) {
  throw new Error("the branch was never prompted even though the heartbeat stayed eligible");
}
const snapshot = readFileSync(`${home}/state/.branch-eligible-rows`, "utf8").trim().split("\n");
if (!snapshot.includes("1")) throw new Error(`eligible-row snapshot omitted the heartbeat row: ${snapshot}`);
if (snapshot.includes("2")) throw new Error(`eligible-row snapshot granted the main-owned row: ${snapshot}`);
releasePrompt();
const queue = readFileSync(`${home}/state/.wake-queue`, "utf8");
if (!queue.includes("\theartbeat\t") || !queue.includes("\tcheck\t")) {
  throw new Error(`the pre-drain recheck mutated the queued set: ${queue}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a co-present check row must not carry a heartbeat review into main: $out"
  pass "a heartbeat review survives a check row arriving before its drain"
}

# The report tool refuses a task the wake being handled never named: the
# refused-ack loop's ghost reports were typed from memory about a task whose
# records teardown had already removed, while the prompt was a stale row for
# another pane. A signal or stale wake may report only the tasks its rows
# resolve to, with fleet refused too; a heartbeat review is unscoped and
# refuses nothing by task id. The wake's own task still goes through, and
# nothing refused ever reaches the durable store.
test_branch_report_refuses_a_task_the_wake_did_not_name() {
  local repo home out status
  repo="$TMP_ROOT/ghost-report-root"
  home="$TMP_ROOT/ghost-report-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, settle, approvedProject, defaultSessionCtx }; })()`);
const { dispatch, fire, home, settle, approvedProject, defaultSessionCtx } = globalThis.__t;
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";

// A second live task the wake does not name, plus the memory of a task whose
// records are already gone.
writeFileSync(`${home}/state/other-task.meta`, `project=${approvedProject}\nwindow=default:wX:p1\n`);
await fire("session_start", {}, defaultSessionCtx);

let finish;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finish = resolve; });
if (!dispatch("signal: task-local wake").accepted) throw new Error("branch refused the task-local wake");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "task-local branch prompt");
const session = globalThis.__fmSessions[globalThis.__fmSessions.length - 1];
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
const ghost = await report.execute("ghost", { task: "other-task", verdict: "captain", summary: "PR ready to merge" }, undefined, undefined, {});
if (!ghost.isError || !ghost.content[0].text.includes("names branch-driver, not other-task")) {
  throw new Error(`a report for a live task the wake never named was not refused: ${JSON.stringify(ghost)}`);
}
const gone = await report.execute("gone", { task: "retired-task", verdict: "captain", summary: "PR ready to merge" }, undefined, undefined, {});
if (!gone.isError) throw new Error(`a report for a task with no record was not refused: ${JSON.stringify(gone)}`);
const fleet = await report.execute("fleet", { task: "fleet", verdict: "routine", summary: "fleet-wide note" }, undefined, undefined, {});
if (!fleet.isError || !fleet.content[0].text.includes("never fleet")) {
  throw new Error(`a fleet-wide report was not refused during a task-local wake: ${JSON.stringify(fleet)}`);
}
const named = await report.execute("named", { task: "branch-driver", verdict: "routine", summary: "worker healthy" }, undefined, undefined, {});
if (named.isError) throw new Error(`the wake's own task was refused: ${JSON.stringify(named)}`);
finish();
await settle(() => !existsSync(`${home}/state/.branch-eligible-rows`), "task-local grant release");

// A heartbeat review is not scoped by task: it may report any task id, a
// task whose records are already gone, and fleet.
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finish = resolve; });
if (!dispatch("heartbeat", [], true, true).accepted) throw new Error("branch refused the heartbeat");
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "heartbeat branch prompt");
const heartbeatSession = globalThis.__fmSessions[globalThis.__fmSessions.length - 1];
const heartbeatReport = heartbeatSession.options.customTools.find((tool) => tool.name === "fm_branch_report");
const live = await heartbeatReport.execute("live", { task: "other-task", verdict: "routine", summary: "worker healthy" }, undefined, undefined, {});
if (live.isError) throw new Error(`a heartbeat report for a live task was refused: ${JSON.stringify(live)}`);
const goneInReview = await heartbeatReport.execute("gone-in-review", { task: "retired-task", verdict: "captain", summary: "PR merged and cleaned up" }, undefined, undefined, {});
if (goneInReview.isError) throw new Error(`a heartbeat report for a task with no record was refused: ${JSON.stringify(goneInReview)}`);
const fleetInReview = await heartbeatReport.execute("fleet-in-review", { task: "fleet", verdict: "routine", summary: "fleet-wide note" }, undefined, undefined, {});
if (fleetInReview.isError) throw new Error(`a fleet-wide report was refused during a heartbeat review: ${JSON.stringify(fleetInReview)}`);
finish();

const stored = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line).task);
if (JSON.stringify(stored) !== JSON.stringify(["branch-driver", "other-task", "retired-task", "fleet"])) {
  throw new Error(`refused reports reached the durable store: ${JSON.stringify(stored)}`);
}

// The classification owner names the tasks behind each eligible row: a
// signal row by its status-log key, a stale row by the endpoint a task's
// metadata records.
const lib = await import(pathToFileURL(`${dirname(process.env.PLUGIN)}/lib/fm-branch-dispatch.ts`).href);
writeFileSync(`${home}/state/.wake-queue`, [
  "1\t1\tsignal\tbranch-driver.status\tsignal: done",
  "2\t2\tstale\tdefault:wX:p1\tstale: default:wX:p1 (idle 378s)",
  "3\t3\tcheck\tmerge-poll\tcheck: merged",
].join("\n") + "\n");
const scope = lib.scopeForUnreadWake(`${home}/state`, false);
if (JSON.stringify([...scope.eligibleTasks].sort()) !== JSON.stringify(["branch-driver", "other-task"])) {
  throw new Error(`eligible rows resolved to the wrong tasks: ${JSON.stringify(scope)}`);
}
if (JSON.stringify(scope.eligibleSeqs) !== JSON.stringify(["1", "2"])) {
  throw new Error(`the main-owned check row leaked into the branch claim: ${JSON.stringify(scope)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the report tool must refuse tasks the wake never named: $out"
  pass "fm_branch_report refuses a task the wake did not name, fleet included, while a heartbeat is unscoped"
}

# The non-heartbeat half of the same recheck: a check-kind row that arrives
# after a signal/stale offer is accepted must stay main-owned WITHOUT bouncing
# the branch's own eligible row back to main
# (docs/watcher-continuity.md "Per-actor acknowledgement"). A check row is
# main-owned in every mode, so the heartbeat case proven above and this one
# resolve the same way.
test_branch_predrain_recheck_excludes_new_main_owned_row_without_deferring_eligible_work() {
  local repo home out status
  repo="$TMP_ROOT/predrain-partial-root"
  home="$TMP_ROOT/predrain-partial-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, mainUserMessages }; })()`);
const { dispatch, fire, home, mainUserMessages } = globalThis.__t;
import { appendFileSync, existsSync, readFileSync } from "node:fs";

await fire("session_start", {});
let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
const offer = dispatch("signal: task-local wake");
if (!offer.accepted) throw new Error("eligible task-local offer was not accepted");
// A main-only notice arrives while main is still finishing its own earlier
// turn - unacked, still sitting in the queue - between offer acceptance and
// the branch's own drain.
appendFileSync(`${home}/state/.wake-queue`, "2\t2\tcheck\tx-inbox\tcheck: pending x mention\n");
for (let i = 0; i < 250 && !globalThis.__fmPromptStarted && mainUserMessages.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (mainUserMessages.length !== 0) {
  throw new Error(`a co-present main-owned row bounced the whole mixed queue to main: ${JSON.stringify(mainUserMessages)}`);
}
if (!globalThis.__fmPromptStarted) {
  throw new Error("the branch was never prompted even though its own row stayed eligible");
}
const snapshot = readFileSync(`${home}/state/.branch-eligible-rows`, "utf8").trim().split("\n");
if (!snapshot.includes("1")) throw new Error(`eligible-row snapshot omitted the task-local row: ${snapshot}`);
if (snapshot.includes("2")) throw new Error(`eligible-row snapshot granted the main-owned row: ${snapshot}`);
const queue = readFileSync(`${home}/state/.wake-queue`, "utf8");
if (!queue.includes("\tcheck\tx-inbox\t")) {
  throw new Error(`the main-owned row must remain queued for main, untouched: ${queue}`);
}
releasePrompt();
for (let i = 0; i < 250 && (globalThis.__fmPrompts ?? []).length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 250 && existsSync(`${home}/state/.branch-eligible-rows`); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("settled branch prompt retained its row grant");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "pre-drain eligibility re-check must exclude only the new main-owned row: $out"
  pass "pre-drain eligibility re-check excludes a newly main-owned row without deferring eligible work"
}

# A needs-decision signal wakes main independently, but it must not veto an
# already accepted routine delivery at the branch's pre-drain recheck. The
# grant serializes the actors: branch owns only the routine row, while the
# decision row remains main-owned. If the prompted branch then fails, rejecting
# the settlement releases the grant so watcher fallback can replay both rows.
test_branch_predrain_needs_decision_keeps_routine_row_branch_eligible() {
  local repo home out status
  repo="$TMP_ROOT/predrain-needs-decision-root"
  home="$TMP_ROOT/predrain-needs-decision-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { bus, fire, home, makeOffer, realRoot }; })()`);
const { bus, fire, home, makeOffer, realRoot } = globalThis.__t;
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

fire("session_start", {});
writeFileSync(
  `${home}/state/.wake-queue`,
  "1\t1\tsignal\tbranch-driver.status\tsignal: routine progress\n" +
    "2\t2\tsignal\tdecision-task.status\tneeds-decision: decision-task.status\n",
);
let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
const offer = makeOffer("signal: branch-driver.status");
bus.emit("fm-branch-supervision:dispatch", offer);
if (!offer.accepted) throw new Error("branch refused the routine offer before its mixed-queue recheck");
for (let i = 0; i < 250 && !globalThis.__fmPromptStarted; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!globalThis.__fmPromptStarted) {
  throw new Error("a co-present needs-decision row vetoed the accepted routine branch prompt");
}
const snapshot = readFileSync(`${home}/state/.branch-eligible-rows`, "utf8").trim().split("\n");
if (!snapshot.includes("1") || snapshot.includes("2")) {
  throw new Error(`mixed queue granted the wrong rows to branch: ${snapshot}`);
}
releasePrompt();
const failure = await offer.settlement.then(() => null, (error) => error);
if (!(failure instanceof Error) || !failure.message.includes("produced no durable outcome")) {
  throw new Error(`accepted wake settled without delivery instead of rejecting to fallback: ${String(failure)}`);
}
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("failed branch prompt retained its routine-row grant");
}
const drain = spawnSync("bash", [`${realRoot}/bin/fm-wake-drain.sh`], {
  encoding: "utf8",
  env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state`, FM_ROOT_OVERRIDE: realRoot },
});
if (drain.status !== 0) throw new Error(`main fallback drain failed: ${drain.stderr}`);
if (!drain.stdout.includes("\t1\tsignal\tbranch-driver.status\t") ||
    !drain.stdout.includes("\t2\tsignal\tdecision-task.status\t")) {
  throw new Error(`fallback did not receive the released mixed queue: ${drain.stdout}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a mixed needs-decision recheck must keep routine branch delivery live: $out"
  pass "a co-present needs-decision row neither vetoes nor falsely settles routine branch delivery"
}

test_settled_branch_prompt_releases_unacknowledged_grant() {
  local repo home out status
  repo="$TMP_ROOT/settled-grant-root"
  home="$TMP_ROOT/settled-grant-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, realRoot, mainUserMessages }; })()`);
const { dispatch, fire, home, realRoot, mainUserMessages } = globalThis.__t;
const { spawnSync } = await import("node:child_process");
const { existsSync } = await import("node:fs");

await fire("session_start", {});
const offer = dispatch("signal: unacknowledged branch wake");
if (!offer.accepted) throw new Error("eligible wake was not accepted");
for (let i = 0; i < 250 && (globalThis.__fmPrompts ?? []).length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if ((globalThis.__fmPrompts ?? []).length !== 1) throw new Error("branch prompt did not settle");
const failure = await offer.settlement.then(
  () => null,
  (error) => error,
);
if (!(failure instanceof Error) || !failure.message.includes("produced no durable outcome")) {
  throw new Error(`settled prompt did not reject delivery ownership: ${String(failure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
for (let i = 0; i < 250 && existsSync(`${home}/state/.branch-eligible-rows`); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("settled prompt left its unacknowledged grant active");
}
const drain = spawnSync("bash", [`${realRoot}/bin/fm-wake-drain.sh`], {
  encoding: "utf8",
  env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state`, FM_ROOT_OVERRIDE: realRoot },
});
if (drain.status !== 0) throw new Error(`main drain failed after grant release: ${drain.stderr}`);
if (!drain.stdout.includes("\tsignal\tbranch-driver.status\t")) {
  throw new Error(`main could not replay the unacknowledged branch row: ${drain.stdout}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "settled branch turns must release residual grants for main replay: $out"
  pass "a settled branch turn without a durable outcome falls back and releases its grant for main replay"
}

test_post_construction_provider_error_falls_back_latches_and_recovers_on_cooldown() {
  local repo home out status
  repo="$TMP_ROOT/provider-error-root"
  home="$TMP_ROOT/provider-error-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { pi, makeOffer, dispatch, fire, settle, home, mainUserMessages, sentToMain }; })()`);
const { pi, makeOffer, dispatch, fire, settle, home, mainUserMessages, sentToMain } = globalThis.__t;
import { existsSync } from "node:fs";

let now = 1_000_000;
Date.now = () => now;
const entries = [];
await fire("session_start", {}, {
  sessionManager: {
    getSessionFile: () => `${home}/main.jsonl`,
    getEntries: () => entries,
  },
});
globalThis.__fmInitialBranchMessages = Array.from({ length: 100 }, (_, index) => ({
  role: index % 2 === 0 ? "user" : "assistant",
  content: `old context ${index}`,
  ...(index % 2 === 0 ? {} : { stopReason: "stop" }),
}));
let attempt = 0;
let releaseFailedProbe;
globalThis.__fmOnBranchPrompt = async ({ session }) => {
  attempt += 1;
  if (attempt === 1) {
    session.messages = [
      { role: "assistant", content: "compaction summary", stopReason: "stop" },
      ...Array.from({ length: 10 }, (_, index) => ({ role: "user", content: `retained ${index}` })),
    ];
  }
  if (attempt === 2 || attempt === 6 || attempt === 8) {
    const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
    const summary = attempt === 2
      ? "healthy branch turn reset the provider-error streak"
      : attempt === 6
        ? "cooldown probe recovered the branch"
        : "post-recovery report proved the provider-error streak was clear";
    const recorded = await report.execute(
      `healthy-${attempt}`,
      { task: "branch-driver", verdict: "routine", summary },
      undefined,
      undefined,
      {},
    );
    if (recorded.isError) throw new Error(`healthy report failed: ${JSON.stringify(recorded)}`);
    session.messages.push({ role: "assistant", content: [], stopReason: "stop" });
    return;
  }
  if (attempt === 5) {
    const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
    const recorded = await report.execute(
      "reported-before-provider-error",
      { task: "branch-driver", verdict: "routine", summary: "durable report preceded a failed continuation" },
      undefined,
      undefined,
      {},
    );
    if (recorded.isError) throw new Error(`pre-error report failed: ${JSON.stringify(recorded)}`);
    await new Promise((resolve) => { releaseFailedProbe = resolve; });
  }
  session.messages.push({
    role: "assistant",
    content: [],
    stopReason: "error",
    errorMessage: "429: Monthly usage limit reached",
  });
};

const first = dispatch("signal: c1 provider error");
if (!first.accepted) throw new Error("first provider-error wake was not accepted after branch construction");
const firstFailure = await first.settlement.then(() => null, (error) => error);
if (!(firstFailure instanceof Error) ||
    !firstFailure.message.includes("provider failed after construction") ||
    !firstFailure.message.includes("429: Monthly usage limit reached")) {
  throw new Error(`provider-error settlement lost the settled error turn: ${String(firstFailure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("provider-error fallback left the claimed row grant active");
}

const healthy = dispatch("signal: healthy branch turn");
if (!healthy.accepted) throw new Error("one provider error latched the branch prematurely");
await healthy.settlement;
await settle(() => attempt === 2 && sentToMain.length === 1, "healthy branch report");
if (mainUserMessages.length !== 0) throw new Error("a healthy reported turn fell back to main");

const third = dispatch("signal: provider error after reset");
if (!third.accepted) throw new Error("a successful report did not reset the consecutive provider-error streak");
const thirdFailure = await third.settlement.then(() => null, (error) => error);
if (!(thirdFailure instanceof Error) || !thirdFailure.message.includes("provider failed after construction")) {
  throw new Error(`provider error after reset did not reject settlement: ${String(thirdFailure)}`);
}
const fourth = dispatch("signal: consecutive provider error");
if (!fourth.accepted) throw new Error("the branch latched before the second consecutive provider error settled");
const fourthFailure = await fourth.settlement.then(() => null, (error) => error);
if (!(fourthFailure instanceof Error) || !fourthFailure.message.includes("provider failed after construction")) {
  throw new Error(`consecutive provider error did not reject settlement: ${String(fourthFailure)}`);
}

const fifth = dispatch("signal: branch must now defer directly to main");
if (fifth.accepted) throw new Error("two consecutive provider errors did not latch the broken branch");
await new Promise((resolve) => setTimeout(resolve, 50));
if (attempt !== 4 || mainUserMessages.length !== 0) {
  throw new Error(`latched branch still prompted or emitted its own fallback: attempts=${attempt} fallbacks=${mainUserMessages.length}`);
}
const pauseNotes = sentToMain.filter((sent) => sent.message.content.includes("Supervision branch paused after repeated provider errors"));
if (pauseNotes.length !== 1 || pauseNotes[0].message.content.includes("\n")) {
  throw new Error(`the first latch must surface exactly one one-line note: ${JSON.stringify(pauseNotes)}`);
}

// No provider attempt occurs inside the first five-minute cooldown. Exactly
// one probe is accepted when it elapses, and all other wakes remain on main
// even while that probe is still in flight.
now += (5 * 60 * 1000) - 1;
if (dispatch("signal: still inside first cooldown").accepted) {
  throw new Error("the latched branch re-probed before its first cooldown elapsed");
}
now += 1;
const failedProbe = dispatch("signal: first cooldown probe");
if (!failedProbe.accepted) throw new Error("the branch did not accept one probe after its cooldown elapsed");
await settle(() => attempt === 5 && typeof releaseFailedProbe === "function", "in-flight failed cooldown probe");
if (sentToMain.some((sent) => sent.message.content.includes("Supervision branch recovered after a successful cooldown probe"))) {
  throw new Error("a durable report cleared the latch before its prompt settled");
}
const duringProbe = makeOffer("signal: main owns wakes during a branch probe");
pi.events.emit("fm-branch-supervision:dispatch", duringProbe);
if (duringProbe.accepted) throw new Error("a second wake entered the branch while its one cooldown probe was in flight");
releaseFailedProbe();
const failedProbeError = await failedProbe.settlement.then(() => null, (error) => error);
if (!(failedProbeError instanceof Error) || !failedProbeError.message.includes("provider failed after construction")) {
  throw new Error(`failed cooldown probe did not reject settlement: ${String(failedProbeError)}`);
}
if (mainUserMessages.length !== 0) throw new Error("failed cooldown probe bypassed watcher-owned fallback delivery");
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("failed cooldown probe left the claimed row grant active");
}

// The failed probe doubles the cooldown from five to ten minutes. Five more
// minutes are not enough, but the next five admit exactly one recovery probe.
now += 5 * 60 * 1000;
if (dispatch("signal: inside extended cooldown").accepted) {
  throw new Error("a failed probe did not extend the next cooldown beyond five minutes");
}
now += 5 * 60 * 1000;
const recoveryProbe = dispatch("signal: recovery probe after extended cooldown");
if (!recoveryProbe.accepted) throw new Error("the branch did not re-probe after the extended cooldown elapsed");
await settle(() => attempt === 6 && sentToMain.some((sent) => sent.message.content.includes("cooldown probe recovered the branch")), "successful recovery probe");
// The recovery note is emitted when the wake SETTLES, which is after the
// report note the condition above waits for.
await recoveryProbe.settlement;
if (mainUserMessages.length !== 0) throw new Error("a successful recovery probe also fell back to main");
const recoveryNotes = sentToMain.filter((sent) => sent.message.content.includes("Supervision branch recovered after a successful cooldown probe"));
if (recoveryNotes.length !== 1 || recoveryNotes[0].message.content.includes("\n")) {
  throw new Error(`recovery must surface exactly one one-line note: ${JSON.stringify(recoveryNotes)}`);
}

// The durable report cleared both the latch and the old streak: one new
// provider error falls back but does not latch, so a following wake still
// reaches the branch and can report successfully.
const afterRecoveryError = dispatch("signal: first provider error after recovery");
if (!afterRecoveryError.accepted) throw new Error("the successful probe did not clear the branch latch");
const afterRecoveryFailure = await afterRecoveryError.settlement.then(() => null, (error) => error);
if (!(afterRecoveryFailure instanceof Error) || !afterRecoveryFailure.message.includes("provider failed after construction")) {
  throw new Error(`first post-recovery provider error did not reject settlement: ${String(afterRecoveryFailure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("post-recovery provider error bypassed watcher-owned fallback delivery");
if (existsSync(`${home}/state/.branch-eligible-rows`)) {
  throw new Error("post-recovery provider error left the claimed row grant active");
}
const afterRecoveryHealthy = dispatch("signal: healthy turn after one post-recovery error");
if (!afterRecoveryHealthy.accepted) throw new Error("the successful probe did not clear the provider-error streak");
await settle(() => attempt === 8 && sentToMain.some((sent) => sent.message.content.includes("post-recovery report proved")), "post-recovery healthy report");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "provider errors must latch, cool down, re-probe once, back off, and recover through a durable report: $out"
  pass "provider-error latches cool down, re-probe once with backoff, and recover through a durable report"
}

test_selection_change_does_not_corrupt_inflight_provider_state() {
  local repo home out status
  repo="$TMP_ROOT/provider-selection-race-root"
  home="$TMP_ROOT/provider-selection-race-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, settle, home, mainUserMessages }; })()`);
const { dispatch, fire, settle, home, mainUserMessages } = globalThis.__t;

const entries = [];
const mainSession = {
  getSessionFile: () => `${home}/main.jsonl`,
  getEntries: () => entries,
};
await fire("session_start", {}, { sessionManager: mainSession });
entries.push({ type: "message", message: { role: "user", content: "context waiting for the branch mirror" } });
await fire("turn_end", {}, { sessionManager: mainSession });

let releaseMirror;
globalThis.__fmMirrorGate = new Promise((resolve) => { releaseMirror = resolve; });
let attempt = 0;
globalThis.__fmOnBranchPrompt = async ({ session }) => {
  attempt += 1;
  if (attempt === 3) {
    const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
    const recorded = await report.execute(
      "healthy-after-selection",
      { task: "branch-driver", verdict: "routine", summary: "replacement branch remains available" },
      undefined,
      undefined,
      {},
    );
    if (recorded.isError) throw new Error(`healthy report failed: ${JSON.stringify(recorded)}`);
    session.messages.push({ role: "assistant", content: [], stopReason: "stop" });
    return;
  }
  session.messages.push({
    role: "assistant",
    content: [],
    stopReason: "error",
    errorMessage: "429: provider unavailable",
  });
};

const stale = dispatch("signal: provider error during model selection");
if (!stale.accepted) throw new Error("in-flight wake was not accepted");
await settle(() => globalThis.__fmMirrorStarted === true, "pending branch mirror");
await fire("model_select", { model: { provider: "anthropic", id: "replacement-model" } });
releaseMirror();
const staleFailure = await stale.settlement.then(() => null, (error) => error);
if (!(staleFailure instanceof Error) ||
    !staleFailure.message.includes("provider failed after construction") ||
    staleFailure.message.includes("no durable transcript")) {
  throw new Error(`selection change detached the in-flight transcript: ${String(staleFailure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");

globalThis.__fmMirrorGate = null;
const replacementError = dispatch("signal: first replacement provider error");
if (!replacementError.accepted) throw new Error("replacement branch was unavailable after selection");
const replacementFailure = await replacementError.settlement.then(() => null, (error) => error);
if (!(replacementFailure instanceof Error) || !replacementFailure.message.includes("provider failed after construction")) {
  throw new Error(`replacement provider error did not reject settlement: ${String(replacementFailure)}`);
}

const healthy = dispatch("signal: replacement branch recovery");
if (!healthy.accepted) throw new Error("stale provider error polluted the replacement failure streak");
await healthy.settlement;
await settle(() => attempt === 3, "replacement branch recovery");
if (mainUserMessages.length !== 0) throw new Error("healthy replacement turn fell back to main");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "selection changes must preserve in-flight transcript and isolate provider streaks: $out"
  pass "selection changes preserve in-flight transcript ownership and reset provider-error streaks"
}

test_main_owned_grant_result_falls_back_to_main() {
  local repo home out status
  repo="$TMP_ROOT/main-owned-fallback-root"
  home="$TMP_ROOT/main-owned-fallback-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, mainUserMessages }; })()`);
const { dispatch, fire, home, mainUserMessages } = globalThis.__t;
import { writeFileSync } from "node:fs";

await fire("session_start", {});
const offer = dispatch("signal: interrupted main claim");
if (!offer.accepted) throw new Error("eligible wake was not accepted before the ownership recheck");
writeFileSync(`${home}/state/.main-eligible-rows`, "1\n");
const failure = await offer.settlement.then(
  () => null,
  (error) => error,
);
if (!(failure instanceof Error) || !failure.message.includes("already claimed by main")) {
  throw new Error(`main-owned claim did not reject branch settlement: ${String(failure)}`);
}
if ((globalThis.__fmPrompts ?? []).length !== 0) {
  throw new Error("branch prompted for a row already claimed by main");
}
if (mainUserMessages.length !== 0) {
  throw new Error(`branch bypassed watcher-owned fallback delivery: ${JSON.stringify(mainUserMessages)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a main-owned grant result must reject to watcher delivery: $out"
  pass "a stale main claim returns the durable wake to watcher delivery"
}

test_branch_predrain_recheck_noops_already_drained_wake() {
  local repo home out status
  repo="$TMP_ROOT/predrain-empty-root"
  home="$TMP_ROOT/predrain-empty-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, home, mainUserMessages }; })()`);
const { dispatch, fire, home, mainUserMessages } = globalThis.__t;
import { writeFileSync } from "node:fs";

await fire("session_start", {});
let releaseFirst;
globalThis.__fmPromptGate = new Promise((resolve) => {
  releaseFirst = resolve;
});
globalThis.__fmOnBranchPrompt = async ({ session }) => {
  const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
  await report.execute(
    "first-drained-elsewhere",
    { task: "branch-driver", verdict: "routine", summary: "the accepted wake was already reconciled" },
    undefined,
    undefined,
    {},
  );
};
if (!dispatch("signal: first queued wake").accepted) throw new Error("first wake was not accepted");
for (let i = 0; i < 250 && !globalThis.__fmPromptStarted; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!globalThis.__fmPromptStarted) throw new Error("first branch prompt did not start");
if (!dispatch("heartbeat", [], true, true).accepted) throw new Error("queued heartbeat was not accepted");
writeFileSync(`${home}/state/.wake-queue`, "");
releaseFirst();
for (let i = 0; i < 250 && (globalThis.__fmPrompts ?? []).length < 1; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await new Promise((resolve) => setTimeout(resolve, 50));
if ((globalThis.__fmPrompts ?? []).length !== 1) {
  throw new Error(`already-drained wake prompted again: ${JSON.stringify(globalThis.__fmPrompts ?? [])}`);
}
if (mainUserMessages.length !== 0) {
  throw new Error(`already-drained wake fell back to main: ${JSON.stringify(mainUserMessages)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an already-drained serialized wake must no-op without main fallback: $out"
  pass "pre-drain eligibility re-check no-ops an already-drained wake"
}

test_branch_mirror_filters_order_and_cursor() {
  local repo home out status
  repo="$TMP_ROOT/mirror-root"
  home="$TMP_ROOT/mirror-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, home }; })()`);
const { fire, dispatch, settle, home } = globalThis.__t;
import { existsSync, readFileSync } from "node:fs";

const entries = [
  { type: "message", message: { role: "user", content: `never merge task-7 without my word ${"h".repeat(5000)} old-history-tail` } },
  { type: "message", message: { role: "assistant", content: [{ type: "text", text: "aye, holding task-7" }, { type: "toolCall", id: "t1" }] } },
  { type: "message", message: { role: "user", content: "⁣FIRSTMATE_OP: v1 watcher: operational injection" } },
  { type: "message", message: { role: "toolResult", content: "tool output stays in main" } },
  { type: "custom", message: { role: "custom", customType: "fm-branch-merge", content: "merged note" } },
  { type: "compaction", summary: "compacted" },
  { type: "message", message: { role: "user", content: `pad ${"x".repeat(5000)}\ntail: retain this request` } },
];
const ctx = {
  sessionManager: {
    getSessionFile: () => `${home}/main-1.jsonl`,
    getEntries: () => entries,
  },
};

// Dialog collected at main's turn_end, delivered into the branch BEFORE the
// next wake, tagged and filtered: no tool traffic, no operational injections,
// no merge notes, long messages capped.
await fire("turn_end", {}, ctx);
dispatch("signal: after mirror");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const session = globalThis.__fmSessions[0];
const kinds = session.ops.map((op) => op.kind);
if (JSON.stringify(kinds) !== JSON.stringify(["custom", "custom", "custom", "prompt"])) {
  throw new Error(`mirror must land before the wake: ${JSON.stringify(kinds)}`);
}
const mirrored = session.ops.filter((op) => op.kind === "custom").map((op) => op.message);
if (mirrored.some((m) => m.customType !== "fm-main-mirror")) throw new Error("mirror used the wrong custom type");
if (mirrored.some((m) => m.display !== false)) throw new Error("mirrored context must be silent");
if (!mirrored[0].content.startsWith("[captain] never merge task-7 without my word") ||
    !mirrored[0].content.includes("[mirror truncated:") ||
    !mirrored[0].content.endsWith("old-history-tail")) {
  throw new Error(`older captain history was not bounded: ${mirrored[0].content}`);
}
if (mirrored[1].content !== "[main] aye, holding task-7") throw new Error(`bad main mirror: ${mirrored[1].content}`);
if (mirrored[2].content !== `[captain] ${entries[6].message.content}`) {
  throw new Error("current captain dialog was not preserved completely");
}
if (mirrored.some((m) => m.content.includes("operational injection") || m.content.includes("tool output") || m.content.includes("merged note"))) {
  throw new Error("mirror leaked operational, tool, or merge-note traffic");
}

// A run that pi.sendCustomMessage starts carries a custom message and no
// prompt, so reading the prompt here threw and every such run surfaced the
// failure instead of starting. It is not captain input either, so nothing of
// it reaches the mirror.
const mirroredBeforeCustomRun = session.ops.filter((op) => op.kind === "custom").length;
await fire("before_agent_start", {
  messageType: "custom",
  message: { role: "custom", customType: "fm-branch-merge", content: "merge note that starts its own run" },
}, ctx);
if (session.ops.filter((op) => op.kind === "custom").length !== mirroredBeforeCustomRun) {
  throw new Error("a custom-message run was mirrored as captain dialog");
}

// The durable cursor advances: a second turn_end mirrors only NEW dialog.
entries.push({ type: "message", message: { role: "user", content: "actually, task-7 may merge when green" } });
await fire("turn_end", {}, ctx);
await settle(() => session.ops.filter((op) => op.kind === "custom").length === 4, "incremental mirror");
const latest = session.ops[session.ops.length - 1];
if (latest.message.content !== "[captain] actually, task-7 may merge when green") {
  throw new Error(`incremental mirror re-sent old dialog or lost the new line: ${latest.message.content}`);
}
if (!existsSync(`${home}/state/.branch-mirror-cursor`)) throw new Error("mirror cursor is not durable");
const cursor = JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8"));
if (cursor.file !== `${home}/main-1.jsonl` || cursor.index !== entries.length) {
  throw new Error(`cursor did not advance with the session file: ${JSON.stringify(cursor)}`);
}

// A replacement main session re-anchors: dialog mirrors from its start.
const ctx2 = {
  sessionManager: {
    getSessionFile: () => `${home}/main-2.jsonl`,
    getEntries: () => [{ type: "message", message: { role: "user", content: "fresh session standing order" } }],
  },
};
await fire("turn_end", {}, ctx2);
await settle(() => session.ops.filter((op) => op.kind === "custom").length === 5, "replacement-session mirror");
const fresh = session.ops[session.ops.length - 1];
if (fresh.message.content !== "[captain] fresh session standing order") {
  throw new Error(`replacement session did not re-anchor the mirror: ${fresh.message.content}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "mirror filtering, ordering, and cursor must hold: $out"
  pass "dialog mirror filters tool and operational traffic, lands before wakes, and keeps a durable cursor"
}

test_branch_mirror_reanchors_for_the_new_session_branch_conversation() {
  local repo home out status
  repo="$TMP_ROOT/mirror-reanchor-root"
  home="$TMP_ROOT/mirror-reanchor-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, home }; })()`);
const { fire, dispatch, settle, makeCtx, home } = globalThis.__t;
import { readFileSync } from "node:fs";

// One main session file throughout: a /resume or reload keeps main's own
// session, which is exactly the case where the durable cursor would otherwise
// hide already-mirrored dialog from the session's new branch conversation.
const entries = [{ type: "message", message: { role: "user", content: "standing order: never merge task-7" } }];
const ctx = makeCtx({
  sessionManager: { getSessionFile: () => `${home}/main-1.jsonl`, getEntries: () => entries },
});
const mirrorsOf = (session) => session.ops.filter((op) => op.kind === "custom").map((op) => op.message.content);

await fire("session_start", {}, ctx);
await fire("turn_end", {}, ctx);
dispatch("signal: first session");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "first branch build");
const first = globalThis.__fmSessions[0];
if (JSON.stringify(mirrorsOf(first)) !== JSON.stringify(["[captain] standing order: never merge task-7"])) {
  throw new Error(`the first branch conversation did not receive the session's dialog: ${JSON.stringify(mirrorsOf(first))}`);
}
const cursor = JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8"));
if (cursor.file !== `${home}/main-1.jsonl` || cursor.index !== entries.length) {
  throw new Error(`the durable cursor did not advance with delivery: ${JSON.stringify(cursor)}`);
}

// The reload starts a new branch conversation, so the mirror re-anchors to the
// current main session's start and that conversation receives the whole
// session's dialog, not only what arrived after the cursor.
entries.push({ type: "message", message: { role: "user", content: "and hold task-9 too" } });
await fire("session_shutdown", {});
await fire("session_start", {}, ctx);
await fire("turn_end", {}, ctx);
dispatch("signal: second session");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "second branch build");
const second = globalThis.__fmSessions[1];
if (second.options.sessionManager.opened) throw new Error("the reload continued the previous branch conversation");
const expected = ["[captain] standing order: never merge task-7", "[captain] and hold task-9 too"];
if (JSON.stringify(mirrorsOf(second)) !== JSON.stringify(expected)) {
  throw new Error(`the new branch conversation lost the session's earlier dialog: ${JSON.stringify(mirrorsOf(second))}`);
}

// Inside that session the cursor keeps working: later dialog mirrors once.
entries.push({ type: "message", message: { role: "user", content: "task-9 may merge when green" } });
await fire("turn_end", {}, ctx);
await settle(() => mirrorsOf(second).length === 3, "incremental mirror after the re-anchor");
if (mirrorsOf(second)[2] !== "[captain] task-9 may merge when green") {
  throw new Error(`the incremental mirror re-sent dialog or lost the new line: ${JSON.stringify(mirrorsOf(second))}`);
}
await settle(
  () => JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8")).index === entries.length,
  "durable cursor after the re-anchor",
);
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a new session's branch conversation must receive that session's dialog from its start: $out"
  pass "the dialog mirror re-anchors for each session's new branch conversation and stays incremental within it"
}

test_branch_session_is_new_at_every_main_session_start() {
  local repo home out status first_pointer
  repo="$TMP_ROOT/fresh-session-root"
  home="$TMP_ROOT/fresh-session-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, home }; })()`);
const { fire, dispatch, settle, makeCtx, home } = globalThis.__t;
import { readFileSync } from "node:fs";

const pointerFile = `${home}/state/.branch-session`;
const readPointer = () => readFileSync(pointerFile, "utf8").trim();

// 1. The first wake of a session opens the branch conversation and records it.
await fire("session_start", {}, makeCtx());
dispatch("signal: first session probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "first branch build");
const first = globalThis.__fmSessions[0].options.sessionManager;
if (first.opened) throw new Error("the first branch build reopened a recorded conversation");
if (readPointer() !== first.getSessionFile()) {
  throw new Error(`the pointer does not name the live branch conversation: ${readPointer()}`);
}

// 2. WITHIN one main session the conversation persists: a model or effort
// change drops the live branch and the next wake continues the same file.
await fire("thinking_level_select", { level: "high", previousLevel: "medium" });
await settle(() => globalThis.__fmSessions[0].disposed, "live branch release inside the session");
dispatch("signal: same session probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "same-session rebuild");
const continued = globalThis.__fmSessions[1].options.sessionManager;
if (!continued.opened || continued.getSessionFile() !== first.getSessionFile()) {
  throw new Error(`a rebuild inside one session must continue that session's conversation: ${continued.getSessionFile()}`);
}

// 3. A main session start - /new here, and identically /resume, /fork, or a
// reload - starts a NEW branch conversation. The recorded pointer is not
// reopened, and it follows the new conversation instead.
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: new session probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "post-session-start branch build");
const replacement = globalThis.__fmSessions[2].options.sessionManager;
if (replacement.opened) throw new Error("a main session start reopened the previous branch conversation");
if (replacement.getSessionFile() === first.getSessionFile()) {
  throw new Error("a main session start reused the previous branch conversation file");
}
if (readPointer() !== replacement.getSessionFile()) {
  throw new Error(`the pointer did not follow the new branch conversation: ${readPointer()}`);
}
console.log(readPointer());
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a main session start must start a new branch conversation: $out"
  first_pointer=$(tail -n 1 "$TMP_ROOT/node-output")
  case "$first_pointer" in
    */fresh-session-home/state/branch-session/*.jsonl) ;;
    *) fail "the branch conversation was not recorded under state/branch-session: $first_pointer" ;;
  esac
  # A restart is a main session start too: the recorded conversation from the
  # previous process is left on disk and never becomes the live one.
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_PRIOR_POINTER="$first_pointer" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, home }; })()`);
const { fire, dispatch, settle, makeCtx, home } = globalThis.__t;
import { existsSync, readFileSync } from "node:fs";

const prior = process.env.FM_TEST_PRIOR_POINTER;
if (!existsSync(prior)) throw new Error("the previous process left no recorded branch conversation to guard against");
if (readFileSync(`${home}/state/.branch-session`, "utf8").trim() !== prior) {
  throw new Error("the restart did not start from the previous process's recorded pointer");
}

await fire("session_start", {}, makeCtx());
dispatch("signal: restart probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "restart branch build");
const restarted = globalThis.__fmSessions[0].options.sessionManager;
if (restarted.opened) throw new Error("the restart reopened the recorded branch conversation");
if (restarted.getSessionFile() === prior) throw new Error("the restart reused the recorded branch conversation file");
if (readFileSync(`${home}/state/.branch-session`, "utf8").trim() !== restarted.getSessionFile()) {
  throw new Error("the restart did not repoint the record at its new branch conversation");
}
if (!existsSync(prior)) throw new Error("the previous conversation file was destroyed instead of left behind");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a restart must start a new branch conversation instead of reopening the recorded one: $out"
  pass "every main session start begins a new branch conversation while one session keeps its own"
}

test_branch_model_pin_applies_and_absent_pin_keeps_the_default() {
  local repo home out status
  repo="$TMP_ROOT/modelpin-root"
  home="$TMP_ROOT/modelpin-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, home } = globalThis.__t;
import { rmSync, writeFileSync } from "node:fs";

registryModels.push({ provider: "anthropic", id: "main-model" }, { provider: "openai", id: "cheap-1" });

// 1. No pin and main's model not known yet: the build falls back to the
// pre-feature path of passing no override rather than refusing to build, so
// a wake is never lost over model choice.
await fire("session_start", {});
dispatch("signal: main model unknown");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "unknown-main-model branch build");
if ("model" in globalThis.__fmSessions[0].options) {
  throw new Error("an unknown main model must fall back to passing no model override");
}

// 2. No pin, main's model known: the branch follows MAIN's own model,
// applied explicitly.
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: unpinned probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "unpinned branch build");
const unpinned = globalThis.__fmSessions[1].options.model;
if (!unpinned || unpinned.provider !== "anthropic" || unpinned.id !== "main-model") {
  throw new Error(`an absent pin must follow main's own model: ${JSON.stringify(unpinned)}`);
}

// 3. Pin present: the very next build carries exactly that model, resolved
// out of Pi's own catalog.
writeFileSync(`${home}/config/supervision-branch-model`, "openai/cheap-1\n");
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: pinned probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "pinned branch build");
const pinned = globalThis.__fmSessions[2].options.model;
if (!pinned || pinned.provider !== "openai" || pinned.id !== "cheap-1") {
  throw new Error(`pinned build did not use the pinned model: ${JSON.stringify(pinned)}`);
}

// 4. The session-replacement path (/new, /resume, /fork, reload all replace
// the session in-process) builds a NEW branch conversation and still applies
// the pin.
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: replacement probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 4, "replacement branch build");
const replaced = globalThis.__fmSessions[3].options.model;
if (!replaced || replaced.provider !== "openai" || replaced.id !== "cheap-1") {
  throw new Error(`the replacement build did not use the pinned model: ${JSON.stringify(replaced)}`);
}
const manager = globalThis.__fmSessions[3].options.sessionManager;
if (manager.opened) throw new Error("a session replacement continued the previous branch conversation");

// 5. Clearing the pin makes the next branch follow main again. Pi's own
// session restore is what would otherwise get this wrong wherever a branch
// conversation IS continued (a model or effort change inside one session),
// because that conversation still records the pinned model, so only an
// explicit override keeps "follow main" honest.
rmSync(`${home}/config/supervision-branch-model`);
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: unpinned again");
await settle(() => (globalThis.__fmSessions ?? []).length === 5, "post-clear branch build");
const cleared = globalThis.__fmSessions[4];
if (cleared.options.model?.id === "cheap-1") {
  throw new Error("clearing the pin left the branch on the previously pinned model");
}
if (cleared.options.model?.provider !== "anthropic" || cleared.options.model?.id !== "main-model") {
  throw new Error(`clearing the pin did not return the branch to main's model: ${JSON.stringify(cleared.options.model)}`);
}
// A native main must use an explicit independent ordinary-Pi branch.
registryModels.push({ provider: "openai-codex", id: "gpt-6-astra" });
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx({ model: { provider: "codex-native", id: "gpt-6-astra" } }));
dispatch("signal: native main ordinary branch");
await settle(() => (globalThis.__fmSessions ?? []).length === 6, "native-main branch build");
const nativeBranch = globalThis.__fmSessions[5].options.model;
if (nativeBranch?.provider !== "openai-codex" || nativeBranch?.id !== "gpt-6-astra") {
  throw new Error(`native main inherited an unsafe branch runtime: ${JSON.stringify(nativeBranch)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the current pin state must decide the model on every branch build: $out"
  pass "the current pin state binds every branch build, and clearing it returns the branch to main's model"
}

test_unpinned_branch_follows_main_model_changes_live() {
  local repo home out status
  repo="$TMP_ROOT/model-live-root"
  home="$TMP_ROOT/model-live-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, home } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

registryModels.push(
  { provider: "anthropic", id: "main-model" },
  { provider: "anthropic", id: "replacement-model" },
  { provider: "openai", id: "cheap-1" },
);
await fire("session_start", {}, makeCtx());
dispatch("signal: before main model change");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "initial unpinned branch build");
const original = globalThis.__fmSessions[0];
if (original.options.model?.id !== "main-model") throw new Error("the unpinned branch did not start on main's model");

await fire("model_select", { model: { provider: "anthropic", id: "replacement-model" } });
await settle(() => original.disposed, "live unpinned branch release");
dispatch("signal: after main model change");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "replacement unpinned branch build");
const following = globalThis.__fmSessions[1];
if (following.options.model?.id !== "replacement-model") {
  throw new Error(`the unpinned branch did not follow main's model change: ${JSON.stringify(following.options.model)}`);
}

writeFileSync(`${home}/config/supervision-branch-model`, "openai/cheap-1\n");
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: establish pinned branch");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "pinned branch build");
const pinned = globalThis.__fmSessions[2];
if (pinned.options.model?.id !== "cheap-1") throw new Error("the pinned branch did not use its pin");
const promptsBefore = pinned.ops.filter((op) => op.kind === "prompt").length;

await fire("model_select", { model: { provider: "anthropic", id: "replacement-model" } });
dispatch("signal: pinned after main model change");
await settle(() => pinned.ops.filter((op) => op.kind === "prompt").length === promptsBefore + 1, "pinned branch wake");
if (pinned.disposed || globalThis.__fmSessions.length !== 3) {
  throw new Error("a main model change replaced the pinned branch");
}
if (readFileSync(`${home}/config/supervision-branch-model`, "utf8") !== "openai/cheap-1\n") {
  throw new Error("a main model change disturbed the supervision pin");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "unpinned branches must follow main model changes while pins remain authoritative: $out"
  pass "unpinned branches follow main model changes live while pinned branches stay fixed"
}

test_supervision_model_command_persists_and_rebinds_the_live_branch() {
  local repo home out status
  repo="$TMP_ROOT/modelcmd-root"
  home="$TMP_ROOT/modelcmd-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, commands, registryModels, uiSelections, uiPrompts, notices, home }; })()`);
const { fire, dispatch, settle, makeCtx, commands, registryModels, uiSelections, uiPrompts, notices, home } = globalThis.__t;
import { existsSync, readFileSync, statSync } from "node:fs";

registryModels.push(
  { provider: "anthropic", id: "main-model" },
  { provider: "openai-codex", id: "cheap-oauth", authKind: "oauth" },
  { provider: "dynamic", id: "extension-only", branchAvailable: false },
);
const command = commands.get("supervision-model");
if (!command) throw new Error("the supervision-model command was not registered");

await fire("session_start", {}, makeCtx());
dispatch("signal: before the pick");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "pre-pick branch build");
const firstSession = globalThis.__fmSessions[0];
if (firstSession.options.model?.id !== "main-model") {
  throw new Error(`the branch started on something other than main's model before any pick: ${JSON.stringify(firstSession.options.model)}`);
}

// The picker offers Pi's branch-runnable catalog plus following main, and the
// captain's pick is persisted as the one-line config value.
uiSelections.push("openai-codex/cheap-oauth");
await command.handler("", makeCtx());
const offered = uiPrompts[0];
if (offered.options[0] !== "Follow main (anthropic/main-model)") {
  throw new Error(`the picker must offer following main first: ${JSON.stringify(offered.options)}`);
}
if (!offered.options.includes("openai-codex/cheap-oauth") || !offered.options.includes("anthropic/main-model")) {
  throw new Error(`the picker omitted a model available to the isolated branch: ${JSON.stringify(offered.options)}`);
}
if (offered.options.includes("dynamic/extension-only")) {
  throw new Error(`the picker offered a main-session-only provider: ${JSON.stringify(offered.options)}`);
}
const pinFile = `${home}/config/supervision-branch-model`;
if (readFileSync(pinFile, "utf8") !== "openai-codex/cheap-oauth\n") {
  throw new Error(`unexpected persisted pin: ${JSON.stringify(readFileSync(pinFile, "utf8"))}`);
}
if ((statSync(pinFile).mode & 0o777) !== 0o600) throw new Error("the pin must be written private to the operator");
if (!notices.some((notice) => notice.message.includes("openai-codex/cheap-oauth"))) {
  throw new Error(`the captain was not told which model the branch now uses: ${JSON.stringify(notices)}`);
}

// The live branch is released, so the pick binds on the next wake instead of
// waiting for a session replacement - and the same persistent conversation
// comes back under the new model.
await settle(() => firstSession.disposed, "live branch release after the pick");
dispatch("signal: after the pick");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "post-pick branch build");
const repinned = globalThis.__fmSessions[1];
if (!repinned.options.model || repinned.options.model.id !== "cheap-oauth") {
  throw new Error(`the pick did not bind the next branch build: ${JSON.stringify(repinned.options.model)}`);
}
if (repinned.options.model.authKind !== "oauth") {
  throw new Error(`the branch runtime changed the stored OAuth credential semantics: ${JSON.stringify(repinned.options.model)}`);
}
if (!repinned.options.sessionManager.opened) throw new Error("the pick must keep the branch conversation, not start a new one");

// Following main again clears the file and actually returns the branch to
// main's model, rather than letting the reopened session restore the pin.
const clearNoticeCount = notices.length;
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
if (existsSync(pinFile)) throw new Error("following main must remove the pin file");
const clearNotices = notices.slice(clearNoticeCount);
if (clearNotices.length !== 1 || clearNotices[0].type !== "info" || !clearNotices[0].message.includes("anthropic/main-model")) {
  throw new Error(`following main did not report the model actually applied: ${JSON.stringify(clearNotices)}`);
}
await settle(() => repinned.disposed, "live branch release after clearing");
dispatch("signal: after clearing");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "post-clear branch build");
const followed = globalThis.__fmSessions[2].options.model;
if (followed?.id === "cheap-oauth") throw new Error("following main left the branch on the cleared pin's model");
if (followed?.provider !== "anthropic" || followed?.id !== "main-model") {
  throw new Error(`following main did not apply main's own model: ${JSON.stringify(followed)}`);
}

// A pick made while the old-model branch build is in flight invalidates that
// build. The accepted wake continues on a second build under the newest pin.
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
let releaseCreate;
globalThis.__fmCreateGate = new Promise((resolve) => { releaseCreate = resolve; });
const createsBeforeRace = globalThis.__fmCreateStarted;
dispatch("signal: model race");
await settle(() => globalThis.__fmCreateStarted === createsBeforeRace + 1, "in-flight old-model build");
uiSelections.push("openai-codex/cheap-oauth");
await command.handler("", makeCtx());
releaseCreate();
await settle(() => (globalThis.__fmSessions ?? []).length === 5, "replacement build after in-flight pick");
const staleBuild = globalThis.__fmSessions[3];
const winningBuild = globalThis.__fmSessions[4];
if (!staleBuild.disposed || staleBuild.options.model?.id === "cheap-oauth") {
  throw new Error("the in-flight old-model build was adopted after the pick");
}
if (winningBuild.options.model?.id !== "cheap-oauth") {
  throw new Error(`the newest pin did not win the in-flight build race: ${JSON.stringify(winningBuild.options.model)}`);
}
await settle(() => (globalThis.__fmPrompts ?? []).some((prompt) => prompt.includes("signal: model race")), "raced wake prompt");

// A cancelled picker changes nothing.
uiSelections.push(undefined);
await command.handler("", makeCtx());
if (readFileSync(pinFile, "utf8") !== "openai-codex/cheap-oauth\n") throw new Error("a cancelled picker must not change the pin");

// If the isolated runtime cannot load, the old pin remains and no success
// notification is emitted.
const noticeCount = notices.length;
globalThis.__fmModelRuntimeError = "synthetic stored-credential load failure";
await command.handler("", makeCtx());
delete globalThis.__fmModelRuntimeError;
if (readFileSync(pinFile, "utf8") !== "openai-codex/cheap-oauth\n") throw new Error("an unapplied model replaced the working pin");
const newNotices = notices.slice(noticeCount);
if (newNotices.length !== 1 || newNotices[0].type !== "error") {
  throw new Error(`an unapplied model emitted a success notification: ${JSON.stringify(newNotices)}`);
}

// If the picker loads but resolving main after Follow main fails, the pin is
// cleared and the captain receives an honest warning rather than a rejection
// or a false success notice.
const clearFailureNoticeCount = notices.length;
globalThis.__fmModelRuntimeErrors = [null, "synthetic post-clear runtime failure"];
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
if (existsSync(pinFile)) throw new Error("following main did not clear the pin before its resolution warning");
const clearFailureNotices = notices.slice(clearFailureNoticeCount);
if (
  clearFailureNotices.length !== 1 ||
  clearFailureNotices[0].type !== "warning" ||
  !clearFailureNotices[0].message.includes("synthetic post-clear runtime failure")
) {
  throw new Error(`post-clear resolution failure was not reported honestly: ${JSON.stringify(clearFailureNotices)}`);
}

// Under a codex-native main, Follow main reports the ordinary openai-codex
// model the next build actually runs, and the picker never offers the main
// native provider itself.
registryModels.push({ provider: "codex-native", id: "gpt-6-astra" }, { provider: "openai-codex", id: "gpt-6-astra" });
const nativeCtx = makeCtx({ model: { provider: "codex-native", id: "gpt-6-astra" } });
const nativePromptCount = uiPrompts.length;
const nativeNoticeCount = notices.length;
uiSelections.push("Follow main (codex-native/gpt-6-astra)");
await command.handler("", nativeCtx);
const nativeOffer = uiPrompts[nativePromptCount];
if (nativeOffer.options[0] !== "Follow main (codex-native/gpt-6-astra)" || nativeOffer.options.includes("codex-native/gpt-6-astra")) {
  throw new Error(`the picker must offer following a native main without offering its native provider: ${JSON.stringify(nativeOffer.options)}`);
}
const nativeNotices = notices.slice(nativeNoticeCount);
if (nativeNotices.length !== 1 || nativeNotices[0].type !== "info" || !nativeNotices[0].message.includes("openai-codex/gpt-6-astra")) {
  throw new Error(`following a native main did not report the ordinary Pi model the build uses: ${JSON.stringify(nativeNotices)}`);
}
dispatch("signal: native follow");
await settle(() => (globalThis.__fmSessions ?? []).length === 6, "native-main follow build");
const nativeFollowed = globalThis.__fmSessions[5].options.model;
if (nativeFollowed?.provider !== "openai-codex" || nativeFollowed?.id !== "gpt-6-astra") {
  throw new Error(`the build did not run the model the picker reported: ${JSON.stringify(nativeFollowed)}`);
}

// When that ordinary model is unavailable, the picker reports the refusal the
// next build enforces instead of claiming the branch keeps a recorded model.
registryModels.splice(registryModels.findIndex((model) => model.provider === "openai-codex" && model.id === "gpt-6-astra"), 1);
const refusalNoticeCount = notices.length;
uiSelections.push("Follow main (codex-native/gpt-6-astra)");
await command.handler("", nativeCtx);
const refusalNotices = notices.slice(refusalNoticeCount);
if (
  refusalNotices.length !== 1 ||
  refusalNotices[0].type !== "warning" ||
  !refusalNotices[0].message.includes("refuses to build") ||
  refusalNotices[0].message.includes("keeps the model its own session recorded")
) {
  throw new Error(`following an unavailable native main did not report the build refusal: ${JSON.stringify(refusalNotices)}`);
}
const refusedOffer = dispatch("signal: native follow refused");
const refusal = await refusedOffer.settlement.then(() => null, (error) => error);
if (!(refusal instanceof Error) || !refusal.message.includes("refuses to build")) {
  throw new Error(`the build did not refuse as the picker reported: ${String(refusal)}`);
}
if (globalThis.__fmSessions.length !== 6) throw new Error("a refused native follow still built a branch");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the supervision-model command must persist the pick and rebind the live branch: $out"
  pass "supervision-model command persists the captain's pick and rebinds the live branch"
}

test_branch_effort_pin_applies_and_absent_pin_follows_main() {
  local repo home out status
  repo="$TMP_ROOT/effortpin-root"
  home="$TMP_ROOT/effortpin-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, setMainThinkingLevel, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, setMainThinkingLevel, home } = globalThis.__t;
import { rmSync, writeFileSync } from "node:fs";

// main-model reasons up to Pi's "high"; deep-1 also maps xhigh and max.
registryModels.push(
  { provider: "anthropic", id: "main-model", reasoning: true },
  { provider: "openai", id: "deep-1", reasoning: true, thinkingLevelMap: { xhigh: "xhigh", max: "max" } },
);
const effortPin = `${home}/config/supervision-branch-effort`;
const modelPin = `${home}/config/supervision-branch-model`;
async function rebuild(reason, expected) {
  await fire("session_shutdown", {});
  await fire("session_start", {}, makeCtx());
  dispatch(`signal: ${reason}`);
  return settle(() => (globalThis.__fmSessions ?? []).length === expected, `${reason} branch build`);
}

// 1. No effort pin: the branch applies MAIN's own current effort explicitly,
// so a reopened conversation cannot restore the level it last ran under.
await fire("session_start", {}, makeCtx());
dispatch("signal: unpinned effort");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "unpinned-effort branch build");
if (globalThis.__fmSessions[0].options.thinkingLevel !== "medium") {
  throw new Error(`an absent effort pin must follow main's own effort: ${globalThis.__fmSessions[0].options.thinkingLevel}`);
}

// 2. An effort-only pin binds the next build and leaves the model following
// main, so the two pins are independently expressible.
writeFileSync(effortPin, "low\n");
await rebuild("effort-only pin", 2);
const effortOnly = globalThis.__fmSessions[1].options;
if (effortOnly.thinkingLevel !== "low") {
  throw new Error(`the effort pin did not bind the build: ${effortOnly.thinkingLevel}`);
}
if (effortOnly.model?.id !== "main-model") {
  throw new Error(`an effort-only pin must leave the model following main: ${JSON.stringify(effortOnly.model)}`);
}

// 3. A session replacement applies the effort pin too, on the new branch
// conversation it starts.
await rebuild("effort pin replacement", 3);
if (globalThis.__fmSessions[2].options.thinkingLevel !== "low") {
  throw new Error(`the replacement build dropped the effort pin: ${globalThis.__fmSessions[2].options.thinkingLevel}`);
}
if (globalThis.__fmSessions[2].options.sessionManager.opened) {
  throw new Error("a session replacement continued the previous branch conversation");
}

// 4. A model-only pin leaves the effort following main, the mirror image of
// case 2.
rmSync(effortPin);
writeFileSync(modelPin, "openai/deep-1\n");
setMainThinkingLevel("high");
await rebuild("model-only pin", 4);
const modelOnly = globalThis.__fmSessions[3].options;
if (modelOnly.model?.id !== "deep-1") throw new Error("the model-only pin did not bind the build");
if (modelOnly.thinkingLevel !== "high") {
  throw new Error(`a model-only pin must leave the effort following main: ${modelOnly.thinkingLevel}`);
}

// 5. Clearing the effort pin is the case Pi's own restore would get wrong:
// the branch conversation still records the pinned level, so main's current
// effort has to be applied explicitly rather than merely omitted.
writeFileSync(effortPin, "max\n");
await rebuild("effort repinned", 5);
if (globalThis.__fmSessions[4].options.thinkingLevel !== "max") {
  throw new Error(`deep-1 must accept Pi's max level: ${globalThis.__fmSessions[4].options.thinkingLevel}`);
}
rmSync(effortPin);
setMainThinkingLevel("minimal");
await rebuild("effort cleared", 6);
if (globalThis.__fmSessions[5].options.thinkingLevel === "max") {
  throw new Error("clearing the effort pin left the branch on the previously pinned level");
}
if (globalThis.__fmSessions[5].options.thinkingLevel !== "minimal") {
  throw new Error(`clearing the effort pin did not return the branch to main's effort: ${globalThis.__fmSessions[5].options.thinkingLevel}`);
}

// 6. Pi owns the clamp: a pinned level the branch's model cannot run becomes
// that model's nearest supported level instead of refusing the branch.
rmSync(modelPin);
writeFileSync(effortPin, "max\n");
await rebuild("clamped effort pin", 7);
const clamped = globalThis.__fmSessions[6].options;
if (clamped.model?.id !== "main-model") throw new Error("the clamp probe must run on main's own model");
if (clamped.thinkingLevel !== "high") {
  throw new Error(`an unsupported pinned level must clamp to the model's nearest level: ${clamped.thinkingLevel}`);
}

// 7. A token Pi does not recognize is no pin at all, exactly like an
// unparseable model pin, and never a silent downgrade to no reasoning.
writeFileSync(effortPin, "deep-thought\n");
setMainThinkingLevel("medium");
await rebuild("unrecognized effort pin", 8);
if (globalThis.__fmSessions[7].options.thinkingLevel !== "medium") {
  throw new Error(`an unrecognized effort token must behave as no pin: ${globalThis.__fmSessions[7].options.thinkingLevel}`);
}

// 8. When Pi cannot report main's own effort either, the build falls back to
// passing no effort override at all rather than losing the wake.
rmSync(effortPin);
globalThis.__fmThinkingLevelError = "synthetic unbound extension runtime";
await rebuild("unknown main effort", 9);
delete globalThis.__fmThinkingLevelError;
if ("thinkingLevel" in globalThis.__fmSessions[8].options) {
  throw new Error("an unknowable main effort must fall back to passing no effort override");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the current effort pin state must decide the branch effort on every build: $out"
  pass "the effort pin binds every branch build, and clearing it returns the branch to main's effort"
}

test_unpinned_branch_follows_main_effort_changes_live() {
  local repo home out status
  repo="$TMP_ROOT/effort-live-root"
  home="$TMP_ROOT/effort-live-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, setMainThinkingLevel, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, setMainThinkingLevel, home } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

registryModels.push({ provider: "anthropic", id: "main-model", reasoning: true });
const effortPin = `${home}/config/supervision-branch-effort`;

await fire("session_start", {}, makeCtx());
dispatch("signal: before main effort change");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "initial branch build");
const original = globalThis.__fmSessions[0];
if (original.options.thinkingLevel !== "medium") throw new Error("the unpinned branch did not start on main's effort");

// A mid-session effort change releases the live branch, so the next wake
// reopens the same conversation at main's new effort without waiting for a
// session replacement.
setMainThinkingLevel("high");
await fire("thinking_level_select", { level: "high", previousLevel: "medium" });
await settle(() => original.disposed, "live branch release after main's effort change");
dispatch("signal: after main effort change");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "post-change branch build");
const following = globalThis.__fmSessions[1];
if (following.options.thinkingLevel !== "high") {
  throw new Error(`the unpinned branch did not follow main's effort change: ${following.options.thinkingLevel}`);
}
if (!following.options.sessionManager.opened) {
  throw new Error("following main's effort must keep the persistent branch conversation");
}

// A pinned branch is authoritative: main's effort changes leave both the live
// branch and the stored pin alone.
writeFileSync(effortPin, "minimal\n");
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: pinned effort");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "pinned effort branch build");
const pinned = globalThis.__fmSessions[2];
if (pinned.options.thinkingLevel !== "minimal") throw new Error("the pinned branch did not use its effort pin");

setMainThinkingLevel("high");
await fire("thinking_level_select", { level: "high", previousLevel: "minimal" });
dispatch("signal: pinned after main effort change");
await new Promise((resolve) => setTimeout(resolve, 50));
if (pinned.disposed) throw new Error("a main effort change replaced the effort-pinned branch");
if (readFileSync(effortPin, "utf8") !== "minimal\n") {
  throw new Error("a main effort change disturbed the supervision effort pin");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "unpinned branches must follow main effort changes while pins remain authoritative: $out"
  pass "unpinned branches follow main effort changes live while pinned branches stay fixed"
}

test_supervision_model_picker_is_bounded_searchable_and_branch_only() {
  local repo home out status
  repo="$TMP_ROOT/pickerux-root"
  home="$TMP_ROOT/pickerux-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, makeCtx, makeTuiCtx, commands, registryModels, uiSelections, uiKeystrokes, mainModelWrites, home }; })()`);
const { fire, makeCtx, makeTuiCtx, commands, registryModels, uiSelections, uiKeystrokes, mainModelWrites, home } = globalThis.__t;
import { readFileSync } from "node:fs";

// A catalog long enough that rendering it whole would run off a terminal,
// plus one distinctively named model to search for and one model the
// isolated branch runtime cannot run.
registryModels.push({ provider: "anthropic", id: "main-model" });
for (let i = 1; i <= 30; i += 1) registryModels.push({ provider: "anthropic", id: `bulk-model-${i}` });
registryModels.push({ provider: "openai-codex", id: "cheap-oauth", authKind: "oauth" });
registryModels.push({ provider: "dynamic", id: "extension-only", branchAvailable: false });

const command = commands.get("supervision-model");
if (!command) throw new Error("the supervision-model command was not registered");
await fire("session_start", {}, makeCtx());

// The captain types a search query and confirms the one row it leaves.
globalThis.__fmPickerLists = [];
uiKeystrokes.push(["c", "h", "e", "a", "p", "tui.select.confirm"]);
uiSelections.push(undefined); // the effort step is cancelled, leaving that choice alone
await command.handler("", makeTuiCtx());

const lists = globalThis.__fmPickerLists;
if (lists.length < 2) throw new Error(`typing a query must rebuild the list: ${JSON.stringify(lists.map((l) => l.items.length))}`);
const opened = lists[0];
if (opened.maxVisible !== 10) {
  throw new Error(`the model list must stay bounded rather than rendering every row: maxVisible=${opened.maxVisible}`);
}
if (opened.items[0].label !== "Follow main (anthropic/main-model)") {
  throw new Error(`following main must be the first row: ${JSON.stringify(opened.items.slice(0, 2))}`);
}
if (opened.items.length !== 33) {
  throw new Error(`the opened list must offer following main plus every branch-runnable model: ${opened.items.length}`);
}
if (opened.items.some((item) => item.label.includes("extension-only"))) {
  throw new Error("the picker widened past the branch runtime's eligibility filter");
}
const filtered = lists[lists.length - 1];
if (filtered.items.length !== 1 || filtered.items[0].value !== "openai-codex/cheap-oauth") {
  throw new Error(`the search query did not narrow the list: ${JSON.stringify(filtered.items)}`);
}

// The pick lands on the supervision branch alone.
if (readFileSync(`${home}/config/supervision-branch-model`, "utf8") !== "openai-codex/cheap-oauth\n") {
  throw new Error("the searched-for pick was not persisted as the supervision branch model");
}
if (mainModelWrites.length !== 0) {
  throw new Error(`pinning the branch moved the captain's own model: ${JSON.stringify(mainModelWrites)}`);
}
if (makeCtx().model.id !== "main-model") throw new Error("the captain's own conversation model changed");

// A query that matches following main keeps that row first, and escape
// leaves every choice standing.
globalThis.__fmPickerLists = [];
uiKeystrokes.push(["m", "a", "i", "n", "tui.select.cancel"]);
await command.handler("", makeTuiCtx());
const mainQuery = globalThis.__fmPickerLists[globalThis.__fmPickerLists.length - 1];
if (mainQuery.items[0].label !== "Follow main (anthropic/main-model)") {
  throw new Error(`a matching query must keep following main first: ${JSON.stringify(mainQuery.items.slice(0, 2))}`);
}
if (mainQuery.items.length < 2) throw new Error("a matching query dropped the models it also matched");
if (readFileSync(`${home}/config/supervision-branch-model`, "utf8") !== "openai-codex/cheap-oauth\n") {
  throw new Error("cancelling the picker changed the standing pin");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the model picker must be bounded, searchable, and branch-only: $out"
  pass "supervision-model opens a bounded searchable list, follow main first, and pins the branch alone"
}

test_branch_model_picker_keeps_follow_main_first_under_ranking() {
  local repo out status
  repo="$TMP_ROOT/pickerlib-root"
  mkdir -p "$repo/.pi/extensions/lib"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  LIB="$repo/.pi/extensions/lib/fm-branch-model-picker.ts" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const { buildBranchModelItems, filterBranchPickerItems, BRANCH_PICKER_MAX_VISIBLE, FOLLOW_MAIN_VALUE } = await import(
  pathToFileURL(process.env.LIB).href
);

const items = buildBranchModelItems("Follow main (anthropic/main-model)", ["anthropic/main-model", "openai/mainly-cheap"], null);
if (items[0].value !== FOLLOW_MAIN_VALUE) throw new Error("following main must be built as the first row");
if (items[0].description !== "current") throw new Error("an absent pin must mark following main as the current choice");
if (items[2].description !== undefined) throw new Error("a model that is not pinned must not be marked current");

const pinned = buildBranchModelItems("Follow main (anthropic/main-model)", ["anthropic/main-model"], "anthropic/main-model");
if (pinned[0].description !== undefined) throw new Error("a pinned branch must not mark following main as current");
if (pinned[1].description !== "current") throw new Error("the pinned model must be marked as the current choice");

// A ranking filter is free to sort a better match ahead of following main;
// the picker must still show following main first whenever it matches.
const rankReversing = (list, query, getText) =>
  list.filter((item) => getText(item).toLowerCase().includes(query.toLowerCase())).reverse();
const matched = filterBranchPickerItems(items, "main", rankReversing);
if (matched[0].value !== FOLLOW_MAIN_VALUE) {
  throw new Error(`ranking moved following main out of first place: ${JSON.stringify(matched)}`);
}
if (matched.length !== 3) throw new Error(`a matching query dropped rows it should keep: ${JSON.stringify(matched)}`);

const narrowed = filterBranchPickerItems(items, "openai", rankReversing);
if (narrowed.length !== 1 || narrowed[0].value !== "openai/mainly-cheap") {
  throw new Error(`a query that excludes following main must drop it: ${JSON.stringify(narrowed)}`);
}
const unfiltered = filterBranchPickerItems(items, "   ", rankReversing);
if (unfiltered.length !== items.length || unfiltered[0].value !== FOLLOW_MAIN_VALUE) {
  throw new Error("an empty query must keep the built order");
}
if (BRANCH_PICKER_MAX_VISIBLE !== 10) throw new Error("the picker must keep a bounded visible row count");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the picker's ordering and filtering must hold: $out"
  pass "branch model picker keeps follow main first and filters the eligible catalog"
}

test_supervision_model_command_picks_effort_after_the_model() {
  local repo home out status
  repo="$TMP_ROOT/effortcmd-root"
  home="$TMP_ROOT/effortcmd-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, commands, registryModels, uiSelections, uiPrompts, notices, setMainThinkingLevel, home }; })()`);
const { fire, dispatch, settle, makeCtx, commands, registryModels, uiSelections, uiPrompts, notices, setMainThinkingLevel, home } = globalThis.__t;
import { existsSync, readFileSync, statSync } from "node:fs";

// main-model reasons up to Pi's "high"; deep-1 also maps xhigh and max, so
// the two models genuinely offer different menus.
registryModels.push(
  { provider: "anthropic", id: "main-model", reasoning: true },
  { provider: "openai", id: "deep-1", reasoning: true, thinkingLevelMap: { xhigh: "xhigh", max: "max" } },
  { provider: "openai", id: "shallow-1", reasoning: true },
);
const command = commands.get("supervision-model");
const effortPin = `${home}/config/supervision-branch-effort`;
const modelPin = `${home}/config/supervision-branch-model`;
await fire("session_start", {}, makeCtx());

// One command, two steps in order: the model picker, then an effort picker
// built from Pi's own supported levels for the model just chosen.
uiSelections.push("openai/deep-1", "xhigh");
await command.handler("", makeCtx());
if (uiPrompts.length !== 2) throw new Error(`the command must show the model picker then the effort picker: ${uiPrompts.length}`);
if (!uiPrompts[0].title.startsWith("Supervision branch model")) {
  throw new Error(`the first step must be the model picker: ${uiPrompts[0].title}`);
}
const effortStep = uiPrompts[1];
if (!effortStep.title.startsWith("Supervision branch effort")) {
  throw new Error(`the second step must be the effort picker: ${effortStep.title}`);
}
if (effortStep.options[0] !== "Follow main (medium)") {
  throw new Error(`the effort picker must offer following main first: ${JSON.stringify(effortStep.options)}`);
}
if (JSON.stringify(effortStep.options.slice(1)) !== JSON.stringify(["off", "minimal", "low", "medium", "high", "xhigh", "max"])) {
  throw new Error(`the effort picker must offer Pi's own levels for the chosen model: ${JSON.stringify(effortStep.options)}`);
}
if (readFileSync(effortPin, "utf8") !== "xhigh\n") {
  throw new Error(`unexpected persisted effort pin: ${JSON.stringify(readFileSync(effortPin, "utf8"))}`);
}
if ((statSync(effortPin).mode & 0o777) !== 0o600) throw new Error("the effort pin must be written private to the operator");
if (readFileSync(modelPin, "utf8") !== "openai/deep-1\n") throw new Error("the model pick was not persisted alongside the effort pick");
const bothNotice = notices[notices.length - 1];
if (!bothNotice.message.includes("openai/deep-1") || !bothNotice.message.includes("xhigh")) {
  throw new Error(`the captain was not told both applied choices: ${JSON.stringify(bothNotice)}`);
}

// Both choices bind the next branch build together.
dispatch("signal: after both picks");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "branch build after both picks");
const both = globalThis.__fmSessions[0].options;
if (both.model?.id !== "deep-1" || both.thinkingLevel !== "xhigh") {
  throw new Error(`the picks did not bind the branch build: ${JSON.stringify({ model: both.model?.id, effort: both.thinkingLevel })}`);
}

// The effort picker's menu follows the model chosen in the SAME invocation,
// not the model the branch was running a moment ago: main-model stops at
// Pi's "high", so xhigh and max disappear.
uiSelections.push("Follow main (anthropic/main-model)", "high");
await command.handler("", makeCtx());
const narrowed = uiPrompts[uiPrompts.length - 1];
if (narrowed.options.includes("xhigh") || narrowed.options.includes("max")) {
  throw new Error(`the effort menu did not follow the model just chosen: ${JSON.stringify(narrowed.options)}`);
}
if (!narrowed.title.includes("now: xhigh")) {
  throw new Error(`the effort picker must show the standing pin: ${narrowed.title}`);
}
if (readFileSync(effortPin, "utf8") !== "high\n") throw new Error("the second effort pick was not persisted");
if (existsSync(modelPin)) throw new Error("following main did not clear the model pin");

// Cancelling the effort step leaves the standing effort choice alone while
// the model pick made in the same invocation still applies, and the captain
// is told what the branch will actually run at.
const cancelNoticeCount = notices.length;
uiSelections.push("openai/deep-1");
await command.handler("", makeCtx());
if (readFileSync(effortPin, "utf8") !== "high\n") throw new Error("a cancelled effort step changed the standing effort pin");
if (readFileSync(modelPin, "utf8") !== "openai/deep-1\n") throw new Error("a cancelled effort step discarded the model pick");
const cancelNotices = notices.slice(cancelNoticeCount);
if (cancelNotices.length !== 1 || cancelNotices[0].type !== "info" || !cancelNotices[0].message.includes("high")) {
  throw new Error(`a cancelled effort step must still report the standing effort: ${JSON.stringify(cancelNotices)}`);
}

// Following main for effort clears the pin and reports main's own level.
const followNoticeCount = notices.length;
uiSelections.push("openai/deep-1", "Follow main (medium)");
await command.handler("", makeCtx());
if (existsSync(effortPin)) throw new Error("following main must remove the effort pin file");
const followNotices = notices.slice(followNoticeCount);
if (followNotices.length !== 1 || !followNotices[0].message.includes("Effort follows main (medium)")) {
  throw new Error(`following main for effort was not reported honestly: ${JSON.stringify(followNotices)}`);
}

// Honest reporting when Pi's own clamp will lower a standing pin: "max" is
// offered on deep-1, but moving the branch back to main-model, which tops out
// at Pi's "high", must be reported as the level the branch will really run at
// rather than as the raw pin - and the captain's raw pick is kept, so
// returning to deep-1 restores it.
uiSelections.push("openai/deep-1", "max");
await command.handler("", makeCtx());
if (readFileSync(effortPin, "utf8") !== "max\n") throw new Error("the max effort pick was not persisted");
const clampNoticeCount = notices.length;
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
const clampNotices = notices.slice(clampNoticeCount);
if (clampNotices.length !== 1 || !clampNotices[0].message.includes("Effort: max, which this model runs at high.")) {
  throw new Error(`a clamped standing effort pin was not reported honestly: ${JSON.stringify(clampNotices)}`);
}
if (readFileSync(effortPin, "utf8") !== "max\n") throw new Error("reporting a clamp rewrote the captain's raw effort pick");
dispatch("signal: clamped build");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "clamped branch build");
if (globalThis.__fmSessions[1].options.thinkingLevel !== "high") {
  throw new Error(`the clamped build did not run at the reported level: ${globalThis.__fmSessions[1].options.thinkingLevel}`);
}

// When main's model cannot be resolved, the effort step derives Pi's level
// set from the model recorded by the most recent branch conversation.
uiSelections.push("openai/shallow-1", "max");
await command.handler("", makeCtx());
dispatch("signal: record shallow branch model");
await settle(() => (globalThis.__fmSessions ?? []).length === 3, "shallow branch build");
registryModels.find((model) => model.id === "main-model").branchAvailable = false;
const restoredNoticeCount = notices.length;
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
const restoredPicker = uiPrompts[uiPrompts.length - 1];
if (JSON.stringify(restoredPicker.options.slice(1)) !== JSON.stringify(["off", "minimal", "low", "medium", "high"])) {
  throw new Error(`the unresolved-main picker did not use Pi's levels for the recorded branch model: ${JSON.stringify(restoredPicker.options)}`);
}
const restoredNotices = notices.slice(restoredNoticeCount);
if (restoredNotices.length !== 1 || !restoredNotices[0].message.includes("Effort: max, which this model runs at high.")) {
  throw new Error(`the recorded branch model did not make clamp reporting honest: ${JSON.stringify(restoredNotices)}`);
}

// If neither main nor the recorded branch model can be resolved, no invented
// catalog is offered and the report says the applied level is unknown.
registryModels.find((model) => model.id === "shallow-1").branchAvailable = false;
const unknownNoticeCount = notices.length;
uiSelections.push("Follow main (anthropic/main-model)");
await command.handler("", makeCtx());
const unknownPicker = uiPrompts[uiPrompts.length - 1];
if (JSON.stringify(unknownPicker.options) !== JSON.stringify(["Follow main (medium)"])) {
  throw new Error(`the unknown-model picker invented effort levels: ${JSON.stringify(unknownPicker.options)}`);
}
const unknownNotices = notices.slice(unknownNoticeCount);
if (unknownNotices.length !== 1 || !unknownNotices[0].message.includes("cannot be determined")) {
  throw new Error(`the unknown effective effort was reported as applied: ${JSON.stringify(unknownNotices)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the effort step must follow the model step and persist independently: $out"
  pass "supervision-model runs an effort picker after the model picker and persists both independently"
}

test_unusable_model_pin_falls_back_to_main() {
  local repo home out status
  repo="$TMP_ROOT/modelbad-root"
  home="$TMP_ROOT/modelbad-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, makeCtx, registryModels, mainUserMessages, home }; })()`);
const { fire, dispatch, settle, makeCtx, registryModels, mainUserMessages, home } = globalThis.__t;
import { writeFileSync } from "node:fs";

registryModels.push(
  { provider: "anthropic", id: "main-model" },
  { provider: "dynamic", id: "extension-only", branchAvailable: false },
);

// A pin the isolated branch runtime cannot hand back is never a silent
// downgrade onto main's model, even when main's session knows that model.
writeFileSync(`${home}/config/supervision-branch-model`, "dynamic/extension-only\n");
await fire("session_start", {}, makeCtx());
const unusableOffer = dispatch("signal: unusable pin probe");
if (!unusableOffer.accepted) throw new Error("unusable-pin wake was not initially accepted");
const unusableFailure = await unusableOffer.settlement.then(
  () => null,
  (error) => error,
);
if (
  !(unusableFailure instanceof Error) ||
  !unusableFailure.message.includes("dynamic/extension-only") ||
  !unusableFailure.message.includes("supervision model pin")
) {
  throw new Error(`the rejected settlement did not name the unusable pin: ${String(unusableFailure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
if ((globalThis.__fmSessions ?? []).length !== 0) throw new Error("an unusable pin must not build a branch session");

// An unparseable file is simply no pin, so supervision keeps working and the
// branch follows main's own model.
writeFileSync(`${home}/config/supervision-branch-model`, "not-a-model-reference\n");
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
dispatch("signal: unparseable pin probe");
await settle(() => (globalThis.__fmSessions ?? []).length === 1, "unparseable-pin branch build");
const unparseable = globalThis.__fmSessions[0].options.model;
if (unparseable?.provider !== "anthropic" || unparseable?.id !== "main-model") {
  throw new Error(`an unparseable pin must be treated as no pin and follow main: ${JSON.stringify(unparseable)}`);
}
// Even a registered native provider cannot be selected by the independent
// supervision session: its persistent native thread belongs to main.
registryModels.push({ provider: "codex-native", id: "gpt-6-astra" });
writeFileSync(`${home}/config/supervision-branch-model`, "codex-native/gpt-6-astra\n");
await fire("session_shutdown", {});
await fire("session_start", {}, makeCtx());
const nativeOffer = dispatch("signal: native branch pin refused");
const nativeFailure = await nativeOffer.settlement.then(() => null, (error) => error);
if (!(nativeFailure instanceof Error) || !nativeFailure.message.includes("ordinary Pi provider")) {
  throw new Error(`native branch pin was not explicitly refused: ${String(nativeFailure)}`);
}
if (globalThis.__fmSessions.length !== 1) throw new Error("native pin built a shared native branch");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an unusable model pin must reject to watcher delivery and an unparseable one must be no pin: $out"
  pass "an unusable model pin rejects to watcher fallback and an unparseable one is treated as no pin"
}

test_replacement_activation_retries_failed_activation() {
  local repo home fakebin out status real_bash
  repo="$TMP_ROOT/activation-root"
  home="$TMP_ROOT/activation-home"
  fakebin="$home/fakebin"
  real_bash=$(command -v bash)
  mkdir -p "$home/state" "$home/config" "$fakebin"
  install_pi_branch_extension_fixture "$repo"
  cat > "$fakebin/bash" <<'SH'
#!/bin/sh
if [ "$1" = "$FM_TEST_GRANT_SCRIPT" ] && [ ! -e "$FM_TEST_FAIL_MARKER" ]; then
  : > "$FM_TEST_FAIL_MARKER"
  exit 7
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
  chmod +x "$fakebin/bash"
  PATH="$fakebin:$PATH" PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_REAL_BASH="$real_bash" FM_TEST_GRANT_SCRIPT="$ROOT/bin/fm-wake-grant.sh" \
    FM_TEST_FAIL_MARKER="$home/state/grant-failed-once" DRIVER_PRELUDE="$DRIVER_PRELUDE" \
    node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, home, defaultSessionCtx }; })()`);
const { fire, home, defaultSessionCtx } = globalThis.__t;
import { existsSync } from "node:fs";

await fire("session_start", {}, defaultSessionCtx);
if (!existsSync(`${home}/state/grant-failed-once`)) {
  throw new Error("session_start did not attempt activation through the grant script");
}
if (existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("failed activation committed the loaded marker");
}
// Activation is retried lazily on the next owned boundary, so a transient
// grant-script failure must not leave the generation permanently inert.
await fire("turn_end", {}, defaultSessionCtx);
if (!existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("later boundary did not retry the failed activation");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "replacement activation must retry a failed grant activation: $out"
  pass "replacement activation retries a failed grant activation on the next owned boundary"
}

test_queued_actions_recheck_lock_ownership() {
  local repo home out status
  repo="$TMP_ROOT/queued-ownership-root"
  home="$TMP_ROOT/queued-ownership-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, home, mainUserMessages }; })()`);
const { fire, dispatch, settle, home, mainUserMessages } = globalThis.__t;
import { existsSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";

let releasePrompt;
globalThis.__fmPromptGate = new Promise((resolve) => { releasePrompt = resolve; });
if (!dispatch("signal: active wake").accepted) throw new Error("first wake was not accepted");
await settle(() => globalThis.__fmPromptStarted === true, "blocked first prompt");
const queuedOffer = dispatch("signal: queued wake");
if (!queuedOffer.accepted) throw new Error("queued wake was not accepted");
const queuedFailure = queuedOffer.settlement.then(
  () => null,
  (error) => error,
);
const entries = [{ type: "message", message: { role: "user", content: "queued mirror must stay undelivered" } }];
await fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/main.jsonl`, getEntries: () => entries },
});
// Ownership is lost only to a LIVE foreign holder now: an absent or dead
// legacy lock belongs to this native home.
const foreign = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
writeFileSync(`${home}/state/.lock`, `${foreign.pid}\n`);
try {
  releasePrompt();
  const failure = await queuedFailure;
  if (!(failure instanceof Error) || !failure.message.includes("no longer owns the fleet lock")) {
    throw new Error(`queued wake did not reject to watcher fallback: ${String(failure)}`);
  }
  if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
  await new Promise((resolve) => setTimeout(resolve, 25));
  const session = globalThis.__fmSessions[0];
  if (session.ops.some((op) => op.kind === "custom")) throw new Error("queued mirror appended after lock ownership was lost");
  if (existsSync(`${home}/state/.branch-mirror-cursor`)) throw new Error("queued mirror advanced its cursor after lock ownership was lost");
} finally {
  foreign.kill("SIGTERM");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "queued branch actions must recheck lock ownership: $out"
  pass "queued wakes and mirrors stop mutating branch state after lock ownership is lost"
}

test_stale_generation_boundaries_are_side_effect_free() {
  local repo home out status
  repo="$TMP_ROOT/stale-boundaries-root"
  home="$TMP_ROOT/stale-boundaries-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, home, sentToMain }; })()`);
const { fire, dispatch, settle, home, sentToMain } = globalThis.__t;
import { existsSync, readFileSync } from "node:fs";

if (!dispatch("signal: establish old branch").accepted) throw new Error("old branch wake was not accepted");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "old branch prompt");
const oldSession = globalThis.__fmSessions[0];
const oldReport = oldSession.options.customTools.find((tool) => tool.name === "fm_branch_report");
const oldBash = oldSession.options.customTools.find((tool) => tool.name === "bash");

let releaseMirror;
globalThis.__fmMirrorGate = new Promise((resolve) => { releaseMirror = resolve; });
const oldEntries = [{ type: "message", message: { role: "user", content: "old generation mirror" } }];
await fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/old-main.jsonl`, getEntries: () => oldEntries },
});
await settle(() => globalThis.__fmMirrorStarted === true, "blocked old mirror delivery");
await fire("session_shutdown", {});
await fire("session_start", {});
const newEntries = [{ type: "message", message: { role: "user", content: "new generation mirror" } }];
await fire("turn_end", {}, {
  sessionManager: { getSessionFile: () => `${home}/new-main.jsonl`, getEntries: () => newEntries },
});

const reportResult = await oldReport.execute(
  "stale-report",
  { task: "task-stale", verdict: "captain", summary: "must not append or merge" },
  undefined,
  undefined,
  {},
);
if (!reportResult.isError) throw new Error("stale report tool was not refused");
let bashRefused = false;
try {
  oldBash.__options.spawnHook({
    command: "printf stale-shell > state/stale-shell-ran",
    cwd: home,
    env: {},
  });
} catch {
  bashRefused = true;
}
if (!bashRefused) throw new Error("stale bash tool was not refused");
if (existsSync(`${home}/state/branch-outcomes.jsonl`)) throw new Error("stale report appended an outcome");
if (existsSync(`${home}/state/stale-shell-ran`)) throw new Error("stale bash tool ran a shell command");
if (sentToMain.length !== 0) throw new Error("stale report merged a note into main");

releaseMirror();
await new Promise((resolve) => setTimeout(resolve, 25));
if (!dispatch("signal: establish replacement branch").accepted) throw new Error("replacement wake was not accepted");
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "replacement branch prompt");
await settle(
  () => (globalThis.__fmMirrors ?? []).some((message) => message.content === "[captain] new generation mirror"),
  "replacement mirror delivery",
);
const cursor = JSON.parse(readFileSync(`${home}/state/.branch-mirror-cursor`, "utf8"));
if (cursor.file !== `${home}/new-main.jsonl` || cursor.index !== 1) {
  throw new Error(`stale mirror continuation changed the replacement cursor: ${JSON.stringify(cursor)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "stale branch boundaries must perform no side effects: $out"
  pass "stale reports, shells, mirrors, cursors, and prompts perform no side effects"
}
