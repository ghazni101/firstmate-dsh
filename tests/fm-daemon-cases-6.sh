# shellcheck shell=bash
# Test cases for fm-daemon, split out of tests/fm-daemon.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-daemon.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2153,SC2329 # cases share setup and helpers with their .test.sh runner


test_overdue_open_decision_without_marker_is_not_repeated() {
  local dir state task statusf
  dir=$(make_supercase overdue-open-no-marker)
  arm_pause_ceiling "$dir"
  state="$dir/state"; task=overdue-crash; statusf="$state/$task.status"
  printf 'paused: waiting for dependency\nblocked [key=paused-overdue-%s]: paused 9s, wait overdue - decide or release\n' "$task" > "$statusf"
  fm_write_meta "$state/$task.meta" "window=sess:fm-$task" "worktree=$dir/wt" "kind=ship" "harness=pi"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" enter --words fixture >/dev/null 2>&1 || fail "fixture: away"
  printf '%s\n' "$(( $(date +%s) - 5000 ))" > "$state/.subsuper-paused-$task"
  sleep 2
  (
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 FM_ESCALATE_BATCH_SECS=999999 . "$ROOT/bin/fm-wake-lib.sh"
    housekeeping "$state"
    [ "$(grep -cF "blocked [key=paused-overdue-$task]" "$statusf")" -eq 1 ] || fail "an interrupted emission opened a second decision"
  ) || fail "open decision without a marker was repeated"
  pass "an open overdue decision with no marker is not opened again"
}
