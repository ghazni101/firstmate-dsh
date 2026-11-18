# shellcheck shell=bash
# Test cases for fm-pi-watch-extension, split out of tests/fm-pi-watch-extension.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-pi-watch-extension.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


# The former after-delivery expectation conflicts with the approved restore
# contract: a verified failure keeps its bounded retry during held delivery.
test_pi_successor_failure_during_delivery_is_retried_after_delivery() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-successor-dies-mid-delivery-root"
  home="$TMP_ROOT/pi-successor-dies-mid-delivery-home"
  log="$TMP_ROOT/pi-successor-dies-mid-delivery.log"
  stop="$TMP_ROOT/pi-successor-dies-mid-delivery.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  printf 'signal: wake before the successor dies\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  sleep 0.1
  printf 'watcher: FAILED - successor lost its beacon\n'
  exit 3
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let releaseBranch = () => {};
const branchSettlement = new Promise((resolve) => {
  releaseBranch = resolve;
});
let branchAccepted = false;
let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(message);
  },
  events: {
    on() {},
    emit(event, data) {
      if (event !== "fm-branch-supervision:dispatch") return;
      branchAccepted = true;
      data.accept(branchSettlement);
    },
  },
};
const arms = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").split("\n").filter((row) => row.startsWith("arm=")).length
  : 0;
async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/mid-delivery.meta`, "project=/projects/mid-delivery\nwindow=fm-mid-delivery\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\tmid-delivery.status\tsignal: wake before the successor dies\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("initial-arm", {}, undefined, undefined, {});
await waitFor(() => branchAccepted, "branch accepted the wake behind a verified successor");
if (arms() !== 2) throw new Error(`expected the verified successor before delivery, got ${arms()} arms`);
// The successor dies while the branch still holds the delivery.
await new Promise((resolve) => setTimeout(resolve, 300));
if (arms() !== 2) throw new Error(`a retry launched while the delivery was still in flight: ${arms()} arms`);
releaseBranch();
await waitFor(() => arms() === 3, "a retry watcher after the delivery settled");
await new Promise((resolve) => setTimeout(resolve, 150));
if (arms() !== 3) throw new Error(`the deferred retry was not single-flight: ${arms()} arms`);
if (prompts.length !== 0) throw new Error(`a bounded retry surfaced a failure prompt: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must retry a verified successor that failed during wake delivery"
  [ -z "$out" ] || fail "Pi successor-dies-mid-delivery test printed output: $out"
  pass "Pi retries a verified successor that failed during wake delivery once that delivery settles"
}

test_pi_late_retiring_actionable_reaches_replacement() {
  local repo home plugin count out status
  repo="$TMP_ROOT/pi-late-retiring-actionable-root"
  home="$TMP_ROOT/pi-late-retiring-actionable-home"
  count="$TMP_ROOT/pi-late-retiring-actionable.count"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_ARM_COUNT" ] || count=$(cat "$FM_ARM_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_ARM_COUNT"
previous=$(cat "$FM_ARM_COUNT.pid" 2>/dev/null || true)
printf '%s\n' "$$" > "$FM_ARM_COUNT.pid"
[ -z "$previous" ] || kill -TERM "$previous" 2>/dev/null || true
late_close() {
  sleep 0.15
  printf 'signal: late retiring actionable outcome\n'
  exit 0
}
trap late_close TERM INT
printf 'watcher: started pid=%s\n' "$$"
while [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_COUNT="$count" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  let tool = null;
  const prompts = [];
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async (message) => {
      prompts.push(message);
    },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, getTool: () => tool, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const originalMod = await import(pathToFileURL(process.env.PLUGIN).href);
const original = makePi();
originalMod.default(original.pi);
const armed = await original.getTool().execute("initial-arm", {}, undefined, undefined, {});
if (!armed.details?.ok) throw new Error(`initial arm failed: ${JSON.stringify(armed.details)}`);
await waitFor(() => existsSync(process.env.FM_ARM_COUNT) && readFileSync(process.env.FM_ARM_COUNT, "utf8").trim() === "1", "original arm");
await original.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
writeFileSync(`${process.env.FM_HOME}/state/extensions`, "block late handoff publication\n");
const foreignState = `${process.env.FM_HOME}/foreign-state`;
const { mkdirSync } = await import("node:fs");
mkdirSync(foreignState, { recursive: true });
writeFileSync(`${foreignState}/.lock`, `${process.pid}\n`);
process.env.FM_STATE_OVERRIDE = foreignState;
const foreignMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=foreign-state`);
const foreign = makePi();
foreignMod.default(foreign.pi);
await foreign.handlers.get("session_start")?.({ type: "session_start", reason: "resume" }, {});
await new Promise((resolve) => setTimeout(resolve, 250));
if (foreign.prompts.some((message) => message.includes("signal: late retiring actionable outcome"))) {
  throw new Error(`late old-state outcome crossed into foreign state: ${foreign.prompts.join(" | ")}`);
}
await foreign.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
delete process.env.FM_STATE_OVERRIDE;

const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=late-retiring-close`);
const replacement = makePi();
replacementMod.default(replacement.pi);
await replacement.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await waitFor(
  () => replacement.prompts.some((message) => message.includes("signal: late retiring actionable outcome")),
  "late actionable delivery to replacement",
);
const latePrompts = replacement.prompts.filter((message) => message.includes("signal: late retiring actionable outcome"));
if (latePrompts.length !== 1) {
  throw new Error(`replacement did not receive exactly one late outcome: ${replacement.prompts.join(" | ")}`);
}
if (!latePrompts[0].includes("watcher: FAILED - Pi extension could not persist a late replacement-session actionable wake")) {
  throw new Error(`late handoff publication failure was not surfaced: ${latePrompts[0]}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi replacement must receive an actionable close after retirement timeout"
  [ -z "$out" ] || fail "Pi late retiring actionable test printed output: $out"
  pass "Pi replacement receives actionable closes after retirement timeout"
}

test_pi_replacement_tokens_are_process_unique() {
  local repo home plugin count out status
  repo="$TMP_ROOT/pi-replacement-token-uniqueness-root"
  home="$TMP_ROOT/pi-replacement-token-uniqueness-home"
  count="$TMP_ROOT/pi-replacement-token-uniqueness.count"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_ARM_COUNT" ] || count=$(cat "$FM_ARM_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_ARM_COUNT"
previous=$(cat "$FM_ARM_COUNT.pid" 2>/dev/null || true)
printf '%s\n' "$$" > "$FM_ARM_COUNT.pid"
[ -z "$previous" ] || kill -TERM "$previous" 2>/dev/null || true
late_close() {
  sleep 0.08
  printf 'signal: module-%s late actionable outcome\n' "$count"
  exit 0
}
trap late_close TERM INT
printf 'watcher: started pid=%s\n' "$$"
while [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_COUNT="$count" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=10 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

Date.now = () => 1700000000000;

function makePi() {
  const handlers = new Map();
  let tool = null;
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async () => {},
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, getTool: () => tool };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
for (let moduleIndex = 1; moduleIndex <= 2; moduleIndex += 1) {
  const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?token-module=${moduleIndex}`);
  const instance = makePi();
  mod.default(instance.pi);
  const armed = await instance.getTool().execute(`arm-${moduleIndex}`, {}, undefined, undefined, {});
  if (!armed.details?.ok) throw new Error(`module ${moduleIndex} arm failed: ${JSON.stringify(armed.details)}`);
  await waitFor(
    () => existsSync(process.env.FM_ARM_COUNT) && Number(readFileSync(process.env.FM_ARM_COUNT, "utf8").trim()) >= moduleIndex,
    `module ${moduleIndex} arm`,
  );
  await instance.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
}
// Replacement shutdown deliberately retains the established module-2 arm until
// a successor commits. Start that successor so both retiring modules publish
// their late actionable closes under distinct process-wide tokens.
const collectorMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?token-module=collector`);
const collector = makePi();
collectorMod.default(collector.pi);
const collectorArm = await collector.getTool().execute("arm-collector", {}, undefined, undefined, {});
if (!collectorArm.details?.ok) throw new Error(`collector arm failed: ${JSON.stringify(collectorArm.details)}`);
await waitFor(
  () => existsSync(process.env.FM_ARM_COUNT) && Number(readFileSync(process.env.FM_ARM_COUNT, "utf8").trim()) >= 3,
  "collector arm",
);
const handoffPath = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
await waitFor(() => existsSync(handoffPath), "replacement handoff");
await waitFor(() => JSON.parse(readFileSync(handoffPath, "utf8")).pending.length === 2, "two distinct handoff outcomes");
const handoff = JSON.parse(readFileSync(handoffPath, "utf8"));
if (new Set(handoff.pending.map((item) => item.token)).size !== 2) {
  throw new Error(`fresh modules reused a replacement token: ${JSON.stringify(handoff)}`);
}
for (const moduleIndex of [1, 2]) {
  if (!handoff.pending.some((item) => item.message.includes(`signal: module-${moduleIndex} late actionable outcome`))) {
    throw new Error(`module ${moduleIndex} outcome was dropped: ${JSON.stringify(handoff)}`);
  }
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi replacement handoff tokens must stay unique across fresh modules"
  [ -z "$out" ] || fail "Pi replacement token uniqueness test printed output: $out"
  pass "Pi replacement handoff tokens stay unique across fresh modules"
}

test_pi_replacement_persistence_failure_keeps_predecessor_until_successor() {
  local repo home plugin count marker out status
  repo="$TMP_ROOT/pi-replacement-persistence-failure-root"
  home="$TMP_ROOT/pi-replacement-persistence-failure-home"
  count="$TMP_ROOT/pi-replacement-persistence-failure.count"
  marker="$TMP_ROOT/pi-replacement-persistence-failure.marker"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_ARM_COUNT" ] || count=$(cat "$FM_ARM_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_ARM_COUNT"
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s\n' "$$"
  printf 'signal: persistence failure actionable outcome\n'
  exit 0
fi
previous=$(cat "$FM_CHILD_MARKER" 2>/dev/null || true)
if [ -n "$previous" ] && kill -0 "$previous" 2>/dev/null; then
  kill -TERM "$previous" 2>/dev/null || true
  while kill -0 "$previous" 2>/dev/null; do sleep 0.01; done
fi
cleanup() { rm -f "$FM_CHILD_MARKER"; }
trap cleanup EXIT
trap 'exit 0' TERM INT
printf '%s\n' "$$" > "$FM_CHILD_MARKER"
printf 'watcher: started pid=%s\n' "$$"
while [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_COUNT="$count" FM_CHILD_MARKER="$marker" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let tool = null;
let deliveryStarted = false;
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    deliveryStarted = true;
    prompts.push(message);
  },
  events: { on() {}, emit() {} },
};

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const armed = await tool.execute("initial-arm", {}, undefined, undefined, {});
if (!armed.details?.ok) throw new Error(`initial arm failed: ${JSON.stringify(armed.details)}`);
await waitFor(() => deliveryStarted && existsSync(process.env.FM_CHILD_MARKER), "blocked delivery and successor child");
writeFileSync(`${process.env.FM_HOME}/state/extensions`, "block handoff directory\n");
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
if (!existsSync(process.env.FM_CHILD_MARKER)) {
  throw new Error("replacement shutdown retired the established predecessor after handoff persistence failed");
}
const { unlinkSync } = await import("node:fs");
unlinkSync(`${process.env.FM_HOME}/state/extensions`);
const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=persistence-failure`);
replacementMod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await waitFor(() => prompts.length >= 2, "in-process handoff after persistence failure");
if (!prompts[1].includes("signal: persistence failure actionable outcome")) {
  throw new Error(`replacement lost the in-process actionable outcome: ${prompts.join(" | ")}`);
}
if (!prompts[1].includes("could not persist a replacement-session actionable wake")) {
  throw new Error(`replacement did not surface the persistence failure: ${prompts[1]}`);
}
handlers.get("before_agent_start")?.({ messageType: "user", prompt: prompts[1] }, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi replacement persistence failure must keep its predecessor until a successor commits"
  [ -z "$out" ] || fail "Pi replacement persistence-failure continuity test printed output: $out"
  pass "Pi replacement persistence failure keeps its predecessor until a successor commits"
}

test_pi_process_exit_cleanup_listener_lifecycle() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-exit-listener-root"
  home="$TMP_ROOT/pi-exit-listener-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async () => {},
};
const before = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("Pi extension did not install exactly one process-exit fallback");
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("session_shutdown removed the process-lifetime exit fallback");
}
await handlers.get("session_start")?.({ type: "session_start" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("replacement activation duplicated the process-exit fallback");
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi cleanup fallback listener must remain singular across session replacement"
  [ -z "$out" ] || fail "Pi listener-lifecycle test printed output: $out"
  pass "Pi process-exit cleanup listener remains singular across session replacement"
}

# A case that fails before writing its stop file leaves its arm stub's poller
# behind, reparented away from the case. The stub here is the unguarded shape of
# the pollers that once outlived this suite: only the process-group reap that
# teardown runs can stop it, and once reaped nothing from its root survives.
test_pi_failed_case_poller_is_reaped_as_a_group() {
  local repo stop pid_file out status poller i
  repo="$TMP_ROOT/pi-failed-case-root"
  stop="$TMP_ROOT/pi-failed-case.stop"
  pid_file="$TMP_ROOT/pi-failed-case.poller"
  mkdir -p "$repo/bin"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
(while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.05; done) &
printf '%s\n' "$!" > "$FM_POLLER_PID_FILE"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_ARM="$repo/bin/fm-watch-arm.sh" FM_STOP_FILE="$stop" FM_POLLER_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { spawnSync } from "node:child_process";
spawnSync("bash", [process.env.FM_ARM], { stdio: "ignore" });
throw new Error("injected case failure before the stop file");
EOF
)
  status=$?
  [ "$status" -ne 0 ] || fail "the injected case failure did not fail: $out"
  poller=$(cat "$pid_file" 2>/dev/null || true)
  if [ -z "$poller" ] || ! kill -0 "$poller" 2>/dev/null; then
    fail "the failed case left no live poller, so the reap below would prove nothing"
  fi
  pi_reap_process_groups
  i=0
  while [ "$i" -lt 20 ] && kill -0 "$poller" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$poller" 2>/dev/null; then
    kill -KILL "$poller" 2>/dev/null || true
    fail "the process-group reap left the failed case's poller pid $poller running"
  fi
  out=$(ps -eo ppid=,args= 2>/dev/null | awk -v root="$repo/" '$1 == 1 && index($0, root)')
  [ -z "$out" ] || fail "orphans from the failed case survived the reap: $out"
  pass "Pi teardown reaps a failed case's orphaned poller as a process group"
}

# Run last: after the teardown reap, nothing this suite started may be left
# running under init from its temporary root.
test_pi_suite_leaves_no_orphaned_processes() {
  local out
  pi_reap_process_groups
  out=$(ps -eo ppid=,args= 2>/dev/null | awk -v root="$TMP_ROOT/" '$1 == 1 && index($0, root)')
  [ -z "$out" ] || fail "processes from this suite's temporary root outlived the teardown reap: $out"
  pass "Pi suite leaves no orphaned process from its temporary root"
}

test_pi_process_exit_cleanup_stops_arm_child() {
  local repo home plugin cleanup_log pid_file out status pid i
  repo="$TMP_ROOT/pi-process-exit-root"
  home="$TMP_ROOT/pi-process-exit-home"
  cleanup_log="$TMP_ROOT/pi-process-exit-cleaned"
  pid_file="$TMP_ROOT/pi-process-exit-child.pid"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "%s\n" "$$" >> "$FM_CLEANUP_LOG"; exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while [ -e "$0" ]; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-exit", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !existsSync(process.env.FM_CHILD_PID_FILE); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_CHILD_PID_FILE)) throw new Error("arm child did not start");
const firstChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
await handlers.get("session_start")?.({ type: "session_start" }, {});
await tool.execute("tool-call-replacement", {}, undefined, undefined, {});
for (let i = 0; i < 250; i += 1) {
  const currentChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
  if (currentChild !== firstChild) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim() === firstChild) {
  throw new Error("replacement arm child did not start");
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi process exit must run the watcher cleanup fallback"
  [ -z "$out" ] || fail "Pi process-exit cleanup test printed output: $out"
  pid=$(cat "$pid_file")
  i=0
  while [ "$i" -lt 250 ] && ! grep -qx "$pid" "$cleanup_log" 2>/dev/null; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -qx "$pid" "$cleanup_log" 2>/dev/null || fail "Pi process-exit fallback did not deliver TERM to the replacement arm child"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_opencode_plugin_package_boundary_is_explicit_esm() {
  local fixture plugin out status
  fixture="$TMP_ROOT/opencode-esm-boundary/.opencode"
  plugin="$fixture/plugins/fm-primary-watch-arm.js"
  mkdir -p "$fixture/plugins/lib"
  printf '%s\n' '{"dependencies":{}}' > "$fixture/package.json"
  cp "$ROOT/.opencode/plugins/package.json" "$fixture/plugins/package.json"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$fixture/plugins/lib/fm-operational-input.js"
  cp "$ROOT/.opencode/plugins/lib/fm-opencode2.js" "$fixture/plugins/lib/fm-opencode2.js"
  out=$(PLUGIN="$plugin" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
await import(pathToFileURL(process.env.PLUGIN).href);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must import beneath an explicit ESM package boundary"
  [ -z "$out" ] || fail "OpenCode ESM boundary import printed output: $out"
  pass "OpenCode plugins have an explicit ESM boundary even under a typeless parent package"
}

test_opencode_primary_watch_plugin_uses_effective_state_home() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-state-root"
  home="$TMP_ROOT/opencode-effective-state-home"
  log="$TMP_ROOT/opencode-effective-state.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s root=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
const expectedRoot = realpathSync(process.env.WORKTREE);
if (!text.includes(`home=${process.env.FM_HOME}`) || !text.includes(`root=${expectedRoot}`)) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must use FM_HOME state outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-state test printed output: $out"
  pass "OpenCode watcher plugin uses the effective FM_HOME state"
}

test_opencode2_watch_plugin_arms_on_interrupted_turn_but_not_shutdown() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode2-terminal-root"
  home="$TMP_ROOT/opencode2-terminal-home"
  log="$TMP_ROOT/opencode2-terminal.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'armed\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # The OpenCode 2.0.x plugin context carries the project only as
  # ctx.location.project.directory, so this fixture deliberately omits every
  # other directory field.
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const queue = [];
let wake = null;
const push = (event) => { queue.push(event); if (wake) { wake(); wake = null; } };
async function* stream() {
  for (;;) {
    while (queue.length) yield queue.shift();
    await new Promise((resolve) => { wake = resolve; });
  }
}
const ctx = {
  location: { project: { directory: process.env.WORKTREE } },
  event: { subscribe: () => stream() },
  session: { prompt: async () => {} },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default.setup(ctx);
push({ type: "session.execution.interrupted", data: { sessionID: "ses-shutdown", reason: "shutdown" } });
await sleep(1000);
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("a shutdown terminal event armed the watcher");
  process.exit(1);
}
push({ type: "session.execution.interrupted", data: { sessionID: "ses-root" } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) await sleep(20);
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("an interrupted turn did not arm the watcher");
  process.exit(1);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode 2 watch plugin must arm on an interrupted turn and ignore shutdown: $out"
  [ -z "$out" ] || fail "OpenCode 2 terminal-event test printed output: $out"
  pass "OpenCode 2 watch plugin arms on an interrupted turn from the project location and ignores shutdown"
}

test_opencode2_sessionstart_nudge_prompts_with_flat_session_shape() {
  local plugin repo home out status
  plugin="$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js"
  repo="$TMP_ROOT/opencode2-nudge-root"
  home="$TMP_ROOT/opencode2-nudge-home"
  mkdir -p "$repo/bin" "$home/state"
  git init -q "$repo"
  cat > "$repo/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
printf 'NUDGE_TEXT\n'
SH
  chmod +x "$repo/bin/fm-sessionstart-nudge.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const calls = [];
async function* stream() {
  yield { type: "session.created", data: { sessionID: "ses-1" } };
  await new Promise(() => {});
}
const ctx = {
  location: { project: { directory: process.env.WORKTREE } },
  event: { subscribe: () => stream() },
  session: { prompt: async (arg) => { calls.push(arg); } },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default.setup(ctx);
for (let i = 0; i < 250 && calls.length === 0; i += 1) await new Promise((r) => setTimeout(r, 20));
const first = calls[0];
if (!first || first.sessionID !== "ses-1" || first.text !== "NUDGE_TEXT") {
  console.error(JSON.stringify(calls));
  process.exit(1);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode 2 session-start nudge must prompt with { sessionID, text }: $out"
  pass "OpenCode 2 session-start nudge resolves the project location and prompts with the flat session shape"
}

test_opencode2_seatbelts_block_only_the_shell_tool() {
  local repo out status plugin owner
  repo="$TMP_ROOT/opencode2-seatbelt-root"
  mkdir -p "$repo/bin"
  git init -q "$repo"
  for owner in fm-cd-pretool-check.sh fm-arm-pretool-check.sh; do
    cat > "$repo/bin/$owner" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --command ] || exit 0
case "${2:-}" in
  *DENY_ME*) printf 'seatbelt denied\n' >&2; exit 2 ;;
esac
exit 0
SH
    chmod +x "$repo/bin/$owner"
  done
  for plugin in fm-primary-cd-check.js fm-primary-pretool-check.js; do
    out=$(PLUGIN="$ROOT/.opencode/plugins/$plugin" WORKTREE="$repo" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

let hook = null;
const ctx = {
  location: { project: { directory: process.env.WORKTREE } },
  tool: { hook: (name, fn) => { if (name === "execute.before") hook = fn; } },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default.setup(ctx);
const call = (tool, command) => hook({ tool, sessionID: "ses-1", id: "call-1", input: { command } });
let blocked = false;
try {
  await call("shell", "echo DENY_ME");
} catch (error) {
  blocked = String(error.message).includes("seatbelt denied");
}
if (!blocked) {
  console.error("the shell tool was not blocked");
  process.exit(1);
}
await call("shell", "echo allowed");
await call("mcp_runner", "echo DENY_ME");
await call("read", "echo DENY_ME");
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "OpenCode 2 $plugin must block the shell tool and never a non-shell tool carrying a command: $out"
  done
  pass "OpenCode 2 seatbelts block only the shell tool, never a non-shell or MCP tool carrying a command"
}

test_opencode2_prompt_session_never_resends_after_a_failed_attempt() {
  local out status
  out=$(LIB="$ROOT/.opencode/plugins/lib/fm-opencode2.js" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const { promptSession } = await import(pathToFileURL(process.env.LIB).href);
const calls = [];
const ctx = { session: { prompt: async (arg) => { calls.push(["prompt", arg]); throw new Error("timeout after delivery"); } } };
const client = { session: { promptAsync: async (arg) => { calls.push(["promptAsync", arg]); } } };
let threw = false;
try {
  await promptSession(ctx, client, "ses-1", "wake");
} catch {
  threw = true;
}
if (!threw || calls.length !== 1 || calls[0][1].sessionID !== "ses-1" || calls[0][1].text !== "wake") {
  console.error(JSON.stringify(calls));
  process.exit(1);
}
calls.length = 0;
await promptSession(null, client, "ses-2", "wake");
if (calls.length !== 1 || calls[0][1].path.id !== "ses-2" || calls[0][1].body.parts[0].text !== "wake") {
  console.error(JSON.stringify(calls));
  process.exit(1);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode promptSession must send once and never retry another shape: $out"
  pass "OpenCode promptSession sends one prompt shape and never resends after a failed attempt"
}

test_opencode_primary_watch_plugin_sources_effective_config() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-config-root"
  home="$TMP_ROOT/opencode-effective-config-home"
  log="$TMP_ROOT/opencode-effective-config.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  printf 'export FM_POLL=7\n' > "$home/config/x-mode.env"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'poll=%s\n' "${FM_POLL:-missing}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
if (!text.includes("poll=7")) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must source FM_HOME config outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-config test printed output: $out"
  pass "OpenCode watcher plugin sources the effective config"
}

test_opencode_primary_watch_plugin_requires_session_lock() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-lock-root"
  home="$TMP_ROOT/opencode-lock-home"
  log="$TMP_ROOT/opencode-lock.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
// Ownership is lost only to a LIVE foreign holder; an absent or dead legacy
// record belongs to this native home.
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${other.pid}\n`);
  await hooks.event(event);
  // The hook starts its attempt without awaiting it, and the plugin answers a
  // second attempt from the one already in flight. Join that attempt through
  // the coordinator rather than waiting a fixed span: refusing an unowned lock
  // walks git and ps probes that can outlast any such span, and the owned-lock
  // event below would then be answered from the refusal instead of arming.
  const refusal = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
  if (refusal !== "read-only") {
    console.error(`expected a read-only refusal under a live foreign holder, got ${refusal}`);
    process.exit(1);
  }
  if (existsSync(process.env.FM_ARM_LOG)) {
    console.error("watch arm ran without owning the session lock");
    process.exit(1);
  }
} finally {
  other.kill("SIGTERM");
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run after the session lock matched");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must arm only when this session owns the fleet lock"
  [ -z "$out" ] || fail "OpenCode session-lock test printed output: $out"
  pass "OpenCode watcher plugin requires session lock ownership"
}

test_opencode_watch_arm_coordinator_respects_primary_scope() {
  local plugin base repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  base="$TMP_ROOT/opencode-coordinator-base"
  repo="$TMP_ROOT/opencode-coordinator-wt"
  home="$TMP_ROOT/opencode-coordinator-home"
  log="$TMP_ROOT/opencode-coordinator.log"
  fm_git_worktree "$base" "$repo" fm/opencode-coordinator
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
await new Promise((resolve) => setTimeout(resolve, 120));
if (status !== "not-primary") {
  console.error(`expected not-primary, got ${status}`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("coordinator armed from a linked worktree");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch coordinator must keep primary scope checks in the shared arm path"
  [ -z "$out" ] || fail "OpenCode coordinator-scope test printed output: $out"
  pass "OpenCode watcher coordinator respects primary scope"
}

test_opencode_primary_watch_plugin_rearms_after_wake() {
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-rearm-root"
  home="$TMP_ROOT/opencode-rearm-home"
  log="$TMP_ROOT/opencode-rearm.log"
  stop="$TMP_ROOT/opencode-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
let rowsAtPrompt = 0;
let releasePrompt = () => {};
const promptBlocked = new Promise((resolve) => {
  releasePrompt = resolve;
});
const client = {
  session: {
    promptAsync: async () => {
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((row) => row.startsWith("arm=")).length
        : 0;
      prompts += 1;
      await promptBlocked;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && prompts >= 1) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
const armRows = rows.filter((row) => row.startsWith("arm="));
if (armRows.length !== 2) throw new Error(`expected one successor arm, got ${armRows.length}: ${rows.join(" | ")}`);
if (prompts !== 1) throw new Error(`expected one blocked wake prompt, got ${prompts}`);
if (rowsAtPrompt !== 2) throw new Error(`wake prompt began before successor establishment (${rowsAtPrompt} arm rows)`);
if (!/predecessor=[0-9]+/.test(armRows[1])) throw new Error(`successor did not receive predecessor identity: ${armRows[1]}`);
if (!rows.some((row) => row.startsWith("confirmed generation=fixture-generation"))) {
  throw new Error(`handling delivery was not confirmed before the follow-up: ${rows.join(" | ")}`);
}
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.filter((row) => row.startsWith("arm=")).length !== 2) {
  throw new Error(`blocked follow-up started extra arm work: ${stableRows.join(" | ")}`);
}
if (stableRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${stableRows.join(" | ")}`);
}
releasePrompt();
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "OpenCode watch plugin must start one successor before wake prompt delivery settles: $out"
  [ -z "$out" ] || fail "OpenCode rearm test printed output: $out"
  pass "OpenCode watcher plugin starts one successor before wake prompt delivery settles"
}

# An opted-in home spawns the supervision host in the arm's place; its
# streamed status line drives readiness and the handling handoff, and a
# handed-back wake is delivered with every host line and the away note.
test_opencode_primary_watch_plugin_runs_the_supervision_host() {  # [away|quiet]
  local kind=${1:-away} plugin repo home log stop out status f
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-host-root-$kind"
  home="$TMP_ROOT/opencode-host-home-$kind"
  log="$TMP_ROOT/opencode-host-$kind.log"
  stop="$TMP_ROOT/opencode-host-$kind.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  if [ "$kind" = quiet ]; then
    # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
    # QUIET): the plugin asks the record owner, so the same handback carries no
    # away note.
    for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$repo/bin/$f"; done
    FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
      || fail "fixture: could not record quiet mode"
  else
    : > "$home/state/.afk-contract"
  fi
  : > "$home/config/supervision-host"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$repo/bin/"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'plain-arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s args=%s primary=%s predecessor=%s\n' "$$" "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^host=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  sleep 0.3
  printf 'signal: synthetic wake\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\nsupervision-host: outcome 1 for demo [captain]: fixture\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" RECORD_KIND="$kind" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = { session: { promptAsync: async (request) => { prompts.push(request.body.parts[0].text); } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 400 && prompts.length < 1; i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
const rows = existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
if (rows.some((row) => row.startsWith("plain-arm="))) throw new Error(`an opted-in home ran the plain arm: ${rows.join(" | ")}`);
const hosts = rows.filter((row) => row.startsWith("host="));
if (hosts.length !== 2) throw new Error(`expected the host and one successor host, got: ${rows.join(" | ")}`);
if (!hosts.every((row) => / args=park --restart primary=opencode /.test(row))) throw new Error(`the host must run as 'park --restart' with the opencode pin: ${hosts.join(" | ")}`);
if (!/predecessor=[0-9]+$/.test(hosts[1])) throw new Error(`the successor host did not receive the closed host as its predecessor: ${hosts[1]}`);
if (!rows.some((row) => row === "confirmed generation=fixture-generation watcher=" + hosts[1].replace(/^host=([0-9]+).*/, "$1"))) {
  throw new Error(`the handling handoff was not confirmed against the successor host's cycle: ${rows.join(" | ")}`);
}
if (prompts.length !== 1) throw new Error(`expected one wake prompt, got ${prompts.length}`);
for (const needle of [
  "signal: synthetic wake",
  "supervision-host: the away session could not take this wake: fixture; this wake is yours",
  "supervision-host: outcome 1 for demo [captain]: fixture",
]) {
  if (!prompts[0].includes(needle)) throw new Error(`the wake prompt lacks '${needle}': ${prompts[0]}`);
}
const awayNote = prompts[0].includes("not from the captain: it is not a return");
if (process.env.RECORD_KIND === "quiet" ? awayNote : !awayNote) {
  throw new Error(`the away note must appear exactly under an away record (${process.env.RECORD_KIND}): ${prompts[0]}`);
}
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "OpenCode watch plugin must run the supervision host on an opted-in home ($kind record): $out"
  [ -z "$out" ] || fail "OpenCode host test printed output: $out"
  pass "OpenCode watcher plugin runs the supervision host on an opted-in home and relays every host line ($kind record)"
}

test_opencode_pre_ready_actionable_close_preserves_its_successor() {
  local plugin repo home log release retired stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-pre-ready-actionable-root"
  home="$TMP_ROOT/opencode-pre-ready-actionable-home"
  log="$TMP_ROOT/opencode-pre-ready-actionable.log"
  release="$TMP_ROOT/opencode-pre-ready-actionable.release"
  retired="$TMP_ROOT/opencode-pre-ready-actionable.retired"
  stop="$TMP_ROOT/opencode-pre-ready-actionable.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  printf 'signal: pre-ready successor wake\n'
  trap 'printf "retired\\n" > "${FM_PRE_READY_RETIRED_FILE:?}"; exit 0' TERM INT
  while [ ! -e "$FM_PRE_READY_RELEASE_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_PRE_READY_RELEASE_FILE="$release" FM_PRE_READY_RETIRED_FILE="$retired" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 500; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && prompts.some((message) => message.includes("original wake"))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`pre-ready successor was replaced before its close: ${rows.join(" | ")}`);
if (!prompts.some((message) => message.includes("original wake"))) throw new Error(`original actionable wake was not delivered: ${prompts.join(" | ")}`);
await new Promise((resolve) => setTimeout(resolve, 150));
if (existsSync(process.env.FM_PRE_READY_RETIRED_FILE)) throw new Error("pre-ready actionable successor was retired before its close");
writeFileSync(process.env.FM_PRE_READY_RELEASE_FILE, "release\n");
for (let i = 0; i < 500; i += 1) {
  const successorRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (successorRows.length >= 3 && prompts.some((message) => message.includes("pre-ready successor wake"))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 3) throw new Error(`pre-ready close did not create exactly one successor: ${stableRows.join(" | ")}`);
if (!prompts.some((message) => message.includes("pre-ready successor wake"))) throw new Error(`pre-ready actionable wake was not delivered: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must retire the pre-ready arm, not its actionable successor"
  [ -z "$out" ] || fail "OpenCode pre-ready actionable test printed output: $out"
  pass "OpenCode pre-ready actionable close preserves its successor"
}

test_opencode_hung_successor_falls_back_to_typed_wake() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-hung-successor-root"
  home="$TMP_ROOT/opencode-hung-successor-home"
  log="$TMP_ROOT/opencode-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
let rowsAtPrompt = 0;
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// Three unready successors each cost the full readiness budget, so wait well
// past their sum. The wait ends as soon as the wake lands.
for (let i = 0; i < 1500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 4) throw new Error(`expected one successor plus two retries, got ${rows.length}: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(`wake arrived before restoration exhausted (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must deliver the actionable wake after bounded hung-successor recovery"
  [ -z "$out" ] || fail "OpenCode hung-successor test printed output: $out"
  pass "OpenCode hung successor falls back to one typed actionable wake"
}

test_opencode_unretired_successor_falls_back_without_retry() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-unretired-successor-root"
  home="$TMP_ROOT/opencode-unretired-successor-home"
  log="$TMP_ROOT/opencode-unretired-successor.log"
  release="$TMP_ROOT/opencode-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ] && [ -e "$0" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
let rowsAtPrompt = 0;
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`unretired arm overlapped a retry: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(`wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must fall back without overlapping an unretired successor"
  [ -z "$out" ] || fail "OpenCode unretired-successor test printed output: $out"
  pass "OpenCode unretired successor falls back without an overlapping retry"
}

test_opencode_late_unretired_close_resumes_supervision() {
  local kind plugin repo home log ready retired release stop out status
  for kind in actionable non-actionable; do
    plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
    repo="$TMP_ROOT/opencode-late-$kind-root"
    home="$TMP_ROOT/opencode-late-$kind-home"
    log="$TMP_ROOT/opencode-late-$kind.log"
    ready="$TMP_ROOT/opencode-late-$kind.ready"
    retired="$TMP_ROOT/opencode-late-$kind.retired"
    release="$TMP_ROOT/opencode-late-$kind.release"
    stop="$TMP_ROOT/opencode-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    git init -q "$repo"
    : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
    : > "$home/state/task.meta"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  trap 'printf "retired\\n" > "${FM_UNRETIRED_RETIRE_FILE:?}"' TERM INT
  printf 'ready\n' > "${FM_UNRETIRED_READY_FILE:?}"
  while [ ! -e "$FM_RELEASE_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  for (let i = 0; i < 500; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_READY_FILE),
  "unretired successor did not enter its retirement wait",
);
await waitFor(() => prompts.length >= 1, "original fallback was not delivered");
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_RETIRE_FILE),
  "unretired successor was not asked to retire before fallback",
);
if (rows().length !== 2) throw new Error(`unretired arm overlapped before fallback: ${rows().join(" | ")}`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
for (let i = 0; i < 500; i += 1) {
  if (rows().length >= 3 && (process.env.FM_LATE_KIND !== "actionable" || prompts.some((message) => message.includes("late wake")))) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (rows().length !== 3) throw new Error(`late close did not restore one successor: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
    status=$?
    expect_code 0 "$status" "OpenCode late $kind close must remain supervised after fallback"
    [ -z "$out" ] || fail "OpenCode late-$kind test printed output: $out"
  done
  pass "OpenCode late unretired closes resume classified supervision"
}

test_opencode_empty_close_retries_instead_of_disappearing() {
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-empty-close-root"
  home="$TMP_ROOT/opencode-empty-close-home"
  log="$TMP_ROOT/opencode-empty-close.log"
  stop="$TMP_ROOT/opencode-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "OpenCode empty-close retry test printed output: $out"
  pass "OpenCode clean empty close triggers a bounded continuity retry"
}

test_opencode_established_empty_close_honors_retry_limit() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-established-empty-close-root"
  home="$TMP_ROOT/opencode-established-empty-close-home"
  log="$TMP_ROOT/opencode-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "OpenCode established-empty-close retry test printed output: $out"
  pass "OpenCode established clean closes stop at the configured retry limit"
}

test_opencode_actionable_close_rechecks_session_lock() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-close-lock-root"
  home="$TMP_ROOT/opencode-close-lock-home"
  log="$TMP_ROOT/opencode-close-lock.log"
  release="$TMP_ROOT/opencode-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const eventPromise = hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  await eventPromise;
  for (let i = 0; i < 250 && !prompt.includes("no longer owns the lock"); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode close handler must verify session-lock ownership before successor launch"
  [ -z "$out" ] || fail "OpenCode close lock test printed output: $out"
  pass "OpenCode close handler verifies session-lock ownership before successor launch"
}

test_opencode_watch_arm_coordinates_with_turnend_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-coordinate-root"
  home="$TMP_ROOT/opencode-coordinate-home"
  log="$TMP_ROOT/opencode-coordinate-arm.log"
  guard_log="$TMP_ROOT/opencode-coordinate-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard should not run\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard ran before the watch arm could establish supervision");
  process.exit(1);
}
if (promptBody) {
  console.error(`unexpected prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode turn-end guard must let the auto-arm plugin establish supervision first"
  [ -z "$out" ] || fail "OpenCode coordination test printed output: $out"
  pass "OpenCode watcher plugin coordinates with the turn-end guard"
}

test_opencode_healthy_arm_output_does_not_suppress_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-external-healthy-root"
  home="$TMP_ROOT/opencode-external-healthy-home"
  log="$TMP_ROOT/opencode-external-healthy-arm.log"
  guard_log="$TMP_ROOT/opencode-external-healthy-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard ran after external healthy watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_GUARD_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (!readFileSync(process.env.FM_ARM_LOG, "utf8").includes("args=--restart")) {
  console.error("watch arm was not asked to restart into an owned child");
  process.exit(1);
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard was suppressed by an external healthy watcher");
  process.exit(1);
}
if (!promptBody.includes("TURN WOULD END BLIND")) {
  console.error(`missing blind-turn prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must not treat external healthy output as an owned arm"
  [ -z "$out" ] || fail "OpenCode external-healthy test printed output: $out"
  pass "OpenCode healthy arm output does not suppress the turn-end guard"
}

# Both OpenCode plugin writes to a child's stdin can fail with EPIPE, because
# the child is free to exit without reading. An unhandled stdin error is a
# thrown 'error' event that takes the whole host process down with it. Here the
# guard's own blind-turn text is larger than a pipe buffer, so the write to an
# encoder that exits without reading cannot complete: the guard must report the
# encoder's refusal by staying silent, not by killing the session.
test_opencode_turnend_guard_survives_an_encoder_that_never_reads_stdin() {
  local guard_plugin repo guard_log out status
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-guard-encoder-root"
  guard_log="$TMP_ROOT/opencode-guard-encoder-guard.log"
  mkdir -p "$repo/bin"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'watcher: FAILED - %s\n' "$(head -c 200000 /dev/zero | tr '\0' 'x')" >&2
exit 2
SH
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
printf 'operational-input: refused\n' >&2
exit 1
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-operational-input.sh"
  out=$(GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard did not run");
  process.exit(1);
}
if (prompts !== 0) {
  console.error(`guard prompted ${prompts} times despite an encoder that refused the input`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode turn-end guard must survive an encoder that never reads its stdin ($out)"
  [ -z "$out" ] || fail "OpenCode guard encoder test printed output: $out"
  pass "OpenCode turn-end guard survives an encoder that never reads stdin"
}
