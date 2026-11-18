# shellcheck shell=bash
# Test cases for fm-daemon, split out of tests/fm-daemon.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-daemon.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2153,SC2329 # cases share setup and helpers with their .test.sh runner

# What the pinned claude primary received: each typed line, with every
# record-backed doorbell followed by the envelope its record holds.
delivered_digest() {  # <sent-log>
  local line record
  while IFS= read -r line; do
    printf '%s\n' "$line"
    fm_operational_doorbell_path "$line" record || continue
    cat "$record" 2>/dev/null
    printf '\n'
  done <"$1"
}

test_afk_start_refuses_when_flag_cannot_be_written() {
  local dir state out status
  dir=$(make_supercase afk-start-flag-unwritable)
  state="$dir/state"
  mkdir -p "$state/.afk"

  out=$(FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_BACKEND=unsupported "$AFK_START" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "fm-afk-start.sh should fail when state/.afk cannot be written"
  assert_not_contains "$out" "starting supervise daemon" "fm-afk-start.sh continued into daemon startup after .afk write failure"
  assert_absent "$state/.supervise-daemon.log" "fm-afk-start.sh started the daemon after .afk write failure"
  pass "fm-afk-start.sh fails before daemon startup when the afk flag cannot be written"
}

test_afk_start_ignores_stale_pidfile_without_lock() {
  local dir state out status
  dir=$(make_supercase afk-start-stale-pidfile)
  state="$dir/state"
  printf '%s\n' "$$" > "$state/.supervise-daemon.pid"

  out=$(FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_BACKEND=unsupported "$AFK_START" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "fm-afk-start.sh should attempt daemon startup instead of trusting a pidfile-only live pid"
  assert_contains "$out" "starting supervise daemon" "fm-afk-start.sh did not attempt daemon startup"
  assert_contains "$out" "does not support supervisor backend 'unsupported'" "daemon startup did not reach backend validation"
  assert_not_contains "$out" "daemon already running" "fm-afk-start.sh trusted a stale pidfile-only live pid"
  pass "fm-afk-start.sh ignores stale pidfile-only live pids"
}

test_afk_start_refuses_tern_supervisor_backend() {
  local dir state out status
  dir=$(make_supercase afk-start-tern-unsupported)
  state="$dir/state"

  out=$(FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_BACKEND=tern "$AFK_START" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "fm-afk-start.sh should refuse a tern supervisor backend (away mode supports only tmux, herdr, and rex)"
  case "$out" in
    *"does not support supervisor backend 'tern'"*|*"no non-visible daemon-launch primitive for backend 'tern'"*) : ;;
    *) fail "away mode did not name tern as an unsupported supervisor backend: $out" ;;
  esac
  pass "fm-afk-start.sh refuses tern as an away-mode supervisor backend (unsupported; documented in docs/tern-backend.md)"
}

test_afk_start_reclaims_stale_daemon_lock_reused_pid() {
  local dir state out status lock
  dir=$(make_supercase afk-start-stale-lock-reused-pid)
  state="$dir/state"
  lock="$state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s\n' "$$" > "$state/.supervise-daemon.pid"
  printf '%s\n' "$$" > "$lock/pid"
  printf '%s\n' "stale daemon identity" > "$lock/pid-identity"

  out=$(FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_BACKEND=unsupported "$AFK_START" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "fm-afk-start.sh should attempt daemon startup after rejecting a reused-pid lock"
  assert_contains "$out" "starting supervise daemon" "fm-afk-start.sh did not attempt daemon startup after rejecting the stale lock"
  assert_contains "$out" "does not support supervisor backend 'unsupported'" "daemon startup did not reach backend validation after stale lock cleanup"
  assert_not_contains "$out" "daemon already running" "fm-afk-start.sh trusted a stale daemon lock with a reused pid"
  assert_not_contains "$out" "another fm-supervise-daemon is already running" "daemon singleton lock still trusted the reused pid"
  pass "fm-afk-start.sh reclaims stale daemon locks whose live pid identity no longer matches"
}

test_daemon_state_root_uses_fm_home() {
  local dir home override out
  dir=$(make_supercase daemon-fm-home)
  home="$dir/firstmate-home"
  override="$dir/override-state"
  mkdir -p "$home" "$override"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE='' _state_root)
  [ "$out" = "$home/state" ] || fail "daemon state root ignored FM_HOME: $out"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$override" _state_root)
  [ "$out" = "$override" ] || fail "daemon state root ignored FM_STATE_OVERRIDE: $out"

  pass "supervise daemon state root is scoped by FM_HOME"
}

# Byte size of a status log: the daemon records escalation progress as a
# position in the append-only stream, so a fixture that means "already escalated
# through here" writes that position.
log_size() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

seen_through() {  # <state> <task>
  local state=$1 task=$2 key ident
  key=$(printf '%s' "$task" | tr ':/.' '___')
  ident=$(_fm_open_decisions_file_ident "$state/$task.status")
  printf '%s@%s' "$(log_size "$state/$task.status")" "$ident" > "$state/.subsuper-seen-status-$key"
}

# The reported bug in away mode: the captain is away, a worker reports something
# the captain must hear, then keeps appending routine progress. Classifying only
# the last line self-handles the wake and the work stalls silently until the
# captain returns.
test_classify_signal_skips_turn_end_markers() {
  local dir state reader turn status out
  dir=$(make_supercase signal-turn-end); state="$dir/state"
  reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"; chmod +x "$reader"
  turn="$state/task.turn-ended"; : > "$turn"
  out=$(FM_STATUS_IDENTITY_READER="$reader" classify_signal "$turn" "$state")
  case "$out" in self\|routine\ signal:*) ;;
    *) fail "an empty turn-end marker was not routine under unavailable identity: $out" ;;
  esac
  status="$state/task.status"
  printf 'blocked: release approval required\nworking: preparing notes\n' > "$status"
  out=$(classify_signal "$turn $status" "$state")
  case "$out" in escalate\|*"blocked: release approval required"*) ;;
    *) fail "a mixed turn-end and actionable status batch did not name the status event: $out" ;;
  esac
  pass "turn-end markers stay routine while mixed actionable status batches escalate"
}

test_classify_signal_survives_a_later_routine_append() {
  local dir state out
  dir=$(make_supercase classify-masked)
  state="$dir/state"

  printf 'working: setup\nblocked [key=release]: cannot reach the release host\nfailed: release verification broke\nworking: retrying the upload\n' \
    > "$state/mask-b1.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/mask-b1.status" "$state")
  case "$out" in
    escalate\|*) ;;
    *) fail "a blocker hidden behind a later working: line was self-handled: $out" ;;
  esac
  case "$out" in
    *"blocked [key=release]: cannot reach the release host"*"failed: release verification broke"*) ;;
    *) fail "the escalation did not report every actionable event before its endpoint: $out" ;;
  esac

  # The captain-reported shape: a finished release/install followed by routine
  # cleanup chatter must still reach an away captain.
  printf 'working: publishing\ndone: release 1.4.0 published and installed\nworking: cleaning the build dir\n' \
    > "$state/mask-r1.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/mask-r1.status" "$state")
  case "$out" in
    escalate\|*) ;;
    *) fail "a release/install completion hidden behind later routine appends was self-handled: $out" ;;
  esac
  case "$out" in
    *"done: release 1.4.0 published and installed"*) ;;
    *) fail "the escalation named the routine line instead of the completion: $out" ;;
  esac

  # Once escalated through the end of the log, a further routine append is
  # routine again: the fix must not turn every later signal into a re-escalation.
  seen_through "$state" "mask-b1"
  printf 'working: still retrying\n' >> "$state/mask-b1.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/mask-b1.status" "$state")
  case "$out" in
    self\|*) ;;
    *) fail "a routine append after the blocker was escalated re-escalated it: $out" ;;
  esac
  pass "an actionable event is escalated to an away captain despite later routine appends"
}

# The away-mode backstop must reach the same event when the per-wake path never
# ran, which is exactly what it exists for.
test_classification_commits_its_captured_endpoint() {
  local dir state capture out captured
  dir=$(make_supercase captured-endpoint); state="$dir/state"
  capture="$dir/endpoints"
  printf 'done: first release complete\n' > "$state/race-r1.status"
  out=$(FM_STATUS_SPAN_ENDPOINT_FILE="$capture" \
    classify_signal "$state/race-r1.status" "$state")
  case "$out" in escalate\|*) ;; *) fail "the first event did not classify actionable: $out" ;; esac
  captured=$(log_size "$state/race-r1.status")
  printf 'failed: second release verification failed\n' >> "$state/race-r1.status"
  mark_escalated_seen "$state" "$capture"
  [ "$(status_seen_offset "$state" race-r1)" = "$captured" ] \
    || fail "the daemon advanced past bytes appended after classification"
  out=$(classify_signal "$state/race-r1.status" "$state")
  case "$out" in
    escalate\|*"failed: second release verification failed"*) ;;
    *) fail "an event appended between classification and commit was lost: $out" ;;
  esac
  pass "the daemon commits exactly the endpoint captured by classification"
}

test_stale_masked_event_escalates_at_captured_endpoint() {
  local dir state key out
  dir=$(make_supercase stale-masked); state="$dir/state"
  printf 'blocked: release host unavailable\nworking: retrying upload\n' > "$state/stale-r2.status"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "stale: sess:fm-stale-r2" "$state"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"blocked: release host unavailable"*) ;; *) fail "a stale wake hid the blocker behind routine progress: $out" ;; esac
  key=$(printf '%s' stale-r2 | tr ':/.' '___')
  [ "$(status_seen_offset "$state" stale-r2)" = "$(log_size "$state/stale-r2.status")" ] \
    || fail "the stale escalation did not commit its captured endpoint"
  pass "a stale wake escalates a blocker hidden by later progress"
}

test_stale_read_failure_surfaces_without_advancing_seen() {
  local dir state key out
  dir=$(make_supercase stale-unreadable); state="$dir/state"
  printf 'working: retrying upload\n' > "$state/stale-r3.status"
  key=$(printf '%s' stale-r3 | tr ':/.' '___')
  printf '3@%s' "$(_fm_open_decisions_file_ident "$state/stale-r3.status")" \
    > "$state/.subsuper-seen-status-$key"
  (
    # shellcheck disable=SC2329 # Invoked indirectly by the function under test.
    _fm_status_read_span() { return 1; }
    FM_ESCALATE_BATCH_SECS=999 handle_wake "stale: sess:fm-stale-r3" "$state"
  )
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"unreadable status span"*) ;; *) fail "a stale span read failure was silently absorbed" ;; esac
  [ "$(status_seen_offset "$state" stale-r3)" = 3 ] \
    || fail "a stale span read failure advanced the daemon seen marker"
  pass "a stale span read failure surfaces without advancing its marker"
}

test_recreated_status_rejects_captured_identity() {
  local dir state reader record rest endpoint ident out
  dir=$(make_supercase recreated-identity); state="$dir/state"
  reader="$dir/identity-reader"
  cat > "$reader" <<EOF
#!/usr/bin/env bash
cat "$dir/identity-value"
EOF
  chmod +x "$reader"
  printf '1:2:old-birth' > "$dir/identity-value"
  printf 'done: old task complete\n' > "$state/reused-r4.status"
  record=$(FM_STATUS_IDENTITY_READER="$reader" \
    status_span_first_actionable_record "$state/reused-r4.status" 0)
  endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
  rm -f "$state/reused-r4.status"
  printf 'blocked: replacement task needs captain\nworking: routine padding after replacement\n' \
    > "$state/reused-r4.status"
  printf '1:2:new-birth' > "$dir/identity-value"
  FM_STATUS_IDENTITY_READER="$reader" mark_status_seen "$state" reused-r4 "$endpoint" "$ident"
  [ ! -e "$state/.subsuper-seen-status-reused-r4" ] \
    || fail "a stale captured identity advanced the replacement task marker"
  out=$(FM_STATUS_IDENTITY_READER="$reader" classify_signal "$state/reused-r4.status" "$state")
  case "$out" in escalate\|*"blocked: replacement task needs captain"*) ;;
    *) fail "the replacement task blocker did not surface after identity rejection: $out" ;;
  esac
  pass "a recreated status rejects the old captured identity"
}

test_unverifiable_identity_surfaces_without_marker() {
  local dir state reader key out
  dir=$(make_supercase unverifiable-identity); state="$dir/state"
  reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"; chmod +x "$reader"
  printf 'working: routine progress\n' > "$state/unknown-r5.status"
  key=$(printf '%s' unknown-r5 | tr ':/.' '___')
  (
    FM_STATUS_IDENTITY_READER="$reader" FM_ESCALATE_BATCH_SECS=999 \
      handle_wake "signal: $state/unknown-r5.status" "$state"
  )
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"unreadable status span"*) ;; *) fail "an unverifiable identity was silently absorbed" ;; esac
  [ "$(status_seen_offset "$state" unknown-r5)" = 0 ] \
    || fail "an unverifiable identity advanced the daemon classification position"
  pass "an unverifiable status identity surfaces without advancing markers"
}

test_status_read_failure_surfaces_without_advancing_seen() {
  local dir state key out
  dir=$(make_supercase unreadable-span); state="$dir/state"
  printf 'done: release complete\n' > "$state/read-r1.status"
  key=$(printf '%s' read-r1 | tr ':/.' '___')
  printf '3@%s' "$(_fm_open_decisions_file_ident "$state/read-r1.status")" \
    > "$state/.subsuper-seen-status-$key"
  (
    # shellcheck disable=SC2329 # Invoked indirectly by the function under test.
    last_status_line() { return 0; }
    # shellcheck disable=SC2329 # Invoked indirectly by the function under test.
    _fm_status_read_span() { return 1; }
    FM_ESCALATE_BATCH_SECS=999 handle_wake "signal: $state/read-r1.status" "$state"
  )
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"unreadable status span"*) ;; *) fail "a status span read failure was silently absorbed" ;; esac
  [ "$(status_seen_offset "$state" read-r1)" = 3 ] \
    || fail "a status span read failure advanced the daemon seen marker"
  pass "a status read failure surfaces without advancing the daemon suppressor"
}

test_catchall_advances_routine_then_surfaces_append() {
  local dir state out
  dir=$(make_supercase catchall-routine); state="$dir/state"
  printf 'working: routine history\nworking: still routine\n' > "$state/routine-r6.status"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ "$(status_seen_offset "$state" routine-r6)" = "$(log_size "$state/routine-r6.status")" ] \
    || fail "routine catch-all classification did not advance its captured endpoint"
  printf 'blocked: appended after routine endpoint\n' >> "$state/routine-r6.status"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"blocked: appended after routine endpoint"*) ;;
    *) fail "an actionable append after the routine endpoint did not surface: $out" ;;
  esac
  pass "catch-all routine scans advance before later actionable appends"
}

test_escalation_buffer_failure_retains_wake_and_position() {
  local dir state fakebin buffer out
  dir=$(make_supercase escalation-write-failure); state="$dir/state"; fakebin="$dir/daemon-bin"
  buffer="$state/.subsuper-escalations"
  printf 'blocked: release approval required\nworking: preparing notes\n' > "$state/write-r1.status"
  mkdir -p "$fakebin" "$buffer"
  cat > "$fakebin/fm-wake-drain.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --ack-through ]; then printf '%s\n' ack >> "$dir/acked"; exit 0; fi
printf '1\t1\tsignal\twrite-r1.status\tsignal: $state/write-r1.status\n'
printf 'WAKE_ACK_REQUIRED: retry --ack-through 1 --recovery-generation gen\n' >&2
EOF
  chmod +x "$fakebin/fm-wake-drain.sh"

  ! FM_DAEMON_DIR="$fakebin" handle_durable_wakes fallback "$state" 2>/dev/null \
    || fail "an unwritable escalation buffer acknowledged the wake"
  [ ! -e "$dir/acked" ] || fail "a wake was acknowledged before its escalation was buffered"
  [ "$(status_seen_offset "$state" write-r1)" = 0 ] \
    || fail "a failed escalation append advanced the classification position"

  rmdir "$buffer"
  FM_DAEMON_DIR="$fakebin" handle_durable_wakes fallback "$state" \
    || fail "the wake did not recover after the escalation buffer became writable"
  out=$(cat "$buffer" 2>/dev/null || true)
  case "$out" in *"blocked: release approval required"*) ;;
    *) fail "the recovered wake did not buffer its actionable event: $out" ;;
  esac
  [ "$(status_seen_offset "$state" write-r1)" = "$(log_size "$state/write-r1.status")" ] \
    || fail "successful buffering did not advance the classification position"
  [ "$(wc -l < "$dir/acked" | tr -d ' ')" = 1 ] \
    || fail "the recovered durable wake was not acknowledged exactly once"
  pass "failed escalation writes retain durable wakes and classification positions"
}

test_busy_inbox_escalation_reaches_supervision() {
  local variant=$1 mode=$2 dir state task=busy-inbox win gen pane reason detail buffer sent drain
  dir=$(make_supercase "busy-inbox-$variant-$mode"); state="$dir/state"
  win="sess:fm-$task"; pane="$dir/pane.txt"; sent="$dir/sent.log"
  buffer="$state/.subsuper-escalations"; drain="$dir/daemon-bin"
  printf '%s\n' "$mode" > "$state/.afk"
  printf 'working: processing instructions\n' > "$state/$task.status"
  fm_write_meta "$state/$task.meta" "window=$win" "backend=tmux" "harness=claude"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$task")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$task" busy --gen "$gen" \
    --source claude-hook --event UserPromptSubmit
  printf 'Question awaiting an answer\n' > "$pane"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$pane" \
    stale_window_is_busy "$win" "$state" || fail "inbox consumer fixture is not busy"
  case "$variant" in
    stuck)
      detail="unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; $state/$task.inbox/001.msg stays unhandled and no doorbell was typed; inspect the worker"
      ;;
    write)
      detail="steering-inbox busy bookkeeping unwritable: $state/$task.inbox/.busy-state cannot be written while $state/$task.inbox/001.msg stays unhandled; inspect the inbox directory"
      ;;
    reset)
      detail="steering-inbox busy bookkeeping unwritable: $state/$task.inbox/.busy-state cannot be reset after a non-busy check; inspect the inbox directory"
      ;;
  esac
  reason="stale: $win ($detail)"
  mkdir "$drain"
  cat > "$drain/fm-wake-drain.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --ack-through ]; then printf '%s\n' ack >> "$dir/acked"; exit 0; fi
if [ "\${FM_TEST_WAKE_FALLBACK:-0}" != 1 ]; then
  printf '1\t1\tstale\t$win\t%s\n' "$reason"
fi
printf 'WAKE_ACK_REQUIRED: inbox --ack-through 1 --recovery-generation gen\n' >&2
EOF
  chmod +x "$drain/fm-wake-drain.sh"
  FM_DAEMON_DIR="$drain" FM_ESCALATE_BATCH_SECS=999999 handle_durable_wakes "$reason" "$state" \
    || fail "$variant $mode inbox wake was not handled"
  [ "$(cat "$buffer" 2>/dev/null)" = "${reason#stale: }" ] \
    || fail "$variant $mode inbox escalation was absorbed before supervision"
  [ "$(cat "$dir/acked")" = ack ] || fail "buffered inbox wake was not acknowledged once"
  [ "$(status_seen_offset "$state" "$task")" = 0 ] || fail "inbox escalation consumed worker status"
  [ ! -e "$state/.subsuper-stale-$task" ] || fail "inbox escalation entered transient stale recovery"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=0 FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"
  [ "$(cat "$buffer")" = "${reason#stale: }" ] || fail "busy housekeeping lost the inbox escalation"
  printf '❯ \n' > "$pane"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_SENT="$sent" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=sess:supervisor escalate_flush "$state" \
    || fail "$variant $mode inbox escalation did not reach the supervisor"
  assert_contains "$(delivered_digest "$sent")" "${reason#stale: }" "supervisor digest lost the inbox reason"
  [ ! -s "$buffer" ] || fail "delivered inbox escalation stayed buffered"

  rm "$buffer" "$dir/acked"
  mkdir "$buffer"
  ! FM_DAEMON_DIR="$drain" FM_ESCALATE_BATCH_SECS=999999 handle_durable_wakes "$reason" "$state" 2>/dev/null \
    || fail "unwritable inbox escalation buffer acknowledged its wake"
  [ ! -e "$dir/acked" ] || fail "failed inbox buffering acknowledged the wake"
  rmdir "$buffer"
  FM_DAEMON_DIR="$drain" FM_ESCALATE_BATCH_SECS=999999 FM_TEST_WAKE_FALLBACK=1 \
    handle_durable_wakes "$reason" "$state" || fail "inbox fallback reason did not recover"
  [ "$(cat "$buffer")" = "${reason#stale: }" ] || fail "fallback lost the inbox escalation"
  [ "$(cat "$dir/acked")" = ack ] || fail "recovered inbox buffering did not acknowledge the wake"
  pass "$variant inbox escalation reaches supervision in $mode mode and survives buffering failure"
}

test_busy_inbox_dispatch_preserves_other_stale_reasons() {
  local dir state detail
  dir=$(make_supercase inbox-dispatch-scope); state="$dir/state"
  printf 'working: processing instructions\n' > "$state/ordinary.status"
  for detail in \
    '' \
    'busy for 4000s without a turn boundary' \
    "unread firstmate instruction: $state/ordinary.inbox/001.msg still unhandled after 3 doorbell delivery attempts with an idle pane; inspect the worker" \
    'steering-inbox ladder bookkeeping unwritable: .ring-state cannot be written' \
    'steering-inbox retry mark unremovable: .retry-ring cannot be removed'; do
    FM_ESCALATE_BATCH_SECS=999999 handle_wake "stale: sess:fm-ordinary${detail:+ ($detail)}" "$state" \
      || fail "ordinary stale handling failed"
    [ ! -s "$state/.subsuper-escalations" ] || fail "inbox dispatch changed another stale reason: $detail"
    [ -e "$state/.subsuper-stale-ordinary" ] || fail "inbox dispatch bypassed ordinary stale recovery"
  done
  pass "inbox dispatch preserves ordinary stale, busy-turn, and other doorbell routing"
}

test_catchall_buffer_failure_preserves_position() {
  local dir state buffer out
  dir=$(make_supercase catchall-write-failure); state="$dir/state"
  buffer="$state/.subsuper-escalations"
  printf 'failed: release verification broke\nworking: collecting logs\n' > "$state/catch-write-r2.status"
  mkdir "$buffer"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state" 2>/dev/null || true
  [ "$(status_seen_offset "$state" catch-write-r2)" = 0 ] \
    || fail "a failed catch-all append advanced the classification position"

  rmdir "$buffer"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  out=$(cat "$buffer" 2>/dev/null || true)
  case "$out" in *"failed: release verification broke"*) ;;
    *) fail "the catch-all did not retry its actionable event after recovery: $out" ;;
  esac
  [ "$(status_seen_offset "$state" catch-write-r2)" = "$(log_size "$state/catch-write-r2.status")" ] \
    || fail "the recovered catch-all did not advance its classification position"
  pass "catch-all markers advance only after escalation buffering succeeds"
}

test_durable_wake_failure_retains_entire_batch() {
  local dir state fakebin attempts
  dir=$(make_supercase durable-failure); state="$dir/state"; fakebin="$dir/daemon-bin"; attempts="$dir/attempts"
  mkdir -p "$fakebin"
  cat > "$fakebin/fm-wake-drain.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --ack-through ]; then printf ack > "$dir/acked"; exit 0; fi
printf '1\t1\tsignal\ttask.status\tsignal: first\n1\t2\theartbeat\theartbeat\theartbeat\n'
printf 'WAKE_ACK_REQUIRED: retry --ack-through 2 --recovery-generation gen\n' >&2
EOF
  chmod +x "$fakebin/fm-wake-drain.sh"
  (
    FM_DAEMON_DIR="$fakebin"
    handle_wake() { printf '%s\n' "$1" >> "$attempts"; [ "$1" != 'signal: first' ]; }
    ! handle_durable_wakes fallback "$state"
  ) || fail "a failed wake classification was acknowledged"
  [ "$(wc -l < "$attempts" | tr -d ' ')" = 2 ] \
    || fail "a failed wake prevented later batch entries from being accounted"
  [ ! -e "$dir/acked" ] || fail "a partially handled durable batch was acknowledged"
  pass "classification failure retains the complete durable wake batch"
}

test_missing_status_stale_is_acknowledged_without_diagnostic() {
  local dir state fakebin
  dir=$(make_supercase durable-no-status); state="$dir/state"; fakebin="$dir/daemon-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/fm-wake-drain.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --ack-through ]; then printf '%s\n' ack >> "$dir/acked"; exit 0; fi
printf '1\t1\tstale\tmissing-r8\tstale: sess:fm-missing-r8\n'
printf 'WAKE_ACK_REQUIRED: ordinary --ack-through 1 --recovery-generation gen\n' >&2
EOF
  chmod +x "$fakebin/fm-wake-drain.sh"
  FM_DAEMON_DIR="$fakebin" handle_durable_wakes fallback "$state" \
    || fail "a stale wake without a status file was retained for retry"
  FM_DAEMON_DIR="$fakebin" handle_durable_wakes fallback "$state" \
    || fail "repeated missing-status handling became a classification failure"
  [ "$(wc -l < "$dir/acked" | tr -d ' ')" = 2 ] \
    || fail "a missing-status stale wake was not acknowledged"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "a missing status file produced an unreadable-span escalation"
  pass "missing-status stale wakes remain ordinary and acknowledgeable"
}

test_transient_unreadable_signal_recovers_without_advancing() {
  local dir state fakebin out key
  dir=$(make_supercase durable-unreadable); state="$dir/state"; fakebin="$dir/daemon-bin"
  printf 'blocked: status cannot be classified\n' > "$state/unreadable-r7.status"
  mkdir -p "$fakebin"
  cat > "$fakebin/fm-wake-drain.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --ack-through ]; then printf '%s\n' ack >> "$dir/acked"; exit 0; fi
printf '1\t1\tsignal\tunreadable-r7.status\tsignal: $state/unreadable-r7.status\n'
printf 'WAKE_ACK_REQUIRED: retry --ack-through 1 --recovery-generation gen\n' >&2
EOF
  chmod +x "$fakebin/fm-wake-drain.sh"
  (
    FM_DAEMON_DIR="$fakebin"
    # shellcheck disable=SC2329 # Invoked indirectly by the function under test.
    _fm_status_read_span() { return 1; }
    handle_durable_wakes fallback "$state"
  ) || fail "an unreadable signal did not acknowledge its wake after reporting"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"unreadable status span"*) ;;
    *) fail "an unreadable durable signal did not surface its diagnostic: $out" ;;
  esac
  key=$(printf '%s' unreadable-r7 | tr ':/.' '___')
  [ "$(status_seen_offset "$state" unreadable-r7)" = 0 ] \
    || fail "an unreadable signal advanced its classification position"
  FM_DAEMON_DIR="$fakebin" handle_durable_wakes fallback "$state" \
    || fail "a readable status did not recover after a transient failure"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"blocked: status cannot be classified"*) ;;
    *) fail "the recovered status was not classified from its original position: $out" ;;
  esac
  pass "transient unreadable signals recover without advancing their position"
}

test_permission_recovery_reclassifies_catchall_status() {
  local dir state status before_ident after_ident out
  dir=$(make_supercase catchall-permission-recovery); state="$dir/state"
  status="$state/permission-r8.status"
  printf 'blocked: release approval required\nworking: preserving context\n' > "$status"
  before_ident=$(_fm_open_decisions_file_ident "$status")
  chmod 000 "$status"
  if [ -r "$status" ]; then
    chmod 600 "$status"
    pass "daemon permission recovery skipped because permissions cannot deny reads"
    return
  fi

  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ "$(status_seen_offset "$state" permission-r8)" = 0 ] \
    || { chmod 600 "$status"; fail "an unreadable catch-all status advanced its classification position"; }
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ "$(grep -c 'unreadable status span' "$state/.subsuper-escalations")" = 1 ] \
    || { chmod 600 "$status"; fail "an unchanged unreadable catch-all status reported repeatedly"; }

  chmod 600 "$status"
  after_ident=$(_fm_open_decisions_file_ident "$status")
  [ "$after_ident" = "$before_ident" ] || fail "permission recovery changed the catch-all file identity"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"blocked: release approval required"*) ;;
    *) fail "the catch-all did not surface preserved content after readability recovery: $out" ;;
  esac
  [ "$(status_seen_offset "$state" permission-r8)" = "$(log_size "$status")" ] \
    || fail "the catch-all did not classify from the unadvanced position"
  pass "daemon catch-all reclassifies permission-recovered status content"
}

# A permanently unclassifiable status must not wedge supervision. The accepted
# contract is deliberately simple: report it, acknowledge the wake so an unchanged
# permanent failure cannot re-alarm on every pass, and never advance the
# classification position, so the log is classified from where it stopped once it
# becomes readable. The residual risk - no guaranteed automatic retry inside a
# crash-mid-read window - is accepted and covered by the locked startup replay.
test_permanent_classification_failure_is_reported_and_acknowledged() {
  local dir state fakebin out
  dir=$(make_supercase durable-symlink); state="$dir/state"; fakebin="$dir/daemon-bin"
  printf 'blocked: first target\n' > "$dir/target-one"
  ln -s "$dir/target-one" "$state/symlink-r9.status"
  mkdir -p "$fakebin"
  cat > "$fakebin/fm-wake-drain.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --ack-through ]; then printf '%s\n' ack >> "$dir/acked"; exit 0; fi
printf '1\t1\tsignal\tsymlink-r9.status\tsignal: $state/symlink-r9.status\n'
printf 'WAKE_ACK_REQUIRED: bounded --ack-through 1 --recovery-generation gen\n' >&2
EOF
  chmod +x "$fakebin/fm-wake-drain.sh"

  FM_DAEMON_DIR="$fakebin" handle_durable_wakes fallback "$state" \
    || fail "a permanent classification failure left its wake unacknowledged"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"unreadable status span"*) ;;
    *) fail "a permanent classification failure did not surface its diagnostic: $out" ;;
  esac
  [ "$(status_seen_offset "$state" symlink-r9)" = 0 ] \
    || fail "a classification failure advanced its position"

  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  FM_DAEMON_DIR="$fakebin" handle_durable_wakes fallback "$state" \
    || fail "a repeated permanent failure retained its wake"
  [ "$(grep -c 'unreadable status span' "$state/.subsuper-escalations")" = 1 ] \
    || fail "an unchanged failure was reported more than once across daemon paths"
  [ "$(status_seen_offset "$state" symlink-r9)" = 0 ] \
    || fail "a repeated classification failure advanced its position"

  printf 'blocked: changed target state with a longer path\n' > "$dir/target-two-longer"
  ln -snf "$dir/target-two-longer" "$state/symlink-r9.status"
  FM_DAEMON_DIR="$fakebin" handle_durable_wakes fallback "$state" \
    || fail "a changed permanent failure retained its wake"
  [ "$(grep -c 'unreadable status span' "$state/.subsuper-escalations")" = 2 ] \
    || fail "a changed failure state did not report again exactly once"
  [ "$(status_seen_offset "$state" symlink-r9)" = 0 ] \
    || fail "a changed classification failure advanced its position"

  # Once the log is readable, its content is classified from the position that
  # was never advanced, so nothing written before the failure is lost.
  rm -f "$state/symlink-r9.status"
  printf 'blocked: readable replacement\nworking: cleanup\n' > "$state/symlink-r9.status"
  : > "$state/.subsuper-escalations"
  FM_DAEMON_DIR="$fakebin" handle_durable_wakes fallback "$state" \
    || fail "a readable replacement did not classify normally"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"blocked: readable replacement"*) ;;
    *) fail "the readable replacement was not classified from the unadvanced position: $out" ;;
  esac
  [ "$(status_seen_offset "$state" symlink-r9)" = "$(log_size "$state/symlink-r9.status")" ] \
    || fail "successful recovery did not advance through the readable replacement"
  [ "$(wc -l < "$dir/acked" | tr -d ' ')" = 4 ] \
    || fail "every durable wake should be acknowledged, including the failures"
  pass "a permanent classification failure is reported, acknowledged, and never advances its position"
}

test_catchall_scan_surfaces_a_masked_event() {
  local dir state
  dir=$(make_supercase catchall-masked)
  state="$dir/state"
  printf 'working: setup\nneeds-decision [key=release]: pick A or B\nfailed: release build broke\nworking: tidying the branch\n' \
    > "$state/catch-m1.status"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "the catch-all scan missed a decision hidden behind a later working: line"
  grep -F "needs-decision [key=release]: pick A or B" "$state/.subsuper-escalations" >/dev/null \
    || fail "the catch-all scan omitted the decision it found"
  grep -F "failed: release build broke" "$state/.subsuper-escalations" >/dev/null \
    || fail "the catch-all scan committed past a failure it did not report"
  # And it records progress, so the next scan does not re-fire the same event.
  : > "$state/.subsuper-escalations"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "the catch-all scan re-fired an event it had already escalated"
  pass "the away-mode catch-all scan surfaces a masked event once"
}

test_classify_routine_signal_self() {
  local dir state out
  dir=$(make_supercase classify-routine)
  state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/foo-x1.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/foo-x1.status" "$state")
  case "$out" in self\|*) pass "routine signal self-handles" ;; *) fail "routine signal did not self-handle: $out" ;; esac
}

test_classify_terminal_signal_escalates() {
  local dir state kw out
  dir=$(make_supercase classify-terminal)
  state="$dir/state"
  for kw in "done: PR https://x/y/pull/1" "needs-decision: pick A" "blocked: no perms" \
            "failed: rc 2" "PR ready https://x/y/pull/2" "checks green" \
            "ready in branch fm/t1" "merged"; do
    printf 'working\n%s\n' "$kw" > "$state/t.status"
    out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/t.status" "$state")
    case "$out" in escalate\|*) ;; *) fail "captain verb did not escalate ($kw): $out" ;; esac
  done
  pass "captain-relevant status verbs escalate"
}

test_classify_check_and_unknown_escalate() {
  local out
  out=$(classify_check "check: /s/c.check.sh: merged: https://x")
  case "$out" in escalate\|*) ;; *) fail "check did not escalate: $out" ;; esac
  out=$(classify_unknown "frobnicate: weird")
  case "$out" in escalate\|*) ;; *) fail "unknown did not fail-safe escalate: $out" ;; esac
  out=$(classify_heartbeat)
  case "$out" in self\|*) ;; *) fail "heartbeat did not self-handle: $out" ;; esac
  pass "check + unknown escalate; heartbeat self-handles"
}

# An unrecognized wake escalates once per identity. Delivery acknowledges that
# exact line; a later copy does not escalate again. A different identity still
# escalates, and an identity that never flushed still escalates. Ordinary
# escalation lines are not part of that acknowledgement. A new away session
# clears the acknowledgements, so the same identity can fire again.
test_unknown_wake_ack_suppresses_handled_identity() {
  local dir state fakebin sent capture out
  dir=$(make_supercase unknown-wake-ack)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf '\342\235\257 \n' > "$capture"

  FM_ESCALATE_BATCH_SECS=999 handle_wake "frobnicate: already-handled" "$state" \
    || fail "the first unknown wake was not handled"
  [ ! -e "$state/.subsuper-unknown-acked" ] \
    || fail "an undelivered unknown wake was acknowledged"

  : > "$state/.subsuper-escalations"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "frobnicate: already-handled" "$state" \
    || fail "an undelivered unknown wake did not escalate again after its buffer was lost"
  [ "$(grep -c 'unknown wake: frobnicate: already-handled' "$state/.subsuper-escalations")" = 1 ] \
    || fail "a lost undelivered unknown wake did not escalate again"

  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "unknown-wake flush failed"
  grep -F 'unknown wake: frobnicate: already-handled' "$state/.subsuper-unknown-acked" >/dev/null \
    || fail "a delivered unknown wake was not acknowledged"
  [ ! -s "$state/.subsuper-escalations" ] || fail "delivered unknown wake stayed buffered"

  FM_ESCALATE_BATCH_SECS=999 handle_wake "frobnicate: already-handled" "$state" \
    || fail "an acknowledged unknown wake was not handled"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "an acknowledged unknown wake escalated again: $(cat "$state/.subsuper-escalations")"

  FM_ESCALATE_BATCH_SECS=999 handle_wake "frobnicate: brand-new" "$state" \
    || fail "a new unknown wake was not handled"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in
    "unknown wake: frobnicate: brand-new") ;;
    *) fail "a new unknown wake did not escalate on its own: $out" ;;
  esac
  escalate_add "$state" "done: PR https://example.test/pull/9"
  [ "$(grep -c 'done: PR https://example.test/pull/9' "$state/.subsuper-escalations")" = 1 ] \
    || fail "an ordinary escalation was swallowed by unknown-wake acknowledgement"
  escalate_add "$state" "done: PR https://example.test/pull/9"
  [ "$(grep -c 'done: PR https://example.test/pull/9' "$state/.subsuper-escalations")" = 2 ] \
    || fail "an ordinary escalation was deduped by unknown-wake acknowledgement"

  bash -c '. "$1"; fm_afk_clear_stale_artifacts "$2"' _ "$AFK_START" "$state" \
    || fail "clearing the away-session artifacts failed"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "frobnicate: already-handled" "$state" \
    || fail "an unknown wake from a prior session was not handled"
  [ "$(grep -c 'unknown wake: frobnicate: already-handled' "$state/.subsuper-escalations")" = 1 ] \
    || fail "an unknown wake acknowledged in a prior away session did not fire again"
  pass "a delivered unknown wake is acknowledged once per away session; a new one and ordinary escalations still fire"
}

# A digest that inject_msg already delivered must not be injected again just
# because the acknowledgement write failed afterwards.
test_unknown_wake_ack_failure_still_clears_delivered_digest() {
  local dir state fakebin sent capture
  dir=$(make_supercase unknown-wake-ack-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf '\342\235\257 \n' > "$capture"
  mkdir -p "$state/.subsuper-unknown-acked"

  FM_ESCALATE_BATCH_SECS=999 handle_wake "frobnicate: ack-write-fails" "$state" \
    || fail "the unknown wake was not handled"
  escalate_add "$state" "done: PR https://example.test/pull/10"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" 2>/dev/null \
    || fail "a delivered digest was reported undelivered after its acknowledgement write failed"
  delivered_digest "$sent" | grep -F 'unknown wake: frobnicate: ack-write-fails' >/dev/null \
    || fail "the digest was not delivered: $(cat "$sent")"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "a delivered digest stayed buffered for re-injection: $(cat "$state/.subsuper-escalations")"
  [ ! -e "$state/.subsuper-escalations.since" ] || fail "a delivered digest kept its batch timer"
  pass "a failed unknown-wake acknowledgement write does not re-inject a delivered digest"
}

test_stale_transient_self_records_marker() {
  local dir state out key
  dir=$(make_supercase stale-transient)
  state="$dir/state"
  printf 'working: building\n' > "$state/qux-w4.status"
  stale_marker_record "sess:fm-qux-w4" "$state"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-qux-w4" "$state")
  case "$out" in self\|*) ;; *) fail "transient stale did not self-handle: $out" ;; esac
  key=$(printf '%s' "$(window_to_task "sess:fm-qux-w4")" | tr ':/.' '___')
  [ -e "$state/.subsuper-stale-$key" ] || fail "stale marker was not recorded"
  pass "transient stale self-handles and records a persistence marker"
}

test_stale_diagnostic_wedge_survives_busy_housekeeping() {
  local case_name dir state fakebin key task win pane reason status_line action_log
  for case_name in working prior-terminal paused; do
    dir=$(make_supercase "stale-diagnostic-$case_name")
    state="$dir/state"
    fakebin="$dir/fakebin"
    task="suffix-$case_name"
    win="sess:fm-$task"
    pane="$dir/pane.txt"
    action_log="$dir/actions.log"
    reason="stale: $win (idle 500s, possible wedge, escalation 3, demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone)"
    fm_write_meta "$state/$task.meta" "window=$win" "backend=tmux"
    case "$case_name" in
      working) status_line='working: building' ;;
      prior-terminal) status_line='done: already surfaced' ;;
      paused) status_line='paused: awaiting an external dependency' ;;
    esac
    printf '%s\n' "$status_line" > "$state/$task.status"
    printf 'Working...\n' > "$pane"
    key=$(printf '%s' "$task" | tr ':/.' '___')
    echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
    [ "$case_name" = prior-terminal ] \
      && seen_through "$state" "$task"
    [ "$case_name" = paused ] \
      && echo $(( $(date +%s) - 500 )) > "$state/.subsuper-paused-$key"

    (
      kill() { printf 'kill %s\n' "$*" >> "$action_log"; }
      fm_backend_send_text_submit() { printf 'interrupt %s\n' "$*" >> "$action_log"; }
      LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
      PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
        FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"
    )
    case "$case_name" in
      paused)
        # A current declared wait owns the cadence: the enriched wedge routes to the
        # bounded PAUSE_RESURFACE_SECS recheck instead of escalating on the wedge
        # cadence. test_enriched_wedge_under_declared_wait_uses_pause_cadence pins
        # the full cadence, including the one recheck that still re-surfaces it.
        [ ! -s "$state/.subsuper-escalations" ] \
          || fail "paused enriched wedge escalated instead of routing to the pause cadence: $(cat "$state/.subsuper-escalations")"
        [ -e "$state/.subsuper-paused-$key" ] \
          || fail "paused enriched wedge erased ordinary pause tracking" ;;
      *)
        [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" = 1 ] \
          || fail "$case_name enriched wedge did not produce exactly one escalation"
        grep -F "${reason#stale: }" "$state/.subsuper-escalations" >/dev/null \
          || fail "$case_name enriched wedge lost its demand-deep-inspection detail"
        [ ! -e "$state/.subsuper-paused-$key" ] \
          || fail "$case_name enriched wedge created pause tracking" ;;
    esac
    [ ! -e "$state/.subsuper-stale-$key" ] \
      || fail "$case_name enriched wedge retained ordinary stale tracking"
    [ ! -s "$action_log" ] \
      || fail "$case_name enriched wedge interrupted or killed the busy worker"
  done
  pass "enriched stale wedges bypass status absorption except under a declared wait, without disturbing busy workers"
}

# The second half of issue #3149. The watcher's wedge timer emits an enriched
# "idle Ns, possible wedge, escalation N" reason for any pane it reads as frozen -
# including one whose crew has a CURRENT declared wait, because the watcher's own
# provably-working classification and the crew's status line can disagree (a crew
# that declares `paused:` while its no-mistakes run is still attributed to its code
# reads `working` to pause_state_class and takes the wedge timer). handle_wake's
# enriched-wedge override force-escalated every such reason, discarding the `pause`
# verdict classify_stale had already returned for the same pane, so a healthy
# declared wait was escalated once per STALE_ESCALATE_SECS for as long as it lasted.
# A declaration is categorically stronger than the run-step/pane state the enriched
# reason tells the supervisor not to re-absorb on, so it routes the pane to the long
# PAUSE_RESURFACE_SECS recheck instead. This drives repeated enriched wedges through
# the real handle_wake/housekeeping pair and asserts the cadence, not just one wake.
test_enriched_wedge_under_declared_wait_uses_pause_cadence() {
  local dir state fakebin task win pane key reason i escalations
  dir=$(make_supercase enriched-wedge-declared-wait)
  state="$dir/state"; fakebin="$dir/fakebin"
  task=paused-wedge-w1; win="sess:fm-$task"; pane="$dir/pane.txt"
  key=$(printf '%s' "$task" | tr ':/.' '___')
  fm_write_meta "$state/$task.meta" "window=$win" "backend=tmux"
  printf 'working: dispatching the long audit\npaused: the audit engine is running to completion\n' \
    > "$state/$task.status"
  printf 'idle prompt $\n' > "$pane"
  case "$(FM_STATE_OVERRIDE="$state" classify_stale "$win" "$state")" in
    pause\|*) ;;
    *) fail "the fixture's own classifier verdict is not a pause, so this case pins nothing about the override" ;;
  esac

  # Four consecutive wedge-cadence deliveries, exactly as the watcher emits them once
  # a pane crosses STALE_ESCALATE_SECS repeatedly.
  for i in 2 3 4 5; do
    if [ "$i" -ge 3 ]; then
      # Past FM_WEDGE_DEMAND_INSPECT_COUNT the watcher enriches the same reason with
      # its demand-deep-inspection marker; a declaration outranks both forms.
      reason="stale: $win (idle 250s, possible wedge, escalation $i, demand-deep-inspection: same pane has wedge-escalated $i times in a row - do not re-absorb on the run-step/pane state alone)"
    else
      reason="stale: $win (idle 250s, possible wedge, escalation $i)"
    fi
    LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
      FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 \
      FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600 housekeeping "$state"
  done

  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "a declared wait escalated inside one PAUSE_RESURFACE_SECS window: $(cat "$state/.subsuper-escalations")"
  [ -e "$state/.subsuper-paused-$key" ] \
    || fail "an enriched wedge under a declared wait did not record pause tracking"
  [ ! -e "$state/.subsuper-stale-$key" ] \
    || fail "an enriched wedge under a declared wait left wedge aging in place"

  # Past PAUSE_RESURFACE_SECS the wait must re-surface exactly once as an
  # awaiting-external recheck (never a wedge) and reset its window.
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 FM_PAUSE_RESURFACE_SECS=3600 \
    housekeeping "$state"
  escalations=0
  [ -s "$state/.subsuper-escalations" ] \
    && escalations=$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')
  [ "$escalations" = 1 ] || fail "the pause window produced $escalations escalations, expected exactly one recheck"
  grep -F "awaiting external" "$state/.subsuper-escalations" >/dev/null \
    || fail "the one pause-window escalation was not an awaiting-external recheck"
  grep -F "possible wedge" "$state/.subsuper-escalations" >/dev/null \
    && fail "the pause-window recheck was mislabeled a possible wedge"

  # A later status append that stops declaring the wait ends the routing: the same
  # enriched wedge escalates again, unchanged.
  : > "$state/.subsuper-escalations"
  printf 'working: the audit finished, resuming\n' >> "$state/$task.status"
  reason="stale: $win (idle 250s, possible wedge, escalation 6)"
  LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 FM_PAUSE_RESURFACE_SECS=3600 \
    housekeeping "$state"
  grep -F "${reason#stale: }" "$state/.subsuper-escalations" >/dev/null \
    || fail "wedge escalation was not restored after the crew left its declared wait"
  [ ! -e "$state/.subsuper-paused-$key" ] \
    || fail "pause tracking survived a status append that no longer declares the wait"
  pass "an enriched wedge under a declared wait uses the pause cadence and restores wedge detection on resume"
}

# Upstream kunchenguid/firstmate#6899, away-daemon half. In a home that armed
# config/wedge-defer-worker-wait, a worker's own open newest `blocked:` line is a
# declaration too, so an enriched wedge for its pane is not escalated on top of
# the blocker the daemon already escalated; unarmed, the wedge escalates as before.
test_enriched_wedge_under_worker_blocker_follows_its_flag() {
  local dir state task win reason armed
  for armed in 1 0; do
    dir=$(make_supercase "enriched-wedge-worker-blocker-$armed")
    state="$dir/state"
    task=blocked-wedge-w$armed; win="sess:fm-$task"
    fm_write_meta "$state/$task.meta" "window=$win" "backend=tmux"
    printf 'working: wiring the client\nblocked: need the API key for the staging account\n' \
      > "$state/$task.status"
    mkdir -p "$dir/config"
    [ "$armed" -eq 0 ] || : > "$dir/config/wedge-defer-worker-wait"
    # The blocker's own signal is escalated first, as it is when it lands.
    FM_CONFIG_OVERRIDE="$dir/config" LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" \
      FM_ESCALATE_BATCH_SECS=999 handle_wake "stale: $win" "$state"
    grep -F 'need the API key' "$state/.subsuper-escalations" >/dev/null \
      || fail "the fixture's blocker was never escalated, so this case pins nothing"
    : > "$state/.subsuper-escalations"
    reason="stale: $win (idle 250s, possible wedge, escalation 2)"
    FM_CONFIG_OVERRIDE="$dir/config" LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" \
      FM_ESCALATE_BATCH_SECS=999 handle_wake "$reason" "$state"
    if [ "$armed" -eq 1 ]; then
      [ ! -s "$state/.subsuper-escalations" ] \
        || fail "an armed home escalated a wedge on top of a worker blocker: $(cat "$state/.subsuper-escalations")"
    else
      grep -F "${reason#stale: }" "$state/.subsuper-escalations" >/dev/null \
        || fail "an unarmed home stopped escalating a wedge under a worker blocker"
    fi
  done
  pass "an enriched wedge under a worker blocker is not escalated only where config/wedge-defer-worker-wait arms it"
}

test_stale_terminal_escalates() {
  local dir state out
  dir=$(make_supercase stale-terminal)
  state="$dir/state"
  printf 'done: ready in branch fm/t1\n' > "$state/fin-t5.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-fin-t5" "$state")
  case "$out" in escalate\|*) ;; *) fail "terminal stale did not escalate: $out" ;; esac
  fm_write_meta "$state/herdr-t5.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-t5.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "default:w1:p2" "$state")
  case "$out" in escalate\|*) ;; *) fail "terminal herdr stale did not escalate through metadata: $out" ;; esac
  pass "stale + terminal status escalates immediately"
}

test_stale_actionable_wait_escalates_and_keeps_pause_cadence() {
  local dir state win key out reason resumed_win resumed_key
  dir=$(make_supercase stale-actionable-wait); state="$dir/state"
  win="sess:fm-waiting-r10"; key=$(printf '%s' waiting-r10 | tr ':/.' '___')
  printf 'blocked [key=release]: need captain approval\npaused: waiting for release access\n' \
    > "$state/waiting-r10.status"

  out=$(FM_STATE_OVERRIDE="$state" classify_stale "$win" "$state")
  case "$out" in escalate\|*"blocked [key=release]: need captain approval"*) ;;
    *) fail "a current wait hid an unreported blocker from stale classification: $out" ;;
  esac
  reason="stale: $win (idle 250s, possible wedge, escalation 3, demand-deep-inspection: inspect the repeated wedge)"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "$reason" "$state"
  out=$(cat "$state/.subsuper-escalations" 2>/dev/null || true)
  case "$out" in *"blocked [key=release]: need captain approval"*) ;;
    *) fail "the stale escalation did not name the blocker behind the current wait: $out" ;;
  esac
  [ -e "$state/.subsuper-paused-$key" ] \
    || fail "an actionable current wait did not retain its pause cadence"
  [ ! -e "$state/.subsuper-stale-$key" ] \
    || fail "an actionable current wait was also aged as a wedge"

  resumed_win="sess:fm-resumed-r10"; resumed_key=$(printf '%s' resumed-r10 | tr ':/.' '___')
  printf 'paused: old wait\nworking: resumed after access arrived\n' > "$state/resumed-r10.status"
  printf '1' > "$state/.subsuper-paused-$resumed_key"
  FM_ESCALATE_BATCH_SECS=999 handle_wake "stale: $resumed_win" "$state"
  [ ! -e "$state/.subsuper-paused-$resumed_key" ] \
    || fail "an older pause declaration kept a resumed crew on pause cadence"
  [ -e "$state/.subsuper-stale-$resumed_key" ] \
    || fail "a resumed crew did not return to ordinary stale aging"
  pass "stale escalation and current wait cadence remain independent"
}

# A DECLARED external-wait pause (paused:) is neither a wedge nor a terminal
# escalation: classify_stale returns the `pause` action so handle_wake records a
# pause marker (long re-surface cadence) rather than a wedge stale marker.
test_stale_paused_classifies_pause() {
  local dir state out pause_reason
  dir=$(make_supercase stale-paused)
  state="$dir/state"
  pause_reason='paused: waiting for upstream checks green, merged, and blocked state to clear'
  status_is_captain_relevant "$pause_reason" && fail "pause reason phrases made the status captain-relevant"
  printf '%s\n' "$pause_reason" > "$state/held-w9.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-held-w9" "$state")
  case "$out" in pause\|*) ;; *) fail "declared pause did not classify as pause: $out" ;; esac
  pass "paused reasons with captain phrases remain pause-classified"
}

# A resolved line for another phase key, including the stated default key that
# `fm-send --resolve-key default` writes for a keyless decision, lands after the
# pause without ending it. The worker's own keyless resolved line does end it.
test_stale_pause_survives_a_foreign_resolved_line() {
  local dir state out
  dir=$(make_supercase stale-paused-foreign-resolved)
  state="$dir/state"
  printf 'needs-decision: which color\npaused: waiting on the vendor release\nresolved [key=default]: answered: blue\n' \
    > "$state/held-w9r.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-held-w9r" "$state" '' 1)
  case "$out" in pause\|*"paused: waiting on the vendor release") ;; *) fail "a default-key answer cleared the pause: $out" ;; esac
  printf 'paused: waiting on the vendor release\nresolved [key=legal]: counsel answered\n' > "$state/held-w9r.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-held-w9r" "$state" '' 1)
  case "$out" in pause\|*) ;; *) fail "a differently keyed resolved line cleared the pause: $out" ;; esac
  printf 'paused: waiting on the vendor release\nresolved: the vendor shipped\n' > "$state/held-w9r.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-held-w9r" "$state" '' 1)
  case "$out" in pause\|*) fail "the worker's own keyless resolved line did not retract the pause: $out" ;; esac
  printf 'captain-held [key=route]: tracked by task-decision-route\nresolved [key=default]: answered: blue\n' > "$state/held-w9r.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-held-w9r" "$state" '' 1)
  case "$out" in pause\|*) fail "a later resolved line no longer retracted a captain-held declaration: $out" ;; esac
  pass "a foreign resolved line keeps a pause, while the worker's own resolved line retracts it"
}

# A verified captain-held transfer is the other declaration that leaves an idle pane
# EXPECTED, so it earns the same pause action as paused: rather than being aged as a
# wedge. The wait itself is already durable in the captain-held backlog task.
test_stale_captain_held_classifies_pause() {
  local dir state out held_reason
  dir=$(make_supercase stale-captain-held)
  state="$dir/state"
  held_reason='captain-held [key=route]: tracked by task-decision-route'
  status_is_captain_relevant "$held_reason" && fail "a captain-held transfer line was treated as captain-relevant"
  printf '%s\n' "$held_reason" > "$state/held-w9h.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-held-w9h" "$state")
  case "$out" in pause\|*) ;; *) fail "captain-held transfer did not classify as pause: $out" ;; esac
  pass "a captain-held transfer classifies as pause, not as a wedge candidate"
}

# handle_wake on a paused stale records a pause marker, drops any pre-existing wedge
# marker (so a working->paused pane is not still wedge-aged), and does NOT escalate
# on the wake itself - the recheck is housekeeping's job on the long cadence.
test_handle_wake_paused_records_pause_marker() {
  local dir state key win
  dir=$(make_supercase handle-paused)
  state="$dir/state"
  win="sess:fm-held-w10"
  printf 'paused: awaiting the vendor rate-limit reset\n' > "$state/held-w10.status"
  key=$(printf '%s' "held-w10" | tr ':/.' '___')
  date +%s > "$state/.subsuper-stale-$key"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ -e "$state/.subsuper-paused-$key" ] || fail "pause marker not recorded by handle_wake"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "wedge marker not cleared when the crew declared a pause"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a declared pause escalated on the wake itself (should defer to the long recheck)"
  pass "handle_wake on a paused stale records a pause marker, drops the wedge marker, and does not escalate"
}

test_handle_wake_paused_signal_records_pause_marker() {
  local dir state key win
  dir=$(make_supercase handle-paused-signal)
  state="$dir/state"
  win="sess:fm-held-w10-signal"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-signal.meta"
  printf 'paused: awaiting the vendor rate-limit reset\n' > "$state/held-w10-signal.status"
  key=$(printf '%s' "held-w10-signal" | tr ':/.' '___')
  date +%s > "$state/.subsuper-stale-$key"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/held-w10-signal.status" "$state"
  [ -e "$state/.subsuper-paused-$key" ] || fail "pause signal did not record a pause marker"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "pause signal did not clear the wedge marker"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a declared pause signal escalated instead of self-handling"
  pass "handle_wake records a declared pause from a routine signal for long-cadence rechecks"
}

test_handle_wake_terminal_signal_clears_pause_tracking() {
  local dir state key watcher_key win
  dir=$(make_supercase handle-terminal-signal)
  state="$dir/state"
  win="sess:fm-held-w10-terminal"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-terminal.meta"
  printf 'done: upstream landed\n' > "$state/held-w10-terminal.status"
  key=$(printf '%s' "held-w10-terminal" | tr '.:/' '___')
  watcher_key=$(watch_window_key "$win")
  date +%s > "$state/.subsuper-paused-$key"
  date +%s > "$state/.subsuper-stale-$key"
  : > "$state/.paused-$watcher_key"
  : > "$state/.stale-$watcher_key"
  : > "$state/.wedge-escalations-$watcher_key"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/held-w10-terminal.status" "$state"
  [ ! -e "$state/.subsuper-paused-$key" ] || fail "terminal signal retained the daemon pause marker"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "terminal signal retained daemon stale tracking"
  [ ! -e "$state/.paused-$watcher_key" ] || fail "terminal signal retained watcher pause tracking"
  [ ! -e "$state/.stale-$watcher_key" ] || fail "terminal signal retained watcher stale tracking"
  [ ! -e "$state/.wedge-escalations-$watcher_key" ] || fail "terminal signal retained watcher wedge tracking"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "terminal stale dedupe restored daemon stale tracking"
  pass "a terminal signal clears pause and stale tracking across both supervisors"
}

test_housekeeping_migrates_watcher_pause_marker() {
  local dir state key win
  dir=$(make_supercase migrate-watcher-pause)
  state="$dir/state"
  win="sess:fm-held-w10-migrate"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-migrate.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/held-w10-migrate.status"
  key=$(watch_window_key "$win")
  : > "$state/.paused-$key"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  key=$(printf '%s' "held-w10-migrate" | tr '.:/' '___')
  [ -e "$state/.subsuper-paused-$key" ] || fail "watcher pause marker was not migrated into daemon tracking"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "watcher pause migration left a wedge marker behind"
  pass "housekeeping migrates a normal-watcher's declared pause into daemon tracking"
}

test_housekeeping_migrates_watcher_unpaused_marker_to_clear() {
  local dir state key watcher_key win
  dir=$(make_supercase migrate-watcher-unpaused)
  state="$dir/state"
  win="sess:fm-held-w10-migrate-unpaused"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-migrate-unpaused.meta"
  printf 'working: upstream landed, resuming\n' > "$state/held-w10-migrate-unpaused.status"
  watcher_key=$(watch_window_key "$win")
  : > "$state/.paused-$watcher_key"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  key=$(printf '%s' "held-w10-migrate-unpaused" | tr '.:/' '___')
  [ ! -e "$state/.paused-$watcher_key" ] || fail "stale watcher pause marker was not cleared after resume"
  [ ! -e "$state/.subsuper-paused-$key" ] || fail "unpaused watcher handoff created a daemon pause marker"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "unpaused watcher handoff retained daemon stale tracking"
  [ ! -e "$state/.stale-$watcher_key" ] || fail "unpaused watcher handoff retained watcher stale tracking"
  pass "housekeeping clears an already-resumed watcher pause across both supervisors"
}

test_housekeeping_seeds_pause_marker_from_status() {
  local dir state key win
  dir=$(make_supercase seed-paused-status)
  state="$dir/state"
  win="sess:fm-held-w10-seed"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-seed.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/held-w10-seed.status"
  key=$(printf '%s' "held-w10-seed" | tr '.:/' '___')
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] || fail "paused status did not seed daemon pause tracking"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "paused status seeded wedge tracking"
  pass "housekeeping seeds pause tracking from status without a watcher marker"
}

# housekeeping re-surfaces a stale declared pause only past PAUSE_RESURFACE_SECS,
# as an awaiting-external recheck (never a wedge), and RESETS the marker so the
# window repeats rather than firing once.
test_housekeeping_paused_resurfaces_and_resets() {
  local dir state fakebin win pane key age
  dir=$(make_supercase paused-resurface)
  state="$dir/state"; fakebin="$dir/fakebin"
  win="sess:fm-held-w11"; pane="$dir/pane.txt"
  printf 'paused: holding for the upstream tool release\n' > "$state/held-w11.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w11" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  grep -F "awaiting external" "$state/.subsuper-escalations" >/dev/null 2>&1 || fail "declared pause was not re-surfaced as an awaiting-external recheck"
  grep -F "awaiting the captain" "$state/.subsuper-escalations" >/dev/null 2>&1 && fail "declared pause named the captain instead of its external dependency"
  grep -F "possible wedge" "$state/.subsuper-escalations" >/dev/null 2>&1 && fail "declared pause was mislabeled a possible wedge"
  [ -e "$state/.subsuper-paused-$key" ] || fail "pause marker cleared instead of reset for the next window"
  age=$(( $(date +%s) - $(cat "$state/.subsuper-paused-$key" 2>/dev/null || echo 0) ))
  [ "$age" -lt 60 ] || fail "pause marker was not reset to now on re-surface (age ${age}s)"
  pass "housekeeping re-surfaces a stale declared pause on the long cadence and resets its window"
}

# The other half of quieting a captain-held task: it must NOT be silenced outright.
# fm-classify-lib.sh's cadence comment is explicit that a forgotten hold cannot rot
# invisibly, so a held task re-surfaces on the same bounded window as a pause, with
# its marker reset so the window repeats instead of firing once. The digest the
# captain reads must also name the captain rather than an external dependency: the
# hold is waiting on the one person reading the digest, so borrowing the pause verb's
# awaiting-external wording would point them away from being the blocker.
test_housekeeping_captain_held_resurfaces_and_resets() {
  local dir state fakebin win pane key age
  dir=$(make_supercase captain-held-resurface)
  state="$dir/state"; fakebin="$dir/fakebin"
  win="sess:fm-held-w11h"; pane="$dir/pane.txt"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$state/held-w11h.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w11h" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  grep -F "awaiting the captain" "$state/.subsuper-escalations" >/dev/null 2>&1 || fail "a captain hold was silenced entirely instead of re-surfacing as a captain-owned recheck: $(cat "$state/.subsuper-escalations" 2>/dev/null || true)"
  grep -F "awaiting external" "$state/.subsuper-escalations" >/dev/null 2>&1 && fail "a captain hold was re-surfaced as an external wait, hiding that the captain is the blocker"
  grep -F "possible wedge" "$state/.subsuper-escalations" >/dev/null 2>&1 && fail "a captain hold was re-surfaced as a possible wedge"
  [ -e "$state/.subsuper-paused-$key" ] || fail "captain-held marker cleared instead of reset for the next window"
  age=$(( $(date +%s) - $(cat "$state/.subsuper-paused-$key" 2>/dev/null || echo 0) ))
  [ "$age" -lt 60 ] || fail "captain-held marker was not reset to now on re-surface (age ${age}s)"
  pass "housekeeping re-surfaces a forgotten captain hold on the long cadence and resets its window"
}

# The away record owns the one exception: nobody is there to answer a captain
# hold, so it is never rechecked. Quiet mode's record is a present captain
# (bin/fm-afk-contract.sh AWAY OR QUIET), so a quiet daemon rechecks the same
# hold on the same cadence.
test_housekeeping_captain_held_silenced_only_by_an_away_record() {
  local mode dir state fakebin win pane key
  for mode in away quiet; do
    dir=$(make_supercase "captain-held-$mode-record")
    state="$dir/state"; fakebin="$dir/fakebin"
    win="sess:fm-held-w11r"; pane="$dir/pane.txt"
    printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$state/held-w11r.status"
    printf 'idle prompt $\n' > "$pane"
    key=$(printf '%s' "held-w11r" | tr ':/.' '___')
    echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_AFK_MODE="$mode" "$ROOT/bin/fm-afk-contract.sh" enter --words 'fixture words' >/dev/null 2>&1 \
      || fail "fixture: could not record the $mode posture"
    [ "$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" mode)" = "$mode" ] || fail "fixture: the record is not $mode"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
      FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
    if [ "$mode" = away ]; then
      ! grep -F "awaiting the captain" "$state/.subsuper-escalations" >/dev/null 2>&1 \
        || fail "a captain hold was rechecked while the away record exists: $(cat "$state/.subsuper-escalations")"
    else
      grep -F "awaiting the captain" "$state/.subsuper-escalations" >/dev/null 2>&1 \
        || fail "quiet mode's record silenced a captain hold as if the captain were away: $(cat "$state/.subsuper-escalations" 2>/dev/null || true)"
    fi
  done
  pass "housekeeping silences a captain hold only under an away record, never under quiet mode's"
}

# A crew that RESUMED - whose latest status line no longer declares the wait - drops
# its pause tracking without escalating. The dimension pinned here is that pane busy
# state does not GATE that clear: the status append alone ends the wait, on the
# reconcile path the loop head runs before the pause recheck ever reads a pane, so a
# crew that resumed into a genuinely busy pane cannot hold a stale window open. The
# fixture asserts its own busy verdict first, so it cannot silently decay into an
# idle-pane case (already covered by test_housekeeping_paused_unpaused_cleared) and
# keep claiming that dimension. The inverse - a busy pane that is STILL declaring the
# wait - is test_housekeeping_busy_declared_wait_matures_its_window.
test_housekeeping_paused_resumed_cleared() {
  local dir state fakebin win pane key
  dir=$(make_supercase paused-resumed)
  state="$dir/state"; fakebin="$dir/fakebin"
  win="sess:fm-held-w12"; pane="$dir/pane.txt"
  printf 'paused: holding for the upstream tool release\nworking: upstream landed, resuming\n' \
    > "$state/held-w12.status"
  printf 'Working...\n' > "$pane"
  fm_write_meta "$state/held-w12.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" held-w12)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" held-w12 busy --gen "$gen" \
    --source pi-ext --event agent-start
  key=$(printf '%s' "held-w12" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" stale_window_is_busy "$win" "$state" \
    || fail "the resumed-pause fixture does not actually read busy, so it pins nothing about busy state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] && fail "resumed (busy, no longer declaring) pause marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a resumed pause was escalated"
  pass "a busy pane cannot gate the pause clear once its crew's status no longer declares the wait"
}

# The inverse of test_housekeeping_paused_resumed_cleared, and the first half of
# issue #3149. A declared wait can legitimately hold a pane BUSY - a worker parked on
# a long foreground call it keeps live for as long as the wait lasts - so a busy
# verdict is not evidence that the crew resumed. Reading it as one dropped the marker
# un-escalated, and migrate_watcher_pause_markers recreated it with a fresh timestamp
# on the very next tick, so the window restarted forever and the wait never matured
# into its one recheck. Away mode makes that terminal: the watcher hands a busy
# declared wait to the daemon exactly once per declaration (bin/fm-watch.sh's
# busy_turn_bound_check), so this recheck is the only thing left that can re-surface
# the pane at all. Both declaration forms take the same 2b arm, so both are pinned.
test_housekeeping_busy_declared_wait_matures_its_window() {
  local case_name dir state fakebin task win pane key gen tick age escalations digest
  for case_name in paused captain-held; do
    dir=$(make_supercase "busy-declared-wait-$case_name")
    state="$dir/state"; fakebin="$dir/fakebin"
    task="held-w12b-$case_name"; win="sess:fm-$task"; pane="$dir/pane.txt"
    case "$case_name" in
      paused) printf 'paused: the audit engine is running to completion\n' > "$state/$task.status"
              digest="awaiting external" ;;
      captain-held) printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$state/$task.status"
              digest="awaiting the captain" ;;
    esac
    printf 'Working...\n' > "$pane"
    fm_write_meta "$state/$task.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$task")
    "$ROOT/bin/fm-busy-event.sh" apply "$state" "$task" busy --gen "$gen" \
      --source pi-ext --event agent-start
    key=$(printf '%s' "$task" | tr ':/.' '___')
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
      FM_STATE_OVERRIDE="$state" stale_window_is_busy "$win" "$state" \
      || fail "the $case_name fixture does not actually read busy, so it pins nothing about busy state"

    # Immature window: ticks inside PAUSE_RESURFACE_SECS neither escalate nor let the
    # marker the window ages against be recreated with a fresh timestamp.
    echo $(( $(date +%s) - 100 )) > "$state/.subsuper-paused-$key"
    for tick in 1 2 3; do
      PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
        FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 FM_PAUSE_RESURFACE_SECS=3600 \
        housekeeping "$state"
      [ -e "$state/.subsuper-paused-$key" ] \
        || fail "$case_name busy declared wait lost its marker on tick $tick inside the window"
      age=$(( $(date +%s) - $(cat "$state/.subsuper-paused-$key" 2>/dev/null || echo 0) ))
      [ "$age" -ge 100 ] \
        || fail "$case_name tick $tick restarted the maturing window (age fell to ${age}s)"
    done
    [ ! -s "$state/.subsuper-escalations" ] \
      || fail "$case_name busy declared wait escalated inside its PAUSE_RESURFACE_SECS window"

    # Matured window: exactly one recheck, named for the right human, never a wedge,
    # and the window reset so the next one repeats rather than firing once.
    echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
      FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 FM_PAUSE_RESURFACE_SECS=3600 \
      housekeeping "$state"
    escalations=0
    [ -s "$state/.subsuper-escalations" ] \
      && escalations=$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')
    [ "$escalations" = 1 ] \
      || fail "$case_name busy declared wait produced $escalations escalations past its window, expected exactly one"
    grep -F "$digest" "$state/.subsuper-escalations" >/dev/null \
      || fail "$case_name busy declared wait was not re-surfaced as a '$digest' recheck: $(cat "$state/.subsuper-escalations")"
    grep -F "possible wedge" "$state/.subsuper-escalations" >/dev/null \
      && fail "$case_name busy declared wait was mislabeled a possible wedge"
    [ -e "$state/.subsuper-paused-$key" ] \
      || fail "$case_name busy declared wait cleared its marker instead of resetting the window"
    age=$(( $(date +%s) - $(cat "$state/.subsuper-paused-$key" 2>/dev/null || echo 0) ))
    [ "$age" -lt 60 ] || fail "$case_name busy declared wait did not reset its window to now (age ${age}s)"

    # The next tick, still inside the fresh window, stays silent: one recheck per window.
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
      FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 FM_PAUSE_RESURFACE_SECS=3600 \
      housekeeping "$state"
    escalations=0
    [ -s "$state/.subsuper-escalations" ] \
      && escalations=$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')
    [ "$escalations" = 1 ] \
      || fail "$case_name busy declared wait re-surfaced again inside its reset window ($escalations escalations)"
  done
  pass "housekeeping matures a busy pane's declared-wait window into exactly one recheck per window"
}

# The pause ceiling is opt-in; a case that exercises it arms the home's presence flag.
arm_pause_ceiling() {  # <home-dir>
  mkdir -p "$1/config" && : > "$1/config/pause-ceiling"
}

test_housekeeping_overdue_pause_opens_one_decision_in_away_mode() {
  local dir state fakebin task win pane key statusf marker identity offset blocked actual_identity rc pause_size
  dir=$(make_supercase overdue-pause-away-mode)
  arm_pause_ceiling "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"
  task=overdue-away; win="sess:fm-$task"; pane="$dir/pane.txt"; statusf="$state/$task.status"
  key=$(printf '%s' "$task" | tr ':/.' '___')
  printf 'paused: waiting for dependency\n' > "$statusf"
  pause_size=$(log_size "$statusf")
  printf 'idle prompt $\n' > "$pane"
  fm_write_meta "$state/$task.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  printf '%s\n' "$(( $(date +%s) - 5000 ))" > "$state/.subsuper-paused-$key"
  sleep 2
  FM_STATE_OVERRIDE="$state" . "$ROOT/bin/fm-wake-lib.sh"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 \
    FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"
  ! grep -Fq "blocked [key=paused-overdue-$task]" "$statusf" \
    || fail "attended housekeeping opened an away-only overdue decision"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" enter --words 'fixture words' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 \
    FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"

  blocked="blocked [key=paused-overdue-$task]"
  [ "$(grep -cF "$blocked" "$statusf")" -eq 1 ] \
    || fail "away-mode housekeeping did not append exactly one overdue decision: $(cat "$statusf")"
  marker="$state/.paused-overdue-$task"
  [ -f "$marker" ] || fail "away-mode housekeeping did not preserve the overdue marker"
  IFS=: read -r identity offset < "$marker"
  if [ "$(uname)" = Darwin ]; then
    actual_identity=$(/usr/bin/stat -f '%d %i' "$statusf")
  else
    actual_identity=$(stat -c '%d %i' "$statusf")
  fi
  [ "$identity" = "$actual_identity" ] \
    || fail "away-mode marker is not bound to the status-log identity"
  [ "$offset" = "$pause_size" ] \
    || fail "away-mode marker does not retain the original pause snapshot"
  [ "$(status_seen_offset "$state" "$task")" = "$(log_size "$statusf")" ] \
    || fail "away-mode overdue event was not recorded as reported through its own line"
  [ "$(grep -cF "stale: $win (paused " "$state/.subsuper-escalations")" -eq 1 ] \
    || fail "away-mode overdue recheck did not queue exactly one stale escalation"
  status_open_decisions "$statusf" | grep -F "paused-overdue-$task" >/dev/null \
    || fail "away-mode overdue decision is absent from the open-decision fold"

  printf 'resolved [key=unrelated]: unrelated answer\n' >> "$statusf"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" housekeeping "$state" \
    || fail "daemon housekeeping failed to reconcile unrelated resolution"
  [ -f "$marker" ] || fail "unrelated resolution removed the overdue marker"
  status_open_decisions "$statusf" | grep -F "paused-overdue-$task" >/dev/null \
    || fail "unrelated resolution closed the overdue decision"

  printf 'needs-decision: dependency needs captain input\n' >> "$statusf"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" housekeeping "$state"
  rc=$?
  [ "$rc" -eq 0 ] || fail "daemon housekeeping failed to reconcile a later worker status event (rc=$rc)"
  [ ! -e "$marker" ] || fail "worker resume retained the overdue marker"
  status_open_decisions "$statusf" | grep -F "paused-overdue-$task" >/dev/null \
    && fail "worker resume left the overdue decision open"
  pass "away-mode housekeeping opens one overdue decision and worker resume closes it"
}

test_housekeeping_pause_ceiling_absent_keeps_the_pause_recheck() {
  local dir state fakebin task win pane key statusf before
  dir=$(make_supercase overdue-pause-flag-absent)
  state="$dir/state"; fakebin="$dir/fakebin"
  task=overdue-off; win="sess:fm-$task"; pane="$dir/pane.txt"; statusf="$state/$task.status"
  key=$(printf '%s' "$task" | tr ':/.' '___')
  printf 'paused: waiting for dependency\n' > "$statusf"
  printf 'idle prompt $\n' > "$pane"
  fm_write_meta "$state/$task.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-afk-contract.sh" enter --words 'fixture words' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture"
  printf '%s\n' "$(( $(date +%s) - 5000 ))" > "$state/.subsuper-paused-$key"
  sleep 2
  before=$(cat "$statusf")
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_PAUSE_UNDATED_MAX_SECS=1 FM_PAUSE_RESURFACE_SECS=3600 \
    FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"
  [ "$(cat "$statusf")" = "$before" ] || fail "without config/pause-ceiling housekeeping wrote to the status log: $(cat "$statusf")"
  [ ! -e "$state/.paused-overdue-$task" ] || fail "without config/pause-ceiling housekeeping created an overdue marker"
  [ "$(grep -c . "$state/.subsuper-escalations")" -eq 1 ] \
    || fail "without config/pause-ceiling the pause recheck was not queued exactly once: $(cat "$state/.subsuper-escalations")"
  grep -F "wait overdue" "$state/.subsuper-escalations" >/dev/null \
    && fail "without config/pause-ceiling the recheck asked for an overdue decision"
  pass "without config/pause-ceiling an old away-mode pause keeps the plain pause recheck"
}
