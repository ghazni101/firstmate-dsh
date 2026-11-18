# shellcheck shell=bash
# Test cases for fm-daemon, split out of tests/fm-daemon.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-daemon.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2153,SC2329 # cases share setup and helpers with their .test.sh runner


test_housekeeping_overdue_queue_failure_leaves_decision_open() {
  local dir state fakebin task win pane statusf
  dir=$(make_supercase overdue-queue-retry)
  arm_pause_ceiling "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"
  task=overdue-retry; win="sess:fm-$task"; pane="$dir/pane.txt"; statusf="$state/$task.status"
  printf 'paused: waiting for dependency\n' > "$statusf"
  printf 'idle prompt $\\n' > "$pane"
  fm_write_meta "$state/$task.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" enter --words 'fixture words' >/dev/null 2>&1 || fail "fixture: could not record away posture"
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$task"
  sleep 2
  FM_STATE_OVERRIDE="$state" . "$ROOT/bin/fm-wake-lib.sh"
  real_escalate_add=$(declare -f escalate_add)
  escalate_add() { return 1; }
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 housekeeping "$state"
  [ -z "$(overdue_delivered_key "$state" "$task")" ] || fail "failed queue was recorded as delivered"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1" && reconcile_overdue_pauses' _ "$ROOT/bin/fm-watch.sh" \
    || fail "watcher overdue reconciliation failed"
  [ -e "$state/.paused-overdue-$task" ] || fail "a watcher poll discarded the overdue marker"
  eval "$real_escalate_add"
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-last-scan"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 FM_HEARTBEAT_SCAN_SECS=0 housekeeping "$state"
  [ "$(grep -cF "blocked [key=paused-overdue-$task]" "$statusf")" -eq 1 ] || fail "the failed queue opened a second decision"
  [ "$(grep -cF "paused-overdue-$task" "$state/.subsuper-escalations")" -eq 1 ] || fail "the next housekeeping pass did not raise the open decision once"
  [ "$(grep -cF "stale: $win (paused " "$state/.subsuper-escalations")" -eq 0 ] || fail "a failed alert was retried"
  pass "a failed overdue queue stays an open decision the next housekeeping pass raises"
}

test_watcher_overdue_marker_does_not_hide_blocker_from_daemon() {
  local dir state task win statusf size identity
  dir=$(make_supercase overdue-watcher-marker)
  arm_pause_ceiling "$dir"
  state="$dir/state"; task=overdue-shared; win="sess:fm-$task"; statusf="$state/$task.status"
  printf 'paused: waiting for dependency\n' > "$statusf"
  size=$(wc -c < "$statusf" | tr -d ' ')
  printf 'blocked [key=paused-overdue-%s]: paused 90s, wait overdue - decide or release\n' "$task" >> "$statusf"
  fm_write_meta "$state/$task.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  (
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 . "$ROOT/bin/fm-wake-lib.sh"
    if [ "$(uname)" = Darwin ]; then identity=$(/usr/bin/stat -f '%d %i' "$statusf"); else identity=$(stat -c '%d %i' "$statusf"); fi
    printf '%s:%s\n' "$identity" "$size" > "$state/.paused-overdue-$task"
    [ -z "$(overdue_delivered_key "$state" "$task")" ] || fail "an undelivered marker hid its blocker"
    handle_wake "stale: $win (paused 90s, wait overdue - decide or release)" "$state"
    grep -F "paused-overdue-$task" "$state/.subsuper-escalations" >/dev/null \
      || fail "the daemon never escalated a blocker only the watcher had reported"
  ) || fail "watcher marker hid the blocker"
  pass "a watcher-written overdue marker leaves the blocker to ordinary escalation"
}
