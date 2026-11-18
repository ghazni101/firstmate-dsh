# shellcheck shell=bash
# Test cases for fm-pi-watch-extension, split out of tests/fm-pi-watch-extension.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-pi-watch-extension.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


# A superseded confirmation is not a failure, so the wake routes exactly like
# a confirmed delivery: an accepting supervision branch owns it and main gets
# no follow-up. The same fixture with the confirmation succeeding is the
# control, so the case cannot go vacuous.
test_pi_superseded_delivery_is_offered_to_branch() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-superseded-branch-root"
  home="$TMP_ROOT/pi-superseded-branch-home"
  log="$TMP_ROOT/pi-superseded-branch.log"
  stop="$TMP_ROOT/pi-superseded-branch.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirm generation=%s watcher=%s status=%s\n' "$2" "$4" "${FM_CONFIRM_STATUS:?}" >> "${FM_ARM_LOG:?}"
  exit "$FM_CONFIRM_STATUS"
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: superseded synthetic wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

async function runScenario(confirmStatus) {
  process.env.FM_CONFIRM_STATUS = String(confirmStatus);
  writeFileSync(process.env.FM_ARM_LOG, "");
  const offers = [];
  let mainPrompt = "";
  let tool = null;
  const handlers = new Map();
  const bus = {
    on(channel, handler) {
      handlers.set(channel, [...(handlers.get(channel) ?? []), handler]);
      return () => {};
    },
    emit(channel, data) {
      for (const handler of handlers.get(channel) ?? []) handler(data);
    },
  };
  bus.on("fm-branch-supervision:dispatch", (offer) => {
    offers.push(offer.message);
    offer.accept();
  });
  const pi = {
    on() {},
    events: bus,
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async (message) => {
      mainPrompt += message;
    },
  };
  const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?confirm=${confirmStatus}`);
  mod.default(pi);
  await tool.execute(`tool-call-superseded-branch-${confirmStatus}`, {}, undefined, undefined, {});
  for (let i = 0; i < 250 && offers.length === 0 && mainPrompt === ""; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  return { offers, mainPrompt, rows };
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/superseded-branch.meta`, "project=/projects/approved\nwindow=fm-superseded-branch\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\tsuperseded-branch.status\tsignal: superseded synthetic wake\n");
for (const confirmStatus of [0, 3]) {
  const result = await runScenario(confirmStatus);
  if (!result.rows.some((row) => row.startsWith("confirm ") && row.endsWith(`status=${confirmStatus}`))) {
    throw new Error(`confirm status ${confirmStatus} was never exercised: ${result.rows.join(" | ")}`);
  }
  if (result.offers.length !== 1) {
    throw new Error(`confirm status ${confirmStatus}: expected one branch offer, got ${result.offers.length}; main got: ${result.mainPrompt}`);
  }
  if (!result.offers[0].includes("signal: superseded synthetic wake")) {
    throw new Error(`confirm status ${confirmStatus}: offer missed the wake reason: ${result.offers[0]}`);
  }
  if (result.offers[0].includes("handling delivery confirmation was rejected")) {
    throw new Error(`confirm status ${confirmStatus}: offer carried a rejection appendix: ${result.offers[0]}`);
  }
  if (result.mainPrompt !== "") {
    throw new Error(`confirm status ${confirmStatus}: accepted offer still reached main: ${result.mainPrompt}`);
  }
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must offer a superseded wake to the branch exactly like a confirmed one: $out"
  [ -z "$out" ] || fail "Pi superseded branch-offer test printed output: $out"
  pass "Pi superseded handling delivery is offered to the branch like a confirmed one"
}

# The extension diagnostic log is opt-in and default-off: the same
# mid-restore supersession that logs when opted in must create no
# state/.watch-extension.log file with the knob unset, zero, or
# non-numeric, while the wake is still delivered with no rejection
# appendix. Each knob value runs in a fresh home because the extension
# reads the knob once at module load.
test_pi_extension_log_stays_off_unless_opted_in() {
  local repo driver mode home log stop extension_log knob_value out status
  repo="$TMP_ROOT/pi-extension-log-off-root"
  driver="$TMP_ROOT/pi-extension-log-off-driver.mjs"
  mkdir -p "$repo/bin"
  install_pi_watch_extension_fixture "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'superseded generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 3
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  cat > "$driver" <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-handling-superseded", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt.includes("FIRSTMATE WATCHER WAKE"); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) throw new Error(`missing follow-up: ${prompt}`);
if (prompt.includes("handling delivery confirmation was rejected")) {
  throw new Error(`a superseded delivery carried a rejection appendix: ${prompt}`);
}
if ((prompt.match(/FIRSTMATE WATCHER WAKE/g) || []).length !== 1) {
  throw new Error(`a superseded delivery was not a single plain message: ${prompt}`);
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.filter((row) => row.startsWith("superseded ")).length < 1) {
  throw new Error(`handling-delivered was never attempted: ${rows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  for mode in unset zero bogus; do
    home="$TMP_ROOT/pi-extension-log-off-home-$mode"
    log="$TMP_ROOT/pi-extension-log-off-$mode.log"
    stop="$TMP_ROOT/pi-extension-log-off-$mode.stop"
    extension_log="$home/state/.watch-extension.log"
    mkdir -p "$home/state" "$home/config"
    if [ "$mode" = unset ]; then
      out=$(PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node "$driver" 2>&1)
    else
      if [ "$mode" = zero ]; then knob_value=0; else knob_value="not-a-number"; fi
      out=$(PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_EXTENSION_LOG_KEEP_LINES="$knob_value" node "$driver" 2>&1)
    fi
    status=$?
    expect_code 0 "$status" "Pi superseded delivery must still succeed with the log $mode: $out"
    [ -z "$out" ] || fail "Pi log-off ($mode) run printed output: $out"
    [ ! -e "$extension_log" ] || fail "Pi extension wrote its diagnostic log with the knob $mode: $(cat "$extension_log")"
  done
  pass "Pi extension diagnostic log stays off unless opted in"
}

# A repair call must not no-op on an arm child whose process is already dead
# while its close event is still pending (stdio pipe held): the first arm
# below exits at once but leaves a pipe holder behind, so the extension still
# holds the handle with no close fired. The repair must not fail over the dead
# arm, and a second arm follows without another call.
test_pi_repair_starts_fresh_arm_over_dead_child() {
  local repo home plugin log stop holder out status
  repo="$TMP_ROOT/pi-stale-child-root"
  home="$TMP_ROOT/pi-stale-child-home"
  log="$TMP_ROOT/pi-stale-child.log"
  stop="$TMP_ROOT/pi-stale-child.stop"
  holder="$TMP_ROOT/pi-stale-child-holder.sh"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$holder" <<'SH'
#!/usr/bin/env bash
while [ ! -e "${1:?}" ] && [ -e "$0" ]; do sleep 0.05; done
SH
  chmod +x "$holder"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
  ("${FM_HOLDER:?}" "${FM_STOP_FILE:?}" >&1 2>/dev/null &)
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_HOLDER="$holder" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const first = await tool.execute("tool-call-first-arm", {}, undefined, undefined, {});
if (!first.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`first arm did not start: ${first.content[0].text}`);
}
const armRows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
let armPid = "";
for (let i = 0; i < 250 && !armPid; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
  const row = armRows().find((line) => line.startsWith("arm="));
  if (row) armPid = row.split(" ")[0].slice("arm=".length);
}
if (!armPid) throw new Error("first arm never logged its pid");
let dead = false;
for (let i = 0; i < 250 && !dead; i += 1) {
  try {
    process.kill(Number(armPid), 0);
  } catch {
    dead = true;
  }
  if (!dead) await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!dead) throw new Error(`first arm pid ${armPid} never exited`);
const second = await tool.execute("tool-call-repair", {}, undefined, undefined, {});
const text = second.content[0].text;
if (text.includes("FAILED")) {
  throw new Error(`repair failed over a dead child: ${text}`);
}
let rearmed = false;
for (let i = 0; i < 250 && !rearmed; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
  rearmed = armRows().filter((line) => line.startsWith("arm=")).length >= 2;
}
if (!rearmed) {
  throw new Error(`repair started no second arm: ${armRows().join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi repair must start a fresh arm over a dead child handle: $out"
  [ -z "$out" ] || fail "Pi stale-child repair test printed output: $out"
  pass "Pi repair starts a fresh arm instead of no-opping on a dead child"
}

# A scheduled continuity retry must not stall behind a dead-but-unclosed arm
# child. The first arm exits with its stdout held open, the next arm (from the
# exit's retry or a manual repair) does the same, and then the first arm's
# close finally fires: continuity must still reach a fresh live arm.
test_pi_scheduled_retry_starts_fresh_arm_over_dead_child() {
  local repo home plugin log stop release out status
  repo="$TMP_ROOT/pi-retry-dead-root"
  home="$TMP_ROOT/pi-retry-dead-home"
  log="$TMP_ROOT/pi-retry-dead.log"
  stop="$TMP_ROOT/pi-retry-dead.stop"
  release="$TMP_ROOT/pi-retry-dead.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  (while [ ! -e "${FM_RELEASE_FILE:?}" ] && [ -e "$0" ]; do sleep 0.02; done) &
  exit 0
fi
if [ "$count" -eq 2 ]; then
  (while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.05; done) &
  exit 0
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_RELEASE_FILE="$release" FM_WATCH_REARM_RETRY_BASE_MS=20 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const armRows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((row) => row.startsWith("arm="))
  : [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitForArms(count) {
  for (let i = 0; i < 250 && armRows().length < count; i += 1) await sleep(20);
  if (armRows().length < count) throw new Error(`expected ${count} arms: ${armRows().join(" | ")}`);
  return Number(armRows()[count - 1].slice("arm=".length));
}
async function waitForExit(pid) {
  for (let i = 0; i < 250; i += 1) {
    try {
      process.kill(pid, 0);
    } catch {
      return;
    }
    await sleep(20);
  }
  throw new Error(`arm pid ${pid} never exited`);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-retry-dead-first", {}, undefined, undefined, {});
await waitForExit(await waitForArms(1));
const repair = await tool.execute("tool-call-retry-dead-repair", {}, undefined, undefined, {});
if (repair.content[0].text.includes("FAILED")) {
  throw new Error(`repair failed over the dead first arm: ${repair.content[0].text}`);
}
await waitForExit(await waitForArms(2));
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
for (let i = 0; i < 250 && armRows().length < 3; i += 1) await sleep(20);
if (armRows().length !== 3) {
  throw new Error(`the first arm's close scheduled no retry over the dead second arm: ${armRows().join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi scheduled retry must start a fresh arm over a dead child handle: $out"
  [ -z "$out" ] || fail "Pi scheduled-retry dead-child test printed output: $out"
  pass "Pi scheduled retry starts a fresh arm instead of stalling on a dead child"
}

# A verified successor that closes while its wake is still being delivered
# defers its retry to the end of that delivery. If a manual repair meanwhile
# left a dead-but-unclosed arm in the slot, the deferred retry must still
# start a fresh arm.
test_pi_deferred_close_starts_fresh_arm_over_dead_child() {
  local repo home plugin log stop release out status
  repo="$TMP_ROOT/pi-deferred-dead-root"
  home="$TMP_ROOT/pi-deferred-dead-home"
  log="$TMP_ROOT/pi-deferred-dead.log"
  stop="$TMP_ROOT/pi-deferred-dead.stop"
  release="$TMP_ROOT/pi-deferred-dead.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
  while [ ! -e "${FM_RELEASE_FILE:?}" ] && [ -e "$0" ]; do sleep 0.02; done
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 3 ]; then
  (while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.05; done) &
  exit 0
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_RELEASE_FILE="$release" FM_WATCH_REARM_RETRY_BASE_MS=20 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveryStarted = false;
let finishDelivery = () => {};
const deliveryHeld = new Promise((resolve) => {
  finishDelivery = resolve;
});
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    deliveryStarted = true;
    await deliveryHeld;
  },
};
const armRows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((row) => row.startsWith("arm="))
  : [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitForArms(count) {
  for (let i = 0; i < 250 && armRows().length < count; i += 1) await sleep(20);
  if (armRows().length < count) throw new Error(`expected ${count} arms: ${armRows().join(" | ")}`);
  return Number(armRows()[count - 1].slice("arm=".length));
}
async function waitForExit(pid) {
  for (let i = 0; i < 250; i += 1) {
    try {
      process.kill(pid, 0);
    } catch {
      return;
    }
    await sleep(20);
  }
  throw new Error(`arm pid ${pid} never exited`);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-deferred-dead-first", {}, undefined, undefined, {});
const successorPid = await waitForArms(2);
for (let i = 0; i < 250 && !deliveryStarted; i += 1) await sleep(20);
if (!deliveryStarted) throw new Error("the restored wake was never delivered");
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await waitForExit(successorPid);
await sleep(100);
const repair = await tool.execute("tool-call-deferred-dead-repair", {}, undefined, undefined, {});
if (!repair.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`repair did not start an arm after the successor closed: ${repair.content[0].text}`);
}
await waitForExit(await waitForArms(3));
finishDelivery();
for (let i = 0; i < 250 && armRows().length < 4; i += 1) await sleep(20);
if (armRows().length !== 4) {
  throw new Error(`the deferred close started no retry over the dead repair arm: ${armRows().join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi deferred close must start a fresh arm over a dead child handle: $out"
  [ -z "$out" ] || fail "Pi deferred-close dead-child test printed output: $out"
  pass "Pi deferred close starts a fresh arm instead of stalling on a dead child"
}

test_pi_hung_successor_falls_back_to_typed_wake() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-hung-successor-root"
  home="$TMP_ROOT/pi-hung-successor-home"
  log="$TMP_ROOT/pi-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-hung-successor", {}, undefined, undefined, {});
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
  expect_code 0 "$status" "Pi must deliver the actionable wake after bounded hung-successor recovery"
  [ -z "$out" ] || fail "Pi hung-successor test printed output: $out"
  pass "Pi hung successor falls back to one typed actionable wake"
}

test_pi_unretired_successor_falls_back_without_retry() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-unretired-successor-root"
  home="$TMP_ROOT/pi-unretired-successor-home"
  log="$TMP_ROOT/pi-unretired-successor.log"
  release="$TMP_ROOT/pi-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-unretired-successor", {}, undefined, undefined, {});
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
  expect_code 0 "$status" "Pi must fall back without overlapping an unretired successor"
  [ -z "$out" ] || fail "Pi unretired-successor test printed output: $out"
  pass "Pi unretired successor falls back without an overlapping retry"
}

test_pi_late_unretired_close_resumes_supervision() {
  local kind repo home plugin log ready retired release stop out status
  for kind in actionable non-actionable; do
    repo="$TMP_ROOT/pi-late-$kind-root"
    home="$TMP_ROOT/pi-late-$kind-home"
    log="$TMP_ROOT/pi-late-$kind.log"
    ready="$TMP_ROOT/pi-late-$kind.ready"
    retired="$TMP_ROOT/pi-late-$kind.retired"
    release="$TMP_ROOT/pi-late-$kind.release"
    stop="$TMP_ROOT/pi-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    install_pi_watch_extension_fixture "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
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
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  // Nothing here consumes the follow-up: continuity must not depend on it.
  sendUserMessage: async (message) => {
    prompts.push(message);
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
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-late-close", {}, undefined, undefined, {});
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
    expect_code 0 "$status" "Pi late $kind close must remain supervised after fallback"
    [ -z "$out" ] || fail "Pi late-$kind test printed output: $out"
  done
  pass "Pi late unretired closes resume classified supervision"
}

test_pi_empty_close_retries_instead_of_disappearing() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-empty-close-root"
  home="$TMP_ROOT/pi-empty-close-home"
  log="$TMP_ROOT/pi-empty-close.log"
  stop="$TMP_ROOT/pi-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompts = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    prompts += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-empty", {}, undefined, undefined, {});
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
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "Pi empty-close retry test printed output: $out"
  pass "Pi clean empty close triggers a bounded continuity retry"
}

test_pi_established_empty_close_honors_retry_limit() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-established-empty-close-root"
  home="$TMP_ROOT/pi-established-empty-close-home"
  log="$TMP_ROOT/pi-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-established-empty", {}, undefined, undefined, {});
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
  expect_code 0 "$status" "Pi established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "Pi established-empty-close retry test printed output: $out"
  pass "Pi established clean closes stop at the configured retry limit"
}

test_pi_actionable_close_rechecks_session_lock() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-close-lock-root"
  home="$TMP_ROOT/pi-close-lock-home"
  log="$TMP_ROOT/pi-close-lock.log"
  release="$TMP_ROOT/pi-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-lock-close", {}, undefined, undefined, {});
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
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
  [ "$status" -eq 0 ] || fail "Pi close handler must verify session-lock ownership before successor launch: $out"
  [ -z "$out" ] || fail "Pi close lock test printed output: $out"
  pass "Pi close handler verifies session-lock ownership before successor launch"
}

test_pi_arm_distinguishes_session_lock_ownership() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-lock-ownership-root"
  home="$TMP_ROOT/pi-lock-ownership-home"
  log="$TMP_ROOT/pi-lock-ownership.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");

const lock = `${process.env.FM_HOME}/state/.lock`;
const callArm = () => tool.execute("tool-call-lock", {}, undefined, undefined, {});
// A home with no legacy record, a malformed one, or a provably dead holder is
// this session's native home: the arm starts. Only a LIVE legacy holder this
// process does not descend from still refuses.
const expectOwned = (result, label) => {
  if (result.details?.ok !== true) {
    throw new Error(`${label} did not arm under native ownership: ${JSON.stringify(result.details)}`);
  }
  if (result.details.message.includes("held by another firstmate session")) {
    throw new Error(`${label} was misreported as a live other holder: ${result.details.message}`);
  }
};

if (existsSync(lock)) unlinkSync(lock);
expectOwned(await callArm(), "absent lock");
writeFileSync(lock, "999999\n");
expectOwned(await callArm(), "dead lock holder");
for (const value of ["unknown\n", "1\n", "2\n3\n"]) {
  writeFileSync(lock, value);
  expectOwned(await callArm(), `malformed lock ${JSON.stringify(value)}`);
}

const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  const liveOther = await callArm();
  if (liveOther.details?.ok !== false) throw new Error(`live other holder unexpectedly armed: ${JSON.stringify(liveOther.details)}`);
  if (liveOther.details.message !== "watcher: read-only - a legacy session lock is held by another live firstmate session") {
    throw new Error(`unexpected live-other response: ${liveOther.details.message}`);
  }
} finally {
  other.kill("SIGTERM");
}

if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("no watcher arm ran for any owned lock state");
writeFileSync(lock, `${process.pid}\n`);
const owned = await callArm();
if (owned.details?.ok !== true) throw new Error(`owned lock did not arm: ${JSON.stringify(owned.details)}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher arm must own absent, malformed, or dead locks and refuse only a live other holder"
  [ -z "$out" ] || fail "Pi lock-ownership arm test printed output: $out"
  pass "Pi watcher arm owns absent, malformed, or dead locks and refuses only a live other holder"
}

# On Windows the session lock may hold a tagged win:<pid> (bin/fm-proc-lib.sh),
# and native Node sees that Windows pid directly, so the arm reads a tagged holder
# by its digits. A malformed tag, a dead holder, and any tag off Windows are no
# usable foreign owner, so they fall back to native ownership; only a LIVE other
# tagged holder refuses. The platform is set per call so every host exercises
# both sides.
test_pi_arm_reads_a_windows_tagged_session_lock() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-tagged-lock-root"
  home="$TMP_ROOT/pi-tagged-lock-home"
  log="$TMP_ROOT/pi-tagged-lock.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");

const lock = `${process.env.FM_HOME}/state/.lock`;
const platform = Object.getOwnPropertyDescriptor(process, "platform");
async function armOn(name, value) {
  writeFileSync(lock, `${value}\n`);
  Object.defineProperty(process, "platform", { ...platform, value: name });
  try {
    return await tool.execute("tool-call-tagged-lock", {}, undefined, undefined, {});
  } finally {
    Object.defineProperty(process, "platform", platform);
  }
}
const otherHolder = "watcher: read-only - a legacy session lock is held by another live firstmate session";
const expectOwned = (result, label) => {
  if (result.details?.ok !== true) throw new Error(`${label} did not arm under native ownership: ${JSON.stringify(result.details)}`);
  if (result.details.message.includes("held by another firstmate session")) {
    throw new Error(`${label} was misreported as a live other holder: ${result.details.message}`);
  }
};

const dead = spawnSync(process.execPath, ["-e", "0"], { stdio: "ignore" }).pid;
expectOwned(await armOn("win32", `win:${dead}`), "a dead tagged holder");
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  const liveOther = await armOn("win32", `win:${other.pid}`);
  if (liveOther.details?.ok !== false) throw new Error(`a live other tagged holder unexpectedly armed: ${JSON.stringify(liveOther.details)}`);
  if (liveOther.details.message !== otherHolder) throw new Error(`a live other tagged holder gave the wrong refusal: ${liveOther.details.message}`);
} finally {
  other.kill("SIGTERM");
}
for (const value of ["win:", `win:${process.pid}x`, `WIN:${process.pid}`, "win:1"]) {
  expectOwned(await armOn("win32", value), `the malformed tagged lock ${value}`);
}
expectOwned(await armOn("linux", `win:${process.pid}`), "a tagged lock off Windows");

const owned = await armOn("win32", `win:${process.pid}`);
if (owned.details?.ok !== true) throw new Error(`an owned tagged lock did not arm: ${JSON.stringify(owned.details)}`);
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("an owned tagged lock did not run the watcher arm");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher arm owns dead or malformed tagged locks and refuses only a live other tagged holder"
  [ -z "$out" ] || fail "Pi tagged-lock arm test printed output: $out"
  pass "Pi watcher arm owns dead or malformed tagged locks and refuses only a live other tagged holder"
}

# A Pi command started from inside the live session, such as the `pi --help`
# capability probe, auto-loads this extension too and passes the ancestor walk
# in lockOwnership. Its pid dies at once, so the marker must stay on the live
# session above it, generation line included, while a dead or foreign marker pid
# is still replaced.
test_pi_extension_keeps_marker_of_live_ancestor_session() {
  local repo home plugin marker_case out status
  repo="$TMP_ROOT/pi-marker-guard-root"
  home="$TMP_ROOT/pi-marker-guard-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  for marker_case in nested dead foreign fresh; do
    rm -f "$home/state/.pi-watch-extension-loaded"
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" MARKER_CASE="$marker_case" node --input-type=module 2>&1 <<'EOF'
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const marker = `${process.env.FM_HOME}/state/.pi-watch-extension-loaded`;
const version = `sha256:${createHash("sha256").update(readFileSync(process.env.PLUGIN)).digest("hex")}`;
// The lock names the parent of this process: a live strict ancestor, exactly where
// the real session sits above a nested `pi --help`.
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.ppid}\n`);

const pi = {
  on() {},
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async () => {},
};
async function load() {
  const mod = await import(pathToFileURL(process.env.PLUGIN).href);
  mod.default(pi);
}
function expectBoundToThisProcess(label) {
  const lines = readFileSync(marker, "utf8").split("\n");
  if (
    lines.length !== 4 || lines[3] !== "" ||
    lines[0] !== version ||
    lines[1] !== String(process.pid) ||
    !/^generation=[1-9][0-9]* phase=active$/.test(lines[2])
  ) {
    throw new Error(`${label}: marker was not bound to this process: ${JSON.stringify(lines.join("\n"))}`);
  }
}
function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

switch (process.env.MARKER_CASE) {
  case "nested": {
    const before = `${version}\n${process.ppid}\ngeneration=7 phase=active\n`;
    writeFileSync(marker, before);
    await load();
    const after = readFileSync(marker, "utf8");
    if (after !== before) throw new Error(`nested load replaced the marker of the live session: ${JSON.stringify(after)}`);
    break;
  }
  case "dead": {
    const dead = spawnSync(process.execPath, ["-e", "0"], { stdio: "ignore" }).pid;
    if (!dead || pidAlive(dead)) throw new Error(`could not produce a dead pid (got ${dead})`);
    writeFileSync(marker, `${version}\n${dead}\ngeneration=7 phase=active\n`);
    await load();
    expectBoundToThisProcess("marker on a dead pid");
    break;
  }
  case "foreign": {
    const foreign = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
    try {
      writeFileSync(marker, `${version}\n${foreign.pid}\ngeneration=7 phase=active\n`);
      await load();
      expectBoundToThisProcess("marker on a live non-ancestor pid");
    } finally {
      foreign.kill("SIGTERM");
    }
    break;
  }
  case "fresh": {
    if (existsSync(marker)) throw new Error("fresh case started with a marker present");
    await load();
    expectBoundToThisProcess("fresh load");
    break;
  }
  default:
    throw new Error(`unknown marker case: ${process.env.MARKER_CASE}`);
}
EOF
)
    status=$?
    [ "$status" = 0 ] || fail "Pi watch marker guard failed for the '$marker_case' case (exit $status): $out"
    [ -z "$out" ] || fail "Pi watch marker guard '$marker_case' case printed output: $out"
  done
  pass "Pi watch extension: a nested load keeps the live session's watch marker"
}

test_pi_session_transition_generation_owner() {
  local repo home plugin child_pid_file child_marker_file marker_root arm_log fail_once out status
  repo="$TMP_ROOT/pi-session-transition-root"
  home="$TMP_ROOT/pi-session-transition-home"
  child_pid_file="$TMP_ROOT/pi-session-transition-child.pid"
  child_marker_file="$TMP_ROOT/pi-session-transition-child.marker"
  marker_root="$TMP_ROOT/pi-session-transition-markers"
  arm_log="$TMP_ROOT/pi-session-transition-arm.log"
  fail_once="$TMP_ROOT/pi-session-transition-fail-once"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$marker_root"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# Model the real --restart arm taking over from the still-live replacement
# predecessor only after this successor process has been committed.
previous=$(cat "${FM_CHILD_PID_FILE:?}" 2>/dev/null || true)
if [ -n "$previous" ] && kill -0 "$previous" 2>/dev/null; then
  kill -TERM "$previous" 2>/dev/null || true
fi
if [ -f "${FM_FAIL_ONCE:?}" ]; then
  rm -f "$FM_FAIL_ONCE"
  printf 'failed-replacement-attempt\n' >> "${FM_ARM_LOG:?}"
  printf 'watcher: FAILED - simulated replacement launch failure\n' >&2
  exit 7
fi
# The marker identifies this exact process lifetime after its PID is recycled.
marker=$(mktemp "${FM_MARKER_ROOT:?}/arm.XXXXXX") || exit 1
cleanup() { rm -f "$marker"; }
trap cleanup EXIT
trap 'exit 0' TERM INT
printf 'watcher: started pid=%s\n' "$$"
printf '%s\n' "$$" > "${FM_CHILD_PID_FILE:?}"
printf '%s\n' "$marker" > "${FM_CHILD_MARKER_FILE:?}"
printf 'arm pid=%s marker=%s\n' "$$" "$marker" >> "${FM_ARM_LOG:?}"
while [ -e "$0" ]; do sleep 0.2; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CHILD_PID_FILE="$child_pid_file" FM_CHILD_MARKER_FILE="$child_marker_file" FM_MARKER_ROOT="$marker_root" FM_ARM_LOG="$arm_log" FM_FAIL_ONCE="$fail_once" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

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
    events: { on() {} },
  };
  return { pi, handlers, getTool: () => tool };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(pred, label, attempts = 250) {
  for (let i = 0; i < attempts; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timeout waiting for ${label}`);
}

function currentArm() {
  try {
    return {
      pid: readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim(),
      marker: readFileSync(process.env.FM_CHILD_MARKER_FILE, "utf8").trim(),
    };
  } catch {
    return { pid: "", marker: "" };
  }
}

function extensionOwner() {
  const path = `${process.env.FM_HOME}/state/.pi-watch-extension-loaded`;
  try {
    return readFileSync(path, "utf8").trim().split("\n")[2] ?? "";
  } catch {
    return "";
  }
}

function liveArmPids() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split(/\n/)
    .filter(Boolean)
    .map((line) => {
      const match = /pid=(\d+) marker=(\S+)/.exec(line);
      return match ? { pid: match[1], marker: match[2] } : { pid: "", marker: "" };
    })
    .filter((arm) => arm.pid && arm.marker && existsSync(arm.marker) && pidAlive(arm.pid))
    .map((arm) => arm.pid);
}

const mod = await import(pathToFileURL(process.env.PLUGIN).href);

const startup = makePi();
mod.default(startup.pi);
if (!/^generation=[1-9][0-9]* phase=active$/.test(extensionOwner())) {
  throw new Error(`extension bind did not publish its pre-lock active generation: ${extensionOwner()}`);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await startup.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
await waitFor(() => {
  const arm = currentArm();
  return arm.pid && arm.marker && existsSync(arm.marker) && pidAlive(arm.pid);
}, "startup child");
const { pid: startupChild, marker: startupMarker } = currentArm();
if (!pidAlive(startupChild)) throw new Error("startup child was not alive");
if (!/^generation=[1-9][0-9]* phase=active$/.test(extensionOwner())) {
  throw new Error(`startup did not publish an active generation owner: ${extensionOwner()}`);
}
const staleTool = startup.getTool();

async function replaceSession(previous, reason) {
  const previousArm = currentArm();
  const previousOwner = extensionOwner();
  const previousGeneration = /^generation=([1-9][0-9]*) phase=active$/.exec(previousOwner)?.[1];
  if (!previousGeneration) throw new Error(`${reason} predecessor had no active generation owner: ${previousOwner}`);
  await previous.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason }, {});
  if (!previousArm.marker || !existsSync(previousArm.marker) || !pidAlive(previousArm.pid)) {
    throw new Error(`${reason} shutdown retired the old generation before a successor owned recovery`);
  }
  if (extensionOwner() !== `generation=${previousGeneration} phase=handoff`) {
    throw new Error(`${reason} shutdown did not publish its generation handoff: ${extensionOwner()}`);
  }
  const next = makePi();
  mod.default(next.pi);
  await next.handlers.get("session_start")?.({
    type: "session_start",
    reason,
    previousSessionFile: `/tmp/previous-${reason}.jsonl`,
  }, {});
  await waitFor(() => {
    const arm = currentArm();
    return arm.pid && arm.marker && arm.marker !== previousArm.marker && existsSync(arm.marker) && pidAlive(arm.pid) && liveArmPids().includes(arm.pid);
  }, `${reason} replacement child and arm record`);
  await waitFor(() => !existsSync(previousArm.marker), `${reason} previous child exit after successor claim`);
  const nextOwner = extensionOwner();
  const nextGeneration = /^generation=([1-9][0-9]*) phase=active$/.exec(nextOwner)?.[1];
  if (!nextGeneration || nextGeneration === previousGeneration) {
    throw new Error(`${reason} successor did not claim a distinct active generation: ${nextOwner}`);
  }
  const live = liveArmPids();
  if (live.length !== 1) {
    throw new Error(`${reason} expected exactly one live arm child, got ${live.join(",") || "(none)"}`);
  }
  const redundant = await next.getTool().execute(`redundant-${reason}`, {}, undefined, undefined, {});
  if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
    throw new Error(`${reason} replacement lost automatic arm ownership: ${JSON.stringify(redundant.details)}`);
  }
  return next;
}

let current = await replaceSession(startup, "new");
current = await replaceSession(current, "resume");
current = await replaceSession(current, "fork");
current = await replaceSession(current, "reload");

// A replacement that kills the predecessor but fails before watcher readiness
// remains generation-owned and reaches its bounded automatic retry.
writeFileSync(process.env.FM_FAIL_ONCE, "fail once\n");
current = await replaceSession(current, "resume");
if (!readFileSync(process.env.FM_ARM_LOG, "utf8").includes("failed-replacement-attempt")) {
  throw new Error("replacement launch failure did not exercise automatic retry");
}

// Same bound instance: ordinary shutdown then session_start without a fresh factory.
const sameInstanceArm = currentArm();
const sameInstanceGeneration = /^generation=([1-9][0-9]*) phase=active$/.exec(extensionOwner())?.[1];
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
if (!sameInstanceArm.marker || !existsSync(sameInstanceArm.marker) || !pidAlive(sameInstanceArm.pid)) {
  throw new Error("same-instance shutdown retired the old generation before its replacement started");
}
if (!sameInstanceGeneration || extensionOwner() !== `generation=${sameInstanceGeneration} phase=handoff`) {
  throw new Error(`same-instance shutdown did not publish its handoff generation: ${extensionOwner()}`);
}
await current.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await waitFor(() => {
    const arm = currentArm();
    return arm.pid && arm.marker && arm.marker !== sameInstanceArm.marker && existsSync(arm.marker) && pidAlive(arm.pid) && liveArmPids().includes(arm.pid);
}, "same-instance replacement child and arm record");
await waitFor(() => !existsSync(sameInstanceArm.marker), "same-instance previous child exit");
const sameInstanceOwner = extensionOwner();
const sameInstanceSuccessor = /^generation=([1-9][0-9]*) phase=active$/.exec(sameInstanceOwner)?.[1];
if (!sameInstanceSuccessor || sameInstanceSuccessor === sameInstanceGeneration) {
  throw new Error(`same-instance successor did not claim a distinct active generation: ${sameInstanceOwner}`);
}
const sameInstanceResult = await current.getTool().execute("same-instance-redundant", {}, undefined, undefined, {});
if (!sameInstanceResult.details?.ok || !String(sameInstanceResult.details.message).includes("unchanged")) {
  throw new Error(`same-instance replacement lost automatic arm ownership: ${JSON.stringify(sameInstanceResult.details)}`);
}
if (liveArmPids().length !== 1) {
  throw new Error(`same-instance expected one live arm child, got ${liveArmPids().join(",")}`);
}

// Stale prior-generation callback must not stop, rearm, or clear the active generation.
const activeChild = currentArm().pid;
const stale = await staleTool.execute("stale-prior-generation", {}, undefined, undefined, {});
if (stale.details?.ok !== false || !String(stale.details.message).includes("shutting down")) {
  throw new Error(`stale prior generation did not refuse: ${JSON.stringify(stale.details)}`);
}
if (!pidAlive(activeChild)) throw new Error("active generation child died after stale callback");
if (existsSync(startupMarker)) throw new Error("startup generation child was resurrected");
// Model the old generation PID being recycled for the active child.
// Its retired lifetime marker must keep the historical row from counting live.
writeFileSync(process.env.FM_ARM_LOG, `arm pid=${activeChild} marker=${startupMarker}\n`, { flag: "a" });
if (liveArmPids().length !== 1 || liveArmPids()[0] !== activeChild) {
  throw new Error(`stale callback mutated live arm set: ${liveArmPids().join(",")}`);
}
const redundant = await current.getTool().execute("redundant", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`active generation lost single-flight ownership: ${JSON.stringify(redundant.details)}`);
}

// Repeated transitions keep exactly one live cycle and never revive the refusal.
for (const reason of ["resume", "fork", "new", "resume"]) {
  current = await replaceSession(current, reason);
}

// Real terminal shutdown still blocks late rearming.
const finalArm = currentArm();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
await waitFor(() => !existsSync(finalArm.marker), "terminal shutdown child exit");
if (extensionOwner()) throw new Error(`terminal shutdown left an extension owner: ${extensionOwner()}`);
const quitArm = await current.getTool().execute("after-quit", {}, undefined, undefined, {});
if (quitArm.details?.ok !== false || quitArm.details.message !== "watcher: not armed - Pi session is shutting down") {
  throw new Error(`terminal quit must keep the shutting-down refusal: ${JSON.stringify(quitArm.details)}`);
}
if (liveArmPids().length !== 0) {
  throw new Error(`terminal quit left live arm children: ${liveArmPids().join(",")}`);
}
EOF
)
  status=$?
  [ "$status" -eq 0 ] || fail "Pi session transitions must auto-arm through their generation owner (exit $status): $out"
  [ -z "$out" ] || fail "Pi session-transition generation owner test printed output: $out"
  pass "Pi session transitions auto-arm through a generation owner across /new /resume /fork/reload, stale callbacks, and quit"
}

test_pi_session_replacement_carries_inflight_actionable_close() {
  local repo home plugin log marker_root trigger stop out status
  repo="$TMP_ROOT/pi-session-replacement-handoff-root"
  home="$TMP_ROOT/pi-session-replacement-handoff-home"
  log="$TMP_ROOT/pi-session-replacement-handoff.log"
  marker_root="$TMP_ROOT/pi-session-replacement-handoff-markers"
  trigger="$TMP_ROOT/pi-session-replacement-handoff.trigger"
  stop="$TMP_ROOT/pi-session-replacement-handoff.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$marker_root"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
marker=$(mktemp "${FM_MARKER_ROOT:?}/arm.XXXXXX") || exit 1
cleanup() { rm -f "$marker"; }
trap cleanup EXIT
trap 'exit 0' TERM INT
printf 'arm pid=%s marker=%s\n' "$$" "$marker" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=replacement-fixture\n' "$$"
# Model --restart taking over the retained predecessor after successor commit.
previous=$(sed -n '1p' "$FM_ARM_LOG.pid" 2>/dev/null || true)
previous_marker=$(sed -n '2p' "$FM_ARM_LOG.pid" 2>/dev/null || true)
printf '%s\n%s\n' "$$" "$marker" > "$FM_ARM_LOG.pid"
if [ -n "$previous" ] && [ -f "$previous_marker" ]; then
  kill -TERM "$previous" 2>/dev/null || true
fi
while :; do
  if [ -e "$FM_TRIGGER_FILE" ]; then
    outcome=$(cat "$FM_TRIGGER_FILE")
    rm -f "$FM_TRIGGER_FILE"
    printf 'signal: '
    sleep 0.02
    printf '%s\n' "$outcome"
    exit 0
  fi
  [ ! -e "$FM_STOP_FILE" ] || exit 0
  sleep 0.02
done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_MARKER_ROOT="$marker_root" FM_TRIGGER_FILE="$trigger" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let releaseOldDelivery = () => {};
const oldDeliveryRelease = new Promise((resolve) => {
  releaseOldDelivery = resolve;
});
let oldDeliveryStarted = false;

function makePi(blockDelivery = false) {
  const handlers = new Map();
  const eventHandlers = new Map();
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
    events: {
      on(event, handler) {
        eventHandlers.set(event, [...(eventHandlers.get(event) ?? []), handler]);
      },
      emit(event, data) {
        if (blockDelivery && event === "fm-branch-supervision:dispatch") {
          oldDeliveryStarted = true;
          data.accept(oldDeliveryRelease);
        }
        for (const handler of eventHandlers.get(event) ?? []) handler(data);
      },
    },
  };
  return { pi, handlers, getTool: () => tool, prompts };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function armRows() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split(/\n/)
    .filter((row) => row.startsWith("arm "))
    .map((row) => {
      const match = /pid=(\d+) marker=(\S+)/.exec(row);
      return match ? { pid: match[1], marker: match[2] } : { pid: "", marker: "" };
    });
}

function liveArms() {
  return armRows().filter((arm) => arm.pid && arm.marker && existsSync(arm.marker) && pidAlive(arm.pid));
}

async function waitFor(pred, label, attempts = 500) {
  for (let i = 0; i < attempts; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/replacement-race.meta`, "project=/projects/replacement-race\nwindow=fm-replacement-race\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\treplacement-race.status\tsignal: replacement-race actionable outcome\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const previous = makePi(true);
mod.default(previous.pi);
const initial = await previous.getTool().execute("initial-arm", {}, undefined, undefined, {});
if (!initial.details?.ok || !String(initial.details.message).includes("started Pi extension arm child")) {
  throw new Error(`initial arm failed: ${JSON.stringify(initial.details)}`);
}
await waitFor(() => liveArms().length === 1, "initial live arm");

writeFileSync(process.env.FM_TRIGGER_FILE, "replacement-race actionable outcome\n");
await waitFor(() => oldDeliveryStarted, "old-session accepted branch delivery");
if (previous.prompts.length !== 0) {
  throw new Error(`accepted old-session branch wake reached main: ${previous.prompts.join(" | ")}`);
}
await waitFor(() => liveArms().length === 1 && armRows().length >= 2, "old-session successor");
writeFileSync(process.env.FM_TRIGGER_FILE, "replacement-successor actionable outcome\n");
await waitFor(() => liveArms().length === 1 && armRows().length === 3, "mid-delivery successor restored before replacement");
const handoffArm = liveArms()[0];

await previous.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
if (!existsSync(handoffArm.marker) || !pidAlive(handoffArm.pid)) {
  throw new Error("replacement shutdown retired the restored predecessor before the new owner committed");
}

const replacement = makePi(false);
const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=durable-handoff`);
replacementMod.default(replacement.pi);
const replacementStart = replacement.handlers.get("session_start")?.({
  type: "session_start",
  reason: "new",
  previousSessionFile: "/tmp/previous.jsonl",
}, {});
await new Promise((resolve) => setTimeout(resolve, 50));
await waitFor(() => liveArms().length === 1 && armRows().length === 4 && !existsSync(handoffArm.marker), "replacement arm before old delivery settlement");
if (replacement.prompts.some((message) => message.includes("signal: replacement-race actionable outcome"))) {
  throw new Error(`replacement raced the accepted old-session delivery: ${replacement.prompts.join(" | ")}`);
}
writeFileSync(
  `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`,
  "{malformed handoff\n",
);
releaseOldDelivery();
await replacementStart;
await waitFor(
  () => replacement.prompts.some((message) => message.includes("signal: replacement-successor actionable outcome")),
  "replacement-session successor actionable delivery",
);
if (replacement.prompts.some((message) => message.includes("signal: replacement-race actionable outcome"))) {
  throw new Error(`settled old-session branch delivery was replayed: ${replacement.prompts.join(" | ")}`);
}
if (replacement.prompts.filter((message) => message.includes("signal: replacement-successor actionable outcome")).length !== 1) {
  throw new Error(`replacement session did not receive exactly one carried successor outcome: ${replacement.prompts.join(" | ")}`);
}
if (!replacement.prompts.some((message) => message.includes("could not clear a delivered replacement-session actionable wake"))) {
  throw new Error(`handoff cleanup failure was not surfaced: ${replacement.prompts.join(" | ")}`);
}
await new Promise((resolve) => setTimeout(resolve, 700));
if (replacement.prompts.filter((message) => message.includes("could not clear a delivered replacement-session actionable wake")).length !== 1) {
  throw new Error(`persistent handoff cleanup failure repeated alerts: ${replacement.prompts.join(" | ")}`);
}
await waitFor(() => liveArms().length === 1 && armRows().length >= 3, "replacement live arm");
const redundant = await replacement.getTool().execute("replacement-redundant", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`replacement did not retain automatic arm ownership: ${JSON.stringify(redundant.details)}`);
}

await new Promise((resolve) => setTimeout(resolve, 100));
if (liveArms().length !== 1) {
  throw new Error(`old delivery completion disturbed replacement ownership: ${JSON.stringify(liveArms())}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi session replacement must auto-arm and carry an in-flight actionable close: $out"
  [ -z "$out" ] || fail "Pi session-replacement handoff test printed output: $out"
  pass "Pi session replacement auto-arms and carries its in-flight actionable close"
}

test_pi_streaming_followup_is_replayed_after_replacement() {
  local repo home plugin trigger out status
  repo="$TMP_ROOT/pi-streaming-followup-replacement-root"
  home="$TMP_ROOT/pi-streaming-followup-replacement-home"
  trigger="$TMP_ROOT/pi-streaming-followup-replacement.trigger"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
printf 'watcher: started pid=%s\n' "$$"
while :; do
  if [ -e "$FM_TRIGGER_FILE" ]; then
    rm -f "$FM_TRIGGER_FILE"
    printf 'signal: streaming queued actionable outcome\n'
    exit 0
  fi
  sleep 0.02
done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_TRIGGER_FILE="$trigger" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  let tool = null;
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
  return { pi, handlers, prompts, getTool: () => tool };
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
await original.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
original.handlers.get("agent_start")?.({}, {});
writeFileSync(process.env.FM_TRIGGER_FILE, "trigger\n");
await waitFor(
  () => original.prompts.some((message) => message.includes("signal: streaming queued actionable outcome")),
  "old-session queued follow-up",
);
await original.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});

const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=streaming-followup`);
const replacement = makePi();
replacementMod.default(replacement.pi);
await replacement.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await waitFor(
  () => replacement.prompts.some((message) => message.includes("signal: streaming queued actionable outcome")),
  "replacement-session replay",
);
if (replacement.prompts.filter((message) => message.includes("signal: streaming queued actionable outcome")).length !== 1) {
  throw new Error(`replacement did not replay the unconsumed follow-up exactly once: ${replacement.prompts.join(" | ")}`);
}
replacement.handlers.get("before_agent_start")?.({
  messageType: "custom",
  message: { role: "custom", customType: "fixture", content: replacement.prompts[0], display: true },
}, {});
await replacement.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});

const finalMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=idle-followup`);
const finalSession = makePi();
finalMod.default(finalSession.pi);
const { unlinkSync } = await import("node:fs");
unlinkSync(`${process.env.FM_HOME}/state/.lock`);
await finalSession.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
if (finalSession.prompts.length !== 0) throw new Error("lockless replacement adopted its handoff early");
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const reclaimed = await finalSession.getTool().execute("reclaimed-arm", {}, undefined, undefined, {});
if (!reclaimed.details?.ok) throw new Error(`reclaimed arm failed: ${JSON.stringify(reclaimed.details)}`);
await waitFor(
  () => finalSession.prompts.some((message) => message.includes("signal: streaming queued actionable outcome")),
  "second replacement replay before idle consumption",
);
if (finalSession.prompts.filter((message) => message.includes("signal: streaming queued actionable outcome")).length !== 1) {
  throw new Error(`second replacement did not replay the idle queued follow-up exactly once: ${finalSession.prompts.join(" | ")}`);
}
finalSession.handlers.get("before_agent_start")?.({ messageType: "user", prompt: finalSession.prompts[0] }, {});
await new Promise((resolve) => setTimeout(resolve, 20));
await finalSession.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
const consumedMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=consumed-user`);
const consumed = makePi();
consumedMod.default(consumed.pi);
await consumed.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
if (consumed.prompts.length !== 0) throw new Error("a consumed user wake replayed after replacement");
await consumed.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "exit" }, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi replacement must replay a streaming follow-up before consumption"
  [ -z "$out" ] || fail "Pi streaming follow-up replacement test printed output: $out"
  pass "Pi replacement replays a streaming follow-up before consumption"
}

# The 2026-09-02 incident: a wake delivered while main was mid-turn never raised
# before_agent_start, the extension waited for it, and every later actionable
# close was dropped. Continuity must settle on Pi accepting the follow-up, while
# consumption still decides what a replacement replays.
test_pi_streaming_time_delivery_keeps_the_successor_chain() {
  local repo home plugin log trigger out status
  repo="$TMP_ROOT/pi-streaming-chain-root"
  home="$TMP_ROOT/pi-streaming-chain-home"
  log="$TMP_ROOT/pi-streaming-chain.log"
  trigger="$TMP_ROOT/pi-streaming-chain.trigger"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed=%s\n' "$2" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=chain-%s\n' "$$" "$count"
trap 'exit 0' TERM INT
while [ ! -e "$FM_TRIGGER_FILE.$count" ] && [ -e "$0" ]; do sleep 0.02; done
printf 'signal: streaming chain wake %s\n' "$count"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_TRIGGER_FILE="$trigger" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
let streaming = false;
let beforeAgentStarts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  // The real Pi prompt path: a follow-up sent while the agent is streaming is
  // queued for the running run and raises no before_agent_start; only a send
  // to an idle agent starts a run and raises it with the exact text.
  sendUserMessage: async (message) => {
    prompts.push(message);
    if (streaming) return;
    beforeAgentStarts += 1;
    handlers.get("before_agent_start")?.({ messageType: "user", prompt: message }, {});
  },
  events: { on() {}, emit() {} },
};
// The running run reaching a queued follow-up: Pi emits the user message.
const consumeQueued = (message) =>
  handlers.get("message_start")?.({ message: { role: "user", content: [{ type: "text", text: message }] } }, {});
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
const wakes = (text) => prompts.filter((message) => message.includes(text)).length;

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
await waitFor(() => arms() === 1, "first arm");
streaming = true;
writeFileSync(`${process.env.FM_TRIGGER_FILE}.1`, "close\n");
await waitFor(() => prompts.length === 1, "first wake delivered while main streams");
if (wakes("signal: streaming chain wake 1") !== 1) throw new Error(`wrong first wake: ${prompts.join(" | ")}`);
await waitFor(() => arms() === 2, "successor after the streaming-time delivery");
writeFileSync(`${process.env.FM_TRIGGER_FILE}.2`, "close\n");
await waitFor(() => prompts.length === 2, "second wake delivered while main still streams");
if (wakes("signal: streaming chain wake 2") !== 1) throw new Error(`wrong second wake: ${prompts.join(" | ")}`);
await waitFor(() => arms() === 3, "successor after the second streaming-time delivery");
if (beforeAgentStarts !== 0) throw new Error(`streaming follow-ups raised before_agent_start ${beforeAgentStarts} times`);

// Pi 1.2 emits an idle custom-message trigger without prompt. Its content
// matching a queued user wake must not mark that wake consumed.
await handlers.get("before_agent_start")?.({
  type: "before_agent_start",
  messageType: "custom",
  message: {
    role: "custom", customType: "fixture", content: prompts[1],
    display: false, timestamp: Date.now(),
  },
  systemPrompt: "fixture", systemPromptOptions: {},
}, {});
// The run reaches the first queued follow-up; the second is still queued when
// the captain replaces the session, so only the second rides the handoff.
consumeQueued(prompts[0]);
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
const handoffPath = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
const handoff = JSON.parse(readFileSync(handoffPath, "utf8"));
if (handoff.pending.length !== 1 || handoff.pending[0].delivered || !handoff.pending[0].message.includes("signal: streaming chain wake 2")) {
  throw new Error(`replacement handoff did not carry exactly the unconsumed wake: ${JSON.stringify(handoff)}`);
}
streaming = false;
const replacementMod = await import(`${pathToFileURL(process.env.PLUGIN).href}?replacement=streaming-chain`);
replacementMod.default(pi);
await handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await waitFor(() => prompts.length === 3, "replacement replay of the unconsumed wake");
if (wakes("signal: streaming chain wake 2") !== 2 || wakes("signal: streaming chain wake 1") !== 1) {
  throw new Error(`replacement replayed the wrong wakes: ${prompts.join(" | ")}`);
}
if (beforeAgentStarts !== 1) throw new Error(`idle replay raised before_agent_start ${beforeAgentStarts} times`);
await waitFor(() => arms() === 4, "replacement arm");
await waitFor(() => !existsSync(handoffPath), "consumed replay clears its handoff record");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi streaming-time wake delivery must keep the successor chain and replay only unconsumed wakes"
  [ -z "$out" ] || fail "Pi streaming-time delivery chain test printed output: $out"
  pass "Pi streaming-time wake delivery keeps the successor chain and replays only unconsumed wakes"
}

# A verified successor can die while the wake it was started for is still
# being delivered (a branch turn can take minutes). Its failure close arrives
# while the pipeline is busy, so the ordinary retry path must be deferred to
# the end of that delivery rather than skipped, or the live generation is left
# with no watcher and no retry.
# Issue 7032 restores per-close succession while keeping branch settlement
# serialized. Real arm processes expose the ordering; Pi callbacks are mocked.
test_pi_actionable_closes_restore_while_branch_delivery_is_held() {
  local repo home plugin log trigger out status mode
  mode=${1:-serial}
  repo="$TMP_ROOT/pi-held-branch-$mode-root"
  home="$TMP_ROOT/pi-held-branch-$mode-home"
  log="$TMP_ROOT/pi-held-branch-$mode.log"
  trigger="$TMP_ROOT/pi-held-branch-$mode.close"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
live="$FM_CLOSE_PREFIX.live.$$"
touch "$live"
trap 'rm -f "$live"' EXIT
trap 'exit 0' TERM INT
previous=$(sed -n '1p' "$FM_ARM_LOG.pid" 2>/dev/null || true)
previous_marker=$(sed -n '2p' "$FM_ARM_LOG.pid" 2>/dev/null || true)
printf '%s\n%s\n' "$$" "$live" > "$FM_ARM_LOG.pid"
if [ -n "$previous" ] && [ -f "$previous_marker" ]; then kill -TERM "$previous" 2>/dev/null || true; fi
if [ "$FM_HELD_CLOSE_CASE" = replacement ] && [ "$count" -eq 3 ]; then
  printf 'waiting=3\n' >> "$FM_ARM_LOG"
  while :; do sleep 0.02; done
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'ready=%s\n' "$count" >> "$FM_ARM_LOG"
while [ "$count" -ne 1 ] && [ ! -e "$FM_CLOSE_PREFIX.$count" ]; do sleep 0.02; done
printf 'signal: held branch close %s\n' "$count"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_CLOSE_PREFIX="$trigger" FM_HELD_CLOSE_CASE="$mode" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const offers = [];
const releases = [];
let tool;
let activeDeliveries = 0;
let maxDeliveries = 0;
let firstSettled = false;
const rows = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
const arms = () => rows().filter((row) => row.startsWith("arm="));
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
async function waitFor(predicate, label) {
  for (let i = 0; i < 500; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}; arms=${arms().length} offers=${offers.length}`);
}
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendUserMessage: async () => { throw new Error("eligible branch wake unexpectedly fell back to main"); },
  events: {
    on() {},
    emit(event, offer) {
      if (event !== "fm-branch-supervision:dispatch") return;
      offers.push(offer.message);
      activeDeliveries += 1;
      maxDeliveries = Math.max(maxDeliveries, activeDeliveries);
      const index = offers.length;
      const held = new Promise((resolve) => releases.push(resolve));
      offer.accept(held.then(() => {
        activeDeliveries -= 1;
        if (index === 1) firstSettled = true;
      }));
    },
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/held.meta`, "project=/projects/held\nwindow=fm-held\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\theld.status\tsignal: held branch close 1\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const mode = process.env.FM_HELD_CLOSE_CASE;
const expectedOffers = mode === "quit" ? 1 : mode === "replacement" ? 2 : 3;
try {
  await tool.execute("held-initial", {}, undefined, undefined, {});
  await waitFor(() => offers.length === 1 && rows().includes("ready=2"), "delivery A behind ready B");
  writeFileSync(`${process.env.FM_CLOSE_PREFIX}.2`, "close\n");
  if (mode === "replacement") {
    await waitFor(() => rows().includes("waiting=3"), "restoration held on C readiness");
    const predecessor = Number(arms()[2].slice(4));
    await handlers.get("session_shutdown")({ type: "session_shutdown", reason: "new" }, {});
    if (!alive(predecessor)) throw new Error("replacement retired the predecessor before successor commit");
    await handlers.get("session_start")({ type: "session_start", reason: "new" }, {});
    await waitFor(() => !alive(predecessor), "replacement committed before retained C retirement");
  } else {
    await waitFor(() => rows().includes("ready=3"), "ready C while A remains held");
    writeFileSync(`${process.env.FM_CLOSE_PREFIX}.3`, "close\n");
  }
  await waitFor(() => rows().includes("ready=4"), "further successor while A remains held");
  if (firstSettled || offers.length !== 1 || maxDeliveries !== 1) {
    throw new Error(`delivery escaped its hold/serialization: ${JSON.stringify({ firstSettled, offers, maxDeliveries })}`);
  }
  const redundant = await tool.execute("held-manual", {}, undefined, undefined, {});
  if (!redundant.details.ok || !redundant.details.message.includes("unchanged") || arms().length !== 4) {
    throw new Error("manual arm duplicated the held-delivery successor");
  }
  if (mode === "quit") await handlers.get("session_shutdown")({ type: "session_shutdown", reason: "quit" }, {});
  for (let index = 0; index < expectedOffers; index += 1) {
    await waitFor(() => offers.length === index + 1, `serialized delivery ${index + 1}`);
    if (offers[index] !== `signal: held branch close ${index + 1}`) throw new Error(`lost/reordered close: ${offers}`);
    releases[index]();
  }
  await waitFor(() => activeDeliveries === 0, "all admitted deliveries settled");
  await new Promise((resolve) => setTimeout(resolve, 100));
  if (offers.length !== expectedOffers || maxDeliveries !== 1 || arms().length !== 4) throw new Error("duplicate delivery or arm after settlement");
} finally {
  await handlers.get("session_shutdown")({ type: "session_shutdown", reason: "quit" }, {});
  for (const release of releases) release();
  await waitFor(() => arms().every((row) => !alive(Number(row.slice(4)))), "all owned arm PIDs stopped");
}
const afterQuit = await tool.execute("held-after-quit", {}, undefined, undefined, {});
if (afterQuit.details.ok || arms().length !== 4 || offers.length !== expectedOffers) throw new Error("terminal callbacks rearmed or replayed");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must restore every actionable close while branch delivery remains held: $out"
  [ -z "$out" ] || fail "Pi held-branch test printed output: $out"
  pass "Pi restores successors during held branch delivery with serialized settlement ($mode)"
}

# A close whose delivery waits behind an earlier held delivery must not be
# confirmed against a successor that a later close already replaced. The
# handoff is confirmed inside the continuity operation, while that successor is
# still the live arm, and the delivery reads the cached outcome. Without that,
# the queued close is confirmed against a dead watcher pid and the healthy
# newer successor is reported to main as a restoration failure.
test_pi_repeated_close_under_a_held_delivery_keeps_its_confirmed_handoff() {
  local repo home plugin log trigger out status
  repo="$TMP_ROOT/pi-repeated-close-root"
  home="$TMP_ROOT/pi-repeated-close-home"
  log="$TMP_ROOT/pi-repeated-close.log"
  trigger="$TMP_ROOT/pi-repeated-close.close"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  gen=${2:-} pid=${4:-}
  # The real script checks the named watcher pid before the episode
  # generation, so a successor that a later close already replaced is
  # rejected rather than reported as superseded. A confirmation of a token
  # whose generation no longer matches the current one is superseded.
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'rejected-dead generation=%s watcher=%s\n' "$gen" "$pid" >> "${FM_ARM_LOG:?}"
    exit 1
  fi
  current=$(cat "${FM_ARM_LOG}.gen" 2>/dev/null || true)
  if [ -n "$current" ] && [ "$current" != "$gen" ]; then
    printf 'superseded generation=%s watcher=%s current=%s\n' "$gen" "$pid" "$current" >> "${FM_ARM_LOG:?}"
    exit 3
  fi
  printf 'confirmed generation=%s watcher=%s\n' "$gen" "$pid" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
live="$FM_CLOSE_PREFIX.live.$$"
touch "$live"
trap 'rm -f "$live"' EXIT
trap 'exit 0' TERM INT
# Each arm carries its own recovery generation and records it as the current
# one, so a confirmation of a token from an earlier arm is a generation
# mismatch rather than an accidental match.
printf 'gen-%s\n' "$count" > "${FM_ARM_LOG}.gen"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$count"
printf 'ready=%s\n' "$count" >> "$FM_ARM_LOG"
while [ "$count" -ne 1 ] && [ ! -e "$FM_CLOSE_PREFIX.$count" ]; do sleep 0.02; done
printf 'signal: repeated close %s\n' "$count"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_CLOSE_PREFIX="$trigger" FM_WATCH_EXTENSION_LOG_KEEP_LINES=200 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const offers = [];
const releases = [];
const prompts = [];
let tool;
let activeDeliveries = 0;
let maxDeliveries = 0;
const rows = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
const arms = () => rows().filter((row) => row.startsWith("arm="));
const confirmations = () => rows().filter((row) => row.startsWith("confirmed generation="));
const rejections = () => rows().filter((row) => row.startsWith("rejected-dead"));
const supersessions = () => rows().filter((row) => row.startsWith("superseded generation="));
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
async function waitFor(predicate, label) {
  for (let i = 0; i < 1000; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}; rows=${rows().join(" | ")}; extlog=${existsSync(`${process.env.FM_HOME}/state/.watch-extension.log`) ? readFileSync(`${process.env.FM_HOME}/state/.watch-extension.log`, "utf8").replace(/\n/g, " | ") : "none"}`);
}
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendUserMessage: async (message) => { prompts.push(message); },
  events: {
    on() {},
    emit(event, offer) {
      if (event !== "fm-branch-supervision:dispatch") return;
      offers.push(offer.message);
      activeDeliveries += 1;
      maxDeliveries = Math.max(maxDeliveries, activeDeliveries);
      const index = offers.length;
      const held = new Promise((resolve) => releases.push(resolve));
      offer.accept(held.then(() => { activeDeliveries -= 1; }));
    },
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/held.meta`, "project=/projects/held\nwindow=fm-held\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\theld.status\tsignal: repeated close 1\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
try {
  await tool.execute("repeated-initial", {}, undefined, undefined, {});
  await waitFor(() => offers.length === 1 && confirmations().length === 1, "first handoff confirmed");
  // The successor closes while the first delivery is still held, and so does
  // its own successor: each queued close replaces the arm the previous one
  // confirmed.
  writeFileSync(`${process.env.FM_CLOSE_PREFIX}.2`, "close\n");
  await waitFor(() => arms().length === 3 && confirmations().length === 2, "second handoff confirmed");
  writeFileSync(`${process.env.FM_CLOSE_PREFIX}.3`, "close\n");
  await waitFor(() => arms().length === 4 && confirmations().length === 3, "third handoff confirmed");
  // Let the held first delivery settle: the queued closes deliver in order,
  // and each of them releases the next one.
  for (let index = 0; index < 3; index += 1) {
    await waitFor(() => offers.length === index + 1, `serialized delivery ${index + 1}`);
    releases[index]();
  }
  await waitFor(() => offers.length === 3, "every queued close delivered");
  await new Promise((resolve) => setTimeout(resolve, 150));
  if (prompts.length !== 0) {
    throw new Error(`a queued close reached main instead of the branch: ${prompts.join(" | ")}`);
  }
  if (maxDeliveries !== 1) throw new Error(`delivery escaped its serialization: ${maxDeliveries}`);
  if (rejections().length !== 0) {
    throw new Error(`a live handoff was rejected: ${rows().join(" | ")}`);
  }
  if (supersessions().length !== 0) {
    throw new Error(`a live handoff was reported as superseded: ${rows().join(" | ")}`);
  }
  const generations = confirmations().map((row) => row.split(" ")[1]);
  if (generations.join(",") !== "generation=gen-2,generation=gen-3,generation=gen-4") {
    throw new Error(`each close was confirmed against its own successor: ${generations.join(" | ")}`);
  }
  const order = offers.map((message) => message.trim());
  const expected = ["signal: repeated close 1", "signal: repeated close 2", "signal: repeated close 3"];
  if (order.join("|") !== expected.join("|")) {
    throw new Error(`queued closes lost or changed their order: ${order.join(" | ")}`);
  }
} finally {
  await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
  for (const release of releases) release();
  await waitFor(() => arms().every((row) => !alive(Number(row.slice(4)))), "all owned arm PIDs stopped");
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must confirm a queued close's handoff while its own successor is still live: $out"
  [ -z "$out" ] || fail "Pi repeated-close test printed output: $out"
  pass "Pi confirms a queued close's handoff inside the continuity operation"
}
