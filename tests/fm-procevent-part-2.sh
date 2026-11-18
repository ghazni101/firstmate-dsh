# shellcheck shell=bash
# Part 2 of tests/fm-procevent.test.sh, split so no single ShellCheck root
# carries the whole suite. This file is sourced, in order, by that
# runner: it is executable test code, not a definition-only module, and
# it shares the runner's shell state and counters.
# shellcheck disable=SC2034,SC2153,SC2154,SC2329 # state is shared across the sourced parts

# --- end-user-aligned regression: an interrupted conclude ends the board -----
# The conclude drops the registration and then records the acknowledgement. An
# interruption between those steps must leave nothing that relaunches the ended
# board, and the same acknowledgement has to finish the job on the next try.
HINTR="$TMP_ROOT/hinterrupted"; new_home "$HINTR"
INTR_ROOT="$TMP_ROOT/lavish-interrupted-root"; mkdir -p "$INTR_ROOT"; export INTR_ROOT
INTR_BIN=$(fm_fakebin "$TMP_ROOT/lavish-interrupted-stub")
cat > "$INTR_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
n=$(cat "$INTR_ROOT/count" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$INTR_ROOT/count"
printf 'session:\n  status: ended\n  session_ended: true\n'
SH
chmod +x "$INTR_BIN/lavish-axi"
INTR_ART="$TMP_ROOT/interrupted-board.html"
printf '<h1>interrupted</h1>\n' > "$INTR_ART"
lavish_session "$INTR_ART"
intr_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$INTR_ART")
fm_test_track_procevent_home "$HINTR"
new_task_endpoint "$HINTR" worker-12
PATH="$INTR_BIN:$PATH" FM_HOME="$HINTR" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$INTR_ART" --for worker-12 >/dev/null
wait_capture "$HINTR" "$intr_id" \
  || fail "the terminal worker-owned round was never captured"
[ "$(cat "$INTR_ROOT/count" 2>/dev/null || echo 0)" = 1 ] \
  || fail "the terminal worker-owned round was not polled exactly once"
rm -f "$HINTR/state/procevent/$intr_id.source"
PATH="$INTR_BIN:$PATH" pe "$HINTR" reconcile >/dev/null 2>&1 || true
[ "$(cat "$INTR_ROOT/count" 2>/dev/null || echo 0)" = 1 ] \
  || fail "an interrupted conclude let the ended board be polled again"
if PATH="$INTR_BIN:$PATH" FM_HOME="$HINTR" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$INTR_ART" --for worker-12 \
  >/dev/null 2>"$INTR_ROOT/intr-arm.err"; then
  fail "an interrupted conclude let its owner re-arm the ended board"
fi
assert_contains "$(cat "$INTR_ROOT/intr-arm.err")" "terminal" \
  "the refusal did not say the round still owed a conclude is terminal"
intr_out=$(PATH="$INTR_BIN:$PATH" pe "$HINTR" handled "$intr_id" 1)
assert_contains "$intr_out" "handled: $intr_id 1" \
  "repeating the interrupted acknowledgement did not record it"
[ -f "$HINTR/state/procevent-inbox/$intr_id.1.handled" ] \
  || fail "the interrupted conclude was never finished by the repeated acknowledgement"
pass "an interrupted conclude leaves the ended board unpollable and finishes on retry"

# --- end-user-aligned regression: a failed re-arm keeps the last generation ---
# Re-arm publishes the next generation and acknowledges the round it replaces.
# When that acknowledgement cannot be recorded the whole re-arm has to be off,
# leaving the generation the board is actually running untouched.
HROLL="$TMP_ROOT/hrollback"; new_home "$HROLL"
ROLL_ROOT="$TMP_ROOT/lavish-rollback-root"; mkdir -p "$ROLL_ROOT"; export ROLL_ROOT
ROLL_BIN=$(fm_fakebin "$TMP_ROOT/lavish-rollback-stub")
cat > "$ROLL_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1-}" != --version ] || { printf '0.1.79\n'; exit 0; }
[ "${3-}" != --agent-reply ] || printf '%s\n' "$4" >> "$ROLL_ROOT/replies"
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","another round","","message",""\n'
SH
chmod +x "$ROLL_BIN/lavish-axi"
ROLL_ART="$TMP_ROOT/rollback-board.html"
printf '<h1>rollback</h1>\n' > "$ROLL_ART"
lavish_session "$ROLL_ART"
roll_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ROLL_ART")
fm_test_track_procevent_home "$HROLL"
new_task_endpoint "$HROLL" worker-8
printf 'reply from generation one\n' > "$ROLL_ROOT/reply1"
printf 'reply from generation two\n' > "$ROLL_ROOT/reply2"
PATH="$ROLL_BIN:$PATH" FM_HOME="$HROLL" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ROLL_ART" --for worker-8 \
  --agent-reply-file "$ROLL_ROOT/reply1" >/dev/null
wait_for "$ROLL_ROOT/replies" \
  || fail "the first generation's reply never reached the board"
[ "$(grep -c 'generation one' "$ROLL_ROOT/replies" 2>/dev/null || true)" = 1 ] \
  || fail "the first generation's reply never reached the board"
# The reply is posted before the round is captured. Making the inbox read-only
# before the runner commits and exits would fail that capture instead of the
# re-arm's acknowledgement, leaving no round for the retried re-arm.
wait_capture "$HROLL" "$roll_id" \
  || fail "the first generation's round was never captured"
cp "$HROLL/state/procevent/$roll_id.source" "$ROLL_ROOT/generation-one.source"
chmod 0500 "$HROLL/state/procevent-inbox"
rollback_status=0
PATH="$ROLL_BIN:$PATH" FM_HOME="$HROLL" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ROLL_ART" --for worker-8 \
  --agent-reply-file "$ROLL_ROOT/reply2" >/dev/null 2>&1 || rollback_status=$?
chmod 0700 "$HROLL/state/procevent-inbox"
[ "$rollback_status" -ne 0 ] \
  || fail "a re-arm that could not acknowledge its round still reported success"
cmp -s "$ROLL_ROOT/generation-one.source" "$HROLL/state/procevent/$roll_id.source" \
  || fail "a failed re-arm replaced the generation the board is still running"
[ ! -f "$HROLL/state/procevent-inbox/$roll_id.1.handled" ] \
  || fail "a failed re-arm still acknowledged the round it could not close"
PATH="$ROLL_BIN:$PATH" FM_HOME="$HROLL" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ROLL_ART" --for worker-8 \
  --agent-reply-file "$ROLL_ROOT/reply2" >/dev/null
wait_for_lines "$ROLL_ROOT/replies" 2 \
  || fail "the retried re-arm did not hand the board its generation's reply exactly once"
[ "$(grep -c 'generation two' "$ROLL_ROOT/replies" 2>/dev/null || true)" = 1 ] \
  || fail "the retried re-arm did not hand the board its generation's reply exactly once"
pass "a re-arm that cannot acknowledge its round leaves the running generation alone"

# --- end-user-aligned regression: re-arm is acknowledgement, nothing else -----
# The board is armed once and re-armed only to acknowledge a captured round. A
# worker that re-arms while its listener is still waiting would replace the
# generation carrying the reply it already handed over, and that reply would be
# swept away without ever reaching the board.
HREARM="$TMP_ROOT/hrearm"; new_home "$HREARM"
REARM_ROOT="$TMP_ROOT/lavish-rearm-root"; mkdir -p "$REARM_ROOT"; export REARM_ROOT
REARM_BIN=$(fm_fakebin "$TMP_ROOT/lavish-rearm-stub")
cat > "$REARM_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1-}" != --version ] || { printf '0.1.79\n'; exit 0; }
[ "${3-}" != --agent-reply ] || printf '%s\n' "$4" >> "$REARM_ROOT/replies"
while [ ! -e "$REARM_ROOT/release" ]; do sleep 0.02; done
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","one more round","","message",""\n'
SH
chmod +x "$REARM_BIN/lavish-axi"
REARM_ART="$TMP_ROOT/rearm-board.html"
printf '<h1>rearm</h1>\n' > "$REARM_ART"
lavish_session "$REARM_ART"
rearm_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$REARM_ART")
fm_test_track_procevent_home "$HREARM"
new_task_endpoint "$HREARM" worker-11
printf 'first generation reply\n' > "$REARM_ROOT/reply1"
printf 'second generation reply\n' > "$REARM_ROOT/reply2"
PATH="$REARM_BIN:$PATH" FM_HOME="$HREARM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REARM_ART" --for worker-11 \
  --agent-reply-file "$REARM_ROOT/reply1" >/dev/null
[ -e "$HREARM/state/procevent/$rearm_id.source" ] \
  || fail "the initial arm of a worker-owned board did not register it"
if PATH="$REARM_BIN:$PATH" FM_HOME="$HREARM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REARM_ART" --for worker-11 \
  --agent-reply-file "$REARM_ROOT/reply2" >/dev/null 2>"$REARM_ROOT/idle-rearm.err"; then
  fail "a worker re-armed its own board with no captured round to acknowledge"
fi
assert_contains "$(cat "$REARM_ROOT/idle-rearm.err")" "worker-11" \
  "the refused idle re-arm did not name the task that already holds the board"
touch "$REARM_ROOT/release"
PATH="$REARM_BIN:$PATH" pe "$HREARM" start "$rearm_id" >/dev/null 2>&1 || true
wait_for "$REARM_ROOT/replies" || fail "the listener never posted the reply it was armed with"
wait_for "$HREARM/state/procevent-inbox/$rearm_id.1.result" \
  || fail "the first worker-owned round never landed"
[ "$(grep -c 'first generation reply' "$REARM_ROOT/replies" 2>/dev/null || true)" = 1 ] \
  || fail "the refused idle re-arm cost the board the reply its listener was already carrying"
[ -f "$HREARM/state/procevent-inbox/$rearm_id.1.result" ] \
  || fail "the first worker-owned round never landed"
if PATH="$REARM_BIN:$PATH" FM_HOME="$HREARM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REARM_ART" --for worker-11 \
  --agent-reply-file "$REARM_ROOT/never-written" >/dev/null 2>&1; then
  fail "a re-arm carrying a nonexistent reply path was accepted"
fi
[ ! -f "$HREARM/state/procevent-inbox/$rearm_id.1.handled" ] \
  || fail "a re-arm refused over its reply path still acknowledged the open round"
PATH="$REARM_BIN:$PATH" FM_HOME="$HREARM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REARM_ART" --for worker-11 \
  --agent-reply-file "$REARM_ROOT/reply2" >/dev/null
[ -f "$HREARM/state/procevent-inbox/$rearm_id.1.handled" ] \
  || fail "re-arming over an open round did not acknowledge that round"
wait_for_lines "$REARM_ROOT/replies" 2 \
  || fail "the acknowledging re-arm did not hand the board its own generation's reply"
[ "$(grep -c 'second generation reply' "$REARM_ROOT/replies" 2>/dev/null || true)" = 1 ] \
  || fail "the acknowledging re-arm did not hand the board its own generation's reply"
pass "a worker-owned board is armed once and re-armed only to acknowledge an open round"

# The other half of the same contract, on the same real path: a close that
# carries what the captain actually said must still reach him. Same runner, same
# adapter, one different response shape.
HANSWER="$TMP_ROOT/hanswer"; new_home "$HANSWER"
ANSWER_BIN=$(fm_fakebin "$TMP_ROOT/lavish-answer-stub")
cat > "$ANSWER_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` on a real `Send & End`: the captain's
# own choice, delivered with session_ended.
printf 'session:\n  file: /answered.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nprompts[1]{tag,text,prompt}:\n  "choice","Option B","Context data: {\\"question\\":\\"noop-check-routing\\",\\"answer\\":\\"b\\"}"\n'
SH
chmod +x "$ANSWER_BIN/lavish-axi"
ANSWER_ART="$TMP_ROOT/answered-board.html"
printf '<h1>answered</h1>\n' > "$ANSWER_ART"
lavish_session "$ANSWER_ART"
answer_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ANSWER_ART")
fm_test_track_procevent_home "$HANSWER"
PATH="$ANSWER_BIN:$PATH" FM_HOME="$HANSWER" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ANSWER_ART" >/dev/null
PATH="$ANSWER_BIN:$PATH" pe "$HANSWER" reconcile >/dev/null
wait_for "$HANSWER/state/.wake-queue" \
  || fail "a board close carrying the captain's real answer produced no wake"
assert_contains "$(wake_payloads "$HANSWER")" "procevent lavish $answer_id 1" \
  "a real board answer still reaches the captain"
[ ! -f "$HANSWER/state/procevent-inbox/$answer_id.1.handled" ] \
  || fail "a real board answer was recorded handled without ever being handled"
pass "a board close carrying the captain's real answer is still announced"

# --- end-user-aligned regression: a transient poll interruption is not news ---
# The dogfood defect: a live board listener can answer with exactly
#     error: Lavish Editor poll response was interrupted
#     code: SERVER_ERROR
# while the board's marks remain available. Firstmate registered raw poll output,
# so the generic runner captured that transient response and woke the whole fleet
# over what is really an internal retry. Every scenario below runs through the
# adapter's own arm command and the real runner, so registration, capture, and
# publication are exercised for real.
LAVISH_SCRIPTED_BIN=$(fm_fakebin "$TMP_ROOT/lavish-scripted-stub")
cat > "$LAVISH_SCRIPTED_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>`, scripted per scenario: LAVISH_SCRIPT
# names the response for each successive poll, one word per poll, and its last
# word repeats forever. `interrupt` is the exact transient response the server
# returns while the board's marks stay available.
[ "${1-}" != --version ] || { printf '0.1.79\n'; exit 0; }
n=$(cat "$LAVISH_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$LAVISH_COUNT"
for arg in "$@"; do
  case "$arg" in
    --agent-reply) ;;
    --*)
      printf 'error: unknown option %s\ncode: VALIDATION_ERROR\n' "$arg" >&2
      exit 2
      ;;
  esac
done
if [ -n "${LAVISH_REPLY_LOG-}" ] && [ "${1-}" = poll ] && [ "${3-}" = --agent-reply ]; then
  printf '%s\n' "$4" >> "$LAVISH_REPLY_LOG"
fi
read -r -a plan <<< "$LAVISH_SCRIPT"
i=$((n - 1))
[ "$i" -ge "${#plan[@]}" ] && i=$((${#plan[@]} - 1))
case "${plan[$i]}" in
  interrupt)
    printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n'; exit 1 ;;
  near-interrupt)
    printf 'error: Lavish Editor poll response was interrupted \ncode: SERVER_ERROR\n'; exit 1 ;;
  other-server-error)
    printf 'error: Lavish Editor session store is unavailable\ncode: SERVER_ERROR\n'; exit 1 ;;
  feedback)
    printf 'session:\n  file: /board.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' ;;
  stream)
    printf 'x%.0s' {1..4096}
    printf 'ready\n' > "$LAVISH_STREAM_READY"
    while [ ! -e "$LAVISH_STREAM_RELEASE" ]; do sleep 0.05; done
    printf '\n' ;;
esac
SH
chmod +x "$LAVISH_SCRIPTED_BIN/lavish-axi"
export LAVISH_COUNT LAVISH_SCRIPT

DEFAULT_RATE_ART="$TMP_ROOT/default-rate-board.html"
printf '<h1>default rate</h1>\n' > "$DEFAULT_RATE_ART"
lavish_session "$DEFAULT_RATE_ART"
DEFAULT_RATE_COUNT="$TMP_ROOT/default-rate-count"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" LAVISH_COUNT="$DEFAULT_RATE_COUNT" LAVISH_SCRIPT=interrupt \
  FM_LAVISH_POLL_RETRY_DELAY='' \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$DEFAULT_RATE_ART" >/dev/null 2>&1 &
DEFAULT_RATE_PID=$!
perl -MTime::HiRes=sleep -e 'sleep 6.2'
kill -TERM "$DEFAULT_RATE_PID" 2>/dev/null || true
wait "$DEFAULT_RATE_PID" 2>/dev/null || true
default_rate_count=$(cat "$DEFAULT_RATE_COUNT" 2>/dev/null || echo 0)
[ "$default_rate_count" -ge 2 ] \
  || fail "the default poll governor stopped an instantly returning source from making progress"
[ "$default_rate_count" -le 2 ] \
  || fail "the shipped poll governor allowed $default_rate_count iterations in 6.2 seconds"
pass "the shipped poll governor bounds an instantly returning source"

# A bounded test override keeps the retry policy's real bound under test without
# making the suite wait out the production delay.
export FM_LAVISH_POLL_RETRY_DELAY=1

# Two interruptions, then the captain's real feedback: the retries are silent and
# only the feedback becomes a captured result and a check wake.
HRETRY="$TMP_ROOT/hretry"; new_home "$HRETRY"
RETRY_ART="$TMP_ROOT/retry-board.html"
printf '<h1>retry</h1>\n' > "$RETRY_ART"
lavish_session "$RETRY_ART"
retry_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$RETRY_ART")
fm_test_track_procevent_home "$HRETRY"
LAVISH_COUNT="$TMP_ROOT/retry-count"; LAVISH_SCRIPT="interrupt interrupt feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HRETRY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$RETRY_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe "$HRETRY" reconcile >/dev/null
wait_for "$HRETRY/state/.wake-queue" || fail "feedback after interrupted polls produced no wake"
[ "$(cat "$LAVISH_COUNT")" = 3 ] \
  || fail "the interrupted listener was polled $(cat "$LAVISH_COUNT") times, not the two quiet retries plus the delivering poll"
[ "$(count_results "$HRETRY" "$retry_id")" = 1 ] \
  || fail "a retried interruption produced $(count_results "$HRETRY" "$retry_id") captured results instead of one"
[ "$(wake_payloads "$HRETRY" | sort -u | grep -c .)" = 1 ] \
  || fail "a retried interruption woke the fleet: $(wake_payloads "$HRETRY" | sort -u)"
assert_contains "$(wake_payloads "$HRETRY")" "procevent lavish $retry_id 1" \
  "feedback arriving after quiet retries is captured and announced"
assert_grep 'ship it' "$(first_result "$HRETRY" "$retry_id")" \
  "the announced result is the captain's feedback, not the interruption"
pass "a transient Lavish poll interruption is retried quietly and never announced"

# --- end-user-aligned regression: a retried poll does not resubmit the reply ---
# The worker hands its round reply to the adapter once. When the first poll of
# that round comes back as the transient interruption, the adapter's own quiet
# retries must keep polling WITHOUT the reply, or the board receives the same
# worker message once per retry.
HREPLY="$TMP_ROOT/hreply"; new_home "$HREPLY"
REPLY_ART="$TMP_ROOT/reply-retry-board.html"
printf '<h1>reply retry</h1>\n' > "$REPLY_ART"
lavish_session "$REPLY_ART"
fm_test_track_procevent_home "$HREPLY"
new_task_endpoint "$HREPLY" worker-9
printf 'applied round one\n' > "$TMP_ROOT/reply-retry.txt"
LAVISH_REPLY_LOG="$TMP_ROOT/reply-retry-log"; export LAVISH_REPLY_LOG
LAVISH_COUNT="$TMP_ROOT/reply-retry-count"; LAVISH_SCRIPT="interrupt interrupt feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HREPLY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REPLY_ART" --for worker-9 \
  --agent-reply-file "$TMP_ROOT/reply-retry.txt" >/dev/null
wait_for "$HREPLY/state/worker-9.inbox/001.msg" 200 \
  || fail "the round that delivered after quiet retries did not reach the worker inbox"
[ "$(cat "$LAVISH_COUNT")" = 3 ] \
  || fail "the reply-carrying listener was polled $(cat "$LAVISH_COUNT") times, not the two quiet retries plus the delivering poll"
[ "$(grep -c 'applied round one' "$LAVISH_REPLY_LOG" 2>/dev/null || true)" = 1 ] \
  || fail "the staged worker reply reached the board $(grep -c 'applied round one' "$LAVISH_REPLY_LOG" 2>/dev/null || true) times across the adapter's internal retries"
[ -f "$HREPLY/state/worker-9.inbox/001.msg" ] \
  || fail "the round that delivered after quiet retries did not reach the worker inbox"
unset LAVISH_REPLY_LOG
pass "a staged worker reply is handed to the board once across quiet poll retries"

# The other side of the same best-effort contract: posting a reply is allowed to
# lose it, so a listener that starts with no staged reply - because a crash
# consumed it, or because the round simply carries none - must still poll the
# board, with no reply and no refusal.
MISSING_REPLY_COUNT="$TMP_ROOT/missing-reply-count"
MISSING_REPLY_LOG="$TMP_ROOT/missing-reply-log"
missing_reply_status=0
PATH="$LAVISH_SCRIPTED_BIN:$PATH" LAVISH_COUNT="$MISSING_REPLY_COUNT" LAVISH_SCRIPT=feedback \
  LAVISH_REPLY_LOG="$MISSING_REPLY_LOG" \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" \
  --agent-reply-file "$TMP_ROOT/never-staged-reply" >/dev/null 2>&1 || missing_reply_status=$?
[ "$missing_reply_status" -eq 0 ] \
  || fail "a listener whose staged reply was gone refused to poll (status $missing_reply_status)"
[ "$(cat "$MISSING_REPLY_COUNT" 2>/dev/null || echo 0)" = 1 ] \
  || fail "a listener whose staged reply was gone never polled the board"
[ ! -s "$MISSING_REPLY_LOG" ] \
  || fail "a listener whose staged reply was gone still posted something: $(cat "$MISSING_REPLY_LOG")"
pass "a listener whose staged reply is gone polls the board without one"

# The accepted loss window is consuming-to-calling and nothing wider: a listener
# that never reaches the board at all must leave the staged reply for the next
# one. A malformed retry-delay override is one of the ordinary setup refusals
# that used to happen after the reply had already been consumed.
SETUP_GUARD_REPLY="$TMP_ROOT/setup-guard-reply"
SETUP_GUARD_COUNT="$TMP_ROOT/setup-guard-count"
printf 'kept for the next listener\n' > "$SETUP_GUARD_REPLY"
setup_guard_status=0
PATH="$LAVISH_SCRIPTED_BIN:$PATH" LAVISH_COUNT="$SETUP_GUARD_COUNT" LAVISH_SCRIPT=feedback \
  FM_LAVISH_POLL_RETRY_DELAY=not-a-number \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" \
  --agent-reply-file "$SETUP_GUARD_REPLY" >/dev/null 2>&1 || setup_guard_status=$?
[ "$setup_guard_status" -ne 0 ] \
  || fail "a malformed retry delay did not stop the listener before it polled"
[ "$(cat "$SETUP_GUARD_COUNT" 2>/dev/null || echo 0)" = 0 ] \
  || fail "a listener that refused its setup still reached the board"
[ -f "$SETUP_GUARD_REPLY" ] \
  || fail "a listener that never reached the board consumed its staged reply anyway"
pass "a listener that refuses its own setup leaves the staged reply for the next one"

# The board itself is part of that setup: an artifact that vanished between the
# re-arm and the listener's launch cannot be polled at all, so the reply it was
# carrying has to survive for the listener that polls the next one.
GONE_ART="$TMP_ROOT/artifact-gone-board.html"
GONE_REPLY="$TMP_ROOT/artifact-gone-reply"
GONE_COUNT="$TMP_ROOT/artifact-gone-count"
printf '<h1>gone</h1>\n' > "$GONE_ART"
lavish_session "$GONE_ART"
printf 'owed to the next listener\n' > "$GONE_REPLY"
rm -f "$GONE_ART"
gone_status=0
PATH="$LAVISH_SCRIPTED_BIN:$PATH" LAVISH_COUNT="$GONE_COUNT" LAVISH_SCRIPT=feedback \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$GONE_ART" \
  --agent-reply-file "$GONE_REPLY" >/dev/null 2>&1 || gone_status=$?
[ "$gone_status" -ne 0 ] \
  || fail "a listener whose artifact vanished reported a successful poll"
[ "$(cat "$GONE_COUNT" 2>/dev/null || echo 0)" = 0 ] \
  || fail "a listener whose artifact vanished still reached the board"
[ -f "$GONE_REPLY" ] \
  || fail "a listener whose artifact vanished consumed its staged reply anyway"
pass "a listener whose artifact vanished leaves the staged reply for the next one"

# Exhaustion is news: after the bounded retries the same exact response is
# captured and announced normally rather than being swallowed forever.
HEXH="$TMP_ROOT/hexh"; new_home "$HEXH"
EXH_ART="$TMP_ROOT/exhaust-board.html"
printf '<h1>exhaust</h1>\n' > "$EXH_ART"
lavish_session "$EXH_ART"
exh_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$EXH_ART")
fm_test_track_procevent_home "$HEXH"
LAVISH_COUNT="$TMP_ROOT/exhaust-count"; LAVISH_SCRIPT="interrupt"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HEXH" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$EXH_ART" >/dev/null
wait_capture "$HEXH" "$exh_id" 200 \
  || fail "exhaustion produced no captured result"
[ "$(cat "$LAVISH_COUNT")" = 13 ] \
  || fail "the retry bound polled $(cat "$LAVISH_COUNT") times, not the first poll plus 12 bounded retries"
[ "$(count_results "$HEXH" "$exh_id")" = 1 ] \
  || fail "exhaustion produced $(count_results "$HEXH" "$exh_id") captured results instead of one"
wait_for "$HEXH/state/.wake-queue" \
  || fail "the interruption that survives the bound produced no wake"
assert_contains "$(wake_payloads "$HEXH")" "procevent lavish $exh_id 1" \
  "the interruption that survives the bound is announced normally"
assert_grep 'poll response was interrupted' "$(first_result "$HEXH" "$exh_id")" \
  "the announced result is the exact interruption the server returned"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HEXH" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$EXH_ART" >/dev/null
pass "an interruption that outlives the bounded retries is captured and announced"

# A different SERVER_ERROR is a genuine error, never a retry: no fail-open drift
# from the one exact transient response this adapter owns.
HOTHER="$TMP_ROOT/hother"; new_home "$HOTHER"
OTHER_ART="$TMP_ROOT/other-board.html"
printf '<h1>other</h1>\n' > "$OTHER_ART"
lavish_session "$OTHER_ART"
other_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$OTHER_ART")
fm_test_track_procevent_home "$HOTHER"
LAVISH_COUNT="$TMP_ROOT/other-count"; LAVISH_SCRIPT="other-server-error"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HOTHER" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$OTHER_ART" >/dev/null
wait_for "$HOTHER/state/.wake-queue" \
  || fail "an unrelated SERVER_ERROR is captured and announced immediately"
[ "$(cat "$LAVISH_COUNT")" = 1 ] \
  || fail "an unrelated SERVER_ERROR was retried $(cat "$LAVISH_COUNT") times instead of surfacing at once"
assert_contains "$(wake_payloads "$HOTHER")" "procevent lavish $other_id 1" \
  "an unrelated SERVER_ERROR is captured and announced immediately"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HOTHER" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$OTHER_ART" >/dev/null
pass "only the exact interruption is retried; an unrelated SERVER_ERROR still surfaces"
unset FM_LAVISH_POLL_RETRY_DELAY

# A whitespace variant is not the exact transient response and must surface on
# the first poll instead of drifting into the quiet retry policy.
HNEAR="$TMP_ROOT/hnear"; new_home "$HNEAR"
NEAR_ART="$TMP_ROOT/near-board.html"
printf '<h1>near</h1>\n' > "$NEAR_ART"
lavish_session "$NEAR_ART"
near_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$NEAR_ART")
fm_test_track_procevent_home "$HNEAR"
LAVISH_COUNT="$TMP_ROOT/near-count"; LAVISH_SCRIPT="near-interrupt feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HNEAR" FM_LAVISH_POLL_RETRY_DELAY=1 \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$NEAR_ART" >/dev/null
wait_for "$HNEAR/state/.wake-queue" \
  || fail "a whitespace variant of the interruption is captured and announced immediately"
[ "$(cat "$LAVISH_COUNT")" = 1 ] \
  || fail "a near-match interruption was retried instead of surfacing on its first poll"
assert_contains "$(wake_payloads "$HNEAR")" "procevent lavish $near_id 1" \
  "a whitespace variant of the interruption is captured and announced immediately"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HNEAR" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$NEAR_ART" >/dev/null
pass "only the literal two-line interruption enters the quiet retry policy"

# The public arm boundary refuses invalid retry intervals before it publishes a
# source registration, rather than arming a listener that can only fail later.
HINVALID="$TMP_ROOT/hinvalid"; new_home "$HINVALID"
INVALID_ART="$TMP_ROOT/invalid-delay-board.html"
printf '<h1>invalid delay</h1>\n' > "$INVALID_ART"
lavish_session "$INVALID_ART"
invalid_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$INVALID_ART")
for invalid_delay in 0 61 invalid; do
  invalid_status=0
  invalid_out=$(PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HINVALID" \
    FM_LAVISH_POLL_RETRY_DELAY="$invalid_delay" \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$INVALID_ART" 2>&1) || invalid_status=$?
  [ "$invalid_status" -ne 0 ] \
    || fail "arm accepted invalid retry delay: $invalid_delay"
  assert_contains "$invalid_out" "must be whole seconds from 1 to 60" \
    "arm explains the rejected retry delay"
  assert_absent "$HINVALID/state/procevent/$invalid_id.source" \
    "arm publishes no source registration for an invalid retry delay"
done
pass "arm rejects malformed and out-of-range retry delays before registration"

# Shell-safe cleanup must preserve a valid TMPDIR containing an apostrophe.
QUOTED_TMPDIR="$TMP_ROOT/poll's-stage"
mkdir -p "$QUOTED_TMPDIR"
LAVISH_COUNT="$TMP_ROOT/quoted-count"; LAVISH_SCRIPT="feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" TMPDIR="$QUOTED_TMPDIR" \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$NEAR_ART" >/dev/null
quoted_staged=("$QUOTED_TMPDIR"/fm-lavish-poll.*)
[ ! -e "${quoted_staged[0]}" ] \
  || fail "poll left its staged response behind in an apostrophe-containing TMPDIR"
pass "poll cleanup safely handles an apostrophe-containing TMPDIR"

HSTREAM="$TMP_ROOT/hstream"; new_home "$HSTREAM"
STREAM_ART="$TMP_ROOT/stream-board.html"
STREAM_TMPDIR="$TMP_ROOT/stream-stage"
LAVISH_STREAM_READY="$TMP_ROOT/stream-ready"
LAVISH_STREAM_RELEASE="$TMP_ROOT/stream-release"
mkdir -p "$STREAM_TMPDIR"
printf '<h1>stream</h1>\n' > "$STREAM_ART"
lavish_session "$STREAM_ART"
stream_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$STREAM_ART")
fm_test_track_procevent_home "$HSTREAM"
LAVISH_COUNT="$TMP_ROOT/stream-count"; LAVISH_SCRIPT="stream"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HSTREAM" TMPDIR="$STREAM_TMPDIR" \
  LAVISH_STREAM_READY="$LAVISH_STREAM_READY" LAVISH_STREAM_RELEASE="$LAVISH_STREAM_RELEASE" \
  FM_PROCEVENT_MAX_OUTPUT_BYTES=100 \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$STREAM_ART" >/dev/null
wait_for "$LAVISH_STREAM_READY" || fail "streaming poll did not start"
stream_staged=("$STREAM_TMPDIR"/fm-lavish-poll.*)
[ -e "${stream_staged[0]}" ] || fail "streaming poll created no classifier staging file"
[ "$(wc -c < "${stream_staged[0]}" | tr -d ' ')" -le 100 ] \
  || fail "streaming poll exceeded its bounded classifier staging"
: > "$LAVISH_STREAM_RELEASE"
wait_for "$HSTREAM/state/.wake-queue" || fail "streaming poll produced no wake"
stream_result=$(first_result "$HSTREAM" "$stream_id" || true)
[ "$(wc -c < "$stream_result" | tr -d ' ')" -le 100 ] \
  || fail "streaming poll bypassed the runner output bound"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HSTREAM" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$STREAM_ART" >/dev/null
pass "Lavish classification staging stays bounded while nonmatches stream"

# --- end-user-aligned regression: the exact drain-before-handling restart cut
# Reproduces the confirmed defect through the public interface end to end: a
# real blocking source completes, its result is captured and published, the
# wake is drained without any handling, a replacement session's reconcile must
# resurface the exact same source and sequence, and only the owned handling
# interface may retire it - safely and without ever authorizing a paired
# effect a second time.
HW="$TMP_ROOT/hw"; new_home "$HW"
TRIGW="$TMP_ROOT/trigger-restart-cut"
pe_register "$HW" lavish restart-cut-src -- "$BLOCKER" "$TRIGW" "restart cut payload" >/dev/null
pe "$HW" start restart-cut-src > "$TMP_ROOT/restart-cut-start.log" 2>&1 &
restart_cut_start_pid=$!
sleep 0.5
: > "$TRIGW"
wait_for "$HW/state/.wake-queue" || fail "the restart-cut source published no event"
assert_contains "$(wake_payloads "$HW")" "procevent lavish restart-cut-src 1" \
  "capture and publish reaches the wake queue before any handling"

# Retire the registration now that the source has completed and captured its
# one result. The fixture's trigger file persists on disk, so a still-armed
# registration would let every further reconcile call restart the blocker and
# capture a fresh generation; retiring leaves only the durable inbox and wake
# state under test, matching the exact restart cut - the source side is done,
# only the handling side is still open.
# Publication precedes runner exit; wait for completion before retiring.
wait "$restart_cut_start_pid" || fail "the restart-cut source did not complete"
pe "$HW" retire restart-cut-src >/dev/null \
  || fail "the restart-cut registration was not retired"

# Drain the wake without handling it: the end-user experience of a session
# reading the wake queue at turn end without yet acting on this specific line.
mv "$HW/state/.wake-queue" "$HW/state/.wake-queue.drained-unhandled"
[ -z "$(wake_payloads "$HW")" ] || fail "the wake queue was not actually drained"

# Simulate a replacement Firstmate session: reconcile runs cold, as it would on
# a fresh process with no memory of the prior turn.
out=$(pe "$HW" reconcile)
assert_contains "$out" "published=1" \
  "a replacement session's reconcile resurfaces a drained-but-unhandled result"
assert_contains "$(wake_payloads "$HW")" "procevent lavish restart-cut-src 1" \
  "the exact same captured source and sequence resurfaces, never a substitute"

# Acknowledge handling through the owned interface.
ack_out=$(pe "$HW" handled restart-cut-src 1)
assert_contains "$ack_out" "handled: restart-cut-src 1" \
  "the first acknowledgement newly authorizes the paired effect"

mv "$HW/state/.wake-queue" "$HW/state/.wake-queue.post-handle"
out=$(pe "$HW" reconcile)
assert_contains "$out" "published=0" \
  "a later reconcile does not resurface a result once it is durably handled"
[ -z "$(wake_payloads "$HW")" ] || fail "a handled result was announced again: $(wake_payloads "$HW")"

auth_count=0
for _ in 1 2 3; do
  repeat_ack=$(pe "$HW" handled restart-cut-src 1)
  assert_contains "$repeat_ack" "already-handled: restart-cut-src 1" "repeated acknowledgement stays safe and idempotent"
  case "$repeat_ack" in handled:*) auth_count=$((auth_count + 1)) ;; esac
done
[ "$auth_count" -eq 0 ] || fail "a result already durably handled was authorized again: count=$auth_count"
pass "a drained-but-unhandled result survives a replacement session and is retired only by explicit handling, never twice"

HP="$TMP_ROOT/hp"; new_home "$HP"
mkdir -p "$HP/state/procevent-inbox"
for seq in 10 2 1; do
  printf '%s\n' "$seq" > "$HP/state/procevent-inbox/ordered-src.$seq.result"
  printf 'lavish\n' > "$HP/state/procevent-inbox/ordered-src.$seq.adapter"
  chmod 0600 "$HP/state/procevent-inbox/ordered-src.$seq.result" "$HP/state/procevent-inbox/ordered-src.$seq.adapter"
done
pending=$(bash -c '. "$1/bin/fm-procevent-lib.sh"; fm_procevent_pending "$2"' _ "$ROOT" "$HP/state")
expected=$(printf '%s\n' \
  "$HP/state/procevent-inbox/ordered-src.1.result" \
  "$HP/state/procevent-inbox/ordered-src.2.result" \
  "$HP/state/procevent-inbox/ordered-src.10.result")
[ "$pending" = "$expected" ] || fail "pending results were not emitted in numeric sequence order: $pending"
pe "$HP" reconcile >/dev/null
deduped=$(FM_HOME="$HP" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_print_deduped "$2/state/.wake-queue" | awk -F "\t" "{print \$5}"
' _ "$ROOT" "$HP")
expected=$(printf '%s\n' \
  'check: procevent lavish ordered-src 1' \
  'check: procevent lavish ordered-src 2' \
  'check: procevent lavish ordered-src 10')
[ "$deduped" = "$expected" ] || fail "distinct result generations were coalesced or reordered: $deduped"
pass "pending results preserve numeric order and distinct wake identity"

# --- two homes cannot both own one canonical source -------------------------
HA="$TMP_ROOT/ha"; HB="$TMP_ROOT/hb"; new_home "$HA"; new_home "$HB"
TRIG2="$TMP_ROOT/trigger-two"
pe_register "$HA" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe_register "$HB" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe "$HA" reconcile >/dev/null
sleep 0.5
out=$(pe "$HB" start shared-src)
assert_contains "$out" "already owned" "a second home cannot own a source another home already owns"
[ -z "$(wake_payloads "$HB")" ] || fail "the losing home published an event"
pass "one owner per canonical source across homes"

# A source whose child never completes must not survive retirement. This is the
# leak that reparented four orphaned runners: the fixture directory was removed
# while the detached child kept blocking, with nothing left to reap it.
runner_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" 2>/dev/null)
[ -n "$runner_pid" ] || fail "no runner pid recorded for the blocked source"
kill -0 "$runner_pid" 2>/dev/null || fail "the blocked runner is not live before retirement"
pe "$HA" retire shared-src >/dev/null
for _ in $(seq 1 40); do kill -0 "$runner_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$runner_pid" 2>/dev/null && fail "retire left the blocked runner alive"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" "retire releases the claim"
pass "retiring a never-completing source stops its runner and its blocked child"

# reconcile must also stop a runner whose registration was removed out from under
# it. The input is a runner already blocked inside its source command, so wait for
# the start marker rather than a settle window: a runner still short of that
# command retires itself when the registration disappears, which on a loaded host
# turns this into a test of the other outcome and reports uncertain=1.
TRIG4="$TMP_ROOT/trigger-four"
ORPHAN_STARTED="$TMP_ROOT/orphan-src.started"
HZ="$TMP_ROOT/hz"; new_home "$HZ"
pe_register "$HZ" lavish orphan-src \
  -- "$STARTED_BLOCKER" "$ORPHAN_STARTED" "$BLOCKER" "$TRIG4" "orphan" >/dev/null
pe "$HZ" reconcile >/dev/null
wait_for "$ORPHAN_STARTED" || fail "the orphan fixture runner never entered its source command"
orphan_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" 2>/dev/null)
if [ -z "$orphan_pid" ] || ! kill -0 "$orphan_pid" 2>/dev/null; then
  fail "orphan fixture runner did not start"
fi
rm -f "$HZ/state/procevent/orphan-src.source"
out=$(pe "$HZ" reconcile)
assert_contains "$out" "stopped=1" "reconcile stops a runner whose registration was removed"
for _ in $(seq 1 40); do kill -0 "$orphan_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orphan_pid" 2>/dev/null && fail "reconcile left an orphaned runner alive"
pass "reconcile reaps a runner whose source registration is gone"

# --- a stale claim is reclaimable, a live one is not ------------------------
CLAIM="$FM_PROCEVENT_CLAIM_ROOT/stale-src.claim"
mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"
HC="$TMP_ROOT/hc"; new_home "$HC"
printf '%s\n%s\nstale-token\nstale-identity\n' "$HC" "999999" > "$CLAIM"
chmod 0600 "$CLAIM"
pe_register "$HC" lavish stale-src -- /bin/echo recovered >/dev/null
printf 'partial sensitive output\n' > "$HC/state/procevent/.stale-src.stale-token.output"
chmod 0600 "$HC/state/procevent/.stale-src.stale-token.output"
out=$(pe "$HC" start stale-src)
assert_contains "$out" "captured:" "a claim whose runner is gone is reclaimable"
assert_absent "$CLAIM" "the replacement claim generation is released after completion"
assert_absent "$HC/state/procevent/.stale-src.stale-token.output" "stale claim recovery removes its abandoned staging generation"
pass "stale-owner recovery removes abandoned output without displacing a live owner"

HC_OLD="$TMP_ROOT/hc-old"; new_home "$HC_OLD"
HC_NEW="$TMP_ROOT/hc-new"; new_home "$HC_NEW"
HC_OLD_STATE="$TMP_ROOT/hc-old-state"
mkdir -p "$HC_OLD_STATE/procevent"
printf '%s\n%s\ncross-home-token\ncross-home-identity\n%s\n' \
  "$HC_OLD" "999999" "$HC_OLD_STATE/procevent" > "$FM_PROCEVENT_CLAIM_ROOT/cross-home-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/cross-home-src.claim"
printf 'partial cross-home output\n' > "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output"
chmod 0600 "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output"
pe_register "$HC_NEW" lavish cross-home-src -- /bin/echo recovered >/dev/null
out=$(pe "$HC_NEW" start cross-home-src)
assert_contains "$out" "captured:" "a second home can replace a stale source owner"
assert_absent "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output" "cross-home reclaim removes the old generation's recorded staging file"
pass "cross-home stale recovery removes abandoned output from the old state directory"

HR="$TMP_ROOT/hr"; new_home "$HR"
RACE_TRIGGER="$TMP_ROOT/race-trigger"
RACE_LOG="$TMP_ROOT/race-executions"
RACE_BLOCKER="$TMP_ROOT/race-blocker.sh"
cat > "$RACE_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
while [ ! -e "$2" ]; do sleep 0.05; done
printf 'race result\n'
SH
chmod +x "$RACE_BLOCKER"
pe_register "$HR" lavish race-src -- "$RACE_BLOCKER" "$RACE_LOG" "$RACE_TRIGGER" >/dev/null
printf '%s\n%s\nold-token\nold-identity\n' "$TMP_ROOT/gone-home" 999999 > "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
race_pids=()
for _ in $(seq 1 24); do
  pe "$HR" start race-src >/dev/null &
  race_pids+=("$!")
done
wait_for "$RACE_LOG" 300 || fail "no contender acquired the stale claim"
sleep 0.5
[ "$(wc -l < "$RACE_LOG" | tr -d ' ')" = 1 ] || fail "stale-claim race started more than one runner"
: > "$RACE_TRIGGER"
for race_pid in "${race_pids[@]}"; do wait "$race_pid" 2>/dev/null || true; done
pass "concurrent stale-claim replacement starts exactly one runner"

# --- a crashed runner leader must not make its live child group look stale ---
# The runner is its own process group leader, so SIGKILL on the leader alone
# leaves the blocking source child running in that group. Classifying the
# missing leader as stale would release ownership and start a second poller
# against one canonical source, which for a destructive source means two
# concurrent long polls racing on the same session. The surviving group must be
# stopped before ownership can move.
HG="$TMP_ROOT/hg"; new_home "$HG"
ORPHAN_TRIGGER="$TMP_ROOT/orphan-trigger"
ORPHAN_LOG="$TMP_ROOT/orphan-executions"
ORPHAN_GROUP="$TMP_ROOT/orphan-group"
ORPHAN_OVERLAP="$TMP_ROOT/orphan-overlap"
ORPHAN_BLOCKER="$TMP_ROOT/orphan-blocker.sh"
cat > "$ORPHAN_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
if [ -s "$3" ]; then
  IFS= read -r old_group < "$3"
  if kill -0 "-$old_group" 2>/dev/null; then
    printf 'overlap\n' > "$4"
  fi
fi
while [ ! -e "$2" ]; do sleep 0.05; done
printf 'orphan result\n'
SH
chmod +x "$ORPHAN_BLOCKER"
pe_register "$HG" lavish orphan-src -- \
  "$ORPHAN_BLOCKER" "$ORPHAN_LOG" "$ORPHAN_TRIGGER" "$ORPHAN_GROUP" "$ORPHAN_OVERLAP" >/dev/null
pe "$HG" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" || fail "leader-crash fixture never claimed its source"
wait_for "$ORPHAN_LOG" || fail "leader-crash fixture source never started"
orphan_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim")
case "$orphan_leader" in ''|*[!0-9]*) fail "could not read the runner leader pid: $orphan_leader" ;; esac
printf '%s\n' "$orphan_leader" > "$ORPHAN_GROUP"

kill -KILL "$orphan_leader" 2>/dev/null || fail "could not kill the runner leader"
for _ in $(seq 1 50); do kill -0 "$orphan_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orphan_leader" 2>/dev/null && fail "the runner leader survived SIGKILL"
kill -0 -"$orphan_leader" 2>/dev/null || fail "fixture invalid: the owned child group did not survive the leader"

orphan_out=$(pe "$HG" reconcile)
kill -0 -"$orphan_leader" 2>/dev/null \
  || fail "reconcile signalled an ambiguous leaderless process group: $orphan_out"
assert_contains "$orphan_out" "started=0" \
  "reconcile does not replace an ambiguous leaderless generation"
[ -e "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" ] \
  || fail "refusing ambiguous cleanup must preserve the claim"
[ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 1 ] \
  || fail "reconcile started a source beside an ambiguous leaderless group"
assert_absent "$ORPHAN_OVERLAP" "no replacement source starts while the leaderless group remains"
# This is the ordinary crash shape, and it is refused permanently: `orphaned`
# in a listing and `uncertain=1` in output the supervision cycle discards
# reach nobody, so the strand has to announce itself durably, exactly once,
# under a key the watcher can tell apart from a captured result.
orphan_token=$(sed -n '3p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim")
[ -n "$orphan_token" ] || fail "could not read the leaderless claim's token"
[ "$(stranded_wake_count "$HG" orphan-src)" = 1 ] \
  || fail "reconcile stranded a leaderless source without announcing it: $orphan_out"
[ "$(stranded_wake_keys "$HG" orphan-src)" = "procevent:orphan-src:stranded:$orphan_token" ] \
  || fail "the stranded wake is not keyed by source and claim generation: $(stranded_wake_keys "$HG" orphan-src)"
orphan_wake=$(stranded_wake_payloads "$HG" orphan-src)
assert_contains "$orphan_wake" "orphan-src" \
  "the leaderless stranded wake does not name the source it is about: $orphan_wake"
assert_contains "$orphan_wake" "polling" \
  "the leaderless stranded wake does not say what a human should check: $orphan_wake"
# `start` reports this claim as owned and reclaims nothing, so a wake that
# named it as the clearing command would send someone to a no-op.
case "$orphan_wake" in
  *"start orphan-src"*) fail "the leaderless stranded wake names start as clearing it: $orphan_wake" ;;
esac
orphan_start=$(pe "$HG" start orphan-src 2>&1)
assert_contains "$orphan_start" "already owned" \
  "start displaced a leaderless group's claim: $orphan_start"
[ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 1 ] \
  || fail "start ran the source beside an ambiguous leaderless group"
orphan_again=$(pe "$HG" reconcile)
assert_contains "$orphan_again" "started=0" \
  "the second cycle replaced an ambiguous leaderless generation: $orphan_again"
assert_contains "$orphan_again" "uncertain=1" \
  "the second cycle stopped reporting the claim it could not settle: $orphan_again"
[ "$(stranded_wake_count "$HG" orphan-src)" = 1 ] \
  || fail "reconcile re-announced the same leaderless strand: $orphan_again"
[ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 1 ] \
  || fail "the second cycle started a source beside an ambiguous leaderless group"
kill -0 -"$orphan_leader" 2>/dev/null \
  || fail "announcing the strand signalled the leaderless process group"
kill -KILL -"$orphan_leader" 2>/dev/null || true
for _ in $(seq 1 50); do kill -0 -"$orphan_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 -"$orphan_leader" 2>/dev/null && fail "could not clean up the leaderless fixture group"
pe "$HG" retire orphan-src >/dev/null
pass "an ambiguous leaderless group is preserved without replacement"

# Counterexample: a genuinely dead generation - no leader and no surviving
# group - must still be reclaimable, or crash recovery would deadlock.
HG2="$TMP_ROOT/hg2"; new_home "$HG2"
DEAD_TRIGGER="$TMP_ROOT/dead-gen-trigger"
DEAD_LOG="$TMP_ROOT/dead-gen-executions"
pe_register "$HG2" lavish dead-gen-src -- "$RACE_BLOCKER" "$DEAD_LOG" "$DEAD_TRIGGER" >/dev/null
printf '%s\n%s\ndead-token\ndead-identity\n%s\n' "$HG2" 999999 "$HG2/state/procevent" \
  > "$FM_PROCEVENT_CLAIM_ROOT/dead-gen-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/dead-gen-src.claim"
dead_out=$(pe "$HG2" reconcile)
assert_contains "$dead_out" "started=1" "a generation with no leader and no group is still reclaimable"
wait_for "$DEAD_LOG" || fail "the replacement source never started for a truly dead generation"
: > "$DEAD_TRIGGER"
pe "$HG2" retire dead-gen-src >/dev/null
pass "a truly dead generation with no surviving group is still safely reclaimed"

# --- a dead generation stays reclaimable when the state root cannot be
# revalidated -----------------------------------------------------------------
# The reported wedge. Reclaiming a dead generation ran the claim's
# capture-reservation cleanup first, and that cleanup re-verifies the recorded
# state-root identity. Once that identity stopped matching, a claim naming a pid
# and a process group that were both provably gone could not be cleared:
# reconcile kept reporting a start while nothing ever attached, and retire
# refused with "cannot release source ownership". Reservation records are keyed
# by claim token and a replacement always claims a fresh one, so they can never
# collide with the generation that replaces them - they are hygiene, not an
# ownership invariant, and they must not veto an ownership move that the
# documented promise already grants.
#
# The claim below is the modern shape (it carries the state-root identity block
# a legacy claim does not have), which is why the existing dead-generation case
# above never reached this path.
HSR="$TMP_ROOT/hsr"; new_home "$HSR"
SR_TRIGGER="$TMP_ROOT/state-root-trigger"
SR_LOG="$TMP_ROOT/state-root-executions"
pe_register "$HSR" lavish state-root-src -- "$RACE_BLOCKER" "$SR_LOG" "$SR_TRIGGER" >/dev/null
pe "$HSR" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/state-root-src.claim" \
  || fail "state-root fixture never claimed its source"
wait_for "$SR_LOG" || fail "state-root fixture source never started"
sr_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/state-root-src.claim")
case "$sr_leader" in ''|*[!0-9]*) fail "could not read the state-root fixture leader pid" ;; esac
[ -n "$(sed -n '8p' "$FM_PROCEVENT_CLAIM_ROOT/state-root-src.claim")" ] \
  || fail "fixture invalid: the claim carries no state-root identity to invalidate"

kill -KILL -"$sr_leader" 2>/dev/null || true
kill -KILL "$sr_leader" 2>/dev/null || true
for _ in $(seq 1 50); do kill -0 -"$sr_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 "$sr_leader" 2>/dev/null && fail "the state-root fixture leader survived SIGKILL"
kill -0 -"$sr_leader" 2>/dev/null && fail "fixture invalid: the owned group outlived the whole generation"
# Drift the live state root away from what the claim recorded.
chmod 750 "$HSR/state" || fail "could not drift the state-root identity"

sr_out=$(pe "$HSR" reconcile)
assert_contains "$sr_out" "started=1" "a dead generation was not reclaimed after the state root drifted: $sr_out"
# Reporting a start is not the same fact as listening: the previous behavior
# reported exactly this while the replacement silently failed to claim.
wait_for_lines "$SR_LOG" 2 \
  || fail "reconcile reported a start but no replacement source ever ran: $(cat "$SR_LOG")"
sr_new=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/state-root-src.claim")
[ "$sr_new" != "$sr_leader" ] || fail "the dead generation's claim was never replaced"
kill -0 "$sr_new" 2>/dev/null || fail "the replacement runner did not take ownership"
: > "$SR_TRIGGER"
pe "$HSR" retire state-root-src >/dev/null
pass "reconcile reclaims a dead generation whose state-root identity no longer matches"

# Retire must release the same wedged claim rather than refusing forever.
HSR2="$TMP_ROOT/hsr2"; new_home "$HSR2"
pe_register "$HSR2" lavish wedged-src -- /bin/echo recovered >/dev/null
sr2_identity=$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_identity "$2"' _ \
  "$ROOT" "$HSR2/state/procevent/wedged-src.source") \
  || fail "could not read the wedged fixture registration identity"
{
  printf '%s\n%s\nwedged-token\nwedged-identity\n' "$HSR2" 999999
  printf '%s\n%s\nactive\n' "$HSR2/state/procevent" "$sr2_identity"
  # A state-root identity that names the right directory with the wrong inode:
  # exactly what a claim recorded before its home was re-created looks like.
  printf '%s\n%s\n%s\n%s\n%s\n' "$HSR2/state" 1 1 "$(id -u)" 755
} > "$FM_PROCEVENT_CLAIM_ROOT/wedged-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/wedged-src.claim"
wedged_out=$(pe "$HSR2" retire wedged-src 2>&1) \
  || fail "retire refused to release a claim whose whole generation is gone: $wedged_out"
assert_contains "$wedged_out" "retired: wedged-src" "retire did not report releasing the wedged source: $wedged_out"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/wedged-src.claim" "retire left the dead generation owning the source"
assert_absent "$HSR2/state/procevent/wedged-src.source" "retire left the wedged source registered"
pass "retire releases a dead generation's claim instead of refusing forever"

# The guard is not weakened in the other direction: the same unrevalidatable
# state root must NOT let anything take a source away from a live generation.
HSR3="$TMP_ROOT/hsr3"; new_home "$HSR3"
SR3_TRIGGER="$TMP_ROOT/state-root-live-trigger"
SR3_LOG="$TMP_ROOT/state-root-live-executions"
pe_register "$HSR3" lavish live-drift-src -- "$RACE_BLOCKER" "$SR3_LOG" "$SR3_TRIGGER" >/dev/null
pe "$HSR3" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/live-drift-src.claim" \
  || fail "live-drift fixture never claimed its source"
wait_for "$SR3_LOG" || fail "live-drift fixture source never started"
sr3_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/live-drift-src.claim")
chmod 750 "$HSR3/state" || fail "could not drift the live owner's state-root identity"
sr3_out=$(pe "$HSR3" start live-drift-src)
assert_contains "$sr3_out" "already owned" "a live generation was displaced after its state root drifted: $sr3_out"
[ "$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/live-drift-src.claim")" = "$sr3_leader" ] \
  || fail "the live generation's claim was replaced"
kill -0 "$sr3_leader" 2>/dev/null || fail "the live owner was killed by a reclaim attempt"
sr3_reconcile=$(pe "$HSR3" reconcile)
assert_contains "$sr3_reconcile" "started=0" "reconcile started a second poller beside a live owner: $sr3_reconcile"
[ "$(wc -l < "$SR3_LOG" | tr -d ' ')" = 1 ] \
  || fail "a second source ran beside the live owner: $(cat "$SR3_LOG")"
: > "$SR3_TRIGGER"
pe "$HSR3" retire live-drift-src >/dev/null
pass "a live generation is never reclaimed, drifted state root or not"

HSR4="$TMP_ROOT/hsr4"; new_home "$HSR4"
SR4_TRIGGER="$TMP_ROOT/state-root-reused-trigger"
SR4_LOG="$TMP_ROOT/state-root-reused-executions"
pe_register "$HSR4" lavish reused-group-src -- "$RACE_BLOCKER" "$SR4_LOG" "$SR4_TRIGGER" >/dev/null
pe "$HSR4" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/reused-group-src.claim" \
  || fail "reused-group fixture never claimed its source"
wait_for "$SR4_LOG" || fail "reused-group fixture source never started"
sr4_claim="$FM_PROCEVENT_CLAIM_ROOT/reused-group-src.claim"
sr4_leader=$(sed -n '2p' "$sr4_claim")
sr4_identity=$(sed -n '4p' "$sr4_claim")
kill -0 -"$sr4_leader" 2>/dev/null \
  || fail "fixture invalid: the reused-pid process group is not alive"
awk 'NR == 4 { print "different-live-process-identity"; next } { print }' \
  "$sr4_claim" > "$sr4_claim.tmp" && mv "$sr4_claim.tmp" "$sr4_claim"
chmod 0600 "$sr4_claim"
chmod 750 "$HSR4/state" || fail "could not drift the reused-group state root"
sr4_out=$(pe "$HSR4" reconcile)
sleep 0.5
[ "$(wc -l < "$SR4_LOG" | tr -d ' ')" = 1 ] \
  || fail "reconcile started a replacement beside a reused pid's live group: $sr4_out"
# Ownership cannot move here by design, so a replacement could only die on the
# claim it cannot take - once per reconcile cycle, forever.
assert_contains "$sr4_out" "started=0" \
  "reconcile reported a start into a claim nothing can take: $sr4_out"
assert_contains "$sr4_out" "uncertain=1" \
  "reconcile did not report the claim it could not settle: $sr4_out"
[ "$(sed -n '2p' "$sr4_claim")" = "$sr4_leader" ] \
  || fail "reconcile replaced the reused-pid generation's claim"
# Nothing can take this source, so reporting it as unowned reads like an idle
# source waiting to be started - the reassuring answer this surface gave while a
# review board collected nothing.
sr4_owner=$(pe "$HSR4" list | awk '$1 == "reused-group-src" { print $3 }')
[ "$sr4_owner" = orphaned ] \
  || fail "a source no caller can claim is listed as '$sr4_owner'"
# `orphaned` in a listing and `uncertain=1` in output the supervision cycle
# discards reach nobody. The strand has to announce itself durably, exactly
# once, and say which command clears it.
[ "$(stranded_wake_count "$HSR4" reused-group-src)" = 1 ] \
  || fail "reconcile stranded a source without announcing it: $sr4_out"
# The key carries the source and its claim generation in a shape the watcher
# can tell apart from a captured result, so the strand is never headlined as one.
[ "$(stranded_wake_keys "$HSR4" reused-group-src)" = "procevent:reused-group-src:stranded:$(sed -n '3p' "$sr4_claim")" ] \
  || fail "the stranded wake is not keyed by source and claim generation: $(stranded_wake_keys "$HSR4" reused-group-src)"
sr4_wake=$(stranded_wake_payloads "$HSR4" reused-group-src)
assert_contains "$sr4_wake" "reused-group-src" \
  "the stranded wake does not name the source it is about: $sr4_wake"
assert_contains "$sr4_wake" "bin/fm-procevent.sh start reused-group-src" \
  "the stranded wake does not name the command that clears it: $sr4_wake"
# A wake nobody can silence is as unusable as one nobody gets: the same stranded
# generation must not re-announce on every supervision cycle.
sr4_again=$(pe "$HSR4" reconcile)
assert_contains "$sr4_again" "uncertain=1" \
  "the second cycle stopped reporting the claim it could not settle: $sr4_again"
[ "$(stranded_wake_count "$HSR4" reused-group-src)" = 1 ] \
  || fail "reconcile re-announced the same stranded generation: $sr4_again"
[ "$(wc -l < "$SR4_LOG" | tr -d ' ')" = 1 ] \
  || fail "the second cycle started a replacement beside a reused pid's live group: $sr4_again"
# The wake names `start` as the recovery, so run it against the state it will
# actually meet. The earlier end-to-end demonstration of that command used an
# UNDRIFTED fixture and therefore proved only the easy case; on this one the
# state root has drifted, so the dead generation's reservation records cannot
# be tidied, and the claim path waives that tidy-up only for a generation
# proven gone - which a surviving group is not. `start` must refuse here, keep
# the claim, and start no second source beside the live group, and the wake
# must have said so rather than promising a reclaim.
assert_contains "$sr4_wake" "cannot claim source" \
  "the stranded wake promises an unconditional reclaim: $sr4_wake"
set +e
sr4_start=$(pe "$HSR4" start reused-group-src 2>&1)
sr4_start_rc=$?
set -e
[ "$sr4_start_rc" -ne 0 ] \
  || fail "start reported success against a claim it could not tidy: $sr4_start"
assert_contains "$sr4_start" "cannot claim source" \
  "start did not refuse by name on the drifted reused-pid fixture: $sr4_start"
[ "$(sed -n '2p' "$sr4_claim")" = "$sr4_leader" ] \
  || fail "a refused start replaced the reused-pid generation's claim"
sleep 0.3
[ "$(wc -l < "$SR4_LOG" | tr -d ' ')" = 1 ] \
  || fail "a refused start ran a second source beside a reused pid's live group: $(cat "$SR4_LOG")"
set +e
sr4_retire=$(pe "$HSR4" retire reused-group-src 2>&1)
sr4_rc=$?
set -e
[ "$sr4_rc" -ne 0 ] || fail "retire released a claim whose process group survives: $sr4_retire"
[ -e "$sr4_claim" ] || fail "retire removed the reused-pid generation's claim"
[ -e "$HSR4/state/procevent/reused-group-src.source" ] \
  || fail "retire removed the reused-pid generation's registration"
awk -v identity="$sr4_identity" 'NR == 4 { print identity; next } { print }' \
  "$sr4_claim" > "$sr4_claim.tmp" && mv "$sr4_claim.tmp" "$sr4_claim"
chmod 0600 "$sr4_claim"
chmod 755 "$HSR4/state"
# Keep the child blocked so retirement alone ends the restored generation;
# releasing it races natural exit against the first signal's ownership check.
pe "$HSR4" retire reused-group-src >/dev/null \
  || fail "retirement failed after restoring the reused-group fixture's identity"
kill -0 -"$sr4_leader" 2>/dev/null \
  && fail "retirement left the restored reused-group fixture running"
pass "a reused pid never makes its surviving process group reclaimable"

# --- the easy case the wake promises: an undrifted reused-pid claim ----------
# Same strand, no state-root drift: the dead generation's reservation records
# can be tidied, so the attached `start` the wake names takes the claim and
# runs the source. The claim path does not consult the process group; that is
# the documented asymmetry between reconcile and a deliberate start.
HSR5="$TMP_ROOT/hsr5"; new_home "$HSR5"
SR5_TRIGGER="$TMP_ROOT/reused-plain-trigger"
SR5_LOG="$TMP_ROOT/reused-plain-executions"
pe_register "$HSR5" lavish reused-plain-src -- "$RACE_BLOCKER" "$SR5_LOG" "$SR5_TRIGGER" >/dev/null
pe "$HSR5" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/reused-plain-src.claim" \
  || fail "undrifted reused-pid fixture never claimed its source"
wait_for "$SR5_LOG" || fail "undrifted reused-pid fixture source never started"
sr5_claim="$FM_PROCEVENT_CLAIM_ROOT/reused-plain-src.claim"
sr5_leader=$(sed -n '2p' "$sr5_claim")
awk 'NR == 4 { print "different-live-process-identity"; next } { print }' \
  "$sr5_claim" > "$sr5_claim.tmp" && mv "$sr5_claim.tmp" "$sr5_claim"
chmod 0600 "$sr5_claim"
sr5_out=$(pe "$HSR5" reconcile)
assert_contains "$sr5_out" "uncertain=1" \
  "reconcile did not strand the undrifted reused-pid claim: $sr5_out"
[ "$(stranded_wake_count "$HSR5" reused-plain-src)" = 1 ] \
  || fail "the undrifted strand was not announced: $sr5_out"
pe "$HSR5" start reused-plain-src > "$TMP_ROOT/reused-plain-start.out" 2>&1 &
sr5_start_pid=$!
wait_for_lines "$SR5_LOG" 2 \
  || fail "start did not reclaim the undrifted reused-pid claim: $(cat "$TMP_ROOT/reused-plain-start.out")"
[ "$(sed -n '2p' "$sr5_claim")" != "$sr5_leader" ] \
  || fail "start ran the source without taking the claim from the dead generation"
: > "$SR5_TRIGGER"
wait "$sr5_start_pid" \
  || fail "start failed after reclaiming the undrifted claim: $(cat "$TMP_ROOT/reused-plain-start.out")"
assert_contains "$(cat "$TMP_ROOT/reused-plain-start.out")" "captured:" \
  "the reclaiming start did not capture the source's result"
for _ in $(seq 1 50); do kill -0 -"$sr5_leader" 2>/dev/null || break; sleep 0.1; done
pe "$HSR5" retire reused-plain-src >/dev/null 2>&1 || true
pass "start reclaims a reused-pid claim whose leftovers can still be tidied"

# --- a launch that cannot confirm is announced once per failure episode ------
# `bin/fm-watch.sh` discards reconcile's `failed=` count and exit status, so a
# runner that dies before claiming - for any cause, not only the claim wedge -
# would be relaunched and reported failed every cycle with nobody told: armed
# in appearance, a dead drop in fact. The episode is keyed by the registration
# identity the launch ran under and ends when a launch of that source confirms,
# so the registration below is damaged and repaired IN PLACE to keep that
# identity fixed across the whole sequence. The wake changes nothing about the
# launch: every failing cycle below still relaunches and still reports failed.
HEP="$TMP_ROOT/hep"; new_home "$HEP"
EP_SOURCE_CMD="$TMP_ROOT/episode-source.sh"
cat > "$EP_SOURCE_CMD" <<'SH'
#!/usr/bin/env bash
printf 'episode result\n'
SH
chmod +x "$EP_SOURCE_CMD"
pe_register "$HEP" lavish episode-src -- "$EP_SOURCE_CMD" >/dev/null
EP_SOURCE="$HEP/state/procevent/episode-src.source"
cp "$EP_SOURCE" "$TMP_ROOT/episode-good.source"
awk '/^argv:$/ { print; exit } { print }' "$EP_SOURCE" > "$TMP_ROOT/episode-bad.source" \
  || fail "could not prepare the damaged episode registration"
ep_damage() { cat "$TMP_ROOT/episode-bad.source" > "$EP_SOURCE"; }
ep_repair() { cat "$TMP_ROOT/episode-good.source" > "$EP_SOURCE"; }
ep_reconcile() {  # <expected-fragment> <expected-exit-nonzero:0|1> <msg>; sets ep_out
  local rc=0
  ep_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 pe "$HEP" reconcile) || rc=$?
  assert_contains "$ep_out" "$1" "$3: $ep_out"
  if [ "$2" -eq 1 ]; then
    [ "$rc" -ne 0 ] || fail "$3 (reconcile exited 0): $ep_out"
  else
    [ "$rc" -eq 0 ] || fail "$3 (reconcile exited $rc): $ep_out"
  fi
}
ep_damage
ep_reconcile "failed=1" 1 "a launch that never proved its claim was not reported failed"
[ "$(launch_failed_wake_count "$HEP" episode-src)" = 1 ] \
  || fail "a launch that could not confirm was not announced: $ep_out"
ep_key=$(launch_failed_wake_keys "$HEP" episode-src)
# <registration identity>-<per-episode nonce>: the watcher remembers every key
# it has surfaced for good, so the identity alone would announce only the first
# episode of a registration (tests/fm-watch-triage.test.sh proves delivery).
[[ "$ep_key" =~ ^(procevent:episode-src:launch-failed:[0-9]+-[0-9]+)-[0-9]+$ ]] \
  || fail "the launch-failed wake is not keyed by source, registration identity and episode: $ep_key"
ep_episode_prefix=${BASH_REMATCH[1]}
ep_wake=$(launch_failed_wake_payloads "$HEP" episode-src)
assert_contains "$ep_wake" "episode-src" \
  "the launch-failed wake does not name the source it is about: $ep_wake"
# The payload may state only what confirmation observed: no claim proved
# inside the window. It cannot know whether the runner died or was slow, so it
# must not assert a cause, must not present `start` as the fix, and must say
# that a later cycle finding the source owned closes the episode by itself.
assert_contains "$ep_wake" "did not prove it took the source's claim within FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS" \
  "the launch-failed wake does not state what confirmation observed: $ep_wake"
assert_contains "$ep_wake" "attached bin/fm-procevent.sh start episode-src to reproduce a refusal" \
  "the launch-failed wake does not say start reproduces rather than fixes: $ep_wake"
assert_contains "$ep_wake" "adapter binary" \
  "the launch-failed wake does not name what to check: $ep_wake"
assert_contains "$ep_wake" "finds the source owned ends this episode on its own" \
  "the launch-failed wake does not say a slow runner closes its own episode: $ep_wake"
case "$ep_wake" in
  *"never claimed"*|*"exited without"*|*"runner died"*)
    fail "the launch-failed wake asserts a cause confirmation cannot observe: $ep_wake" ;;
esac
ep_reconcile "failed=1" 1 "the second cycle stopped relaunching a source that cannot start"
[ "$(launch_failed_wake_count "$HEP" episode-src)" = 1 ] \
  || fail "the same failure episode was announced twice: $ep_out"
ep_repair
ep_reconcile "started=1" 0 "a repaired source did not confirm"
assert_contains "$ep_out" "failed=0" "a repaired source was still reported failed: $ep_out"
[ "$(launch_failed_wake_count "$HEP" episode-src)" = 1 ] \
  || fail "a confirmed launch produced a launch-failed wake: $ep_out"
for _ in $(seq 1 100); do
  [ -e "$FM_PROCEVENT_CLAIM_ROOT/episode-src.claim" ] || break
  sleep 0.1
done
[ ! -e "$FM_PROCEVENT_CLAIM_ROOT/episode-src.claim" ] \
  || fail "the confirmed episode runner never released its claim"
ep_damage
ep_reconcile "failed=1" 1 "a source that failed again after recovering was not reported failed"
[ "$(launch_failed_wake_count "$HEP" episode-src)" = 2 ] \
  || fail "a new failure episode after a confirmed launch was not announced: $ep_out"
# The earlier version of this assertion locked in ONE key for both episodes,
# which is exactly the collision that left every episode after the first
# unsurfaced: both keys must carry the same registration identity and still
# differ, or the watcher's seen marker for episode one suppresses episode two.
ep_key_again=$(launch_failed_wake_keys "$HEP" episode-src | sed -n '2p')
[ "$ep_key_again" != "$ep_key" ] \
  || fail "a new failure episode reused the first episode's queue key: $ep_key_again"
case "$ep_key_again" in
  "$ep_episode_prefix"-*) ;;
  *) fail "the second episode ran under a different registration identity: $ep_key_again (first: $ep_key)" ;;
esac
ep_repair
pe "$HEP" retire episode-src >/dev/null 2>&1 || true
pass "a launch that cannot confirm is announced once per failure episode"

# --- the launch-failed key fits the watcher's seen marker at the id limit ----
# bin/fm-watch.sh names the marker for a surfaced key `.seen-procevent-<hex>`,
# 16 + 2 * keylen bytes against NAME_MAX 255, so a key longer than 119 chars
# cannot be marked and its wake would re-surface every cycle. The longest id
# the validator accepts is 64 chars; the executed key for such an id must fit.
HLK="$TMP_ROOT/hlk"; new_home "$HLK"
LK_ID=$(printf 'k%.0s' $(seq 1 64))
[ "${#LK_ID}" -eq 64 ] || fail "fixture invalid: long source id is ${#LK_ID} chars"
pe_register "$HLK" lavish "$LK_ID" -- "$EP_SOURCE_CMD" >/dev/null
LK_SOURCE="$HLK/state/procevent/$LK_ID.source"
if ! { awk '/^argv:$/ { print; exit } { print }' "$LK_SOURCE" > "$LK_SOURCE.tmp" \
  && cat "$LK_SOURCE.tmp" > "$LK_SOURCE" && rm -f -- "$LK_SOURCE.tmp"; }; then
  fail "could not damage the long-id registration"
fi
lk_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 pe "$HLK" reconcile) || true
assert_contains "$lk_out" "failed=1" "the long-id launch was not reported failed: $lk_out"
lk_key=$(launch_failed_wake_keys "$HLK" "$LK_ID")
[ -n "$lk_key" ] || fail "the long-id launch failure was not announced: $lk_out"
[ "${#lk_key}" -le 119 ] \
  || fail "a 64-char source id yields a ${#lk_key}-char launch-failed key, which the watcher cannot mark: $lk_key"
pe "$HLK" retire "$LK_ID" >/dev/null 2>&1 || true
pass "a 64-char source id keeps the launch-failed key within the watcher's marker bound"

# --- reconcile reports only launches it actually confirmed -------------------
# The reported incident. A review board the captain had answered sat collecting
# nothing while `reconcile` reported a start on every run: `detach_runner` is
# fire-and-forget with the child's stderr discarded, so a runner that died
# before it could claim was counted exactly like one that is listening. A
# surface that presents as armed while being a dead drop is worse than one that
# visibly fails, because the answers look recorded.
#
# The damaged registration below makes the runner die BEFORE it claims, which
# is what keeps this deterministic: a runner that claims and then dies would
# race the confirmation either way, and the next reconcile cycle is what covers
# that case.
HUF="$TMP_ROOT/huf"; new_home "$HUF"
UF_TRIGGER="$TMP_ROOT/unstartable-trigger"
pe_register "$HUF" lavish unstartable-src -- "$BLOCKER" "$UF_TRIGGER" "unstartable" >/dev/null
UF_SOURCE="$HUF/state/procevent/unstartable-src.source"
if ! awk '/^argv:$/ { print; exit } { print }' "$UF_SOURCE" > "$UF_SOURCE.tmp"; then
  fail "could not damage the unstartable registration"
fi
mv "$UF_SOURCE.tmp" "$UF_SOURCE" || fail "could not damage the unstartable registration"
chmod 0600 "$UF_SOURCE"
uf_rc=0
uf_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 pe "$HUF" reconcile) || uf_rc=$?
assert_contains "$uf_out" "started=0" \
  "reconcile counted a runner that never started as a start: $uf_out"
assert_contains "$uf_out" "failed=1" \
  "reconcile did not report the launch it could not confirm: $uf_out"
[ "$uf_rc" -ne 0 ] || fail "reconcile reported success while a source could not start: $uf_out"
uf_owner=$(pe "$HUF" list | awk '$1 == "unstartable-src" { print $3 }')
[ "$uf_owner" = none ] || fail "the unstartable source reports an owner: $uf_owner"
pe "$HUF" retire unstartable-src >/dev/null 2>&1 || true
pass "reconcile reports a launch it could not confirm instead of counting it as a start"

# --- a launch that finished before the first poll is still confirmed ---------
# Confirmation has to read evidence a finished runner leaves behind. A runner
# removes its own runner record on the way out, so a source that claims, runs
# and exits before confirmation looks at it once returns every transient signal
# to exactly what it was before the launch - and a good run gets reported as a
# failure, on every cycle, for a source that is working perfectly.
#
# The second registration is what makes that deterministic rather than a race:
# reconcile launches the fast source first, then blocks acquiring the held
# lock of the second source, and the holder is released only once the fast
# runner has captured its result and let go of both its claim and its runner
# record. Confirmation therefore starts strictly after the fast runner is gone.
HFC="$TMP_ROOT/hfc"; new_home "$HFC"
FC_FAST="$TMP_ROOT/fast-source.sh"
cat > "$FC_FAST" <<'SH'
#!/usr/bin/env bash
printf 'fast payload\n'
SH
chmod +x "$FC_FAST"
FC_TRIGGER="$TMP_ROOT/fast-hold-trigger"
pe_register "$HFC" lavish aa-fast-src -- "$FC_FAST" >/dev/null
pe_register "$HFC" lavish zz-hold-src -- "$BLOCKER" "$FC_TRIGGER" "held" >/dev/null
FC_READY="$TMP_ROOT/fast-hold-ready"; FC_RELEASE="$TMP_ROOT/fast-hold-release"
hold_source_lock zz-hold-src "$FC_READY" "$FC_RELEASE"
wait_for "$FC_READY" || fail "the fast-source fixture could not hold a source lock"
(
  for _ in $(seq 1 600); do
    if first_result "$HFC" aa-fast-src >/dev/null 2>&1 \
      && [ ! -e "$HFC/state/procevent/aa-fast-src.runner" ] \
      && [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/aa-fast-src.claim" ]; then
      break
    fi
    sleep 0.05
  done
  : > "$FC_RELEASE"
) &
FC_RELEASER=$!
fc_rc=0
fc_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 pe "$HFC" reconcile) || fc_rc=$?
wait "$FC_RELEASER" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
first_result "$HFC" aa-fast-src >/dev/null \
  || fail "fixture invalid: the fast source never produced a result: $fc_out"
assert_contains "$fc_out" "started=2" \
  "reconcile did not report both launches as started: $fc_out"
assert_contains "$fc_out" "failed=0" \
  "reconcile reported a launch that ran to completion as a failure: $fc_out"
[ "$fc_rc" -eq 0 ] || fail "reconcile exited non-zero with every launch confirmed: $fc_out"
: > "$FC_TRIGGER"
pe "$HFC" retire aa-fast-src >/dev/null 2>&1 || true
pe "$HFC" retire zz-hold-src >/dev/null 2>&1 || true
pass "a launch that finished before confirmation looked is still reported as started"

# --- a zero-padded confirm window is read as base 10 -------------------------
# The window's validator reads base 10, so `08` is a value it accepts. Read as
# octal in arithmetic it is not a number at all, which under `set -u` takes the
# confirmation down with it and turns every launch of the cycle - including a
# perfectly healthy one - into a reported failure and a non-zero exit.
HZP="$TMP_ROOT/hzp"; new_home "$HZP"
ZP_TRIGGER="$TMP_ROOT/zeropad-trigger"
pe_register "$HZP" lavish zeropad-src -- "$BLOCKER" "$ZP_TRIGGER" "zeropad" >/dev/null
zp_rc=0
zp_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=08 pe "$HZP" reconcile 2>/dev/null) || zp_rc=$?
assert_contains "$zp_out" "started=1" \
  "a zero-padded confirm window lost the launch reconcile started: $zp_out"
assert_contains "$zp_out" "failed=0" \
  "a zero-padded confirm window reported a healthy launch as failed: $zp_out"
[ "$zp_rc" -eq 0 ] || fail "a zero-padded confirm window made reconcile exit non-zero: $zp_out"
: > "$ZP_TRIGGER"
pe "$HZP" retire zeropad-src >/dev/null 2>&1 || true
pass "a zero-padded launch confirm window is honored as base 10"

# --- an unusable confirm window is refused by name --------------------------
# A window this command cannot use makes every launch unconfirmable. Reported
# from inside the confirmation it comes out as a fleet of healthy runners that
# all "could not start", blaming the sources instead of the typo. Every other
# tunable on this path - the launch floor, the output bound - refuses a bad
# value by name before anything runs, and so does this one.
HIW="$TMP_ROOT/hiw"; new_home "$HIW"
IW_TRIGGER="$TMP_ROOT/invalid-window-trigger"
pe_register "$HIW" lavish invalid-window-src -- "$BLOCKER" "$IW_TRIGGER" "window" >/dev/null
for iw_value in 5s 0 700; do
  iw_rc=0
  iw_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS="$iw_value" pe "$HIW" reconcile 2>&1) || iw_rc=$?
  [ "$iw_rc" -ne 0 ] \
    || fail "reconcile accepted the unusable confirm window '$iw_value': $iw_out"
  assert_contains "$iw_out" "FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS" \
    "the unusable confirm window '$iw_value' was not named by what refused it: $iw_out"
  case "$iw_out" in
    *failed=*) fail "the unusable confirm window '$iw_value' was blamed on the sources: $iw_out" ;;
  esac
  [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/invalid-window-src.claim" ] \
    || fail "reconcile launched a runner before refusing the confirm window '$iw_value'"
done
# The refusal costs the source nothing: it still arms on the next run with a
# usable value.
iw_ok=$(pe "$HIW" reconcile)
assert_contains "$iw_ok" "started=1" \
  "the source did not arm once its confirm window was usable: $iw_ok"
assert_contains "$iw_ok" "failed=0" \
  "the source was reported as failed once its confirm window was usable: $iw_ok"
: > "$IW_TRIGGER"
pe "$HIW" retire invalid-window-src >/dev/null 2>&1 || true
pass "an unusable launch confirm window is refused by name instead of blamed on the sources"

