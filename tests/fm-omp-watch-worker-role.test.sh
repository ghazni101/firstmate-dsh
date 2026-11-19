#!/usr/bin/env bash
# tests/fm-omp-watch-worker-role.test.sh - a Firstmate-launched crewmate or
# scout omp pane must never activate the tracked primary watcher bridge, and its
# own turn-end rows must drain instead of accumulating while it is idle.
# shellcheck disable=SC2034 # TMP_ROOT is consumed by the sourced case helpers
set -u

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-watch-worker-role)
EXT="$ROOT/.omp/extensions/fm-primary-omp-watch.ts"

install_omp_watch_fixture() { # <repo> <home>
  local repo=$1 home=$2
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin" \
    "$repo/node_modules/typebox" "$home/state" "$home/config"
  cp "$EXT" "$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
    "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) { return { type: "object", properties, additionalProperties: false }; },
};
JS
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "$FM_TEST_ARM_LOG"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
}

# Drive the real extension through a stub omp API and record everything a pane
# could observe: handler registrations, tools, injected user messages, and the
# child the arm would spawn. The role is the only difference between calls.
run_bridge() { # <repo> <home> <out> <role>
  local repo=$1 home=$2 out=$3 role=$4
  PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_OMP_ROLE="$role" OUT="$out" \
    NODE_NO_WARNINGS=1 node --input-type=module <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const events = [];
const handlers = {};
const pi = {
  on(name, handler) { events.push(`on:${name}`); handlers[name] = handler; },
  registerTool(tool) { events.push(`tool:${tool.name}`); },
  registerCommand(name) { events.push(`command:${name}`); },
  sendUserMessage(content) { events.push(`message:${String(content).slice(0, 160)}`); },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
for (const name of ["session_start", "before_agent_start", "message_start"]) {
  const handler = handlers[name];
  if (!handler) continue;
  try {
    await handler({}, { ui: { notify() {} } });
  } catch (error) {
    events.push(`handler-error:${name}:${error.message}`);
  }
}
await new Promise((resolve) => setTimeout(resolve, 400));
writeFileSync(process.env.OUT, `${events.join("\n")}\n`);
process.exit(0);
EOF
}

test_worker_role_keeps_bridge_inactive() {
  local dir repo home out arm_log queue
  dir=$(make_case worker-role)
  repo="$dir/repo"
  home="$dir/home"
  out="$dir/events"
  arm_log="$dir/arm.log"
  install_omp_watch_fixture "$repo" "$home"
  queue="$home/state/.wake-queue"
  printf 'seed\t1\tsignal\tother.status\tsignal: other\n' > "$queue"

  FM_TEST_ARM_LOG="$arm_log" run_bridge "$repo" "$home" "$out" worker

  [ ! -s "$arm_log" ] || fail "a crewmate/scout pane spawned a watcher arm child"
  [ ! -e "$home/state/.omp-watch-extension-loaded" ] \
    || fail "a crewmate/scout pane marked the watcher bridge loaded"
  ! grep -q '^on:' "$out" || fail "a crewmate/scout pane registered watcher handlers"
  ! grep -q '^tool:' "$out" || fail "a crewmate/scout pane registered the arm tool"
  ! grep -q '^message:' "$out" || fail "a crewmate/scout pane injected a watcher message"
  ! grep -q 'FIRSTMATE_OP' "$out" || fail "a crewmate/scout pane emitted encoded operational input"
  [ "$(cat "$queue")" = 'seed	1	signal	other.status	signal: other' ] \
    || fail "a crewmate/scout pane changed the home wake queue"
  pass "a crewmate/scout omp pane activates no watcher bridge"
}

test_primary_without_marker_still_arms() {
  local dir repo home out arm_log
  dir=$(make_case primary-role)
  repo="$dir/repo"
  home="$dir/home"
  out="$dir/events"
  arm_log="$dir/arm.log"
  install_omp_watch_fixture "$repo" "$home"

  FM_TEST_ARM_LOG="$arm_log" run_bridge "$repo" "$home" "$out" ''

  grep -q '^on:session_start$' "$out" || fail "a primary pane did not register session_start"
  [ -s "$arm_log" ] || fail "a primary pane did not spawn its watcher arm child"
  pass "an omp pane without the worker marker keeps the watcher bridge active"
}

test_worker_turn_end_rows_drain() {
  local dir state out err i rows
  dir=$(make_case turnend-drain)
  state="$dir/state"
  i=1
  while [ "$i" -le 3 ]; do
    : > "$state/worker.turn-ended"
    append_wake "$state" signal "worker.turn-ended" \
      "signal: $state/worker.turn-ended"
    out="$dir/drain-$i.out"
    err="$dir/drain-$i.err"
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$out" 2> "$err" \
      || fail "drain $i failed"
    grep -q 'worker.turn-ended' "$out" || fail "turn-end row $i was not presented"
    ack_drain_err "$state" "$err" || fail "turn-end row $i could not be acknowledged"
    [ ! -s "$state/.wake-queue" ] \
      || fail "turn-end row $i stayed queued after acknowledgement"
    rows=$(wc -l < "$state/.wake-queue" 2>/dev/null || printf '0\n')
    [ "${rows//[[:space:]]/}" = 0 ] || fail "turn-end rows accumulated at turn $i"
    i=$((i + 1))
  done
  pass "worker turn-end rows drain each turn instead of accumulating"
}

test_worker_role_keeps_bridge_inactive
test_primary_without_marker_still_arms
test_worker_turn_end_rows_drain
