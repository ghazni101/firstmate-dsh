# shellcheck shell=bash
# Test cases for fm-pi-watch-extension, split out of tests/fm-pi-watch-extension.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-pi-watch-extension.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


node() {
  local leader
  perl -e '
    setpgrp(0, 0) or exit 125;
    shift;
    my $pid = fork() // exit 125;
    if (!$pid) { exec { $ARGV[0] } @ARGV or exit 127; }
    waitpid($pid, 0);
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "$TMP_ROOT/" node "$@" <&0 &
  leader=$!
  printf '%s\n' "$leader" >> "$PI_PROCESS_GROUPS"
  wait "$leader"
}

pi_owned_group_live() {  # <pgid>
  ps -eo pgid=,args= 2>/dev/null \
    | awk -v group="$1" -v root="$TMP_ROOT/" '$1 == group && index($0, root) { found = 1 } END { exit !found }'
}

pi_reap_process_groups() {
  local signal pgid i live
  [ -f "$PI_PROCESS_GROUPS" ] || return 0
  for signal in TERM KILL; do
    while IFS= read -r pgid; do
      case "$pgid" in ''|*[!0-9]*) continue ;; esac
      pi_owned_group_live "$pgid" && kill -s "$signal" -- "-$pgid" 2>/dev/null
    done < "$PI_PROCESS_GROUPS"
    i=0
    while [ "$i" -lt 20 ]; do
      live=0
      while IFS= read -r pgid; do
        case "$pgid" in ''|*[!0-9]*) continue ;; esac
        pi_owned_group_live "$pgid" && live=1 && break
      done < "$PI_PROCESS_GROUPS"
      [ "$live" -eq 1 ] || return 0
      sleep 0.1
      i=$((i + 1))
    done
  done
}

pi_teardown() {
  pi_reap_process_groups
  fm_test_cleanup
}

trap pi_teardown EXIT
trap 'pi_teardown; exit 130' INT
trap 'pi_teardown; exit 143' TERM
trap 'pi_teardown; exit 129' HUP
trap 'pi_teardown; exit 131' QUIT

# One owner for the readiness budget every unready-successor test below spends
# on purpose. Both plugins start a successor arm through a login shell and
# SIGTERM it when it stays silent past this budget, so the budget has to outlast
# a cold login-shell start. A successor killed before its first statement never
# appends its arm row and never installs the TERM trap these tests observe, so
# too small a budget reports a lost successor instead of the bounded recovery
# under test. A stock login shell already costs about 200ms on an idle
# workstation, and a loaded CI runner is slower, so keep an order of magnitude
# over that rather than a value that only holds locally. The wait loops in those
# tests are sized against this number.
ARM_READY_TIMEOUT_MS=2000

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

test_pi_extension_reports_external_healthy_watcher() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-external-healthy-root"
  home="$TMP_ROOT/pi-external-healthy-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let handler = null;
let notification = "";
let prompt = "";
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!handler) {
  console.error("Pi watch command was not registered");
  process.exit(1);
}
const result = await handler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (result !== undefined) {
  console.error(`Pi command returned a value: ${String(result)}`);
  process.exit(1);
}
if (!notification.includes("started Pi extension arm child")) {
  console.error(notification);
  process.exit(1);
}
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.startsWith("\u2063FIRSTMATE_OP: v1 watcher: ")) {
  console.error(`untyped operational follow-up: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) {
  console.error(`missing follow-up prompt: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("external healthy watcher")) {
  console.error(prompt);
  process.exit(1);
}
if (!prompt.includes("watcher: healthy pid=1")) {
  console.error(prompt);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must surface an external healthy watcher as an owned-wake failure"
  [ -z "$out" ] || fail "Pi external-healthy test printed output: $out"
  pass "Pi extension reports external healthy watcher output"
}

test_pi_tool_returns_agent_tool_result() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-tool-result-root"
  home="$TMP_ROOT/pi-tool-result-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
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
if (!tool) throw new Error("Pi watch tool was not registered");
if (tool.label !== "Arm firstmate watcher") throw new Error(`unexpected label: ${tool.label}`);
if (tool.parameters?.type !== "object") throw new Error("tool parameters are not a TypeBox object schema");
const metadata = [tool.description, tool.promptSnippet, ...(tool.promptGuidelines ?? [])].join("\n");
if (metadata.includes("Always use this tool")) throw new Error(`broad tool-selection metadata remained visible: ${metadata}`);
if (!tool.description.includes("first required Pi watcher cycle")) throw new Error(`tool description omitted the first-cycle condition: ${tool.description}`);
if (!tool.promptSnippet.includes("ordinary re-arming is automatic")) throw new Error(`tool snippet omitted automatic continuation: ${tool.promptSnippet}`);
if (!tool.promptGuidelines.some((guideline) => guideline.includes("ordinary signal, stale, check, or heartbeat handling"))) {
  throw new Error(`tool guidelines omitted ordinary-notification prevention: ${tool.promptGuidelines}`);
}
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!Array.isArray(result.content) || result.content[0]?.type !== "text") {
  throw new Error(`invalid tool content: ${JSON.stringify(result)}`);
}
if (!result.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`unexpected tool text: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("future ordinary re-arms are automatic")) {
  throw new Error(`initial tool result omitted automatic continuation guidance: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`initial tool result omitted the repair-only condition: ${result.content[0].text}`);
}
if (result.details?.ok !== true || result.details?.message !== result.content[0].text) {
  throw new Error(`invalid tool details: ${JSON.stringify(result.details)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi custom tool must expose first-cycle or repair-only metadata and return Pi's AgentToolResult shape"
  [ -z "$out" ] || fail "Pi tool-result test printed output: $out"
  pass "Pi custom tool exposes repair-only metadata and returns automatic-continuation guidance"
}

test_pi_redundant_tool_call_is_owned_noop() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-redundant-tool-root"
  home="$TMP_ROOT/pi-redundant-tool-home"
  log="$TMP_ROOT/pi-redundant-tool.log"
  stop="$TMP_ROOT/pi-redundant-tool.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
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
const initial = await tool.execute("tool-call-first", {}, undefined, undefined, {});
if (!initial.content[0]?.text.includes("started Pi extension arm child")) {
  throw new Error(`initial call did not start the arm child: ${initial.content[0]?.text}`);
}
const redundant = await tool.execute("tool-call-redundant", {}, undefined, undefined, {});
if (!redundant.content[0]?.text.includes("Pi extension already owns an arm child; no manual re-arm needed")) {
  throw new Error(`redundant call omitted ownership-based no-op guidance: ${redundant.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`redundant call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`redundant call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
for (let i = 0; i < 100 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("initial arm child did not start");
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`redundant call spawned ${rows.length} arm children`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi redundant tool call must remain an ownership-based no-op with repair-only guidance"
  [ -z "$out" ] || fail "Pi redundant-call test printed output: $out"
  pass "Pi redundant tool call returns ownership guidance and spawns no second child"
}

test_pi_scheduled_retry_call_is_owned_noop() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-scheduled-retry-root"
  home="$TMP_ROOT/pi-scheduled-retry-home"
  log="$TMP_ROOT/pi-scheduled-retry.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=10000 FM_WATCH_REARM_RETRY_MAX_MS=10000 node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
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
await tool.execute("tool-call-first", {}, undefined, undefined, {});
let redundant = null;
for (let i = 0; i < 100; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
  redundant = await tool.execute("tool-call-during-retry", {}, undefined, undefined, {});
  if (redundant.content[0]?.text.includes("scheduled continuity retry")) break;
}
if (!redundant?.content[0]?.text.includes("Pi extension already owns a scheduled continuity retry; no manual re-arm needed")) {
  throw new Error(`scheduled retry did not return ownership-based no-op guidance: ${redundant?.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`scheduled retry call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`scheduled retry call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`scheduled retry call spawned ${rows.length} arm children`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi scheduled-retry call must not duplicate the extension-owned retry"
  [ -z "$out" ] || fail "Pi scheduled-retry test printed output: $out"
  pass "Pi scheduled retry remains extension-owned after another tool call"
}

test_pi_actionable_close_starts_single_successor_before_delivery() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-continuous-rearm-root"
  home="$TMP_ROOT/pi-continuous-rearm-home"
  log="$TMP_ROOT/pi-continuous-rearm.log"
  stop="$TMP_ROOT/pi-continuous-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
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
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveryStarted = false;
let rowsAtDelivery = 0;
let releaseDelivery = () => {};
const deliveryBlocked = new Promise((resolve) => {
  releaseDelivery = resolve;
});
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    rowsAtDelivery = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((row) => row.startsWith("arm=")).length
      : 0;
    deliveryStarted = true;
    await deliveryBlocked;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-continuity", {}, undefined, undefined, {});
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && deliveryStarted) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
const armRows = rows.filter((row) => row.startsWith("arm="));
if (armRows.length !== 2) throw new Error(`expected one successor arm, got ${armRows.length}: ${rows.join(" | ")}`);
if (!deliveryStarted) throw new Error("wake delivery did not begin");
if (rowsAtDelivery !== 2) throw new Error(`wake delivery began before successor establishment (${rowsAtDelivery} arm rows)`);
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
releaseDelivery();
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi actionable close must start one successor before wake delivery settles"
  [ -z "$out" ] || fail "Pi continuous-rearm test printed output: $out"
  pass "Pi actionable close starts one successor before wake delivery settles"
}

# The arm child can publish its complete actionable line before its process
# closes while the watcher finishes durable cleanup. The still-open predecessor
# must never be mistaken for the successor merely because its readiness promise
# already settled.
test_pi_actionable_output_waits_for_predecessor_close() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-actionable-before-close-root"
  home="$TMP_ROOT/pi-actionable-before-close-home"
  log="$TMP_ROOT/pi-actionable-before-close.log"
  stop="$TMP_ROOT/pi-actionable-before-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'handling-confirmed\n' >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=before-close-%s\n' "$$" "$count"
if [ "$count" -eq 1 ]; then
  printf 'actionable-emitted\n' >> "$FM_ARM_LOG"
  printf 'signal: actionable output before predecessor close\n'
  sleep 0.5
  printf 'predecessor-closed\n' >> "$FM_ARM_LOG"
  exit 0
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const failNow = (message) => {
  console.error(message);
  process.exit(1);
};
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
    writeFileSync(process.env.FM_ARM_LOG, "delivery\n", { flag: "a" });
  },
  events: { on() {}, emit() {} },
};

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("initial-arm", {}, undefined, undefined, {});
await new Promise((resolve) => setTimeout(resolve, 1200));
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
const armIndexes = rows.map((row, index) => row.startsWith("arm=") ? index : -1).filter((index) => index >= 0);
const closeIndex = rows.indexOf("predecessor-closed");
const deliveryIndex = rows.indexOf("delivery");
if (armIndexes.length !== 2) failNow(`expected a successor after the predecessor close: ${rows.join(" | ")}`);
if (closeIndex < 0 || deliveryIndex < 0) failNow(`missing close or delivery evidence: ${rows.join(" | ")}`);
if (armIndexes[1] < closeIndex) failNow(`successor started before predecessor close: ${rows.join(" | ")}`);
if (deliveryIndex < armIndexes[1]) failNow(`wake was delivered before successor startup: ${rows.join(" | ")}`);
if (prompts.length !== 1 || !prompts[0].includes("signal: actionable output before predecessor close")) {
  failNow(`wrong actionable wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi actionable output must wait for predecessor close before successor restoration"
  [ -z "$out" ] || fail "Pi actionable-before-close test printed output: $out"
  pass "Pi actionable output waits for predecessor close before successor restoration"
}

# A successor can print readiness after its arm process has already exited when
# a descendant retains the stdout pipe and emits the line. Readiness alone must
# not let the original wake reach Pi while no arm child is alive: restoration
# has to start a live successor inside its existing retry bound first.
test_pi_dead_ready_successor_is_retried_before_delivery() {
  local repo home plugin log stop release holder out status
  repo="$TMP_ROOT/pi-dead-ready-successor-root"
  home="$TMP_ROOT/pi-dead-ready-successor-home"
  log="$TMP_ROOT/pi-dead-ready-successor.log"
  stop="$TMP_ROOT/pi-dead-ready-successor.stop"
  release="$TMP_ROOT/pi-dead-ready-successor.release"
  holder="$TMP_ROOT/pi-dead-ready-successor-holder.sh"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$holder" <<'SH'
#!/usr/bin/env bash
parent=$1
release=$2
while kill -0 "$parent" 2>/dev/null; do sleep 0.01; done
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=dead-ready\n' "$parent"
while [ ! -e "$release" ]; do sleep 0.02; done
SH
  chmod +x "$holder"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: wake before dead-ready successor\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  ("${FM_HOLDER:?}" "$$" "${FM_RELEASE_FILE:?}" >&1 2>/dev/null &)
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=live-successor\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_RELEASE_FILE="$release" FM_HOLDER="$holder" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let armsAtDelivery = 0;
const armRows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").split("\n").filter((row) => row.startsWith("arm="))
  : [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    armsAtDelivery = armRows().length;
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("initial-dead-ready-arm", {}, undefined, undefined, {});
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
let failure = "";
if (!prompt.includes("signal: wake before dead-ready successor")) {
  failure = `original wake was not delivered: ${prompt}`;
} else if (armsAtDelivery < 3) {
  failure = `wake reached Pi with no live successor; arms at delivery=${armsAtDelivery}: ${armRows().join(" | ")}`;
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 100));
if (failure) throw new Error(failure);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi restoration must retry a dead-but-ready successor before delivering the wake: $out"
  [ -z "$out" ] || fail "Pi dead-ready successor test printed output: $out"
  pass "Pi restoration retries a dead-but-ready successor before delivering the wake"
}

# A verified successor can die just after restoration accepts it while a
# descendant still holds its stdio pipes, so Node never reports close. The
# arm's exit alone must still route into the bounded retry instead of leaving
# the home unwatched until the descendant lets go.
test_pi_successor_exit_with_held_pipe_schedules_retry() {
  local repo home plugin log stop release delivered out status
  repo="$TMP_ROOT/pi-held-pipe-successor-root"
  home="$TMP_ROOT/pi-held-pipe-successor-home"
  log="$TMP_ROOT/pi-held-pipe-successor.log"
  stop="$TMP_ROOT/pi-held-pipe-successor.stop"
  release="$TMP_ROOT/pi-held-pipe-successor.release"
  delivered="$TMP_ROOT/pi-held-pipe-successor.delivered"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: wake before held-pipe successor\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  printf 'watcher: started pid=%s (beacon fresh) recovery-generation=held-pipe\n' "$$"
  (while [ ! -e "${FM_RELEASE_FILE:?}" ]; do sleep 0.02; done &)
  while [ ! -e "${FM_DELIVERED_FILE:?}" ]; do sleep 0.02; done
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=retry-successor\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_RELEASE_FILE="$release" FM_DELIVERED_FILE="$delivered" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const armRows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").split("\n").filter((row) => row.startsWith("arm="))
  : [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    writeFileSync(process.env.FM_DELIVERED_FILE, "delivered\n");
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("initial-held-pipe-arm", {}, undefined, undefined, {});
for (let i = 0; i < 500 && armRows().length < 3; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
let failure = "";
if (!prompt.includes("signal: wake before held-pipe successor")) {
  failure = `original wake was not delivered: ${prompt}`;
} else if (armRows().length < 3) {
  failure = `successor exit with a held pipe left no retry: ${armRows().join(" | ")}`;
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 100));
if (failure) throw new Error(failure);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi successor exit with a held pipe must schedule the bounded retry: $out"
  [ -z "$out" ] || fail "Pi held-pipe successor test printed output: $out"
  pass "Pi successor exit with a held pipe schedules the bounded retry"
}

# Node can report the arm process exit before its stdout pipe drains. Delay the
# arm's own final output behind a descendant-held FIFO so the actionable line
# reaches the extension after exit; it must still become the wake, not a retry.
test_pi_actionable_line_draining_after_exit_stays_actionable() {
  local repo home plugin log fifo stop out status
  repo="$TMP_ROOT/pi-actionable-after-exit-root"
  home="$TMP_ROOT/pi-actionable-after-exit-home"
  log="$TMP_ROOT/pi-actionable-after-exit.log"
  fifo="$TMP_ROOT/pi-actionable-after-exit.fifo"
  stop="$TMP_ROOT/pi-actionable-after-exit.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  mkfifo "${FM_DELAY_FIFO:?}"
  exec 3>&1
  (
    exec 4<"$FM_DELAY_FIFO"
    sleep 0.1
    cat <&4 >&3
  ) &
  exec 3>&-
  exec >"$FM_DELAY_FIFO"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: actionable output drained after exit\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=drained-actionable\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_DELAY_FIFO="$fifo" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=2000 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const armRows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").split("\n").filter((row) => row.startsWith("arm="))
  : [];
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
await tool.execute("initial-delayed-drain-arm", {}, undefined, undefined, {});
for (let i = 0; i < 100 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
let failure = "";
if (!prompt.includes("signal: actionable output drained after exit")) {
  failure = `late actionable line was lost: ${prompt || "no wake delivered"}`;
} else if (armRows().length !== 2) {
  failure = `late actionable line started the wrong number of successors: ${armRows().join(" | ")}`;
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 100));
if (failure) throw new Error(failure);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi actionable output draining after exit must stay actionable: $out"
  [ -z "$out" ] || fail "Pi actionable-after-exit test printed output: $out"
  pass "Pi actionable output draining after exit stays actionable"
}

test_pi_branch_offer_owns_actionable_wake() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-branch-offer-root"
  home="$TMP_ROOT/pi-branch-offer-home"
  log="$TMP_ROOT/pi-branch-offer.log"
  stop="$TMP_ROOT/pi-branch-offer.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: branch-offer synthetic wake\n'
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

// Two independent runs against the SAME dispatcher build: with an accepting
// branch listener the wake must be owned by the branch (no main follow-up);
// with a bus but no acceptor the dispatcher must fall back to main. The
// divergence between the two runs is asserted, so the case cannot go vacuous.
async function runScenario(withAcceptor) {
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
  if (withAcceptor) {
    bus.on("fm-branch-supervision:dispatch", (offer) => {
      offers.push({ message: offer.message, projects: offer.projects });
      offer.accept();
    });
  }
  const pi = {
    on() {},
    events: bus,
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async (message) => {
      mainPrompt = message;
    },
  };
  const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?scenario=${withAcceptor}`);
  mod.default(pi);
  await tool.execute("tool-call-branch-offer", {}, undefined, undefined, {});
  for (let i = 0; i < 250; i += 1) {
    const settled = withAcceptor ? offers.length > 0 : mainPrompt !== "";
    if (settled) break;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  return { offers, mainPrompt, rows };
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/branch-offer.meta`, "project=/projects/approved\nwindow=fm-branch-offer\n");
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\tsignal\tbranch-offer.status\tsignal: branch-offer synthetic wake\n");
const accepted = await runScenario(true);
if (accepted.offers.length !== 1) throw new Error(`expected one branch offer, got ${accepted.offers.length}`);
if (!accepted.offers[0].message.includes("signal: branch-offer synthetic wake")) {
  throw new Error(`offer missed the wake reason: ${accepted.offers[0].message}`);
}
if (JSON.stringify(accepted.offers[0].projects) !== JSON.stringify(["/projects/approved"])) {
  throw new Error(`offer did not carry the queued task project: ${JSON.stringify(accepted.offers[0].projects)}`);
}
if (accepted.mainPrompt !== "") throw new Error(`accepted offer still reached main: ${accepted.mainPrompt}`);
if (!accepted.rows.some((row) => row.startsWith("confirmed generation=fixture-generation"))) {
  throw new Error(`handling delivery was not confirmed before the branch handoff: ${accepted.rows.join(" | ")}`);
}
const declined = await runScenario(false);
if (declined.offers.length !== 0) throw new Error("no-acceptor scenario recorded an offer");
if (!declined.mainPrompt.includes("FIRSTMATE WATCHER WAKE")) {
  throw new Error(`unaccepted offer did not fall back to main: ${declined.mainPrompt}`);
}
if (!declined.mainPrompt.includes("signal: branch-offer synthetic wake")) {
  throw new Error(`fallback wake lost the reason line: ${declined.mainPrompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi dispatcher must hand an accepted wake to the branch and fall back to main otherwise"
  [ -z "$out" ] || fail "Pi branch-offer test printed output: $out"
  pass "Pi dispatcher branch offer owns accepted wakes and falls back to main"
}

test_pi_branch_offer_flags_heartbeat() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-branch-heartbeat-root"
  home="$TMP_ROOT/pi-branch-heartbeat-home"
  log="$TMP_ROOT/pi-branch-heartbeat.log"
  stop="$TMP_ROOT/pi-branch-heartbeat.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'heartbeat\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # A bare heartbeat is the real wake emitted after the cheap bash scan flags
  # a fleet pass as possibly captain-relevant. It has no task-scoped queue row,
  # so branch eligibility must remain independent of project resolution.
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
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
  offers.push({ message: offer.message, projects: offer.projects, heartbeat: offer.heartbeat, eligible: offer.eligible });
  offer.accept();
});
let tool = null;
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "1\t1\theartbeat\theartbeat\theartbeat\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-branch-heartbeat", {}, undefined, undefined, {});
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1) throw new Error(`expected one branch offer, got ${offers.length}`);
if (offers[0].message !== "heartbeat") {
  throw new Error(`offer changed the bare heartbeat wake reason: ${offers[0].message}`);
}
if (offers[0].heartbeat !== true || offers[0].eligible !== true) throw new Error(`heartbeat offer was not eligible: ${JSON.stringify(offers[0])}`);
if (JSON.stringify(offers[0].projects) !== JSON.stringify([])) {
  throw new Error(`heartbeat offer unexpectedly carried scoped projects: ${JSON.stringify(offers[0].projects)}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi dispatcher must flag a heartbeat offer independent of task scoping"
  [ -z "$out" ] || fail "Pi branch-heartbeat test printed output: $out"
  pass "Pi dispatcher flags a fleet-wide heartbeat offer as branch-eligible"
}

test_pi_heartbeat_is_not_ridden_into_main_by_a_co_present_check() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-heartbeat-mixed-queue-root"
  home="$TMP_ROOT/pi-heartbeat-mixed-queue-home"
  log="$TMP_ROOT/pi-heartbeat-mixed-queue.log"
  stop="$TMP_ROOT/pi-heartbeat-mixed-queue.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'heartbeat\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
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
  offers.push({ message: offer.message, heartbeat: offer.heartbeat, eligible: offer.eligible });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\theartbeat\theartbeat\theartbeat\n2\t2\tcheck\tx-inbox\tcheck: pending x mention\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-heartbeat-mixed-queue", {}, undefined, undefined, {});
// The offer is what this asserts on, so wait for it and then give any
// erroneous main delivery a real chance to land before calling it absent.
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 25 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].heartbeat !== true || offers[0].eligible !== true) {
  throw new Error(`a co-present check row made the heartbeat offer ineligible: ${JSON.stringify(offers)}`);
}
if (prompt) {
  throw new Error(`a co-present check row rode the heartbeat into main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "a heartbeat must not ride a co-present check row into main: $out"
  [ -z "$out" ] || fail "Pi mixed heartbeat-queue test printed output: $out"
  pass "a co-present check row neither vetoes nor rides a heartbeat into main"
}

# Every check the main session alone can act on stays on main, even when an
# unrelated task-local row in the same queue is perfectly branch-eligible. The
# no-op checks the branch never sees are suppressed at their source instead
# (bin/fm-procevent-lavish.sh "silent"), so what remains under a `check:`
# trigger is exactly the main-only set, and each named class is driven here
# through the real dispatcher.
test_pi_main_only_check_classes_stay_on_main() {
  local repo home plugin log stop out status reason label
  repo="$TMP_ROOT/pi-main-only-check-root"
  home="$TMP_ROOT/pi-main-only-check-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/projects/approved"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'project=%s/projects/approved\nwindow=fm-window\n' "$home" > "$home/state/task-a.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf '%s\n' "${FM_TEST_REASON:?}"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  while IFS='|' read -r label reason; do
    [ -n "$label" ] || continue
    log="$TMP_ROOT/pi-main-only-check-$label.log"
    stop="$TMP_ROOT/pi-main-only-check-$label.stop"
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
      FM_TEST_REASON="$reason" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
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
  offers.push({ message: offer.message, eligible: offer.eligible });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
// A task-local row the branch would happily take sits in the same queue, so
// only the check-kind TRIGGER itself can be what keeps this wake on main.
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\tsignal\ttask-a.status\tsignal: task-a.status\n2\t2\tcheck\tmain-only\t" + process.env.FM_TEST_REASON + "\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-main-only-check", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].eligible !== false) {
  throw new Error(`a main-only check was offered to the branch: ${JSON.stringify(offers)}`);
}
if (!prompt.includes(`FIRSTMATE WATCHER WAKE: ${process.env.FM_TEST_REASON}`)) {
  throw new Error(`a main-only check did not reach main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
    )
    status=$?
    expect_code 0 "$status" "the $label check class must stay on main: $out"
    [ -z "$out" ] || fail "Pi main-only check test ($label) printed output: $out"
  done <<'CLASSES'
relay-mention|check: x-mention 1234567890
credential-failure|check: gh auth check failed; re-authenticate before dispatch
merge-confirmation|check: task-a.check.sh: PR merged
real-board-answer|check: procevent lavish lavish-abcdef0123456789 1
CLASSES
  pass "every main-only check class still reaches main, never the supervision branch"
}

# A surfaced captain-held signal uses the existing decision-owned payload, so a
# co-present routine row cannot take the signal close away from main.
test_pi_captain_held_signal_stays_on_main() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-captain-held-whitespace-root"
  home="$TMP_ROOT/pi-captain-held-whitespace-home"
  log="$TMP_ROOT/pi-captain-held-whitespace.log"
  stop="$TMP_ROOT/pi-captain-held-whitespace.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/projects/approved"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'project=%s/projects/approved\nwindow=fm-window\n' "$home" > "$home/state/task-a.meta"
  printf 'captain-held [key=route]: awaiting the captain\n \t \n' > "$home/state/task-a.status"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: task-a.status\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
    node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
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
  offers.push({ message: offer.message, eligible: offer.eligible });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status\n" +
    "1\t2\tsignal\ttask-a.status\tsignal: routine follow-up\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-captain-held-signal", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].eligible !== false) {
  throw new Error(`a captain-held signal trigger was offered to the branch: ${JSON.stringify(offers)}`);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE: signal: task-a.status")) {
  throw new Error(`a captain-held signal trigger did not reach main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "a captain-held signal trigger must stay on main: $out"
  [ -z "$out" ] || fail "Pi captain-held signal test printed output: $out"
  pass "a captain-held signal trigger reaches main with routine rows present"
}

# An unread second-mate pending-reply escalation keeps a later stale reminder
# under the same task's window alias on main until the decision row is read.
test_pi_unread_pending_reply_forces_later_stale_alias_to_main() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-mixed-signal-root"
  home="$TMP_ROOT/pi-mixed-signal-home"
  log="$TMP_ROOT/pi-mixed-signal.log"
  stop="$TMP_ROOT/pi-mixed-signal.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/projects/approved"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'project=%s/projects/approved\nwindow=fm-a\n' "$home" > "$home/state/task-a.meta"
  printf 'blocked [key=pending-reply-0123456789abcdef]: pending-reply-missed: task=task-a pending-reply-id=0123456789abcdef request=finish report\n' \
    > "$home/state/task-a.status"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'stale: fm-a (routine reminder)\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
    node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
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
  offers.push({ message: offer.message, eligible: offer.eligible, projects: [...offer.projects] });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status\n" +
    "2\t2\tstale\tfm-a\tstale: fm-a (routine reminder)\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-later-stale-alias", {}, undefined, undefined, {});
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].eligible !== false) {
  throw new Error(`a later stale alias bypassed its unread decision: ${JSON.stringify(offers)}`);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE: stale: fm-a")) {
  throw new Error(`a later stale alias with an unread decision did not wake main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "an unread pending-reply escalation must keep a later stale alias on main: $out"
  [ -z "$out" ] || fail "Pi unread pending-reply alias test printed output: $out"
  pass "an unread pending-reply escalation keeps later stale aliases on main"
}

# The captain's accepted rule names ONE coalesced trigger batch, not only a
# single status file with two rows: when a watcher poll bundles a routine
# signal for one task and a needs-decision signal for a DIFFERENT task into
# one "signal: <files>" close, the whole batch - both files - must reach main
# together, never split so the routine file goes to the branch while only the
# decision file goes to main. A `some`-vs-`every` regression on the file-list
# cross-reference would pass the same-key test above (both entries share one
# key) but must fail here, where the two files are genuinely distinct.
test_pi_distinct_files_mixed_batch_routes_whole_batch_to_main() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-distinct-mixed-batch-root"
  home="$TMP_ROOT/pi-distinct-mixed-batch-home"
  log="$TMP_ROOT/pi-distinct-mixed-batch.log"
  stop="$TMP_ROOT/pi-distinct-mixed-batch.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/projects/approved"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'project=%s/projects/approved\nwindow=fm-a\n' "$home" > "$home/state/task-a.meta"
  printf 'project=%s/projects/approved\nwindow=fm-b\n' "$home" > "$home/state/task-b.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: task-a.status task-b.status\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
    node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
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
  offers.push({ message: offer.message, eligible: offer.eligible, projects: [...offer.projects] });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\tsignal\ttask-a.status\tneeds-decision: task-a.status\n" +
    "2\t2\tsignal\ttask-b.status\tsignal: task-b.status\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-distinct-mixed-batch", {}, undefined, undefined, {});
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].eligible !== false) {
  throw new Error(`a distinct-file mixed batch was split, offering the routine file to the branch: ${JSON.stringify(offers)}`);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE: signal: task-a.status task-b.status")) {
  throw new Error(`the distinct-file mixed batch did not reach main as one whole close: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "a distinct-file mixed batch must route wholly to main, not split: $out"
  [ -z "$out" ] || fail "Pi distinct-file mixed-batch test printed output: $out"
  pass "a mixed batch of two distinct files - one routine, one needs-decision - routes wholly to main"
}

# Independent heartbeat handling: a needs-decision row sitting elsewhere in the
# unread queue is excluded and non-vetoing exactly like a check-kind row, so it
# must neither block nor ride along with a co-present, otherwise-eligible
# heartbeat scan (docs/pi-supervision-branch.md "Heartbeat routing").
test_pi_heartbeat_is_not_ridden_into_main_by_a_co_present_needs_decision() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-heartbeat-needs-decision-root"
  home="$TMP_ROOT/pi-heartbeat-needs-decision-home"
  log="$TMP_ROOT/pi-heartbeat-needs-decision.log"
  stop="$TMP_ROOT/pi-heartbeat-needs-decision.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'heartbeat\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
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
  offers.push({ message: offer.message, heartbeat: offer.heartbeat, eligible: offer.eligible });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  "1\t1\theartbeat\theartbeat\theartbeat\n2\t2\tsignal\tdecision-task.status\tneeds-decision: decision-task.status\n",
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-heartbeat-needs-decision", {}, undefined, undefined, {});
for (let i = 0; i < 250 && offers.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (let i = 0; i < 25 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 1 || offers[0].heartbeat !== true || offers[0].eligible !== true) {
  throw new Error(`a co-present needs-decision row made the heartbeat offer ineligible: ${JSON.stringify(offers)}`);
}
if (prompt) {
  throw new Error(`a co-present needs-decision row rode the heartbeat into main: ${prompt}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "a heartbeat must not ride a co-present needs-decision row into main: $out"
  [ -z "$out" ] || fail "Pi heartbeat/needs-decision test printed output: $out"
  pass "a co-present needs-decision row neither vetoes nor rides a heartbeat into main"
}

test_pi_heartbeat_restoration_failure_stays_on_main() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-heartbeat-restoration-failure-root"
  home="$TMP_ROOT/pi-heartbeat-restoration-failure-home"
  log="$TMP_ROOT/pi-heartbeat-restoration-failure.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'heartbeat\n'
  exit 0
fi
printf 'synthetic successor startup failure\n' >&2
exit 1
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
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
  offers.push({ message: offer.message, heartbeat: offer.heartbeat });
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
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-heartbeat-restoration-failure", {}, undefined, undefined, {});
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (offers.length !== 0) {
  throw new Error(`heartbeat restoration failure was offered to the branch: ${JSON.stringify(offers)}`);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE: heartbeat\n\nwatcher: FAILED")) {
  throw new Error(`main wake lost the bare heartbeat reason: ${prompt}`);
}
if (!prompt.includes("watcher: FAILED - Pi extension could not restore watcher continuity after 2 retries")) {
  throw new Error(`main wake lost the restoration failure: ${prompt}`);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "heartbeat restoration failure must bypass an accepting branch: $out"
  [ -z "$out" ] || fail "Pi heartbeat restoration-failure test printed output: $out"
  pass "heartbeat restoration failure stays on main"
}

test_pi_watcher_failure_never_offered_to_branch() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-watcher-failure-root"
  home="$TMP_ROOT/pi-watcher-failure-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # Only "actionable" closes (signal/stale/check/heartbeat) ever reach
  # offerWakeToBranch; only main can repair the watcher cycle
  # (docs/pi-supervision-branch.md), and default-on eligibility must not
  # change that. A live, always-accepting bus listener proves the negative:
  # even with an acceptor present, a watcher-failure close is never offered.
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let handler = null;
const handlers = new Map();
const bus = {
  on(channel, h) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), h]);
    return () => {};
  },
  emit(channel, data) {
    for (const h of handlers.get(channel) ?? []) h(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message, heartbeat: offer.heartbeat });
  offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handler("", { ui: { notify() {} } });
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("external healthy watcher")) {
  throw new Error(`watcher failure did not reach main: ${prompt}`);
}
if (offers.length !== 0) {
  throw new Error(`watcher failure was offered to the branch: ${JSON.stringify(offers)}`);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "watcher-failure repair must never be offered to the branch: $out"
  [ -z "$out" ] || fail "Pi watcher-failure test printed output: $out"
  pass "watcher-failure repair stays with main even with a live, accepting branch listener"
}

# Under the away-posture record the dispatcher offers every actionable row to
# the branch - a check-kind trigger and a needs-decision signal included, the
# two classes attended routing forces to main - while the two broken-queue
# vetoes (an unresolvable task-local row, a structurally invalid row) and every
# watcher-failure alarm still reach main exactly as attended
# (docs/pi-supervision-branch.md "Postures").
test_pi_away_record_collapses_eligibility_and_keeps_vetoes_on_main() {
  local repo home plugin log stop out status label expect reason queue
  repo="$TMP_ROOT/pi-away-root"
  home="$TMP_ROOT/pi-away-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/projects/approved"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf 'project=%s/projects/approved\nwindow=fm-window\n' "$home" > "$home/state/task-a.meta"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "away entry failed"
  [ -f "$home/state/.afk-contract" ] || fail "the away-posture record was not written"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf '%s\n' "${FM_TEST_REASON:?}"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  while IFS='|' read -r label expect reason queue; do
    [ -n "$label" ] || continue
    log="$TMP_ROOT/pi-away-$label.log"
    stop="$TMP_ROOT/pi-away-$label.stop"
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
      FM_TEST_REASON="$reason" FM_TEST_QUEUE="$queue" FM_TEST_EXPECT="$expect" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
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
  offers.push({ message: offer.message, eligible: offer.eligible });
  if (offer.eligible) offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(
  `${process.env.FM_HOME}/state/.wake-queue`,
  process.env.FM_TEST_QUEUE.replace(/\\t/g, "\t").replace(/\\n/g, "\n"),
);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-away", {}, undefined, undefined, {});
for (let i = 0; i < 250 && offers.length === 0 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
// Give a wrongly-routed main follow-up time to show up before asserting its absence.
for (let i = 0; i < 25 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (process.env.FM_TEST_EXPECT === "branch") {
  if (offers.length !== 1 || offers[0].eligible !== true) {
    throw new Error(`under the away-posture record this wake was not offered to the branch: ${JSON.stringify(offers)}`);
  }
  if (prompt) throw new Error(`a branch-eligible wake still woke the parked main: ${prompt}`);
} else {
  if (offers.length !== 1 || offers[0].eligible !== false) {
    throw new Error(`a broken-queue wake was offered to the branch under the record: ${JSON.stringify(offers)}`);
  }
  if (!prompt.includes(`FIRSTMATE WATCHER WAKE: ${process.env.FM_TEST_REASON}`)) {
    throw new Error(`a wake the branch cannot take did not fall back to main: ${prompt}`);
  }
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
    )
    status=$?
    expect_code 0 "$status" "away routing for the $label case must bind: $out"
    [ -z "$out" ] || fail "Pi away routing test ($label) printed output: $out"
  done <<'CASES'
check-trigger|branch|check: task-a.check.sh: PR merged|1\t1\tsignal\ttask-a.status\tsignal: task-a.status\n2\t2\tcheck\tmain-only\tcheck: task-a.check.sh: PR merged\n
check-only|branch|check: x-mention 1234567890|1\t1\tcheck\tmain-only\tcheck: x-mention 1234567890\n
needs-decision|branch|signal: task-a.status|1\t1\tsignal\ttask-a.status\tneeds-decision: [key=scope] skip or re-implement\n
unresolvable|main|signal: task-zz.status|1\t1\tsignal\ttask-zz.status\tsignal: task-zz.status\n
corrupt|main|signal: task-a.status|not a queue row\n
CASES

  # Only main can repair supervision itself: a watcher-failure alarm still
  # reaches main with the record present and a live, accepting branch listener.
  repo="$TMP_ROOT/pi-away-alarm-root"
  mkdir -p "$repo/bin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const offers = [];
let prompt = "";
let handler = null;
const handlers = new Map();
const bus = {
  on(channel, h) {
    handlers.set(channel, [...(handlers.get(channel) ?? []), h]);
    return () => {};
  },
  emit(channel, data) {
    for (const h of handlers.get(channel) ?? []) h(data);
  },
};
bus.on("fm-branch-supervision:dispatch", (offer) => {
  offers.push({ message: offer.message });
  offer.accept();
});
const pi = {
  on() {},
  events: bus,
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handler("", { ui: { notify() {} } });
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("external healthy watcher")) {
  throw new Error(`a watcher failure under the away-posture record did not reach main: ${prompt}`);
}
if (offers.length !== 0) {
  throw new Error(`a watcher failure was offered to the branch under the record: ${JSON.stringify(offers)}`);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "a watcher-failure alarm must still reach main under the record: $out"
  [ -z "$out" ] || fail "Pi away alarm test printed output: $out"
  pass "under the away-posture record every actionable row is offered to the branch while broken-queue wakes and watcher-failure alarms still reach main"
}

test_pi_handling_delivery_failure_is_typed_once() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-handling-fail-root"
  home="$TMP_ROOT/pi-handling-fail-home"
  log="$TMP_ROOT/pi-handling-fail.log"
  stop="$TMP_ROOT/pi-handling-fail.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'refused generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 1
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
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
await tool.execute("tool-call-handling-fail", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt.includes("handling delivery confirmation was rejected"); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) throw new Error(`missing follow-up: ${prompt}`);
if (!prompt.includes("handling delivery confirmation was rejected")) {
  throw new Error(`failed handshake was swallowed: ${prompt}`);
}
if ((prompt.match(/FIRSTMATE WATCHER WAKE/g) || []).length !== 1) {
  throw new Error(`failed handshake was not a single typed message: ${prompt}`);
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.filter((row) => row.startsWith("refused ")).length < 1) {
  throw new Error(`handling-delivered was never attempted: ${rows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must surface a refused handling handshake as one typed failure"
  [ -z "$out" ] || fail "Pi handling-delivery failure test printed output: $out"
  pass "Pi refused handling handshake is classified and not swallowed"
}

test_pi_confirm_failure_retires_arm_with_distinct_watcher_pid() {
  local repo home plugin log stop retired out status
  repo="$TMP_ROOT/pi-confirm-distinct-root"
  home="$TMP_ROOT/pi-confirm-distinct-home"
  log="$TMP_ROOT/pi-confirm-distinct.log"
  stop="$TMP_ROOT/pi-confirm-distinct.stop"
  retired="$TMP_ROOT/pi-confirm-distinct.retired"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'refused generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 1
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
sleep 0.02 & dead=$!; wait "$dead" 2>/dev/null || true
if [ "$dead" = "$$" ]; then dead=1; fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-distinct\n' "$dead"
trap 'printf "retired\n" > "${FM_RETIRED_FILE:?}"; exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_RETIRED_FILE="$retired" node --input-type=module 2>&1 <<'EOF'
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
await tool.execute("tool-call-confirm-distinct", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt.includes("handling delivery confirmation was rejected"); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("handling delivery confirmation was rejected")) {
  throw new Error(`failed handshake was swallowed: ${prompt}`);
}
let retired = false;
for (let i = 0; i < 250 && !retired; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
  retired = existsSync(process.env.FM_RETIRED_FILE);
}
if (!retired) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  throw new Error(`broken arm survived a failed confirmation with a distinct watcher pid: ${rows.join(" | ")}`);
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
const armRows = rows.filter((row) => row.startsWith("arm="));
if (armRows.length !== 2) throw new Error(`expected one successor arm, got ${armRows.length}: ${rows.join(" | ")}`);
const watcherPid = rows.find((row) => row.startsWith("refused "))?.split("watcher=")[1];
const armPid = armRows[1].split(" ")[0].slice("arm=".length);
if (!watcherPid || watcherPid === armPid) {
  throw new Error(`fixture did not use distinct arm and watcher pids: ${rows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must retire the failed arm when the watcher pid differs from the arm pid: $out"
  [ -z "$out" ] || fail "Pi confirm-distinct test printed output: $out"
  pass "Pi confirm failure retires the named arm with distinct watcher pid"
}

# A failed confirmation retires only the arm its own recovery token names.
# Here the restored successor has already exited (its stdout still held open,
# so its close never fires) and a manual repair has started a newer arm before
# the successor reports ready; the confirmation then fails with the
# successor's dead watcher pid, and the newer healthy arm must survive.
test_pi_confirm_failure_spares_a_newer_arm() {
  local repo home plugin log stop go retired out status
  repo="$TMP_ROOT/pi-confirm-newer-root"
  home="$TMP_ROOT/pi-confirm-newer-home"
  log="$TMP_ROOT/pi-confirm-newer.log"
  stop="$TMP_ROOT/pi-confirm-newer.stop"
  go="$TMP_ROOT/pi-confirm-newer.go"
  retired="$TMP_ROOT/pi-confirm-newer.retired"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'refused generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 1
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  sleep 0 & dead=$!; wait "$dead" 2>/dev/null || true
  (
    while [ ! -e "${FM_GO_FILE:?}" ] && [ -e "$0" ]; do sleep 0.02; done
    printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-stale\n' "$dead"
    while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.05; done
  ) &
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-newer\n' "$$"
trap 'printf "retired\n" > "${FM_RETIRED_FILE:?}"; exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ] && [ -e "$0" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_GO_FILE="$go" FM_RETIRED_FILE="$retired" node --input-type=module 2>&1 <<'EOF'
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
const armRows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((row) => row.startsWith("arm="))
  : [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-confirm-newer-first", {}, undefined, undefined, {});
for (let i = 0; i < 250 && armRows().length < 2; i += 1) await sleep(20);
if (armRows().length < 2) throw new Error("restoration never started a successor");
const successorPid = Number(armRows()[1].slice("arm=".length));
let dead = false;
for (let i = 0; i < 250 && !dead; i += 1) {
  try {
    process.kill(successorPid, 0);
    await sleep(20);
  } catch {
    dead = true;
  }
}
if (!dead) throw new Error(`successor pid ${successorPid} never exited`);
const repair = await tool.execute("tool-call-confirm-newer-repair", {}, undefined, undefined, {});
if (!repair.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`repair did not start a newer arm: ${repair.content[0].text}`);
}
for (let i = 0; i < 250 && armRows().length < 3; i += 1) await sleep(20);
if (armRows().length !== 3) throw new Error(`expected a newer third arm: ${armRows().join(" | ")}`);
const newerPid = Number(armRows()[2].slice("arm=".length));
writeFileSync(process.env.FM_GO_FILE, "go\n");
for (let i = 0; i < 250 && !prompt.includes("handling delivery confirmation was rejected"); i += 1) await sleep(20);
if (!prompt.includes("handling delivery confirmation was rejected")) {
  throw new Error(`the stale successor's confirmation never failed: ${prompt}`);
}
await sleep(200);
if (existsSync(process.env.FM_RETIRED_FILE)) {
  throw new Error("a failed confirmation for a stale successor retired the newer healthy arm");
}
process.kill(newerPid, 0);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must not retire a newer arm when a stale successor's confirmation fails: $out"
  [ -z "$out" ] || fail "Pi confirm-newer test printed output: $out"
  pass "Pi confirm failure for a stale successor spares the newer arm"
}

# A marker that advanced mid-restore supersedes the in-flight delivery: the
# shell reports a generation mismatch (status 3), so the wake must be
# delivered with no rejection appendix, nothing may be retired, and the
# attempt plus the confirm result must land in the bounded extension log.
# The log assertions run opted in (FM_WATCH_EXTENSION_LOG_KEEP_LINES=50
# below); the default-off contract lives in
# test_pi_extension_log_stays_off_unless_opted_in.
test_pi_superseded_delivery_has_no_rejection_appendix() {
  local repo home plugin log stop out status extension_log
  repo="$TMP_ROOT/pi-handling-superseded-root"
  home="$TMP_ROOT/pi-handling-superseded-home"
  log="$TMP_ROOT/pi-handling-superseded.log"
  stop="$TMP_ROOT/pi-handling-superseded.stop"
  extension_log="$home/state/.watch-extension.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_EXTENSION_LOG_KEEP_LINES=50 node --input-type=module 2>&1 <<'EOF'
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
)
  status=$?
  expect_code 0 "$status" "Pi must deliver a superseded wake with no rejection appendix: $out"
  [ -z "$out" ] || fail "Pi superseded-delivery test printed output: $out"
  [ -f "$extension_log" ] || fail "Pi extension recorded no bounded restore/confirm log"
  grep -qF "restore attempt=" "$extension_log" \
    || fail "extension log has no restore attempt: $(cat "$extension_log")"
  grep -qF "result=superseded" "$extension_log" \
    || fail "extension log has no superseded confirm result: $(cat "$extension_log")"
  pass "Pi superseded handling delivery carries no rejection appendix and is logged"
}
