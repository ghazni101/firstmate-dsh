# shellcheck shell=bash
# Test cases for fm-backend-herdr, split out of tests/fm-backend-herdr.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-backend-herdr.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


# make_herdr_fakebin: a `herdr` stub that logs every invocation (one line,
# unit-separated args, to $FM_HERDR_LOG) and returns the canned response for
# that call read from $FM_HERDR_RESPONSES/<n>.out, consumed IN ORDER (call 1
# reads 1.out, call 2 reads 2.out, ...) so a test can script a short sequence
# of calls precisely. A missing response file means "succeed with empty
# stdout" (mirrors send-text/send-keys/pane close/tab close, which are silent
# on success in the real CLI - verified in herdr-verification-p2.md).
make_herdr_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ] && [ "${FM_HERDR_SCRIPT_STATUS:-0}" != 1 ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
if [ "${1:-}" = terminal ] && [ "${2:-}" = title ] && [ "${3:-}" = clear ]; then
  reason=${FM_FAKE_HERDR_FOREGROUND_REASON:-no_foreground_client}
  printf '{"result":{"reason":"%s"}}\n' "$reason"
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
[ -f "$RESP/$n.err" ] && cat "$RESP/$n.err" >&2
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# herdr_submit_shift: move every canned response <by> slots later, so a
# fixture numbered from the literal send can take new calls in front of it.
herdr_submit_shift() {  # <resp-dir> <by>
  local resp=$1 by=$2 n ext f sorted
  local -a found=()
  shopt -s nullglob
  for f in "$resp"/*.out "$resp"/*.exit; do
    n=$(basename "$f")
    n=${n%%.*}
    found+=("$n")
  done
  shopt -u nullglob
  [ "${#found[@]}" -gt 0 ] || return 0
  sorted=$(printf '%s\n' "${found[@]}" | sort -rn -u)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    for ext in out exit; do
      f="$resp/$n.$ext"
      if [ -f "$f" ]; then
        mv "$f" "$resp/$((n + by)).$ext"
      fi
    done
  done <<EOF
$sorted
EOF
}

# herdr_submit_identity_prefix: submit first asks `agent get` which harness
# the pane runs. A non-Claude harness skips the payload proof, so a fixture
# numbered for the old send-text-first sequence moves one slot later.
herdr_submit_identity_prefix() {  # <resp-dir> <agent>
  herdr_submit_shift "$1" 1
  printf '{"result":{"agent":{"agent":"%s","agent_status":"idle"}}}\n' "$2" > "$1/1.out"
}

# herdr_submit_claude_prefix: a Claude pane adds the identity probe, an empty
# composer read before the send, and a composer read after it. Call 1 is the
# identity, call 2 the empty composer, call 3 the literal send, and call 4 the
# composer holding <text>. Old call N (N >= 2) moves to N + 3.
herdr_submit_claude_prefix() {  # <resp-dir> <typed-text>
  local resp=$1 text=$2
  herdr_submit_shift "$resp" 3
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/2.out"
  printf '  \xe2\x9d\xaf %s\n' "$text" > "$resp/4.out"
}

# herdr_submit_preflight_prefix: fm_backend_send_text_submit reads the composer
# once before the adapter types. That read is call 1 and shows an empty
# composer, so every adapter call moves one slot later.
herdr_submit_preflight_prefix() {  # <resp-dir>
  herdr_submit_shift "$1" 1
  printf '  \xe2\x9d\xaf\n' > "$1/1.out"
}

# make_herdr_server_env_fakebin: a stateful server stub that records only the
# long-lived server launch environment, then reports the server as running.
make_herdr_server_env_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    if [ -e "$FM_HERDR_SERVER_MARKER" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  server)
    {
      for name in FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_SUPERVISION_MODEL FM_HERDR_SENTINEL HERDR_SESSION; do
        eval 'value=${'"$name"'-<unset>}'
        printf '%s=%s\n' "$name" "$value"
      done
      printf 'args=%s\n' "$*"
    } > "$FM_HERDR_SERVER_ENV_LOG"
    : > "$FM_HERDR_SERVER_MARKER"
    ;;
esac
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# make_herdr_owned_server_fakebin: a stateful server stub for the ownership
# markers. `status` reports its socket in $FM_HERDR_SESSION_DIR, reports running while $FM_HERDR_SERVER_MARKER exists and counts each
# read in $FM_HERDR_STATUS_COUNT, and `server` records its launch in
# $FM_HERDR_START_LOG. A `sleep` stub returns at once and counts each wait in
# $FM_HERDR_SLEEP_COUNT; when $FM_HERDR_FLIP_AFTER is set, the wait with that
# number applies $FM_HERDR_FLIP: `up` brings the server up and ends the
# replacement, `clear` only ends the replacement, mimicking an owner that
# finishes its work while Firstmate waits.
make_herdr_owned_server_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json")
    echo $(( $(cat "$FM_HERDR_STATUS_COUNT" 2>/dev/null || echo 0) + 1 )) > "$FM_HERDR_STATUS_COUNT"
    if [ -e "$FM_HERDR_SERVER_MARKER" ]; then
      printf '{"server":{"running":true,"socket":"%s/herdr.sock"}}\n' "$FM_HERDR_SESSION_DIR"
    else
      printf '{"server":{"running":false,"socket":"%s/herdr.sock"}}\n' "$FM_HERDR_SESSION_DIR"
    fi
    ;;
  server*)
    echo started >> "$FM_HERDR_START_LOG"
    : > "$FM_HERDR_SERVER_MARKER"
    ;;
esac
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
set -u
n=$(( $(cat "$FM_HERDR_SLEEP_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FM_HERDR_SLEEP_COUNT"
if [ -n "${FM_HERDR_FLIP_AFTER:-}" ] && [ "$n" -eq "$FM_HERDR_FLIP_AFTER" ]; then
  rm -f "$FM_HERDR_SESSION_DIR/firstmate-server-replacing"
  [ "${FM_HERDR_FLIP:-}" != up ] || : > "$FM_HERDR_SERVER_MARKER"
fi
SH
  chmod +x "$fb/herdr" "$fb/sleep"
  printf '%s\n' "$fb"
}

# make_herdr_statefake: a STATEFUL `herdr` stub that models the parts of herdr's
# real container behavior the workspace-leak fix (and the default-tab-prune
# safety fix) depend on, so a full spawn->teardown cycle can be replayed
# repeatedly and the "one persistent firstmate workspace, no orphans"
# invariant asserted end to end (the canned, call-numbered make_herdr_fakebin
# above cannot model state carried ACROSS calls). Backed by a JSON state file
# ($FM_FAKE_HERDR_STATE) mutated with real jq. Modeled behaviors, all
# verified real-herdr facts recorded in docs/herdr-backend.md: `workspace
# create` seeds the new workspace with one auto-created default tab (label
# "1") and returns that tab's tab_id/pane_id in the SAME response
# (`.result.tab.tab_id` / `.result.root_pane.pane_id`, verified empirically
# against the real binary); `pane close` removes the pane's single-pane tab
# (closing a tab's only pane closes the tab); `workspace list` / `tab list` /
# `pane list` reflect live state; `agent get <pane>` reports the pane's preset
# agent_status (set via fake_herdr_set_agent_status, never through a CLI
# call - mirrors an out-of-band agent registering itself) or an
# agent_not_found error when none was preset (verified real-herdr behavior for
# a pane with no registered agent). Every call is logged to $FM_HERDR_LOG in
# the same unit-separated form as make_herdr_fakebin.
make_herdr_statefake() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; label=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "terminal title")
    printf '{"result":{"reason":"no_foreground_client"}}\n'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "tab close")
    tab=${3:-}
    jq_state --arg t "$tab" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "agent get")
    pane=${3:-}
    status=$(jq_state -r --arg p "$pane" '.agent_status[$p] // empty')
    if [ -n "$status" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# fake_herdr_set_agent_status: preset <pane_id>'s agent_status in the
# stateful fake's state file, mirroring an agent registering itself
# out-of-band (never through a CLI call the adapter itself would make).
# Used to exercise fm_backend_herdr_workspace_prune_seeded_default_tab's
# defense-in-depth refuse-if-busy check.
fake_herdr_set_agent_status() {  # <state-file> <pane_id> <status>
  local state=$1 pane=$2 status=$3 tmp="$1.tmp.$$"
  jq --arg p "$pane" --arg s "$status" '.agent_status[$p] = $s' "$state" > "$tmp" && mv "$tmp" "$state"
}

# herdr_case <name> -> sets up FM_HERDR_LOG/FM_HERDR_RESPONSES/fb for one test,
# registers cleanup-free tmp dirs under TMP_ROOT.
herdr_env() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/responses"
  : > "$dir/log"
  printf '%s\n%s\n' "$dir/log" "$dir/responses"
}

# --- version_check / tool_check ----------------------------------------------

test_version_check_accepts_current_protocol() {
  local dir log resp fb status
  dir="$TMP_ROOT/version-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.7.1","channel":"stable","protocol":14}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept protocol 14 (>= the verified minimum)"
  assert_contains "$(cat "$log")" $'\x1f''status'$'\x1f''--json' "version_check did not call herdr status --json"
  pass "fm_backend_herdr_version_check: accepts the current protocol (14)"
}

test_version_check_refuses_old_protocol() {
  local dir log resp fb out status
  dir="$TMP_ROOT/version-old"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.3.0","channel":"stable","protocol":5}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse protocol 5 (below min)"
  assert_contains "$out" "protocol 5" "version_check error did not name the rejected protocol"
  pass "fm_backend_herdr_version_check: refuses an old protocol loudly"
}

test_version_check_refuses_missing_herdr() {
  local dir out status
  dir="$TMP_ROOT/version-missing"; mkdir -p "$dir/empty-fakebin"
  # Hermetic PATH: the fakebin carries only bash (so the inner `bash -c`
  # still resolves) and no system dir, so a real herdr installed under
  # /usr/bin (or /bin -> usr/bin) cannot leak into this "not installed"
  # simulation. fm_backend_herdr_tool_check needs no external tool on this
  # path: `command -v` is a builtin and it short-circuits on herdr first.
  ln -sf "$(command -v bash)" "$dir/empty-fakebin/bash"
  out=$( PATH="$dir/empty-fakebin" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse when herdr is not installed"
  assert_contains "$out" "not installed" "version_check did not report herdr as missing"
  pass "fm_backend_herdr_version_check: refuses loudly when herdr is not installed"
}

# --- workspace_label: per-firstmate-HOME resolution (P3, herdr-sm-spaces-k4) -

test_workspace_label_primary_home_no_marker() {
  local home
  home="$TMP_ROOT/primary-home-no-marker"; mkdir -p "$home"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "firstmate" ] || fail "a primary home (no .fm-secondmate-home marker) should resolve to label 'firstmate', got '$out'"
  pass "fm_backend_herdr_workspace_label: a primary home (no marker) resolves to 'firstmate'"
}

test_workspace_label_secondmate_home_uses_marker_id() {
  local home
  home="$TMP_ROOT/secondmate-home"; mkdir -p "$home"
  printf 'sshhip-h7\n' > "$home/.fm-secondmate-home"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "2ndmate-sshhip-h7" ] || fail "a secondmate home should resolve to '2ndmate-<id>', got '$out'"
  pass "fm_backend_herdr_workspace_label: a secondmate home (.fm-secondmate-home) resolves to '2ndmate-<id>'"
}

test_workspace_label_secondmate_marker_trims_whitespace() {
  local home
  home="$TMP_ROOT/secondmate-home-ws"; mkdir -p "$home"
  printf '  sshhip-h7  \n\n' > "$home/.fm-secondmate-home"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "2ndmate-sshhip-h7" ] || fail "the marker id should be trimmed of surrounding whitespace, got '$out'"
  pass "fm_backend_herdr_workspace_label: trims whitespace around the marker's secondmate id"
}

test_workspace_label_empty_marker_falls_back_to_primary() {
  local home
  home="$TMP_ROOT/secondmate-home-empty"; mkdir -p "$home"
  : > "$home/.fm-secondmate-home"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "firstmate" ] || fail "an empty/unreadable marker should fall back to 'firstmate', got '$out'"
  pass "fm_backend_herdr_workspace_label: an empty marker file falls back to the primary label 'firstmate'"
}

test_workspace_label_different_secondmates_get_different_labels() {
  local home1 home2 out1 out2
  home1="$TMP_ROOT/secondmate-a"; mkdir -p "$home1"; printf 'alpha-a1\n' > "$home1/.fm-secondmate-home"
  home2="$TMP_ROOT/secondmate-b"; mkdir -p "$home2"; printf 'bravo-b2\n' > "$home2/.fm-secondmate-home"
  out1=$( FM_HOME="$home1" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  out2=$( FM_HOME="$home2" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out1" = "2ndmate-alpha-a1" ] || fail "secondmate home1 label mismatch: $out1"
  [ "$out2" = "2ndmate-bravo-b2" ] || fail "secondmate home2 label mismatch: $out2"
  [ "$out1" != "$out2" ] || fail "two different secondmate homes must not collide on the same label"
  pass "fm_backend_herdr_workspace_label: two different secondmate homes get two different, non-colliding labels"
}

test_workspace_label_config_file_names_the_primary_workspace() {
  local home out
  home="$TMP_ROOT/primary-configured"; mkdir -p "$home/config"
  printf 'fm-dsh\n' > "$home/config/herdr-workspace"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "fm-dsh" ] || fail "a primary home with config/herdr-workspace 'fm-dsh' should resolve to 'fm-dsh', got '$out'"
  pass "fm_backend_herdr_workspace_label: config/herdr-workspace names the primary home's workspace label"
}

test_workspace_label_config_file_trims_surrounding_whitespace_only() {
  local home out
  home="$TMP_ROOT/primary-configured-padded"; mkdir -p "$home/config"
  printf '\n  fm-dsh  \n\n' > "$home/config/herdr-workspace"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "fm-dsh" ] || fail "surrounding whitespace should be trimmed from config/herdr-workspace, got '$out'"
  pass "fm_backend_herdr_workspace_label: trims surrounding whitespace around a configured label"
}

test_workspace_label_config_honors_config_override() {
  local home cfg out
  home="$TMP_ROOT/primary-config-override-home"; mkdir -p "$home"
  cfg="$TMP_ROOT/primary-config-override-dir"; mkdir -p "$cfg"
  printf 'fm-other\n' > "$cfg/herdr-workspace"
  out=$( FM_HOME="$home" FM_CONFIG_OVERRIDE="$cfg" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "fm-other" ] || fail "FM_CONFIG_OVERRIDE should select the config dir holding herdr-workspace, got '$out'"
  pass "fm_backend_herdr_workspace_label: reads the configured label from FM_CONFIG_OVERRIDE's config dir"
}

test_workspace_label_empty_config_file_keeps_the_default() {
  local home out
  home="$TMP_ROOT/primary-configured-empty"; mkdir -p "$home/config"
  : > "$home/config/herdr-workspace"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "firstmate" ] || fail "an empty config/herdr-workspace should keep 'firstmate', got '$out'"
  pass "fm_backend_herdr_workspace_label: an empty config/herdr-workspace keeps the 'firstmate' default"
}

test_workspace_label_unusable_config_value_is_refused() {
  local home value out status
  home="$TMP_ROOT/primary-configured-bad"; mkdir -p "$home/config"
  for value in 'fm dsh' 'fm:dsh' 'fm/dsh' '└ fm-dsh · p:AAAAAAAAAAAAAAAAAAAAAA'; do
    printf '%s\n' "$value" > "$home/config/herdr-workspace"
    out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" 2>&1 )
    status=$?
    [ "$status" -ne 0 ] || fail "config/herdr-workspace '$value' should be refused, got success with '$out'"
    assert_contains "$out" "unusable herdr workspace label" "the refusal for '$value' did not name the unusable label"
    assert_contains "$out" "$home/config/herdr-workspace" "the refusal for '$value' did not name the offending file"
  done
  pass "fm_backend_herdr_workspace_label: refuses an unusable configured value with an actionable error instead of falling back"
}

test_workspace_label_secondmate_marker_wins_over_config() {
  local home out
  home="$TMP_ROOT/secondmate-configured"; mkdir -p "$home/config"
  printf 'alpha-a1\n' > "$home/.fm-secondmate-home"
  printf 'fm-dsh\n' > "$home/config/herdr-workspace"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "2ndmate-alpha-a1" ] || fail "a secondmate home's marker must win over config/herdr-workspace, got '$out'"
  pass "fm_backend_herdr_workspace_label: the secondmate marker keeps precedence over config/herdr-workspace"
}

# --- fm_backend_herdr_cli: session targeting (2026-07-02 incident fix) -------

test_cli_helper_sets_env_and_appends_trailing_session_flag() {
  local dir log resp fb
  dir="$TMP_ROOT/cli-helper"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_cli fmtest workspace list' "$ROOT"
  expect_code 0 $? "fm_backend_herdr_cli should succeed"
  assert_contains "$(cat "$log")" "HERDR_SESSION=fmtest"$'\x1f''workspace'$'\x1f''list' \
    "fm_backend_herdr_cli did not set the HERDR_SESSION env var"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''list'$'\x1f''--session'$'\x1f''fmtest' \
    "fm_backend_herdr_cli did not append a trailing --session <name> flag (the fix for the env-var-alone routing bug)"
  pass "fm_backend_herdr_cli: sets HERDR_SESSION AND appends a trailing --session flag on every call"
}

# --- client selection: a stale client shadowing a compatible one -------------
#
# Two herdr clients on PATH is a real host shape (a self-updated ~/.local/bin
# copy next to a package-managed one), and the fixed remote-job PATH resolves
# ~/.local/bin first. A client older than the running server answers every
# command with error code protocol_mismatch (verified: herdr 0.8.2, protocol
# 20, against a 0.9.0 server, protocol 22), and until the adapter learned to
# step around it, a live remote secondmate read `unreadable`, every doorbell
# into it failed, and the relaunch that would repair it was refused.

# run_with_clients <dir> <path-dirs...> -- <bash -c body>: sources the adapter
# in a fresh shell whose PATH holds exactly the named client directories plus
# jq and the system tail, so no herdr from the runner's own PATH can leak in.
# Bodies are bash -c sources, so their single-quoted $ expansions are
# deliberate (SC2016).
# shellcheck disable=SC2016
run_with_clients() {  # <dir> <path> <body>
  local dir=$1 path=$2 body=$3
  FM_HERDR_PAIR_DIR="$dir" PATH="$path:$dir/tools:/usr/bin:/bin" \
    bash -c ". \"\$0/bin/backends/herdr.sh\"; $body" "$ROOT"
}

# The #4091 widening, and the boundary it is deliberately confined to.
#
# A recovery-grade read that cannot confirm the pane is `missing` only when the
# session's server is POSITIVELY stopped - absence for that whole session -
# and stays `unreadable` otherwise. The two signals are driven apart here on
# purpose: the SAME failed pane read is settled two ways by the server state
# alone, so the case cannot go quietly vacuous if one signal stops being read.
#
# The second half matters as much as the first: the widening must not reach the
# husk classifier under it, because that one licenses CLOSING panes.
test_recovery_grade_read_widens_only_at_its_own_boundary() {
  local dir log resp fb gone running husk

  herdr_state_with_server() {  # <dir-suffix> <server-running-json>
    local dir="$TMP_ROOT/recovery-widen-$1" resp log fb
    mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
    # 1: the pane read, failing in a way this parse cannot interpret.
    printf 'Error: socket unavailable\n' > "$resp/1.out"
    printf '1\n' > "$resp/1.exit"
    # 2: the server-state read that settles it.
    printf '{"client":{"protocol":22},"server":{"running":%s}}\n' "$2" > "$resp/2.out"
    fb=$(make_herdr_fakebin "$dir")
    PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p2' "$ROOT"
  }

  gone=$(herdr_state_with_server gone false)
  running=$(herdr_state_with_server running true)
  [ "$gone" = missing ] \
    || fail "an uninterpretable pane read against a positively stopped server must read missing, got '$gone'"
  [ "$running" = unreadable ] \
    || fail "an uninterpretable pane read against a RUNNING server must stay unreadable, got '$running'"
  [ "$gone" != "$running" ] \
    || fail "the server-state signal is not being consulted: both verdicts are '$gone'"

  # An unreadable server state is not evidence of absence either.
  dir="$TMP_ROOT/recovery-widen-unknown"; mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  printf 'Error: socket unavailable\n' > "$resp/1.out"; printf '1\n' > "$resp/1.exit"
  printf 'not json at all\n' > "$resp/2.out"; printf '1\n' > "$resp/2.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p2' "$ROOT")
  [ "$out" = unreadable ] \
    || fail "a server state that cannot itself be read must keep the conservative verdict, got '$out'"

  # The confinement: the husk classifier sees the SAME stopped-server read and
  # must still refuse, because it is what licenses closing a pane.
  dir="$TMP_ROOT/recovery-widen-husk"; mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  printf 'Error: socket unavailable\n' > "$resp/1.out"; printf '1\n' > "$resp/1.exit"
  printf '{"client":{"protocol":22},"server":{"running":false}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  husk=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state fmtest w1:p2; printf " "; fm_backend_herdr_tab_is_husk fmtest w1:p2 && printf husk || printf refused' "$ROOT")
  [ "$husk" = "unknown refused" ] \
    || fail "the stopped-server rule leaked into the husk classifier, which licenses closing panes: got '$husk'"
  pass "herdr recovery-grade read: a stopped server means missing there, and nowhere else"
}

# --- stale agent registration over a shell-only pane (issue #4115) -----------
#
# Herdr keeps a Pi registration (`agent get` -> agent=pi, agent_status=idle)
# after the Pi process has exited to a plain shell whenever a nested interactive
# shell sits under the pane's top shell (the `treehouse get` crew shape;
# reproduced on Herdr 0.9.0 - docs/verification/runtime-backends.md "Stale agent
# registration"). Trusting that registration alone classified the pane `live`,
# so every relaunch and recovery was refused forever. The classifier must now
# prove an agent at process level before reporting one, exactly as the tmux
# adapter does, and a registration with no live agent process is agent-free
# with an explicit reason.
#
# The fixture pairs a canned `pane process-info` body with REAL processes:
# the shell pid it names is a real process this test owns, so the descendant
# walk runs against the real operating-system process table.

stale_registration_case() {  # <dir-suffix> <agent_status> <process-info-body|-> [process-info-exit]
  local dir="$TMP_ROOT/stale-reg-$1" resp log fb n
  mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  # The probe below classifies the same pane three times (pane state, the
  # recovery-grade read, the husk check), and the canned fake consumes
  # responses in call order, so the same three-call script is laid down for
  # each pass:
  for n in 0 3 6; do
    # +1: pane get -> the pane structurally exists
    printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/$((n + 1)).out"
    # +2: agent get -> a registered agent with the given status
    printf '{"result":{"agent":{"agent":"pi","agent_status":"%s"}}}\n' "$2" > "$resp/$((n + 2)).out"
    # +3: pane process-info -> the pane's actual process view
    [ "$3" = - ] || printf '%s\n' "$3" > "$resp/$((n + 3)).out"
    [ -z "${4:-}" ] || printf '%s\n' "$4" > "$resp/$((n + 3)).exit"
  done
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"
      printf "%s %s " "$(fm_backend_herdr_pane_agent_state fmtest w1:p2)" "$(fm_backend_herdr_agent_state fmtest:w1:p2)"
      fm_backend_herdr_tab_is_husk fmtest w1:p2 && printf husk || printf refused' "$ROOT"
}

shell_only_process_info() {  # <shell-pid>
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"],"cmdline":"-zsh"}]}}}' "$1" "$1" "$1"
}

test_stale_registration_over_a_shell_only_pane_is_agent_free() {
  local sleep_bin shell_pid out
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  # A real, childless process stands in for the pane's shell.
  "$sleep_bin" 300 &
  shell_pid=$!
  out=$(stale_registration_case shell-only idle "$(shell_only_process_info "$shell_pid")")
  kill "$shell_pid" 2>/dev/null || true
  [ "$out" = "stale-agent dead refused" ] \
    || fail "a registered idle agent over a shell-only pane must read stale-agent, recover as dead, and still refuse husk closing; got '$out'"
  pass "herdr stale registration: a shell-only pane with a lingering Pi record is agent-free with an explicit reason"
}

test_stale_registration_ignores_status_and_reads_the_process() {
  local sleep_bin shell_pid out status
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  shell_pid=$!
  for status in working 'done' blocked; do
    out=$(stale_registration_case "shell-only-$status" "$status" "$(shell_only_process_info "$shell_pid")")
    [ "$out" = "stale-agent dead refused" ] \
      || { kill "$shell_pid" 2>/dev/null; fail "a lingering '$status' record over a shell-only pane must still read stale-agent/dead, got '$out'"; }
  done
  kill "$shell_pid" 2>/dev/null || true
  pass "herdr stale registration: no registered status can outrank a shell-only process view"
}

test_registered_agent_with_a_live_foreground_process_stays_alive() {
  local out
  # The real Pi shape on Herdr 0.9.0: the kernel name is the interpreter and
  # only argv0 says pi.
  out=$(stale_registration_case live-pi idle \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4243,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi","argv":["pi"],"cmdline":"pi"}]}}}')
  [ "$out" = "live alive refused" ] \
    || fail "a registered agent whose foreground process is Pi must stay live/alive, got '$out'"
  pass "herdr stale registration: a registered agent with a live Pi foreground process still reads alive"
}

# --- the foreground-occupant session proof ----------------------------------
#
# fm_backend_herdr_pane_owns_session is the herdr equivalent of the tmux
# pane_pid ancestor + tpgid proof the hand-back retry makes before delivery:
# the pane's own process-info must name a shell pid that is an ancestor-or-self
# of the pinned pid AND that pid's process group must be the pane's foreground
# group. The canned `pane process-info` body is paired with a real child
# process so the ancestry walk and pgid read run against the real process
# table, and every foreign, malformed, or unreadable half refuses.

owns_session_process_info() {  # <shell-pid> <fg-pgid>
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[]}}}' "$1" "$2"
}

owns_session_case() {  # <process-info-body|-> <pid> [process-info-exit]
  local dir resp log fb
  dir=$(mktemp -d "$TMP_ROOT/owns-session.XXXXXX")
  mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  [ "$1" = - ] || printf '%s\n' "$1" > "$resp/1.out"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_owns_session fmtest w1:p2 "$1"' "$ROOT" "$2"
}

test_pane_owns_session_proves_the_foreground_occupant() {
  local sleep_bin pid pgid
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  pid=$!
  pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  # shell_pid = the suite's own pid $$ - a real ancestor of the child.
  owns_session_case "$(owns_session_process_info "$$" "$pgid")" "$pid" \
    || { kill "$pid" 2>/dev/null; fail "a real ancestor shell pid plus a matching foreground group must prove ownership"; }
  # shell_pid = the pinned pid itself - the pane's top process IS the session.
  owns_session_case "$(owns_session_process_info "$pid" "$pgid")" "$pid" \
    || { kill "$pid" 2>/dev/null; fail "a pane whose top process is the session must prove ownership"; }
  if owns_session_case "$(owns_session_process_info 999999 "$pgid")" "$pid" \
    || owns_session_case "$(owns_session_process_info "$$" 999999)" "$pid" \
    || owns_session_case - "$pid" 1 \
    || owns_session_case "$(owns_session_process_info 1 "$pgid")" "$pid" \
    || owns_session_case "$(owns_session_process_info "$$" "$pgid")" not-a-pid; then
    kill "$pid" 2>/dev/null
    fail "a foreign shell pid, foreign foreground group, unreadable read, invalid shell pid, or invalid pid must all refuse"
  fi
  kill "$pid" 2>/dev/null || true
  pass "herdr pane owns session: the foreground-occupant proof accepts only the real ancestry plus foreground group"
}

# --- the bound agent session reference (relaunch session continuity) --------
#
# Herdr applies only reports carrying the session identity it bound to a pane,
# and that registration survives its agent process in the crew shape above. A
# worker relaunched with a FRESH session therefore reports into a pane that
# ignores it and reads idle while it works. bin/fm-spawn.sh hands the
# replacement the reference this read returns: the exact identity the
# endpoint's own runtime recorded, never a guess about which session looks
# recent. It must return that record and nothing else - a reference handed to
# `pi --session` is a launch input, so an unreadable, foreign-shaped, or
# non-resumable value degrades to the ordinary fresh launch.
pane_agent_session_ref_read() {  # <agent-get-body> [exit-status]
  local dir resp log fb
  dir=$(mktemp -d "$TMP_ROOT/session-ref.XXXXXX")
  mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  printf '%s\n' "$1" > "$resp/1.out"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_session_ref fmtest w1:p2' "$ROOT"
}

test_pane_agent_session_ref_reports_a_resumable_reference_with_its_agent() {
  local out
  out=$(pane_agent_session_ref_read \
    '{"result":{"agent":{"agent":"pi","agent_status":"stale","agent_session":{"agent":"pi","kind":"path","source":"herdr:pi","value":"/home/u/.pi/agent/sessions/--wt--/2026-09-20T07-14-40-136Z_01a0bdaa.jsonl"}}}}')
  [ "$out" = $'pi\t/home/u/.pi/agent/sessions/--wt--/2026-09-20T07-14-40-136Z_01a0bdaa.jsonl' ] \
    || fail "an absolute path reference must be reported with its agent label, got '$out'"

  out=$(pane_agent_session_ref_read \
    '{"result":{"agent":{"agent":"pi","agent_session":{"agent":"pi","kind":"id","source":"herdr:pi","value":"01a0bdaa-c387-749d-966c-0dcd96a4b755"}}}}')
  [ "$out" = $'pi\t01a0bdaa-c387-749d-966c-0dcd96a4b755' ] \
    || fail "a bare session id must be reported as-is, got '$out'"
  pass "herdr pane agent session: a resumable reference is reported with the agent label that reported it"
}

test_pane_agent_session_ref_degrades_to_nothing_when_not_resumable() {
  local out body
  for body in \
    '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}' \
    '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}' \
    '{"result":{"agent":{"agent":"pi","agent_session":{"agent":"pi","kind":"path","value":"relative/session.jsonl"}}}}' \
    '{"result":{"agent":{"agent":"pi","agent_session":{"agent":"pi","kind":"id","value":"not a token"}}}}' \
    '{"result":{"agent":{"agent":"pi","agent_session":{"agent":"pi","kind":"id","value":""}}}}' \
    '{"result":{"agent":{"agent":"pi","agent_session":{"agent":"pi","kind":"opaque","value":"whatever"}}}}' \
    'not json at all'; do
    out=$(pane_agent_session_ref_read "$body") \
      && fail "an unresumable registration must report nothing resumable, but the read succeeded for: $body"
    [ -z "$out" ] \
      || fail "an unresumable registration read must print nothing (got '$out') for: $body"
  done
  out=$(pane_agent_session_ref_read \
    '{"result":{"agent":{"agent":"pi","agent_session":{"agent":"pi","kind":"path","value":"/abs/session.jsonl"}}}}' 1)
  [ -z "$out" ] \
    || fail "a failed agent read must print nothing, got '$out'"
  pass "herdr pane agent session: anything unresumable degrades to a nonzero read with no output"
}

test_registered_agent_with_a_non_shell_foreground_process_stays_alive() {
  local out
  # A registered agent running a foreground tool in its own process group is
  # not a shell-only pane, so the registration keeps its authority.
  out=$(FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 stale_registration_case live-tool working \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4250,"foreground_processes":[{"pid":4250,"name":"git","argv0":"git","argv":["git","status"],"cmdline":"git status"}]}}}')
  [ "$out" = "live alive refused" ] \
    || fail "a registered agent with a non-shell foreground process must stay live/alive, got '$out'"
  pass "herdr stale registration: only a shell-only pane demotes a registration"
}

# settle_registration_case: one pane classification over a scripted sequence
# of `pane process-info` samples, so the settle window's resampling is
# observable in the fake CLI's call log.
settle_registration_case() {  # <dir-suffix> <polls> <process-info-body>...
  local dir="$TMP_ROOT/settle-reg-$1" polls=$2 resp log fb n
  shift 2
  mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/2.out"
  n=3
  for body in "$@"; do
    printf '%s\n' "$body" > "$resp/$n.out"
    n=$((n + 1))
  done
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS="$polls" \
    bash -c '. "$0/bin/backends/herdr.sh"
      printf "%s %s" "$(fm_backend_herdr_pane_agent_state fmtest w1:p2)" "$(grep -c "process-info" "$1")"' "$ROOT" "$log"
}

prompt_helper_process_info() {  # <shell-pid>
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":99998,"name":"starship","argv":["/usr/local/bin/starship","prompt","--continuation"]},{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"],"cmdline":"-zsh"}]}}}' "$1" "$1" "$1"
}

test_transient_prompt_helper_settles_into_stale_agent() {
  local sleep_bin shell_pid out
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  shell_pid=$!
  # Sample 1: the shell is redrawing its prompt with starship beside it (the
  # real 0.7.5 shape); sample 2: the helper is gone and the shell is alone.
  out=$(settle_registration_case helper-settles 3 \
    "$(prompt_helper_process_info "$shell_pid")" "$(shell_only_process_info "$shell_pid")")
  kill "$shell_pid" 2>/dev/null || true
  [ "$out" = "stale-agent 2" ] \
    || fail "a transient prompt helper followed by a shell-only sample must settle into stale-agent after exactly two samples, got '$out'"
  pass "herdr stale registration: a transient prompt helper settles into stale-agent instead of reading live"
}

test_exhausted_settle_window_keeps_a_non_shell_foreground_live() {
  local sleep_bin shell_pid out
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  shell_pid=$!
  out=$(settle_registration_case helper-persists 2 \
    "$(prompt_helper_process_info "$shell_pid")" "$(prompt_helper_process_info "$shell_pid")" \
    "$(shell_only_process_info "$shell_pid")")
  kill "$shell_pid" 2>/dev/null || true
  [ "$out" = "live 2" ] \
    || fail "a foreground that never settles within the bound must stay live after exactly the bounded sample count, got '$out'"
  pass "herdr stale registration: an exhausted settle window still reads a non-shell foreground as live"
}

test_registered_agent_with_an_agent_descendant_outside_the_foreground_stays_alive() {
  local lab standin sleep_bin shell_pid out shell_verdict
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  lab="$TMP_ROOT/stale-reg-descendant-bin"; mkdir -p "$lab"
  # A symlink to a real long-running stand-in so the kernel records `pi` as the
  # executable identity (tests/lib.sh fm_agent_standin owns why not host sleep).
  standin=$(fm_agent_standin "$TMP_ROOT/standin") || {
    echo "skip: no long-running stand-in survives a rename, so the agent-named descendant case cannot run"
    return 0
  }
  ln -sf "$standin" "$lab/pi"
  # A real shell whose child is that agent-named process, while the canned
  # foreground view shows only the shell (a suspended or backgrounded agent).
  sh -c "'$lab/pi' 300; :" &
  shell_pid=$!
  sleep 0.3
  out=$(stale_registration_case descendant idle "$(shell_only_process_info "$shell_pid")")
  pkill -P "$shell_pid" 2>/dev/null || true
  kill "$shell_pid" 2>/dev/null || true
  [ "$out" = "live alive refused" ] \
    || fail "a registered agent with a live agent-named descendant must stay live/alive, got '$out'"
  # The divergence itself: the identical canned foreground view reads
  # stale-agent for a childless shell, so the descendant walk is what carried
  # this verdict.
  "$sleep_bin" 300 &
  shell_pid=$!
  shell_verdict=$(stale_registration_case descendant-childless idle "$(shell_only_process_info "$shell_pid")")
  kill "$shell_pid" 2>/dev/null || true
  [ "$shell_verdict" = "stale-agent dead refused" ] \
    || fail "the childless control must read stale-agent so the descendant case is not vacuous, got '$shell_verdict'"
  pass "herdr stale registration: an agent process outside the foreground group still counts as alive"
}

test_agent_descendant_under_a_spaced_install_path_stays_alive() {
  local lab standin shell_pid out
  standin=$(fm_agent_standin "$TMP_ROOT/standin") || {
    echo "skip: no long-running stand-in survives a rename, so the spaced-path descendant case cannot run"
    return 0
  }
  # The executable path the process table reports contains a space (the macOS
  # `/Library/Application Support/...` shape), so a field-split read of the
  # process table sees only a fragment of the name.
  lab="$TMP_ROOT/stale-reg-spaced-bin/Application Support/Some Dir"; mkdir -p "$lab"
  ln -sf "$standin" "$lab/pi"
  sh -c "'$lab/pi' 300; :" &
  shell_pid=$!
  sleep 0.3
  out=$(stale_registration_case spaced-descendant idle "$(shell_only_process_info "$shell_pid")")
  pkill -P "$shell_pid" 2>/dev/null || true
  kill "$shell_pid" 2>/dev/null || true
  [ "$out" = "live alive refused" ] \
    || fail "an agent-named descendant under a spaced install path must stay live/alive, got '$out'"
  pass "herdr stale registration: the descendant walk reads a spaced executable path whole"
}

test_registered_agent_with_an_unreadable_process_view_is_unknown() {
  local out
  out=$(stale_registration_case unreadable-exit idle 'Error: socket unavailable' 1)
  [ "$out" = "unknown unreadable refused" ] \
    || fail "a failed process-info read must not demote OR trust the registration: expected unknown/unreadable, got '$out'"
  out=$(stale_registration_case unreadable-empty idle -)
  [ "$out" = "unknown unreadable refused" ] \
    || fail "an empty process-info read must read unknown/unreadable, got '$out'"
  out=$(stale_registration_case unreadable-mismatch idle \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w9:p9","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"zsh","argv0":"zsh"}]}}}')
  [ "$out" = "unknown unreadable refused" ] \
    || fail "a process view for a different pane must read unknown/unreadable, got '$out'"
  out=$(stale_registration_case unreadable-no-foreground idle \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[]}}}')
  [ "$out" = "unknown unreadable refused" ] \
    || fail "an empty foreground list must read unknown/unreadable, got '$out'"
  pass "herdr stale registration: an unreadable process view refuses instead of guessing either way"
}

test_registered_agent_with_an_empty_foreground_over_a_real_shell_settles_via_descendant_walk() {
  local sleep_bin shell_pid out
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  # A real, childless shell process stands in for the pane's shell, and the
  # foreground list is empty - the exec-to-shell handoff shape the flake fix
  # targets. Unlike unreadable-no-foreground above (a synthetic pid absent
  # from `ps`), this shell_pid is real, so the descendant walk can run to
  # completion and prove the empty array settles to stale-agent, not
  # unreadable.
  "$sleep_bin" 300 &
  shell_pid=$!
  out=$(stale_registration_case empty-foreground idle \
    "$(printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[]}}}' "$shell_pid" "$shell_pid")")
  kill "$shell_pid" 2>/dev/null || true
  [ "$out" = "stale-agent dead refused" ] \
    || fail "an empty foreground list over a real childless shell must settle to stale-agent via the descendant walk, not unreadable, got '$out'"
  pass "herdr stale registration: an empty foreground list over a real shell is not unreadable, it settles via the descendant walk"
}

# --- foreground process parsing ----------------------------------------------
#
# The watcher classifies every busy pane on every poll, so reading each
# foreground process must not cost a jq process per field. These cases drive
# fm_backend_herdr_pane_process_state over one canned `pane process-info` body
# through a counting jq shim that runs the real jq.

process_state_read() {  # <dir-suffix> <process-info-body> -> "<verdict> <jq-calls>"
  local dir="$TMP_ROOT/process-state-$1" resp log fb real_jq
  mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  printf '%s\n' "$2" > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  real_jq=$(command -v jq)
  cat > "$fb/jq" <<SH
#!/usr/bin/env bash
printf 'jq\n' >> "$dir/jq-calls"
exec "$real_jq" "\$@"
SH
  chmod +x "$fb/jq"
  : > "$dir/jq-calls"
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"
      v=$(fm_backend_herdr_pane_process_state fmtest w1:p2)
      printf "%s %s" "$v" "$(wc -l < "$1" | tr -d " ")"' "$ROOT" "$dir/jq-calls"
}

process_info_body() {  # <shell-pid> <foreground-processes-json-array>
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":%s}}}' "$1" "$1" "$2"
}

test_process_state_reads_every_foreground_process_with_args_intact() {
  local gemini=/usr/local/lib/node_modules/@google/gemini-cli/dist/index.js out
  # The harness is the last of several processes, and only its full command
  # line names it, so the verdict needs every record and the args past the
  # first space.
  out=$(process_state_read many-cmdline "$(process_info_body 4242 \
    '[{"pid":4250,"name":"git","argv0":"git","argv":["git","status"],"cmdline":"git status"},
      {"pid":4251,"name":"starship","argv":["/usr/local/bin/starship","prompt"]},
      {"pid":4252,"name":"node","argv0":"node","cmdline":"node --max-old-space-size=10000 '"$gemini"'"}]')")
  [ "${out%% *}" = agent ] \
    || fail "a harness named only by the cmdline of the last foreground process must read agent, got '$out'"
  out=$(process_state_read many-argv "$(process_info_body 4242 \
    '[{"pid":4250,"name":"git","argv0":"git"},
      {"pid":4252,"name":"node","argv":["node","--max-old-space-size=10000","'"$gemini"'"]}]')")
  [ "${out%% *}" = agent ] \
    || fail "args joined from argv must reach the classifier whole, got '$out'"
  out=$(process_state_read tab-cmdline "$(process_info_body 4242 \
    '[{"pid":4252,"name":"node","argv0":"node","cmdline":"node\t'"$gemini"'\n"}]')")
  [ "${out%% *}" = agent ] \
    || fail "a tab inside the cmdline must reach the classifier as a tab, not an escape, got '$out'"
  out=$(process_state_read node-only "$(process_info_body 4242 \
    '[{"pid":4252,"name":"node","argv0":"node","cmdline":"node --max-old-space-size=10000"}]')")
  [ "${out%% *}" = other ] \
    || fail "a node process with no harness argument must stay other, got '$out'"
  pass "herdr process state: every foreground process is read, with spaced and tabbed args intact"
}

test_process_state_tolerates_missing_and_malformed_process_fields() {
  local out
  out=$(process_state_read missing-fields "$(process_info_body 4242 \
    '[null, "str", 5, {}, {"pid":"7","name":7,"argv":"notarray","argv0":["a"]}, {"name":"git"}]')")
  [ "${out%% *}" = other ] \
    || fail "missing or malformed fields with no harness must read other, got '$out'"
  out=$(process_state_read argv-only "$(process_info_body 4242 '[{}, {"argv":["/opt/tools/pi","--continue"]}]')")
  [ "${out%% *}" = agent ] \
    || fail "argv[0] must name the harness when name and argv0 are missing, got '$out'"
  out=$(process_state_read argv0-only "$(process_info_body 4242 '[{"pid":4243,"name":"node","argv0":"pi"}]')")
  [ "${out%% *}" = agent ] \
    || fail "argv0 must name the harness when argv and cmdline are missing, got '$out'"
  out=$(process_state_read no-shell-pid \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_processes":[{"name":"node","argv0":"pi"}]}}}')
  [ "${out%% *}" = unreadable ] \
    || fail "a process view with no shell pid must stay unreadable even with a harness in it, got '$out'"
  out=$(process_state_read not-an-array \
    '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_processes":{"name":"pi"}}}}')
  [ "${out%% *}" = unreadable ] \
    || fail "a foreground list that is not an array must read unreadable, got '$out'"
  pass "herdr process state: missing fields read empty and malformed views stay unreadable"
}

test_process_state_shell_verdict_survives_several_shell_processes() {
  local sleep_bin shell_pid out
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  shell_pid=$!
  out=$(process_state_read two-shells "$(process_info_body "$shell_pid" \
    '[{"pid":'"$shell_pid"',"name":"zsh","argv0":"-zsh","cmdline":"-zsh"},{"pid":1,"name":"bash","argv":["bash","-l"]}]')")
  kill "$shell_pid" 2>/dev/null || true
  [ "${out%% *}" = shell ] \
    || fail "a foreground of only shells over a real childless shell must read shell, got '$out'"
  pass "herdr process state: a foreground of several shells still proves a shell-only pane"
}

test_process_state_jq_calls_do_not_grow_with_foreground_processes() {
  local one many procs i
  procs='{"pid":4250,"name":"git","argv0":"git","argv":["git","status"]}'
  for i in 1 2 3 4 5 6 7; do
    procs="$procs,{\"pid\":$((4250 + i)),\"name\":\"rg\",\"argv0\":\"rg\",\"argv\":[\"rg\",\"needle\"]}"
  done
  one=$(process_state_read jq-one "$(process_info_body 4242 '[{"pid":4250,"name":"git","argv0":"git","argv":["git","status"]}]')")
  many=$(process_state_read jq-many "$(process_info_body 4242 "[$procs]")")
  [ "${one%% *}" = other ] && [ "${many%% *}" = other ] \
    || fail "non-harness foregrounds must read other, got '$one' and '$many'"
  [ "${one#* }" = "${many#* }" ] \
    || fail "jq calls must not grow with the foreground process count: 1 process took ${one#* }, 8 took ${many#* }"
  pass "herdr process state: one sample costs the same jq calls for 1 or 8 foreground processes"
}

test_projection_reclaim_rollback_refuses_a_stale_registration() {
  local out
  out=$(bash -c '. "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_agent_state() { printf stale-agent; }
    fm_backend_herdr_projection_close_pane_focus_preserving() { printf "CLOSED %s\n" "$2" >&2; exit 99; }
    fm_backend_herdr_projection_reclaim_rollback fmtest w1:p9; printf "rc=%s" "$?"' "$ROOT" 2>&1)
  [ "$out" = "rc=1" ] \
    || fail "reclaim rollback must refuse (never close) a pane with a stale registration, got '$out'"
  pass "herdr stale registration: presentation reclaim never closes a stale-registration pane"
}

test_projection_cleanup_exact_succeeds_only_when_the_task_pane_closed() {
  local closed refused absent restore_failed_after_close restore_failed_after_failed_close
  closed=$(bash -c '. "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_close_pane_focus_preserving() { printf "CLOSED %s;" "$2"; }
    fm_backend_herdr_projection_cleanup_exact fmtest w1:p2 w1:p1; printf "rc=%s" "$?"' "$ROOT" 2>&1)
  refused=$(bash -c '. "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_close_pane_focus_preserving() { [ "$2" != w1:p2 ] || return 1; printf "CLOSED %s;" "$2"; }
    fm_backend_herdr_cli() { [ "$2 $3 $4" = "pane get w1:p2" ] && printf "{\"result\":{\"pane\":{\"pane_id\":\"w1:p2\"}}}"; }
    fm_backend_herdr_projection_cleanup_exact fmtest w1:p2 w1:p1; printf "rc=%s" "$?"' "$ROOT" 2>&1)
  absent=$(bash -c '. "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_close_pane_focus_preserving() { printf "CLOSED %s;" "$2"; }
    fm_backend_herdr_projection_cleanup_exact fmtest "" w1:p1; printf "rc=%s" "$?"' "$ROOT" 2>&1)
  # The close call fails with 2 when focus restoration fails, whether or not
  # the pane closed; only an exact presence check can tell the two apart.
  restore_failed_after_close=$(bash -c '. "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_close_pane_focus_preserving() { [ "$2" != w1:p2 ] || return 2; printf "CLOSED %s;" "$2"; }
    fm_backend_herdr_cli() { [ "$2 $3 $4" = "pane get w1:p2" ] && printf "{\"error\":{\"code\":\"pane_not_found\"}}"; }
    fm_backend_herdr_projection_cleanup_exact fmtest w1:p2 w1:p1; printf "rc=%s" "$?"' "$ROOT" 2>&1)
  restore_failed_after_failed_close=$(bash -c '. "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_close_pane_focus_preserving() { [ "$2" != w1:p2 ] || return 2; printf "CLOSED %s;" "$2"; }
    fm_backend_herdr_cli() { [ "$2 $3 $4" = "pane get w1:p2" ] && printf "{\"result\":{\"pane\":{\"pane_id\":\"w1:p2\"}}}"; }
    fm_backend_herdr_projection_cleanup_exact fmtest w1:p2 w1:p1; printf "rc=%s" "$?"' "$ROOT" 2>&1)
  [ "$closed" = "CLOSED w1:p2;CLOSED w1:p1;rc=0" ] \
    || fail "a closed task pane must report success after closing both panes, got '$closed'"
  [ "$refused" = "CLOSED w1:p1;rc=1" ] \
    || fail "a task pane left open must report failure and still close the seeded pane, got '$refused'"
  [ "$absent" = "CLOSED w1:p1;rc=1" ] \
    || fail "no task pane must never report a closed endpoint, got '$absent'"
  [ "$restore_failed_after_close" = "CLOSED w1:p1;rc=0" ] \
    || fail "a task pane confirmed gone must report success even when focus restoration failed, got '$restore_failed_after_close'"
  [ "$restore_failed_after_failed_close" = "CLOSED w1:p1;rc=1" ] \
    || fail "a failed close with failed focus restoration must report failure while the pane is present, got '$restore_failed_after_failed_close'"
  pass "herdr projection abort cleanup reports success only when the task pane closed"
}

test_busy_state_never_reports_a_shell_only_pane_busy() {
  local sleep_bin shell_pid dir resp log fb out
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  shell_pid=$!
  dir="$TMP_ROOT/busy-stale"; mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  # 1: agent get -> a lingering working record; 2: process-info -> shell only
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/1.out"
  shell_only_process_info "$shell_pid" > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state fmtest:w1:p2' "$ROOT")
  kill "$shell_pid" 2>/dev/null || true
  [ "$out" = unknown ] \
    || fail "a working record over a shell-only pane must not read busy, got '$out'"
  assert_contains "$(cat "$log")" $'pane\x1fprocess-info' "busy_state did not verify the working record at process level"

  # The control: the same working record with a live Pi foreground reads busy.
  dir="$TMP_ROOT/busy-live"; mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/1.out"
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4243,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi","argv":["pi"],"cmdline":"pi"}]}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state fmtest:w1:p2' "$ROOT")
  [ "$out" = busy ] || fail "a working record with a live Pi foreground must read busy, got '$out'"

  # An idle record needs no process read: idle is never trusted as busy anyway.
  dir="$TMP_ROOT/busy-idle"; mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state fmtest:w1:p2' "$ROOT")
  [ "$out" = idle ] || fail "an idle record should read idle without a process read, got '$out'"
  assert_not_contains "$(cat "$log")" $'pane\x1fprocess-info' "busy_state ran a process read for an idle record"
  pass "herdr stale registration: busy_state proves a working record at process level before reporting busy"
}

test_agent_state_bypasses_a_stale_client_shadowing_a_compatible_one() {
  local dir out err
  dir="$TMP_ROOT/client-pair-bypass"; make_herdr_client_pair "$dir"
  out=$(run_with_clients "$dir" "$dir/stale:$dir/current" 'fm_backend_herdr_agent_state fm-remote:wCY:p2' 2>"$dir/stderr") \
    || fail "agent-state read with a shadowing stale client should not fail"
  err=$(cat "$dir/stderr")
  [ "$out" = alive ] || fail "a live remote pane behind a stale shadowing client should read alive, got: $out (stderr: $err)"
  assert_contains "$(cat "$dir/current.log")" "pane get wCY:p2" "the compatible client should have served the pane read"
  assert_contains "$(cat "$dir/current.log")" "agent get wCY:p2" "the compatible client should have served the agent read"
  [ -z "$err" ] || fail "a successful bypass must print nothing on stderr (callers merge stderr into parsed JSON), got: $err"
  pass "herdr client selection: a live pane behind a stale shadowing client reads alive"
}

# shellcheck disable=SC2016
test_cli_caches_the_selected_client_within_a_process() {
  local dir out
  dir="$TMP_ROOT/client-pair-cache"; make_herdr_client_pair "$dir"
  out=$(run_with_clients "$dir" "$dir/stale:$dir/current" \
    'fm_backend_herdr_cli fm-remote pane get wCY:p2 >/dev/null 2>&1
     fm_backend_herdr_cli fm-remote agent get wCY:p2 >/dev/null 2>&1
     printf "%s" "${FM_BACKEND_HERDR_BIN:-unset}"')
  [ "$out" = "$dir/current/herdr" ] \
    || fail "the compatible client should be selected and exported, got: $out"
  [ "$(grep -c 'pane get\|agent get' "$dir/stale.log")" -eq 1 ] \
    || fail "after selection the stale client must not be retried in the same process, got: $(cat "$dir/stale.log")"
  assert_contains "$(cat "$dir/current.log")" "agent get wCY:p2" "the second call should go straight to the selected client"
  pass "herdr client selection: one selected client is reused per process"
}

# shellcheck disable=SC2016
test_cli_scopes_the_selected_client_to_its_session() {
  local dir out
  dir="$TMP_ROOT/client-pair-cross-session"
  mkdir -p "$dir/stale" "$dir/current" "$dir/tools"
  ln -sf "$(command -v jq)" "$dir/tools/jq"
  cat > "$dir/stale/herdr" <<'SH'
#!/usr/bin/env bash
session=${!#}
printf '%s\n' "$*" >> "${FM_HERDR_PAIR_DIR:?}/stale.log"
if [ "${1:-} ${2:-}" = "status --json" ]; then
  if [ "$session" = fresh ]; then
    printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":false}}\n'
  elif [ -e "$FM_HERDR_PAIR_DIR/switched" ]; then
    printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true,"protocol":20,"compatible":true}}\n'
  else
    printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true,"protocol":22,"compatible":false}}\n'
  fi
elif [ "$session" = fresh ] && [ "${1:-}" = server ]; then
  printf 'path-default-server\n'
elif [ "$session" = modern ] && [ -e "$FM_HERDR_PAIR_DIR/switched" ]; then
  printf 'legacy\n'
else
  printf '{"error":{"code":"protocol_mismatch"}}\n' >&2
  exit 1
fi
SH
  cat > "$dir/current/herdr" <<'SH'
#!/usr/bin/env bash
session=${!#}
printf '%s\n' "$*" >> "${FM_HERDR_PAIR_DIR:?}/current.log"
if [ "${1:-} ${2:-}" = "status --json" ]; then
  if [ "$session" = fresh ]; then
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":false}}\n'
  elif [ -e "$FM_HERDR_PAIR_DIR/switched" ]; then
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true,"protocol":20,"compatible":false}}\n'
  else
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true,"protocol":22,"compatible":true}}\n'
  fi
elif [ "$session" = fresh ] && [ "${1:-}" = server ]; then
  printf 'selected-server\n'
elif [ "$session" = modern ] && [ ! -e "$FM_HERDR_PAIR_DIR/switched" ]; then
  printf 'modern\n'
else
  printf '{"error":{"code":"protocol_mismatch"}}\n' >&2
  exit 1
fi
SH
  chmod +x "$dir/stale/herdr" "$dir/current/herdr"
  out=$(run_with_clients "$dir" "$dir/stale:$dir/current" \
    'fm_backend_herdr_cli modern pane get w1:p1 > "$FM_HERDR_PAIR_DIR/modern.out" || exit 1
     fm_backend_herdr_cli fresh status --json > "$FM_HERDR_PAIR_DIR/fresh-status.out" || exit 1
     fm_backend_herdr_cli fresh server > "$FM_HERDR_PAIR_DIR/server.out" || exit 1
     touch "$FM_HERDR_PAIR_DIR/switched"
     fm_backend_herdr_cli modern pane get w1:p1 > "$FM_HERDR_PAIR_DIR/legacy.out" || exit 1
     printf "%s|%s|%s|%s|%s" "$(cat "$FM_HERDR_PAIR_DIR/modern.out")" "$(jq -r .server.running "$FM_HERDR_PAIR_DIR/fresh-status.out")" "$(cat "$FM_HERDR_PAIR_DIR/server.out")" "$(cat "$FM_HERDR_PAIR_DIR/legacy.out")" "${FM_BACKEND_HERDR_BIN:-PATH-default}"')
  [ "$out" = 'modern|false|path-default-server|legacy|PATH-default' ] \
    || fail "a selected client should stay scoped to its session while forced reselection still returns to the PATH default, got: $out"
  assert_contains "$(cat "$dir/stale.log")" 'server --session fresh' "a stopped second session should start with the PATH-default client"
  assert_not_contains "$(cat "$dir/current.log")" 'server --session fresh' "another session's selected client must not start the stopped session"
  [ "$(grep -c 'pane get w1:p1' "$dir/current.log")" -eq 2 ] \
    || fail "the selected client should be retried after its own server compatibility changes: $(cat "$dir/current.log")"
  assert_contains "$(cat "$dir/stale.log")" 'pane get w1:p1' "the changed session call should retry on the newly compatible PATH-default client"
  pass "herdr client selection: selected clients remain scoped to their session"
}

# shellcheck disable=SC2016
test_cli_unrelated_failure_never_triggers_reselection() {
  local dir out rc
  dir="$TMP_ROOT/client-pair-unrelated"; make_herdr_client_pair "$dir"
  # current first: its pane_not_found refusal is an ordinary business result,
  # so the stale client behind it must never be consulted or selected.
  out=$(run_with_clients "$dir" "$dir/current:$dir/stale" \
    'fm_backend_herdr_cli fm-remote pane get wZZ:p9 2>&1; rc=$?; printf "\nrc=%s bin=%s\n" "$rc" "${FM_BACKEND_HERDR_BIN:-unset}"'); rc=$?
  assert_contains "$out" 'pane_not_found' "the ordinary refusal must be replayed to the caller verbatim"
  assert_contains "$out" 'rc=1 bin=unset' "an unrelated failure must keep the exit status and select nothing"
  [ ! -e "$dir/stale.log" ] || fail "the shadowed client must not be consulted on an unrelated failure: $(cat "$dir/stale.log")"
  pass "herdr client selection: only protocol_mismatch triggers reselection; other failures pass through untouched"
}

# shellcheck disable=SC2016
test_cli_single_client_pays_no_selection_read() {
  local dir out
  dir="$TMP_ROOT/client-single"; make_herdr_client_pair "$dir"
  out=$(run_with_clients "$dir" "$dir/current" 'fm_backend_herdr_cli fm-remote pane get wCY:p2 >/dev/null; printf "%s" "${FM_BACKEND_HERDR_BIN:-unset}"')
  [ "$out" = unset ] || fail "a single healthy client must stay the PATH default, got: $out"
  [ "$(grep -c status "$dir/current.log")" -eq 0 ] \
    || fail "a healthy call must make no status read: $(cat "$dir/current.log")"
  pass "herdr client selection: the happy path makes no extra call"
}

test_client_status_reads_both_status_shapes() {
  local dir out
  dir="$TMP_ROOT/client-status-shapes"; mkdir -p "$dir/bin" "$dir/tools"
  ln -sf "$(command -v jq)" "$dir/tools/jq"
  # An older client that reports protocols but no .server.compatible field
  # (the pre-0.8 status shape) must be judged by protocol equality.
  cat > "$dir/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "${FM_HERDR_STATUS_SHAPE:?}" in
  legacy-equal) printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true,"protocol":16}}\n' ;;
  legacy-older) printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true,"protocol":22}}\n' ;;
  no-protocol)  printf '{"client":{"version":"0.7.1"},"server":{"running":true}}\n' ;;
  stopped)      printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":false}}\n' ;;
esac
SH
  chmod +x "$dir/bin/herdr"
  for shape in legacy-equal legacy-older no-protocol stopped; do
    out=$(FM_HERDR_STATUS_SHAPE=$shape PATH="$dir/tools:/usr/bin:/bin" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_client_status "$1" fm-remote' "$ROOT" "$dir/bin/herdr")
    case "$shape" in
      legacy-equal) [ "$out" = 'true|true' ] || fail "legacy equal protocols should read compatible, got: $out" ;;
      legacy-older) [ "$out" = 'true|false' ] || fail "legacy older client should read incompatible, got: $out" ;;
      no-protocol)  [ "$out" = 'true|' ] || fail "a client reporting no protocol must read unknown, never false, got: $out" ;;
      stopped)      [ "$out" = 'false|' ] || fail "a stopped server must read not running, got: $out" ;;
    esac
  done
  pass "herdr client status: .server.compatible, legacy protocol equality, unknown, and stopped shapes all normalize"
}

# --- launcher_identity: the exact workspace a worker must be placed in -------
#
# Herdr injects HERDR_ENV/HERDR_PANE_ID/HERDR_SESSION/HERDR_SOCKET_PATH into
# every process it manages a pane for, so a firstmate or secondmate agent's own
# tool calls carry the identity of the workspace the captain is watching it in.
# Placement resolves from that identity because workspace labels are mutable and
# non-unique, and the globally focused workspace is unrelated to the launcher.
# The refusal cases matter as much as the resolution: a broken binding must stop
# the spawn, never quietly degrade back to picking a workspace by label.

test_launcher_identity_absent_without_a_herdr_pane() {
  local dir log resp fb status
  dir="$TMP_ROOT/launcher-none"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  ( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest' "$ROOT" )
  status=$?
  expect_code 2 "$status" "a process with no herdr pane must report 'no launcher to inherit' (2), not a refusal"
  [ ! -s "$log" ] || fail "resolving an absent launcher identity must not call herdr at all"$'\n'"$(cat "$log")"
  pass "fm_backend_herdr_launcher_identity: a firstmate not running inside herdr has no launcher workspace to inherit"
}

test_launcher_identity_absent_when_herdr_env_alone_is_set() {
  local dir log resp fb status
  dir="$TMP_ROOT/launcher-env-only"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  ( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_ENV=1 \
    \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest' "$ROOT" )
  status=$?
  expect_code 2 "$status" "HERDR_ENV=1 alone is a backend-selection marker, not a parent binding"
  pass "fm_backend_herdr_launcher_identity: HERDR_ENV=1 without a pane id selects the backend but binds no parent"
}

test_launcher_identity_resolves_the_exact_pane_tab_and_workspace() {
  local dir log resp fb out
  dir="$TMP_ROOT/launcher-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-herdr-unit/fmtest.sock"}]}\n' > "$resp/1.out"
  printf '{"result":{"pane":{"pane_id":"w7:p3","tab_id":"w7:t3","workspace_id":"w7"}}}\n' > "$resp/2.out"
  printf '{"result":{"tab":{"tab_id":"w7:t3","workspace_id":"w7"}}}\n' > "$resp/3.out"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w7","label":"firstmate"}]}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fmtest HERDR_SOCKET_PATH=/tmp/fm-herdr-unit/fmtest.sock \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest || exit 1
      printf "%s|%s|%s" "$FM_BACKEND_HERDR_LAUNCHER_PANE_ID" "$FM_BACKEND_HERDR_LAUNCHER_TAB_ID" "$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID"' "$ROOT" )
  [ "$out" = 'w7:p3|w7:t3|w7' ] \
    || fail "launcher_identity should resolve the launcher's own pane, tab, and workspace, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''get'$'\x1f''w7:p3' "launcher_identity did not read its own pane"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''get'$'\x1f''w7:t3' "launcher_identity did not cross-check the owning tab"
  pass "fm_backend_herdr_launcher_identity: resolves the launcher's exact workspace even when a same-labeled workspace sorts first"
}

test_launcher_identity_refuses_a_pane_from_another_session_name() {
  local dir log resp fb out status
  dir="$TMP_ROOT/launcher-xsession"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=someother \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest' "$ROOT" 2>&1 )
  status=$?
  expect_code 1 "$status" "a launcher pane naming another herdr session must refuse"
  assert_contains "$out" "cross-session parent identity" "the cross-session refusal did not explain itself"
  [ ! -s "$log" ] || fail "a cross-session launcher identity must be refused before any herdr call"
  pass "fm_backend_herdr_launcher_identity: refuses a launcher pane that names a different herdr session"
}

test_launcher_identity_refuses_a_missing_server_socket() {
  local dir log resp fb out status
  dir="$TMP_ROOT/launcher-no-socket"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest' "$ROOT" 2>&1 )
  status=$?
  expect_code 1 "$status" "a launcher pane without an injected server socket must refuse"
  assert_contains "$out" "no injected socket identity" "the missing-socket refusal did not explain itself"
  [ ! -s "$log" ] || fail "a missing-socket launcher identity must be refused before any herdr call"
  pass "fm_backend_herdr_launcher_identity: refuses a claimed pane without exact server identity"
}

test_launcher_identity_refuses_a_pane_from_another_server_socket() {
  local dir log resp fb out status
  dir="$TMP_ROOT/launcher-xsocket"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: session list --json, resolving THIS session's own socket.
  printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-herdr-unit/fmtest.sock"}]}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fmtest HERDR_SOCKET_PATH=/tmp/fm-herdr-unit/other.sock \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest' "$ROOT" 2>&1 )
  status=$?
  expect_code 1 "$status" "a launcher pane on a different herdr server socket must refuse"
  assert_contains "$out" "cross-session parent identity" "the cross-socket refusal did not explain itself"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''get' "a cross-server launcher identity must be refused before its pane is trusted"
  pass "fm_backend_herdr_launcher_identity: refuses a launcher pane whose injected socket belongs to another herdr server"
}

test_launcher_identity_refuses_an_unreadable_pane() {
  local dir log resp fb out status
  dir="$TMP_ROOT/launcher-stale"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-herdr-unit/fmtest.sock"}]}\n' > "$resp/1.out"
  # A destroyed pane: herdr 0.9.3 answers `pane get` with pane_not_found, rc=1.
  printf '1\n' > "$resp/2.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fmtest HERDR_SOCKET_PATH=/tmp/fm-herdr-unit/fmtest.sock \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest' "$ROOT" 2>&1 )
  status=$?
  expect_code 1 "$status" "a launcher pane that no longer reads must refuse, not fall back to a label search"
  assert_contains "$out" "w7:p3" "the unreadable-pane refusal did not name the pane it could not resolve"
  assert_contains "$out" "could not be read" "the unreadable-pane refusal did not say the pane could not be read"
  pass "fm_backend_herdr_launcher_identity: refuses as unreadable when the launcher's own pane was destroyed"
}

test_launcher_identity_refuses_a_stale_pane_id() {
  local dir log resp fb out status shape
  for shape in other-pane empty-tab; do
    dir="$TMP_ROOT/launcher-stale-$shape"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-herdr-unit/fmtest.sock"}]}\n' > "$resp/1.out"
    case "$shape" in
      # An id herdr resolves to a different pane (a legacy id form such as
      # `1-1` answers as `w1:p1`), so the exact-id filter keeps nothing.
      other-pane) printf '{"result":{"pane":{"pane_id":"w7:p9","tab_id":"w7:t9","workspace_id":"w7"}}}\n' > "$resp/2.out" ;;
      # A pane record that names no tab at all.
      empty-tab) printf '{"result":{"pane":{"pane_id":"w7:p3","tab_id":"","workspace_id":"w7"}}}\n' > "$resp/2.out" ;;
    esac
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fmtest HERDR_SOCKET_PATH=/tmp/fm-herdr-unit/fmtest.sock \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest' "$ROOT" 2>&1 )
    status=$?
    expect_code 1 "$status" "a stale launcher pane id must refuse, not fall back to a label search"
    assert_contains "$out" "w7:p3" "the stale-pane refusal did not name the stale pane id"
    assert_contains "$out" "no longer exists" "the stale-pane refusal did not say the pane id no longer names a pane"
    assert_contains "$out" "HERDR_PANE_ID" "the stale-pane refusal did not name HERDR_PANE_ID as a value to refresh"
    assert_contains "$out" "HERDR_TAB_ID" "the stale-pane refusal did not name HERDR_TAB_ID as a value to refresh"
    assert_contains "$out" "HERDR_WORKSPACE_ID" "the stale-pane refusal did not name HERDR_WORKSPACE_ID as a value to refresh"
    assert_not_contains "$out" "ambiguous tab or workspace" "the stale-pane refusal still blamed an ambiguity that does not exist"
    assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "a stale launcher pane must not mint or pick a workspace"
  done
  pass "fm_backend_herdr_launcher_identity: names a launcher pane id that resolves elsewhere or names no tab as stale and names the values to refresh"
}

test_launcher_identity_refuses_a_pane_and_tab_that_disagree() {
  local dir log resp fb out status
  dir="$TMP_ROOT/launcher-contradictory"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-herdr-unit/fmtest.sock"}]}\n' > "$resp/1.out"
  printf '{"result":{"pane":{"pane_id":"w7:p3","tab_id":"w7:t3","workspace_id":"w7"}}}\n' > "$resp/2.out"
  # The tab claims a DIFFERENT owning workspace than the pane just did.
  printf '{"result":{"tab":{"tab_id":"w7:t3","workspace_id":"w9"}}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fmtest HERDR_SOCKET_PATH=/tmp/fm-herdr-unit/fmtest.sock \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest' "$ROOT" 2>&1 )
  status=$?
  expect_code 1 "$status" "a pane and tab that disagree about their workspace must refuse"
  assert_contains "$out" "contradictory parent identity" "the contradictory-identity refusal did not explain itself"
  pass "fm_backend_herdr_launcher_identity: refuses when the launcher's pane and tab disagree about their workspace"
}

test_launcher_identity_refuses_a_workspace_missing_from_the_session() {
  local dir log resp fb out status
  dir="$TMP_ROOT/launcher-gone"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-herdr-unit/fmtest.sock"}]}\n' > "$resp/1.out"
  printf '{"result":{"pane":{"pane_id":"w7:p3","tab_id":"w7:t3","workspace_id":"w7"}}}\n' > "$resp/2.out"
  printf '{"result":{"tab":{"tab_id":"w7:t3","workspace_id":"w7"}}}\n' > "$resp/3.out"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fmtest HERDR_SOCKET_PATH=/tmp/fm-herdr-unit/fmtest.sock \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_launcher_identity fmtest' "$ROOT" 2>&1 )
  status=$?
  expect_code 1 "$status" "a launcher workspace absent from the session listing must refuse"
  assert_contains "$out" "stale parent identity" "the stale-workspace refusal did not explain itself"
  pass "fm_backend_herdr_launcher_identity: refuses when the launcher's workspace is gone from its own session"
}

# --- workspace_ensure placement ---------------------------------------------

test_workspace_ensure_prefers_the_launcher_over_the_first_label_match() {
  local dir log resp fb out
  dir="$TMP_ROOT/ensure-launcher"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-herdr-unit/fmtest.sock"}]}\n' > "$resp/1.out"
  printf '{"result":{"pane":{"pane_id":"w7:p3","tab_id":"w7:t3","workspace_id":"w7"}}}\n' > "$resp/2.out"
  printf '{"result":{"tab":{"tab_id":"w7:t3","workspace_id":"w7"}}}\n' > "$resp/3.out"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w7","label":"firstmate"}]}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fmtest HERDR_SOCKET_PATH=/tmp/fm-herdr-unit/fmtest.sock \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_ensure fmtest /tmp' "$ROOT" )
  [ "$out" = w7 ] || fail "workspace_ensure should place the worker in the launcher's own workspace w7, got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "the launcher's existing workspace must be reused, not duplicated"
  pass "fm_backend_herdr_workspace_ensure: places a worker in the launcher's exact workspace, not the first same-labeled one"
}

test_workspace_ensure_refuses_an_ambiguous_label_with_no_launcher() {
  local dir log resp fb out status
  dir="$TMP_ROOT/ensure-ambiguous"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w7","label":"firstmate"}]}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_ensure fmtest /tmp' "$ROOT" 2>&1 )
  status=$?
  expect_code 3 "$status" "two same-labeled home workspaces with no launcher identity must refuse"
  assert_contains "$out" "labeled 'firstmate'" "the ambiguity refusal did not name the duplicated label"
  assert_contains "$out" "w1 w7" "the ambiguity refusal did not name the candidate workspaces"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "an ambiguous placement must not mint a third same-labeled workspace"
  pass "fm_backend_herdr_workspace_ensure: refuses to guess between two same-labeled home workspaces"
}

test_workspace_ensure_other_home_ignores_the_launcher_identity() {
  local dir log resp fb out
  dir="$TMP_ROOT/ensure-other-home"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Only a workspace list: the launcher's own pane is never consulted, because a
  # --secondmate launch stands up a different home's workspace by design.
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    HERDR_ENV=1 HERDR_PANE_ID=w7:p3 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_ensure fmtest /tmp other-home' "$ROOT" )
  [ "$out" = w1 ] || fail "an other-home container should resolve by this home's own label, got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''get' "an other-home container must not inherit the launcher's workspace"
  pass "fm_backend_herdr_workspace_ensure: a --secondmate container resolves that home's own workspace, not the launcher's"
}

test_container_ensure_refuses_an_ambiguous_home_label() {
  local dir log resp fb out status
  dir="$TMP_ROOT/container-ambiguous"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w7","label":"firstmate"}]}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "container_ensure must fail when the home workspace is ambiguous"
  assert_contains "$out" "labeled 'firstmate'" "container_ensure buried the specific ambiguity it refused"
  assert_not_contains "$out" "failed to ensure herdr workspace" "container_ensure added a generic message over the specific one"
  pass "fm_backend_herdr_container_ensure: surfaces the exact ambiguous-placement refusal instead of a generic failure"
}

# --- container_ensure / create_task ------------------------------------------

test_container_ensure_starts_server_and_workspace() {
  local dir log resp fb out
  dir="$TMP_ROOT/container"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: version_check status --json (server not running yet, irrelevant to client check)
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  # 2: server_ensure's status --json check -> not running
  printf '{"server":{"running":false}}\n' > "$resp/2.out"
  # 3: `herdr server` backgrounded launch - no meaningful output
  # 4: server_ensure poll -> now running
  printf '{"server":{"running":true}}\n' > "$resp/4.out"
  # 5: workspace list -> empty (no "firstmate" workspace yet)
  printf '{"result":{"workspaces":[]}}\n' > "$resp/5.out"
  # 6: workspace create -> w1, seeding default tab w1:t9 (real herdr returns
  # the seeded tab/pane ids in the SAME response - verified empirically).
  printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"},"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w1\tw1:t9' ] || fail "container_ensure should echo '<session>:<workspace_id>\\t<seeded_default_tab_id>', got '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=fmtest"$'\x1f''server' "container_ensure did not start the herdr server"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--cwd'$'\x1f''/tmp'$'\x1f''--label'$'\x1f''firstmate' \
    "container_ensure did not create the firstmate workspace with the given cwd"
  pass "fm_backend_herdr_container_ensure: version-gates, starts the server, ensures the firstmate workspace, echoes session:workspace_id + the seeded default tab id"
}

test_server_ensure_scrubs_home_and_harness_identity() {
  local dir log marker fb output name
  dir="$TMP_ROOT/server-env"; mkdir -p "$dir"; log="$dir/env"; marker="$dir/running"
  fb=$(make_herdr_server_env_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_SERVER_ENV_LOG="$log" FM_HERDR_SERVER_MARKER="$marker" FM_HERDR_SENTINEL=kept \
    FM_HOME=/tmp/wrong-home FM_ROOT_OVERRIDE=/tmp/wrong-root FM_STATE_OVERRIDE=/tmp/wrong-state \
    FM_DATA_OVERRIDE=/tmp/wrong-data FM_PROJECTS_OVERRIDE=/tmp/wrong-projects FM_CONFIG_OVERRIDE=/tmp/wrong-config \
    CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent CLAUDECODE=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed GROK_AGENT=1 FM_SUPERVISION_MODEL=autoarm \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT"
  expect_code 0 $? "server_ensure should start under a polluted launcher environment"
  output=$(cat "$log")
  for name in FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE \
    CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_SUPERVISION_MODEL; do
    assert_contains "$output" "$name=<unset>" "server_ensure leaked $name into the long-lived Herdr server"
  done
  assert_contains "$output" "FM_HERDR_SENTINEL=kept" "server_ensure removed an unrelated environment variable"
  assert_contains "$output" "HERDR_SESSION=fmtest" "server_ensure lost explicit Herdr session routing"
  assert_contains "$output" "args=server --session fmtest" "server_ensure lost the trailing Herdr session flag"
  pass "fm_backend_herdr_server_ensure: scrubs home and harness identity without disturbing unrelated environment or session routing"
}

# run_owned_server_ensure: run server_ensure for fmtest against
# make_herdr_owned_server_fakebin rooted at <dir>, printing its output; any
# extra NAME=value arguments are added to its environment.
run_owned_server_ensure() {  # <dir> [NAME=value...]
  local dir=$1 fb
  shift
  fb=$(make_herdr_owned_server_fakebin "$dir")
  (
    # shellcheck disable=SC2163 # each argument is a NAME=value assignment.
    [ "$#" -eq 0 ] || export "$@"
    PATH="$fb:$PATH" FM_HERDR_SESSION_DIR="$dir/session" FM_HERDR_SERVER_MARKER="$dir/running" \
      FM_HERDR_STATUS_COUNT="$dir/status-count" FM_HERDR_SLEEP_COUNT="$dir/sleep-count" FM_HERDR_START_LOG="$dir/starts" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" 2>&1
  )
}

test_server_ensure_starts_a_firstmate_owned_server() {
  local dir out status
  dir="$TMP_ROOT/server-owned-default"; mkdir -p "$dir/session"
  out=$(run_owned_server_ensure "$dir")
  status=$?
  expect_code 0 $status "server_ensure should start a stopped server the session directory does not mark as externally owned"
  [ "$(cat "$dir/starts" 2>/dev/null)" = started ] || fail "server_ensure did not start exactly one Firstmate-owned server: $out"
  pass "fm_backend_herdr_server_ensure: still starts a stopped server when no ownership marker is present"
}

test_server_ensure_never_starts_an_externally_managed_server() {
  local dir out status
  dir="$TMP_ROOT/server-owned-external"; mkdir -p "$dir/session"
  printf 'systemd user unit herdr-fmtest.service\n' > "$dir/session/firstmate-server-owner"
  out=$(run_owned_server_ensure "$dir")
  status=$?
  [ "$status" -ne 0 ] || fail "server_ensure must fail when an externally managed server stays down"
  [ ! -e "$dir/starts" ] || fail "server_ensure started a server that an external owner manages"
  [ "$(cat "$dir/sleep-count")" = 60 ] || fail "server_ensure should give up after its 60 bounded waits, got $(cat "$dir/sleep-count")"
  [ "$(cat "$dir/status-count")" = 61 ] || fail "server_ensure should read status once plus once per bounded wait, got $(cat "$dir/status-count")"
  assert_contains "$out" "managed by systemd user unit herdr-fmtest.service" "the error should name the owner from the marker"
  assert_contains "$out" "will not start it" "the error should say Firstmate did not start the server"
  pass "fm_backend_herdr_server_ensure: an externally managed server that stays down gets a bounded wait, no start, and an error naming its owner"
}

test_server_ensure_uses_a_running_externally_managed_server() {
  local dir out status
  dir="$TMP_ROOT/server-owned-external-up"; mkdir -p "$dir/session"
  printf 'systemd user unit herdr-fmtest.service\n' > "$dir/session/firstmate-server-owner"
  : > "$dir/running"
  out=$(run_owned_server_ensure "$dir")
  status=$?
  expect_code 0 $status "server_ensure should use a running externally managed server: $out"
  [ ! -e "$dir/sleep-count" ] || fail "server_ensure waited on a running externally managed server with no replacement in progress"
  [ ! -e "$dir/starts" ] || fail "server_ensure started a server that an external owner manages"
  pass "fm_backend_herdr_server_ensure: a running externally managed server is used at once"
}

test_server_ensure_waits_out_a_server_replacement() {
  local dir out status
  dir="$TMP_ROOT/server-owned-replacing"; mkdir -p "$dir/session"
  : > "$dir/session/firstmate-server-replacing"
  out=$(run_owned_server_ensure "$dir" FM_HERDR_FLIP_AFTER=3 FM_HERDR_FLIP=up)
  status=$?
  expect_code 0 $status "server_ensure should proceed once the replaced server reports running: $out"
  [ ! -e "$dir/starts" ] || fail "server_ensure started a server during a replacement"
  [ "$(cat "$dir/sleep-count")" = 3 ] || fail "server_ensure should have waited until the replacement ended on the third wait, got $(cat "$dir/sleep-count")"
  pass "fm_backend_herdr_server_ensure: a replacement marker makes it wait without starting, then proceed once the server is running"
}

test_server_ensure_holds_callers_off_a_running_server_during_a_replacement() {
  local dir out status
  dir="$TMP_ROOT/server-owned-replacing-running"; mkdir -p "$dir/session"
  : > "$dir/session/firstmate-server-replacing"
  : > "$dir/running"
  out=$(run_owned_server_ensure "$dir" FM_HERDR_FLIP_AFTER=4 FM_HERDR_FLIP=clear)
  status=$?
  expect_code 0 $status "server_ensure should proceed once the replacement marker clears: $out"
  [ ! -e "$dir/starts" ] || fail "server_ensure started a server during a replacement"
  [ "$(cat "$dir/sleep-count" 2>/dev/null)" = 4 ] || fail "server_ensure released its caller to a running server while the replacement marker remained: $(cat "$dir/sleep-count" 2>/dev/null) waits"
  pass "fm_backend_herdr_server_ensure: a running server is not used while a replacement marker remains"
}

test_server_ensure_resumes_ownership_after_a_replacement_clears() {
  local dir out status
  dir="$TMP_ROOT/server-owned-replacing-cleared"; mkdir -p "$dir/session"
  : > "$dir/session/firstmate-server-replacing"
  out=$(run_owned_server_ensure "$dir" FM_HERDR_FLIP_AFTER=2 FM_HERDR_FLIP=clear)
  status=$?
  expect_code 0 $status "server_ensure should start its own server once a replacement ends with the server down: $out"
  [ "$(cat "$dir/starts" 2>/dev/null)" = started ] || fail "server_ensure did not start its own server after the replacement marker cleared"
  pass "fm_backend_herdr_server_ensure: with no owner marker, a cleared replacement hands back to the Firstmate-owned start"
}

test_server_ensure_reports_a_replacement_that_never_ends() {
  local dir out status
  dir="$TMP_ROOT/server-owned-replacing-stuck"; mkdir -p "$dir/session"
  : > "$dir/session/firstmate-server-replacing"
  : > "$dir/running"
  out=$(run_owned_server_ensure "$dir")
  status=$?
  [ "$status" -ne 0 ] || fail "server_ensure must fail when a replacement never finishes, even with the server running"
  [ ! -e "$dir/starts" ] || fail "server_ensure started a server while the replacement marker remained"
  [ "$(cat "$dir/sleep-count")" = 60 ] || fail "server_ensure should give up after its 60 bounded waits, got $(cat "$dir/sleep-count")"
  assert_contains "$out" "is being replaced ($dir/session/firstmate-server-replacing)" "the error should name the replacement marker"
  pass "fm_backend_herdr_server_ensure: a replacement that never ends fails naming its marker instead of starting or using a server"
}

test_container_ensure_reuses_existing_workspace() {
  local dir log resp fb out
  dir="$TMP_ROOT/container-reuse"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[{"workspace_id":"w9","label":"firstmate"}]}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w9\t' ] || fail "container_ensure should reuse the existing firstmate workspace id with an EMPTY seeded-tab field (an ADOPTED workspace is never a prune candidate), got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "container_ensure should not create a workspace that already exists"
  pass "fm_backend_herdr_container_ensure: reuses an existing firstmate workspace without recreating it, and reports no seeded default tab (adopted, not created)"
}

test_create_task_refuses_duplicate_label() {
  local dir log resp fb out status
  dir="$TMP_ROOT/dup-task"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-dup1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse an existing tab label (herdr itself does not enforce uniqueness)"
  assert_contains "$out" "already exists" "create_task did not report the duplicate label"
  pass "fm_backend_herdr_create_task: refuses a duplicate tab label (herdr's own tab create has no uniqueness check)"
}

# --- restored-layout husk close-and-replace (herdr session.json restore) -----
#
# herdr persists and restores its whole session layout (workspaces/tabs/
# panes) across a server restart, including a reboot. A restored fm-<id> task
# tab comes back a HUSK - a dead pane, or a plain agent-less shell sitting in
# the saved cwd - never the crewmate that used to be there. Before this fix,
# create_task refused ANY same-labeled tab unconditionally, so every fleet
# respawn after such a restart needed the operator to manually close each
# husk pane first. These tests cover the four cases the fix must get right:
# a genuinely LIVE duplicate still refuses (unchanged), a DEAD pane husk and a
# NO-AGENT (restored plain shell) husk both close-and-replace, and an
# AMBIGUOUS/unparseable read refuses (fail-safe, never guesses toward
# closing).

test_create_task_refuses_duplicate_label_when_agent_live() {
  local dir log resp fb out status
  dir="$TMP_ROOT/dup-live"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: tab list -> an existing same-labeled tab
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-dup1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  # 2: pane list (pane_for_tab) -> resolves the duplicate's pane id
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  # 3: pane get -> the pane structurally exists
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  # 4: agent get -> a genuinely registered, live agent (idle, not just working)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  # 5: pane process-info -> a live Pi process backs that registration (#4115)
  printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4243,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi"}]}}}' > "$resp/5.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should still refuse when the duplicate's pane hosts a live (even idle) registered agent"
  assert_contains "$out" "already exists" "create_task did not report the duplicate label for a live agent"
  assert_not_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create' "create_task must not create a replacement tab when the duplicate is live"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' "create_task must not close a live agent's pane"
  pass "fm_backend_herdr_create_task: a same-labeled tab with a live (even idle) registered agent still refuses exactly as before"
}

test_create_task_refuses_when_any_duplicate_label_is_live() {
  local dir log resp fb out status
  dir="$TMP_ROOT/dup-mixed-live"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-mixed1","workspace_id":"w1"},{"tab_id":"w1:t3","label":"fm-mixed1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"w1:p3"}}}\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/7.out"
  # 8: pane process-info -> a live Pi process backs that registration (#4115)
  printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":4242,"foreground_process_group_id":4243,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi"}]}}}' > "$resp/8.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-mixed1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must refuse when any same-labeled tab hosts a live registered agent"
  assert_contains "$out" "already exists" "create_task did not report the duplicate label when one duplicate was live"
  assert_not_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create' "create_task must not create a replacement tab when any duplicate is live"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' "create_task must not close any duplicate pane when one duplicate is live"
  pass "fm_backend_herdr_create_task: scans every same-labeled tab and refuses if any duplicate is live"
}

test_create_task_closes_and_replaces_dead_pane_husk() {
  local dir log resp fb out status tab pane
  dir="$TMP_ROOT/husk-dead"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-husk1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  # 3: pane get -> pane_not_found: the restored pane is dead
  printf '{"error":{"code":"pane_not_found","message":"pane w1:p2 not found"}}\n' > "$resp/3.out"
  # 4: tab create -> the replacement tab (created BEFORE the husk is closed)
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/4.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t3","label":"fm-husk1","workspace_id":"w1"}]}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-husk1 /tmp/proj' "$ROOT" ) \
    || fail "create_task should close-and-replace a dead-pane husk instead of refusing"
  read -r tab pane <<EOF
$out
EOF
  if [ "$tab" != "w1:t3" ] || [ "$pane" != "w1:p3" ]; then
    fail "create_task should echo the NEW tab/pane ids, got '$out'"
  fi
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f''w1'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--label'$'\x1f''fm-husk1' \
    "create_task did not create the replacement tab"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "create_task did not close the dead husk's tab"
  pass "fm_backend_herdr_create_task: closes and replaces a same-labeled tab whose pane is dead (pane_not_found)"
}

test_create_task_closes_and_replaces_no_agent_husk() {
  local dir log resp fb out status tab pane
  dir="$TMP_ROOT/husk-no-agent"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-husk2","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  # 3: pane get -> the pane is alive (a session-restore restarts the shell)
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  # 4: agent get -> agent_not_found: nothing registered - a restored plain shell
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  # 5: tab create -> the replacement tab (created BEFORE the husk is closed)
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/5.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t3","label":"fm-husk2","workspace_id":"w1"}]}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-husk2 /tmp/proj' "$ROOT" ) \
    || fail "create_task should close-and-replace a no-agent husk (restored plain shell) instead of refusing"
  read -r tab pane <<EOF
$out
EOF
  if [ "$tab" != "w1:t3" ] || [ "$pane" != "w1:p3" ]; then
    fail "create_task should echo the NEW tab/pane ids, got '$out'"
  fi
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f''w1'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--label'$'\x1f''fm-husk2' \
    "create_task did not create the replacement tab"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "create_task did not close the no-agent husk's tab"
  pass "fm_backend_herdr_create_task: closes and replaces a same-labeled tab whose pane is alive but hosts no registered agent (a restored plain shell)"
}

test_create_task_closes_all_duplicate_husks_after_replacement() {
  local dir log resp fb out tab pane create_line close_p2_line close_p3_line
  dir="$TMP_ROOT/husk-multiple"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-husk-many","workspace_id":"w1"},{"tab_id":"w1:t3","label":"fm-husk-many","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"w1:p3"}}}\n' > "$resp/6.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p3 not found"}}\n' > "$resp/7.out"
  printf '{"result":{"tab":{"tab_id":"w1:t4"},"root_pane":{"pane_id":"w1:p4"}}}\n' > "$resp/8.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t4","label":"fm-husk-many","workspace_id":"w1"}]}}\n' > "$resp/11.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-husk-many /tmp/proj' "$ROOT" ) \
    || fail "create_task should close-and-replace all same-labeled husks after creating a replacement"
  read -r tab pane <<EOF
$out
EOF
  if [ "$tab" != "w1:t4" ] || [ "$pane" != "w1:p4" ]; then
    fail "create_task should echo the NEW tab/pane ids, got '$out'"
  fi
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "create_task did not close the first duplicate husk"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t3' "create_task did not close the second duplicate husk"
  create_line=$(grep -n $'\x1f''tab'$'\x1f''create' "$log" | head -1 | cut -d: -f1)
  close_p2_line=$(grep -n $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "$log" | head -1 | cut -d: -f1)
  close_p3_line=$(grep -n $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t3' "$log" | head -1 | cut -d: -f1)
  [ -n "$create_line" ] || fail "expected a 'tab create' call in the log"
  if [ "$create_line" -ge "$close_p2_line" ] || [ "$create_line" -ge "$close_p3_line" ]; then
    fail "REGRESSION: duplicate husks were closed before the replacement tab was created"
  fi
  pass "fm_backend_herdr_create_task: closes every confirmed same-labeled husk only after creating the replacement"
}

test_create_task_refuses_when_preexisting_husk_tab_remains() {
  local dir log resp fb out status
  dir="$TMP_ROOT/husk-close-fails"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-stale-husk","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/5.out"
  printf '1\n' > "$resp/6.exit"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-stale-husk","workspace_id":"w1"},{"tab_id":"w1:t3","label":"fm-stale-husk","workspace_id":"w1"}]}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-stale-husk /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must fail when a preexisting same-labeled husk remains after close-and-replace"
  assert_contains "$out" "failed to remove preexisting herdr tab" "create_task did not report the stale preexisting husk tab"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "create_task did not close the stale husk by tab id"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p2' "create_task should not rely on pane close for a preexisting husk"
  pass "fm_backend_herdr_create_task: refuses success when a preexisting husk tab remains after replacement"
}

test_create_task_refuses_when_agent_state_ambiguous() {
  # An unexpected error code from agent get (neither agent_not_found nor a
  # successful read) must not be misread as a husk - fail-safe toward
  # refusal, exactly like today's unconditional-refusal behavior.
  local dir log resp fb out status
  dir="$TMP_ROOT/husk-ambiguous"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-ambig1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  # 4: agent get -> an unrecognized error code, not agent_not_found
  printf '{"error":{"code":"internal_error","message":"transient failure"}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-ambig1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must refuse (fail-safe) when the agent state cannot be classified confidently, not treat it as a husk"
  assert_contains "$out" "already exists" "create_task did not report the duplicate label for an ambiguous state"
  assert_not_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create' "create_task must not create a replacement tab on an ambiguous read"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' "create_task must not close a pane whose state is ambiguous"
  pass "fm_backend_herdr_create_task: refuses (fail-safe) rather than guessing when the duplicate's agent state cannot be classified confidently"
}

test_create_task_husk_replacement_creates_before_closing() {
  # Safety-critical ordering: the replacement tab must be created BEFORE the
  # husk tab is closed, never the reverse - closing a workspace's LAST
  # remaining tab deletes the whole workspace on real herdr (docs/herdr-
  # backend.md "Workspace lifecycle"), and a session-restore husk can
  # legitimately be that workspace's only tab. Verified here by log order
  # rather than by state, since herdr's destroy-on-last-tab-close side effect
  # is not modeled by the canned-response fake.
  local dir log resp fb out create_line close_line
  dir="$TMP_ROOT/husk-order"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-order1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  printf '{"error":{"code":"pane_not_found","message":"pane w1:p2 not found"}}\n' > "$resp/3.out"
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/4.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t3","label":"fm-order1","workspace_id":"w1"}]}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-order1 /tmp/proj' "$ROOT" ) \
    || fail "create_task should close-and-replace the dead-pane husk"
  create_line=$(grep -n $'\x1f''tab'$'\x1f''create' "$log" | head -1 | cut -d: -f1)
  close_line=$(grep -n $'\x1f''tab'$'\x1f''close' "$log" | head -1 | cut -d: -f1)
  [ -n "$create_line" ] || fail "expected a 'tab create' call in the log"
  [ -n "$close_line" ] || fail "expected a 'tab close' call in the log"
  [ "$create_line" -lt "$close_line" ] || fail "REGRESSION: the husk tab was closed (line $close_line) before (or at the same time as) the replacement tab was created (line $create_line) - risks deleting the whole workspace if the husk was its only tab"
  pass "fm_backend_herdr_create_task: creates the replacement tab BEFORE closing the husk tab, never the reverse"
}

test_create_task_creates_and_parses_ids() {
  local dir log resp fb out
  dir="$TMP_ROOT/create-task"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[]}}\n' > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "w1:t2 w1:p2" ] || fail "create_task should echo '<tab_id> <pane_id>', got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f''w1'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--label'$'\x1f''fm-newtask' \
    "create_task did not call tab create with workspace/cwd/label"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' \
    "create_task must never prune when called with no seeded default tab id (the 4th arg defaults to empty)"
  pass "fm_backend_herdr_create_task: creates a tab and parses tab_id/pane_id from the JSON response, prunes nothing when no seeded tab id is given"
}

# --- container_ensure / create_task: --no-focus and per-home label ----------

test_container_ensure_creates_with_no_focus_flag() {
  local dir log resp fb out
  dir="$TMP_ROOT/container-no-focus"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[]}}\n' > "$resp/3.out"
  printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w1\tw1:t1' ] || fail "container_ensure should still echo '<session>:<workspace_id>\\t<seeded_default_tab_id>', got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--cwd'$'\x1f''/tmp'$'\x1f''--label'$'\x1f''firstmate'$'\x1f''--no-focus' \
    "container_ensure's workspace create did not pass --no-focus (focus-safety: never steal the captain's attention on spawn)"
  pass "fm_backend_herdr_container_ensure: workspace create passes --no-focus"
}

test_container_ensure_uses_secondmate_home_label() {
  local dir log resp fb out home
  dir="$TMP_ROOT/container-secondmate-label"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/container-secondmate-home"; mkdir -p "$home"; printf 'sshhip-h7\n' > "$home/.fm-secondmate-home"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[]}}\n' > "$resp/3.out"
  printf '{"result":{"workspace":{"workspace_id":"w9","label":"2ndmate-sshhip-h7"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w9\tw9:t1' ] || fail "container_ensure did not echo the expected session:workspace_id + seeded default tab id, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--cwd'$'\x1f''/tmp'$'\x1f''--label'$'\x1f''2ndmate-sshhip-h7' \
    "container_ensure did not create the workspace under this secondmate home's own label"
  pass "fm_backend_herdr_container_ensure: creates the workspace under the SECONDMATE home's own label, not 'firstmate'"
}

test_container_ensure_creates_configured_home_label() {
  local dir log resp fb out home
  dir="$TMP_ROOT/container-configured-label"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/container-configured-home"; mkdir -p "$home/config"
  printf 'fm-dsh\n' > "$home/config/herdr-workspace"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' > "$resp/3.out"
  printf '{"result":{"workspace":{"workspace_id":"w2","label":"fm-dsh"},"tab":{"tab_id":"w2:t1"},"root_pane":{"pane_id":"w2:p1"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w2\tw2:t1' ] || fail "container_ensure should create the configured workspace, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--cwd'$'\x1f''/tmp'$'\x1f''--label'$'\x1f''fm-dsh' \
    "container_ensure did not create the workspace under the configured label"
  pass "fm_backend_herdr_container_ensure: creates the workspace under config/herdr-workspace's label instead of 'firstmate'"
}

test_container_ensure_adopts_only_the_configured_home_label() {
  local dir log resp fb out home
  dir="$TMP_ROOT/container-configured-adopt"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/container-configured-adopt-home"; mkdir -p "$home/config"
  printf 'fm-dsh\n' > "$home/config/herdr-workspace"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"fm-dsh"}]}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w2\t' ] || fail "container_ensure should adopt only the configured 'fm-dsh' workspace, got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "container_ensure should not create a workspace when the configured one exists"
  pass "fm_backend_herdr_container_ensure: exact-matches the configured label and never falls back to the legacy 'firstmate' workspace"
}

test_container_ensure_refuses_unusable_configured_label() {
  local dir log resp fb out status home
  dir="$TMP_ROOT/container-configured-refused"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/container-configured-bad-home"; mkdir -p "$home/config"
  printf 'fm dsh\n' > "$home/config/herdr-workspace"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "container_ensure must refuse an unusable config/herdr-workspace value"
  assert_contains "$out" "unusable herdr workspace label" "container_ensure buried the actionable label refusal"
  assert_contains "$out" "$home/config/herdr-workspace" "the refusal did not name the offending config file"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "container_ensure created a workspace despite the unusable configured label"
  pass "fm_backend_herdr_container_ensure: refuses an unusable configured label before any workspace mutation"
}

test_create_task_creates_with_no_focus_flag() {
  local dir log resp fb out
  dir="$TMP_ROOT/create-task-no-focus"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[]}}\n' > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "w1:t2 w1:p2" ] || fail "create_task should still echo '<tab_id> <pane_id>', got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f''w1'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--label'$'\x1f''fm-newtask'$'\x1f''--no-focus' \
    "create_task's tab create did not pass --no-focus"
  pass "fm_backend_herdr_create_task: tab create passes --no-focus"
}

# --- default-on disposable presentation projection --------------------------

# make_release_fakebin: a `herdr` stub whose only job is `status --json`, so the
# presentation version floor can be exercised against scripted client and
# selected-session server releases with no herdr installed at all. An empty
# protocol or version omits that field; the literal client value "unreadable"
# makes the whole call fail, and a server-running value other than true or false
# omits that state.
make_release_fakebin() {  # <dir> <client-protocol> <client-version> [<server-running> <server-protocol> <server-version>] -> echoes fakebin dir
  local dir=$1 protocol=$2 version=$3 server_running=${4:-false} server_protocol=${5:-} server_version=${6:-}
  local fb="$1/release-fakebin" fields="" server_fields=""
  mkdir -p "$fb"
  if [ -n "$version" ]; then
    fields="\"version\":\"$version\""
  fi
  if [ -n "$protocol" ]; then
    [ -n "$fields" ] && fields="$fields,"
    fields="$fields\"protocol\":$protocol"
  fi
  case "$server_running" in
    true|false) server_fields="\"running\":$server_running" ;;
  esac
  if [ -n "$server_version" ]; then
    [ -n "$server_fields" ] && server_fields="$server_fields,"
    server_fields="$server_fields\"version\":\"$server_version\""
  fi
  if [ -n "$server_protocol" ]; then
    [ -n "$server_fields" ] && server_fields="$server_fields,"
    server_fields="$server_fields\"protocol\":$server_protocol"
  fi
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = status ] || exit 3
SH
  if [ "$protocol" = unreadable ] || [ "$version" = unreadable ]; then
    printf 'exit 4\n' >> "$fb/herdr"
  else
    printf 'printf %s\n' "'{\"client\":{$fields},\"server\":{$server_fields}}\\n'" >> "$fb/herdr"
  fi
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# fm_backend_herdr_presentation_enabled is the one gate bin/fm-spawn.sh consults
# before projecting a crewmate or scout, so these cases pin the default-on
# contract, its explicit opt-out, its explicit opt-in, and the version floor
# that decides the unconfigured default at that interface.
presentation_enabled_verdict() {  # <config-dir> <fakebin> [state-dir] [session] -> "on"/"off"
  HERDR_SESSION="${4:-}" PATH="$2:$PATH" bash -c '
    . "$0/bin/backends/herdr.sh"
    if fm_backend_herdr_presentation_enabled "$1" "$2"; then printf "on\n"; else printf "off\n"; fi
  ' "$ROOT" "$1" "${3:-}"
}

# The exact release identities measured against the real macOS aarch64 release
# binaries on 2026-08-05 and recorded in docs/verification/runtime-backends.md.
AT_FLOOR_PROTOCOL=19
AT_FLOOR_VERSION=0.8.0
BELOW_FLOOR_PROTOCOL=17
BELOW_FLOOR_VERSION=0.7.5

test_presentation_defaults_on_at_or_above_the_floor() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-default-on"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/default-on.err"
  fb=$(make_release_fakebin "$dir" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "an absent presentation config at the floor must resolve on, got '$verdict'"
  [ ! -s "$stderr" ] || fail "a supported release must not warn: $(cat "$stderr")"
  verdict=$(presentation_enabled_verdict "$dir/missing-config-dir" "$fb" 2>/dev/null)
  [ "$verdict" = on ] || fail "a missing config dir at the floor must resolve on, got '$verdict'"
  pass "herdr presentation: a home that set nothing gets the projection by default at or above the floor"
}

test_presentation_default_falls_back_below_the_floor() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-below-floor"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/below-floor.err"
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = off ] || fail "an unconfigured home below the floor must fall back flat, got '$verdict'"
  assert_contains "$(cat "$stderr")" "$BELOW_FLOOR_VERSION" \
    "the below-floor warning must name the running release"
  assert_contains "$(cat "$stderr")" "0.8.0" \
    "the below-floor warning must name the upgrade that fixes it"
  pass "herdr presentation: an unconfigured home below the floor falls back flat with one naming warning"
}

test_presentation_unreadable_release_falls_back() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-unreadable"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/unreadable.err"
  fb=$(make_release_fakebin "$dir" unreadable unreadable)
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = off ] || fail "an unverifiable release must fall back flat, got '$verdict'"
  assert_contains "$(cat "$stderr")" "could not be read" \
    "an unverifiable release must say the floor could not be checked"
  pass "herdr presentation: an unreadable client release falls back flat instead of guessing"
}

test_presentation_explicit_opt_in_survives_the_floor() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-legacy-opt-in"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/legacy.err"
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  # The historical opt-in was a bare `touch` of the file, so an empty file must
  # keep meaning a deliberate on - and must not warn, or every migrated home
  # warns on every spawn.
  : > "$config/herdr-presentation-spaces"
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "a legacy empty opt-in file must resolve on below the floor, got '$verdict'"
  [ ! -s "$stderr" ] || fail "a legacy empty opt-in file must not warn: $(cat "$stderr")"
  printf '\n \n' > "$config/herdr-presentation-spaces"
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "a whitespace-only opt-in file must resolve on below the floor, got '$verdict'"
  [ ! -s "$stderr" ] || fail "a whitespace-only opt-in file must not warn: $(cat "$stderr")"
  printf 'on\n' > "$config/herdr-presentation-spaces"
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "an explicit on must resolve on below the floor, got '$verdict'"
  [ ! -s "$stderr" ] || fail "an explicit opt-in must not warn: $(cat "$stderr")"
  pass "herdr presentation: a deliberate opt-in is never silently downgraded below the floor"
}

test_presentation_explicit_off_opts_out() {
  local dir config fb verdict value
  dir="$TMP_ROOT/presentation-opt-out"; config="$dir/config"; mkdir -p "$config"
  fb=$(make_release_fakebin "$dir" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  for value in 'off' 'off
' '  off  ' 'OFF' 'Off'; do
    printf '%s' "$value" > "$config/herdr-presentation-spaces"
    verdict=$(presentation_enabled_verdict "$config" "$fb" 2>/dev/null)
    [ "$verdict" = off ] || fail "the opt-out value '$value' must resolve off, got '$verdict'"
  done
  pass "herdr presentation: an explicit off opts the home out"
}

test_presentation_unrecognized_value_warns_and_keeps_the_default() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-unrecognized"; config="$dir/config"; mkdir -p "$config"
  stderr="$dir/unrecognized.err"
  printf 'disabled\n' > "$config/herdr-presentation-spaces"
  fb=$(make_release_fakebin "$dir" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = on ] || fail "an unrecognized value at the floor must keep the default on, got '$verdict'"
  assert_contains "$(cat "$stderr")" 'unrecognized value' \
    "an unrecognized value must warn so a typo is visible"
  # A typo is not a deliberate opt-in, so below the floor it takes the default's
  # flat fallback rather than forcing a focus-unsafe projection.
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" 2>"$stderr")
  [ "$verdict" = off ] || fail "an unrecognized value below the floor must follow the default, got '$verdict'"
  pass "herdr presentation: an unrecognized value warns and follows the default instead of failing a spawn"
}

test_presentation_floor_warning_is_one_per_release() {
  local dir config state fb first second third
  dir="$TMP_ROOT/presentation-floor-dedupe"; config="$dir/config"; state="$dir/state"
  mkdir -p "$config" "$state"
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  first=$(presentation_enabled_verdict "$config" "$fb" "$state" 2>&1 >/dev/null)
  second=$(presentation_enabled_verdict "$config" "$fb" "$state" 2>&1 >/dev/null)
  [ -n "$first" ] || fail "the first below-floor spawn must warn"
  [ -z "$second" ] || fail "a repeat spawn on the same release must not warn again: $second"
  # A downgrade or an upgrade is a different release, so it is announced again.
  fb=$(make_release_fakebin "$dir/other" 16 0.7.3)
  third=$(presentation_enabled_verdict "$config" "$fb" "$state" 2>&1 >/dev/null)
  assert_contains "$third" '0.7.3' "a changed release must re-announce the floor"
  pass "herdr presentation: the below-floor warning is one per home per release, not one per spawn"
}

test_presentation_floor_warning_marker_is_atomic_and_symlink_safe() {
  local dir config state fb i pid warnings marker outside symlink_warning failure_state failure_warning
  local pids=()
  dir="$TMP_ROOT/presentation-floor-marker-safety"; config="$dir/config"; state="$dir/state"
  mkdir -p "$config" "$state"
  fb=$(make_release_fakebin "$dir" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  for i in {1..20}; do
    presentation_enabled_verdict "$config" "$fb" "$state" \
      >"$dir/concurrent-$i.out" 2>"$dir/concurrent-$i.err" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "a concurrent presentation-floor verdict failed"
  done
  warnings=$(awk '/^warning:/ { count++ } END { print count + 0 }' "$dir"/concurrent-*.err)
  [ "$warnings" -eq 1 ] \
    || fail "concurrent below-floor spawns must publish exactly one warning, got $warnings"

  state="$dir/symlink-state"
  mkdir -p "$state"
  marker="$state/.herdr-presentation-floor-version-0-7-5--protocol-17-"
  outside="$dir/symlink-target"
  ln -s "$outside" "$marker"
  symlink_warning=$(presentation_enabled_verdict "$config" "$fb" "$state" 2>&1 >/dev/null)
  [ -z "$symlink_warning" ] \
    || fail "an existing dangling marker symlink must be treated as already claimed: $symlink_warning"
  [ ! -e "$outside" ] \
    || fail "publishing the floor marker followed a dangling symlink outside the state directory"

  failure_state="$dir/failure-state"
  mkdir -p "$failure_state"
  cat > "$fb/ln" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/ln"
  failure_warning=$(presentation_enabled_verdict "$config" "$fb" "$failure_state" 2>&1 >/dev/null)
  [ -n "$failure_warning" ] \
    || fail "a non-collision marker publication failure must not suppress the warning"
  pass "herdr presentation: warning marker publication is atomic, symlink-safe, and fails visible"
}

test_presentation_running_server_release_is_load_bearing() {
  local dir config fb verdict stderr
  dir="$TMP_ROOT/presentation-running-server-floor"; config="$dir/config"
  mkdir -p "$config"
  stderr="$dir/server.err"

  fb=$(make_release_fakebin "$dir/old-server" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION" \
    true "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" stale-session 2>"$stderr")
  [ "$verdict" = off ] \
    || fail "an old running server must keep a new client below the presentation floor, got '$verdict'"
  assert_contains "$(cat "$stderr")" "server version $BELOW_FLOOR_VERSION" \
    "the floor warning must name the selected running server release"

  fb=$(make_release_fakebin "$dir/new-server" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION" \
    true "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" current-session 2>"$stderr")
  [ "$verdict" = on ] \
    || fail "an at-floor client and running server must project, got '$verdict'"
  [ ! -s "$stderr" ] || fail "an at-floor client and running server must not warn: $(cat "$stderr")"

  fb=$(make_release_fakebin "$dir/old-client" "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION" \
    true "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" current-session 2>"$stderr")
  [ "$verdict" = off ] \
    || fail "a below-floor client must conservatively block projection despite an at-floor server, got '$verdict'"
  assert_contains "$(cat "$stderr")" "$BELOW_FLOOR_VERSION" \
    "the conservative client/server warning must name the below-floor client"

  printf 'on\n' > "$config/herdr-presentation-spaces"
  fb=$(make_release_fakebin "$dir/opt-in-old-server" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION" \
    true "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION")
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" stale-session 2>"$stderr")
  [ "$verdict" = on ] \
    || fail "an explicit opt-in must survive a below-floor running server, got '$verdict'"
  [ ! -s "$stderr" ] || fail "an explicit opt-in below the server floor must not warn: $(cat "$stderr")"
  unlink "$config/herdr-presentation-spaces"

  fb=$(make_release_fakebin "$dir/unknown-server" "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION" unknown)
  verdict=$(presentation_enabled_verdict "$config" "$fb" "" unknown-session 2>"$stderr")
  [ "$verdict" = off ] \
    || fail "an unreadable selected-session server state must fail flat instead of substituting the client, got '$verdict'"
  assert_contains "$(cat "$stderr")" "could not be read" \
    "an unreadable selected-session server state must warn"
  pass "herdr presentation: client and selected server floors compose conservatively without overriding explicit opt-in"
}

# The floor classifier is pure, so these cases pin it against every release
# identity measured from the real binaries plus the deliberate signal-loss and
# signal-divergence shapes that decide which signal carried a verdict.
release_floor_verdict() {  # <protocol> <version> -> above|below|indeterminate
  bash -c '
    . "$0/bin/backends/herdr.sh"
    status=0
    fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
    case "$status" in
      0) printf "above\n" ;;
      1) printf "below\n" ;;
      *) printf "indeterminate\n" ;;
    esac
  ' "$ROOT" "$1" "$2"
}

test_release_floor_verdict_matches_the_measured_releases() {
  local expected protocol version got case_line
  # protocol<TAB>version<TAB>expected, from the 2026-08-05 measurement.
  while IFS=$'\t' read -r protocol version expected; do
    [ -n "$expected" ] || continue
    got=$(release_floor_verdict "$protocol" "$version")
    [ "$got" = "$expected" ] \
      || fail "protocol '$protocol' version '$version' should be $expected, got $got"
  done <<'CASES'
16	0.7.3	below
16	0.7.4	below
17	0.7.5	below
17	0.7.5-preview.2026-07-21-0f10e1453a7f	below
18	0.7.5-preview.2026-07-29-44b3adb12552	below
19	0.8.0-preview.2026-08-04-d78e3d3b5126	above
19	0.8.0	above
20	0.9.0	above
CASES
  case_line=$(release_floor_verdict 19 '')
  [ "$case_line" = above ] || fail "a floor protocol alone must carry an above verdict, got $case_line"
  case_line=$(release_floor_verdict 17 '')
  [ "$case_line" = below ] || fail "a below-floor protocol alone must carry a below verdict, got $case_line"
  case_line=$(release_floor_verdict '' 0.8.0)
  [ "$case_line" = above ] || fail "a floor version alone must carry an above verdict, got $case_line"
  case_line=$(release_floor_verdict '' 0.7.5)
  [ "$case_line" = below ] || fail "a below-floor version alone must carry a below verdict, got $case_line"
  case_line=$(release_floor_verdict '' '')
  [ "$case_line" = indeterminate ] || fail "losing both signals must be indeterminate, got $case_line"
  case_line=$(release_floor_verdict 'not-a-number' 'not-a-version')
  [ "$case_line" = indeterminate ] || fail "two unparseable signals must be indeterminate, got $case_line"
  pass "herdr presentation floor: every measured release, and each signal alone, classifies correctly"
}

test_release_floor_verdict_survives_losing_either_signal() {
  local got
  # Divergence, asserted explicitly so neither half can go vacuous: with a
  # floor protocol and a below-floor version the protocol carries the verdict,
  # and removing it flips the answer, which proves it was load-bearing there.
  got=$(release_floor_verdict 19 0.7.5)
  [ "$got" = above ] || fail "the protocol signal must carry an above verdict on its own, got $got"
  got=$(release_floor_verdict '' 0.7.5)
  [ "$got" = below ] || fail "the divergent case must flip once the protocol signal is gone, got $got"
  # The mirror image: a floor version with a stale protocol, and the same
  # removal check.
  got=$(release_floor_verdict 16 0.9.0)
  [ "$got" = above ] || fail "the version signal must carry an above verdict on its own, got $got"
  got=$(release_floor_verdict 16 '')
  [ "$got" = below ] || fail "the divergent case must flip once the version signal is gone, got $got"
  pass "herdr presentation floor: either signal alone can carry an above verdict, and each divergence is real"
}

test_presentation_preference_reports_three_distinct_states() {
  local dir config got
  dir="$TMP_ROOT/presentation-preference"; config="$dir/config"; mkdir -p "$config"
  preference() {
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_preference "$1"' "$ROOT" "$1" 2>/dev/null
  }
  got=$(preference "$config")
  [ "$got" = default ] || fail "an absent file must report the default, got '$got'"
  printf 'on\n' > "$config/herdr-presentation-spaces"
  got=$(preference "$config")
  [ "$got" = on ] || fail "an explicit on must report on, got '$got'"
  printf 'off\n' > "$config/herdr-presentation-spaces"
  got=$(preference "$config")
  [ "$got" = off ] || fail "an explicit off must report off, got '$got'"
  printf 'disabled\n' > "$config/herdr-presentation-spaces"
  got=$(preference "$config")
  [ "$got" = default ] || fail "an unrecognized value must report the default, got '$got'"
  pass "herdr presentation: config parsing separates a deliberate choice from an unconfigured default"
}

test_projection_journal_is_atomic_and_uses_128_bit_token() {
  local dir state out token parsed status
  dir="$TMP_ROOT/projection-journal"; state="$dir/state"; mkdir -p "$state"
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" task-p1) || exit 1
    parsed=$(fm_backend_herdr_projection_journal_token "$1/task-p1.herdr-presentation" task-p1) || exit 1
    printf "%s\n%s\n" "$token" "$parsed"
    fm_backend_herdr_projection_journal_create "$1" task-p1 >/dev/null 2>&1
  ' "$ROOT" "$state" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a second presentation journal publication must fail instead of overwriting the first"
  token=$(printf '%s\n' "$out" | sed -n '1p')
  parsed=$(printf '%s\n' "$out" | sed -n '2p')
  [ "$token" = "$parsed" ] || fail "journal round-trip changed the projection id"
  [ "${#token}" -eq 22 ] || fail "a 128-bit base64url projection id must be 22 characters, got '${#token}'"
  case "$token" in *[!A-Za-z0-9_-]*) fail "projection id was not base64url: $token" ;; esac
  [ "$(wc -l < "$state/task-p1.herdr-presentation" | tr -d '[:space:]')" = 3 ] \
    || fail "presentation journal must contain only version, task id, and projection id"
  pass "herdr presentation journal: atomically publishes one non-authoritative 128-bit correlator and refuses overwrite"
}

test_projection_journal_v2_binds_and_advances_exact_endpoint() {
  local dir state home home_real out token
  dir="$TMP_ROOT/projection-journal-v2"; state="$dir/state"; home="$dir/home"
  mkdir -p "$state" "$home"
  home_real=$(cd "$home" && pwd -P)
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" fm-hibit-r1) || exit 1
    journal="$1/fm-hibit-r1.herdr-presentation"
    home=$(fm_backend_herdr_projection_home_identity "$2") || exit 1
    label=$(fm_backend_herdr_projection_workspace_label fm-hibit-r1 "$token")
    fm_backend_herdr_projection_journal_bind \
      "$journal" fm-hibit-r1 "$home" lab-session w2 w2:t2 w2:p2 w1 firstmate "$label" fm-fm-hibit-r1 || exit 1
    fm_backend_herdr_projection_journal_snapshot "$journal" fm-hibit-r1 || exit 1
    printf "%s|%s|%s|%s|%s|%s|%s\n" \
      "$FM_BACKEND_HERDR_JOURNAL_VERSION" \
      "$FM_BACKEND_HERDR_JOURNAL_HOME" \
      "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL"
    fm_backend_herdr_projection_journal_replace_endpoint \
      "$journal" fm-hibit-r1 w2:t2 w2:p2 w2:t3 w2:p3 || exit 1
    fm_backend_herdr_projection_journal_snapshot "$journal" fm-hibit-r1 || exit 1
    printf "%s|%s\n" "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" "$FM_BACKEND_HERDR_JOURNAL_PANE_ID"
  ' "$ROOT" "$state" "$home") || fail "version 2 projection journal binding failed"
  token=$(sed -n 's/^projection_id=//p' "$state/fm-hibit-r1.herdr-presentation")
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = "2|$home_real|w2|w2:t2|w2:p2|w1|└ hibit-r1 · p:$token" ] \
    || fail "version 2 projection journal did not retain exact home/endpoint/parent binding: $out"
  [ "$(printf '%s\n' "$out" | sed -n '2p')" = "w2:t3|w2:p3" ] \
    || fail "version 2 projection journal did not advance the exact replacement endpoint: $out"
  [ "$(wc -l < "$state/fm-hibit-r1.herdr-presentation" | tr -d '[:space:]')" = 12 ] \
    || fail "version 2 projection journal must have exactly 12 fields"
  printf 'pane_id=duplicate\n' >> "$state/fm-hibit-r1.herdr-presentation"
  if bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_snapshot "$1" fm-hibit-r1' \
    "$ROOT" "$state/fm-hibit-r1.herdr-presentation"; then
    fail "duplicate version 2 journal fields must be ambiguous"
  fi
  pass "herdr presentation journal: version 2 binds exact home/endpoint/parent identities and advances atomically"
}

test_projection_create_uses_exact_response_ids_and_leaves_one_task_pane() {
  local dir state log resp fb out token journal
  dir="$TMP_ROOT/projection-create"; state="$dir/state"; mkdir -p "$dir/responses" "$state"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}\n' > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w9:t2"},"root_pane":{"pane_id":"w9:p2"}}}\n' > "$resp/2.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"},{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/3.out"
  printf '{"result":{"panes":[{"pane_id":"w9:p1","tab_id":"w9:t1"},{"pane_id":"w9:p2","tab_id":"w9:t2"}]}}\n' > "$resp/4.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9"}}}\n' > "$resp/6.out"
  # The emptying-close plan's tab list proves the seeded prune is NOT
  # workspace-emptying (the task tab remains), so the close stays plain.
  printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"},{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/7.out"
  printf '{"error":{"code":"pane_not_found"}}\n' > "$resp/9.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/10.out"
  printf '{"result":{"panes":[{"pane_id":"w9:p2","tab_id":"w9:t2"}]}}\n' > "$resp/11.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_SESSION=fmtest \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_projection_focus_snapshot() { printf "captain-ws\tcaptain-tab"; }
      fm_backend_herdr_projection_focus_restore() { return 0; }
      token=$(fm_backend_herdr_projection_journal_create "$1" task-p2) || exit 1
      label=$(fm_backend_herdr_projection_workspace_label task-p2 "$token")
      fm_backend_herdr_projection_create_task /tmp/proj "$label" fm-task-p2 || exit 1
      printf "%s %s %s %s %s\n" \
        "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
        "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" \
        "$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID" \
        "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
        "$FM_BACKEND_HERDR_PROJECTION_PANE_ID"
    ' "$ROOT" "$state") || fail "projection create should succeed from complete exact responses"
  [ "$out" = "w9 w9:t1 w9:p1 w9:t2 w9:p2" ] || fail "projection create did not retain exact response IDs: $out"
  journal="$state/task-p2.herdr-presentation"
  token=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_token "$1" task-p2' "$ROOT" "$journal") \
    || fail "projection journal was not readable"
  assert_contains "$(cat "$log")" $'workspace\x1fcreate\x1f--cwd\x1f/tmp/proj\x1f--label\x1f└ task-p2 · p:'"$token"$'\x1f--no-focus' \
    "projection workspace create did not use the corner label, full token, and --no-focus"
  assert_contains "$(cat "$log")" $'tab\x1fcreate\x1f--workspace\x1fw9\x1f--cwd\x1f/tmp/proj\x1f--label\x1ffm-task-p2\x1f--no-focus' \
    "projection task tab did not target the exact new workspace"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p1' \
    "projection create did not prune the exact seeded root pane"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' \
    "projection create must never call workspace close"
  pass "herdr presentation create: exact response IDs yield one normal task pane with no workspace-close authority"
}

test_projection_create_never_closes_a_concurrent_same_label_tab() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-concurrent-tab"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}\n' > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w9:t2"},"root_pane":{"pane_id":"w9:p2"}}}\n' > "$resp/2.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"},{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"},{"tab_id":"w9:t3","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/3.out"
  printf '{"result":{"panes":[{"pane_id":"w9:p1","tab_id":"w9:t1"},{"pane_id":"w9:p2","tab_id":"w9:t2"},{"pane_id":"w9:p3","tab_id":"w9:t3"}]}}\n' > "$resp/4.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9"}}}\n' > "$resp/6.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"},{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"},{"tab_id":"w9:t3","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/7.out"
  printf '{"error":{"code":"pane_not_found"}}\n' > "$resp/9.out"
  printf '{"result":{"tabs":[{"tab_id":"w9:t2","label":"fm-task-p2","workspace_id":"w9"},{"tab_id":"w9:t3","label":"fm-task-p2","workspace_id":"w9"}]}}\n' > "$resp/10.out"
  printf '{"result":{"panes":[{"pane_id":"w9:p2","tab_id":"w9:t2"},{"pane_id":"w9:p3","tab_id":"w9:t3"}]}}\n' > "$resp/11.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "captain-ws\tcaptain-tab"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_create_task /tmp/proj label fm-task-p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a concurrent tab should prevent exact one-pane projection convergence"
  assert_contains "$out" "did not converge to exactly one task pane" \
    "projection did not report the concurrent shape"
  assert_not_contains "$(cat "$log")" $'tab\x1fclose\x1fw9:t3' \
    "projection closed a concurrent same-label tab"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p3' \
    "projection closed a concurrent same-label pane"
  pass "herdr presentation create: concurrent same-label tabs are never prune targets"
}

test_projection_focus_snapshot_requires_exact_workspace_and_tab() {
  local dir log resp fb out
  dir="$TMP_ROOT/projection-focus-snapshot"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":false},{"tab_id":"w2:t2","focused":true}]}}' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot fmtest' "$ROOT") \
    || fail "an exact active workspace and tab should produce a focus snapshot"
  [ "$out" = $'w2\tw2:t2' ] || fail "focus snapshot did not preserve exact response IDs: $out"
  pass "herdr presentation focus: snapshot requires one exact active workspace and tab"
}
