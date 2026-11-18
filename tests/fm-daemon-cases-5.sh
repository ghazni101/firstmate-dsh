# shellcheck shell=bash
# Test cases for fm-daemon, split out of tests/fm-daemon.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-daemon.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2153,SC2329 # cases share setup and helpers with their .test.sh runner


test_max_defer_pending_composer_alarms_without_typing() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-pending-digest)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '╭─────────────────╮\n│ > human draft   │\n╰─────────────────╯\n' > "$dir/composer"
  escalate_add "$state" "needs-decision: pick B"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "max-defer typed into a pending composer"
  [ -s "$state/.subsuper-inject-wedged" ] || fail "pending composer did not raise a wedge alarm marker"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer lost while composer was pending"
  grep -F 'human draft' "$dir/composer" >/dev/null || fail "pending composer content changed"
  pass "max-defer on a pending composer alarms without typing"
}

test_composer_deferral_names_pending_text_or_unrecognized_shape() {
  # A deferral must say WHICH refusal it was: real unsubmitted text is a
  # human's draft, while an unproven composer points at the classifier, the
  # pane, a dead shell, or a busy harness - the case a titled claude rule once
  # hid for hours.
  local dir state fakebin sent log
  dir=$(make_bordered_case composer-deferral-reason)
  state="$dir/state"; fakebin="$dir/fakebin"; log="$dir/daemon.log"
  sent="$dir/sent.log"; : > "$sent"
  afk_enter "$state"
  printf '╭─────────────────╮\n│ > human draft   │\n╰─────────────────╯\n' > "$dir/composer"
  if LOG="$log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    inject_msg "needs-decision: pick B" "$state"; then
    fail "inject_msg typed into a pending composer"
  fi
  grep -F 'inject deferred: supervisor composer not confirmed-empty (state=pending: unsubmitted text in the composer)' "$log" >/dev/null \
    || fail "a pending composer deferral does not name the unsubmitted text: $(cat "$log")"
  : > "$log"
  printf 'build output\nplain transcript line\n' > "$dir/composer"
  if LOG="$log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    inject_msg "needs-decision: pick B" "$state"; then
    fail "inject_msg typed into a screen with no recognized composer"
  fi
  grep -F 'inject deferred: supervisor composer not confirmed-empty (state=unknown: composer not proven empty or pending (unrecognized screen, or harness not idle))' "$log" >/dev/null \
    || fail "an unrecognized screen deferral does not say the composer was not proven empty or pending: $(cat "$log")"
  [ ! -s "$sent" ] || fail "a deferred inject typed text"
  pass "a composer deferral names pending text apart from an unproven composer"
}

test_normal_flush_clears_stale_wedge_marker() {
  local dir state fakebin sent
  dir=$(make_bordered_case normal-clears-wedge)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf 'old wedge\n' > "$state/.subsuper-inject-wedged"
  escalate_add "$state" "done: PR https://x/y/pull/2"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state" \
    || fail "normal escalate_flush failed"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after normal flush"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge marker survived successful normal flush"
  pass "normal flush clears a stale wedge marker"
}

# The start-up catch-all scan turns each status log's unread span into one
# buffered item, so a first digest can exceed the 131,071 bytes one transport
# argument can carry. The fake tmux refuses any literal send above that.
test_oversized_digest_is_bounded_and_kept_durable() {
  local dir state fakebin sent raw digest full i item
  dir=$(make_bordered_case digest-oversized)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  for i in a b c; do
    item="secondmate-$i.status: "
    while [ "${#item}" -lt 60000 ]; do item+="done: café fix shipped, PR https://x/y/pull/1 ; "; done
    escalate_add "$state" "$item (catch-all scan)"
  done
  escalate_add "$state" "secondmate-a.status: needs-decision [key=pick]: pick A or B"
  cp "$state/.subsuper-escalations" "$dir/buffer.orig"
  raw=$(LC_ALL=C wc -c < "$dir/buffer.orig" | tr -d ' ')
  [ "$raw" -gt 131071 ] || fail "fixture buffer is only $raw bytes; it must exceed one argument's 131,071-byte ceiling"
  afk_enter "$state"
  LOG="$dir/daemon.log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SEND_MAX_BYTES=131071 FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state" \
    || fail "oversized digest was not delivered: $(cat "$dir/daemon.log" 2>/dev/null)"
  digest=$(delivered_digest "$sent" | grep -F 'Supervisor escalate')
  [ "$(printf '%s\n' "$digest" | wc -l | tr -d ' ')" -eq 1 ] || fail "expected exactly one typed digest"
  [ "$(printf '%s' "$digest" | LC_ALL=C wc -c | tr -d ' ')" -le 16384 ] \
    || fail "delivered digest is not bounded well below the transport ceilings"
  assert_contains "$digest" 'Supervisor escalate (4 event(s)): secondmate-a.status: done:' "digest lost its header or first event"
  assert_contains "$digest" 'secondmate-a.status: needs-decision [key=pick]: pick A or B' "a short event did not survive whole"
  printf '%s' "$digest" | grep -E '\[\+[0-9]+ bytes\]' >/dev/null || fail "truncated items carry no omitted-bytes marker"
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$digest" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || fail "truncation split a UTF-8 sequence"
  fi
  full=$(printf '%s' "$digest" | sed -n 's/.*full text of every event: \([^ )]*\).*/\1/p')
  [ -n "$full" ] && [ -f "$full" ] || fail "bounded digest names no readable full-text file: $digest"
  cmp -s "$full" "$dir/buffer.orig" || fail "full-text file does not hold every buffered event verbatim"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after the bounded digest was delivered"
  pass "an oversized buffered digest is delivered bounded, with the full text kept durable"
}

test_digest_budget_counts_omitted_events() {
  local dir state fakebin sent digest full i shown more
  dir=$(make_bordered_case digest-many)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  for i in $(seq 1 20); do
    escalate_add "$state" "event $i: $(printf 'x%.0s' $(seq 1 1000))"
  done
  cp "$state/.subsuper-escalations" "$dir/buffer.orig"
  afk_enter "$state"
  LOG="$dir/daemon.log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state" || fail "many-event digest was not delivered"
  digest=$(delivered_digest "$sent" | grep -F 'Supervisor escalate')
  assert_contains "$digest" 'Supervisor escalate (20 event(s)): event 1: x' "digest header must count every buffered event"
  more=$(printf '%s' "$digest" | sed -n 's/.* | +\([0-9][0-9]*\) more event(s).*/\1/p')
  [ -n "$more" ] || fail "an exhausted budget left no '+K more event(s)' tail: $digest"
  shown=$(printf '%s' "$digest" | grep -o 'event [0-9][0-9]*: x' | wc -l | tr -d ' ')
  [ "$((shown + more))" -eq 20 ] || fail "shown ($shown) plus omitted ($more) events do not account for all 20"
  full=$(printf '%s' "$digest" | sed -n 's/.*full text of every event: \([^ )]*\).*/\1/p')
  cmp -s "$full" "$dir/buffer.orig" || fail "omitted events are missing from the full-text file"
  pass "a digest past its byte budget counts the omitted events and keeps them in the full text"
}

test_inject_send_failure_logs_stage_stderr_and_bytes() {
  local dir state fakebin sent log item
  dir=$(make_bordered_case digest-send-failure)
  state="$dir/state"; fakebin="$dir/fakebin"; log="$dir/daemon.log"
  sent="$dir/sent.log"; : > "$sent"
  item="secondmate-b.status: "
  while [ "${#item}" -lt 5000 ]; do item+="blocked: waiting on review ; "; done
  escalate_add "$state" "$item"
  cp "$state/.subsuper-escalations" "$dir/buffer.orig"
  afk_enter "$state"
  if LOG="$log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SEND_MAX_BYTES=100 FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state"; then
    fail "escalate_flush reported success although the transport refused the send"
  fi
  grep -E 'inject failed at initial send or Enter delivery \(verdict=send-failed, bytes=[0-9]+;[^)]*\): command too long' "$log" >/dev/null \
    || fail "send failure did not log its stage, byte count, and transport stderr: $(cat "$log")"
  if grep -F 'Enter confirmation' "$log" >/dev/null; then
    fail "an initial-send failure was reported as an Enter-confirmation failure: $(cat "$log")"
  fi
  [ ! -s "$sent" ] || fail "nothing may be typed when the initial send fails"
  cmp -s "$state/.subsuper-escalations" "$dir/buffer.orig" || fail "buffer changed after a failed send"
  if LOG="$log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SEND_MAX_BYTES=100 FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state"; then
    fail "escalate_flush reported success on a retried refused send"
  fi
  [ "$(find "$state/.subsuper-digests" -type f | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "retrying an unchanged buffer must reuse one full-text file: $(ls -A "$state/.subsuper-digests")"
  WEDGE_ALARM_LAST_EPOCH=0
  LOG="$log" FM_WEDGE_ALARM_CHANNEL=off FM_SUPERVISOR_BACKEND=herdr inject_wedge_alarm "$state" 600
  grep -E 'ERROR: away-mode escalation undelivered 600s; last delivery failure: initial send .*command too long' "$log" >/dev/null \
    || fail "wedge line does not carry the last failure reason: $(cat "$log")"
  grep -F 'Last delivery failure: initial send' "$state/.subsuper-inject-wedged" >/dev/null \
    || fail "wedge marker does not carry the last failure reason"
  pass "an initial-send failure logs its stage, bytes, and stderr, and the wedge alarm names it"
}

test_inject_enter_failure_logs_confirmation_stage() {
  local dir state fakebin sent log
  dir=$(make_bordered_case digest-enter-failure)
  state="$dir/state"; fakebin="$dir/fakebin"; log="$dir/daemon.log"
  sent="$dir/sent.log"; : > "$sent"
  touch "$dir/.swallow"
  escalate_add "$state" "needs-decision: pick C"
  afk_enter "$state"
  if LOG="$log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_INJECT_CONFIRM_SLEEP=0.05 \
    escalate_flush "$state"; then
    fail "escalate_flush reported success on a swallowed Enter"
  fi
  grep -E 'inject failed at Enter confirmation: submit unconfirmed after 3 retries \(verdict=pending[a-z-]*, bytes=[0-9]+, text may be in composer\)' "$log" >/dev/null \
    || fail "Enter-confirmation failure did not log its stage and byte count: $(cat "$log")"
  if grep -F 'initial send' "$log" >/dev/null; then
    fail "an Enter-confirmation failure was reported as an initial-send failure"
  fi
  pass "an Enter-confirmation failure logs its own stage and byte count"
}

test_bounded_digest_full_text_kept_after_typing() {
  local dir state fakebin sent log item digest full
  dir=$(make_bordered_case digest-kept-after-typing)
  state="$dir/state"; fakebin="$dir/fakebin"; log="$dir/daemon.log"
  sent="$dir/sent.log"; : > "$sent"
  touch "$dir/.swallow"
  item="secondmate-c.status: "
  while [ "${#item}" -lt 5000 ]; do item+="blocked: waiting on review ; "; done
  escalate_add "$state" "$item"
  cp "$state/.subsuper-escalations" "$dir/buffer.orig"
  afk_enter "$state"
  if LOG="$log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_INJECT_CONFIRM_SLEEP=0.05 \
    escalate_flush "$state"; then
    fail "escalate_flush reported success on a swallowed Enter"
  fi
  digest=$(delivered_digest "$sent" | grep -F 'Supervisor escalate')
  full=$(printf '%s' "$digest" | sed -n 's/.*full text of every event: \([^ )]*\).*/\1/p')
  [ -n "$full" ] && [ -f "$full" ] || fail "a typed bounded digest names a full-text file that was removed: $digest"
  cmp -s "$full" "$dir/buffer.orig" || fail "kept full-text file does not hold the buffered event verbatim"
  if LOG="$log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state"; then
    fail "escalate_flush reported success while the composer still held the typed digest"
  fi
  [ -f "$full" ] || fail "a deferred retry removed the full-text file the typed digest names"
  escalate_add "$state" "needs-decision: pick D"
  if LOG="$log" PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state"; then
    fail "escalate_flush reported success while the composer still held the typed digest"
  fi
  [ "$(ls -A "$state/.subsuper-digests")" = "$(basename "$full")" ] \
    || fail "a deferral before any send must leave no new full-text file: $(ls -A "$state/.subsuper-digests")"
  pass "a bounded digest's full-text file survives a failure after typing, and a deferral writes none"
}

test_below_max_defer_does_nothing() {
  local dir state fakebin sent capture
  dir=$(make_supercase below-maxdefer)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf 'stuck junk line\n' > "$capture"
  escalate_add "$state" "needs-decision: pick A"
  date +%s > "$state/.subsuper-escalations.since"   # just now
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=300 housekeeping "$state"
  [ ! -s "$sent" ] || fail "injected before MAX_DEFER elapsed"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm fired before MAX_DEFER"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer dropped below MAX_DEFER"
  pass "below MAX_DEFER: no inject, no alarm, buffer preserved"
}

test_max_defer_afk_inactive_does_not_flush_or_alarm() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-inactive)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  escalate_add "$state" "needs-decision: pick B"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "injected while afk was inactive"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm fired while afk was inactive"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer dropped while afk was inactive"
  pass "max-defer does not flush or alarm while afk is inactive"
}

# --- backend-independent active wedge alert ---------------------------------
# These cover the 2026-07-10 overnight-incident fix: the max-defer wedge alarm's
# ACTIVE alert channel must reach the captain even when the wedged pane and its
# backend status-line are unreadable (a claude-on-herdr primary that night).
#
# NO test here EVER posts a real notification. Every notifier routes through
# the FM_WEDGE_ALARM_EXEC seam, which tests/wake-helpers.sh forces to a recorder
# ($FM_WEDGE_ALARM_LOG logs "<channel>\t<summary>"); the daemon also defaults
# that seam to "discard" whenever it is sourced. Assertions read the recorder
# log, so they verify channel SELECTION and summary propagation; the real
# osascript/herdr argv is verified once by the bounded manual evidence in
# docs/wedge-alarm.md, never from a suite.
make_wedge_case() {  # <name> -> echoes dir; creates state/, fakebin/{uname,osascript,herdr}, alert.log
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  # Fake uname so `auto` platform resolution is deterministic on any CI host.
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_UNAME:-Darwin}"
SH
  # Fakes keep command discovery deterministic on any CI host.
  cat > "$fakebin/osascript" <<'SH'
#!/usr/bin/env bash
printf '%s\n' osascript >> "${FM_WEDGE_ALARM_REAL_LOG:-/dev/null}"
exit 0
SH
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' herdr >> "${FM_WEDGE_ALARM_REAL_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/uname" "$fakebin/osascript" "$fakebin/herdr"
  : > "$dir/alert.log"
  printf '%s\n' "$dir"
}

test_wedge_alarm_library_mode_defaults_to_discard() {
  # The structural guarantee: sourcing the daemon with NO seam configured defaults
  # FM_WEDGE_ALARM_EXEC to "discard", so a sourced context (every test) cannot
  # fire a real notification even if it forgets to stub. Checked in a clean
  # subshell that first unsets this harness's recorder.
  local out
  # shellcheck disable=SC2016  # $1/$FM_WEDGE_ALARM_EXEC must expand in the child, not here
  out=$(env -u FM_WEDGE_ALARM_EXEC bash -c '. "$1"; printf "%s" "${FM_WEDGE_ALARM_EXEC:-UNSET}"' _ "$DAEMON")
  [ "$out" = discard ] \
    || fail "sourcing the daemon did not default the notifier seam to discard (got: $out)"
  pass "library mode: sourcing the daemon defaults FM_WEDGE_ALARM_EXEC to discard (no test can fire a real notification)"
}

test_wake_helpers_replace_inherited_notifier_override() {
  local dir unsafe_log alert_log unsafe
  dir=$(make_wedge_case wedge-inherited-override)
  unsafe_log="$dir/unsafe.log"
  alert_log="$dir/alert.log"
  unsafe="$dir/unsafe-override"
  cat > "$unsafe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' invoked >> "${FM_WEDGE_ALARM_UNSAFE_LOG:?}"
SH
  chmod +x "$unsafe"
  FM_WEDGE_ALARM_EXEC="$unsafe" FM_WEDGE_ALARM_UNSAFE_LOG="$unsafe_log" \
    FM_WEDGE_ALARM_LOG="$alert_log" FM_WEDGE_ALARM_CHANNEL=osascript \
    bash -c '. "$1"; . "$2"; wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"' \
      _ "$ROOT/tests/wake-helpers.sh" "$DAEMON"
  [ ! -s "$unsafe_log" ] || fail "wake helpers preserved an inherited notifier override"
  grep -F 'osascript' "$alert_log" >/dev/null \
    || fail "wake helpers did not install the safe notifier recorder"
  pass "wake helpers replace inherited notifier overrides with the safe recorder"
}

test_wedge_alarm_discard_seam_fires_nothing() {
  local dir log command_output channel
  dir=$(make_wedge_case wedge-discard); log="$dir/alert.log"
  command_output="$dir/command-output"
  channel="command: printf '%s' \"\$1\" > '$command_output'"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_EXEC=discard \
    FM_WEDGE_ALARM_CHANNEL=$'osascript\nherdr\n'"$channel" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  [ ! -s "$log" ] || fail "the discard seam still fired a notifier: $(cat "$log")"
  [ ! -e "$command_output" ] || fail "the discard seam still fired a command: notifier"
  pass "the discard seam suppresses every notifier, including command: (fires nothing)"
}

test_wedge_alarm_direct_notifiers_honor_discard_seam() {
  local dir real_log command_output command
  dir=$(make_wedge_case wedge-direct-discard); real_log="$dir/real.log"
  command_output="$dir/command-output"
  command="printf '%s' \"\$1\" > '$command_output'"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_REAL_LOG="$real_log" FM_WEDGE_ALARM_EXEC=discard \
    wedge_alarm_via_osascript "away-mode WEDGED 900s"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_REAL_LOG="$real_log" FM_WEDGE_ALARM_EXEC=discard \
    wedge_alarm_via_herdr "away-mode WEDGED 900s"
  FM_WEDGE_ALARM_EXEC=discard wedge_alarm_via_command "$command" "away-mode WEDGED 900s"
  [ ! -s "$real_log" ] || fail "direct notifier helpers bypassed the discard seam: $(cat "$real_log")"
  [ ! -e "$command_output" ] || fail "direct command helper bypassed the discard seam"
  pass "direct notifier helpers honor the discard seam, including command:"
}

test_wedge_alarm_osascript_channel_selected() {
  local dir log
  dir=$(make_wedge_case wedge-osascript); log="$dir/alert.log"
  FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_CHANNEL=osascript \
    wedge_alarm_notify "away-mode escalations WEDGED 600s undelivered - see /s/.marker" "/s/.marker"
  grep -F 'osascript' "$log" >/dev/null || fail "osascript channel not routed through the notifier seam: $(cat "$log")"
  grep -F 'WEDGED 600s undelivered' "$log" >/dev/null || fail "osascript channel did not carry the summary"
  grep -F 'herdr' "$log" >/dev/null && fail "osascript-only config also selected herdr"
  pass "osascript channel routes through the notifier seam with the summary (never a real notification)"
}

test_wedge_alarm_herdr_channel_selected() {
  local dir log
  dir=$(make_wedge_case wedge-herdr); log="$dir/alert.log"
  FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_CHANNEL=herdr \
    wedge_alarm_notify "away-mode escalations WEDGED 800s undelivered - see /s/.marker" "/s/.marker"
  grep -F 'herdr' "$log" >/dev/null || fail "herdr channel not routed through the notifier seam: $(cat "$log")"
  grep -F 'WEDGED 800s undelivered' "$log" >/dev/null || fail "herdr channel did not carry the summary"
  grep -F 'osascript' "$log" >/dev/null && fail "herdr-only config also selected osascript"
  pass "herdr channel routes through the notifier seam with the summary (never a real notification)"
}

test_wedge_alarm_rex_channel_selected() {
  local dir log
  dir=$(make_wedge_case wedge-rex); log="$dir/alert.log"
  FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_CHANNEL=rex FM_SUPERVISOR_BACKEND=rex \
    wedge_alarm_notify "away-mode escalations WEDGED 700s undelivered - see /s/.marker" "/s/.marker"
  grep -F 'rex' "$log" >/dev/null || fail "rex channel not routed through the notifier seam: $(cat "$log")"
  grep -F 'WEDGED 700s undelivered' "$log" >/dev/null || fail "rex channel did not carry the summary"
  grep -F 'osascript' "$log" >/dev/null && fail "rex-only config also selected osascript"
  pass "rex channel routes through the notifier seam with the summary (never a real pane write)"
}

test_wedge_alarm_auto_never_selects_rex() {
  local dir log
  dir=$(make_wedge_case wedge-auto-rex); log="$dir/alert.log"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_LOG="$log" FM_FAKE_UNAME=Darwin FM_WEDGE_ALARM_CHANNEL=auto \
    FM_SUPERVISOR_BACKEND=rex wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  grep -F 'osascript' "$log" >/dev/null || fail "auto on Darwin did not select osascript: $(cat "$log")"
  grep -E '^rex' "$log" >/dev/null && fail "auto selected the opt-in rex channel on a Rex supervisor: $(cat "$log")"
  pass "auto never adds the opt-in rex channel, even on a Rex supervisor pane"
}

test_wedge_alarm_command_channel_receives_summary() {
  local dir out_argv out_stdin chan
  dir=$(make_wedge_case wedge-command)
  out_argv="$dir/argv.txt"; out_stdin="$dir/stdin.txt"
  chan="command: printf '%s' \"\$1\" > '$out_argv'; cat > '$out_stdin'"
  FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_CHANNEL="$chan" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  [ "$(cat "$out_argv" 2>/dev/null)" = "away-mode WEDGED 900s" ] || fail "command channel did not receive the summary on \$1"
  grep -F 'away-mode WEDGED 900s' "$out_stdin" >/dev/null || fail "command channel did not receive the summary on stdin"
  pass "command channel runs the captain command with the summary on \$1 and on stdin"
}

test_wedge_alarm_command_failure_hides_configured_command() {
  local dir daemon_log secret rc
  dir=$(make_wedge_case wedge-command-redaction); daemon_log="$dir/daemon.log"
  secret="https://alerts.example.invalid/hook?token=private-wedge-token"
  LOG="$daemon_log" FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_CHANNEL="command:exit 73 # $secret" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  rc=$?
  [ "$rc" -eq 0 ] || fail "a failed command channel made wedge_alarm_notify return non-zero ($rc)"
  grep -F 'command channel exited 73 (command redacted)' "$daemon_log" >/dev/null \
    || fail "command channel failure did not log its exit status: $(cat "$daemon_log" 2>/dev/null)"
  grep -F "$secret" "$daemon_log" >/dev/null \
    && fail "command channel failure leaked its configured command: $(cat "$daemon_log")"
  pass "command channel failures redact configured commands while logging their exit status"
}

test_wedge_alarm_unknown_channel_hides_configured_directive() {
  local dir daemon_log secret rc
  dir=$(make_wedge_case wedge-unknown-redaction); daemon_log="$dir/daemon.log"
  secret="https://alerts.example.invalid/hook?token=private-wedge-token"
  LOG="$daemon_log" FM_WEDGE_ALARM_CHANNEL="webhook:$secret" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  rc=$?
  [ "$rc" -eq 0 ] || fail "an unknown channel made wedge_alarm_notify return non-zero ($rc)"
  grep -F 'unrecognized active-alert channel directive (redacted); marker still written' "$daemon_log" >/dev/null \
    || fail "an unknown channel did not log the redacted directive category: $(cat "$daemon_log" 2>/dev/null)"
  grep -F "$secret" "$daemon_log" >/dev/null \
    && fail "an unknown channel leaked its configured directive: $(cat "$daemon_log")"
  pass "unknown channel directives are redacted while the alarm keeps running"
}

test_wedge_alarm_off_disables_active_alert_regardless_of_position() {
  local dir log directives
  dir=$(make_wedge_case wedge-off); log="$dir/alert.log"
  for directives in $'osascript\noff' $'off\nosascript'; do
    : > "$log"
    FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_CHANNEL="$directives" \
      wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
    [ ! -s "$log" ] || fail "off did not disable a preceding or following active alert: $(cat "$log")"
  done
  pass "off disables every active alert regardless of directive position (marker and tmux flash are unaffected)"
}

test_wedge_alarm_auto_darwin_selects_osascript() {
  local dir log
  dir=$(make_wedge_case wedge-auto-darwin); log="$dir/alert.log"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_LOG="$log" FM_FAKE_UNAME=Darwin FM_WEDGE_ALARM_CHANNEL=auto \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  grep -F 'osascript' "$log" >/dev/null || fail "auto did not resolve to osascript on Darwin: $(cat "$log")"
  pass "auto resolves to the macOS osascript notifier on Darwin (default-on)"
}

test_wedge_alarm_auto_non_darwin_has_no_os_channel() {
  local dir log
  dir=$(make_wedge_case wedge-auto-linux); log="$dir/alert.log"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_LOG="$log" FM_FAKE_UNAME=Linux FM_WEDGE_ALARM_CHANNEL=auto \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  [ ! -s "$log" ] || fail "auto selected a built-in OS channel on a non-macOS platform: $(cat "$log")"
  pass "auto on a non-macOS platform selects no built-in OS channel (the marker or a configured command carries it)"
}

test_wedge_alarm_config_file_multi_channel() {
  local dir cfgdir log
  dir=$(make_wedge_case wedge-config); log="$dir/alert.log"
  cfgdir="$dir/config"; mkdir -p "$cfgdir"
  printf '# active alert channels\n\nosascript\nherdr\n' > "$cfgdir/wedge-alarm"
  FM_WEDGE_ALARM_LOG="$log" FM_CONFIG_OVERRIDE="$cfgdir" \
    wedge_alarm_notify "away-mode WEDGED 700s" "/s/.marker"
  grep -F 'osascript' "$log" >/dev/null || fail "config/wedge-alarm osascript line was not selected"
  grep -F 'herdr' "$log" >/dev/null || fail "config/wedge-alarm herdr line was not selected"
  pass "config/wedge-alarm selects every configured channel and skips comment and blank lines"
}

test_wedge_alarm_failing_channel_degrades_gracefully() {
  local dir log rc
  dir=$(make_wedge_case wedge-degrade); log="$dir/alert.log"
  FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_FAIL=osascript \
    FM_WEDGE_ALARM_CHANNEL=$'osascript\nherdr' \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  rc=$?
  [ "$rc" -eq 0 ] || fail "a failing channel made wedge_alarm_notify return non-zero ($rc)"
  grep -F 'osascript' "$log" >/dev/null || fail "the failing osascript channel was not even attempted"
  grep -F 'herdr' "$log" >/dev/null || fail "a failing earlier channel prevented the herdr channel from firing"
  pass "a failing channel logs and falls back to the next channel, never crashing the alarm"
}

test_wedge_alarm_hung_channel_times_out_and_falls_through() {
  local dir daemon_log output channel start elapsed
  dir=$(make_wedge_case wedge-timeout); daemon_log="$dir/daemon.log"; output="$dir/fallback-output"
  channel="command: printf '%s' \"\$1\" > '$output'"
  start=$SECONDS
  LOG="$daemon_log" FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_TIMEOUT_SECS=1 \
    FM_WEDGE_ALARM_CHANNEL=$'command:sleep 30\n'"$channel" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 5 ] || fail "a hung wedge notifier blocked the alarm for ${elapsed}s"
  grep -F 'command notifier timed out' "$daemon_log" >/dev/null \
    || fail "a hung wedge notifier did not log its timeout: $(cat "$daemon_log" 2>/dev/null)"
  [ "$(cat "$output" 2>/dev/null)" = "away-mode WEDGED 900s" ] \
    || fail "a timed-out command notifier prevented the next channel"
  pass "a hung notifier is bounded, logged, and falls through to the next channel"
}

test_wedge_alarm_backgrounded_command_times_out_and_reaps_descendant() {
  local dir daemon_log child_file child command
  dir=$(make_wedge_case wedge-backgrounded-timeout)
  daemon_log="$dir/daemon.log"
  child_file="$dir/notifier-child"
  command="sleep 30 & printf '%s' \"\$!\" > '$child_file'"
  LOG="$daemon_log" FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_TIMEOUT_SECS=1 \
    wedge_alarm_via_command "$command" "away-mode WEDGED 900s"
  [ -s "$child_file" ] || fail "the backgrounded notifier did not record its descendant"
  child=$(cat "$child_file")
  grep -F 'command notifier timed out' "$daemon_log" >/dev/null \
    || fail "a backgrounded command notifier bypassed its timeout: $(cat "$daemon_log" 2>/dev/null)"
  if is_live_non_zombie "$child"; then
    kill -TERM "$child" 2>/dev/null || true
    fail "a timed-out command notifier left its descendant running (pid $child)"
  fi
  pass "a backgrounded command notifier remains bounded until its process group is reaped"
}

test_wedge_alarm_hung_override_times_out_and_falls_through() {
  local dir blocker daemon_log start elapsed
  dir=$(make_wedge_case wedge-override-timeout)
  blocker="$dir/blocker"; daemon_log="$dir/daemon.log"
  cat > "$blocker" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$blocker"
  start=$SECONDS
  LOG="$daemon_log" FM_WEDGE_ALARM_EXEC="$blocker" FM_WEDGE_ALARM_TIMEOUT_SECS=1 \
    FM_WEDGE_ALARM_CHANNEL=$'osascript\nherdr' \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 6 ] || fail "a hung wedge notifier override blocked the alarm for ${elapsed}s"
  grep -F 'osascript notifier timed out' "$daemon_log" >/dev/null \
    || fail "a hung notifier override did not log its timeout: $(cat "$daemon_log" 2>/dev/null)"
  grep -F 'herdr notifier timed out' "$daemon_log" >/dev/null \
    || fail "a hung notifier override prevented the next channel: $(cat "$daemon_log" 2>/dev/null)"
  pass "a hung notifier override is bounded, logged, and proceeds to the next channel"
}

test_wedge_alarm_shutdown_stops_active_notifier_group() {
  local dir child_file pid child
  dir=$(make_wedge_case wedge-shutdown)
  child_file="$dir/notifier-child"
  (
    set -m
    sh -c 'sleep 30 & printf "%s" "$!" > "$1"; wait' sh "$child_file" &
    pid=$!
    while [ ! -s "$child_file" ]; do sleep 0.05; done
    child=$(cat "$child_file")
    WEDGE_ALARM_NOTIFIER_PID=$pid
    wedge_alarm_stop_active_notifier
    if kill -0 "$child" 2>/dev/null; then
      fail "shutdown left a notifier descendant running (pid $child)"
    fi
  ) || fail "notifier shutdown cleanup helper failed"
  pass "daemon shutdown stops and reaps the active notifier process group"
}

test_inject_wedge_alarm_fires_active_alert_on_non_tmux_backend() {
  # The whole incident: a non-tmux (herdr) primary gets NO tmux status-line
  # flash, so inject_wedge_alarm must still emit the backend-independent alert
  # alongside the durable marker.
  local dir state log
  dir=$(make_wedge_case wedge-integration); state="$dir/state"; log="$dir/alert.log"
  escalate_add "$state" "needs-decision: pick A"
  WEDGE_ALARM_LAST_EPOCH=0
  FM_WEDGE_ALARM_LOG="$log" FM_STATE_OVERRIDE="$state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_SUPERVISOR_BACKEND=herdr \
    inject_wedge_alarm "$state" 30600
  [ -s "$state/.subsuper-inject-wedged" ] || fail "inject_wedge_alarm did not write the durable marker"
  grep -F 'osascript' "$log" >/dev/null || fail "inject_wedge_alarm did not emit the active alert on a non-tmux backend: $(cat "$log")"
  grep -F 'WEDGED 30600s' "$log" >/dev/null || fail "active alert missing the age and summary"
  pass "inject_wedge_alarm writes the marker AND emits the active alert even with no tmux status-line (herdr backend)"
}

test_inject_wedge_alarm_throttles_when_marker_cannot_be_written() {
  local dir state log daemon_log alerts errors
  dir=$(make_wedge_case wedge-unwritable-marker)
  state="$dir/state"; log="$dir/alert.log"; daemon_log="$dir/daemon.log"
  escalate_add "$state" "needs-decision: pick A"
  chmod u-w "$state"
  WEDGE_ALARM_LAST_EPOCH=0
  LOG="$daemon_log" FM_WEDGE_ALARM_LOG="$log" FM_MAX_DEFER_SECS=600 \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_SUPERVISOR_BACKEND=herdr \
    inject_wedge_alarm "$state" 30600
  LOG="$daemon_log" FM_WEDGE_ALARM_LOG="$log" FM_MAX_DEFER_SECS=600 \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_SUPERVISOR_BACKEND=herdr \
    inject_wedge_alarm "$state" 30615
  chmod u+w "$state"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge marker unexpectedly persisted in an unwritable state directory"
  alerts=$(grep -c 'osascript' "$log" 2>/dev/null || true)
  [ "$alerts" -eq 1 ] || fail "unwritable marker emitted $alerts active alerts instead of one"
  errors=$(grep -c 'ERROR: away-mode escalation undelivered' "$daemon_log" 2>/dev/null || true)
  [ "$errors" -eq 1 ] || fail "unwritable marker logged $errors wedge errors instead of one"
  pass "in-process wedge throttle prevents alert spam when the marker cannot persist"
}

test_fm_send_reports_delivered_unconfirmed_submit() {
  # When typed-plane text was typed and Enter sent but the submit read-back
  # remains pending, fm-send must return its documented delivered-unconfirmed status and prevent
  # a duplicate resend reflex. A synchronously confirmed submit remains zero.
  local dir fakebin err rc
  dir=$(make_bordered_case send-swallow)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  # Clean submit -> exit 0.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_SEND_SLEEP=0.05 "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err" \
    || fail "fm-send exited non-zero on a clean submit: $(cat "$err")"
  # Persistent composer text after Enter -> delivered-unconfirmed exit 3 with
  # a non-error warning that explicitly tells the operator not to resend.
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/composer"
  touch "$dir/.swallow"
  if PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'fix findings 1 and 3, skip 2' >/dev/null 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 3 ] || fail "fm-send returned $rc instead of delivered-unconfirmed exit 3: $(cat "$err")"
  grep -F 'submission is unconfirmed' "$err" >/dev/null \
    || fail "fm-send did not explain the pending confirmation: $(cat "$err")"
  grep -F 'do not retype or blindly resend' "$err" >/dev/null \
    || fail "fm-send did not prevent a duplicate resend: $(cat "$err")"
  if grep -F 'error:' "$err" >/dev/null; then
    fail "fm-send mislabeled delivered-unconfirmed as an error: $(cat "$err")"
  fi
  pass "fm-send returns 3 with a non-error no-resend warning when confirmation stays pending"
}

test_fm_send_exits_nonzero_on_initial_send_failure() {
  local dir fakebin err
  dir=$(make_bordered_case send-type-failure)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  if PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SEND_FAIL=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err"; then
    fail "fm-send exited zero despite initial tmux send-keys failure"
  fi
  grep -F 'text not sent' "$err" >/dev/null || fail "fm-send did not explain initial send failure: $(cat "$err")"
  pass "fm-send exits non-zero when initial text send fails"
}

test_fm_send_exits_nonzero_on_unproven_submit() {
  local dir fakebin err
  dir=$(make_bordered_case send-unproven)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  touch "$dir/.swallow"
  if PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win '修复' >/dev/null 2>"$err"; then
    fail "fm-send exited zero when submit proof remained pending-unproven"
  fi
  grep -F 'verdict=pending-unproven' "$err" >/dev/null \
    || fail "fm-send did not preserve the unproven-submit verdict: $(cat "$err")"
  pass "fm-send exits non-zero unless delivery is proven empty"
}

# --- herdr backend-awareness (fm-turnend-guard-h6-adjacent transport fix) ----
# Discovery, busy/pending dispatch, and the full inject_msg guard chain must
# work through the herdr backend, not just tmux. Env-var prefix assignments
# (e.g. `TMUX_PANE= HERDR_ENV=1 ... discover_supervisor_target`) neutralize
# whatever ambient TMUX_PANE/HERDR_ENV the CURRENT dev/CI shell happens to carry
# for the duration of that one call only, so these tests are deterministic
# regardless of what runtime backend is running this test suite itself.

test_discover_supervisor_backend_precedence() {
  local out
  out=$(FM_SUPERVISOR_BACKEND=herdr TMUX_PANE='%9' HERDR_ENV=1 HERDR_PANE_ID=w1:p1 discover_supervisor_backend)
  [ "$out" = herdr ] || fail "explicit FM_SUPERVISOR_BACKEND override was not honored: $out"

  out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='%9' HERDR_ENV=1 HERDR_PANE_ID=w1:p1 discover_supervisor_backend)
  [ "$out" = tmux ] || fail "TMUX_PANE should win over HERDR_ENV (tmux nested in herdr resolves to tmux): $out"

  out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p1 discover_supervisor_backend)
  [ "$out" = herdr ] || fail "HERDR_ENV=1 with HERDR_PANE_ID present should resolve to herdr: $out"

  # The adapter reads its bearer from FM_BACKEND_CONFIG_DIR (pinned when
  # fm-backend.sh was sourced); pointing it at no bearer keeps the t3code rule
  # closed whatever T3 state this dev box carries.
  if out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' FM_BACKEND_CONFIG_DIR="$TMP_ROOT/no-t3" discover_supervisor_backend); then
    fail "bare fallback (no override, no TMUX_PANE, no HERDR_ENV, no T3 bearer) should return non-zero"
  fi
  [ "$out" = tmux ] || fail "bare fallback should still print tmux: $out"

  pass "discover_supervisor_backend: override > TMUX_PANE > HERDR_ENV+HERDR_PANE_ID > tmux fallback"
}

test_discover_supervisor_target_herdr() {
  local out
  out=$(FM_SUPERVISOR_TARGET=explicit:target TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 discover_supervisor_target)
  [ "$out" = "explicit:target" ] || fail "explicit FM_SUPERVISOR_TARGET override was not honored: $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='%3' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 discover_supervisor_target)
  [ "$out" = '%3' ] || fail "TMUX_PANE should win over herdr markers: $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SESSION='' discover_supervisor_target)
  [ "$out" = "default:w1:p9" ] || fail "herdr target should default HERDR_SESSION to 'default': $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SESSION=iso1 discover_supervisor_target)
  [ "$out" = "iso1:w1:p9" ] || fail "herdr target should use an explicit HERDR_SESSION: $out"

  if out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' FM_BACKEND_CONFIG_DIR="$TMP_ROOT/no-t3" discover_supervisor_target); then
    fail "bare fallback should return non-zero"
  fi
  [ "$out" = "firstmate:0" ] || fail "bare fallback should still print firstmate:0: $out"

  pass "discover_supervisor_target: override > TMUX_PANE > herdr '<session>:<pane-id>' composition > firstmate:0 fallback"
}

# --- hc supervisor discovery (fm-herdr-core-s3-app) --------------------------
# A firstmate inside an hc terminal - including a Herdr.app terminal, which
# carries the same core markers - must resolve its own terminal as the
# supervisor target and hc as the backend, so the away daemon's supported-
# backend check refuses loudly instead of silently steering firstmate:0 tmux.
test_discover_supervisor_hc() {
  local out
  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' \
    HC_TERMINAL_ID=t9 HC_TERMINAL_SOCKET=/tmp/fm-test.sock HC_SESSION='' \
    FM_BACKEND_CONFIG_DIR="$TMP_ROOT/no-t3" discover_supervisor_target)
  [ "$out" = "default:t9" ] || fail "hc target should default HC_SESSION to 'default': $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' \
    HC_TERMINAL_ID=t9 HC_TERMINAL_SOCKET=/tmp/fm-test.sock HC_SESSION=iso1 \
    FM_BACKEND_CONFIG_DIR="$TMP_ROOT/no-t3" discover_supervisor_target)
  [ "$out" = "iso1:t9" ] || fail "hc target should use an explicit HC_SESSION: $out"

  out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' \
    HC_TERMINAL_ID=t9 HC_TERMINAL_SOCKET=/tmp/fm-test.sock \
    FM_BACKEND_CONFIG_DIR="$TMP_ROOT/no-t3" discover_supervisor_backend)
  [ "$out" = hc ] || fail "hc markers should resolve the hc backend: $out"

  # The pair is required: a bare HC_TERMINAL_ID without a socket keeps the
  # fallback, and the earlier innermost markers still win.
  if out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' \
    HC_TERMINAL_ID=t9 HC_TERMINAL_SOCKET='' HC_SESSION='' \
    FM_BACKEND_CONFIG_DIR="$TMP_ROOT/no-t3" discover_supervisor_target); then
    fail "a bare HC_TERMINAL_ID must not resolve a supervisor target"
  fi
  [ "$out" = "firstmate:0" ] || fail "a bare HC_TERMINAL_ID must keep the tmux fallback: $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='%3' HERDR_ENV='' HERDR_PANE_ID='' \
    HC_TERMINAL_ID=t9 HC_TERMINAL_SOCKET=/tmp/fm-test.sock discover_supervisor_target)
  [ "$out" = '%3' ] || fail "TMUX_PANE nested in an hc terminal must keep tmux: $out"
  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SESSION='' \
    HC_TERMINAL_ID=t9 HC_TERMINAL_SOCKET=/tmp/fm-test.sock discover_supervisor_target)
  [ "$out" = "default:w1:p9" ] || fail "herdr markers nested in an hc terminal must keep herdr: $out"
  out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 \
    HC_TERMINAL_ID=t9 HC_TERMINAL_SOCKET=/tmp/fm-test.sock discover_supervisor_backend)
  [ "$out" = herdr ] || fail "herdr markers nested in an hc terminal must keep herdr: $out"

  # The resolution is deliberately fail-closed: the away daemon's supported
  # list does not name hc, so it refuses at startup with the supported set
  # rather than silently steering the tmux fallback.
  if fm_backend_list_contains "$FM_SUPERVISOR_SUPPORTED_BACKENDS" hc; then
    fail "the away daemon must not list hc as a supported supervisor backend"
  fi

  pass "discover_supervisor_{target,backend}: hc markers resolve <session>:<address> + hc; bare id, nested tmux/herdr keep their verdicts; supported list stays closed to hc"
}

# --- t3code supervisor discovery and busy verdict --------------------------
# The real adapter is sourced once so fm_backend_source's sourced flag keeps it
# from re-sourcing over the stub; the stub records every home it is asked about
# and answers from FM_FAKE_T3_THREAD (empty: no live thread, `ambiguous`: the
# adapter's two-threads error, anything else: that thread id).
t3_discovery_stub() {
  fm_backend_source t3code || fail "could not source the t3code adapter"
  fm_backend_t3code_thread_for_home() {
    printf '%s\n' "$1" >> "${FM_FAKE_T3_CALLS:?}"
    case "${FM_FAKE_T3_THREAD:-}" in
      '') return 1 ;;
      ambiguous) echo "error: 2 live T3 threads run in $1 (t-a, t-b); set FM_SUPERVISOR_TARGET to the captain thread id" >&2; return 2 ;;
      *) printf '%s' "$FM_FAKE_T3_THREAD" ;;
    esac
  }
}

test_discover_supervisor_t3code_after_env_tmux_and_herdr() {
  local dir
  dir=$(make_supercase discover-t3code)
  mkdir -p "$dir/config"
  printf 'tok\n' > "$dir/config/t3code-token"
  (
    t3_discovery_stub
    export FM_FAKE_T3_CALLS="$dir/calls" FM_FAKE_T3_THREAD=thread-captain
    export FM_HOME="$dir" FM_BACKEND_CONFIG_DIR="$dir/config" FM_T3CODE_ORIGIN=http://127.0.0.1:9 FM_BACKEND=
    local out
    if out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target); then
      fail "T3 supervisor discovery must require explicit backend selection"
    fi
    [ "$out" = firstmate:0 ] || fail "without explicit T3 selection the tmux fallback must stand"
    [ ! -s "$dir/calls" ] || fail "without explicit T3 selection the adapter must not be consulted"
    printf '\n t3code \n' > "$dir/config/backend"
    [ "$(fm_backend_name)" = t3code ] || fail "spawns must read the padded config/backend as t3code"
    out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target) \
      || fail "one live T3 thread in the home must resolve the target cleanly"
    [ "$out" = thread-captain ] || fail "the target should be the live thread id, got '$out'"
    if out=$(FM_BACKEND=tmux FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target); then
      fail "FM_BACKEND=tmux must override config/backend for T3 supervisor discovery"
    fi
    [ "$out" = firstmate:0 ] || fail "FM_BACKEND=tmux must leave the tmux fallback, got '$out'"
    out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_backend) \
      || fail "one live T3 thread in the home must resolve the backend cleanly"
    [ "$out" = t3code ] || fail "the backend should be t3code, got '$out'"
    [ "$(sort -u "$dir/calls")" = "$dir" ] || fail "the adapter must be asked about this home only, got '$(cat "$dir/calls")'"

    : > "$dir/calls"
    out=$(FM_SUPERVISOR_TARGET=explicit:target FM_SUPERVISOR_BACKEND=herdr TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target)
    [ "$out" = explicit:target ] || fail "explicit FM_SUPERVISOR_TARGET must win over a live T3 thread: $out"
    out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND=herdr TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_backend)
    [ "$out" = herdr ] || fail "explicit FM_SUPERVISOR_BACKEND must win over a live T3 thread: $out"
    out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='%3' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target)
    [ "$out" = '%3' ] || fail "TMUX_PANE must win over a live T3 thread: $out"
    out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='%3' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_backend)
    [ "$out" = tmux ] || fail "TMUX_PANE must resolve tmux ahead of t3code: $out"
    out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SESSION='' discover_supervisor_target)
    [ "$out" = default:w1:p9 ] || fail "herdr markers must win over a live T3 thread: $out"
    out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 discover_supervisor_backend)
    [ "$out" = herdr ] || fail "herdr markers must resolve herdr ahead of t3code: $out"
    [ ! -s "$dir/calls" ] || fail "the explicit env, tmux, and herdr rules must win before the adapter is consulted"

    export FM_FAKE_T3_THREAD=
    if out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target); then
      fail "no live T3 thread must fall through to the default with a non-zero status"
    fi
    [ "$out" = firstmate:0 ] || fail "no live T3 thread should still print the tmux default target: $out"
    if out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_backend); then
      fail "no live T3 thread must fall through to the default backend with a non-zero status"
    fi
    [ "$out" = tmux ] || fail "no live T3 thread should still print the tmux default backend: $out"

    export FM_FAKE_T3_THREAD=ambiguous
    if out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target 2>"$dir/ambiguous.err"); then
      fail "two live T3 threads must not resolve a target"
    fi
    [ "$out" = firstmate:0 ] || fail "an ambiguous home falls through to the default target: $out"
    assert_contains "$(cat "$dir/ambiguous.err")" "error: 2 live T3 threads run in $dir (t-a, t-b)" "discovery must pass the adapter's ambiguity error through to stderr"

    : > "$dir/calls"
    export FM_FAKE_T3_THREAD=thread-captain
    rm -f "$dir/config/t3code-token"
    if out=$(FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target); then
      fail "without a bearer the t3code rule must stay closed"
    fi
    [ "$out" = firstmate:0 ] || fail "without a bearer the default target stands: $out"
    [ ! -s "$dir/calls" ] || fail "without a bearer the adapter must not be consulted"
  ) || fail "t3code discovery subshell failed"
  pass "discover_supervisor_*: t3code resolves from the home's live thread after env, TMUX_PANE, and herdr; zero, ambiguous, and no-bearer fall through"
}

test_pane_is_busy_t3code_trusts_native_verdict_without_capture() {
  local dir row
  dir=$(make_supercase primary-t3code-busy)
  (
    fm_backend_source t3code || fail "could not source the t3code adapter"
    fm_backend_capture() { : > "$dir/capture-called"; }
    fm_backend_t3code_probe() {
      [ "$1" = thread-captain ] || : > "$dir/unexpected-probe"
      printf '%s' "${FM_FAKE_T3_ROW:?}"
    }
    for row in running starting blocked error http-failure http-404 archived closing; do
      FM_FAKE_T3_ROW=$row FM_STATE_OVERRIDE="$dir/state" FM_DAEMON_PRIMARY_HARNESS=claude pane_is_busy thread-captain t3code \
        || fail "a T3 supervisor thread reading $row must defer injection"
    done
    for row in idle ready interrupted; do
      if FM_FAKE_T3_ROW=$row FM_STATE_OVERRIDE="$dir/state" FM_DAEMON_PRIMARY_HARNESS=claude pane_is_busy thread-captain t3code; then
        fail "a settled T3 supervisor thread reading $row must accept injection without a rendered-tail fallback"
      fi
    done
  ) || fail "t3code pane_is_busy subshell failed"
  [ ! -e "$dir/capture-called" ] || fail "capture must never be consulted for a t3code supervisor"
  [ ! -e "$dir/unexpected-probe" ] || fail "pane_is_busy must probe the supervisor thread it was given"
  pass "pane_is_busy: t3code accepts only a settled thread with no pending request and never reads a rendered tail"
}

test_pane_is_busy_herdr_native_busy_state() {
  local dir
  dir=$(make_supercase primary-herdr-busy)
  (
    fm_backend_busy_state() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected busy_state args: $1 $2"; printf 'busy'; }
    fm_backend_capture() { fail "capture should not be consulted when busy_state is conclusive"; }
    FM_STATE_OVERRIDE="$dir/state" FM_DAEMON_PRIMARY_HARNESS=claude pane_is_busy "default:w1:p2" herdr \
      || fail "pane_is_busy should report busy from herdr's native busy_state"
  ) || fail "herdr native-busy pane_is_busy subshell failed"
  pass "pane_is_busy: herdr native busy_state='busy' short-circuits without a capture fallback"
}

test_primary_busy_guard_is_harness_scoped() {
  (
    fm_backend_busy_state() { printf 'unknown'; }
    fm_backend_capture() { printf 'esc interrupt\n'; }
    if FM_DAEMON_PRIMARY_HARNESS=claude pane_is_busy "default:w1:p2" herdr; then
      fail "OpenCode's rendered signature must not classify a Claude primary busy"
    fi
    FM_DAEMON_PRIMARY_HARNESS=opencode pane_is_busy "default:w1:p2" herdr \
      || fail "OpenCode's rendered signature should classify an OpenCode primary busy"
  ) || fail "harness-scoped primary busy guard subshell failed"
  pass "primary busy guard isolates rendered signatures by detected harness"
}

test_pane_is_busy_defaults_to_tmux_when_backend_omitted() {
  local dir fakebin capture
  dir=$(make_supercase busy-default-backend)
  fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  printf 'Ctrl+c:cancel\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_STATE_OVERRIDE="$dir/state" FM_DAEMON_PRIMARY_HARNESS=grok pane_is_busy "fakepane" \
    || fail "pane_is_busy with no backend arg should still default to tmux"
  pass "pane_is_busy: omitted backend defaults to tmux for Grok's isolated fallback"
}

test_pane_input_pending_herdr_dispatch() {
  (
    fm_backend_composer_state() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected composer_state args: $1 $2"; printf 'pending'; }
    pane_input_pending "default:w1:p2" herdr || fail "pane_input_pending should report pending from herdr composer_state"
  ) || fail "herdr pane_input_pending (pending case) subshell failed"
  (
    fm_backend_composer_state() { printf 'empty'; }
    if pane_input_pending "default:w1:p2" herdr; then
      fail "pane_input_pending should report not-pending for an empty herdr composer"
    fi
  ) || fail "herdr pane_input_pending (empty case) subshell failed"
  (
    fm_backend_composer_state() { printf 'future-state'; }
    pane_input_pending "default:w1:p2" herdr \
      || fail "pane_input_pending should defer on an unrecognized composer state"
  ) || fail "herdr pane_input_pending (future-state case) subshell failed"
  pass "pane_input_pending: dispatches through fm_backend_composer_state for backend=herdr"
}

test_inject_msg_herdr_busy_guard_defers() {
  local dir state
  dir=$(make_supercase inject-herdr-busy)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected target_exists args: $1 $2"; return 0; }
    pane_is_busy() { return 0; }
    fm_backend_composer_state() { fail "composer_state should not be consulted once the busy-guard already deferred"; }
    fm_backend_send_text_submit() { fail "send_text_submit should not run when the busy-guard defers"; }
    if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:p2" inject_msg "hello" "$state"; then
      fail "inject_msg should defer (return non-zero) when the herdr supervisor pane is busy"
    fi
  ) || fail "herdr busy-guard inject_msg subshell failed"
  pass "inject_msg: herdr busy-guard defers before ever attempting a submit"
}

test_inject_msg_herdr_composer_guard_defers() {
  local dir state
  dir=$(make_supercase inject-herdr-pending)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { return 0; }
    pane_is_busy() { return 1; }
    fm_backend_composer_state() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected composer_state args: $1 $2"; printf 'pending'; }
    fm_backend_send_text_submit() { fail "send_text_submit should not run when the composer-guard defers"; }
    if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:p2" inject_msg "hello" "$state"; then
      fail "inject_msg should defer when the herdr composer has pending input"
    fi
  ) || fail "herdr composer-guard inject_msg subshell failed"
  pass "inject_msg: herdr composer-guard defers before ever attempting a submit"
}

test_inject_msg_herdr_pane_gone_defers() {
  local dir state
  dir=$(make_supercase inject-herdr-gone)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { return 1; }
    pane_is_busy() { fail "busy guard should not be consulted once the pane-exists check already failed"; }
    fm_backend_send_text_submit() { fail "send_text_submit should not run when the pane does not exist"; }
    if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:gone" inject_msg "hello" "$state"; then
      fail "inject_msg should defer when the herdr target does not exist"
    fi
  ) || fail "herdr pane-gone inject_msg subshell failed"
  pass "inject_msg: herdr pane-gone check defers before any busy/composer/submit call"
}

test_inject_msg_herdr_submits_through_backend_dispatch() {
  local dir state
  dir=$(make_supercase inject-herdr-submit)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { return 0; }
    pane_is_busy() { return 1; }
    fm_backend_composer_state() { printf 'empty'; }
    fm_backend_send_text_submit() {
      [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected send_text_submit args: $1 $2"
      printf '%s\n' "$3" > "$dir/sent.log"
      printf 'empty'
    }
    FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:p2" inject_msg "hello" "$state" \
      || fail "inject_msg should succeed when send_text_submit confirms empty"
  ) || fail "herdr successful-submit inject_msg subshell failed"
  delivered_digest "$dir/sent.log" | grep -F 'hello' >/dev/null \
    || fail "digest text missing from send_text_submit: $(cat "$dir/sent.log")"
  pass "inject_msg: dispatches busy-guard/composer-guard/submit through the herdr backend and succeeds on a confirmed empty composer"
}

# Safety-critical (task fm-composer-shellglyph-safety): the away-mode injector
# must NEVER type an escalation into a dead-shell pane. A bare shell prompt
# classifies `unknown` (not `pending`), and inject_msg now defers on anything
# that is not affirmatively `empty`, so a dead shell (or an unreadable pane) can
# never be mistaken for a safe empty agent composer and typed into.
test_inject_msg_defers_on_dead_shell_unknown() {
  local dir state
  dir=$(make_supercase inject-dead-shell)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { return 0; }
    pane_is_busy() { return 1; }
    fm_backend_composer_state() { printf 'unknown'; }
    fm_backend_send_text_submit() { fail "send_text_submit must NOT run when the composer is a dead shell (unknown)"; }
    if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:p2" inject_msg "hello" "$state"; then
      fail "inject_msg should defer (never inject) when the composer reads unknown (dead shell / unreadable)"
    fi
  ) || fail "dead-shell inject_msg subshell failed"
  pass "inject_msg: defers on a dead-shell/unreadable composer (unknown), never typing the escalation into a shell"
}

test_inject_msg_defers_on_unrecognized_composer_state() {
  local dir state
  dir=$(make_supercase inject-future-composer-state)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { return 0; }
    pane_is_busy() { return 1; }
    fm_backend_composer_state() { printf 'future-state'; }
    fm_backend_send_text_submit() { fail "send_text_submit must not run for an unrecognized composer state"; }
    if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:p2" inject_msg "hello" "$state"; then
      fail "inject_msg should defer on an unrecognized composer state"
    fi
  ) || fail "unrecognized composer-state inject_msg subshell failed"
  pass "inject_msg: unrecognized composer states defer by default"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

test_afk_start_refuses_when_flag_cannot_be_written
test_afk_start_ignores_stale_pidfile_without_lock
test_afk_start_refuses_tern_supervisor_backend
test_afk_start_reclaims_stale_daemon_lock_reused_pid
test_daemon_state_root_uses_fm_home
test_classify_routine_signal_self
test_classify_terminal_signal_escalates
test_classify_check_and_unknown_escalate
test_unknown_wake_ack_suppresses_handled_identity
test_unknown_wake_ack_failure_still_clears_delivered_digest
test_stale_transient_self_records_marker
test_stale_diagnostic_wedge_survives_busy_housekeeping
test_enriched_wedge_under_declared_wait_uses_pause_cadence
test_enriched_wedge_under_worker_blocker_follows_its_flag
test_stale_terminal_escalates
test_stale_actionable_wait_escalates_and_keeps_pause_cadence
test_stale_paused_classifies_pause
test_stale_pause_survives_a_foreign_resolved_line
test_stale_captain_held_classifies_pause
test_handle_wake_paused_records_pause_marker
test_handle_wake_paused_signal_records_pause_marker
test_handle_wake_terminal_signal_clears_pause_tracking
test_housekeeping_migrates_watcher_pause_marker
test_housekeeping_migrates_watcher_unpaused_marker_to_clear
test_housekeeping_seeds_pause_marker_from_status
test_housekeeping_persistent_stale_escalates
test_housekeeping_resumed_stale_cleared
test_housekeeping_paused_resurfaces_and_resets
test_housekeeping_captain_held_resurfaces_and_resets
test_housekeeping_captain_held_silenced_only_by_an_away_record
test_housekeeping_paused_resumed_cleared
test_housekeeping_busy_declared_wait_matures_its_window
test_housekeeping_overdue_pause_opens_one_decision_in_away_mode
test_housekeeping_pause_ceiling_absent_keeps_the_pause_recheck
test_housekeeping_overdue_queue_failure_leaves_decision_open
test_housekeeping_overdue_queue_failure_resume_discards
test_watcher_overdue_marker_does_not_hide_blocker_from_daemon
test_overdue_open_decision_without_marker_is_not_repeated
test_overdue_reconcile_ignores_unrelated_and_repeated_pause
test_housekeeping_overdue_initial_publication_reconciles_resume
test_housekeeping_overdue_pause_preserves_prior_actionable_event
test_housekeeping_quiet_overdue_pause_opens_decision
test_housekeeping_declared_time_controls_pause_recheck
test_housekeeping_paused_unpaused_cleared
test_housekeeping_captain_held_resolved_cleared
test_housekeeping_stale_marker_transitions_to_pause
test_housekeeping_captain_held_stale_marker_transitions_to_pause
test_housekeeping_pause_marker_transitions_to_clear
test_housekeeping_herdr_persistent_stale_resolves_meta
test_housekeeping_herdr_idle_busy_record_clears_stale
test_housekeeping_herdr_resumed_stale_cleared
test_housekeeping_orca_persistent_stale_resolves_terminal
test_escalate_batches_into_one_digest
test_escalate_batch_age_uses_first_append
test_heartbeat_scan_dedup
test_handle_wake_routes_self_and_escalate
test_needs_decision_queued_row_escalates_once_as_the_decision
test_captain_held_decision_owned_row_is_self_handled
test_inject_skip_forces_self
test_is_wake_reason_distinguishes_status_stdout
test_terminal_stale_escalate_leaves_no_marker
test_signal_escalate_marks_seen_no_catchall_refire
test_collapse_newlines_pure
test_afk_absent_daemon_does_not_inject
test_busy_guard_defers_when_supervisor_busy
test_marker_detection
test_afk_turn_exemption
test_should_exit_afk_when_afk_inactive
test_strip_injection_marker
test_escalate_marker_preserving_primary_types_envelope
test_record_doorbell_detection
test_pane_input_pending_detects_partial_input
test_pane_input_pending_blank_defers_strict
test_pane_input_pending_requires_proven_empty_prompt
test_tmux_composer_state_bare_shell_is_unknown
test_tmux_composer_state_bordered_and_agent_rows_are_empty
test_tmux_composer_state_requires_matching_box_borders
test_pane_input_pending_preserves_bright_placeholder_like_draft
test_classify_signal_dedup_against_scan
test_classify_signal_skips_turn_end_markers
test_classify_signal_survives_a_later_routine_append
test_classification_commits_its_captured_endpoint
test_stale_masked_event_escalates_at_captured_endpoint
test_stale_read_failure_surfaces_without_advancing_seen
test_recreated_status_rejects_captured_identity
test_unverifiable_identity_surfaces_without_marker
test_status_read_failure_surfaces_without_advancing_seen
test_catchall_advances_routine_then_surfaces_append
test_escalation_buffer_failure_retains_wake_and_position
test_busy_inbox_escalation_reaches_supervision stuck away
test_busy_inbox_escalation_reaches_supervision stuck quiet
test_busy_inbox_escalation_reaches_supervision write away
test_busy_inbox_escalation_reaches_supervision write quiet
test_busy_inbox_escalation_reaches_supervision reset away
test_busy_inbox_escalation_reaches_supervision reset quiet
test_busy_inbox_dispatch_preserves_other_stale_reasons
test_catchall_buffer_failure_preserves_position
test_durable_wake_failure_retains_entire_batch
test_missing_status_stale_is_acknowledged_without_diagnostic
test_transient_unreadable_signal_recovers_without_advancing
test_permission_recovery_reclassifies_catchall_status
test_permanent_classification_failure_is_reported_and_acknowledged
test_catchall_scan_surfaces_a_masked_event
test_classify_stale_dedup_against_signal
test_afk_nonterminal_working_merged_keeps_wedge_aging
test_afk_genuine_done_still_terminal_stale
test_pane_input_pending_bordered_idle_not_pending
test_pane_input_pending_bordered_with_text_is_pending
test_submit_ack_confirms_on_bordered_empty_composer
test_submit_ack_reports_pending_on_persistent_swallow
test_max_defer_empty_swallow_types_once_and_alarms
test_max_defer_flushes_empty_idle_pane
test_max_defer_pending_composer_alarms_without_typing
test_composer_deferral_names_pending_text_or_unrecognized_shape
test_normal_flush_clears_stale_wedge_marker
test_oversized_digest_is_bounded_and_kept_durable
test_digest_budget_counts_omitted_events
test_inject_send_failure_logs_stage_stderr_and_bytes
test_inject_enter_failure_logs_confirmation_stage
test_bounded_digest_full_text_kept_after_typing
test_below_max_defer_does_nothing
test_max_defer_afk_inactive_does_not_flush_or_alarm
test_wedge_alarm_library_mode_defaults_to_discard
test_wake_helpers_replace_inherited_notifier_override
test_wedge_alarm_discard_seam_fires_nothing
test_wedge_alarm_direct_notifiers_honor_discard_seam
test_wedge_alarm_osascript_channel_selected
test_wedge_alarm_herdr_channel_selected
test_wedge_alarm_rex_channel_selected
test_wedge_alarm_auto_never_selects_rex
test_wedge_alarm_command_channel_receives_summary
test_wedge_alarm_command_failure_hides_configured_command
test_wedge_alarm_unknown_channel_hides_configured_directive
test_wedge_alarm_off_disables_active_alert_regardless_of_position
test_wedge_alarm_auto_darwin_selects_osascript
test_wedge_alarm_auto_non_darwin_has_no_os_channel
test_wedge_alarm_config_file_multi_channel
test_wedge_alarm_failing_channel_degrades_gracefully
test_wedge_alarm_hung_channel_times_out_and_falls_through
test_wedge_alarm_backgrounded_command_times_out_and_reaps_descendant
test_wedge_alarm_hung_override_times_out_and_falls_through
test_wedge_alarm_shutdown_stops_active_notifier_group
test_inject_wedge_alarm_fires_active_alert_on_non_tmux_backend
test_inject_wedge_alarm_throttles_when_marker_cannot_be_written
test_fm_send_reports_delivered_unconfirmed_submit
test_fm_send_exits_nonzero_on_initial_send_failure
test_fm_send_exits_nonzero_on_unproven_submit
test_discover_supervisor_backend_precedence
test_discover_supervisor_target_herdr
test_discover_supervisor_hc
test_discover_supervisor_t3code_after_env_tmux_and_herdr
test_pane_is_busy_t3code_trusts_native_verdict_without_capture
test_pane_is_busy_herdr_native_busy_state
test_primary_busy_guard_is_harness_scoped
test_pane_is_busy_defaults_to_tmux_when_backend_omitted
test_pane_input_pending_herdr_dispatch
test_inject_msg_herdr_busy_guard_defers
test_inject_msg_herdr_composer_guard_defers
test_inject_msg_herdr_pane_gone_defers
test_inject_msg_herdr_submits_through_backend_dispatch
test_inject_msg_defers_on_dead_shell_unknown
test_inject_msg_defers_on_unrecognized_composer_state

# The Claude background-task exit picker names itself on the stale reason.
# Away mode self-handles the first sight, so the name has to be saved and
# then appear on the persistence line. A wedge reason that also carries
# demand-deep-inspection must still escalate, with the name after that clause,
# and a declared wait must still take the pause cadence.
test_dialog_name_survives_away_self_handle() {
  local dir state fakebin win pane key reason
  dir=$(make_supercase dialog-name-persists)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-picker-ship"
  pane="$dir/pane.txt"
  printf 'idle on the picker\n' > "$pane"
  fm_write_meta "$state/picker-ship.meta" "window=$win" "backend=tmux"
  printf 'working: parked between turns\n' > "$state/picker-ship.status"
  reason="stale: $win (blocked-on-prompt: Claude background-task exit picker)"
  LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
  key=$(printf '%s' picker-ship | tr ':/.' '___')
  [ "$(cat "$state/.subsuper-dialog-$key" 2>/dev/null || true)" = 'Claude background-task exit picker' ] \
    || fail "a self-handled dialog stale did not save the name: $(cat "$state/.subsuper-dialog-$key" 2>/dev/null)"
  [ -e "$state/.subsuper-stale-$key" ] || fail "a self-handled dialog stale did not record the persistence marker"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a first-sight dialog stale escalated instead of waiting: $(cat "$state/.subsuper-escalations")"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 housekeeping "$state"
  grep -F 'stale persisted' "$state/.subsuper-escalations" >/dev/null \
    || fail "the persistence line was not escalated: $(cat "$state/.subsuper-escalations" 2>/dev/null)"
  grep -F 'blocked-on-prompt: Claude background-task exit picker' "$state/.subsuper-escalations" >/dev/null \
    || fail "the persistence line dropped the dialog name: $(cat "$state/.subsuper-escalations")"
  grep -F 'possible wedge' "$state/.subsuper-escalations" >/dev/null \
    || fail "the persistence line dropped the wedge wording: $(cat "$state/.subsuper-escalations")"
  [ ! -e "$state/.subsuper-dialog-$key" ] || fail "the saved dialog name outlived the persistence escalation"
  pass "a dialog name on a first-sight stale reaches the away persistence line"
}

test_dialog_name_after_demand_deep_inspection_still_escalates() {
  local dir state win reason i
  dir=$(make_supercase dialog-name-combined)
  state="$dir/state"
  win="sess:fm-picker-ship"
  fm_write_meta "$state/picker-ship.meta" "window=$win" "backend=tmux"
  printf 'working: parked between turns\n' > "$state/picker-ship.status"
  for i in 1 2; do
    reason="stale: $win (idle 250s, possible wedge, escalation $i, demand-deep-inspection: same pane has wedge-escalated $i times in a row - do not re-absorb on the run-step/pane state alone, blocked-on-prompt: Claude background-task exit picker)"
    : > "$dir/daemon.log"
    LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
    grep -F "${reason#stale: }" "$state/.subsuper-escalations" >/dev/null \
      || fail "escalation $i lost the combined dialog reason: $(cat "$state/.subsuper-escalations" 2>/dev/null)"
  done
  [ "$(grep -c 'blocked-on-prompt: Claude background-task exit picker' "$state/.subsuper-escalations")" -eq 2 ] \
    || fail "the ladder did not escalate both combined reasons: $(cat "$state/.subsuper-escalations")"
  grep -F 'demand-deep-inspection:' "$state/.subsuper-escalations" >/dev/null \
    || fail "the combined reason dropped demand-deep-inspection"
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 2 times in a row - do not re-absorb on the run-step/pane state alone, blocked-on-prompt: Claude background-task exit picker)' \
    "$state/.subsuper-escalations" >/dev/null \
    || fail "the dialog name was not after demand-deep-inspection: $(cat "$state/.subsuper-escalations")"
  printf 'paused: awaiting an external dependency\n' > "$state/picker-ship.status"
  : > "$state/.subsuper-escalations"
  reason="stale: $win (idle 250s, possible wedge, escalation 3, demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone, blocked-on-prompt: Claude background-task exit picker)"
  LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "a declared wait with the dialog suffix escalated as a wedge: $(cat "$state/.subsuper-escalations")"
  pass "a dialog name after demand-deep-inspection still escalates, and a declared wait still pauses"
}

# /exit on a finished worker with a background shell is what opens the picker,
# so the status is already `done:` and already escalated when the stale wake
# arrives. That wake self-handles exactly as a plain stale does: no persistence
# marker, and no later wedge.
test_seen_terminal_dialog_stale_clears_like_a_plain_stale() {
  local dir state win key reason
  dir=$(make_supercase dialog-name-terminal)
  state="$dir/state"
  win="sess:fm-picker-done"
  fm_write_meta "$state/picker-done.meta" "window=$win" "backend=tmux"
  printf 'done: shipped the change\n' > "$state/picker-done.status"
  seen_through "$state" picker-done
  key=$(printf '%s' picker-done | tr ':/.' '___')
  LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] \
    || fail "a seen terminal stale with no dialog recorded a wedge marker"
  reason="stale: $win (blocked-on-prompt: Claude background-task exit picker)"
  LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
  grep -F 'stale + terminal (already escalated by signal)' "$dir/daemon.log" >/dev/null \
    || fail "the fixture did not take the seen terminal self-handle path: $(cat "$dir/daemon.log")"
  [ ! -e "$state/.subsuper-dialog-$key" ] \
    || fail "a seen terminal dialog stale kept the saved name"
  [ ! -e "$state/.subsuper-stale-$key" ] \
    || fail "a seen terminal dialog stale recorded a wedge marker"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "a seen terminal dialog stale escalated: $(cat "$state/.subsuper-escalations")"
  pass "a seen terminal status on the picker clears like a plain stale"
}

# The first stale wake after a new `done:` escalates from the status log, and
# that one line is all the captain gets, so it has to carry the name too.
test_dialog_name_joins_unseen_status_escalation() {
  local dir state win
  dir=$(make_supercase dialog-name-unseen)
  state="$dir/state"
  win="sess:fm-picker-new"
  fm_write_meta "$state/picker-new.meta" "window=$win" "backend=tmux"
  printf 'done: shipped the change\n' > "$state/picker-new.status"
  LOG="$dir/daemon.log" FM_STATE_OVERRIDE="$state" FM_ESCALATE_BATCH_SECS=999999 \
    handle_wake "stale: $win (blocked-on-prompt: Claude background-task exit picker)" "$state"
  grep -F 'done: shipped the change' "$state/.subsuper-escalations" \
    | grep -F 'blocked-on-prompt: Claude background-task exit picker' >/dev/null \
    || fail "an unseen status escalation dropped the dialog name: $(cat "$state/.subsuper-escalations" 2>/dev/null)"
  pass "a dialog name joins the escalation of an unseen status"
}
