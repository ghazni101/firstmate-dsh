# shellcheck shell=bash
# Test cases for fm-daemon, split out of tests/fm-daemon.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-daemon.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2153,SC2329 # cases share setup and helpers with their .test.sh runner


test_housekeeping_quiet_overdue_pause_opens_decision() {
  local dir state fakebin task win pane statusf
  dir=$(make_supercase quiet-overdue-pause)
  arm_pause_ceiling "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"
  task=overdue-quiet; win="sess:fm-$task"; pane="$dir/pane.txt"; statusf="$state/$task.status"
  printf 'paused: waiting for dependency\n' > "$statusf"
  printf 'idle prompt $\n' > "$pane"
  fm_write_meta "$state/$task.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$task"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'fixture words' >/dev/null 2>&1 \
    || fail "fixture: could not record the quiet posture"
  sleep 2
  FM_STATE_OVERRIDE="$state" . "$ROOT/bin/fm-wake-lib.sh"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 \
    FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"
  [ "$(grep -cF "blocked [key=paused-overdue-$task]" "$statusf")" -eq 1 ] \
    || fail "quiet-mode housekeeping did not open one overdue decision"
  [ "$(grep -cF "stale: $win (paused " "$state/.subsuper-escalations")" -eq 1 ] \
    || fail "quiet-mode housekeeping did not queue one stale escalation"
  pass "quiet-mode housekeeping applies the overdue pause ceiling"
}

test_housekeeping_overdue_pause_preserves_prior_actionable_event() {
  local dir state fakebin task win pane statusf blocked
  dir=$(make_supercase overdue-pause-unread-event)
  arm_pause_ceiling "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"
  task=overdue-unread; win="sess:fm-$task"; pane="$dir/pane.txt"; statusf="$state/$task.status"
  printf 'done: prior actionable event\npaused: waiting for dependency\n' > "$statusf"
  printf 'idle prompt $\n' > "$pane"
  fm_write_meta "$state/$task.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" enter --words 'fixture words' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture"
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$task"
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-last-scan"
  sleep 2
  FM_STATE_OVERRIDE="$state" . "$ROOT/bin/fm-wake-lib.sh"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 \
    FM_HEARTBEAT_SCAN_SECS=0 FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"

  blocked="blocked [key=paused-overdue-$task]"
  [ "$(grep -cF "$blocked" "$statusf")" -eq 1 ] || fail "overdue blocker was not appended once"
  [ "$(grep -cF 'prior actionable event (catch-all scan)' "$state/.subsuper-escalations")" -eq 1 ] \
    || fail "the prior unread status event was not presented once"
  [ "$(grep -cF "stale: $win (paused " "$state/.subsuper-escalations")" -eq 1 ] \
    || fail "the overdue pause was not queued once"
  ! grep -Fq "paused-overdue-$task (catch-all scan)" "$state/.subsuper-escalations" \
    || fail "the self-announced overdue blocker was re-reported by heartbeat"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 \
    FM_HEARTBEAT_SCAN_SECS=0 FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"
  [ "$(grep -cF 'prior actionable event (catch-all scan)' "$state/.subsuper-escalations")" -eq 1 ] \
    || fail "the prior actionable event was presented more than once"
  [ "$(grep -cF "stale: $win (paused " "$state/.subsuper-escalations")" -eq 1 ] \
    || fail "the overdue pause was queued more than once"
  pass "overdue self-announcement preserves prior unread events without duplicate heartbeat"
}

test_housekeeping_declared_time_controls_pause_recheck() {
  local dir state fakebin task win pane key now future distant past escalations
  dir=$(make_supercase pause-until-cadence)
  state="$dir/state"; fakebin="$dir/fakebin"
  task='held-until'; win="sess:fm-$task"; pane="$dir/pane.txt"
  printf 'idle prompt $\n' > "$pane"
  fm_write_meta "$state/$task.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  key=$(printf '%s' "$task" | tr ':/.' '___')
  now=$(date +%s)
  if [ "$(uname)" = Darwin ]; then
    future=$(date -u -r "$((now + 120))" +%Y-%m-%dT%H:%M:%SZ)
    distant=$(date -u -r "$((now + 31536000))" +%Y-%m-%dT%H:%M:%SZ)
    past=$(date -u -r "$((now - 120))" +%Y-%m-%dT%H:%M:%SZ)
  else
    future=$(date -u -d "@$((now + 120))" +%Y-%m-%dT%H:%M:%SZ)
    distant=$(date -u -d "@$((now + 31536000))" +%Y-%m-%dT%H:%M:%SZ)
    past=$(date -u -d "@$((now - 120))" +%Y-%m-%dT%H:%M:%SZ)
  fi
  printf 'paused: waiting for release until %s\n' "$future" > "$state/$task.status"
  echo $((now - 60)) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "a near-future declared time was rechecked before that time"

  printf 'paused: waiting for release until %s\n' "$distant" > "$state/$task.status"
  echo $((now - 300)) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  escalations=$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')
  [ "$escalations" -eq 1 ] || fail "a wrong-year declared time silenced daemon housekeeping beyond the cadence"
  grep -F 'declared time is beyond the recheck cadence' "$state/.subsuper-escalations" >/dev/null \
    || fail "the bounded daemon recheck gave the wrong reason: $(cat "$state/.subsuper-escalations")"
  grep -F 'declared clearing time has passed' "$state/.subsuper-escalations" >/dev/null \
    && fail "the bounded daemon recheck falsely claimed the future declared time passed"

  printf 'paused: waiting for release until %s\n' "$past" > "$state/$task.status"
  date +%s > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  escalations=$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')
  [ "$escalations" -eq 2 ] || fail "a reached declared time did not trigger an immediate recheck"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  escalations=$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')
  [ "$escalations" -eq 2 ] || fail "a reached declared time bypassed the reset pause cadence"
  pass "housekeeping bounds a distant declared time, defers to a near one, and rechecks a passed one at once"
}

# A pane still idle but whose status is no longer a pause (the crew changed state
# without becoming busy) drops the marker - the signal path owns the new state, so
# the pause recheck must not re-surface a stale pause reason.
test_housekeeping_paused_unpaused_cleared() {
  local dir state fakebin win pane key
  dir=$(make_supercase paused-unpaused)
  state="$dir/state"; fakebin="$dir/fakebin"
  win="sess:fm-held-w13"; pane="$dir/pane.txt"
  printf 'paused: holding for the upstream release\nworking: resumed, upstream landed\n' > "$state/held-w13.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w13" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] && fail "no-longer-paused marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a crew that left its pause was re-surfaced as a pause"
  pass "housekeeping clears a paused marker once the crew is no longer declaring the pause"
}

# Once the captain answers, the hold is no longer a declared wait: the resolved line
# takes over the last-line read, so the pause cadence must stop claiming the task
# rather than keep re-surfacing a settled decision.
test_housekeeping_captain_held_resolved_cleared() {
  local dir state fakebin win pane key
  dir=$(make_supercase captain-held-resolved)
  state="$dir/state"; fakebin="$dir/fakebin"
  win="sess:fm-held-w13h"; pane="$dir/pane.txt"
  printf 'captain-held [key=route]: tracked by task-decision-route\nresolved [key=route]: captain chose the direct path\n' > "$state/held-w13h.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w13h" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] && fail "an answered captain hold kept its pause marker"
  [ ! -s "$state/.subsuper-escalations" ] || fail "an answered captain hold was re-surfaced as a declared wait"
  pass "housekeeping clears the pause marker once a captain hold is answered"
}

test_housekeeping_stale_marker_transitions_to_pause() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-to-paused)
  state="$dir/state"; fakebin="$dir/fakebin"; win="sess:fm-held-w14"; pane="$dir/pane.txt"
  printf 'paused: awaiting the upstream tool release\n' > "$state/held-w14.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w14" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] || fail "existing stale marker did not move to paused state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "existing stale marker remained wedge-aged after pause"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a newly declared pause was escalated as a possible wedge"
  pass "housekeeping moves an existing stale marker to pause before wedge escalation"
}

# The quieting half for a captain hold. A finished task marked captain-held is idle by
# design, so an already-aged wedge marker converts to pause tracking on the next sweep
# instead of firing the possible-wedge escalation.
test_housekeeping_captain_held_stale_marker_transitions_to_pause() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-to-captain-held)
  state="$dir/state"; fakebin="$dir/fakebin"; win="sess:fm-held-w14h"; pane="$dir/pane.txt"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$state/held-w14h.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w14h" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] || fail "a captain hold did not move its stale marker to pause tracking"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "a captain hold remained wedge-aged"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a captain hold was escalated as a possible wedge"
  pass "housekeeping moves a captain hold's existing stale marker to pause before wedge escalation"
}

test_housekeeping_pause_marker_transitions_to_clear() {
  local dir state fakebin win pane key
  dir=$(make_supercase paused-to-stale)
  state="$dir/state"; fakebin="$dir/fakebin"; win="sess:fm-held-w15"; pane="$dir/pane.txt"
  printf 'working: upstream landed, resuming\n' > "$state/held-w15.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w15" | tr ':/.' '___')
  date +%s > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=999999 housekeeping "$state"
  [ ! -e "$state/.subsuper-paused-$key" ] || fail "pause marker remained after the crew resumed"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "resume retained normal stale tracking"
  [ ! -s "$state/.subsuper-escalations" ] || fail "resuming from pause escalated immediately"
  pass "housekeeping clears tracking when a crew leaves pause"
}

test_housekeeping_persistent_stale_escalates() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-persistent)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-pers-w5"
  pane="$dir/pane.txt"
  printf 'working\n' > "$state/pers-w5.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "pers-w5" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"
  pass "persistent stale escalates after threshold and clears its marker"
}

test_housekeeping_resumed_stale_cleared() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-resumed)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-res-w6"
  pane="$dir/pane.txt"
  printf 'working\n' > "$state/res-w6.status"
  printf 'Working...\n' > "$pane"
  # A resumed crew proves it is working through its own semantic busy-state
  # record (bin/fm-busy-lib.sh), not through the pane's rendered footer.
  fm_write_meta "$state/res-w6.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" res-w6)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" res-w6 busy --gen "$gen" \
    --source pi-ext --event agent-start
  key=$(printf '%s' "res-w6" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-stale-$key" ] && fail "resumed stale marker was not cleared"
  [ -s "$state/.subsuper-escalations" ] && fail "resumed stale was escalated"
  pass "resumed (busy) stale clears its marker without escalating"
}

test_housekeeping_herdr_persistent_stale_resolves_meta() {
  local dir state key
  dir=$(make_supercase stale-herdr-persistent)
  state="$dir/state"
  fm_write_meta "$state/herdr-w7.meta" "window=default:w1:p2" "backend=herdr"
  printf 'working\n' > "$state/herdr-w7.status"
  key=$(printf '%s' "herdr-w7" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  (
    fm_backend_capture() {
      [ "$1" = herdr ] || fail "expected herdr capture backend, got $1"
      [ "$2" = "default:w1:p2" ] || fail "expected herdr window target, got $2"
      printf 'idle prompt\n'
    }
    fm_backend_busy_state() {
      [ "$1" = herdr ] || fail "expected herdr busy backend, got $1"
      [ "$2" = "default:w1:p2" ] || fail "expected herdr busy target, got $2"
      printf 'idle'
    }
    fm_backend_capture herdr default:w1:p2 40 >/dev/null
    [ "$(fm_backend_busy_state herdr default:w1:p2)" = idle ] || fail "herdr busy stub did not report idle"
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  ) || fail "herdr persistent stale housekeeping failed"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent herdr stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "herdr stale marker not cleared after escalation"
  pass "persistent herdr stale resolves the target from metadata and escalates"
}

# A herdr crew whose native agent.get reads idle (generation state) but whose
# own semantic busy-state record says busy is still working, so its stale
# marker clears without escalating. The record - not the pane's rendered
# footer - is what proves it.
test_housekeeping_herdr_idle_busy_record_clears_stale() {
  local dir state key gen
  dir=$(make_supercase stale-herdr-idle-busy-record)
  state="$dir/state"
  fm_write_meta "$state/herdr-footer.meta" "window=default:w1:p4" "backend=herdr" "harness=claude"
  printf 'working\n' > "$state/herdr-footer.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" herdr-footer)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" herdr-footer busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  key=$(printf '%s' "herdr-footer" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  (
    fm_backend_capture() {
      [ "$1" = herdr ] || fail "expected herdr capture backend, got $1"
      [ "$2" = "default:w1:p4" ] || fail "expected herdr window target, got $2"
      printf 'quiet\n'
    }
    fm_backend_busy_state() {
      [ "$1" = herdr ] || fail "expected herdr busy backend, got $1"
      [ "$2" = "default:w1:p4" ] || fail "expected herdr busy target, got $2"
      printf 'idle'
    }
    fm_backend_capture herdr default:w1:p4 40 >/dev/null
    [ "$(fm_backend_busy_state herdr default:w1:p4)" = idle ] || fail "herdr busy stub did not report idle"
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  ) || fail "herdr idle busy-footer housekeeping failed"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "idle-native busy-record herdr stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "idle-native busy-record herdr stale was escalated"
  pass "herdr idle busy-footer stale clears through capture corroboration"
}

test_housekeeping_herdr_resumed_stale_cleared() {
  local dir state key
  dir=$(make_supercase stale-herdr-resumed)
  state="$dir/state"
  fm_write_meta "$state/herdr-busy.meta" "window=default:w1:p3" "backend=herdr"
  printf 'working\n' > "$state/herdr-busy.status"
  key=$(printf '%s' "herdr-busy" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  (
    fm_backend_capture() {
      [ "$1" = herdr ] || fail "expected herdr capture backend, got $1"
      [ "$2" = "default:w1:p3" ] || fail "expected herdr window target, got $2"
      printf 'unchanged pane\n'
    }
    fm_backend_busy_state() {
      [ "$1" = herdr ] || fail "expected herdr busy backend, got $1"
      [ "$2" = "default:w1:p3" ] || fail "expected herdr busy target, got $2"
      printf 'busy'
    }
    fm_backend_capture herdr default:w1:p3 40 >/dev/null
    [ "$(fm_backend_busy_state herdr default:w1:p3)" = busy ] || fail "herdr busy stub did not report busy"
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  ) || fail "herdr resumed stale housekeeping failed"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "busy herdr stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "busy herdr stale was escalated"
  pass "resumed herdr stale clears through backend-aware busy state"
}

test_housekeeping_orca_persistent_stale_resolves_terminal() {
  local dir state key
  dir=$(make_supercase stale-orca-persistent)
  state="$dir/state"
  fm_write_meta "$state/orca-w8.meta" "window=fm-orca-w8" "terminal=term-orca-w8" "backend=orca"
  printf 'working\n' > "$state/orca-w8.status"
  key=$(printf '%s' "orca-w8" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  (
    fm_backend_capture() {
      [ "$1" = orca ] || fail "expected orca capture backend, got $1"
      [ "$2" = "term-orca-w8" ] || fail "expected Orca terminal target, got $2"
      printf 'idle prompt\n'
    }
    fm_backend_busy_state() {
      [ "$1" = orca ] || fail "expected orca busy backend, got $1"
      [ "$2" = "term-orca-w8" ] || fail "expected Orca busy target, got $2"
      printf 'idle'
    }
    fm_backend_capture orca term-orca-w8 40 >/dev/null
    [ "$(fm_backend_busy_state orca term-orca-w8)" = idle ] || fail "Orca busy stub did not report idle"
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  ) || fail "Orca persistent stale housekeeping failed"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent Orca stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "Orca stale marker not cleared after escalation"
  pass "persistent Orca stale resolves the terminal from metadata"
}

test_escalate_batches_into_one_digest() {
  local dir state fakebin sent capture n record
  dir=$(make_supercase batch)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf '\342\235\257 \n' > "$capture"  # a proven-empty bare claude composer: STRICT injection needs positive proof
  escalate_add "$state" "event A: done: PR 1"
  escalate_add "$state" "event B: done: PR 2"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed"
  # A Claude Code primary strips U+2063 from submitted prompts, so the digest
  # travels as a record in this home's operational inbox behind a plain doorbell.
  record=$(sed -n "s/.*: Firstmate operational input waiting: read '\([^']*\)'.*/\1/p" "$sent" | head -1)
  [ -n "$record" ] || fail "batch digest was not typed as a record-backed doorbell for the claude primary: $(cat "$sent")"
  grep -F "$FM_OPERATIONAL_MARK" "$sent" >/dev/null \
    && fail "the claude primary was typed the invisible marker it strips"
  [ "$(cd "$(dirname "$record")" && pwd -P)" = "$(cd "$state/operational-inbox" && pwd -P)" ] \
    || fail "the doorbell names a record outside this home's operational inbox: $record"
  grep -F "${FM_OPERATIONAL_PREFIX}v1 away-supervisor: " "$record" >/dev/null \
    || fail "the digest record lacks the exact current away-supervisor envelope"
  grep -F "event A" "$record" >/dev/null || fail "batch digest missing event A"
  grep -F "event B" "$record" >/dev/null || fail "batch digest missing event B"
  grep -F 'event A: done: PR 1 | event B: done: PR 2' "$record" >/dev/null \
    || fail "batch digest did not join events with literal ' | '"
  [ -s "$state/.subsuper-escalations" ] && fail "escalation buffer not cleared after flush"
  [ -e "$state/.subsuper-escalations.since" ] && fail "first-append sidecar not cleared after flush"
  n=$(grep -c '\[ENTER\]' "$sent")
  [ "$n" -eq 1 ] || fail "expected one injected digest, got $n send-keys submits"
  pass "multiple escalations flush as a single batched digest"
}

test_escalate_marker_preserving_primary_types_envelope() {
  local dir state fakebin sent capture
  dir=$(make_supercase batch-typed-envelope)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf '\342\235\257 \n' > "$capture"
  escalate_add "$state" "event C: done: PR 3"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 FM_DAEMON_PRIMARY_HARNESS=codex \
    escalate_flush "$state" || fail "escalate_flush failed for a marker-preserving primary"
  grep -F "${FM_OPERATIONAL_PREFIX}v1 away-supervisor: " "$sent" >/dev/null \
    || fail "a marker-preserving primary lost the typed away-supervisor envelope"
  grep -F 'event C: done: PR 3' "$sent" >/dev/null || fail "typed digest missing event C"
  grep -F 'Firstmate operational input waiting' "$sent" >/dev/null \
    && fail "a marker-preserving primary was sent a record-backed doorbell"
  [ ! -e "$state/operational-inbox" ] || fail "a marker-preserving primary published an operational record"
  pass "a marker-preserving primary still receives the typed U+2063 away-supervisor envelope and no record"
}

test_record_doorbell_detection() {
  local dir state other doorbell stray missing
  dir=$(make_supercase doorbell-detect)
  state="$dir/state"
  other="$dir/other-state"
  mkdir -p "$other"
  afk_enter "$state"
  fm_operational_record_write "$state" away-supervisor "Supervisor escalate: done" doorbell \
    || fail "could not publish an away-supervisor record"
  message_is_injection "$doorbell" "$state" \
    || fail "a doorbell for this home's own record was not detected as an injection"
  should_exit_afk "$state" "$doorbell" \
    && fail "a doorbell for this home's own record exited afk"
  fm_operational_record_write "$other" away-supervisor "Supervisor escalate: done" stray \
    || fail "could not publish another home's record"
  should_exit_afk "$state" "$stray" \
    || fail "a doorbell naming another home's record kept afk"
  missing=${doorbell%.msg\'*}-gone.msg${doorbell##*.msg}
  should_exit_afk "$state" "$missing" \
    || fail "a doorbell naming no record kept afk"
  should_exit_afk "$state" "FIRSTMATE_OP: v1 away-supervisor: Supervisor escalate: done" \
    || fail "a typed ASCII FIRSTMATE_OP label kept afk"
  rm -f "$state"/operational-inbox/*.msg
  should_exit_afk "$state" "$doorbell" \
    || fail "a doorbell whose record was pruned kept afk"
  pass "record-backed doorbell: only a doorbell naming this home's own record stays afk; a bare ASCII label, a missing record, and another home's record exit"
}

test_escalate_batch_age_uses_first_append() {
  local dir state fakebin sent capture
  dir=$(make_supercase batch-age)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf '\342\235\257 \n' > "$capture"  # a proven-empty bare claude composer: STRICT injection needs positive proof
  escalate_add "$state" "event A: done: PR 1"
  escalate_add "$state" "event B: done: PR 2"
  echo $(( $(date +%s) - 100 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=90 FM_HOUSEKEEPING_TICK=0 \
    housekeeping "$state"
  delivered_digest "$sent" | grep -F 'event A: done: PR 1 | event B: done: PR 2' >/dev/null \
    || fail "backdated batch did not flush as a joined digest (max-delay measured from last append)"
  [ -s "$state/.subsuper-escalations" ] && fail "escalation buffer not cleared after backdated flush"
  [ -e "$state/.subsuper-escalations.since" ] && fail "first-append sidecar not cleared after flush"
  pass "batch flush measures max-delay from the first append, not the last"
}

test_heartbeat_scan_dedup() {
  local dir state
  dir=$(make_supercase scan-dedup)
  state="$dir/state"
  printf 'done: ready\n' > "$state/dup-t6.status"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "catch-all scan did not escalate a terminal"
  : > "$state/.subsuper-escalations"
  echo $(( $(date +%s) - 99999 )) > "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "catch-all scan re-escalated the same terminal (dedup failed)"
  pass "catch-all scan escalates a missed terminal once, not twice"
}

test_handle_wake_routes_self_and_escalate() {
  local dir state
  dir=$(make_supercase handle)
  state="$dir/state"
  printf 'working\n' > "$state/h-routine.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/h-routine.status" "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "routine signal was escalated by handle_wake"
  printf 'done: PR 1\n' > "$state/h-done.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/h-done.status" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain signal was not buffered by handle_wake"
  pass "handle_wake routes routine->self and captain->escalate"
}

# Decision-owned queued rows are marked needs-decision:<files> by the watcher.
# The away-mode daemon must classify that payload the same way it classifies an
# ordinary signal: escalate once as the decision, suppress an unchanged repeat
# (queued-row and catch-all alike), and re-escalate when the status log grows.
# https://github.com/kunchenguid/firstmate/issues/4096
test_needs_decision_queued_row_escalates_once_as_the_decision() {
  local dir state fakebin status_file payload out
  dir=$(make_supercase needs-decision-queued-row)
  state="$dir/state"
  fakebin="$dir/daemon-bin"
  mkdir -p "$fakebin"
  status_file="$state/decision-task.status"
  printf 'working: setup\nneeds-decision [key=release]: pick A or B\n' > "$status_file"
  payload="needs-decision: $status_file"
  cat > "$fakebin/fm-wake-drain.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --ack-through ]; then printf '%s\n' ack >> "$dir/acked"; exit 0; fi
printf '1\t1\tsignal\tdecision-task.status\t%s\n' "$payload"
printf 'WAKE_ACK_REQUIRED: retry --ack-through 1 --recovery-generation gen\n' >&2
EOF
  chmod +x "$fakebin/fm-wake-drain.sh"

  FM_DAEMON_DIR="$fakebin" FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999 \
    handle_durable_wakes fallback "$state" \
    || fail "the first decision-owned queued row was not handled"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in
    *"unknown wake:"*) fail "a decision-owned wake was labelled unknown: $out" ;;
  esac
  case "$out" in
    *"needs-decision [key=release]: pick A or B"*) ;;
    *) fail "the first decision-owned wake was not presented as the decision: $out" ;;
  esac
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" = 1 ] \
    || fail "the first decision-owned wake did not escalate exactly once: $out"

  : > "$state/.subsuper-escalations"
  FM_DAEMON_DIR="$fakebin" FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999 \
    handle_durable_wakes fallback "$state" \
    || fail "an unchanged decision-owned repeat was not handled"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "an unchanged open decision re-escalated: $(cat "$state/.subsuper-escalations")"

  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "the catch-all scan re-escalated an already-surfaced open decision: $(cat "$state/.subsuper-escalations")"

  printf 'needs-decision [key=release]: pick A, C, or D\n' >> "$status_file"
  : > "$state/.subsuper-escalations"
  FM_DAEMON_DIR="$fakebin" FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999 \
    handle_durable_wakes fallback "$state" \
    || fail "a changed decision-owned wake was not handled"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in
    *"unknown wake:"*) fail "a changed decision-owned wake was labelled unknown: $out" ;;
  esac
  case "$out" in
    *"needs-decision [key=release]: pick A, C, or D"*) ;;
    *) fail "a later status change did not re-escalate the decision: $out" ;;
  esac

  : > "$state/.subsuper-escalations"
  printf 'working: still going\n' > "$state/ordinary-routine.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/ordinary-routine.status" "$state"
  [ -s "$state/.subsuper-escalations" ] \
    && fail "an ordinary routine signal was escalated: $(cat "$state/.subsuper-escalations")"
  printf 'done: PR https://example.test/pull/1\n' > "$state/ordinary-done.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/ordinary-done.status" "$state"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in
    *"done: PR https://example.test/pull/1"*) ;;
    *) fail "an ordinary captain-relevant signal lost its escalate behaviour: $out" ;;
  esac
  case "$out" in
    *"unknown wake:"*) fail "an ordinary signal was labelled unknown: $out" ;;
  esac

  pass "a decision-owned queued row escalates once as the decision, then suppresses until the status changes"
}

# The watcher also marks a row decision-owned when its only new line is a
# captain-held transfer. fm-captain-hold.sh complete writes that line through the
# self-announced append and the hold stays durable in the backlog, so the daemon
# self-handles the row like any other captain-held line, now and on repeat.
test_captain_held_decision_owned_row_is_self_handled() {
  local dir state fakebin status_file
  dir=$(make_supercase captain-held-decision-owned-row)
  state="$dir/state"
  fakebin="$dir/daemon-bin"
  mkdir -p "$fakebin"
  status_file="$state/held-task.status"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$status_file"
  cat > "$fakebin/fm-wake-drain.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --ack-through ]; then exit 0; fi
printf '1\t1\tsignal\theld-task.status\t%s\n' "needs-decision: $status_file"
printf 'WAKE_ACK_REQUIRED: retry --ack-through 1 --recovery-generation gen\n' >&2
EOF
  chmod +x "$fakebin/fm-wake-drain.sh"

  FM_DAEMON_DIR="$fakebin" FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999 \
    handle_durable_wakes fallback "$state" \
    || fail "the captain-held decision-owned row was not handled"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "a captain-held decision-owned row escalated: $(cat "$state/.subsuper-escalations")"

  FM_DAEMON_DIR="$fakebin" FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999 \
    handle_durable_wakes fallback "$state" \
    || fail "an unchanged captain-held decision-owned repeat was not handled"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "an unchanged captain-held decision-owned repeat escalated: $(cat "$state/.subsuper-escalations")"

  pass "a captain-held decision-owned row is self-handled without escalation, now and on repeat"
}

test_inject_skip_forces_self() {
  local dir state
  dir=$(make_supercase skip)
  state="$dir/state"
  printf 'done: PR 1\n' > "$state/s1.status"
  FM_STATE_OVERRIDE="$state" FM_INJECT_SKIP="signal" handle_wake "signal: $state/s1.status" "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "INJECT_SKIP=signal did not force self-handle"
  pass "INJECT_SKIP forces self-handle, bypassing captain-relevant classification"
}

test_is_wake_reason_distinguishes_status_stdout() {
  # Real wake reasons are recognized; watcher status lines (singleton collision)
  # are not, so the main loop can idle them without flooding escalations.
  is_wake_reason "signal: /x/y.status" || fail "signal: not recognized as wake"
  is_wake_reason "stale: s:fm-x" || fail "stale: not recognized as wake"
  is_wake_reason "check: /s/c.sh: merged" || fail "check: not recognized as wake"
  is_wake_reason "heartbeat" || fail "heartbeat not recognized as wake"
  is_wake_reason "watcher: already running" && fail "singleton status line misclassified as wake"
  is_wake_reason "watcher: already running pid 123" && fail "singleton status (pid) misclassified as wake"
  pass "is_wake_reason distinguishes watcher wake reasons from singleton-status stdout"
}

test_terminal_stale_escalate_leaves_no_marker() {
  local dir state win key
  dir=$(make_supercase stale-terminal-nomarker)
  state="$dir/state"
  win="sess:fm-fin-n7"
  printf 'done: PR https://x/y/pull/7\n' > "$state/fin-n7.status"
  key=$(printf '%s' "fin-n7" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "terminal stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "terminal stale left a persistence marker (housekeeping would re-escalate)"
  : > "$state/.subsuper-escalations"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "housekeeping re-escalated a terminal stale as a wedge"
  pass "terminal-stale escalate removes its marker so housekeeping does not re-escalate"
}

test_signal_escalate_marks_seen_no_catchall_refire() {
  local dir state key
  dir=$(make_supercase signal-seen)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/8\n' > "$state/sig-t8.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/sig-t8.status" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain signal was not escalated"
  key=$(printf '%s' "sig-t8" | tr ':/.' '___')
  [ "$(status_seen_offset "$state" sig-t8)" = "$(log_size "$state/sig-t8.status")" ] \
    || fail "captain signal escalate did not record the escalated-through offset"
  : > "$state/.subsuper-escalations"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "catch-all scan re-fired an already-escalated signal"
  pass "captain signal escalate marks seen so the catch-all scan does not re-fire"
}

test_collapse_newlines_pure() {
  local out
  out=$(_collapse_newlines $'line one\nline two\nline three')
  [ "$out" = "line one - line two - line three" ] || fail "collapse failed: '$out'"
  out=$(_collapse_newlines "no newlines here")
  [ "$out" = "no newlines here" ] || fail "collapse changed no-newline text"
  out=$(_collapse_newlines $'a\nb')
  [ "$out" = "a - b" ] || fail "collapse two lines failed: '$out'"
  pass "_collapse_newlines replaces newlines with literal separator"
}

test_afk_absent_daemon_does_not_inject() {
  local dir state fakebin sent capture
  dir=$(make_supercase afk-off)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf '\342\235\257 \n' > "$capture"  # a proven-empty bare claude composer: STRICT injection needs positive proof
  escalate_add "$state" "done: PR 1"
  # afk flag deliberately NOT set
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush succeeded while afk inactive"
  fi
  [ -s "$sent" ] && fail "daemon injected while afk inactive"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when afk inactive"
  pass "afk flag absent: daemon does not inject, buffer preserved"
}

test_busy_guard_defers_when_supervisor_busy() {
  local dir state fakebin sent capture
  dir=$(make_supercase busy-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  printf 'esc to interrupt\n' > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush should defer when supervisor pane busy"
  fi
  [ -s "$sent" ] && fail "daemon injected into a busy pane"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when deferred"
  pass "busy-guard defers injection when supervisor pane is busy"
}

test_marker_detection() {
  local marker_hex
  marker_hex=$(printf '%s' "$FM_INJECT_MARK" | od -An -tx1 | tr -d ' \n')
  [ "$marker_hex" = e281a3 ] \
    || fail "FM_INJECT_MARK must use terminal-safe U+2063 bytes, got $marker_hex"
  [ "$FM_OPERATIONAL_PREFIX" = "${FM_INJECT_MARK}FIRSTMATE_OP: " ] \
    || fail "away-mode operational prefix drifted from the shared captain-boundary marker"
  # message_is_injection: marker present -> injection; absent -> real message
  message_is_injection "${FM_OPERATIONAL_PREFIX}Supervisor escalate: done" \
    || fail "operationally-prefixed message not detected as injection"
  message_is_injection "${FM_INJECT_MARK}Supervisor escalate: done" \
    || fail "legacy marker-prefixed message not detected as injection"
  message_is_injection "how's it going?" \
    && fail "plain message misdetected as injection"
  message_is_injection "" && fail "empty message misdetected as injection"
  # should_exit_afk: the full afk-exit contract
  local dir state
  dir=$(make_supercase marker-detect)
  state="$dir/state"
  afk_enter "$state"
  should_exit_afk "$state" "${FM_INJECT_MARK}escalate" \
    && fail "marker message should not exit afk (internal escalation)"
  should_exit_afk "$state" "status update please" \
    || fail "plain message should exit afk (captain is back)"
  pass "marker detection: marker -> stay afk, no marker -> exit afk"
}

test_afk_turn_exemption() {
  local dir state
  dir=$(make_supercase afk-exempt)
  state="$dir/state"
  afk_enter "$state"
  # /afk while already away must NOT self-cancel (re-entering/extending)
  should_exit_afk "$state" "/afk" \
    && fail "bare /afk should not exit afk"
  should_exit_afk "$state" "/afk back in an hour" \
    && fail "/afk with args should not exit afk"
  # a non-/afk skill invocation DOES exit (the captain is actively working)
  should_exit_afk "$state" "/no-mistakes" \
    || fail "non-afk skill should exit afk"
  pass "/afk invocation is exempt from afk exit (no self-cancel)"
}

test_should_exit_afk_when_afk_inactive() {
  local dir state
  dir=$(make_supercase no-afk)
  state="$dir/state"
  # afk flag absent: should never signal exit (nothing to exit)
  should_exit_afk "$state" "hello" \
    && fail "should_exit_afk true when afk inactive"
  should_exit_afk "$state" "${FM_INJECT_MARK}test" \
    && fail "should_exit_afk true when afk inactive (marker)"
  pass "should_exit_afk returns false when afk is not active"
}

test_strip_injection_marker() {
  local encoded stripped
  fm_operational_input_encode away-supervisor "Supervisor escalate: done" encoded \
    || fail "could not encode current away fixture"
  stripped=$(strip_injection_marker "$encoded")
  [ "$stripped" = "Supervisor escalate: done" ] \
    || fail "current typed operational envelope not stripped: '$stripped'"
  stripped=$(strip_injection_marker "${FM_OPERATIONAL_PREFIX}Supervisor escalate: done")
  [ "$stripped" = "Supervisor escalate: done" ] \
    || fail "landed untyped operational prefix not stripped: '$stripped'"
  stripped=$(strip_injection_marker "${FM_INJECT_MARK}Supervisor escalate: done")
  [ "$stripped" = "Supervisor escalate: done" ] \
    || fail "legacy marker not stripped: '$stripped'"
  # No marker → unchanged.
  stripped=$(strip_injection_marker "no marker here")
  [ "$stripped" = "no marker here" ] \
    || fail "non-marker text changed: '$stripped'"
  # Empty → empty.
  stripped=$(strip_injection_marker "")
  [ "$stripped" = "" ] || fail "empty text changed: '$stripped'"
  # Only marker → empty.
  stripped=$(strip_injection_marker "$FM_INJECT_MARK")
  [ "$stripped" = "" ] || fail "bare marker not stripped: '$stripped'"
  pass "strip_injection_marker removes the sentinel marker cleanly"
}

test_pane_input_pending_detects_partial_input() {
  local dir state fakebin capture
  dir=$(make_supercase pending-input)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Line 3 (cursor_y=2) has human's partial text (no Enter) → pending.
  printf 'line one\nline two\nhuman draft text\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    || fail "pane_input_pending should detect non-empty composer (human text)"
  pass "pane_input_pending detects partial input on the cursor line"
}

test_pane_input_pending_blank_defers_strict() {
  # THE STRICT BLANK-ROW RULE (captain decision blank-row-injection-posture,
  # 2026-08-09): a blank cursor row with no positive container proof is
  # `unknown` and the injector DEFERS. The permissive rule this replaced read
  # the same row as `empty` and injected - into whatever the blank row really
  # was (a modal dialog, a dead shell between stale transcript rules, a
  # mid-redraw pane). This assertion IS the posture divergence: if it ever
  # reads not-pending again, the permissive rule has silently returned.
  local dir state fakebin capture
  dir=$(make_supercase pending-blank)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf 'some output\nmore output\n\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    || fail "a blank unidentified cursor row must defer under the strict rule, not read empty"
  pass "pane_input_pending: a blank unidentified cursor row defers (strict container-proof rule)"
}

test_pane_input_pending_requires_proven_empty_prompt() {
  local dir state fakebin capture prompt
  dir=$(make_supercase pending-prompt)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  for prompt in '$' '>'; do
    printf 'output\noutput\n%s \n' "$prompt" > "$capture"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
      pane_input_pending "fakepane" \
      || fail "bare shell prompt '$prompt' should defer as unknown"
  done
  for prompt in '❯' '›'; do
    printf 'output\noutput\n%s \n' "$prompt" > "$capture"
    if PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
      pane_input_pending "fakepane"; then
      fail "proven empty agent prompt '$prompt' should not defer"
    fi
  done
  pass "pane_input_pending: only proven empty agent prompts pass"
}

# The safety fix at the tmux classifier (task fm-composer-shellglyph-safety): a
# bare, unbordered shell prompt is a dead shell (the agent exited to its login
# shell), NOT an empty agent composer. It must read `unknown` (unsafe target),
# never `empty`. Before this fix a dead-shell pane read `empty` and the away-mode
# injector could type (and a shell could execute) an escalation there.
test_tmux_composer_state_bare_shell_is_unknown() {
  local dir fakebin capture g out
  dir=$(make_supercase composer-bare-shell)
  fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  for g in '$' '%' '#' '>'; do
    printf 'output\noutput\n%s \n' "$g" > "$capture"
    out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = unknown ] \
      || fail "bare shell prompt '$g' must classify unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_tmux_composer_state: a bare shell prompt (\$/%/#/>) reads unknown, never empty (dead-shell injection safety)"
}

# The other side of the fix: a bordered composer box (the harness draws its own
# prompt glyph inside it) and a bare AGENT prompt glyph (claude ❯, codex ›) are
# genuine empty agent composers and must still read `empty`.
test_tmux_composer_state_bordered_and_agent_rows_are_empty() {
  local dir fakebin capture out
  dir=$(make_supercase composer-empty-agent)
  fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  printf '╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯\n' > "$capture"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "a bordered '│ > │' composer should read empty, got '$out'"
  printf '%s\n' "❯ " > "$capture"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "a bare claude '❯' composer should read empty, got '$out'"
  printf '%s\n' "› " > "$capture"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "a bare codex '›' composer should read empty, got '$out'"
  pass "fm_tmux_composer_state: a bordered composer box and bare agent glyphs (❯/›) still read empty"
}

test_tmux_composer_state_requires_matching_box_borders() {
  local dir fakebin capture line out
  dir=$(make_supercase composer-decorated-shell)
  fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  for line in '| $ ' '$ |' '│ % ' '# ┃'; do
    printf '%s\n' "$line" > "$capture"
    out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
      fm_tmux_composer_state "fakepane")
    [ "$out" != empty ] \
      || fail "a decorated shell prompt '$line' must not read as an empty composer"
  done
  pass "fm_tmux_composer_state: only matching edge borders form a composer box"
}

test_pane_input_pending_preserves_bright_placeholder_like_draft() {
  local dir fakebin capture
  dir=$(make_supercase pending-custom-idle)
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf '╭────────────────╮\n│ custom idle>   │\n╰────────────────╯\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=1 \
    FM_COMPOSER_IDLE_RE='^custom idle>$' pane_input_pending "fakepane" \
    || fail "bright placeholder-like input must remain pending in a styled capture"
  pass "pane_input_pending preserves bright placeholder-like drafts in styled captures"
}

test_classify_signal_dedup_against_scan() {
  # If the catch-all scan already escalated a status (seen marker matches),
  # classify_signal must self-handle to avoid a duplicate in the digest.
  local dir state key out
  dir=$(make_supercase signal-dedup)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/9\n' > "$state/dup-s9.status"
  # Simulate the catch-all scan having already escalated this status.
  key=$(printf '%s' "dup-s9" | tr ':/.' '___')
  seen_through "$state" "dup-s9"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/dup-s9.status" "$state")
  case "$out" in self\|*) ;; *) fail "signal not deduped against scan: $out" ;; esac
  # Without the seen marker, it should escalate.
  rm -f "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/dup-s9.status" "$state")
  case "$out" in escalate\|*) ;; *) fail "signal should escalate when not seen: $out" ;; esac
  pass "classify_signal dedupes against the catch-all scan seen marker"
}

test_classify_stale_dedup_against_signal() {
  # If the signal path already escalated a status (seen marker matches),
  # classify_stale must self-handle to avoid a duplicate in the digest.
  local dir state key out
  dir=$(make_supercase stale-dedup)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/10\n' > "$state/dup-s10.status"
  key=$(printf '%s' "dup-s10" | tr ':/.' '___')
  seen_through "$state" "dup-s10"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-dup-s10" "$state")
  case "$out" in self\|*) ;; *) fail "stale not deduped against signal: $out" ;; esac
  # Without the seen marker, it should escalate.
  rm -f "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-dup-s10" "$state")
  case "$out" in escalate\|*) ;; *) fail "stale should escalate when not seen: $out" ;; esac
  pass "classify_stale dedupes against the signal path seen marker"
}

# AFK incident regression: a nonterminal working: line that was already surfaced
# (seen marker matches, including free-text "merged") must keep possible-wedge
# aging. handle_wake must record the stale marker; housekeeping re-escalates
# once at the configured bound.
test_afk_nonterminal_working_merged_keeps_wedge_aging() {
  local dir state key out win pane incident fakebin
  dir=$(make_supercase afk-working-merged-wedge)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-wishlist-w1"
  pane="$dir/pane.txt"
  incident='working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved'
  printf '%s\n' "$incident" > "$state/wishlist-w1.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "wishlist-w1" | tr ':/.' '___')
  # Simulate an earlier false-positive escalate that wrote the seen marker.
  seen_through "$state" "wishlist-w1"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "$win" "$state")
  case "$out" in
    self\|*transient*) ;;
    escalate\|*) fail "nonterminal working: escalated as terminal stale: $out" ;;
    *)
      case "$out" in
        *already\ escalated*) fail "nonterminal working: treated as already-escalated terminal: $out" ;;
        *) fail "nonterminal working: unexpected classify_stale: $out" ;;
      esac
      ;;
  esac
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ -e "$state/.subsuper-stale-$key" ] \
    || fail "wedge stale marker was not recorded for already-seen nonterminal working:"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "nonterminal working: stale incorrectly escalated immediately"
  # Age the marker past the escalate bound (marker stores first-seen epoch).
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "housekeeping did not re-escalate aged nonterminal working: wedge"
  grep -q 'possible wedge' "$state/.subsuper-escalations" \
    || fail "housekeeping escalate was not a possible-wedge: $(cat "$state/.subsuper-escalations")"
  pass "AFK nonterminal working:+merged keeps wedge aging and re-escalates at bound"
}

test_afk_genuine_done_still_terminal_stale() {
  local dir state out
  dir=$(make_supercase afk-genuine-done-stale)
  state="$dir/state"
  printf 'done: PR https://example.com/pull/76 checks green; stage 1 of 4 ready for firstmate merge\n' \
    > "$state/stage1-w2.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-stage1-w2" "$state")
  case "$out" in escalate\|*) ;; *) fail "genuine done: stale did not escalate: $out" ;; esac
  out=$(classify_check "check: /s/t.check.sh: merged")
  case "$out" in escalate\|*) ;; *) fail "validated merge-check did not escalate: $out" ;; esac
  pass "genuine done: and merge-check events still escalate"
}

test_pane_input_pending_bordered_idle_not_pending() {
  # THE regression: an idle claude composer is a bordered box ("│ > … │"). The
  # old idle regex only matched a BARE prompt, so every idle claude pane read as
  # pending and the away-mode daemon deferred 100% of escalations for 9.5h.
  local dir state fakebin capture line
  dir=$(make_supercase pending-bordered-idle)
  state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  for line in '>' '❯' ''; do
    case "$line" in
      '>') printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$capture" ;;
      '❯') printf '╭────────────╮\n│ ❯          │\n╰────────────╯\n' > "$capture" ;;
      '') printf '╭────────────╮\n│            │\n╰────────────╯\n' > "$capture" ;;
    esac
    if PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=1 \
      pane_input_pending "fakepane"; then
      fail "bordered idle composer falsely detected as pending: <$line>"
    fi
  done
  pass "pane_input_pending: an idle bordered composer is NOT pending (afk-invx-i5)"
}

test_pane_input_pending_bordered_with_text_is_pending() {
  # Guard against over-broadening: real unsubmitted text inside the box must
  # still read as pending so the daemon defers (and the captain-return race is
  # still protected).
  local dir state fakebin capture
  dir=$(make_supercase pending-bordered-text)
  state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  printf '╭────────────────────────────────────────────────╮\n│ > fix findings 1 and 3, skip 2                 │\n╰────────────────────────────────────────────────╯\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=1 \
    pane_input_pending "fakepane" \
    || fail "real text inside a bordered composer was not detected as pending"
  pass "pane_input_pending: text inside a bordered composer is still pending"
}

test_submit_ack_confirms_on_bordered_empty_composer() {
  # RC2: the submit acknowledgement must recognize a bordered-EMPTY composer as
  # "submitted." The old ACK reused the broken check, so on claude it could never
  # confirm and always reported a false "Enter swallowed."
  local dir fakebin sent verdict
  dir=$(make_bordered_case ack-bordered)
  fakebin="$dir/fakebin"; sent="$dir/sent.log"; : > "$sent"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    fm_tmux_submit_core "win" "the digest" 3 0.05 0.05)
  [ "$verdict" = empty ] || fail "submit-ACK did not confirm on a bordered-empty composer: $verdict"
  [ "$(grep -cv '\[ENTER\]' "$sent")" -eq 1 ] || fail "digest typed more than once (retype)"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "expected exactly one submitted Enter"
  pass "submit-ACK confirms a submit when the composer returns to a bordered-empty box"
}

test_submit_ack_reports_pending_on_persistent_swallow() {
  # A genuinely swallowed Enter (text stays in the box across all retries) is
  # reported as "pending" — the daemon keeps the buffer, fm-send exits non-zero —
  # and the digest is typed ONCE (Enter-only retries, never a retype).
  local dir fakebin sent verdict
  dir=$(make_bordered_case ack-swallow)
  fakebin="$dir/fakebin"; sent="$dir/sent.log"; : > "$sent"
  touch "$dir/.swallow"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_core "win" "the digest" 3 0.05 0.05)
  [ "$verdict" = pending ] || fail "persistent swallow not reported as pending: $verdict"
  [ "$(grep -cv '\[ENTER\]' "$sent")" -eq 1 ] || fail "digest retyped on swallow (expected type-once)"
  pass "submit-ACK reports pending on a persistently swallowed Enter (type-once)"
}

test_max_defer_empty_swallow_types_once_and_alarms() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-stuck)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/composer"
  touch "$dir/.swallow"
  escalate_add "$state" "needs-decision: pick A"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_INJECT_CONFIRM_SLEEP=0.05 \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 housekeeping "$state"
  [ "$(delivered_digest "$sent" 2>/dev/null | grep -c 'Supervisor escalate' || true)" -eq 1 ] \
    || fail "max-defer typed the digest more than once"
  [ -s "$state/.subsuper-inject-wedged" ] \
    || fail "stuck max-defer inject did not raise a wedge alarm marker"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "buffer lost after a failed max-defer inject (must be preserved)"
  pass "max-defer on an empty stuck pane types once, alarms, and preserves the buffer"
}

test_max_defer_flushes_empty_idle_pane() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-recover)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/composer"
  escalate_add "$state" "done: PR https://x/y/pull/1"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a recovered max-defer flush"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm left behind after a successful max-defer flush"
  pass "max-defer flushes and clears the buffer on an empty bordered pane"
}
