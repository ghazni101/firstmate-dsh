# shellcheck shell=bash
# Test cases for fm-backend-herdr, split out of tests/fm-backend-herdr.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-backend-herdr.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


test_composer_state_codex_faint_suggestion_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-faint-suggestion"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 You have 2 usage limit resets available. Run /usage\nto use one.\n\n\x1b[0m\x1b[1m\xe2\x80\xba \x1b[0m\x1b[2mFind and fix a bug in @filename\x1b[0m\n\n  gpt-5.5 xhigh \xc2\xb7 Context 100%% left\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a faint real-codex ghost suggestion should read empty, not pending, got '$out'"
  pass "fm_backend_herdr_composer_state: a faint real-codex ghost suggestion reads empty"
}

test_composer_state_codex_non_faint_same_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-non-faint-same-text"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 You have 2 usage limit resets available. Run /usage\nto use one.\n\n\x1b[0m\x1b[1m\xe2\x80\xba \x1b[0mFind and fix a bug in @filename\n\n  gpt-5.5 xhigh \xc2\xb7 Context 100%% left\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "the same words without faint styling should still protect real typed input, got '$out'"
  pass "fm_backend_herdr_composer_state: non-faint codex prompt text still reads pending"
}

# --- wait_for_working: the native agent-state poll-and-classify primitive ---
# Direct unit coverage for fm_backend_herdr_wait_for_working, the helper
# fm_backend_herdr_send_text_submit now uses instead of composer scraping
# (docs/herdr-backend.md "Native agent-state submit confirmation").

test_wait_for_working_returns_busy_on_first_poll() {
  local dir log resp fb out calls
  dir="$TMP_ROOT/wait-busy-first"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 1 5' "$ROOT" )
  [ "$out" = busy ] || fail "wait_for_working should report busy once 'working' is observed, got '$out'"
  calls=$(grep -c $'\x1f''agent'$'\x1f''get' "$log")
  [ "$calls" -eq 1 ] || fail "wait_for_working should short-circuit on the FIRST busy poll instead of consuming the whole budget, made $calls call(s)"
  pass "fm_backend_herdr_wait_for_working: reports 'busy' immediately on the first poll, without spending the rest of the budget"
}

test_wait_for_working_catches_a_slow_transition_mid_window() {
  local dir log resp fb out calls
  dir="$TMP_ROOT/wait-busy-slow"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Two idle samples, then working on the third - a transition that would be
  # MISSED by a single check-at-the-end design (the old composer approach's
  # shape) but is caught here because the budget is sampled repeatedly.
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.03 3' "$ROOT" )
  [ "$out" = busy ] || fail "wait_for_working should catch a transition that lands on a later sample within the SAME window, got '$out'"
  calls=$(grep -c $'\x1f''agent'$'\x1f''get' "$log")
  [ "$calls" -eq 3 ] || fail "expected exactly 3 agent-get polls (idle, idle, working), got $calls"
  pass "fm_backend_herdr_wait_for_working: a slow transition landing on a later sample within one window is still caught (robust against the 'slow transition' failure direction)"
}

test_wait_for_working_samples_budget_endpoint_without_final_sleep() {
  local dir log resp fb out sleep_log sleeps
  dir="$TMP_ROOT/wait-budget-endpoint"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; sleep_log="$dir/sleeps"; : > "$log"; : > "$sleep_log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SLEEP_LOG="$sleep_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; sleep() { printf "sleep:%s\n" "$1" >> "$FM_SLEEP_LOG"; }; fm_backend_herdr_wait_for_working default w1:p2 0.5 6' "$ROOT" )
  [ "$out" = idle ] || fail "wait_for_working should report idle when every endpoint-spread poll is readable-idle, got '$out'"
  sleeps=$(grep -c '^sleep:0.1000$' "$sleep_log")
  [ "$sleeps" -eq 5 ] || fail "six polls across a 0.5s budget should sleep five times at 0.1000s, got $sleeps matching sleeps; log: $(cat "$sleep_log")"
  pass "fm_backend_herdr_wait_for_working: spreads six samples across the full budget endpoint without a final trailing sleep"
}

test_send_text_submit_applies_herdr_minimum_confirm_budget() {
  local dir log resp fb out sleep_log sleeps
  dir="$TMP_ROOT/submit-min-budget"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; sleep_log="$dir/sleeps"; : > "$log"; : > "$sleep_log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/7.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/8.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/9.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SLEEP_LOG="$sleep_log" FM_BACKEND_HERDR_SUBMIT_POLLS=6 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6 \
    bash -c '. "$0/bin/backends/herdr.sh"; sleep() { printf "sleep:%s\n" "$1" >> "$FM_SLEEP_LOG"; }; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.4 0' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should catch a slow-but-valid transition inside the herdr minimum budget, got '$out'"
  sleeps=$(grep -c '^sleep:0.1200$' "$sleep_log")
  [ "$sleeps" -eq 5 ] || fail "a 0.4s caller budget should be expanded to five 0.1200s sleeps across the 0.6s herdr floor, got $sleeps; log: $(cat "$sleep_log")"
  [ "$(grep -c '^sleep:0.0800$' "$sleep_log")" -eq 0 ] || fail "send_text_submit used the caller's too-short 0.4s budget instead of the herdr floor: $(cat "$sleep_log")"
  pass "fm_backend_herdr_send_text_submit: applies the herdr minimum confirmation budget before polling agent-state"
}

test_wait_for_working_returns_idle_when_never_busy_but_readable() {
  local dir log resp fb out
  dir="$TMP_ROOT/wait-idle"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.02 2' "$ROOT" )
  [ "$out" = idle ] || fail "wait_for_working should report idle when the target was legibly read but never busy, got '$out'"
  pass "fm_backend_herdr_wait_for_working: reports 'idle' (readable, genuinely not yet working) when 'busy' never appears"
}

test_wait_for_working_returns_unknown_when_never_readable() {
  local dir log resp fb out
  dir="$TMP_ROOT/wait-unknown"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  printf '1\n' > "$resp/2.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.02 2' "$ROOT" )
  [ "$out" = unknown ] || fail "wait_for_working should report unknown when every poll fails to read the target, got '$out'"
  pass "fm_backend_herdr_wait_for_working: reports 'unknown' (a hard read failure, not a timing race) only when EVERY poll in the window fails"
}

test_wait_for_working_treats_blocked_as_submit_active() {
  local dir log resp fb out
  dir="$TMP_ROOT/wait-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.01 1' "$ROOT" )
  [ "$out" = busy ] || fail "wait_for_working should treat a post-Enter blocked state as submit-active, got '$out'"
  pass "fm_backend_herdr_wait_for_working: treats blocked as submit-active for confirmation without changing watcher busy-state semantics"
}

# --- send_text_submit: native agent-state (agent get) verify-and-retry ------
# Rewritten for the 2026-07-07 incident (docs/herdr-backend.md): confirmation
# no longer reads composer content in the normal idle-baseline path, so a
# harness whose IDLE composer shows dynamic tip text (real codex) can no
# longer misread as "pending" and block/mis-confirm a send.
# FM_BACKEND_HERDR_SUBMIT_POLLS=1 pins most tests
# below to exactly one agent-get sample per Enter attempt for simple,
# deterministic call-count assertions; the multi-sample behavior itself is
# covered above by the wait_for_working tests and by
# test_send_text_submit_slow_transition_within_one_enter_needs_no_extra_enter.

test_send_text_submit_detects_landed_send() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text (literal, no output)
  # 2: agent get - pre-Enter baseline is idle
  # 3: send-keys enter
  # 4: agent get - agent_status working (a real turn started: submitted)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty (submitted) once agent_status reports working, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-text'$'\x1f''w1:p2'$'\x1f''hello captain' "send_text_submit did not type the literal text first"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should not need a second Enter for a plain message with no popup, sent $enter_count Enter(s)"
  [ "$(grep -c $'\x1f''pane'$'\x1f''read' "$log")" -eq 0 ] || fail "send_text_submit must never read the composer/pane content for confirmation anymore"
  pass "fm_backend_herdr_send_text_submit: reports 'empty' once agent_status reports working after one Enter, without ever reading the composer"
}

test_send_text_submit_detects_swallowed_enter() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-swallow"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Every post-Enter agent-get read still reports idle, and the composer still
  # holds the typed text: a genuine swallow, not a queued Enter.
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/7.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/8.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/9.out"
  printf '  ready\n' > "$resp/10.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "send_text_submit should report pending once retries are exhausted with agent_status never going busy and the composer still holding the text, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'pending' when agent_status stays idle and the composer still holds unsent text after retried Enters (swallowed)"
}

test_send_text_submit_replays_literal_send_stderr() {
  local dir log resp fb out err
  dir="$TMP_ROOT/submit-send-stderr"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  err="$dir/stderr"
  # 1: agent get (a non-Claude identity skips the payload proof)
  # 2: send-text fails the way an oversized argument does, before herdr runs
  printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n' > "$resp/1.out"
  printf 'herdr: Argument list too long\n' > "$resp/2.err"
  printf '126\n' > "$resp/2.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" 2>"$err" )
  [ "$out" = send-failed ] || fail "a failed literal send should report send-failed, got '$out'"
  grep -F 'Argument list too long' "$err" >/dev/null \
    || fail "the literal send's stderr was not replayed to the caller: $(cat "$err")"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-keys' "$log")" -eq 0 ] \
    || fail "no Enter may follow a failed literal send"
  pass "fm_backend_herdr_send_text_submit: a failed literal send reports send-failed and replays the transport's stderr"
}

# Regression coverage for the 2026-07-03 incident using the NEW mechanism: a
# slash command's first Enter can close a completion popup and fill an
# argument-hint placeholder WITHOUT submitting. In the idle-baseline path,
# filling a placeholder never starts a turn, so agent_status simply stays idle
# for Enter #1, and the retry loop sends a genuine second Enter exactly as it
# would for any other swallowed Enter.
test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-popup-autocomplete"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text "/compact"
  # 2: agent get - pre-Enter baseline is idle
  # 3: send-keys enter (#1) - closes the popup, fills the placeholder; no turn starts
  # 4: agent get -> idle (not submitted yet)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  # 5: composer still holds the placeholder fill; native idle falls through
  #    to the shared composer verdict, which retries rather than confirming.
  printf '  \xe2\x9d\xaf /compact\n' > "$resp/5.out"
  # 6: send-keys enter (#2) - actually submits
  # 7: agent get -> working (submitted)
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "/compact" 3 0.01 1.2' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually starts a turn, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 2 ] || fail "send_text_submit must send a SECOND Enter after the popup-placeholder fill's agent_status still reads idle, got $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a slash-command popup's placeholder fill on Enter #1 never flips agent_status to working, so it does not short-circuit as submitted; Enter #2 is retried and lands it"
}

test_send_text_submit_refuses_confirming_enter_on_exit_picker() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-exit-picker"; mkdir -p "$dir/responses" "$dir/tmp"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_submit_claude_prefix "$resp" "/exit"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/7.out"
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel' > "$resp/8.out"
  herdr_submit_preflight_prefix "$resp"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    TMPDIR="$dir/tmp" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_text_submit herdr default:w1:p2 "/exit" 3 0.01 0.01' "$ROOT" )
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log" || true)
  [ "$out" = unknown ] || fail "the exit picker should stop the retry as unknown, got '$out'; log: $(cat "$log")"
  [ "$enter_count" -eq 1 ] || fail "the exit picker should get one Enter, got $enter_count; log: $(cat "$log")"
  [ -z "$(ls -A "$dir/tmp")" ] || fail "the submit left its dialog record behind: $(ls -A "$dir/tmp")"
  pass "fm_backend_herdr_send_text_submit: the Claude background-task exit picker gets no confirming Enter"
}

# Herdr can report `blocked` for a picker the submitting Enter opened. The
# submit then reports delivery with no composer read, so the picker is named
# only by the caller's next composer read, the one fm-control exit takes when
# its wait for the agent to stop times out.
test_blocked_submit_leaves_the_exit_picker_to_the_next_composer_read() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-blocked-picker"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_submit_claude_prefix "$resp" "/exit"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"blocked"}}}\n' > "$resp/7.out"
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel' > "$resp/8.out"
  herdr_submit_preflight_prefix "$resp"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    FM_COMPOSER_DIALOG_SINK="$dir/sink" \
    bash -c '. "$0/bin/fm-backend.sh"
      verdict=$(fm_backend_send_text_submit herdr default:w1:p2 "/exit" 3 0.01 0.01)
      printf "%s|%s|" "$verdict" "$(cat "$FM_COMPOSER_DIALOG_SINK")"
      fm_backend_composer_state herdr default:w1:p2 >/dev/null
      cat "$FM_COMPOSER_DIALOG_SINK"' "$ROOT" )
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log" || true)
  [ "$out" = 'empty||Claude background-task exit picker' ] \
    || fail "a blocked submit should report delivery unnamed and the next composer read should name the picker, got '$out'; log: $(cat "$log")"
  [ "$enter_count" -eq 1 ] || fail "a blocked submit should send one Enter, got $enter_count; log: $(cat "$log")"
  [ -f "$dir/sink" ] || fail "a submit must not remove a dialog record its caller owns"
  pass "fm_backend_send_text_submit (herdr): a picker behind a blocked verdict is named by the caller's next composer read"
}

test_send_text_submit_confirms_blocked_after_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/4.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "needs approval" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should treat a blocked state after Enter as a confirmed delivered prompt, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "blocked after Enter must not provoke a retry into the prompt, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a post-Enter blocked state confirms delivery without retrying into the prompt"
}

test_send_text_submit_preexisting_working_pending_is_queued_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-preexisting-working-queued"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Native working + proven pending after the retry budget is the OpenCode
  # busy-queued Enter: the harness accepted Enter and will submit when the
  # current turn ends. Footer transition is not the confirmation path here
  # because the pre-Enter native status is already working.
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/2.out"
  printf '  ready\n' > "$resp/3.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/6.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "a working native baseline plus proven pending after retries is a queued Enter, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "queued-Enter confirmation should use the configured retry count, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: native working + proven pending after retries reports empty (queued Enter)"
}

test_send_text_submit_preexisting_working_does_not_confirm_failed_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-preexisting-working-enter-failed"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/2.out"
  printf '  ready\n' > "$resp/3.out"
  printf '1\n' > "$resp/4.exit"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/6.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "a failed Enter must not be reported as queued delivery merely because native status is working, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should attempt the configured number of Enters, made $enter_count attempt(s)"
  pass "fm_backend_herdr_send_text_submit: a failed Enter cannot borrow preexisting working state as queued-delivery proof"
}

test_send_text_submit_idle_baseline_does_not_confirm_failed_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-idle-enter-failed"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '1\n' > "$resp/3.exit"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "a failed Enter must not borrow a later native transition as delivery proof, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should attempt the configured number of Enters, made $enter_count attempt(s)"
  [ "$(grep -c $'\x1f''agent'$'\x1f''get' "$log")" -eq 2 ] || fail "a failed Enter must not run native delivery confirmation beyond the identity and baseline reads"
  pass "fm_backend_herdr_send_text_submit: a failed Enter cannot borrow a later native transition as delivery proof"
}

test_send_text_submit_idle_native_empty_composer_confirms_delivery() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-idle-native-empty-composer"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Live Claude on Herdr 0.8.0 keeps agent_status idle through a landed turn.
  # After Enter, native wait_for_working stays idle and the composer clears:
  # that empty verdict is positive delivery, not a swallow.
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/5.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "an idle native status plus a cleared composer must confirm delivery, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a cleared composer should confirm without extra Enters, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: idle native agent-state plus empty composer reports empty (landed Claude turn)"
}

test_send_text_submit_idle_native_pending_plus_rendered_busy_is_queued() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-idle-native-rendered-busy-queued"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Idle native baseline (Claude never leaves idle) with proven pending text
  # and a generating footer after retries is a queued follow-up Enter.
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  printf 'thinking... esc to interrupt\n' > "$resp/7.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "idle native + proven pending + rendered busy after retries is a queued Enter, got '$out'"
  pass "fm_backend_herdr_send_text_submit: idle native baseline uses a rendered busy footer to confirm a queued Enter"
}

# --- the never-idle-native-state harness (real cursor on herdr) --------------
# Measured live on cursor-agent 2026.08.11-e8db854 under herdr: `agent get`
# reports a cursor pane `blocked` in EVERY state - idle, mid-turn, and after -
# so the idle-baseline native path is structurally unreachable and every typed
# send lands in the composer branch. Cursor's mid-turn composer row renders its own
# `Add a follow-up` placeholder beside a right-aligned `ctrl+c to stop`, so the
# content verdict is `pending` on a composer holding no user text, and every
# typed steer reported delivery unconfirmed on a message that had actually landed.
# The bytes below are the real captures from that pane.

# The idle capture: no busy token anywhere, which is the pre-Enter baseline.
herdr_cursor_idle_plain() {
  printf '%b' ' ▄▄▄▄▄▄▄▄▄▄\n  → Add a follow-up\n ▀▀▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 7%%           Run Everything\n  ~/.treehouse/curhd-ae68cd/1/curhd · 39418af\n'
}

# The mid-turn capture, plain: the spinner verb rotates, the `ctrl+c to stop`
# token does not, which is why the token is what the matcher keys on.
herdr_cursor_midturn_plain() {
  printf '%b' ' ⠘⠆ Running  59 tokens\n ▄▄▄▄▄▄▄▄▄▄\n  → Add a follow-up                   ctrl+c to stop\n ▀▀▀▀▀▀▀▀▀▀\n  1 task\n  Cursor Grok 4.5 High · 7%%           Run Everything\n  ~/.treehouse/curhd-ae68cd/1/curhd · 39418af\n'
}

# The same mid-turn rows as herdr renders them with styling: the glyph and the
# placeholder tail are dim, the cell under the parked terminal cursor is
# reverse video, and the busy token trails on the SAME row.
herdr_cursor_midturn_ansi() {
  printf '%b' ' \033[0m\033[38;2;21;21;21m▄▄▄▄▄▄▄▄▄▄\033[0m\r\n \033[0m\033[48;2;21;21;21m \033[0m\033[2m\033[48;2;21;21;21m→ \033[0m\033[7m\033[48;2;21;21;21mA\033[0m\033[2m\033[48;2;21;21;21mdd a follow-up\033[0m\033[48;2;21;21;21m                   \033[0m\033[2m\033[48;2;21;21;21mctrl+c to stop\033[0m\033[48;2;21;21;21m \033[0m\r\n \033[0m\033[38;2;21;21;21m▀▀▀▀▀▀▀▀▀▀\033[0m\r\n  \033[0m\033[38;5;4m1 task\033[0m\r\n  \033[0m\033[2mCursor Grok 4.5 High\033[0m \033[0m\033[2m·\033[0m \033[0m\033[2m7%%\033[0m           \033[0m\033[38;5;5mRun Everything\033[0m\r\n  \033[0m\033[2m~/.treehouse/curhd-ae68cd/1/curhd · 39418af\033[0m\r\n'
}

# Non-vacuity anchor for the two submit tests below: the real mid-turn capture
# genuinely reads `pending`, so the confirmation those tests assert can only be
# coming from the rendered-footer transition and never from a softened composer
# verdict. The composer verdict is deliberately NOT relaxed - a right-aligned
# status token on the composer row is content the shared classifier must keep
# treating as content for every other caller.
test_composer_state_cursor_midturn_row_reads_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-cursor-midturn"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_cursor_midturn_ansi > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "cursor's mid-turn composer row carries a busy token and must stay 'pending' as composer CONTENT, got '$out'"
  pass "fm_backend_herdr_composer_state: cursor's mid-turn placeholder-plus-busy-token row reads pending (why delivery needs a separate signal)"
}

test_rendered_busy_state_reads_the_cursor_busy_token() {
  local dir log resp fb idle_out busy_out fail_out
  dir="$TMP_ROOT/rendered-busy"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_cursor_idle_plain > "$resp/1.out"
  herdr_cursor_midturn_plain > "$resp/2.out"
  printf '1\n' > "$resp/3.exit"
  fb=$(make_herdr_fakebin "$dir")
  idle_out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_rendered_busy_state default:w1:p2' "$ROOT" )
  busy_out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_rendered_busy_state default:w1:p2' "$ROOT" )
  fail_out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_rendered_busy_state default:w1:p2' "$ROOT" )
  [ "$idle_out" = idle ] || fail "an idle cursor pane renders no busy token and must read idle, got '$idle_out'"
  [ "$busy_out" = busy ] || fail "a mid-turn cursor pane renders 'ctrl+c to stop' and must read busy, got '$busy_out'"
  [ "$fail_out" = unknown ] || fail "an unreadable pane must read unknown, never idle, got '$fail_out'"
  pass "fm_backend_herdr_rendered_busy_state: busy/idle/unknown from the rendered footer, with an unreadable pane never reading idle"
}

test_send_text_submit_confirms_never_idle_native_state_via_footer_transition() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-cursor-footer-transition"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text
  # 2: agent get - cursor is `blocked` even while idle, so the native
  #    idle-baseline path is unreachable and the composer branch runs
  # 3: pane read - rendered footer baseline: no busy token, so the pane was NOT
  #    mid-turn before our Enter
  # 4: send-keys enter
  # 5: pane read - composer content mid-turn: placeholder plus busy token
  # 6: pane read - rendered footer now busy: an idle-to-busy transition ACROSS
  #    our Enter, which is the submission proof
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/2.out"
  herdr_cursor_idle_plain > "$resp/3.out"
  herdr_cursor_midturn_ansi > "$resp/5.out"
  herdr_cursor_midturn_plain > "$resp/6.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "an idle-to-busy rendered-footer transition must confirm the submit for a harness whose native state never goes idle, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a confirmed submit must not send a needless extra Enter, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a rendered-footer idle-to-busy transition confirms delivery when native agent-state never reports idle"
}

test_send_text_submit_never_idle_native_state_keeps_pending_without_a_transition() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-cursor-no-transition"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # The pane was ALREADY mid-turn before our Enter, so its busy footer is not
  # evidence about OUR message: the verdict must stay pending rather than
  # borrowing someone else's turn as proof of our delivery.
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/2.out"
  herdr_cursor_midturn_plain > "$resp/3.out"
  herdr_cursor_midturn_ansi > "$resp/5.out"
  herdr_cursor_midturn_ansi > "$resp/7.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "a pane already busy before our Enter must not confirm from that same busy footer, got '$out'"
  pass "fm_backend_herdr_send_text_submit: an already-busy footer baseline is never accepted as proof that this Enter landed"
}

# Regression for the submit-confirmation side of the 2026-07-07 incident:
# even if a Codex idle composer displays suggestion text, an idle-baseline
# submit must confirm from native agent-state rather than composer scraping.
# The pre-injection composer guard has its own faint-suggestion coverage below.
test_send_text_submit_confirms_despite_codex_idle_tip_composer() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-codex-idle-tip"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "reply with just OK" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should confirm via agent_status alone even for a harness whose idle composer shows dynamic tip text, got '$out'"
  [ "$(grep -c $'\x1f''pane'$'\x1f''read' "$log")" -eq 0 ] || fail "send_text_submit must never call 'pane read' - a codex-style dynamic idle-tip composer can never mislead a confirmation path that does not read it"
  pass "fm_backend_herdr_send_text_submit: confirms submission via native agent-state alone, immune to a codex-style dynamic idle-tip composer that would have misread as 'pending' under the old composer-based confirmation"
}

# Companion regression for the pre-injection empty-box guard itself
# (bin/fm-supervise-daemon.sh's pane_input_pending): a real Codex idle
# composer can show faint ghost suggestions after the bare `›` prompt.
# The guard must ignore that faint suggestion text, otherwise away-mode
# escalation delivery defers forever even though the human has typed nothing.
test_composer_state_codex_dynamic_idle_tip_reads_empty_when_faint() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-dynamic-tip"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 OK\n\n\n\x1b[0m\x1b[1m\xe2\x80\xba \x1b[0m\x1b[2mSummarize recent commits\x1b[0m\n\n  gpt-5.5 xhigh \xc2\xb7 Context 97%% left \xc2\xb7 /private/tmp \xc2\xb7 2\xe2\x80\xa6\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a faint real-codex dynamic idle-tip row should read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a faint real-codex dynamic idle-tip composer row reads empty"
}

# Regression guard for the PRE-injection empty-box guard itself
# (bin/fm-supervise-daemon.sh's pane_input_pending, dispatched via
# fm_backend_composer_state -> fm_backend_herdr_composer_state): this task
# changes ONLY submit confirmation, so genuine unsubmitted text in the
# composer must still read 'pending' and the guard must still refuse to
# inject into it.
test_composer_state_guard_still_refuses_real_pending_text_after_submit_confirmation_change() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-guard-still-refuses"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  \xe2\x9d\xaf hello there this is a test message\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_composer_state herdr default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "the pre-injection empty-box guard must still refuse real unsubmitted composer text after this change, got '$out'"
  pass "fm_backend_composer_state (herdr): the pre-injection empty-box guard still refuses a genuinely non-empty composer, unaffected by the submit-confirmation change"
}

# A slow transition landing partway through a single Enter attempt's own
# budget must not provoke a needless extra Enter - end-to-end through
# send_text_submit itself (test_wait_for_working_catches_a_slow_transition_mid_window
# above covers the primitive directly; this proves the caller wires it
# correctly).
test_send_text_submit_slow_transition_within_one_enter_needs_no_extra_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-slow-transition"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text  2: baseline idle  3: send-keys enter  4,5: agent get -> idle  6: agent get -> working
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/6.out"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=3 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.03 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should confirm once a later sample within the SAME Enter attempt observes working, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a slow (but within-budget) transition must not provoke a needless extra Enter, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a slow transition landing on a later sample within one Enter's budget is confirmed WITHOUT sending a needless extra Enter"
}

test_send_text_submit_send_failed() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the literal send itself fails, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'send-failed' when the literal send-text call itself errors"
}

test_send_text_submit_unknown_on_capture_failure() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-read-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '1\n' > "$resp/4.exit"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = unknown ] || fail "send_text_submit should report unknown when the post-Enter agent-get read fails, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit must never retry past an unreadable target (that is a hard I/O failure, not a timing race), sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: reports 'unknown' when the post-Enter agent-get read fails (never retries past an unreadable target)"
}

test_send_text_submit_unknown_on_composer_capture_failure() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-composer-read-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '1\n' > "$resp/5.exit"
  herdr_submit_identity_prefix "$resp" codex
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = unknown ] || fail "send_text_submit should report unknown when native status stays idle but the composer cannot be read, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit must not retry Enter after composer verification becomes unreadable, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: an unreadable composer stops Enter retries after native status stays idle"
}

# On a Claude pane, a long payload the selected composer still holds is
# submitted whole. A composer that kept only a suffix, a stale transcript head
# above that suffix, or a paste placeholder plus a literal remainder does not
# receive Enter, is cleared back to empty, and is not reported delivered.
herdr_long_payload() {  # <middle-length>
  awk -v n="$1" 'BEGIN { printf "HEAD"; for (i = 0; i < n; i++) printf "m"; printf "TAIL" }'
}

herdr_ctrl_u_count() {  # <log>
  grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''ctrl+u' "$1"
}

# herdr_wrapped_composer: a Claude composer holding <text> wrapped at <width>
# columns, with its first <drop> rows already deleted. Live Claude's Ctrl+U
# deletes one wrapped screen row per press, so a stub that clears a whole
# single-line draft with one press would hide an undercounted clear.
herdr_wrapped_composer() {  # <text> <width> <drop>
  local text=$1 width=$2 drop=$3 prefix='  \xe2\x9d\xaf '
  text=${text:$((drop * width))}
  [ -n "$text" ] || { printf '  \xe2\x9d\xaf\n'; return 0; }
  while [ -n "$text" ]; do
    printf "$prefix%s\n" "${text:0:$width}"
    text=${text:$width}
    prefix='    '
  done
}

# herdr_popup_composer_screen: a Claude Code 2.1.283-shaped screen after a
# typed slash command, with the command popup rendered BETWEEN the composer
# and the pane bottom. Verified live: the popup is ~19 menu rows, so the
# composer row lands outside a 20-row tail window - a bounded tail read
# reports the composer as empty while it holds typed text, which broke
# fm-control exit (the typed /exit was judged unsent and cleared). The
# composer reads capture the full visible viewport instead. The composer
# sits inside a solid-rule pair (rule above, rule below), exactly as live
# Claude draws it, with the menu rows below the closing rule; the rules are
# structural edge rows, so the composer's content block ends there and the
# unmarked menu rows never read as typed text. Claude Code 2.1.291 marks the
# popup's selected row with a `❯` of its own, which is a different shape; the
# real captures under tests/captures/claude-2.1.291-slash-popup cover it.
herdr_popup_composer_screen() {  # <typed-text>
  local i typed=$1 rule
  rule=$(printf '%0.s\xe2\x94\x80' $(seq 1 60))
  printf ' \xe2\x95\xad\xe2\x94\x80\xe2\x94\x80 Claude Code v2.1.283 \xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n'
  printf '  %s\n' "$rule"
  printf '  \xe2\x9d\xaf %s\n' "$typed"
  printf '  %s\n' "$rule"
  printf '  %s    Exit the CLI\n' "$typed"
  for ((i = 0; i < 21; i++)); do
    printf '  /skill-%02d    A skill description long enough to read as a popup row\n' "$i"
  done
  printf '  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on\n'
}

test_send_text_submit_long_literal_submits_when_composer_holds_every_byte() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-long-exact"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_claude_prefix "$resp" "$text"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a composer holding the full long payload should confirm delivery, got '$out'"
  [ "${#text}" -eq 1500 ] || fail "the long payload fixture was ${#text} chars, not 1500"
  assert_contains "$(cat "$log")" $'\x1f'"$text" "send_text_submit did not type the full long payload"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a fully observed long payload should be submitted once, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "a proven payload must not be cleared"
  pass "fm_backend_herdr_send_text_submit: a 1500-character payload a Claude composer still holds is submitted whole"
}

test_send_text_submit_refuses_enter_when_composer_holds_only_the_suffix() {
  local dir log resp fb out enter_count text suffix
  dir="$TMP_ROOT/submit-long-suffix"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf %s\n' "$suffix" > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a composer holding only the payload suffix, cleared back to empty, should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a suffix must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 1 ] || fail "the refused suffix should be cleared with one Ctrl+U, sent $(herdr_ctrl_u_count "$log")"
  [ "$(grep -c $'\x1f''agent'$'\x1f''get' "$log")" -eq 1 ] || fail "a refused suffix must not be confirmed by a later working status"
  pass "fm_backend_herdr_send_text_submit: a long payload whose Claude composer kept only the tail is not submitted, is cleared, and reports send-failed"
}

test_send_text_submit_refused_suffix_that_will_not_clear_is_unknown() {
  local dir log resp fb out enter_count text suffix cap n
  dir="$TMP_ROOT/submit-long-suffix-stuck"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf %s\n' "$suffix" > "$resp/4.out"
  cap=$(( 1500 / 40 + 8 ))
  for ((n = 6; n <= 4 + 2 * cap; n += 2)); do
    printf '  \xe2\x9d\xaf %s\n' "$suffix" > "$resp/$n.out"
  done
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = unknown ] || fail "a refused suffix that stays in the composer must not claim nothing was typed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a suffix must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq "$cap" ] || fail "a leftover that will not clear should get a bounded $cap Ctrl+U presses, sent $(herdr_ctrl_u_count "$log")"
  pass "fm_backend_herdr_send_text_submit: a refused suffix whose clear cannot be verified reports unknown, not send-failed"
}

test_send_text_submit_clears_a_wrapped_suffix_one_row_per_press() {
  local dir log resp fb out enter_count text suffix drop
  dir="$TMP_ROOT/submit-long-suffix-wrapped"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  for drop in 0 1 2 3 4 5; do
    herdr_wrapped_composer "$suffix" 96 "$drop" > "$resp/$((4 + 2 * drop)).out"
  done
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a refused suffix wrapped over five rows, cleared row by row, should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a suffix must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 5 ] || fail "a five-row wrapped suffix should take five Ctrl+U presses, sent $(herdr_ctrl_u_count "$log")"
  pass "fm_backend_herdr_send_text_submit: a refused 480-character suffix wrapped over five rows is cleared one row per Ctrl+U and reports send-failed"
}

test_send_text_submit_refused_suffix_then_clean_retry_submits_only_the_message() {
  local dir log resp fb out enter_count text suffix
  dir="$TMP_ROOT/submit-long-suffix-retry"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf %s\n' "$suffix" > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/7.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/8.out"
  printf '  \xe2\x9d\xaf %s\n' "$text" > "$resp/10.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/11.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/13.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"
      first=$(fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01)
      second=$(fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01)
      printf "%s %s" "$first" "$second"' "$ROOT" "$text" )
  [ "$out" = "send-failed empty" ] || fail "a refused send followed by a resend should report 'send-failed empty', got '$out'"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-text'$'\x1f''w1:p2'$'\x1f'"$text" "$log")" -eq 2 ] || fail "each attempt should type the full message exactly once"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "only the clean retry should be submitted, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: after a refused suffix is cleared, a resend starts from an empty Claude composer and submits only the message"
}

test_send_text_submit_claude_refuses_to_type_into_a_nonempty_composer() {
  local dir log resp fb out text
  dir="$TMP_ROOT/submit-claude-leftover"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '  \xe2\x9d\xaf %s\n' "${text: -480}" > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a Claude composer that already holds text should refuse the send, got '$out'"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-text' "$log")" -eq 0 ] || fail "nothing may be typed after a leftover tail, or Enter would submit tail plus message"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-keys' "$log")" -eq 0 ] || fail "a refused pre-send composer must not receive any key"
  pass "fm_backend_herdr_send_text_submit: a Claude composer holding leftover text is refused before anything is typed"
}

test_send_text_submit_refuses_suffix_when_transcript_still_shows_the_head() {
  local dir log resp fb out enter_count text suffix
  dir="$TMP_ROOT/submit-stale-head"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  {
    printf '%s\n' "$text"
    printf '  \xe2\x9d\xaf %s\n' "$suffix"
  } > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a stale transcript head above a suffix composer should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a transcript head must not authorize Enter for a suffix composer, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a matching head in the transcript does not prove the current composer"
}

# Away-mode digests and marked firstmate steers carry U+2063, which Claude's
# composer read-back on Herdr drops (verified live). The rest of the payload,
# byte for byte, is still proof; a missing message head is still refused.
test_send_text_submit_accepts_marked_payloads_whose_read_back_drops_u2063() {
  local kind dir log resp fb out enter_count text shown
  for kind in digest steer; do
    dir="$TMP_ROOT/submit-u2063-$kind"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    if [ "$kind" = digest ]; then
      text=$(bash -c '. "$0/bin/fm-operational-input.sh"; fm_operational_input_encode away-supervisor "$1" out; printf "%s" "$out"' \
        "$ROOT" "$(herdr_long_payload 1492)")
    else
      text=$(bash -c '. "$0/bin/fm-operational-input.sh"; printf "%s %s" "$FM_FROMFIRST_MARK" "$1"' "$ROOT" "please rebase onto main")
    fi
    shown=${text//$'\xe2\x81\xa3'/}
    [ "$shown" != "$text" ] || fail "the $kind fixture did not carry U+2063"
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
    printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
    herdr_submit_claude_prefix "$resp" "$text"
    printf '  \xe2\x9d\xaf\xc2\xa0%s\n' "$shown" > "$resp/4.out"
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
    [ "$out" = empty ] || fail "a marked $kind whose read-back only lacks U+2063 should be submitted, got '$out'"
    assert_contains "$(cat "$log")" $'\x1f'"$text" "the marked $kind was not typed with its U+2063"
    enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
    [ "$enter_count" -eq 1 ] || fail "a marked $kind should be submitted once, sent $enter_count Enter(s)"
    [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "an accepted marked $kind must not be cleared"
  done
  pass "fm_backend_herdr_send_text_submit: an away-mode digest and a marked steer are submitted when Claude's read-back only drops U+2063"
}

test_send_text_submit_refuses_marked_digest_missing_its_head() {
  local dir log resp fb out enter_count text shown
  dir="$TMP_ROOT/submit-u2063-suffix"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(bash -c '. "$0/bin/fm-operational-input.sh"; fm_operational_input_encode away-supervisor "$1" out; printf "%s" "$out"' \
    "$ROOT" "$(herdr_long_payload 1492)")
  shown=${text//$'\xe2\x81\xa3'/}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf\xc2\xa0%s\n' "${shown: -480}" > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a marked digest whose composer kept only the tail should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a marked digest tail must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 1 ] || fail "the refused marked digest tail should be cleared"
  pass "fm_backend_herdr_send_text_submit: dropping U+2063 does not let a marked digest missing its head be submitted"
}

# Claude Code 2.1.283 renders a slash-command popup between the composer and
# the pane bottom, pushing the composer row outside a 20-row tail window. The
# composer reads must capture the full visible viewport: the old bounded read
# reported the composer empty, so the typed /exit was judged unsent, cleared,
# and never submitted (fm-control exit never exited).
test_composer_state_claude_slash_popup_pushes_composer_above_tail_window() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-slash-popup"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_popup_composer_screen '/exit' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "a composer above a slash-command popup must read pending, got '$out'"
  grep -F $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2'$'\x1f''--source'$'\x1f''visible' "$log" >/dev/null \
    || fail "the composer state read must use the visible viewport"
  [ "$(grep -c $'\x1f''--lines' "$log")" -eq 0 ] || fail "the composer state read must not be a bounded --lines tail"
  pass "fm_backend_herdr_composer_state: a slash-command popup cannot hide a typed composer"
}

test_send_text_submit_claude_slash_popup_composer_is_still_proven_and_submitted() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-claude-slash-popup"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text='/exit'
  herdr_submit_claude_prefix "$resp" "$text"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  herdr_popup_composer_screen "$text" > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a composer proven above a slash-command popup must be submitted, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "the proven typed command should be submitted once, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "a proven composer must not be cleared"
  grep -F $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2'$'\x1f''--source'$'\x1f''visible' "$log" >/dev/null \
    || fail "the payload proof must use the visible viewport"
  [ "$(grep -c $'\x1f''--lines' "$log")" -eq 0 ] || fail "no composer read may be a bounded --lines tail"
  pass "fm_backend_herdr_send_text_submit: a typed slash command hidden behind its popup is still proven and submitted"
}

# Claude Code 2.1.291 draws the selected row of its slash-command popup with the
# same `❯` marker as its composer, so that row was read as a second composer and
# the popup list as the typed command: fm-control exit and every slash command
# sent through fm-send judged the payload unsent, cleared it, and reported
# send-failed. The screens are real captures (Herdr 0.8.2, Haiku 4.5).
herdr_popup_capture() {  # <name>
  cat "$ROOT/tests/captures/claude-2.1.291-slash-popup/$1.ansi"
}

# herdr_popup_capture_with_composer: the real capture <name> with its composer
# row replaced by <composer-text>, the popup rows below it left exactly as
# captured. Used for the refusals that must hold while a popup is on screen.
herdr_popup_capture_with_composer() {  # <name> <composer-text>
  local name=$1 text=$2
  {
    herdr_popup_capture "$name" | sed -n 1p
    printf '\xe2\x9d\xaf\xc2\xa0%s\n' "$text"
    herdr_popup_capture "$name" | sed -n '3,$p'
  }
}

test_composer_content_claude_2_1_291_marked_popup_row_is_not_the_composer() {
  local dir log resp fb out pair name want
  for pair in exit-typed:/exit exit-typed-with-notice:/exit no-mistakes-typed:/no-mistakes; do
    name=${pair%%:*}
    want=${pair#*:}
    dir="$TMP_ROOT/composer-claude-2-1-291-popup-$name"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    herdr_popup_capture "$name" > "$resp/1.out"
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_content default:w1:p2' "$ROOT" )
    [ "$out" = "$want" ] || fail "$name: the composer read must be '$want', not the popup list, got '$out'"
    printf '%s\n' "$out" | grep -F 'Exit the CLI' >/dev/null && fail "$name: the popup list leaked into the composer read"
    dir="$TMP_ROOT/composer-state-claude-2-1-291-popup-$name"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    herdr_popup_capture "$name" > "$resp/1.out"
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
    [ "$out" = pending ] || fail "$name: a typed command above its popup must read pending, got '$out'"
  done
  pass "fm_backend_herdr_composer_content: Claude 2.1.291's marked popup row is not read as the typed command"
}

test_send_text_submit_claude_2_1_291_marked_popup_row_is_proven_and_submitted() {
  local dir log resp fb out enter_count pair name text
  for pair in exit-typed:/exit exit-typed-with-notice:/exit no-mistakes-typed:/no-mistakes; do
    name=${pair%%:*}
    text=${pair#*:}
    dir="$TMP_ROOT/submit-claude-2-1-291-popup-$name"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    herdr_submit_claude_prefix "$resp" "$text"
    printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
    printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
    herdr_popup_capture "$name" > "$resp/4.out"
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
    [ "$out" = empty ] || fail "$name: a typed $text proven above its marked popup row must be submitted, got '$out'"
    enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
    [ "$enter_count" -eq 1 ] || fail "$name: the proven typed command should be submitted once, sent $enter_count Enter(s)"
    [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "$name: a proven composer must not be cleared"
  done
  pass "fm_backend_herdr_send_text_submit: a slash command behind Claude 2.1.291's marked popup row is proven and submitted"
}

# The marked popup row must not weaken the head-truncation protection: a
# composer holding only a suffix, a paste placeholder followed by a literal
# remainder, or only a prefix of the payload is still refused and cleared while
# the same popup is on screen.
test_send_text_submit_claude_2_1_291_popup_still_refuses_a_partial_payload() {
  local dir log resp fb out enter_count name capture text composer
  while IFS='|' read -r name capture text composer; do
    dir="$TMP_ROOT/submit-claude-2-1-291-popup-refuse-$name"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    herdr_submit_claude_prefix "$resp" "$text"
    herdr_popup_capture_with_composer "$capture" "$composer" > "$resp/4.out"
    printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
    printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
    [ "$out" = send-failed ] || fail "$name: a partial payload ('$composer') under the popup must report send-failed, got '$out'"
    enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
    [ "$enter_count" -eq 0 ] || fail "$name: a partial payload must not be submitted, sent $enter_count Enter(s)"
    [ "$(herdr_ctrl_u_count "$log")" -eq 1 ] || fail "$name: the refused partial payload should be cleared with one Ctrl+U"
  done <<'EOF'
suffix|no-mistakes-typed|/no-mistakes|mistakes
placeholder-remainder|no-mistakes-typed|/no-mistakes|[Pasted text #1] mistakes
prefix|no-mistakes-typed|/no-mistakes now|/no-mistakes
popup-suffix|exit-typed|/exit|xit
EOF
  pass "fm_backend_herdr_send_text_submit: with Claude 2.1.291's popup on screen a suffix, a placeholder plus remainder, or a prefix is still refused and cleared"
}

# Live Claude Code 2.1.283 draws a recognized typed slash command in muted
# truecolor grey (38;2;112;112;112, luminance 112), below the grok-tuned
# dark-foreground ghost threshold. Claude's own ghost suggestion is SGR-2 dim,
# so the Claude payload proof must not strip the grey command and judge the
# typed /exit unsent (the fm-control exit breakage, reproduced live).
test_send_text_submit_claude_grey_slash_command_is_proven_and_submitted() {
  local dir log resp fb out enter_count text rule head
  dir="$TMP_ROOT/submit-claude-grey-slash"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text='/exit'
  herdr_submit_claude_prefix "$resp" "$text"
  rule=$(printf '%0.s\xe2\x94\x80' $(seq 1 60))
  head=$(printf '%0.s\xe2\x94\x80' $(seq 1 19))
  {
    printf '  \x1b[0m\x1b[38;2;112;112;112m/\x1b[0m\x1b[1m\x1b[38;2;112;112;112mexit\x1b[0m\x1b[38;2;112;112;112m    Exit the CLI\x1b[0m\n'
    printf '\x1b[0m\x1b[38;2;121;129;134m%s Firstmate operational input 1790546042 \xe2\x94\x80\x1b[0m\n' "$head"
    printf '\xe2\x9d\xaf\xc2\xa0\x1b[0m\x1b[38;2;112;112;112m/exit\x1b[0m\n'
    printf '\x1b[0m\x1b[38;2;121;129;134m%s\x1b[0m\n' "$rule"
    printf '  \x1b[0m\x1b[38;2;86;93;96m\xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on\x1b[0m\n'
  } > "$resp/4.out"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a typed /exit drawn in Claude's grey slash-command colour must be proven and submitted, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "the proven grey slash command should be submitted once, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "a proven grey slash command must not be cleared"
  pass "fm_backend_herdr_send_text_submit: a typed slash command Claude draws in muted truecolor grey is proven and submitted"
}

test_send_text_submit_lone_paste_placeholder_submits_the_long_payload() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-paste-placeholder"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf [Pasted text #1]\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a lone paste placeholder for the whole burst should still be submitted, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f'"$text" "the typed payload was not the full long text"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a lone paste placeholder should be submitted once, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a lone paste placeholder still submits the full long payload"
}

# Live Claude 2.1.278 collapses a long multi-line paste into
# `[Pasted text #N +M lines]` and expands it on submit, like the one-line form.
test_send_text_submit_multiline_paste_placeholder_submits_the_long_payload() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-multiline-placeholder"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(awk 'BEGIN { for (i = 1; i <= 42; i++) printf "steer line %02d with enough words to be a real instruction\n", i }')
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf [Pasted text #4 +40 lines]\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "a lone multi-line paste placeholder for the whole burst should be submitted, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a lone multi-line paste placeholder should be submitted once, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 0 ] || fail "an accepted multi-line placeholder must not be cleared"
  pass "fm_backend_herdr_send_text_submit: a lone multi-line paste placeholder still submits the long multi-line payload"
}

test_send_text_submit_refuses_placeholder_followed_by_a_literal_remainder() {
  local dir log resp fb out enter_count text suffix
  dir="$TMP_ROOT/submit-paste-remainder"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 1492)
  suffix=${text: -480}
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf [Pasted text #1]%s\n' "$suffix" > "$resp/4.out"
  printf '  \xe2\x9d\xaf\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = send-failed ] || fail "a paste placeholder followed by a literal remainder should report send-failed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 0 ] || fail "a placeholder plus remainder must not be submitted, sent $enter_count Enter(s)"
  [ "$(herdr_ctrl_u_count "$log")" -eq 1 ] || fail "the refused placeholder and remainder should be cleared"
  pass "fm_backend_herdr_send_text_submit: a paste placeholder followed by a literal remainder is not submitted and is cleared"
}

test_send_text_submit_three_paste_placeholders_submit_the_long_payload() {
  local dir log resp fb out enter_count text
  dir="$TMP_ROOT/submit-three-placeholders"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  text=$(herdr_long_payload 2992)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  herdr_submit_claude_prefix "$resp" "$text"
  printf '  \xe2\x9d\xaf [Pasted text #1][Pasted text #2][Pasted text #3]\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
  [ "$out" = empty ] || fail "three paste placeholders with no literal remainder should be submitted, got '$out'"
  [ "${#text}" -eq 3000 ] || fail "the 3000-character fixture was ${#text} chars"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "three placeholders should be submitted once, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: three paste placeholders with no literal remainder submit the long payload"
}

# A non-Claude harness keeps the unproven type-then-Enter path: its composer
# is never read before Enter, so a harness-specific placeholder or an
# unselectable composer cannot turn a landed send into send-failed.
test_send_text_submit_non_claude_skips_the_payload_proof() {
  local agent dir log resp fb out enter_count text
  text=$(herdr_long_payload 1492)
  for agent in codex missing; do
    dir="$TMP_ROOT/submit-non-claude-$agent"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/3.out"
    printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/5.out"
    if [ "$agent" = missing ]; then
      printf '1\n' > "$resp/1.exit"
    else
      printf '{"result":{"agent":{"agent":"%s","agent_status":"idle"}}}\n' "$agent" > "$resp/1.out"
    fi
    fb=$(make_herdr_fakebin "$dir")
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 3 0.01 0.01' "$ROOT" "$text" )
    [ "$out" = empty ] || fail "a $agent pane should keep the type-then-Enter path and confirm from agent_status, got '$out'"
    [ "$(grep -c $'\x1f''pane'$'\x1f''read' "$log")" -eq 0 ] || fail "a $agent pane must not have its composer read before Enter"
    enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
    [ "$enter_count" -eq 1 ] || fail "a $agent pane should be submitted once, sent $enter_count Enter(s)"
  done
  pass "fm_backend_herdr_send_text_submit: non-Claude and unidentified panes keep the pre-proof type-then-Enter behavior"
}

# --- fm-backend.sh dispatch wiring -------------------------------------------

test_dispatch_routes_herdr_backend() {
  fm_backend_validate herdr 2>/dev/null || fail "fm_backend_validate should accept herdr (P2 adds it to FM_BACKEND_KNOWN)"
  pass "fm_backend_validate: herdr is a known backend (P2)"
}

test_dispatch_busy_state_unknown_for_tmux() {
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  [ "$(fm_backend_busy_state tmux 'sess:win')" = unknown ] \
    || fail "fm_backend_busy_state should report unknown for tmux (no native agent-state primitive; watcher falls back to regex)"
  pass "fm_backend_busy_state: tmux (no native primitive) always reports unknown, preserving the P1 regex-only path"
}

test_dispatch_composer_state_routes_by_backend() {
  # fm_backend_composer_state (the generic per-backend composer/pending-input
  # classifier the away-mode daemon dispatches through - bin/fm-supervise-daemon.sh's
  # pane_input_pending) must route to each backend's OWN named classifier with
  # the target passed through unchanged - every backend has one now, all thin
  # wrappers over the shared fm_composer_classify_screen - and report unknown
  # for an unrecognized backend name.
  # Sourced-guards are pre-set so fm_backend_source no-ops and these stubs are
  # never clobbered by the real per-backend files trying (and failing) a live call.
  (
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    _FM_BACKEND_TMUX_SOURCED=1
    _FM_BACKEND_HERDR_SOURCED=1
    _FM_BACKEND_ORCA_SOURCED=1
    _FM_BACKEND_ZELLIJ_SOURCED=1
    fm_tmux_composer_state() { [ "$1" = "sess:win" ] || fail "tmux composer_state got wrong target: $1"; printf 'pending'; }
    fm_backend_herdr_composer_state() { [ "$1" = "default:w1:p2" ] || fail "herdr composer_state got wrong target: $1"; printf 'empty'; }
    fm_backend_orca_composer_state() { [ "$1" = "term-1" ] || fail "orca composer_state got wrong target: $1"; printf 'empty'; }
    fm_backend_zellij_composer_state() { [ "$1" = "sess:7" ] || fail "zellij composer_state got wrong target: $1"; printf 'empty'; }
    [ "$(fm_backend_composer_state tmux sess:win)" = pending ] || fail "composer_state did not dispatch to the tmux classifier"
    [ "$(fm_backend_composer_state herdr default:w1:p2)" = empty ] || fail "composer_state did not dispatch to the herdr classifier"
    [ "$(fm_backend_composer_state orca term-1)" = empty ] || fail "composer_state did not dispatch to the orca classifier"
    [ "$(fm_backend_composer_state zellij sess:7)" = empty ] || fail "composer_state did not dispatch to the zellij classifier"
    [ "$(fm_backend_composer_state bogus x)" = unknown ] || fail "composer_state should report unknown for an unrecognized backend"
  ) || fail "composer_state dispatch subshell failed"
  pass "fm_backend_composer_state dispatches every backend to its named thin classifier, unknown for unrecognized backends"
}

test_scripts_route_explicit_target_through_meta_backend() {
  local dir state log resp fb neutral out
  dir="$TMP_ROOT/script-explicit-target"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/herdr-stale.meta" "window=default:w1:p2" "backend=herdr"
  touch "$state/.last-watcher-beat"
  printf 'captured herdr pane\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux should not be used for a metadata-matched herdr target\n' >&2
exit 42
SH
  chmod +x "$fb/tmux"

  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    "$ROOT/bin/fm-peek.sh" default:w1:p2 5 2>/dev/null )
  [ "$out" = "captured herdr pane" ] || fail "fm-peek did not capture through herdr for an explicit metadata-matched target, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2' \
    "fm-peek did not route the explicit stale target through herdr capture"

  : > "$log"
  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    "$ROOT/bin/fm-send.sh" default:w1:p2 --key Escape >/dev/null 2>&1
  expect_code 0 $? "fm-send --key should route an explicit metadata-matched target through herdr"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''escape' \
    "fm-send did not route the explicit stale target through herdr send-key"

  pass "fm-peek/fm-send: explicit stale targets matching metadata use the recorded backend"
}

# --- workspace lifecycle: reuse, no orphans, default-tab pruning -------------

test_workspace_ensure_prunes_default_tab() {
  local dir log state fb raw container seeded wsid ids pane tabcount
  dir="$TMP_ROOT/prune-default"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  wsid=${container#*:}
  [ -n "$seeded" ] || fail "container_ensure should report the seeded default tab id for a freshly created workspace, got raw='$raw'"
  # herdr seeds a fresh workspace with one auto-created default tab (label "1")
  # and closing a workspace's LAST tab deletes the whole workspace on real
  # herdr, so the adapter must not prune it until a real task tab exists
  # alongside it - verify it is still present right after container_ensure.
  tabcount=$(jq -r --arg w "$wsid" '[.tabs[]|select(.workspace_id==$w)]|length' "$state")
  [ "$tabcount" = 1 ] || fail "expected the untouched default tab to remain after container_ensure alone, got $tabcount tab(s): $(jq -c '.tabs' "$state")"
  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-prunetest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"
  # Once the real task tab exists, create_task must prune the SEEDED default
  # tab id container_ensure captured, so only the real task tab remains.
  tabcount=$(jq -r --arg w "$wsid" '[.tabs[]|select(.workspace_id==$w)]|length' "$state")
  [ "$tabcount" = 1 ] || fail "the auto-created default tab should be pruned once a real task tab exists, $tabcount tab(s) remain: $(jq -c '.tabs' "$state")"
  jq -r --arg w "$wsid" '[.tabs[]|select(.workspace_id==$w)][0].label' "$state" | grep -qx 'fm-prunetest' \
    || fail "the surviving tab should be the real task tab, not the default: $(jq -c '.tabs' "$state")"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' "create_task did not close the default tab's pane"
  pass "fm_backend_herdr_create_task: prunes exactly the seeded default tab container_ensure identified, once the first real task tab exists"
}

test_repeated_cycles_reuse_one_workspace_no_orphans() {
  local dir log state fb i raw container seeded wsid ids pane first_ws="" wscount total tabcount created
  dir="$TMP_ROOT/cycles"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  for i in 1 2 3; do
    raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
      || fail "cycle $i: container_ensure failed"
    container=${raw%%$'\t'*}
    seeded=${raw#*$'\t'}
    case "$container" in fmtest:w*) : ;; *) fail "cycle $i: unexpected container '$container'" ;; esac
    wsid=${container#*:}
    if [ -z "$first_ws" ]; then
      first_ws=$wsid
      [ -n "$seeded" ] || fail "cycle $i: the first cycle must create a fresh workspace and report its seeded default tab id"
    else
      [ "$wsid" = "$first_ws" ] || fail "cycle $i: workspace not reused ('$wsid' != '$first_ws')"
      [ -z "$seeded" ] || fail "cycle $i: a REUSED (adopted) workspace must never report a seeded default tab id, got '$seeded'"
    fi
    ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-cycle$i" "$seeded" ) \
      || fail "cycle $i: create_task failed"
    read -r _ pane <<EOF
$ids
EOF
    [ -n "$pane" ] || fail "cycle $i: create_task returned no pane id"
    PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
      bash -c '
        . "$0/bin/backends/herdr.sh"
        fm_backend_herdr_presentation_session_lock_path() { printf "/tmp/fm-herdr-cycle-test-lock"; }
        fm_lock_try_acquire() { return 0; }
        fm_lock_release() { return 0; }
        fm_backend_herdr_kill "$1"
      ' "$ROOT" "fmtest:$pane" \
      || fail "cycle $i: kill failed"
  done
  # exactly one firstmate workspace survives three spawn/teardown cycles
  wscount=$(jq -r '[.workspaces[]|select(.label=="firstmate")]|length' "$state")
  [ "$wscount" = 1 ] || fail "expected exactly 1 firstmate workspace after 3 cycles, got $wscount: $(jq -c '.workspaces' "$state")"
  # and no orphaned workspaces of any label
  total=$(jq -r '.workspaces|length' "$state")
  [ "$total" = 1 ] || fail "expected no orphaned workspaces after 3 cycles, got $total total: $(jq -c '.workspaces' "$state")"
  # zero tabs remain: every fm- task tab torn down AND the default tab pruned
  tabcount=$(jq -r '.tabs|length' "$state")
  [ "$tabcount" = 0 ] || fail "expected 0 tabs after teardown (default tab pruned, task tabs killed), got $tabcount: $(jq -c '.tabs' "$state")"
  # the workspace was minted once and reused thereafter, never re-created
  created=$(grep -c $'\x1f''workspace'$'\x1f''create' "$log")
  [ "$created" = 1 ] || fail "workspace create should run exactly once across 3 cycles (reuse, not re-mint), ran $created times"
  pass "herdr repeated spawn/teardown: one persistent firstmate workspace reused, zero orphans, default tab pruned, create ran once"
}

# --- created-vs-adopted default-tab-prune safety (2026-07-02 self-kill fix) -
#
# Root cause and fix are documented at
# fm_backend_herdr_workspace_prune_seeded_default_tab in bin/backends/herdr.sh
# and docs/herdr-backend.md's "Default-tab prune" section. These three tests
# cover the acceptance bar directly: an ADOPTED workspace's tab is never a
# prune candidate (regardless of label or count), a freshly CREATED
# workspace's seeded default tab IS pruned (already covered above by
# test_workspace_ensure_prunes_default_tab and
# test_repeated_cycles_reuse_one_workspace_no_orphans), and the exact
# label-collision startup-workspace shape that caused the real incident
# leaves the live tab alone.

test_adopted_workspace_never_prunes_default_tab() {
  # An ADOPTED workspace (fm_backend_herdr_workspace_find matched a
  # pre-existing workspace by label) must never have any tab pruned by
  # create_task, regardless of that tab's label or count - the created-vs-
  # adopted gate is structural (an empty seeded_tab_id), never re-derived
  # from label patterns at create_task time.
  local dir log state fb raw container seeded ids pane
  dir="$TMP_ROOT/adopt-no-prune"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  # Pre-seed a workspace that ALREADY exists before this spawn runs (as if a
  # previous session created it), with a single tab labeled "1" - the same
  # shape herdr's own auto-seeded default tab has, but this run's own
  # container_ensure never ran a `workspace create` call to produce it.
  jq -n '{next:2,workspaces:[{workspace_id:"w1",label:"firstmate"}],tabs:[{tab_id:"w1:t1",label:"1",workspace_id:"w1",pane_id:"w1:p1"}],agent_status:{}}' > "$state"
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  [ "$container" = "fmtest:w1" ] || fail "container_ensure should have ADOPTED the pre-existing workspace w1, got '$container'"
  [ -z "$seeded" ] || fail "an ADOPTED workspace must report an EMPTY seeded default tab id, got '$seeded'"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "container_ensure must not create a new workspace when one already exists to adopt"

  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-adopttest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"

  # The pre-existing tab (and its pane) must be COMPLETELY untouched.
  jq -e '.tabs[] | select(.tab_id == "w1:t1")' "$state" >/dev/null \
    || fail "the pre-existing (adopted) tab w1:t1 was removed - an adopted workspace's tab must never be pruned"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p1' \
    "create_task must never close a tab belonging to an ADOPTED workspace, no matter its label or count"
  pass "fm_backend_herdr_create_task: an ADOPTED workspace's pre-existing tab is never pruned (the created-vs-adopted gate)"
}

test_label_collision_startup_workspace_leaves_live_tab_alone() {
  # The exact live-fire incident shape (2026-07-02): a captain launches herdr
  # directly inside a directory named "firstmate", so herdr auto-derives that
  # workspace's DISPLAYED label from the cwd basename - "firstmate" - byte-
  # identical to the primary firstmate home's own derived label, with no
  # --label ever passed and no firstmate involvement at all. That workspace's
  # single auto-created tab (label "1") holds the captain's own live agent.
  # The very next crewmate spawn must adopt-and-leave-alone, never prune.
  local dir log state fb raw container seeded ids pane
  dir="$TMP_ROOT/label-collision"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  # Mimic a bare `herdr workspace create --cwd <dir-named-firstmate>` (no
  # --label): the resulting workspace's label is the cwd basename, and its
  # one auto-created tab is still labeled "1" - indistinguishable, by label
  # alone, from firstmate's own freshly-seeded default tab. Its pane hosts a
  # live agent (agent_status=working), exactly like the captain's own pane.
  jq -n '{next:2,workspaces:[{workspace_id:"w1",label:"firstmate"}],tabs:[{tab_id:"w1:t1",label:"1",workspace_id:"w1",pane_id:"w1:p1"}],agent_status:{"w1:p1":"working"}}' > "$state"
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  [ "$container" = "fmtest:w1" ] || fail "container_ensure should adopt the captain's coincidentally-labeled workspace, got '$container'"
  [ -z "$seeded" ] || fail "the coincidentally-labeled workspace was ADOPTED, not created, so seeded default tab id must be empty, got '$seeded'"

  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-collisiontest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"

  jq -e '.tabs[] | select(.tab_id == "w1:t1")' "$state" >/dev/null \
    || fail "REGRESSION: the captain's live tab was closed - this is the exact 2026-07-02 self-kill incident"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p1' \
    "REGRESSION: create_task closed the captain's live pane in the label-collision scenario"
  pass "fm_backend_herdr_create_task: the label-collision startup-workspace scenario (2026-07-02 incident) leaves the captain's live tab untouched"
}

test_prune_refuses_a_working_agent_pane_defense_in_depth() {
  # Defense in depth (not the primary safety mechanism): even for a
  # freshly-created workspace with a genuine non-empty seeded default tab id,
  # if that specific pane's agent reports "working" by the time create_task
  # runs, the prune must refuse rather than close a live agent's pane.
  local dir log state fb raw container seeded seeded_pane ids pane
  dir="$TMP_ROOT/prune-busy-defense"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  [ -n "$seeded" ] || fail "expected a freshly created workspace to report a seeded default tab id"
  # Mark the seeded default tab's pane as hosting a working agent (simulates
  # some other path landing a live agent there between creation and prune).
  seeded_pane=$(jq -r --arg t "$seeded" '.tabs[] | select(.tab_id == $t) | .pane_id' "$state")
  [ -n "$seeded_pane" ] || fail "could not resolve the seeded default tab's pane id from state"
  fake_herdr_set_agent_status "$state" "$seeded_pane" working

  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-busytest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"

  jq -e --arg t "$seeded" '.tabs[] | select(.tab_id == $t)' "$state" >/dev/null \
    || fail "the seeded default tab was closed despite its pane reporting a working agent (defense-in-depth failed)"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f'"$seeded_pane" \
    "create_task must refuse to close a seeded default tab whose pane hosts a working agent"
  pass "fm_backend_herdr_workspace_prune_seeded_default_tab: refuses to close the seeded default tab when its pane reports a working agent (defense in depth)"
}

# --- native event push: normalize / policy-routing / dedupe / wait ----------
#
# These exercise the herdr subscriber (fm_backend_herdr_wait_transition and its
# helpers) with a FAKE socket reader and fake herdr CLI, so the policy routing,
# per-pane dedupe marker, reconnect level-reconcile, and fail-closed return
# codes are asserted without a real herdr server. The isolated real-herdr smoke
# that drives a live idle->blocked transition lives in
# tests/fm-backend-herdr-eventwait-smoke.test.sh.

# make_herdr_eventfake: a herdr stub answering exactly the calls the event path
# makes - `session list --json` (echoes one session, name FM_FAKE_SESSION_NAME,
# socket FM_FAKE_SOCKET), `status --json`, and `agent get <pane>` (per-pane
# status read from $FM_FAKE_AGENT_DIR/<key>.status, else agent_not_found).
make_herdr_eventfake() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:-/dev/null}"
{ printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"
cmd=${1:-}; sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.3","protocol":16},"server":{"running":true}}\n' ;;
  "session list")
    printf '{"sessions":[{"name":"%s","running":true,"default":false,"socket_path":"%s"}]}\n' \
      "${FM_FAKE_SESSION_NAME:-default}" "${FM_FAKE_SOCKET:-/tmp/fm-fake.sock}" ;;
  "agent get")
    if [ -n "${FM_FAKE_READER_READY_FILE:-}" ] && [ ! -e "$FM_FAKE_READER_READY_FILE" ]; then
      exit 9
    fi
    pane=${3:-}
    key=$(printf '%s' "$pane" | tr ':/.' '___')
    f="${FM_FAKE_AGENT_DIR:-/tmp}/$key.status"
    if [ -f "$f" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$(cat "$f")"
    else
      printf '{"error":{"code":"agent_not_found"}}\n' >&2
      exit 1
    fi ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# make_fake_reader: a stand-in for bin/backends/herdr-eventwait.py. It ignores
# the socket, streams the TAB-separated lines in $FM_FAKE_READER_LINES to stdout
# (one projected event per line: pane_id\tworkspace_id\tagent_status\tagent),
# then exits $FM_FAKE_READER_EXIT (default 0). A non-zero exit with no lines
# models a connect/subscribe failure.
make_fake_reader() {  # <dir> -> echoes reader path
  local dir=$1 path="$1/fake-reader.sh"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
# argv: <sock> <timeout> <pane...> - ignored; behavior is env-driven.
if [ -n "${FM_FAKE_READER_READY_FILE:-}" ]; then
  : > "$FM_FAKE_READER_READY_FILE"
fi
printf '%s\n' "${FM_FAKE_READER_ACK:-@subscribed}"
if [ -n "${FM_FAKE_READER_LINES:-}" ] && [ -f "$FM_FAKE_READER_LINES" ]; then
  cat "$FM_FAKE_READER_LINES"
fi
exit "${FM_FAKE_READER_EXIT:-0}"
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

set_fake_agent() {  # <agent-dir> <window-or-pane> <status>
  local dir=$1 target=$2 status=$3 key
  key=$(printf '%s' "$target" | tr ':/.' '___')
  mkdir -p "$dir"
  printf '%s' "$status" > "$dir/$key.status"
}

test_normalize_event_leaves_from_empty() {
  local rec
  rec=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_normalize_event wG:pQ wG blocked claude' "$ROOT")
  [ "$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_pane_id "$1"' "$ROOT" "$rec")" = "wG:pQ" ] \
    || fail "normalize_event pane_id wrong: $rec"
  [ "$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_from_status "$1"' "$ROOT" "$rec")" = "" ] \
    || fail "normalize_event should leave from_status empty (herdr carries no previous status): $rec"
  [ "$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_to_status "$1"' "$ROOT" "$rec")" = "blocked" ] \
    || fail "normalize_event to_status wrong: $rec"
  pass "fm_backend_herdr_normalize_event routes through the shared record with an empty from_status"
}

test_escalation_marker_keys_like_watcher() {
  local m
  m=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_escalation_marker /st default:wG:pQ' "$ROOT")
  [ "$m" = "/st/.herdr-escalated-default_wG_pQ" ] \
    || fail "escalation marker key must match the watcher's tr ':/.' '___' scheme, got '$m'"
  pass "fm_backend_herdr_escalation_marker keys the dedupe marker exactly like the watcher's .stale-<key>"
}

test_apply_transition_blocked_requires_commit_to_dedupe() {
  local dir state rec out rc marker
  dir="$TMP_ROOT/apply-blocked"; state="$dir/state"; mkdir -p "$state"
  rec=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" blocked claude' "$ROOT")
  marker="$state/.herdr-escalated-default_wG_pQ"
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"); rc=$?
  [ "$rc" = 0 ] || fail "a fresh blocked edge must return 0 (actionable), got $rc"
  case "$out" in *blocked*) : ;; *) fail "apply_transition should print the record on a fresh actionable edge, got '$out'" ;; esac
  [ ! -e "$marker" ] || fail "detecting a blocked edge must not commit its marker before durable handling"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_commit_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"
  [ -e "$marker" ] || fail "commit_transition must set the marker after the caller handles the edge"
  # Second identical blocked edge (marker present) must NOT re-fire.
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"); rc=$?
  [ "$rc" = 1 ] || fail "an already-marked blocked pane must return 1 (deduped), got $rc"
  [ -z "$out" ] || fail "an already-marked blocked pane must print nothing, got '$out'"
  pass "fm_backend_herdr_apply_transition: blocked dedupe starts only after explicit commit"
}

test_apply_transition_working_clears_marker() {
  local dir state blocked working marker rc
  dir="$TMP_ROOT/apply-working"; state="$dir/state"; mkdir -p "$state"
  marker="$state/.herdr-escalated-default_wG_pQ"
  blocked=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" blocked claude' "$ROOT")
  working=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" working claude' "$ROOT")
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_commit_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$blocked"
  [ -e "$marker" ] || fail "setup: committed blocked edge should have set the marker"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$working"; rc=$?
  [ "$rc" = 1 ] || fail "a working (absorb) edge must return 1 (no wake), got $rc"
  [ ! -e "$marker" ] || fail "a working edge must CLEAR the escalation marker so a later re-block re-fires"
  # A re-block after the clear must fire again.
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$blocked" >/dev/null; rc=$?
  [ "$rc" = 0 ] || fail "a re-block after a working clear must re-fire (return 0), got $rc"
  pass "fm_backend_herdr_apply_transition: a working edge clears the marker so the next ->blocked re-escalates"
}

test_clear_transition_removes_task_marker() {
  local dir state marker
  dir="$TMP_ROOT/clear-transition"; state="$dir/state"; mkdir -p "$state"
  marker="$state/.herdr-escalated-default_wG_pQ"
  : > "$marker"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_clear_transition "$1" "$2"' "$ROOT" "$state" default:wG:pQ
  [ ! -e "$marker" ] || fail "clear_transition must remove the marker owned by a torn-down pane"
  pass "fm_backend_herdr_clear_transition removes task-owned dedupe state"
}

test_apply_transition_defer_and_fallback_are_noops() {
  local dir state marker rc s
  dir="$TMP_ROOT/apply-defer"; state="$dir/state"; mkdir -p "$state"
  marker="$state/.herdr-escalated-default_wG_pQ"
  for s in idle "done" unknown ""; do
    local rec
    rec=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" "$1" claude' "$ROOT" "$s")
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"; rc=$?
    [ "$rc" = 1 ] || fail "defer/fallback status '$s' must return 1 (no fast action), got $rc"
    [ ! -e "$marker" ] || fail "defer/fallback status '$s' must not touch the escalation marker"
  done
  pass "fm_backend_herdr_apply_transition: idle/done (defer) and unknown/empty (fallback) take no fast action"
}

test_wait_transition_no_panes_returns_2() {
  local rc
  bash -c '. "$0/bin/backends/herdr.sh"; FM_BACKEND_HERDR_EVENTS_FORCE=1 fm_backend_herdr_wait_transition default 1 /tmp/st' "$ROOT"; rc=$?
  [ "$rc" = 2 ] || fail "wait_transition with no pane windows must return 2 (fall back to sleep), got $rc"
  pass "fm_backend_herdr_wait_transition: a home with no herdr panes falls back to polling (rc 2)"
}

test_wait_transition_not_capable_returns_2() {
  local dir state fb rc
  dir="$TMP_ROOT/wt-incapable"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_herdr_eventfake "$dir")
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=0 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 2 ] || fail "wait_transition must return 2 when events are below capability (fail closed to poll), got $rc"
  pass "fm_backend_herdr_wait_transition: below-capability protocol/schema falls back to polling (rc 2)"
}

test_wait_transition_reconcile_blocked_returns_record() {
  local dir state agent temp fb reader lines out rc marker
  dir="$TMP_ROOT/wt-reconcile"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" blocked
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  marker="$state/.herdr-escalated-sess_wG_pQ"
  out=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ' "$ROOT" "$state"); rc=$?
  [ "$rc" = 0 ] || fail "reconcile of an already-blocked pane must return 0, got $rc"
  case "$out" in *blocked*) : ;; *) fail "reconcile must print the blocked record, got '$out'" ;; esac
  [ ! -e "$marker" ] || fail "reconcile must not mark a blocked pane before the caller durably handles it"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "actionable reconciliation must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: reconnect level-reconcile returns an uncommitted blocked pane"
}

test_wait_transition_subscribes_before_reconcile() {
  local dir state agent fb reader lines ready rc
  dir="$TMP_ROOT/wt-subscribe-first"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; ready="$dir/subscribed"; : > "$lines"
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" FM_FAKE_READER_READY_FILE="$ready" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 1 ] || fail "subscription must be acknowledged before reconciliation begins, got $rc"
  pass "fm_backend_herdr_wait_transition: subscribes before reconnect level-reconcile"
}

test_wait_transition_reconcile_dedupes_when_marked() {
  local dir state agent fb rc
  dir="$TMP_ROOT/wt-reconcile-dedupe"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" blocked
  # Pre-mark: this blocked was already escalated.
  : > "$state/.herdr-escalated-sess_wG_pQ"
  # No stream events, reader exits 0 -> a clean timeout (rc 1), NOT a re-fire.
  local reader lines
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 1 ] || fail "an already-marked blocked pane must not re-fire on reconcile (expect clean timeout rc 1), got $rc"
  pass "fm_backend_herdr_wait_transition: a still-blocked, already-escalated pane is not re-delivered on reconnect"
}

test_wait_transition_stream_blocked_returns_record() {
  local dir state agent fb reader lines out rc marker
  dir="$TMP_ROOT/wt-stream-blocked"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle   # reconcile sees idle -> proceeds to stream
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"
  printf 'wG:pQ\t\tblocked\tclaude\n' > "$lines"
  marker="$state/.herdr-escalated-sess_wG_pQ"
  out=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 2 "$1" sess:wG:pQ' "$ROOT" "$state"); rc=$?
  [ "$rc" = 0 ] || fail "a streamed blocked edge must return 0, got $rc"
  case "$out" in *blocked*) : ;; *) fail "a streamed blocked edge must print the record, got '$out'" ;; esac
  [ ! -e "$marker" ] || fail "a streamed blocked edge must remain uncommitted until durable handling"
  pass "fm_backend_herdr_wait_transition: a streamed ->blocked edge returns the record sub-poll"
}

test_wait_transition_stream_absorb_clears_then_timeout() {
  local dir state agent fb reader lines rc marker
  dir="$TMP_ROOT/wt-stream-absorb"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  : > "$state/.herdr-escalated-sess_wG_pQ"   # previously escalated
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"
  marker="$state/.herdr-escalated-sess_wG_pQ"
  # Stream a working edge (absorb) then an idle edge (defer). Neither is a fresh
  # actionable edge, so the wait ends as a clean timeout (rc 1) and the marker
  # is cleared by the working edge.
  printf 'wG:pQ\t\tworking\tclaude\nwG:pQ\t\tidle\tclaude\n' > "$lines"
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 2 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 1 ] || fail "a stream of only working/idle edges must end as a clean timeout (rc 1), got $rc"
  [ ! -e "$marker" ] || fail "a streamed working edge must clear the escalation marker"
  pass "fm_backend_herdr_wait_transition: streamed working clears the marker, idle/done are deferred (clean timeout)"
}

test_wait_transition_reader_failure_returns_2() {
  local dir state agent temp fb reader lines rc
  dir="$TMP_ROOT/wt-reader-fail"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  rc=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" FM_FAKE_READER_EXIT=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 2 ] || fail "a reader connect/subscribe failure must return 2 (fall back to poll), got $rc"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "reader failure must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: a reader/subscribe failure falls back to polling (rc 2)"
}

test_wait_transition_bad_ack_returns_2_and_cleans_up() {
  local dir state agent temp fb reader lines result rc fd_open
  dir="$TMP_ROOT/wt-bad-ack"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  result=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" FM_FAKE_READER_ACK=invalid \
    /bin/bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; rc=$?; [ -e /dev/fd/9 ] && fd_open=yes || fd_open=no; printf "%s %s\n" "$rc" "$fd_open"' "$ROOT" "$state")
  rc=${result%% *}; fd_open=${result#* }
  [ "$rc" = 2 ] || fail "an invalid subscription acknowledgement must return 2, got $rc"
  [ "$fd_open" = no ] || fail "an invalid subscription acknowledgement must close fixed fd 9"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "an invalid subscription acknowledgement must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: Bash 3.2-safe bad-ack path closes fd 9 and removes its FIFO"
}

test_wait_transition_clean_timeout_returns_1() {
  local dir state agent temp fb reader lines result rc fd_open
  dir="$TMP_ROOT/wt-timeout"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"   # no events, reader exits 0
  result=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    /bin/bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; rc=$?; [ -e /dev/fd/9 ] && fd_open=yes || fd_open=no; printf "%s %s\n" "$rc" "$fd_open"' "$ROOT" "$state")
  rc=${result%% *}; fd_open=${result#* }
  [ "$rc" = 1 ] || fail "a clean full-budget wait with no actionable edge must return 1, got $rc"
  [ "$fd_open" = no ] || fail "a clean timeout must close fixed fd 9"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "a clean timeout must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: stock macOS Bash clean timeout closes fd 9 and returns 1"
}

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# fm_backend_herdr_canonical_socket_path folds a Windows drive-letter spelling
# into the POSIX spelling of the same socket, so the launcher's claimed socket
# and the session list's socket_path compare equal on native Windows. `cygpath`
# ships only with Git for Windows, so these cases stub it and therefore run
# everywhere; the guard in the adapter matches only `[A-Za-z]:[\/]*`, a shape
# that cannot occur on Linux or macOS.
# make_cygpath_fakebin <dir> <map|fail|empty> [mapped-path] -> echoes fakebin dir
make_cygpath_fakebin() {
  local dir=$1 mode=$2 mapped=${3-} fb="$1/cygpath-fakebin"
  mkdir -p "$fb"
  case "$mode" in
    map)   printf '#!/usr/bin/env bash\nprintf %%s %s\n' "$(printf '%q' "$mapped")" > "$fb/cygpath" ;;
    fail)  printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/cygpath" ;;
    empty) printf '#!/usr/bin/env bash\nprintf ""\n' > "$fb/cygpath" ;;
  esac
  chmod +x "$fb/cygpath"
  printf '%s' "$fb"
}

canonical_socket_path_via() {  # <fakebin-dir-or-empty> <path> -> stdout, status
  local fb=$1 path=$2
  if [ -n "$fb" ]; then
    PATH="$fb:$PATH" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_canonical_socket_path "$1"' "$ROOT" "$path"
  else
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_canonical_socket_path "$1"' "$ROOT" "$path"
  fi
}

test_canonical_socket_path_folds_a_windows_drive_letter_spelling() {
  local dir sock fb posix_id win_id
  dir="$TMP_ROOT/cygpath-map"; mkdir -p "$dir"
  sock="$dir/herdr.sock"; : > "$sock"
  fb=$(make_cygpath_fakebin "$dir" map "$sock")
  posix_id=$(canonical_socket_path_via '' "$sock")
  [ -n "$posix_id" ] || fail "the POSIX spelling must canonicalize to a non-empty identity"
  win_id=$(canonical_socket_path_via "$fb" 'C:\fake\herdr.sock')
  [ "$win_id" = "$posix_id" ] || \
    fail "a drive-letter spelling must normalize to the same identity as its POSIX spelling (got '$win_id', want '$posix_id')"
}

test_canonical_socket_path_refuses_a_failed_cygpath() {
  local dir fb status
  dir="$TMP_ROOT/cygpath-fail"; mkdir -p "$dir"
  fb=$(make_cygpath_fakebin "$dir" fail)
  status=0
  canonical_socket_path_via "$fb" 'C:\fake\herdr.sock' >/dev/null || status=$?
  expect_code 1 "$status" "a drive-letter path whose cygpath conversion fails must be refused, not compared half-converted"
}

test_canonical_socket_path_refuses_empty_cygpath_output() {
  local dir fb status
  dir="$TMP_ROOT/cygpath-empty"; mkdir -p "$dir"
  fb=$(make_cygpath_fakebin "$dir" empty)
  status=0
  canonical_socket_path_via "$fb" 'C:\fake\herdr.sock' >/dev/null || status=$?
  expect_code 1 "$status" "a drive-letter path whose cygpath output is empty must be refused"
}
