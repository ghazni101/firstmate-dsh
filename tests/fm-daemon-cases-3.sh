# shellcheck shell=bash
# Test cases for fm-daemon, split out of tests/fm-daemon.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-daemon.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2153,SC2329 # cases share setup and helpers with their .test.sh runner


test_housekeeping_overdue_queue_failure_resume_discards() {
  local event route dir state fakebin task win pane statusf original_enqueue original_append undated
  original_enqueue=$(declare -f escalate_add)
  for event in working paused; do
    for route in housekeeping signal stale; do
      (
        dir=$(make_supercase "overdue-resume-$event-$route")
        arm_pause_ceiling "$dir"
        state="$dir/state"; fakebin="$dir/fakebin"
        task=overdue-resume; win="sess:fm-$task"; pane="$dir/pane.txt"; statusf="$state/$task.status"
        printf 'paused: waiting for dependency\n' > "$statusf"
        printf 'idle prompt $\n' > "$pane"
        fm_write_meta "$state/$task.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
        FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" enter --words fixture >/dev/null 2>&1 || fail "fixture: away posture"
        printf '%s\n' "$(( $(date +%s) - 5000 ))" > "$state/.subsuper-paused-$task"
        sleep 2
        # shellcheck source=/dev/null
        . "$ROOT/bin/fm-wake-lib.sh"
        # Prefix assignments on a sourced file last only while it is sourced, so each
        # daemon call carries the fixture environment itself.
        undated=1
        fixture() { PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
          FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=$undated FM_ESCALATE_BATCH_SECS=999999 "$@"; }
        original_append=$(declare -f fm_wake_status_append_self_announced)
        escalate_add() { return 1; }
        fixture housekeeping "$state"
        [ -e "$state/.paused-overdue-$task" ] || fail "failed queue lost the overdue marker"
        undated=86400
        printf '%s: worker changed wait\n' "$event" >> "$statusf"
        eval "$original_enqueue"
        fm_wake_status_append_self_announced() { return 2; }
        case "$route" in
          housekeeping) fixture housekeeping "$state" ;;
          signal) fixture handle_wake "signal: $statusf" "$state" ;;
          stale) fixture handle_wake "stale: $win" "$state" ;;
        esac
        [ -e "$state/.paused-overdue-$task" ] || fail "failed resolution lost the overdue marker ($event/$route)"
        : > "$state/.subsuper-escalations"
        eval "$original_append"
        case "$route" in
          housekeeping) fixture housekeeping "$state" ;;
          signal) fixture handle_wake "signal: $statusf" "$state"; fixture housekeeping "$state" ;;
          stale) fixture handle_wake "stale: $win" "$state"; fixture housekeeping "$state" ;;
        esac
        [ ! -s "$state/.subsuper-escalations" ] || fail "resumed worker queued an obsolete alert ($event/$route)"
        [ ! -e "$state/.paused-overdue-$task" ] || fail "resume retained the overdue marker"
        FM_HOME="$dir" status_open_decisions "$statusf" | grep -F "paused-overdue-$task" >/dev/null \
          && fail "resume left the overdue decision open ($event/$route)"
        grep -Fq "resolved [key=paused-overdue-$task]" "$statusf" || fail "resume did not record resolution"
      ) || fail "pending resume reconciliation failed ($event/$route)"
    done
  done
  pass "failed enqueue followed by a worker event closes without an obsolete alert, retaining failed resolutions"
}

test_overdue_reconcile_ignores_unrelated_and_repeated_pause() {
  local dir state task statusf identity offset event
  for event in blocked repeated prose custom "done" merged configured-resolve; do
    dir=$(make_supercase "overdue-reconcile-$event"); state="$dir/state"
    arm_pause_ceiling "$dir"
    task=overdue-reconcile; statusf="$state/$task.status"
    if [ "$event" = custom ]; then printf 'holding [at=100]: waiting for dependency\n' > "$statusf"; else printf 'paused [at=100]: waiting for dependency\n' > "$statusf"; fi
    offset=$(wc -c < "$statusf" | tr -d ' ')
    printf 'blocked [key=paused-overdue-%s]: overdue\n' "$task" >> "$statusf"
    if [ "$(uname)" = Darwin ]; then identity=$(/usr/bin/stat -f '%d %i' "$statusf"); else identity=$(stat -c '%d %i' "$statusf"); fi
    printf '%s:%s\n' "$identity" "$offset" > "$state/.paused-overdue-$task"
    case "$event" in
      blocked) printf 'blocked [key=other]: another decision\n' >> "$statusf" ;;
      repeated) printf 'paused [at=200]: waiting for dependency\n' >> "$statusf" ;;
      prose) printf 'Still waiting for the dependency\n' >> "$statusf" ;;
      custom) printf 'holding [at=200]: waiting for dependency\n' >> "$statusf" ;;
      done) printf 'done: finished\n' >> "$statusf" ;;
      merged) printf 'merged\n' >> "$statusf" ;;
      configured-resolve) printf 'working: resumed\n' >> "$statusf" ;;
    esac
    (
      FM_HOME="$dir" FM_STATE_OVERRIDE="$state" . "$ROOT/bin/fm-wake-lib.sh"
      if [ "$event" = custom ]; then
        FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CLASSIFY_PAUSED_VERB=holding reconcile_overdue_pause "$state" "$task"
      elif [ "$event" = configured-resolve ]; then
        FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CLASSIFY_RESOLVE_VERB=answered reconcile_overdue_pause "$state" "$task"
      else
        FM_HOME="$dir" FM_STATE_OVERRIDE="$state" reconcile_overdue_pause "$state" "$task"
      fi
      if [ "$event" = "done" ] || [ "$event" = merged ] || [ "$event" = configured-resolve ]; then
        [ ! -e "$state/.paused-overdue-$task" ] || fail "$event left the overdue marker"
        if [ "$event" = configured-resolve ]; then
          ! FM_CLASSIFY_RESOLVE_VERB=answered status_open_decisions "$statusf" | grep -Fq "paused-overdue-$task" || fail "$event left the overdue decision open"
          grep -Fq "answered [key=paused-overdue-$task]" "$statusf" || fail "$event did not record configured resolution"
        else
          ! status_open_decisions "$statusf" | grep -Fq "paused-overdue-$task" || fail "$event left the overdue decision open"
        fi
      else
        [ -e "$state/.paused-overdue-$task" ] || fail "$event removed the overdue marker"
        status_open_decisions "$statusf" | grep -Fq "paused-overdue-$task" || fail "$event closed the overdue decision"
      fi
    ) || fail "overdue reconciliation accepted $event as resume"
  done
  pass "unrelated blockers and repeated pauses preserve overdue decisions"
}

test_housekeeping_overdue_initial_publication_reconciles_resume() {
  local timing dir state task statusf original_append
  for timing in before after; do
    (
      dir=$(make_supercase "overdue-initial-resume-$timing"); state="$dir/state"
      arm_pause_ceiling "$dir"
      task=overdue-initial; statusf="$state/$task.status"
      printf 'paused: waiting for dependency\n' > "$statusf"
      fm_write_meta "$state/$task.meta" "window=sess:fm-$task" "worktree=$dir/wt" "kind=ship" "harness=pi"
      FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" enter --words fixture >/dev/null 2>&1 || fail "fixture: away posture"
      printf '%s\n' "$(( $(date +%s) - 5000 ))" > "$state/.subsuper-paused-$task"
      sleep 2
      FM_HOME="$dir" FM_STATE_OVERRIDE="$state" . "$ROOT/bin/fm-wake-lib.sh"
      original_append=$(declare -f fm_wake_status_append_self_announced)
      eval "${original_append/fm_wake_status_append_self_announced ()/original_append_impl ()}"
      fm_wake_status_append_self_announced() {
        case "$3" in blocked*)
          [ "$timing" != before ] || printf 'working: resumed\n' >> "$2"
          original_append_impl "$@"
          [ "$timing" != after ] || printf 'working: resumed\n' >> "$2"
          return 1 ;;
        esac
        original_append_impl "$@"
      }
      PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 \
        FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"
      [ ! -s "$state/.subsuper-escalations" ] || fail "initial publication queued an obsolete alert ($timing)"
      [ -z "$(status_open_decisions "$statusf")" ] || fail "initial publication left an obsolete decision ($timing)"
      grep -Fq "resolved [key=paused-overdue-$task]" "$statusf" || fail "initial race was not reconciled"
    ) || fail "initial resume race failed ($timing)"
  done
  pass "initial overdue publication reconciles resumes on either side of its blocker append"
}
