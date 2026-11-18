# shellcheck shell=bash
# Test cases for fm-backend-herdr, split out of tests/fm-backend-herdr.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-backend-herdr.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


test_projection_close_restores_exact_prior_focus() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-focus-restore"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":true},{"workspace_id":"w9","active_tab_id":"w9:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":false},{"tab_id":"w2:t2","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"}}}' > "$resp/3.out"
  # The emptying-close plan sees a second tab in w9, so the close stays plain
  # and the exact-tab restore backstop is what reclaims the stolen focus.
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9"},{"tab_id":"w9:t2","workspace_id":"w9"}]}}' > "$resp/4.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/6.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":true}]}}' > "$resp/7.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}' > "$resp/10.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":false},{"tab_id":"w2:t2","focused":true}]}}' > "$resp/12.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "an exact non-active projection close should succeed after restoring focus: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p2' \
    "focus-preserving cleanup did not close only the exact projection pane"
  assert_contains "$(cat "$log")" $'tab\x1ffocus\x1fw2:t2' \
    "focus-preserving cleanup did not restore the exact prior active tab"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' \
    "focus-preserving cleanup introduced workspace-close authority"
  pass "herdr presentation focus: exact pane close restores the exact prior workspace and tab"
}

test_projection_close_refuses_active_tab() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-focus-active-refusal"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","active_tab_id":"w9:t2","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t2","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9"},{"tab_id":"w9:t2","workspace_id":"w9"}]}}' > "$resp/4.out"
  cp "$resp/1.out" "$resp/5.out"
  cp "$resp/2.out" "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_FAKE_HERDR_FOREGROUND_REASON=cleared \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup must refuse when a live client is viewing the active tab"
  assert_contains "$out" "target is the captain's active tab" \
    "active-tab cleanup refusal did not explain the focus-safety boundary"
  assert_contains "$(cat "$log")" $'terminal\x1ftitle\x1fclear' \
    "live-client active-tab refusal did not probe foreground attachment"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' \
    "active-tab cleanup refusal still closed the pane"
  pass "herdr presentation focus: cleanup refuses rather than close the tab a live client is viewing"
}

test_projection_close_refuses_unknown_foreground_reason() {
  local dir events out status
  dir="$TMP_ROOT/projection-focus-unknown-foreground"; mkdir -p "$dir"
  events="$dir/events"; : > "$events"
  out=$(ROOT="$ROOT" EVENTS="$events" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() { printf "w9\tw9:t2"; }
    fm_backend_herdr_emptying_close_plan() { printf "plain\n"; }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\",\"workspace_id\":\"w9\"}}}\n" ;;
        "terminal title") printf "{\"result\":{\"reason\":\"set\"}}\n" ;;
        "pane close") printf "close\n" >> "$EVENTS" ;;
      esac
    }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2
  ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unexpected foreground response must not authorize an active-tab close"
  [ ! -s "$events" ] || fail "unexpected foreground response still closed the pane"
  assert_contains "$out" "could not verify whether a foreground client is viewing the target tab" \
    "unexpected foreground response did not take the fail-closed unknown path"
  pass "herdr presentation focus: unexpected foreground-client reasons fail closed"
}

test_projection_close_allows_stale_active_tab_without_foreground_client() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-focus-stale-active-allow"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","active_tab_id":"w9:t2","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t2","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9"},{"tab_id":"w9:t2","workspace_id":"w9"}]}}' > "$resp/4.out"
  : > "$resp/5.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "cleanup must close a persisted-focused tab when no live client is attached: $out"
  assert_not_contains "$out" "target is the captain's active tab" \
    "detached persisted-focus close still used the live-viewer refusal"
  assert_contains "$(cat "$log")" $'terminal\x1ftitle\x1fclear' \
    "detached persisted-focus close did not probe foreground attachment"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p2' \
    "detached persisted-focus close did not close the exact pane"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' \
    "detached persisted-focus close restored a persisted pointer with no live viewer"
  pass "herdr presentation focus: cleanup closes a persisted-focused tab when no live client is attached"
}

test_projection_close_reports_focus_restore_failure() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-focus-restore-failure"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w9","active_tab_id":"w9:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9"},{"tab_id":"w9:t2","workspace_id":"w9"}]}}' > "$resp/4.out"
  : > "$resp/5.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/6.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true}]}}' > "$resp/7.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/9.out"
  : > "$resp/10.out"
  cp "$resp/7.out" "$resp/11.out"
  cp "$resp/8.out" "$resp/12.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "cleanup did not distinguish post-close focus uncertainty: $status"
  assert_contains "$out" "did not restore the exact prior workspace and tab" \
    "focus restoration failure was not reported"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw9:p2' \
    "focus restoration failure fixture did not reach the close boundary"
  pass "herdr presentation focus: pane close fails when exact focus restoration fails"
}

test_projection_close_rechecks_required_agent_state_at_boundary() {
  local dir log out status
  dir="$TMP_ROOT/projection-close-agent-boundary"; mkdir -p "$dir"
  log="$dir/log"; : > "$log"
  out=$(ROOT="$ROOT" LOG="$log" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() { printf "w1\tw1:t1"; }
    fm_backend_herdr_pane_agent_state() { printf live; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$LOG"
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\"}}}\n" ;;
      esac
    }
    set +e
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2 no-agent
    rc=$?
    set -e
    printf "%s:%s" "$rc" "$FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE"
  ')
  status=${out%%:*}
  [ "$status" -ne 0 ] && [ "$out" = "$status:live" ] \
    || fail "required close-boundary agent state did not refuse live: $out"
  assert_not_contains "$(cat "$log")" "pane close" \
    "required close-boundary agent state still closed a live pane"
  pass "herdr presentation reclaim: live agent state at the close boundary refuses mutation"
}

test_projection_close_rechecks_foreground_client_after_agent_validation() {
  local dir events attached out status
  dir="$TMP_ROOT/projection-close-foreground-boundary"; mkdir -p "$dir"
  events="$dir/events"; attached="$dir/attached"; : > "$events"
  out=$(ROOT="$ROOT" EVENTS="$events" ATTACHED="$attached" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() { printf "w9\tw9:t2"; }
    fm_backend_herdr_pane_agent_state() {
      printf "agent\n" >> "$EVENTS"
      : > "$ATTACHED"
      printf no-agent
    }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\"}}}\n" ;;
        "terminal title")
          printf "foreground\n" >> "$EVENTS"
          if [ -e "$ATTACHED" ]; then
            printf "{\"result\":{\"reason\":\"cleared\"}}\n"
          else
            printf "{\"result\":{\"reason\":\"no_foreground_client\"}}\n"
          fi
          ;;
        "pane close") printf "close\n" >> "$EVENTS" ;;
      esac
    }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2 no-agent
  ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a client attaching during agent validation must defer the active-tab close"
  [ "$(cat "$events")" = $'agent\nforeground' ] \
    || fail "foreground attachment was not checked immediately after agent validation: $(cat "$events")"
  assert_contains "$out" "target is the captain's active tab" \
    "fresh foreground-client refusal did not explain the active-tab boundary"
  pass "herdr presentation focus: active-tab attachment is rechecked after agent validation"
}

test_projection_close_rechecks_target_focus_after_planning() {
  local dir events focused out status
  dir="$TMP_ROOT/projection-close-focus-switch"; mkdir -p "$dir"
  events="$dir/events"; focused="$dir/focused"; : > "$events"
  out=$(ROOT="$ROOT" EVENTS="$events" FOCUSED="$focused" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() {
      if [ -e "$FOCUSED" ]; then
        printf "w9\tw9:t2"
      else
        printf "w1\tw1:t1"
      fi
    }
    fm_backend_herdr_emptying_close_plan() {
      : > "$FOCUSED"
      printf "plain\n"
    }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\",\"workspace_id\":\"w9\"}}}\n" ;;
        "terminal title") printf "{\"result\":{\"reason\":\"cleared\"}}\n" ;;
        "pane close") printf "close\n" >> "$EVENTS" ;;
      esac
    }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2
  ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a target focused during planning must defer the pane close"
  [ ! -s "$events" ] || fail "the focus-switched target was still mutated: $(cat "$events")"
  assert_contains "$out" "target is the captain's active tab" \
    "focus-switch refusal did not explain the active-tab boundary"
  pass "herdr presentation focus: pre-close checkpoint catches a target focused during planning"
}

test_projection_close_preserves_live_focus_that_switched_away_from_target() {
  local dir events sample out status
  dir="$TMP_ROOT/projection-close-focus-switch-away"; mkdir -p "$dir"
  events="$dir/events"; sample="$dir/sample"; : > "$events"; printf '0\n' > "$sample"
  out=$(ROOT="$ROOT" EVENTS="$events" SAMPLE="$sample" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() {
      local n
      n=$(cat "$SAMPLE"); n=$((n + 1)); printf "%s\n" "$n" > "$SAMPLE"
      if [ "$n" -eq 1 ]; then printf "w9\tw9:t2"; else printf "w1\tw1:t1"; fi
    }
    fm_backend_herdr_emptying_close_plan() { printf "plain\n"; }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w9:p2\",\"tab_id\":\"w9:t2\",\"workspace_id\":\"w9\"}}}\n" ;;
        "terminal title") printf "{\"result\":{\"reason\":\"cleared\"}}\n" ;;
      esac
    }
    fm_backend_herdr_explicit_close_pane_confirmed() { printf "close\n" >> "$EVENTS"; }
    fm_backend_herdr_projection_focus_restore() { printf "restore:%s\n" "$2" >> "$EVENTS"; }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w9:p2
  ' 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a client switching from the target to another tab should allow the target close: $out"
  [ "$(cat "$events")" = $'close\nrestore:w1\tw1:t1' ] \
    || fail "close did not preserve the live client's fresh non-target focus: $(cat "$events")"
  pass "herdr presentation focus: close preserves a live client that switches away from the target during planning"
}

# --- emptying-close focus-safe removal (Herdr 0.7.5 #1621 mitigation) ------
#
# The fixtures below model the verified 0.7.5 rules: an explicit close that
# empties a non-focused workspace moves focus to that workspace's neighbor,
# while a pane-death removal preserves focus whenever the dying workspace
# sits behind the focused one (or the focused one is last).

# make_death_lab <dir> <shell-pid>: a fake ps and a fake workspace mover for
# the pane-death close fixtures. The mover appends to $FM_FAKE_MOVER_LOG and
# exits 9 unless $FM_FAKE_MOVER_RESPONSE names a readable response file.
make_death_lab() {  # <dir> <shell-pid>
  local dir=$1 pid=$2
  mkdir -p "$dir"
  cat > "$dir/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  "-axo pid=,ppid=") printf '1 0\n$pid 1\n' ;;
  "-p $pid -o stat=") printf 'Ss+\n' ;;
  "-p $pid -o comm=") printf -- '-zsh\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
calls=$(wc -l < "$FM_FAKE_MOVER_LOG" | tr -d ' ')
if [ "$calls" -ge 2 ] && [ -f "${FM_FAKE_MOVER_RESPONSE_2:-}" ]; then
  cat "$FM_FAKE_MOVER_RESPONSE_2"
  exit 0
fi
if [ -f "$FM_FAKE_MOVER_RESPONSE" ]; then
  cat "$FM_FAKE_MOVER_RESPONSE"
  exit 0
fi
exit 9
SH
  chmod +x "$dir/ps" "$dir/mover"
  : > "$dir/mover.log"
}

death_process_info_fixture() {  # <pane> <pid>
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh"}]}}}\n' "$1" "$2" "$2" "$2"
}

test_projection_close_emptying_after_focus_uses_pane_death_without_move() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-after"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # w1 focused; target w2 sits after it (r > a), so no repositioning is needed.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "emptying close behind focus should succeed through the pane-death path: $out"
  [ ! -s "$dir/mover.log" ] || fail "a close already behind focus invoked the workspace mover"
  assert_contains "$(cat "$log")" $'pane\x1fprocess-info' "pane-death close skipped the idle-shell proof"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "emptying close behind focus used the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "focus moved despite the pane-death removal"
  pass "herdr presentation cleanup: emptying close behind focus ends the exact shell without a move or focus change"
}

test_projection_close_emptying_before_focus_repositions_then_uses_pane_death() {
  local dir log resp fb out status bgpid mover_line
  dir="$TMP_ROOT/close-death-before"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Target w1 sits BEFORE the focused w2, which is not last: reposition first.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  printf '%s\n' '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}' > "$resp/7.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/8.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/9.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w1:p1 "$bgpid" > "$resp/10.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/12.out"
  cp "$resp/12.out" "$resp/13.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/14.out"
  make_death_lab "$dir" "$bgpid"
  printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w2","focused":true},{"workspace_id":"w3","focused":false},{"workspace_id":"w1","focused":false}]}}' > "$dir/mover-response"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/mover-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "repositioned emptying close should succeed through the pane-death path: $out"
  [ "$(cat "$dir/mover.log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w1"$'\t'"3" ] \
    || fail "the repositioning move did not target the exact doomed workspace at the list length: $(cat "$dir/mover.log")"
  mover_line=$(grep -n $'pane\x1fprocess-info' "$log" | head -1 | cut -d: -f1)
  [ -n "$mover_line" ] || fail "repositioned close skipped the idle-shell proof"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "repositioned emptying close used the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "focus moved despite the repositioned pane-death removal"
  pass "herdr presentation cleanup: emptying close before focus moves the doomed workspace to the end and ends its exact shell"
}

test_projection_close_emptying_before_last_focus_needs_no_move() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-focus-last"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Focused w3 is LAST, so the pane-death clamp preserves it without a move.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w1:p1 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":true}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' > "$resp/10.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "emptying close with last focus should succeed through the pane-death path: $out"
  [ ! -s "$dir/mover.log" ] || fail "a last-focused close invoked the workspace mover"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "last-focused emptying close used the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "focus moved despite the pane-death removal"
  pass "herdr presentation cleanup: emptying close with the focused workspace last skips the move"
}

test_projection_close_emptying_last_workspace_needs_no_move() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-target-last"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Target w3 is already last (r > a), so no repositioning is needed.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w3:p1","tab_id":"w3:t1","workspace_id":"w3"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","workspace_id":"w3"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w3:p1","tab_id":"w3:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w3:p1 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w3:p1' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "last-workspace emptying close should succeed through the pane-death path: $out"
  [ ! -s "$dir/mover.log" ] || fail "an already-last close invoked the workspace mover"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "last-workspace emptying close used the focus-unsafe explicit close"
  pass "herdr presentation cleanup: emptying close of the last workspace skips the move"
}

test_projection_close_non_emptying_stays_plain_without_proof_or_move() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-non-emptying"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","workspace_id":"w2"},{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/6.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":false}]}}' > "$resp/7.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/8.out"
  sleep 300 & bgpid=$!
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "non-emptying close should succeed through the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "non-emptying close did not use the plain close"
  assert_not_contains "$(cat "$log")" $'pane\x1fprocess-info' "non-emptying close ran the idle-shell proof"
  [ ! -s "$dir/mover.log" ] || fail "non-emptying close invoked the workspace mover"
  kill -0 "$bgpid" 2>/dev/null || fail "non-emptying close signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a non-emptying close stays plain with no proof, move, or signal"
}

test_projection_close_plain_without_move_requires_structured_removal() {
  local dir log out status
  dir="$TMP_ROOT/close-plain-unconfirmed"; mkdir -p "$dir"
  log="$dir/log"; : > "$log"
  out=$(ROOT="$ROOT" LOG="$log" bash -c '
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_projection_focus_snapshot() { printf "w1\tw1:t1"; }
    fm_backend_herdr_emptying_close_plan() { printf "plain\n"; }
    fm_backend_herdr_projection_focus_restore() { return 0; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$LOG"
      case "$2 $3" in
        "pane get") printf "{\"result\":{\"pane\":{\"pane_id\":\"w2:p2\",\"tab_id\":\"w2:t2\",\"workspace_id\":\"w2\"}}}\n" ;;
      esac
    }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2
  ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a no-move plain close must fail while structured presence remains present: $out"
  assert_contains "$(cat "$log")" "pane close w2:p2" \
    "the no-move unconfirmed regression did not reach the explicit close"
  pass "herdr presentation cleanup: no-move plain close requires structured pane removal"
}

test_projection_close_ambiguous_positions_fall_back_to_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-ambiguous-positions"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  # The position snapshot is ambiguous: the target workspace is absent.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/6.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  sleep 300 & bgpid=$!
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "an ambiguous position snapshot should fall back to the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "ambiguous positions did not use the plain close"
  assert_not_contains "$(cat "$log")" $'pane\x1fprocess-info' "ambiguous positions ran the idle-shell proof"
  [ ! -s "$dir/mover.log" ] || fail "ambiguous positions invoked the workspace mover"
  kill -0 "$bgpid" 2>/dev/null || fail "ambiguous positions signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: an ambiguous workspace layout falls back to the plain close"
}

test_projection_close_move_failure_falls_back_to_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-move-failure"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  printf '%s\n' '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}' > "$resp/7.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/8.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/9.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/12.out"
  cp "$resp/12.out" "$resp/13.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/14.out"
  sleep 300 & bgpid=$!
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a failed repositioning move should fall back to the plain close: $out"
  assert_contains "$out" "could not move the doomed workspace behind the focused one" \
    "a failed repositioning move did not warn about losing the focus-safe path"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw1:p1' "move failure did not use the plain close"
  assert_not_contains "$(cat "$log")" $'pane\x1fprocess-info' "move failure ran the idle-shell proof"
  kill -0 "$bgpid" 2>/dev/null || fail "move failure signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a failed repositioning move falls back to the plain close with a warning"
}

test_projection_close_busy_pane_falls_back_to_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-busy-pane"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  # The pane still has a foreground agent, so the idle-shell proof refuses.
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh"},{"pid":99999,"name":"pi","argv0":"pi"}]}}}\n' "$bgpid" "$bgpid" "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/11.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a busy pane should fall back to the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "a busy pane did not use the plain close"
  kill -0 "$bgpid" 2>/dev/null || fail "a busy pane close signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a pane with a live foreground process falls back to the plain close"
}

test_projection_close_transient_prompt_helper_settles_then_uses_pane_death() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-transient-helper"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  # Sample 1: the shell is transiently redrawing its prompt (real 0.7.5 shape:
  # a helper such as starship rides along as a second foreground process).
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":99998,"name":"starship","argv":["/usr/local/bin/starship","prompt","--continuation"]},{"pid":%s,"name":"zsh","argv0":"zsh"}]}}}\n' "$bgpid" "$bgpid" "$bgpid" > "$resp/7.out"
  # Sample 2: the helper finished; the shell is provably alone and idle.
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/8.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/11.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=3 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "a transient prompt helper should settle into the pane-death path: $out"
  [ "$(grep -c $'pane\x1fprocess-info' "$log")" -ge 2 ] \
    || fail "the settle window did not retry the idle-shell proof"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "a transient prompt helper forced the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "focus moved despite the settled pane-death removal"
  pass "herdr presentation cleanup: a transient prompt helper settles into the pane-death path instead of the plain close"
}

test_projection_close_death_escalates_sigkill_after_sighup_survival() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-escalate"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  bash -c 'trap "" HUP; sleep 300' & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"internal_error","message":"transient failure"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/9.out"
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/10.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/12.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/13.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a SIGHUP-surviving shell should be finished by the SIGKILL escalation: $out"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "the SIGKILL escalation used the focus-unsafe explicit close"
  if kill -0 "$bgpid" 2>/dev/null; then
    kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
    fail "the SIGKILL escalation left the trapped shell alive"
  fi
  wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a SIGHUP-surviving shell is escalated to SIGKILL before giving up"
}

test_projection_close_death_failure_falls_back_to_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-fallback"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  bash -c 'trap "" HUP; sleep 300' & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/9.out"
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/10.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/12.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/14.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/15.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/16.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "an unkillable shell should fall back to the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "a failed pane-death close did not use the plain close fallback"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "herdr presentation cleanup: a failed pane-death close falls back to the plain close"
}

test_projection_close_death_still_restores_a_stolen_focus() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-restore"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  # The backstop still fires when the post-close snapshot disagrees.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":true}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' > "$resp/10.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/13.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/14.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "the pane-death close with a restored backstop should succeed: $out"
  assert_contains "$(cat "$log")" $'tab\x1ffocus\x1fw1:t1' "the backstop did not restore the exact prior tab"
  pass "herdr presentation cleanup: the exact-tab restore remains the backstop behind the pane-death close"
}

test_projection_close_death_never_sigkills_a_reused_pid() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-death-pid-reuse"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  # The original shell survives SIGHUP; by SIGKILL time the pane's process
  # information shows a DIFFERENT shell pid, modeling the original pid having
  # been reused by an unrelated process the pane no longer owns.
  bash -c 'trap "" HUP; sleep 300' & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  cp "$resp/3.out" "$resp/8.out"   # SIGHUP poll 1: pane still present
  cp "$resp/3.out" "$resp/9.out"   # SIGHUP poll 2: pane still present
  death_process_info_fixture w2:p2 99997 > "$resp/10.out"
  : > "$resp/11.out"               # fallback explicit close: pane close ok
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/12.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/13.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/14.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w2:p2' "$ROOT" 2>&1)
  status=$?
  if ! kill -0 "$bgpid" 2>/dev/null; then
    wait "$bgpid" 2>/dev/null || true
    fail "the SIGKILL escalation signaled a pid the exact pane no longer owns"
  fi
  kill -KILL "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "the refused escalation should fall back to the plain close: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "the refused escalation did not fall back to the plain close"
  pass "herdr presentation cleanup: SIGKILL never reaches a pid the exact pane no longer owns"
}

assert_projection_close_failed_removal_rolls_back_the_reposition() {
  local mode=$1 dir log resp fb out status bgpid
  dir="$TMP_ROOT/close-move-rollback-$mode"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Doomed w1 sits BEFORE the focused w2 (not last): the plan repositions it
  # to the end; then every removal path fails, so the exact original order
  # must be restored under the same session lock and the close must fail.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  printf '%s\n' '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}' > "$resp/7.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/8.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/9.out"
  bash -c 'trap "" HUP; sleep 300' & bgpid=$!
  death_process_info_fixture w1:p1 "$bgpid" > "$resp/10.out"
  if [ "$mode" = pane-gone-workspace-present ]; then
    printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/11.out"
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false},{"workspace_id":"w1","active_tab_id":"w1:t2","focused":false}]}}' > "$resp/12.out"
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/13.out"
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/14.out"
  else
    cp "$resp/3.out" "$resp/11.out"  # SIGHUP poll 1: pane still present
    cp "$resp/3.out" "$resp/12.out"  # SIGHUP poll 2: pane still present
    death_process_info_fixture w1:p1 "$bgpid" > "$resp/13.out"  # escalation resample: same owner
    cp "$resp/3.out" "$resp/14.out"  # SIGKILL poll 1: pane still present
    cp "$resp/3.out" "$resp/15.out"  # SIGKILL poll 2: pane still present
  fi
  if [ "$mode" = command-fails ]; then
    printf '9\n' > "$resp/16.exit"
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/17.out"
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/18.out"
  else
    : > "$resp/16.out"
    cp "$resp/3.out" "$resp/17.out"
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t1","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","focused":false}]}}' > "$resp/18.out"
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t1","focused":true}]}}' > "$resp/19.out"
  fi
  make_death_lab "$dir" "$bgpid"
  printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w2","focused":true},{"workspace_id":"w3","focused":false},{"workspace_id":"w1","focused":false}]}}' > "$dir/mover-response"
  printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","focused":false},{"workspace_id":"w2","focused":true},{"workspace_id":"w3","focused":false}]}}' > "$dir/mover-response-2"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/mover-response" \
    FM_FAKE_MOVER_RESPONSE_2="$dir/mover-response-2" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1' "$ROOT" 2>&1)
  status=$?
  kill -KILL "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "an unconfirmed removal must report failure: $out"
  [ "$(wc -l < "$dir/mover.log" | tr -d ' ')" = 2 ] \
    || fail "a failed removal did not roll the reposition back exactly once: $(cat "$dir/mover.log")"
  [ "$(sed -n '1p' "$dir/mover.log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w1"$'\t'"3" ] \
    || fail "the reposition did not move the doomed workspace to the end: $(sed -n '1p' "$dir/mover.log")"
  [ "$(sed -n '2p' "$dir/mover.log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w1"$'\t'"0" ] \
    || fail "the rollback did not restore the doomed workspace to its exact original position: $(sed -n '2p' "$dir/mover.log")"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "a failed rolled-back removal moved focus"
}

test_projection_close_failed_removal_rolls_back_the_reposition() {
  assert_projection_close_failed_removal_rolls_back_the_reposition command-fails
  assert_projection_close_failed_removal_rolls_back_the_reposition command-succeeds-pane-present
  assert_projection_close_failed_removal_rolls_back_the_reposition pane-gone-workspace-present
  pass "herdr presentation cleanup: every unconfirmed removal restores the exact original workspace order and reports failure"
}

test_kill_emptying_non_focused_uses_pane_death() {
  local dir log resp fb out status bgpid lock_log lock_held
  dir="$TMP_ROOT/kill-death"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; lock_log="$dir/lock.log"; lock_held="$dir/lock-held"
  : > "$log"; : > "$lock_log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2"}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/5.out"
  cp "$resp/1.out" "$resp/6.out"
  sleep 300 & bgpid=$!
  death_process_info_fixture w2:p2 "$bgpid" > "$resp/7.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/8.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":true}]}}' > "$resp/9.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/10.out"
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 FM_FAKE_LOCK_LOG="$lock_log" \
    FM_FAKE_LOCK_HELD="$lock_held" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_target_ready() { fm_backend_herdr_parse_target "$1"; }
      fm_backend_herdr_presentation_session_lock_path() { printf "%s" "$FM_FAKE_LOCK_HELD.lock"; }
      fm_lock_try_acquire() {
        printf "acquire\n" >> "$FM_FAKE_LOCK_LOG"
        : > "$FM_FAKE_LOCK_HELD"
      }
      fm_lock_release() {
        [ -e "$FM_FAKE_LOCK_HELD" ] || return 1
        rm -f "$FM_FAKE_LOCK_HELD"
        printf "release\n" >> "$FM_FAKE_LOCK_LOG"
      }
      eval "$(declare -f fm_backend_herdr_cli | sed "1s/fm_backend_herdr_cli/fm_backend_herdr_cli_locked/")"
      fm_backend_herdr_cli() {
        [ -e "$FM_FAKE_LOCK_HELD" ] || return 97
        fm_backend_herdr_cli_locked "$@"
      }
      fm_backend_herdr_kill fmtest:w2:p2
    ' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "an emptying non-focused kill should stay best-effort: $out"
  [ "$(cat "$lock_log")" = "$(printf 'acquire\nrelease')" ] \
    || fail "the generic kill did not hold one presentation lock across its complete mutation: $(cat "$lock_log")"
  [ ! -e "$lock_held" ] || fail "the generic kill retained its presentation lock"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "an emptying non-focused kill used the focus-unsafe explicit close"
  assert_not_contains "$(cat "$log")" $'tab\x1ffocus' "an emptying non-focused kill moved focus"
  pass "fm_backend_herdr_kill: one session lock covers the focus-safe emptying removal"
}

test_kill_focused_workspace_stays_plain_close() {
  local dir log resp fb out status bgpid
  dir="$TMP_ROOT/kill-focused"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t1","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","focused":true}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/3.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/5.out"
  sleep 300 & bgpid=$!
  make_death_lab "$dir" "$bgpid"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_HERDR_PS_BIN="$dir/ps" FM_BACKEND_HERDR_WORKSPACE_MOVER="$dir/mover" \
    FM_FAKE_MOVER_LOG="$dir/mover.log" FM_FAKE_MOVER_RESPONSE="$dir/no-response" \
    FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=2 \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_presentation_session_lock_path() { printf "/tmp/fm-herdr-test-lock"; }
      fm_lock_try_acquire() { return 0; }
      fm_lock_release() { return 0; }
      fm_backend_herdr_kill fmtest:w2:p2
    ' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a focused-workspace kill should stay best-effort: $out"
  assert_contains "$(cat "$log")" $'pane\x1fclose\x1fw2:p2' "a focused-workspace kill did not use the plain close"
  assert_not_contains "$(cat "$log")" $'pane\x1fprocess-info' "a focused-workspace kill ran the idle-shell proof"
  kill -0 "$bgpid" 2>/dev/null || fail "a focused-workspace kill signaled the pane's shell"
  kill "$bgpid" 2>/dev/null || true; wait "$bgpid" 2>/dev/null || true
  pass "fm_backend_herdr_kill: killing the focused workspace's tab keeps the legitimate plain close"
}

test_kill_refuses_when_presentation_lock_is_unavailable() {
  local dir mode out status attempts
  dir="$TMP_ROOT/kill-lock-refusal"; mkdir -p "$dir"
  for mode in unresolved contended; do
    : > "$dir/cli.log"
    : > "$dir/attempts"
    out=$(ROOT="$ROOT" MODE="$mode" CLI_LOG="$dir/cli.log" ATTEMPTS="$dir/attempts" bash -c '
      . "$ROOT/bin/backends/herdr.sh"
      fm_backend_herdr_target_ready() { fm_backend_herdr_parse_target "$1"; }
      fm_backend_herdr_presentation_session_lock_path() {
        [ "$MODE" = contended ] || return 1
        printf "/tmp/fm-herdr-contended-test-lock"
      }
      fm_lock_try_acquire() {
        printf "x\n" >> "$ATTEMPTS"
        return 1
      }
      fm_backend_herdr_cli() {
        printf "%s\n" "$*" >> "$CLI_LOG"
        return 0
      }
      sleep() { :; }
      fm_backend_herdr_kill fmtest:w2:p2
    ' 2>&1)
    status=$?
    [ "$status" -eq 0 ] || fail "$mode presentation lock refusal changed best-effort kill status: $status"
    [ ! -s "$dir/cli.log" ] || fail "$mode presentation lock refusal still mutated Herdr: $(cat "$dir/cli.log")"
    assert_contains "$out" "refusing an unlocked pane close" \
      "$mode presentation lock refusal did not report the deferred close"
    attempts=$(wc -l < "$dir/attempts" | tr -d ' ')
    if [ "$mode" = contended ]; then
      [ "$attempts" = 50 ] || fail "contended presentation lock did not use the bounded wait: $attempts attempts"
    else
      [ "$attempts" = 0 ] || fail "unresolved presentation lock path attempted acquisition: $attempts"
    fi
  done
  pass "fm_backend_herdr_kill: unavailable session locks defer every pane close"
}

test_endpoint_confirmed_gone_gates_on_structured_presence() {
  local out
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_cli() { printf "%s\n" "$FM_FAKE_PRESENCE_RESPONSE"; return "${FM_FAKE_PRESENCE_STATUS:-0}"; }
    check() {  # <label> <response> <status> <mode> <expected-rc>
      FM_FAKE_PRESENCE_RESPONSE=$2 FM_FAKE_PRESENCE_STATUS=$3
      rc=0
      fm_backend_herdr_endpoint_confirmed_gone fmtest:w2:p2 "$4" || rc=$?
      [ "$rc" = "$5" ] || printf "MISMATCH %s: rc=%s expected=%s\n" "$1" "$rc" "$5"
    }
    check present-default "{\"result\":{\"pane\":{\"pane_id\":\"w2:p2\"}}}" 0 "" 1
    check present-strict "{\"result\":{\"pane\":{\"pane_id\":\"w2:p2\"}}}" 0 strict 1
    check notfound-default "{\"error\":{\"code\":\"pane_not_found\"}}" 1 "" 0
    check notfound-strict "{\"error\":{\"code\":\"pane_not_found\"}}" 1 strict 0
    check unknown-default "" 1 "" 1
    check unknown-strict "" 1 strict 1
    check othererror-default "{\"error\":{\"code\":\"internal\"}}" 1 "" 1
    check othererror-strict "{\"error\":{\"code\":\"internal\"}}" 1 strict 1
    # Missing or malformed endpoint identity is ambiguity, never proof of a
    # gone pane: it must refuse record removal.
    rc=0
    fm_backend_herdr_endpoint_confirmed_gone malformed-target strict || rc=$?
    [ "$rc" = 1 ] || printf "MISMATCH malformed-target: rc=%s expected=1\n" "$rc"
    rc=0
    fm_backend_herdr_endpoint_confirmed_gone "" || rc=$?
    [ "$rc" = 1 ] || printf "MISMATCH empty-target: rc=%s expected=1\n" "$rc"
  ' "$ROOT" 2>&1)
  [ -z "$out" ] || fail "endpoint confirmed-gone gate matrix mismatch: $out"
  pass "endpoint confirmed-gone: only structured not-found permits record removal and ambiguous identity refuses"
}

test_projection_seeded_prune_refuses_active_tab() {
  local dir log resp fb out status
  dir="$TMP_ROOT/projection-seeded-focus-active-refusal"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9","focused":true},{"tab_id":"w9:t2","label":"fm-task","workspace_id":"w9","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w9:p1","tab_id":"w9:t1"},{"pane_id":"w9:p2","tab_id":"w9:t2"}]}}' > "$resp/2.out"
  printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","active_tab_id":"w9:t1","focused":true}]}}' > "$resp/4.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","focused":true},{"tab_id":"w9:t2","focused":false}]}}' > "$resp/5.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9"}}}' > "$resp/6.out"
  cp "$resp/1.out" "$resp/7.out"
  cp "$resp/4.out" "$resp/8.out"
  cp "$resp/5.out" "$resp/9.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_FAKE_HERDR_FOREGROUND_REASON=cleared \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_prune_seeded_default_tab fmtest w9 w9:t1 focus-preserving' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "projected seeded pruning must refuse the active tab"
  assert_contains "$out" "target is the captain's active tab" \
    "projected seeded prune did not explain its active-tab refusal"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' \
    "projected seeded prune closed the captain's active tab"
  pass "herdr presentation focus: projected seeded pruning refuses the active tab"
}

test_projection_label_builder_uses_corner_and_strips_owner_prefixes() {
  local primary secondmate token
  token='AbCdEfGhIjKlMnOpQrStUv'
  [ "${#token}" -eq 22 ] || fail "fixture token must be 22 characters"
  primary=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label task-p2 '"$token" "$ROOT")
  [ "$primary" = "└ task-p2 · p:$token" ] \
    || fail "primary child label was wrong: $primary"
  secondmate=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label secondmate-child-demo '"$token" "$ROOT")
  [ "$secondmate" = "└ secondmate-child-demo · p:$token" ] \
    || fail "secondmate child label was wrong: $secondmate"
  primary=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label firstmate/task-p2 '"$token" "$ROOT")
  [ "$primary" = "└ task-p2 · p:$token" ] \
    || fail "firstmate/ owner prefix was not stripped: $primary"
  secondmate=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label 2ndmate-fmdev-f2/child '"$token" "$ROOT")
  [ "$secondmate" = "└ child · p:$token" ] \
    || fail "2ndmate owner prefix was not stripped: $secondmate"
  primary=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_workspace_label fm-task-p2 '"$token" "$ROOT")
  [ "$primary" = "└ task-p2 · p:$token" ] \
    || fail "presentation fm- owner prefix was not stripped: $primary"
  case "$primary" in $'└ '*) ;; *) fail "label must start with U+2514 and one space" ;; esac
  pass "herdr presentation labels: └ concise-task · p:<full-token> for primary and secondmate children"
}

test_projection_order_moves_only_exact_new_workspace_and_preserves_relative_order() {
  local dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":false},{"workspace_id":"w2","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w3","label":"2ndmate-alpha","focused":false},{"workspace_id":"w4","label":"2ndmate-bravo","focused":true},{"workspace_id":"w5","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","label":"firstmate","focused":false},{"workspace_id":"w2","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w5","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false},{"workspace_id":"w3","label":"2ndmate-alpha","focused":false},{"workspace_id":"w4","label":"2ndmate-bravo","focused":true}]}}'
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w4\tw4:t2"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w5 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "best-effort projection ordering must not fail the spawn"
  [ -z "$out" ] || fail "successful projection ordering emitted a warning: $out"
  [ "$(cat "$mover_log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w5"$'\t'"2" ] \
    || fail "projection ordering did not move only the exact new response id to the owning-parent append index"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' "projection ordering called workspace close"
  assert_not_contains "$(cat "$log")" $'session\x1fdelete' "projection ordering called session delete"
  assert_not_contains "$(cat "$log")" $'workspace\x1frename' "projection ordering called a label-based workspace mutation"
  pass "herdr presentation ordering: exact new workspace appends to the primary block while focus and relative orders stay stable"
}

# run_group_order_case <name> <group-key> <children-json-array>: one projected
# create under parent w1 with the given existing children, then the new w9
# last; the mover answers with w9 at the requested index. Prints the mover's
# requested index, or nothing when no move was attempted.
run_group_order_case() {
  local name=$1 key=$2 children=$3 dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order-group-$name"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  jq -cn --argjson children "$children" '
    {result: {workspaces: ([{workspace_id: "w1", label: "firstmate"}] + $children
      + [{workspace_id: "w9", label: "└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"}])}}' > "$dir/base.json"
  cp "$dir/base.json" "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.9.3","protocol":22},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$FM_FAKE_MOVER_LOG"
jq -c --argjson at "$3" '
  .result.workspaces as $w
  | ([$w[] | select(.workspace_id != "w9")]) as $rest
  | {id: "fm-workspace-move", result: {type: "workspace_list",
      workspaces: ($rest[0:$at] + [$w[-1]] + $rest[$at:])}}' "$FM_FAKE_BASE"
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" FM_FAKE_BASE="$dir/base.json" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w1\tw1:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w9 firstmate w1 "$1"' "$ROOT" "$key" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "group ordering $name must not fail the spawn: $out"
  [ -z "$out" ] || fail "group ordering $name emitted a warning: $out"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' "group ordering $name called workspace close"
  assert_not_contains "$(cat "$log")" $'workspace\x1frename' "group ordering $name renamed a workspace"
  cat "$mover_log"
}

test_projection_order_group_key_places_new_task_inside_its_group() {
  local tagged at
  tagged='[{"workspace_id":"w2","label":"└ a · p:AbCdEfGhIjKlMnOpQrStU1","tokens":{"fm_group_order":"001.Web"}},
           {"workspace_id":"w3","label":"└ b · p:AbCdEfGhIjKlMnOpQrStU2","tokens":{"fm_group_order":"001.Web"}},
           {"workspace_id":"w4","label":"└ c · p:AbCdEfGhIjKlMnOpQrStU3","tokens":{"fm_group_order":"003.Other"}},
           {"workspace_id":"wH","label":"captain-notes"}]'
  at=$(run_group_order_case middle 002.Backend "$tagged")
  [ "$at" = 3 ] || fail "a new group-2 task must land after the group-1 children and before group 3, got index: $at"
  at=$(run_group_order_case same-group 001.Web "$tagged")
  [ "$at" = 3 ] || fail "a new task must land at the end of its own group, got index: $at"
  at=$(run_group_order_case first 000.Alpha "$tagged")
  [ "$at" = 1 ] || fail "a new task sorting first must land at the block start, got index: $at"
  at=$(run_group_order_case last 999.Zed "$tagged")
  [ "$at" = 4 ] || fail "a new task sorting last must land at the block end, before a foreign workspace, got index: $at"
  at=$(run_group_order_case untagged 001.Web '[{"workspace_id":"w2","label":"└ a · p:AbCdEfGhIjKlMnOpQrStU1","tokens":{"fm_group_order":"003.Other"}},
           {"workspace_id":"w3","label":"└ b · p:AbCdEfGhIjKlMnOpQrStU2"},
           {"workspace_id":"w4","label":"└ c · p:AbCdEfGhIjKlMnOpQrStU3","tokens":{"fm_group_order":"003.Other"}}]')
  [ "$at" = 3 ] || fail "an untagged child must never end up behind a new task, got index: $at"
  at=$(run_group_order_case no-key '' "$tagged")
  [ "$at" = 4 ] || fail "without a group key the block-end placement must be unchanged, got index: $at"
  pass "herdr presentation ordering: a group key places only the new workspace inside its group, untagged children stay ahead"
}

test_projection_order_secondmate_parent_block() {
  local dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order-secondmate"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  # firstmate, primary child, 2ndmate-A, A-child legacy, 2ndmate-B, human, NEW for A
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"└ primary · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w3","label":"2ndmate-alpha"},{"workspace_id":"w4","label":"2ndmate-alpha/old · p:AbCdEfGhIjKlMnOpQrStU1"},{"workspace_id":"w5","label":"2ndmate-bravo"},{"workspace_id":"wH","label":"human-notes"},{"workspace_id":"w6","label":"└ new-a · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"└ primary · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w3","label":"2ndmate-alpha"},{"workspace_id":"w4","label":"2ndmate-alpha/old · p:AbCdEfGhIjKlMnOpQrStU1"},{"workspace_id":"w6","label":"└ new-a · p:ZyXwVuTsRqPoNmLkJiHgFe"},{"workspace_id":"w5","label":"2ndmate-bravo"},{"workspace_id":"wH","label":"human-notes"}]}}'
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w5\tw5:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w6 2ndmate-alpha' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "secondmate parent ordering must not fail the spawn: $out"
  [ -z "$out" ] || fail "successful secondmate ordering emitted a warning: $out"
  [ "$(cat "$mover_log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w6"$'\t'"4" ] \
    || fail "secondmate child was not inserted after its parent block: $(cat "$mover_log")"
  assert_not_contains "$(cat "$log")" $'workspace\x1frename' "secondmate ordering renamed a legacy child"
  pass "herdr presentation ordering: secondmate children append under their owning parent block"
}

test_projection_order_foreign_legacy_child_is_read_only() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-foreign-legacy"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-alpha"},{"workspace_id":"w3","label":"2ndmate-bravo/foreign · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w4","label":"└ new-alpha · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w4 2ndmate-alpha' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "foreign legacy ordering must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "foreign legacy child did not warn"
  [ ! -e "$dir/called" ] || fail "foreign legacy child attempted workspace.move"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' "foreign legacy layout triggered workspace cleanup"
  assert_not_contains "$(cat "$log")" $'session\x1fdelete' "foreign legacy layout triggered session cleanup"
  assert_not_contains "$(cat "$log")" $'workspace\x1frename' "foreign legacy layout triggered workspace rename"
  pass "herdr presentation ordering: a foreign legacy child is warning-only and read-only"
}

test_projection_order_allows_intervening_parent_child_block() {
  local dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order-intervening-parent"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w3","label":"2ndmate-alpha"},{"workspace_id":"w4","label":"2ndmate-bravo"},{"workspace_id":"w5","label":"└ bravo-child · p:QqWwEeRrTtYyUuIiOoPpAa"},{"workspace_id":"w6","label":"└ new-first · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv"},{"workspace_id":"w6","label":"└ new-first · p:ZyXwVuTsRqPoNmLkJiHgFe"},{"workspace_id":"w3","label":"2ndmate-alpha"},{"workspace_id":"w4","label":"2ndmate-bravo"},{"workspace_id":"w5","label":"└ bravo-child · p:QqWwEeRrTtYyUuIiOoPpAa"}]}}'
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w4\tw4:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w6 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "intervening parent ordering must not fail the spawn: $out"
  [ -z "$out" ] || fail "legitimate intervening parent ordering emitted a warning: $out"
  [ "$(cat "$mover_log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w6"$'\t'"2" ] \
    || fail "intervening parent block prevented the owning-parent insertion: $(cat "$mover_log")"
  pass "herdr presentation ordering: intervening parent child blocks remain traversable"
}

test_projection_order_human_spaces_never_move_targets() {
  local dir log resp fb mover mover_log out status
  dir="$TMP_ROOT/projection-order-human"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; mover_log="$dir/mover.log"
  : > "$log"; : > "$mover_log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH1","label":"notes"},{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"wH2","label":"scratch"},{"workspace_id":"w2","label":"2ndmate-alpha"},{"workspace_id":"w3","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FM_FAKE_MOVER_LOG"
printf '%s\n' '{"id":"fm-workspace-move","result":{"type":"workspace_list","workspaces":[{"workspace_id":"wH1","label":"notes"},{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w3","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"},{"workspace_id":"wH2","label":"scratch"},{"workspace_id":"w2","label":"2ndmate-alpha"}]}}'
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_LOG="$mover_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w2\tw2:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w3 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "human-interleaved ordering must not fail: $out"
  [ "$(cat "$mover_log")" = "$(cd /tmp && pwd -P)/fmtest.sock"$'\t'"w3"$'\t'"2" ] \
    || fail "human spaces changed the move target or insert index: $(cat "$mover_log")"
  pass "herdr presentation ordering: only the exact new id moves; human spaces keep relative order"
}

test_projection_order_failure_warns_without_cleanup_or_spawn_failure() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-failure"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true},{"workspace_id":"w2","label":"2ndmate-alpha","focused":false},{"workspace_id":"w3","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016 # $defs is a literal JSON Schema key.
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
exit 9
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_focus_snapshot() { printf "w1\tw1:t1"; }; fm_backend_herdr_projection_focus_restore() { return 0; }; fm_backend_herdr_projection_order_best_effort fmtest w3 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a workspace.move failure must not fail the projected spawn"
  assert_contains "$out" "workspace move failed or had an ambiguous response" \
    "workspace.move failure did not report the best-effort warning"
  assert_not_contains "$(cat "$log")" $'workspace\x1fclose' "workspace.move failure triggered workspace cleanup"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "workspace.move failure triggered pane cleanup"
  assert_not_contains "$(cat "$log")" $'session\x1fdelete' "workspace.move failure triggered session cleanup"
  pass "herdr presentation ordering: move failure warns, returns success, and grants no cleanup authority"
}

test_projection_order_ambiguous_existing_block_is_read_only() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-ambiguous"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  # Detached legacy child after the next parent breaks the contiguous block.
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true},{"workspace_id":"w2","label":"2ndmate-alpha","focused":false},{"workspace_id":"w3","label":"firstmate/old · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w4","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}' > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w4 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "ambiguous projection ordering must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "ambiguous projection layout did not warn"
  [ ! -e "$dir/called" ] || fail "ambiguous projection layout attempted workspace.move"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" = 1 ] \
    || fail "ambiguous projection ordering did more than one read-only workspace list"
  pass "herdr presentation ordering: an ambiguous existing worker block is warning-only and read-only"
}

test_projection_order_anchors_the_parent_by_exact_id() {
  local dir log resp fb mover layout out status
  layout='{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":false},{"workspace_id":"w7","label":"firstmate","focused":false},{"workspace_id":"wH","label":"human-notes","focused":false},{"workspace_id":"w8","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}'

  # Without the exact parent id, two same-labeled parents make the whole layout
  # ambiguous and ordering steps aside.
  dir="$TMP_ROOT/projection-order-dup-label"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' "$layout" > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w8 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "ambiguous projection ordering must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "a duplicated parent label should make label-anchored ordering step aside"
  [ ! -e "$dir/called" ] || fail "ambiguous parent label attempted workspace.move"

  # With the launcher's exact parent workspace id, the same layout is no longer
  # ambiguous: ordering gets past parent selection and stops later, on this
  # fake's protocol, having still moved nothing.
  dir="$TMP_ROOT/projection-order-exact-parent"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' "$layout" > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w8 firstmate w7' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "exact-parent projection ordering must not fail the spawn"
  assert_not_contains "$out" "ambiguous workspace layout" "the exact parent id should have resolved the duplicated label"
  assert_contains "$out" "protocol" "exact-parent ordering did not reach its protocol gate"
  [ ! -e "$dir/called" ] || fail "exact-parent ordering attempted workspace.move below the required protocol"
  pass "herdr presentation ordering: the launcher's exact parent workspace id disambiguates a duplicated home label without moving anything"
}

test_projection_order_foreign_new_child_before_parent_is_read_only() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-foreign-new"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true},{"workspace_id":"wH","label":"human-notes","focused":false},{"workspace_id":"w2","label":"└ foreign · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w3","label":"2ndmate-alpha","focused":false},{"workspace_id":"w4","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe","focused":false}]}}' > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w4 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "foreign new-child ordering must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "foreign new child before its parent did not warn"
  [ ! -e "$dir/called" ] || fail "foreign new child before its parent attempted workspace.move"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" = 1 ] \
    || fail "foreign new-child ordering did more than one read-only workspace list"
  pass "herdr presentation ordering: a foreign new-format child is warning-only and read-only"
}

test_projection_order_missing_parent_is_read_only() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-missing-parent"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w2 2ndmate-missing' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "missing parent must not fail the spawn"
  assert_contains "$out" "ambiguous workspace layout" "missing parent did not warn"
  [ ! -e "$dir/called" ] || fail "missing parent attempted workspace.move"
  pass "herdr presentation ordering: missing owning parent is warning-only and read-only"
}

test_presentation_session_lock_path_is_shared_across_homes() {
  local dir log resp fb path_a path_b path_other path_tmp path_private
  dir="$TMP_ROOT/presentation-session-lock"; mkdir -p "$dir/responses" "$dir/sockdir"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  : > "$dir/sockdir/fmtest.sock"
  printf '%s\n' "{\"sessions\":[{\"name\":\"fmtest\",\"running\":true,\"socket_path\":\"$dir/sockdir/fmtest.sock\"}]}" > "$resp/1.out"
  printf '%s\n' "{\"sessions\":[{\"name\":\"fmtest\",\"running\":true,\"socket_path\":\"$dir/sockdir/fmtest.sock\"}]}" > "$resp/2.out"
  printf '%s\n' "{\"sessions\":[{\"name\":\"other\",\"running\":true,\"socket_path\":\"$dir/sockdir/other.sock\"}]}" > "$resp/3.out"
  : > "$dir/sockdir/other.sock"
  fb=$(make_herdr_fakebin "$dir")
  path_a=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT") \
    || fail "session lock path resolution failed for home A"
  path_b=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT") \
    || fail "session lock path resolution failed for home B"
  [ "$path_a" = "$path_b" ] || fail "same session/socket must resolve one shared lock path"
  case "$path_a" in
    "/tmp/firstmate-herdr-presentation-$(id -u)"/order-*.lock) ;;
    *) fail "session lock path must use this account's namespace: $path_a" ;;
  esac
  case "$path_a" in
    */state/*) fail "session lock path must not live under a home state directory: $path_a" ;;
  esac
  path_other=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path other' "$ROOT") \
    || fail "session lock path resolution failed for a different session"
  [ "$path_other" != "$path_a" ] || fail "different sessions must not share one lock path"
  # Symlink parents such as /tmp -> /private/tmp must not split the lock identity.
  if [ -L /tmp ] || [ "$(cd /tmp && pwd -P)" != /tmp ]; then
    : > /tmp/fm-herdr-lock-canon-$$.sock
    printf '%s\n' '{"sessions":[{"name":"canon","running":true,"socket_path":"/tmp/fm-herdr-lock-canon-'"$$"'.sock"}]}' > "$resp/4.out"
    printf '%s\n' "{\"sessions\":[{\"name\":\"canon\",\"running\":true,\"socket_path\":\"$(cd /tmp && pwd -P)/fm-herdr-lock-canon-$$.sock\"}]}" > "$resp/5.out"
    path_tmp=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path canon' "$ROOT") \
      || fail "lock path with /tmp socket failed"
    path_private=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path canon' "$ROOT") \
      || fail "lock path with canonical socket failed"
    rm -f /tmp/fm-herdr-lock-canon-$$.sock
    [ "$path_tmp" = "$path_private" ] \
      || fail "symlink parent socket paths must resolve one lock: $path_tmp vs $path_private"
  fi
  pass "herdr presentation lock: one path per session/socket across homes"
}

test_presentation_session_lock_path_rejects_malformed_socket() {
  local dir log resp fb path status
  dir="$TMP_ROOT/presentation-malformed-socket"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":null}]}' > "$resp/1.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true}]}' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  path=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "null socket_path must refuse the presentation lock path"
  [ -z "$path" ] || fail "null socket_path returned a lock path: $path"
  case "$path" in *null*) fail "null socket_path leaked into a lock path: $path" ;; esac
  path=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path fmtest' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "missing socket_path must refuse the presentation lock path"
  [ -z "$path" ] || fail "missing socket_path returned a lock path: $path"
  pass "herdr presentation lock: null and missing socket paths fail closed"
}

test_projection_order_rejects_malformed_socket() {
  local dir log resp fb mover out status
  dir="$TMP_ROOT/projection-order-malformed-socket"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; mover="$dir/mover"; : > "$log"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"wH","label":"2ndmate-alpha"},{"workspace_id":"w2","label":"└ new · p:ZyXwVuTsRqPoNmLkJiHgFe"}]}}' > "$resp/1.out"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}' > "$resp/2.out"
  # shellcheck disable=SC2016
  printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"workspace.move"}}}],"$defs":{"WorkspaceMoveParams":{"required":["workspace_id","insert_index"],"properties":{"insert_index":{"type":"integer"}}}}}}}' > "$resp/3.out"
  printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":null}]}' > "$resp/4.out"
  cat > "$mover" <<'SH'
#!/usr/bin/env bash
echo called > "$FM_FAKE_MOVER_CALLED"
exit 0
SH
  chmod +x "$mover"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    FM_BACKEND_HERDR_WORKSPACE_MOVER="$mover" FM_FAKE_MOVER_CALLED="$dir/called" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_order_best_effort fmtest w2 firstmate' "$ROOT" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "malformed ordering socket must not fail the spawn"
  assert_contains "$out" "ambiguous named session socket" "malformed ordering socket did not warn"
  [ ! -e "$dir/called" ] || fail "malformed ordering socket attempted workspace.move"
  pass "herdr presentation ordering: malformed socket metadata is warning-only and read-only"
}

test_projection_reclaim_refusal_matrix_is_non_mutating() {
  local dir state home other_home home_real journal legacy token label out mutation_log
  dir="$TMP_ROOT/projection-reclaim-refusals"; state="$dir/state"; home="$dir/home"; other_home="$dir/other-home"
  mkdir -p "$state" "$home" "$other_home"
  home_real=$(cd "$home" && pwd -P)
  token=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" refusal-r1) || exit 1
    label=$(fm_backend_herdr_projection_workspace_label refusal-r1 "$token")
    fm_backend_herdr_projection_journal_bind \
      "$1/refusal-r1.herdr-presentation" refusal-r1 "$2" fmtest \
      w2 w2:t2 w2:p2 w1 firstmate "$label" fm-refusal-r1 || exit 1
    printf "%s" "$token"
  ' "$ROOT" "$state" "$home_real") || fail "could not create reclaim refusal fixture"
  journal="$state/refusal-r1.herdr-presentation"
  label="└ refusal-r1 · p:$token"
  mkdir -p "$state/legacy"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_create "$1" refusal-r1 >/dev/null' \
    "$ROOT" "$state/legacy" || fail "could not create legacy reclaim fixture"
  legacy="$state/legacy/refusal-r1.herdr-presentation"
  mutation_log="$dir/mutations.log"; : > "$mutation_log"
  out=$(ROOT="$ROOT" JOURNAL="$journal" LEGACY="$legacy" HOME_A="$home" HOME_B="$other_home" MUTATIONS="$mutation_log" \
    bash -c '
      . "$ROOT/bin/backends/herdr.sh"
      fm_backend_herdr_cli() { printf "%s\n" "$*" >> "$MUTATIONS"; return 1; }
      run_case() {
        mode=$1; journal=$2; home=$3
        fm_backend_herdr_projection_live_binding_matches() {
          [ "$mode" != ambiguous ]
        }
        fm_backend_herdr_pane_agent_state() {
          case "$mode" in
            live) printf live ;;
            unknown) printf unknown ;;
            *) printf no-agent ;;
          esac
        }
        fm_backend_herdr_projection_focus_snapshot() {
          [ "$mode" != focus-unknown ] || return 1
          printf "w1\tw1:t1"
        }
        set +e
        fm_backend_herdr_projection_reclaim_task \
          fmtest "$journal" refusal-r1 "$home" w2 w2:t2 w2:p2 firstmate fm-refusal-r1 /tmp/project \
          >/dev/null 2>&1
        rc=$?
        set -e
        printf "%s:%s\n" "$mode" "$rc"
      }
      run_case legacy "$LEGACY" "$HOME_A"
      run_case cross-home "$JOURNAL" "$HOME_B"
      run_case ambiguous "$JOURNAL" "$HOME_A"
      run_case live "$JOURNAL" "$HOME_A"
      run_case unknown "$JOURNAL" "$HOME_A"
      run_case focus-unknown "$JOURNAL" "$HOME_A"
    ')
  [ "$out" = $'legacy:2\ncross-home:2\nambiguous:2\nlive:1\nunknown:1\nfocus-unknown:2' ] \
    || fail "reclaim refusal matrix returned wrong decisions: $out"
  [ ! -s "$mutation_log" ] \
    || fail "legacy, cross-home, ambiguous, live/unknown, or focus-unknown refusal mutated Herdr: $(cat "$mutation_log")"
  [ "$(sed -n 's/^workspace_label=//p' "$journal")" = "$label" ] \
    || fail "reclaim refusal matrix rewrote the bound workspace label"
  pass "herdr presentation reclaim: legacy, cross-home, ambiguous, live/unknown, and focus-unknown cases refuse without mutation"
}

test_projection_reclaim_replaces_only_exact_husk_and_advances_binding() {
  local dir state home home_real log resp fb journal token label out calls create_line close_line agent_line boundary_mutations
  dir="$TMP_ROOT/projection-reclaim-exact"; state="$dir/state"; home="$dir/home"
  mkdir -p "$dir/responses" "$state" "$home"
  home_real=$(cd "$home" && pwd -P)
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  token=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" fm-hibit-r1) || exit 1
    label=$(fm_backend_herdr_projection_workspace_label fm-hibit-r1 "$token")
    fm_backend_herdr_projection_journal_bind \
      "$1/fm-hibit-r1.herdr-presentation" fm-hibit-r1 "$2" fmtest \
      w2 w2:t2 w2:p2 w1 firstmate "$label" fm-fm-hibit-r1 || exit 1
    printf "%s" "$token"
  ' "$ROOT" "$state" "$home_real") || fail "could not create exact reclaim journal fixture"
  journal="$state/fm-hibit-r1.herdr-presentation"
  label="└ hibit-r1 · p:$token"
  printf '%s\n' "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w0\",\"label\":\"firstmate\",\"focused\":false,\"active_tab_id\":\"w0:t1\"},{\"workspace_id\":\"w1\",\"label\":\"firstmate\",\"focused\":true,\"active_tab_id\":\"w1:t1\"},{\"workspace_id\":\"w2\",\"label\":\"$label\",\"focused\":false,\"active_tab_id\":\"w2:t2\"}]}}" > "$resp/1.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","label":"fm-fm-hibit-r1"}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/4.out"
  printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$resp/5.out"
  printf '%s\n' "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"firstmate\",\"focused\":true,\"active_tab_id\":\"w1:t1\"},{\"workspace_id\":\"w2\",\"label\":\"$label\",\"focused\":false,\"active_tab_id\":\"w2:t2\"}]}}" > "$resp/6.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","focused":true}]}}' > "$resp/7.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t3"},"root_pane":{"pane_id":"w2:p3"}}}' > "$resp/8.out"
  cp "$resp/6.out" "$resp/9.out"
  cp "$resp/7.out" "$resp/10.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t3","workspace_id":"w2"}}}' > "$resp/11.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p3","tab_id":"w2:t3","workspace_id":"w2"}}}' > "$resp/12.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/13.out"
  printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$resp/14.out"
  cp "$resp/6.out" "$resp/15.out"
  cp "$resp/7.out" "$resp/16.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/17.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2"}}}' > "$resp/18.out"
  printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$resp/19.out"
  # The emptying-close plan sees the replacement tab alongside the old husk
  # tab, so the husk close stays plain.
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","label":"fm-fm-hibit-r1"},{"tab_id":"w2:t3","label":"fm-fm-hibit-r1"}]}}' > "$resp/20.out"
  : > "$resp/21.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/22.out"
  cp "$resp/6.out" "$resp/23.out"
  cp "$resp/7.out" "$resp/24.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/25.out"
  # The replaced old husk tab survives its pane close because a residual
  # companion pane (the docked herdr:sidebar slot) is still attached to it.
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","label":"fm-fm-hibit-r1"},{"tab_id":"w2:t3","label":"fm-fm-hibit-r1"}]}}' > "$resp/26.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:pD","tab_id":"w2:t2","label":"herdr:sidebar"},{"pane_id":"w2:p3","tab_id":"w2:t3"}]}}' > "$resp/27.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:pD","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/28.out"
  printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$resp/29.out"
  # The close of the swept companion pane takes its own focus snapshot pair
  # (30, 31), verifies the exact pane (32), plans a plain close (33), closes
  # silently (34), confirms the pane gone (35), and restores focus (36, 37);
  # the title-clear probe is answered inline by the fake and consumes no
  # response file.
  cp "$resp/6.out" "$resp/30.out"
  cp "$resp/7.out" "$resp/31.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w2:pD","tab_id":"w2:t2","workspace_id":"w2"}}}' > "$resp/32.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","label":"fm-fm-hibit-r1"},{"tab_id":"w2:t3","label":"fm-fm-hibit-r1"}]}}' > "$resp/33.out"
  : > "$resp/34.out"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/35.out"
  cp "$resp/6.out" "$resp/36.out"
  cp "$resp/7.out" "$resp/37.out"
  cp "$resp/1.out" "$resp/38.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t3","label":"fm-fm-hibit-r1"}]}}' > "$resp/39.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p3","tab_id":"w2:t3"}]}}' > "$resp/40.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_projection_reclaim_task \
        fmtest "$1" fm-hibit-r1 "$2" w2 w2:t2 w2:p2 firstmate fm-fm-hibit-r1 /tmp/project || exit 1
      printf "%s %s" "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" "$FM_BACKEND_HERDR_PROJECTION_PANE_ID"
    ' "$ROOT" "$journal" "$home") || fail "exact agent-free projection reclaim failed"
  [ "$out" = "w2:t3 w2:p3" ] || fail "reclaim did not return exact replacement ids: $out"
  [ "$(sed -n 's/^tab_id=//p' "$journal")" = w2:t3 ] \
    && [ "$(sed -n 's/^pane_id=//p' "$journal")" = w2:p3 ] \
    || fail "reclaim did not advance the journal to the replacement endpoint"
  calls=$(cat "$log")
  create_line=$(grep -n $'tab\x1fcreate\x1f--workspace\x1fw2' "$log" | cut -d: -f1)
  close_line=$(grep -n $'pane\x1fclose\x1fw2:p2' "$log" | cut -d: -f1)
  [ -n "$create_line" ] && [ -n "$close_line" ] && [ "$create_line" -lt "$close_line" ] \
    || fail "reclaim did not create the exact replacement before closing the old husk"
  sweep_line=$(grep -n $'pane\x1fclose\x1fw2:pD' "$log" | cut -d: -f1)
  [ -n "$sweep_line" ] && [ "$sweep_line" -gt "$close_line" ] \
    || fail "reclaim did not sweep the replaced tab's residual companion pane after the husk close"
  agent_line=$(grep -n $'agent\x1fget\x1fw2:p2' "$log" | tail -1 | cut -d: -f1)
  [ -n "$agent_line" ] && [ "$agent_line" -lt "$close_line" ] \
    || fail "reclaim did not recheck the old pane agent state before the close"
  boundary_mutations=$(sed -n "$((agent_line + 1)),$((close_line - 1))p" "$log" \
    | grep -Ev $'\x1f(tab\x1flist|pane\x1flist|workspace\x1flist|terminal\x1ftitle\x1fclear)' || true)
  [ -z "$boundary_mutations" ] \
    || fail "reclaim mutated between the old pane agent recheck and the close: $boundary_mutations"
  assert_not_contains "$calls" $'workspace\x1fclose' "reclaim introduced workspace-close authority"
  assert_not_contains "$calls" $'workspace\x1frename' "reclaim renamed the projected workspace"
  assert_not_contains "$calls" $'tab\x1ffocus' "focus-preserving reclaim changed an already-stable focus snapshot"
  assert_not_contains "$calls" $'\x1fw0' "reclaim touched the same-labeled sibling parent"
  pass "herdr presentation reclaim: exact agent-free husk survives duplicate parent labels while its sibling stays untouched"
}

test_projection_recovery_is_read_only_and_refuses_live_duplicate_risk() {
  local dir state log resp fb token journal out status calls
  dir="$TMP_ROOT/projection-recovery"; state="$dir/state"; mkdir -p "$dir/responses" "$state"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  token=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_create "$1" task-p3' "$ROOT" "$state")
  journal="$state/task-p3.herdr-presentation"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate/task-p3 · p:%s"},{"workspace_id":"w2","label":"copy/task-p3 · p:%s"}]}}\n' "$token" "$token" > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$resp/4.out"
  printf '{"result":{"panes":[{"pane_id":"w2:p1","tab_id":"w2:t1"}]}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"w2:p1"}}}\n' > "$resp/6.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_recovery_allows_flat fmtest "$1" task-p3' "$ROOT" "$journal" \
    >/dev/null || fail "agent-free duplicate token matches should allow flat fallback"
  calls=$(cat "$log")
  assert_not_contains "$calls" $'workspace\x1fcreate' "recovery inspection created a workspace"
  assert_not_contains "$calls" $'workspace\x1fclose' "recovery inspection closed a workspace"
  assert_not_contains "$calls" $'tab\x1fcreate' "recovery inspection created a tab"
  assert_not_contains "$calls" $'tab\x1fclose' "recovery inspection closed a tab"
  assert_not_contains "$calls" $'pane\x1fclose' "recovery inspection closed a pane"

  : > "$log"; rm -f "$resp"/*.out "$resp"/*.exit "$resp/.count"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate/task-p3 · p:%s"}]}}\n' "$token" > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  # 5: process-info -> a live harness backs the registration (issue #4115)
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":4242,"foreground_process_group_id":4243,"foreground_processes":[{"pid":4243,"name":"node","argv0":"pi"}]}}}\n' > "$resp/5.out"
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_recovery_allows_flat fmtest "$1" task-p3' "$ROOT" "$journal" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a token match with a live registered agent must refuse duplicate launch"
  assert_contains "$out" "has a live pane" "live duplicate refusal did not explain the risk"
  assert_not_contains "$(cat "$log")" $'pane\x1fclose' "live duplicate refusal closed a pane"
  pass "herdr presentation recovery: duplicate-token inspection is read-only and live-agent risk refuses fallback"
}

# --- workspace_find: scoped to THIS home's own label, not just any match ----

test_workspace_find_matches_only_this_homes_own_label() {
  local dir log resp fb out home
  dir="$TMP_ROOT/find-scoped"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/find-scoped-home"; mkdir -p "$home"; printf 'bravo-b2\n' > "$home/.fm-secondmate-home"
  # A workspace list carrying BOTH the primary's "firstmate" space and this
  # secondmate's own "2ndmate-bravo-b2" space (as would be true once several
  # homes share one herdr session) - find must pick the one matching THIS
  # home's own label, never the primary's or a sibling secondmate's.
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-bravo-b2"},{"workspace_id":"w3","label":"2ndmate-alpha-a1"}]}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_find fmtest' "$ROOT" )
  [ "$out" = "w2" ] || fail "workspace_find should have matched this home's own label (2ndmate-bravo-b2 -> w2), got '$out'"
  pass "fm_backend_herdr_workspace_find: matches only THIS home's own label among several coexisting workspaces"
}

# --- list_live: scoped to this home's own workspace only ---------------------

test_list_live_scoped_to_this_homes_workspace_only() {
  local dir log resp fb out home
  dir="$TMP_ROOT/list-live-scoped"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/list-live-scoped-home"; mkdir -p "$home"; printf 'bravo-b2\n' > "$home/.fm-secondmate-home"
  # 1: workspace_find's `workspace list` - two homes coexist, secondmate's is w2
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-bravo-b2"}]}}\n' > "$resp/1.out"
  # 2: tab list --workspace w2 (this secondmate's own tabs only)
  printf '{"result":{"tabs":[{"tab_id":"w2:t1","label":"fm-secondmatetask"}]}}\n' > "$resp/2.out"
  # 3: pane_for_tab's `pane list --workspace w2`
  printf '{"result":{"panes":[{"pane_id":"w2:p1","tab_id":"w2:t1"}]}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_list_live fmtest' "$ROOT" )
  [ "$out" = $'fmtest:w2:p1\tfm-secondmatetask' ] || fail "list_live should report only this home's own tab, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''list'$'\x1f''--workspace'$'\x1f''w2' \
    "list_live did not scope the tab list call to this home's own workspace (w2)"
  assert_not_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''list'$'\x1f''--workspace'$'\x1f''w1' \
    "list_live must never query the primary's (or a sibling secondmate's) workspace"
  pass "fm_backend_herdr_list_live: scoped to this home's own workspace, never a sibling home's"
}

# --- target parsing, key normalization ---------------------------------------

test_parse_target() {
  ( . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_parse_target "default:w1:p2" || exit 1
    [ "$FM_BACKEND_HERDR_SESSION" = default ] || { echo "session mismatch: $FM_BACKEND_HERDR_SESSION" >&2; exit 1; }
    [ "$FM_BACKEND_HERDR_PANE" = "w1:p2" ] || { echo "pane mismatch: $FM_BACKEND_HERDR_PANE" >&2; exit 1; }
  ) || fail "fm_backend_herdr_parse_target did not split session:pane on the first colon only"
  pass "fm_backend_herdr_parse_target: splits '<session>:<pane_id>' on the FIRST colon (pane_id itself contains one)"
}

test_normalize_key() {
  ( . "$ROOT/bin/backends/herdr.sh"
    [ "$(fm_backend_herdr_normalize_key Enter)" = enter ] || exit 1
    [ "$(fm_backend_herdr_normalize_key Escape)" = escape ] || exit 1
    [ "$(fm_backend_herdr_normalize_key C-c)" = ctrl+c ] || exit 1
    [ "$(fm_backend_herdr_normalize_key ctrl+c)" = ctrl+c ] || exit 1
  ) || fail "fm_backend_herdr_normalize_key did not map firstmate's key vocabulary to herdr's verified names"
  pass "fm_backend_herdr_normalize_key: Enter/Escape/C-c map to herdr's verified enter/escape/ctrl+c"
}

# --- capture / send_key / kill / current_path --------------------------------

test_capture_calls_pane_read() {
  local dir log resp fb out
  dir="$TMP_ROOT/capture"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'line one\nline two\nline three\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  # Requesting 250 (already >= the 200 floor) passes straight through as the
  # fetch bound; the adapter then trims to the caller's requested 250 lines
  # locally, so all 3 fake lines survive.
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 250' "$ROOT" )
  [ "$out" = $'line one\nline two\nline three' ] || fail "capture did not pass through pane read output, got '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=default"$'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2'$'\x1f''--source'$'\x1f''recent'$'\x1f''--lines'$'\x1f''250' \
    "capture did not call pane read with the right pane id and line bound"
  pass "fm_backend_herdr_capture: calls 'pane read <pane> --source recent --lines N' with the session set"
}

test_capture_works_around_small_lines_bug() {
  local dir log resp fb out
  # Verified herdr v0.7.1 bug (herdr-verification-p2.md): `pane read --lines N`
  # for a small N (below the pane's viewport height) returns EMPTY, not the
  # last N lines. The adapter must never ask herdr for a small --lines bound -
  # it always fetches >= 200 and trims locally with tail.
  dir="$TMP_ROOT/capture-small"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'a\nb\nc\nd\ne\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 2' "$ROOT" )
  [ "$out" = $'d\ne' ] || fail "a small --lines request should still return the last N lines (trimmed locally), got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''--lines'$'\x1f''200' \
    "capture should request a generous fetch (>=200), never the caller's small N, from herdr's own --lines flag"
  pass "fm_backend_herdr_capture: works around the verified small-N '--lines' bug by over-fetching and trimming locally"
}

test_capture_preserves_pane_read_failure() {
  local dir log resp fb out status
  dir="$TMP_ROOT/capture-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 2' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when pane read fails, got output '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=default"$'\x1f''status'$'\x1f''--json' \
    "capture did not ensure the herdr server before reading the pane"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2' \
    "capture did not try to read the requested pane"
  pass "fm_backend_herdr_capture: ensures the session and preserves pane read failure"
}

test_send_key_normalizes_and_targets_pane() {
  local dir log resp fb
  dir="$TMP_ROOT/sendkey"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_key default:w1:p2 Escape' "$ROOT"
  expect_code 0 $? "send_key should succeed"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''escape' "send_key did not normalize Escape to escape"
  pass "fm_backend_herdr_send_key: normalizes the key and targets the right pane"
}

test_kill_is_best_effort() {
  local dir log resp fb
  dir="$TMP_ROOT/kill"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_target_ready() { fm_backend_herdr_parse_target "$1"; }
      fm_backend_herdr_presentation_session_lock_path() { printf "/tmp/fm-herdr-test-lock"; }
      fm_lock_try_acquire() { return 0; }
      fm_lock_release() { return 0; }
      fm_backend_herdr_kill default:w1:p2
    ' "$ROOT"
  expect_code 0 $? "kill must be best-effort (never fail even when the pane close call itself fails)"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p2' "kill did not call pane close on the right pane"
  pass "fm_backend_herdr_kill: calls pane close and stays best-effort on failure"
}

test_current_path_reads_cwd() {
  local dir log resp fb out
  dir="$TMP_ROOT/cwd"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Verified pitfall (herdr-verification-p2.md): .result.pane.cwd is frozen at
  # pane-creation time and never updates; .foreground_cwd tracks the live
  # running process (e.g. a treehouse get subshell) and is what must be read.
  printf '{"result":{"pane":{"cwd":"/tmp/pane-creation-dir","foreground_cwd":"/tmp/fake-worktree"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_current_path default:w1:p2' "$ROOT" )
  [ "$out" = "/tmp/fake-worktree" ] || fail "current_path should read foreground_cwd (the live process), not the frozen creation-time cwd, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''get'$'\x1f''w1:p2' "current_path did not call pane get"
  pass "fm_backend_herdr_current_path: reads pane foreground_cwd (the live running process), not the frozen creation-time cwd"
}

# --- busy_state (semantic agent state) ---------------------------------------

test_busy_state_working_maps_to_busy() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-working"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = busy ] || fail "agent_status=working should map to busy, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''agent'$'\x1f''get'$'\x1f''w1:p2' "busy_state did not call agent get"
  pass "fm_backend_herdr_busy_state: working -> busy"
}

test_busy_state_done_and_blocked_map_to_idle() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-done"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"done"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = idle ] || fail "agent_status=done should map to idle, got '$out'"

  dir="$TMP_ROOT/busy-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = idle ] || fail "agent_status=blocked should map to idle (stuck waiting on the human, not grinding), got '$out'"
  pass "fm_backend_herdr_busy_state: done -> idle, blocked -> idle (surfaced like a stale pane, not suppressed as busy)"
}

test_busy_state_unknown_on_no_agent() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-unknown"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = unknown ] || fail "a failed agent get should report unknown (the fallback-to-regex cue), got '$out'"
  pass "fm_backend_herdr_busy_state: unparseable/absent agent state reports unknown, the regex-fallback cue"
}

# --- composer_state: structural border-row classification --------------------

test_composer_state_bare_prompt_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-bare"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯\n\n  Shift+Tab:mode\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a bare prompt glyph should read as empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a bare '❯' composer row reads empty"
}

test_composer_state_styled_placeholder_draft_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-ghost"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭────────────────────────╮\n  │ ❯ Type a message...    │\n  ╰──────── Composer ──────╯\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "bright placeholder-like text in a styled capture should remain pending, got '$out'"
  pass "fm_backend_herdr_composer_state: bright placeholder-like text stays pending rather than being mistaken for an idle ghost"
}

test_composer_state_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pending"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real unsubmitted text should read as pending, got '$out'"
  pass "fm_backend_herdr_composer_state: real composer text reads pending"
}

# A titled rounded top rule reads as a composer only for a pane whose native
# agent probe names cortex; the identical capture under any other agent, or no
# agent record, keeps the ambiguous verdict every harness reads. The probe
# (`agent get`) is asked for only when the classifier reports the identity
# matters - a titled rounded box with an agent prompt glyph - so every other
# pane keeps the single capture call it always had.
cortex_composer_case() {  # <dir-suffix> <capture-body> <agent-json-or-error-body>
  local dir="$TMP_ROOT/composer-titled-$1" resp log fb
  mkdir -p "$dir/responses"; resp="$dir/responses"; log="$dir/log"; : > "$log"
  printf '%b' "$2" > "$resp/1.out"
  printf '%s\n' "$3" > "$resp/2.out"
  printf '%s\n' "$3" > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT"
}

cortex_agent_get_calls() {  # <dir-suffix>
  grep -c "$(printf '\037agent\037get\037')" "$TMP_ROOT/composer-titled-$1/log" || true
}

test_composer_state_titled_box_requires_cortex_identity() {
  local out calls titled
  titled='╭────────────── New Session ──╮\n│ ❯                           │\n╰─────────────────────────────╯\n\n>> bypass safeguards  |  teams: off  |  plan: off\n'
  out=$(cortex_composer_case cortex "$titled" '{"result":{"agent":{"agent":"cortex","agent_status":"idle"}}}')
  [ "$out" = empty ] || fail "a titled box under a cortex agent probe should read empty, got '$out'"
  calls=$(cortex_agent_get_calls cortex)
  [ "$calls" = 1 ] || fail "a titled box should resolve Cortex with exactly one agent get, saw $calls"
  out=$(cortex_composer_case other "$titled" '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}')
  [ "$out" = unknown ] || [ "$out" = pending-unproven ] \
    || fail "a titled box under a non-cortex agent must stay ambiguous, got '$out'"
  calls=$(cortex_agent_get_calls other)
  [ "$calls" = 1 ] || fail "a titled box under another agent should ask for the identity once, saw $calls"
  out=$(cortex_composer_case absent "$titled" '{"error":{"code":"agent_not_found"}}')
  [ "$out" = unknown ] || [ "$out" = pending-unproven ] \
    || fail "a titled box with no agent record must stay ambiguous, got '$out'"
  pass "fm_backend_herdr_composer_state: titled rounded top rule is a composer only under a cortex agent probe"
}

# A pane that never shows a titled rounded composer box never pays a second
# identity read, whatever its verdict: a plain idle box, a plain draft, and
# titled boxes the Cortex tolerance cannot accept (no prompt glyph row, a
# non-ASCII title) all keep the one capture call, even under a cortex agent.
test_composer_state_non_cortex_panes_skip_identity_probe() {
  local agent='{"result":{"agent":{"agent":"cortex","agent_status":"idle"}}}' out calls name expect body
  while IFS='|' read -r name expect body; do
    out=$(cortex_composer_case "$name" "$body" "$agent")
    case "$expect" in
      ambiguous)
        case "$out" in
          unknown|pending-unproven) ;;
          *) fail "$name: expected an ambiguous verdict, got '$out'" ;;
        esac
        ;;
      *) [ "$out" = "$expect" ] || fail "$name: expected '$expect', got '$out'" ;;
    esac
    calls=$(cortex_agent_get_calls "$name")
    [ "$calls" = 0 ] || fail "$name: a pane with no titled composer box must not probe identity, saw $calls agent get calls"
  done <<'CASES'
plain-empty|empty|  ╭────────────────────────╮\n  │ ❯                      │\n  ╰────────────────────────╯\n
plain-draft|pending|  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰────────────────────────╯\n
titled-glyphless|ambiguous|╭────────── Select a model ──╮\n│ ○ Auto                      │\n╰─────────────────────────────╯\n
titled-nonascii|ambiguous|╭────────────── Nüw Session ──╮\n│ ❯                           │\n╰─────────────────────────────╯\n
CASES
  pass "fm_backend_herdr_composer_state: panes without a titled composer box make no second agent get call"
}

# Issue #3436: Grok 1.0.5's real bottom border is three columns wider than
# the aligned top and content rows. Herdr has no cursor anchor, so the old
# geometry verdict was unknown even when this composer was genuinely idle.
test_composer_state_grok_oversized_title_preserves_safe_verdicts() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-grok-oversized-title"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' \
    '  ╭──────────────────────────────────────────────────────────────────────────╮' \
    '  │ ❯                                                                        │' \
    '  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯' \
    '' \
    '  Shift+Tab:mode  │  Ctrl+x:shortcuts' > "$resp/1.out"
  printf '%s\n' \
    '  ╭──────────────────────────────────────────────────────────────────────────╮' \
    '  │ ❯ deploy the fix                                                         │' \
    '  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯' > "$resp/2.out"
  printf '%s\n' \
    '  ╭──────────────────────────────────────────────────────────────────────────╮' \
    '  │ ❯                                                                        │' \
    '  ╰────────────────────────────────────────────────────────── unknown surface ─╯' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")

  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "issue #3436's idle Grok/Herdr composer should read empty, got '$out'"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "typed text inside Grok's oversized box should stay pending, got '$out'"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = unknown ] || fail "an oversized unrecognized title should stay unknown, got '$out'"
  pass "fm_backend_herdr_composer_state: Grok's exact title overhang is empty while pending and unproved panes remain safe"
}

# Live-verified incident (2026-07-03, real grok 0.2.82 on herdr, isolated
# session): typing "/compact" opens the completion popup; the FIRST Enter
# closes the popup and EXPANDS the composer into an argument-hint placeholder
# ("/compact compaction instructions") rather than submitting - the composer
# still reads real, unsubmitted text and the footer still shows "Enter:send".
# A prior raw-diff verification saw the popup vanish and the text change and
# declared this "submitted". The structural composer-row read must still call
# this pending.
test_composer_state_popup_placeholder_fill_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-popup-placeholder"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions   │\n  ╰──────────────── Composer ────────────╯\n\n  Enter:send\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_herdr_composer_state: a slash-command popup's argument-hint placeholder still reads pending (the incident fix)"
}

test_composer_state_unknown_on_capture_failure() {
  local dir log resp fb out status
  dir="$TMP_ROOT/composer-capture-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  status=$?
  [ "$status" -eq 0 ] || fail "composer_state should not itself fail the caller"
  [ "$out" = unknown ] || fail "an unreadable pane should read as unknown, got '$out'"
  pass "fm_backend_herdr_composer_state: reports unknown when the pane cannot be captured"
}

test_composer_state_inactive_session_fails_fast_without_server_autostart() {
  local dir log resp fb out status
  dir="$TMP_ROOT/composer-inactive-session"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # status --json reports stopped server
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":false}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state nonexistent:w1:p2' "$ROOT" )
  status=$?
  [ "$status" -eq 0 ] || fail "composer_state should exit 0 on inactive session"
  [ "$out" = unknown ] || fail "composer_state on inactive session should read unknown, got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f''server' "composer probe on inactive session must never autostart a herdr server"
  pass "fm_backend_herdr_composer_state: fails fast to unknown for inactive session without starting server"
}

# shellcheck disable=SC2016
test_composer_state_piped_reader_does_not_hang() {
  local out rc=0
  out=$( fm_run_timed 3 bash -c '. "$0/bin/fm-backend.sh"; ( fm_backend_composer_state herdr nonexistent-session:p2 ) 2>&1 | head -20' "$ROOT" ) || rc=$?
  [ "$rc" -eq 0 ] || fail "piped composer probe on bad target hung or failed with rc=$rc"
  [ "$out" = unknown ] || fail "piped composer probe should print unknown, got '$out'"
  pass "fm_backend_composer_state (herdr): piped probe on bad target does not hang EOF-sensitive readers"
}

test_composer_state_unknown_when_no_composer_row_found() {
  local dir log resp fb out glyph idx=1
  dir="$TMP_ROOT/composer-no-row"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  for glyph in '>' '$' '%' '#'; do
    printf '%s \n' "$glyph" > "$resp/$idx.out"
    idx=$((idx + 1))
  done
  fb=$(make_herdr_fakebin "$dir")
  for glyph in '>' '$' '%' '#'; do
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
    [ "$out" = unknown ] || fail "a bare shell prompt '$glyph' should read as unknown, got '$out'"
  done
  pass "fm_backend_herdr_composer_state: reports unknown for bare shell prompts with no composer row"
}

# Real Pi 0.80.7 on Herdr 0.7.3 renders no prompt glyph and no side border.
# Its content is the row(s) between two blue horizontal separators; the idle row
# carries only a reverse-video cursor. This exact shape was `unknown` for 4555s
# during the 2026-07-14 incident, so the safe injector never attempted submit.
test_composer_state_pi_separator_idle_is_empty() {
  local dir log resp fb out calls
  dir="$TMP_ROOT/composer-pi-separated-idle"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '│ stale bordered transcript row │\n\x1b[0m\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n\x1b[0m\x1b[7m \x1b[0m                                                    \n\x1b[0m\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n\x1b[0m\x1b[38;2;102;102;102m~/synthetic-primary (main)\x1b[0m\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "an idle native Pi separator composer should read empty, got '$out'"
  calls=$(grep -c $'\x1f''agent'$'\x1f''get' "$log")
  [ "$calls" -eq 1 ] || fail "Pi separator recognition must corroborate identity exactly once, made $calls agent calls"
  pass "fm_backend_herdr_composer_state: a native idle Pi separator composer reads empty"
}

test_composer_state_pi_dollar_status_footer_is_empty() {
  # `$0.000 (sub) 5.4%/272k (auto)` at column 0 made herdr composer_state
  # unknown, so exit and relaunch refused on an otherwise idle Pi pane.
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pi-dollar-status"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s\n' $'transcript\n─────────────────────────────────────────────────────\n\n─────────────────────────────────────────────────────\n$0.000 (sub) 5.4%/272k (auto)' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "an idle Pi composer with a dollar-first status footer should read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a dollar-first Pi status footer reads empty, not a dead shell"
}

# A pi worker parked on an interactive prompt (permission dialog, question
# menu, trust dialog) reports agent_status=blocked: it is waiting on a human
# keystroke. The menu is drawn ABOVE the separator pair, so the composer region
# itself is blank and structure alone looks like a free composer. Typing there
# does not compose a message - the menu consumes the keys and Enter selects the
# highlighted default, so the text is discarded and a decision nobody made is
# recorded (issue #2797). Every "is it safe to type here?" consumer reads this
# verdict: the away-mode injection guard (bin/fm-supervise-daemon.sh) and
# fm-send's pre-type refusal both proceed ONLY on an affirmative `empty`.
test_composer_state_pi_parked_prompt_is_not_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pi-parked-prompt"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'Should I keep going?\n  1. Yes, continue\n\x1b[7m  2. Stop, do not act\x1b[0m\n\x1b[0m\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n\x1b[0m\x1b[7m \x1b[0m                                                    \n\x1b[0m\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"blocked"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" != empty ] \
    || fail "a pi pane parked on a prompt must not report an affirmatively empty composer, got '$out'"
  pass "fm_backend_herdr_composer_state: a blocked pi pane parked on a prompt is not an empty composer"
}

test_composer_state_pi_separator_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pi-separated-pending"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\nprivacy safe human draft\x1b[7m \x1b[0m\n\x1b[38;2;129;162;190m─────────────────────────────────────────────────────\x1b[0m\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"done"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real text in a native Pi separator composer should read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: real Pi composer text remains pending"
}

test_composer_state_pi_incomplete_separator_below_stale_generic_is_unknown() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pi-separated-incomplete"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '│   │\n─────────────────────────────────────────────────────\n\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
  [ "$out" = unknown ] || fail "an incomplete Pi separator below a stale generic row should remain unknown, got '$out'"
  pass "fm_backend_herdr_composer_state: an incomplete lower Pi separator cannot inherit a stale empty row"
}

test_composer_state_pi_separator_requires_safe_native_identity() {
  local dir log resp fb out status case_id idx=0
  for case_id in working non-pi unreadable over-tall; do
    dir="$TMP_ROOT/composer-pi-separated-$case_id"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    if [ "$case_id" = over-tall ]; then
      {
        printf '─────────────────────────────────────────────────────\n'
        for idx in $(seq 1 9); do printf 'line %s\n' "$idx"; done
        printf '─────────────────────────────────────────────────────\n'
      } > "$resp/1.out"
    else
      printf '─────────────────────────────────────────────────────\n\n─────────────────────────────────────────────────────\n' > "$resp/1.out"
    fi
    case "$case_id" in
      working) printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/2.out" ;;
      non-pi) printf '{"result":{"agent":{"agent":"shell","agent_status":"idle"}}}\n' > "$resp/2.out" ;;
      unreadable) printf '1\n' > "$resp/2.exit" ;;
      over-tall) printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' > "$resp/2.out" ;;
    esac
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state lab:w1:p2' "$ROOT" )
    [ "$out" = unknown ] || fail "unsafe Pi separator case '$case_id' must remain unknown, got '$out'"
  done
  pass "fm_backend_herdr_composer_state: Pi separators never authorize working, non-Pi, unreadable, or over-tall targets"
}

# --- composer_state: unbordered (bare) composer rows -------------------------
# Regression coverage for the away-mode redelivery-loop incident
# (docs/herdr-backend.md "Incident (2026-07-07)"): real claude and codex
# composer rows carry NO border glyph at all - the fixtures below are captured
# verbatim (character-for-character) from a real herdr session running real
# `claude`/`codex` (see the dated evidence entry). Before the fix these all
# read "unknown" (claude/codex fixtures) or produced a false "empty" from a
# stale decorative box (the banner-priority fixture) - none of them correctly
# tracked the live composer, which is exactly what caused
# bin/fm-supervise-daemon.sh's fm_backend_herdr_send_text_submit to never
# confirm a landed injection, so escalate_flush never cleared
# state/.subsuper-escalations and the same digest was redelivered every cycle.

test_composer_state_claude_unbordered_prompt_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-bare-empty"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  20\n  21\n\n\xe2\x9c\xbb Worked for 2s\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Opus 4.8 (1M context)   \xe2\x96\x8d               3%%\n  \xe2\x86\x90 for agents\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a genuinely idle, unbordered real-claude '❯' prompt row (no border glyph anywhere in view) should read empty, got '$out' (regression: this used to read 'unknown' forever, which is exactly what broke escalate_flush's buffer-clear)"
  pass "fm_backend_herdr_composer_state: a real-claude unbordered '❯' prompt row (no border box in view) reads empty"
}

test_composer_state_claude_unbordered_prompt_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-bare-pending"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  20\n  21\n\n\xe2\x9c\xbb Worked for 2s\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf hello there this is a test message\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real unsubmitted text in an unbordered real-claude prompt row should read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: a real-claude unbordered '❯ <text>' prompt row reads pending"
}

# The exact incident shape: a bordered decorative box (claude's own startup
# welcome banner) is STILL in the capture window, sitting ABOVE the live,
# unbordered "❯" prompt. Before the fix, the bordered branch was the ONLY one
# ever consulted, so the LAST bordered row (the banner's own blank interior
# spacer row, immediately above its closing ╰──╯) won by construction and was
# misread as the live composer - which happened to strip to empty here, but
# for the same reason never tracks the REAL composer once real text is typed
# below the banner (see the daemon-level E2E evidence in
# docs/herdr-backend.md). The live, bottom-most row must win regardless of
# shape.
test_composer_state_bare_prompt_below_stale_bordered_banner_wins() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-banner-priority"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x95\xad\xe2\x94\x80 Claude Code \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82           Welcome back Kun!           \xe2\x94\x82\n\xe2\x94\x82                                       \xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf still typing captain\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "the live unbordered prompt row below a stale bordered banner must win (pending, real text present), got '$out'"
  pass "fm_backend_herdr_composer_state: a live unbordered prompt row below a stale bordered decorative box still wins (not misread as the box's own row)"
}

# THE OVERNIGHT WEDGE regression (task afk-herdr-false-pending). Captured
# read-only from the live primary claude-on-herdr pane default:w1:p3 on
# 2026-07-10: an idle composer whose only content is claude's rotating
# prompt-suggestion GHOST, rendered SGR-2 dim after the bare "❯" prompt
# ("❯ \033[0m\033[2m<suggestion>\033[0m"). herdr's `pane read --format ansi`
# preserves the dim attribute. The pre-fix herdr classifier stripped ALL ANSI
# and read the suggestion as real pending text (its only faint check matched
# codex's bold-wrapped "\033[1m❯ \033[0m\033[2m", which this shape is NOT), so
# every away-mode injection deferred with "pending input (non-empty composer)"
# all night (6524 lifetime defers; wedge 30623s undelivered). The shared
# ANSI-aware owner now drops the dim ghost and the row reads empty (safe to
# inject).
test_composer_state_claude_dim_prompt_suggestion_ghost_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-dim-ghost"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x9c\xbb Brewed for 2m 40s\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf \x1b[0m\x1b[2mwhat did the wheelhouse healing verification find?\x1b[0m\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Fable 5                 80%%\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p3' "$ROOT" )
  [ "$out" = empty ] || fail "the overnight shape - claude's SGR-2 dim prompt-suggestion ghost after a bare '❯' - must read empty, got '$out' (regression: this false-pending wedged away-mode injection all night)"
  pass "fm_backend_herdr_composer_state: claude's dim prompt-suggestion ghost (the overnight wedge shape) reads empty"
}

# Same prompt row, but the text after "❯" is REAL (normal intensity, no dim) -
# it must still read pending, so the ghost fix never weakens real-input
# protection.
test_composer_state_claude_dim_ghost_row_with_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-dim-ghost-real"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf land pr 416 now\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Fable 5                 80%%\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p3' "$ROOT" )
  [ "$out" = pending ] || fail "real normal-intensity text after '❯' must still read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: real typed text on the same claude prompt row still reads pending"
}

# grok's TRUECOLOR placeholder gap (harness-adapters "Known gap"), now covered by
# the same owner. grok renders its composer inside a bordered box whose border
# and placeholder/hint text use a dark, muted truecolor foreground (verified live
# against grok 0.2.93: border 38;2;86;82;110, muted 38;2;50;47;70, hint
# 38;2;110;106;134; real input is the BRIGHT 38;2;224;222;244), while the "❯"
# prompt glyph stays bright. The dark placeholder drops and the row reads empty.
test_composer_state_grok_dark_truecolor_placeholder_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-grok-truecolor-ghost"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  \x1b[38;2;86;82;110m\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x94\x82\x1b[38;2;224;222;244m \xe2\x9d\xaf \x1b[38;2;50;47;70mType a message...\x1b[38;2;86;82;110m \xe2\x94\x82\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\x1b[39m\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a grok bordered composer whose only content is a dark-truecolor placeholder must read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: grok's dark-truecolor placeholder (the TRUECOLOR gap) reads empty"
}

# grok's bordered composer with REAL bright typed input must still read pending.
test_composer_state_grok_bright_truecolor_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-grok-truecolor-real"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  \x1b[38;2;86;82;110m\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x94\x82\x1b[38;2;224;222;244m \xe2\x9d\xaf fix the login bug \x1b[38;2;86;82;110m\xe2\x94\x82\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\x1b[39m\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real bright typed text in a grok bordered composer must read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: grok's real bright typed input still reads pending"
}

test_composer_state_codex_bare_prompt_glyph_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-bare"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 You have 2 usage limit resets available.\n\n\xe2\x80\xba\n\n  gpt-5.5 xhigh \xc2\xb7 Context 100%% left\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a bare '›' (codex) prompt glyph with no trailing text should read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a real-codex unbordered '›' prompt row reads empty"
}
