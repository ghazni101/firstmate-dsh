# shellcheck shell=bash
# Part 3 of tests/fm-procevent.test.sh, split so no single ShellCheck root
# carries the whole suite. This file is sourced, in order, by that
# runner: it is executable test code, not a definition-only module, and
# it shares the runner's shell state and counters.
# shellcheck disable=SC2034,SC2153,SC2154,SC2329 # state is shared across the sourced parts

# --- a dead generation's untidyable leftovers never wedge ownership ----------
# The same wedge as the state-root case above, reached through the sibling
# cleanups in the stale-claim branch rather than the capture reservation. Every
# one of them tidies leftovers keyed by the DEAD generation's claim token, so
# none can collide with the replacement, yet a failure in any of them used to
# refuse the claim outright - permanently, because the condition never clears on
# its own. Here the recorded registry directory no longer resolves to a
# directory at all, which is what a claim recorded before its home was replaced
# looks like.
HUW="$TMP_ROOT/huw"; new_home "$HUW"
UW_TRIGGER="$TMP_ROOT/untidyable-trigger"
UW_LOG="$TMP_ROOT/untidyable-executions"
pe_register "$HUW" lavish untidyable-src -- "$RACE_BLOCKER" "$UW_LOG" "$UW_TRIGGER" >/dev/null
UW_REG_FILE="$TMP_ROOT/untidyable-recorded-registry"
: > "$UW_REG_FILE"
uw_identity=$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_identity "$2"' _ \
  "$ROOT" "$HUW/state/procevent/untidyable-src.source") \
  || fail "could not read the untidyable fixture registration identity"
UW_CLAIM="$FM_PROCEVENT_CLAIM_ROOT/untidyable-src.claim"
{
  printf '%s\n%s\nuntidyable-token\nuntidyable-identity\n' "$HUW" 999999
  printf '%s\n%s\nactive\n' "$UW_REG_FILE" "$uw_identity"
  printf '%s\n%s\n%s\n%s\n%s\n' "$HUW/state" \
    "$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_device "$2"' _ "$ROOT" "$HUW/state")" \
    "$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_inode "$2"' _ "$ROOT" "$HUW/state")" \
    "$(id -u)" 755
} > "$UW_CLAIM"
chmod 0600 "$UW_CLAIM"
kill -0 999999 2>/dev/null && fail "fixture invalid: the untidyable claim names a live pid"
kill -0 -999999 2>/dev/null && fail "fixture invalid: the untidyable claim's process group is alive"
uw_rc=0
uw_out=$(pe "$HUW" reconcile) || uw_rc=$?
[ "$uw_rc" -eq 0 ] || fail "reconcile could not repair a provably dead generation: $uw_out"
# Reporting a start is not the same fact as listening, so prove the listening
# half first: before this fix reconcile reported exactly this start on every run
# while the dead generation kept the claim and nothing ever attached.
wait_for "$UW_LOG" || fail "reconcile reported a start but no replacement source ever ran: $uw_out"
uw_new=$(sed -n '2p' "$UW_CLAIM")
[ "$uw_new" != 999999 ] || fail "the dead generation kept owning the source: $uw_out"
kill -0 "$uw_new" 2>/dev/null || fail "the replacement runner did not take ownership: $uw_out"
assert_contains "$uw_out" "started=1" "reconcile did not report the replacement it started: $uw_out"
assert_contains "$uw_out" "failed=0" "reconcile could not confirm the replacement: $uw_out"
: > "$UW_TRIGGER"
pe "$HUW" retire untidyable-src >/dev/null
pass "a dead generation whose leftovers cannot be tidied never keeps owning its source"

HJ="$TMP_ROOT/hj"; new_home "$HJ"
TORN_TRIGGER="$TMP_ROOT/torn-trigger"
pe_register "$HJ" lavish torn-src -- "$BLOCKER" "$TORN_TRIGGER" "torn" >/dev/null
pe "$HJ" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim" || fail "torn-read fixture runner did not claim its source"
awk 'NR == 3 { print "replacement-token"; next } { print }' \
  "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim" > "$TMP_ROOT/torn-next.claim"
chmod 0600 "$TMP_ROOT/torn-next.claim"
TORN_READY="$TMP_ROOT/torn-lock-ready"
TORN_RELEASE="$TMP_ROOT/torn-lock-release"
hold_source_lock torn-src "$TORN_READY" "$TORN_RELEASE"
torn_holder_pid=$HOLDER_PID
wait_for "$TORN_READY" || fail "could not hold the torn-read source boundary"
pe "$HJ" list > "$TMP_ROOT/torn-list.out" &
torn_list_pid=$!
sleep 0.2
kill -0 "$torn_list_pid" 2>/dev/null || fail "claim reader escaped the source boundary during replacement"
mv "$TMP_ROOT/torn-next.claim" "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim"
: > "$TORN_RELEASE"
wait "$torn_list_pid" || fail "claim reader failed after serialized replacement"
wait "$torn_holder_pid" || fail "torn-read source boundary holder failed"
assert_contains "$(cat "$TMP_ROOT/torn-list.out")" "live" "claim reader observes one coherent replacement generation"
pe "$HJ" retire torn-src >/dev/null
pass "claim replacement cannot produce a torn ownership snapshot"

HK="$TMP_ROOT/hk"; new_home "$HK"
START_LOG="$TMP_ROOT/retire-start-executions"
START_BLOCKER="$TMP_ROOT/retire-start-blocker.sh"
cat > "$START_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
sleep 30
SH
chmod +x "$START_BLOCKER"
pe_register "$HK" lavish retire-start-src -- "$START_BLOCKER" "$START_LOG" >/dev/null
START_READY="$TMP_ROOT/retire-start-lock-ready"
START_RELEASE="$TMP_ROOT/retire-start-lock-release"
hold_source_lock retire-start-src "$START_READY" "$START_RELEASE"
retire_start_holder_pid=$HOLDER_PID
wait_for "$START_READY" || fail "could not hold the retire-start source boundary"
pe "$HK" start retire-start-src > "$TMP_ROOT/retire-start.out" 2>&1 &
retire_start_pid=$!
sleep 0.2
kill -0 "$retire_start_pid" 2>/dev/null || fail "start did not wait for the source lifecycle boundary"
rm -f "$HK/state/procevent/retire-start-src.source"
: > "$START_RELEASE"
wait "$retire_start_pid" 2>/dev/null || true
wait "$retire_start_holder_pid" || fail "retire-start source boundary holder failed"
assert_absent "$START_LOG" "a start queued before retirement must revalidate the registration"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/retire-start-src.claim" "retirement cannot leave a late claim"
pass "retirement and start share one serialized lifecycle boundary"

HI="$TMP_ROOT/hi"; new_home "$HI"
pe_register "$HI" lavish reused-src -- /bin/true >/dev/null
sleep 60 &
innocent_pid=$!
printf '%s\n%s\nreused-token\nnot-the-live-process-identity\n' \
  "$HI" "$innocent_pid" > "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
pe "$HI" retire reused-src >/dev/null
kill -0 "$innocent_pid" 2>/dev/null || fail "retirement signaled a PID whose identity did not match the claim"
kill "$innocent_pid" 2>/dev/null || true
wait "$innocent_pid" 2>/dev/null || true
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim" "retirement releases the exact reused-pid claim"
pass "detected PID reuse is refused before signalling"

HL="$TMP_ROOT/hl"; new_home "$HL"
IDENTITY_TRIGGER="$TMP_ROOT/identity-trigger"
pe_register "$HL" lavish identity-src -- "$BLOCKER" "$IDENTITY_TRIGGER" "identity" >/dev/null
pe "$HL" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim" || fail "identity fixture runner did not claim its source"
identity_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim")
IDENTITY_FAKEBIN=$(fm_fakebin "$TMP_ROOT/identity-tools")
cat > "$IDENTITY_FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$IDENTITY_FAKEBIN/ps"
identity_status=0
identity_out=$(PATH="$IDENTITY_FAKEBIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" \
  pe "$HL" retire identity-src 2>&1) || identity_status=$?
[ "$identity_status" -ne 0 ] || fail "retirement succeeded despite uncertain live identity"
assert_contains "$identity_out" "source remains registered" "uncertain retirement reports preserved state"
kill -0 "$identity_pid" 2>/dev/null || fail "uncertain retirement signaled the runner"
assert_present "$HL/state/procevent/identity-src.source" "uncertain retirement preserves registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim" "uncertain retirement preserves claim generation"
pe "$HL" retire identity-src >/dev/null
pass "transient identity failure preserves the live source for retry"

HM="$TMP_ROOT/hm"; new_home "$HM"
SWEEP_TRIGGER_ONE="$TMP_ROOT/sweep-trigger-one"
SWEEP_TRIGGER_TWO="$TMP_ROOT/sweep-trigger-two"
pe_register "$HM" lavish sweep-one -- "$BLOCKER" "$SWEEP_TRIGGER_ONE" "sweep one" >/dev/null
pe_register "$HM" lavish sweep-two -- "$BLOCKER" "$SWEEP_TRIGGER_TWO" "sweep two" >/dev/null
pe "$HM" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" || fail "home sweep fixture one did not start"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" || fail "home sweep fixture two did not start"
sweep_pid_one=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim")
sweep_pid_two=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim")
# The claim-only case is an owned claim with no live runner, so build exactly
# that: kill the runner's group so it cannot run its own cleanup, confirm it is
# gone, and only then drop the registration. Deleting the registration out from
# under a LIVE runner no longer produces this case, because a superseded
# generation now observes the identity mismatch, self-retires, and releases its
# claim - so the sweep would race that exit and see one source or two depending
# on which won.
kill -KILL -"$sweep_pid_two" 2>/dev/null || true
for _ in $(seq 1 50); do kill -0 "$sweep_pid_two" 2>/dev/null || break; sleep 0.1; done
kill -0 "$sweep_pid_two" 2>/dev/null \
  && fail "the claim-only sweep fixture runner did not stop"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" \
  "a killed runner leaves its owned claim behind for the sweep"
rm -f "$HM/state/procevent/sweep-two.source"
out=$(pe "$HM" sweep-home --preflight)
assert_contains "$out" "sweep preflight: ready" "home sweep preflight validates the full bounded snapshot"
assert_present "$HM/state/procevent/sweep-one.source" "home sweep preflight does not remove registrations"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" "home sweep preflight does not release claims"
out=$(pe "$HM" sweep-home)
assert_contains "$out" "swept: attempted=2" "home sweep retires registrations and owned claim-only sources"
for sweep_pid in "$sweep_pid_one" "$sweep_pid_two"; do
  for _ in $(seq 1 40); do kill -0 "$sweep_pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$sweep_pid" 2>/dev/null && fail "home sweep left a runner alive"
done
assert_absent "$HM/state/procevent/sweep-one.source" "home sweep removes registrations"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" "home sweep releases the first claim"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" "home sweep releases a claim with no registration"
pass "bounded home sweep preflights then retires every locally owned source"

HN="$TMP_ROOT/hn"; HO="$TMP_ROOT/ho"; new_home "$HN"; new_home "$HO"
FOREIGN_TRIGGER="$TMP_ROOT/foreign-trigger"
pe_register "$HN" lavish foreign-src -- "$BLOCKER" "$FOREIGN_TRIGGER" "foreign" >/dev/null
pe_register "$HO" lavish foreign-src -- "$BLOCKER" "$FOREIGN_TRIGGER" "foreign" >/dev/null
pe "$HN" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" || fail "foreign-owner fixture did not start"
foreign_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim")
out=$(pe "$HO" sweep-home)
assert_contains "$out" "swept: attempted=1" "home sweep retires the local registration"
kill -0 "$foreign_pid" 2>/dev/null || fail "home sweep signaled a foreign-home runner"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" "home sweep preserves a foreign-home claim"
[ "$(sed -n '1p' "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim")" = "$HN" ] || fail "home sweep changed foreign claim ownership"
assert_absent "$HO/state/procevent/foreign-src.source" "home sweep removes only the local registration"
pe "$HN" retire foreign-src >/dev/null
pass "home sweep leaves foreign-home claims and runners untouched"

HU="$TMP_ROOT/hu"; new_home "$HU"
SWEEP_UNCERTAIN_TRIGGER="$TMP_ROOT/sweep-uncertain-trigger"
pe_register "$HU" lavish sweep-uncertain -- "$BLOCKER" "$SWEEP_UNCERTAIN_TRIGGER" "uncertain" >/dev/null
pe "$HU" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim" || fail "uncertain sweep fixture did not start"
sweep_uncertain_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim")
sweep_status=0
sweep_out=$(PATH="$IDENTITY_FAKEBIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-sweep-proc" \
  pe "$HU" sweep-home 2>&1) || sweep_status=$?
[ "$sweep_status" -ne 0 ] || fail "home sweep succeeded with an uncertain runner identity"
assert_contains "$sweep_out" "home sweep preflight failed" "uncertain home sweep reports a retryable refusal"
kill -0 "$sweep_uncertain_pid" 2>/dev/null || fail "uncertain home sweep signaled the runner"
assert_present "$HU/state/procevent/sweep-uncertain.source" "uncertain home sweep preserves registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim" "uncertain home sweep preserves the claim"
pe "$HU" sweep-home >/dev/null
pass "home sweep refuses safely until runner identity is readable"

HV="$TMP_ROOT/hv"; new_home "$HV"
mkdir -p "$HV/state/procevent-inbox"
printf 'already captured\n' > "$HV/state/procevent-inbox/result-only.1.result"
sup=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$HV/state")
assert_contains "$sup" no "registration-free results do not broaden continuous supervision"
out=$(pe "$HV" sweep-home)
assert_contains "$out" "swept: attempted=0" "result-only homes need no process cleanup"
pass "healthy runtime behavior remains registration-only"

# --- argv boundaries, stderr, exit status, bounds, malformed output ---------
HD="$TMP_ROOT/hd"; new_home "$HD"
TRIG3="$TMP_ROOT/trigger-three"
pe_register "$HD" lavish argv-src -- "$BLOCKER" "$TRIG3" "one arg with spaces" "second; rm -rf /tmp/nope" >/dev/null
pe "$HD" reconcile >/dev/null
: > "$TRIG3"
wait_for "$HD/state/.wake-queue" || fail "argv source published no event"
R=$(first_result "$HD" argv-src || true)
assert_grep 'one arg with spaces' "$R" "an argument containing spaces survives as one argument"
assert_grep 'second; rm -rf /tmp/nope' "$R" "a shell-looking argument is passed literally, never interpreted"
assert_absent /tmp/nope "no shell interpretation occurred"
assert_not_contains "$(wake_payloads "$HD")" "rm -rf" "argv content never reaches the event line"

newline_status=0
newline_out=$(pe_register "$HD" lavish newline-src -- /bin/echo $'first\nsecond' 2>&1) || newline_status=$?
[ "$newline_status" -ne 0 ] || fail "registration accepted an argv element containing a newline"
assert_contains "$newline_out" "cannot contain newlines" "newline rejection explains the unsupported representation"
assert_absent "$HD/state/procevent/newline-src.source" "newline rejection publishes no corrupt registration"
pass "registration rejects unrepresentable newline arguments"

HE="$TMP_ROOT/he"; new_home "$HE"
pe_register "$HE" lavish fail-src -- /bin/sh -c 'exit 7' >/dev/null
out=$(pe "$HE" start fail-src)
assert_contains "$out" "no-result" "a failing source with no output publishes nothing"
[ -z "$(wake_payloads "$HE")" ] || fail "a failing source published an event"
assert_present "$HE/state/procevent/fail-src.source" "a failing source stays registered for retry"
pass "nonzero exit with no output stays armed and silent"

HF="$TMP_ROOT/hf"; new_home "$HF"
# shellcheck disable=SC2016  # single quotes are deliberate: the child shell expands this.
pe_register "$HF" lavish big-src -- /bin/sh -c 'printf "x%.0s" $(seq 1 5000)' >/dev/null
FM_PROCEVENT_MAX_OUTPUT_BYTES=100 FM_HOME="$HF" "$ROOT/bin/fm-procevent.sh" start big-src >/dev/null 2>&1
RB=$(first_result "$HF" big-src || true)
[ -n "$RB" ] || fail "bounded output was not captured at all"
[ "$(wc -c < "$RB" | tr -d ' ')" -le 100 ] || fail "output bound was not enforced"
pass "oversized output is bounded rather than published whole or dropped"

HG="$TMP_ROOT/hg-live"; new_home "$HG"
NOISY="$TMP_ROOT/noisy.sh"
NOISY_PID="$TMP_ROOT/noisy.pid"
cat > "$NOISY" <<'SH'
#!/usr/bin/env bash
trap '' TERM PIPE
printf '%s\n' "$$" > "$1"
while :; do
  printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
done
SH
chmod +x "$NOISY"
pe_register "$HG" lavish noisy-src -- "$NOISY" "$NOISY_PID" >/dev/null
FM_PROCEVENT_MAX_OUTPUT_BYTES=100 pe "$HG" reconcile >/dev/null
wait_for "$NOISY_PID" || fail "noisy source child did not start"
noisy_child=$(cat "$NOISY_PID")
staged=
for _ in $(seq 1 100); do
  for candidate in "$HG/state/procevent"/.noisy-src.*.output; do
    if [ -f "$candidate" ]; then staged=$candidate; break; fi
  done
  [ -n "$staged" ] && break
  sleep 0.1
done
[ -n "$staged" ] || fail "noisy source created no bounded staging file"
sleep 0.2
[ "$(wc -c < "$staged" | tr -d ' ')" -le 100 ] || fail "live staging exceeded the configured output bound"
pe "$HG" retire noisy-src >/dev/null
kill -0 "$noisy_child" 2>/dev/null && fail "TERM-resistant source child survived runner retirement"
assert_absent "$staged" "retirement removes the tracked partial staging file"
pass "live output stays bounded and retirement reaps the whole source group"

# When a fixture never records TERM, capture the claim, leader, group, and
# retirement output to help distinguish a blocked stop from a refused signal.
# Collect this evidence only on the failure path so passing cases stay quiet.
post_term_evidence() {  # <case> <runner-pid> <claim> <signals> <started-epoch> <retire-output>
  local case=$1 runner=$2 claim=$3 signals=$4 started=$5 out=$6
  {
    printf 'post-TERM evidence (%s case)\n' "$case"
    printf '  elapsed since retire started: %ss\n' "$(( $(date +%s) - started ))"
    printf '  identity recorded at claim time: %s\n' "$(sed -n '4p' "$claim" 2>/dev/null || echo '<claim unreadable>')"
    printf '  identity readable now (real ps): %s\n' "$(LC_ALL=C ps -p "$runner" -o lstart= 2>/dev/null || echo '<ps failed>')"
    printf '  signals file: %s (%s bytes)\n' "$signals" "$(wc -c < "$signals" 2>/dev/null | tr -d ' ' || echo 0)"
    printf '  leader state: %s\n' "$(ps -o pid=,ppid=,pgid=,stat= -p "$runner" 2>/dev/null || echo '<leader gone>')"
    printf '  leader wchan: %s\n' "$(ps -o wchan= -p "$runner" 2>/dev/null || echo '<none>')"
    printf '  live members of the runner group:\n'
    ps -Ao pid,ppid,pgid,stat,wchan,command 2>/dev/null | awk -v g="$runner" 'NR==1 || $3==g' | sed 's/^/    /'
    printf '  retire said: %s\n' "${out:-<no output>}"
  } >&2
}

for post_term_case in mismatch unreadable unreadable-pgid nonleader; do
  HPOST_TERM="$TMP_ROOT/post-term-$post_term_case"; new_home "$HPOST_TERM"
  POST_TERM_SOURCE="$HPOST_TERM/source.sh"
  POST_TERM_PID="$HPOST_TERM/child.pid"
  POST_TERM_SIGNALS="$HPOST_TERM/child.signals"
  cat > "$POST_TERM_SOURCE" <<'SH'
#!/usr/bin/env bash
trap 'printf "signalled\n" >> "$2"' TERM
printf '%s\n' "$$" > "$1"
while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
SH
  chmod +x "$POST_TERM_SOURCE"
  POST_TERM_BIN=$(fm_fakebin "$HPOST_TERM/tools")
  REAL_PS=$(command -v ps) || fail "the post-TERM reuse fixture requires ps"
  pe_register "$HPOST_TERM" lavish post-term-src -- \
    "$POST_TERM_SOURCE" "$POST_TERM_PID" "$POST_TERM_SIGNALS" >/dev/null
  FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-post-term-proc" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS=5 pe "$HPOST_TERM" reconcile >/dev/null
  wait_for "$POST_TERM_PID" || fail "the post-TERM reuse fixture did not start"
  wait_for "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim" \
    || fail "the post-TERM reuse fixture did not claim its source"
  POST_TERM_RUNNER=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim")
  # The child can publish its PID before startup releases the source lock.
  # Cross that boundary before suspending the runner, or retirement waits on
  # a stopped lock owner instead of exercising the signal checks below.
  FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-post-term-proc" pe "$HPOST_TERM" list >/dev/null \
    || fail "the post-TERM fixture never finished its source launch"
  kill -STOP "$POST_TERM_RUNNER" || fail "the post-TERM fixture could not keep its leader alive"
  cat > "$POST_TERM_BIN/ps" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = -p ] && [ "\${2-}" = "$POST_TERM_RUNNER" ] \
  && [ "\${3-}" = -o ] && [ "\${4-}" = lstart= ]; then
  if [ "$post_term_case" = mismatch ]; then
    printf 'reused identity\n'
    exit 0
  fi
  [ ! -s "$POST_TERM_SIGNALS" ] || exit 1
fi
if [ "\${1-}" = -o ] && [ "\${2-}" = pgid= ] \
  && [ "\${3-}" = -p ] && [ "\${4-}" = "$POST_TERM_RUNNER" ]; then
  case "$post_term_case" in
    unreadable-pgid) [ ! -s "$POST_TERM_SIGNALS" ] || exit 1 ;;
    nonleader) printf '0\n'; exit 0 ;;
  esac
fi
exec "$REAL_PS" "\$@"
SH
  chmod +x "$POST_TERM_BIN/ps"
  post_term_status=0
  post_term_started=$(date +%s)
  post_term_out=$(PATH="$POST_TERM_BIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-post-term-proc" \
    pe "$HPOST_TERM" retire post-term-src 2>&1) || post_term_status=$?
  case "$post_term_case" in
    mismatch|nonleader)
      assert_absent "$POST_TERM_SIGNALS" "the first signal refuses $post_term_case evidence"
      [ "$post_term_status" -ne 0 ] || fail "retirement escalated despite $post_term_case evidence"
      assert_contains "$post_term_out" "cannot confirm runner identity" \
        "first-signal $post_term_case evidence refuses retirement"
      kill -0 "$POST_TERM_RUNNER" 2>/dev/null \
        || fail "the post-TERM fixture lost its leader instead of exercising $post_term_case evidence"
      kill -0 -"$POST_TERM_RUNNER" 2>/dev/null \
        || fail "a $post_term_case group was killed during escalation"
      assert_present "$HPOST_TERM/state/procevent/post-term-src.source" \
        "first-signal $post_term_case evidence preserves registration"
      assert_present "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim" \
        "first-signal $post_term_case evidence preserves its claim"
      kill -KILL -"$POST_TERM_RUNNER" 2>/dev/null || true
      ;;
    *)
      if [ ! -s "$POST_TERM_SIGNALS" ]; then
        post_term_evidence "$post_term_case" "$POST_TERM_RUNNER" \
          "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim" "$POST_TERM_SIGNALS" \
          "$post_term_started" "$post_term_out"
        fail "the post-TERM fixture never received TERM"
      fi
      [ "$post_term_status" -eq 0 ] \
        || fail "retirement abandoned a proved stop after $post_term_case identity: $post_term_out"
      assert_absent "$HPOST_TERM/state/procevent/post-term-src.source" \
        "proved escalation retires the source after $post_term_case identity"
      assert_absent "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim" \
        "proved escalation releases its claim after $post_term_case identity"
      ;;
  esac
  for _ in $(seq 1 50); do kill -0 -"$POST_TERM_RUNNER" 2>/dev/null || break; sleep 0.1; done
  kill -0 -"$POST_TERM_RUNNER" 2>/dev/null && fail "the post-TERM fixture group survived: $post_term_case"
  pe "$HPOST_TERM" retire post-term-src >/dev/null
  pass "stop $post_term_case evidence preserves the proved-stop boundary"
done

HBAD="$TMP_ROOT/hbad"; new_home "$HBAD"
pe_register "$HBAD" lavish bad-limit -- /bin/true >/dev/null
bad_limit_status=0
bad_limit_out=$(FM_PROCEVENT_MAX_OUTPUT_BYTES=invalid pe "$HBAD" start bad-limit 2>&1) || bad_limit_status=$?
[ "$bad_limit_status" -ne 0 ] || fail "an invalid output bound was accepted"
assert_contains "$bad_limit_out" "must be a nonnegative integer" "invalid output bound reports its contract"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/bad-limit.claim" "invalid output bound leaves no source claim"
pass "invalid output bounds fail closed"

# --- the Lavish adapter uses the published poll shape -----------------------
ART="$TMP_ROOT/artifact.html"
printf '<h1>fixture</h1>\n' > "$ART"
lavish_session "$ART"
sid=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
case "$sid" in lavish-*) : ;; *) fail "adapter source id has an unexpected shape: $sid" ;; esac
sid2=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
[ "$sid" = "$sid2" ] || fail "adapter source id is not stable"
ART_ALIAS="$TMP_ROOT/artifact-alias.html"
ln -s "$ART" "$ART_ALIAS"
sid3=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART_ALIAS")
[ "$sid" = "$sid3" ] || fail "a final-component symlink produced a second source id"
ART_NEWLINE="$TMP_ROOT/line-ending"$'\n'
printf '<h1>newline fixture</h1>\n' > "$ART_NEWLINE"
printf '<h1>sibling fixture</h1>\n' > "$TMP_ROOT/line-ending"
newline_artifact_status=0
newline_artifact_out=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART_NEWLINE" 2>&1) || newline_artifact_status=$?
[ "$newline_artifact_status" -ne 0 ] || fail "Lavish source identity accepted an artifact path ending in a newline"
assert_contains "$newline_artifact_out" "cannot contain newlines" "Lavish rejects newline paths before canonicalization"
pass "the adapter derives physical identity without newline path corruption"

HS="$TMP_ROOT/hs"; new_home "$HS"
mkdir -p "$HS/state/procevent"
: > "$HS/state/procevent/source-only.source"
guard_out=$(FM_ROOT_OVERRIDE="$TMP_ROOT/guard-root" FM_HOME="$HS" FM_GUARD_GRACE=1 \
  "$ROOT/bin/fm-guard.sh" 2>&1)
assert_contains "$guard_out" "WATCHER DOWN - SUPERVISION IS OFF" \
  "the general guard warns when only a process-event source needs supervision"
assert_contains "$guard_out" "1 process-event source(s) registered" \
  "the general guard identifies the source-only supervision need"
pass "source-only homes trigger the general supervision guard"

CLS="$TMP_ROOT/cls"
while IFS='|' read -r status expected; do
  printf 'session:\n  file: /a.html\n  status: %s\n' "$status" > "$CLS"
  out=$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS") \
    || fail "classify failed for handled Lavish status: $status"
  [ "$out" = "$expected" ] \
    || fail "handled Lavish status $status classified as '$out', expected '$expected'"
done <<'EOF'
feedback|feedback
ended|ended
waiting|waiting
browser_disconnected|disconnected
EOF
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{text}:\n  No active Lavish Editor session; code: NOT_FOUND\n' > "$CLS"
[ "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" = feedback ] \
  || fail "prompt text overrode a valid session status"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" missing "an explicit missing session classifies as missing"
printf 'garbage that is not a session block\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" unknown "malformed output classifies as unknown rather than a lifecycle state"
pass "the adapter classifies published poll output safely"

HOST_HOME="$TMP_ROOT/host-config"
mkdir -p "$HOST_HOME/config"
printf '%s\n' '100.99.161.42' > "$HOST_HOME/config/lavish-axi-host"
HOST_ART="$TMP_ROOT/board, '评审'.html"
printf '<h1>session routing</h1>\n' > "$HOST_ART"
HOST_SEEN="$TMP_ROOT/session-route-seen"
HOST_BIN=$(fm_fakebin "$TMP_ROOT/session-route-bin")
cat > "$HOST_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = poll ] || exit 2
printf '%s:%s\n' "${LAVISH_AXI_HOST-unset}" "${LAVISH_AXI_PORT-unset}" >> "$HOST_SEEN"
if [ -n "${HOST_RETRY-}" ] && [ "$(wc -l < "$HOST_SEEN" | tr -d ' ')" = 1 ]; then
  rm -f "$HOST_CONFIG_FILE"
  printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n'
else
  printf 'session:\n  status: ended\n  ended_by: user\n'
fi
SH
chmod +x "$HOST_BIN/lavish-axi"
# Re-reading the session makes its saved endpoint authoritative without a
# Firstmate route record, even when the same artifact is subsequently reopened.
for endpoint in '127.0.0.1:14387' 'board.example:24387' '[::1]:34387'; do
  lavish_session "$HOST_ART" "http://$endpoint/session/0123456789abcdef"
  : > "$HOST_SEEN"
  PATH="$HOST_BIN:$PATH" HOST_SEEN="$HOST_SEEN" LAVISH_AXI_HOST=wrong.example \
    LAVISH_AXI_PORT=44387 FM_HOME="$HOST_HOME" \
    "$ROOT/bin/fm-procevent-lavish.sh" poll "$HOST_ART" >/dev/null
  expected=${endpoint//\[/}; expected=${expected//\]/}
  [ "$(cat "$HOST_SEEN")" = "$expected" ] \
    || fail "poll did not derive the endpoint from the Unicode-path board session"
done
pass "poll derives host and port from the artifact session, not ambient or configured routing"

lavish_session "$HOST_ART"
: > "$HOST_SEEN"
PATH="$HOST_BIN:$PATH" HOST_SEEN="$HOST_SEEN" HOST_RETRY=1 \
  HOST_CONFIG_FILE="$HOST_HOME/config/lavish-axi-host" LAVISH_AXI_HOST=ambient.example \
  LAVISH_AXI_PORT=44387 FM_LAVISH_POLL_RETRY_DELAY=1 FM_HOME="$HOST_HOME" \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$HOST_ART" >/dev/null
printf '%s\n%s\n' '127.0.0.1:14387' '127.0.0.1:14387' > "$HOST_HOME/expected"
cmp -s "$HOST_HOME/expected" "$HOST_SEEN" \
  || fail "a retry switched away from the session server after config removal"
pass "quiet retries use the board session regardless of configuration changes"

# Route lookup is read-only and precedes reply consumption. Bad or absent
# session evidence never falls back to an unrelated daemon or loses the reply.
BAD_STORE="$TMP_ROOT/bad-lavish-state"
mkdir -p "$BAD_STORE"
for shape in missing malformed no-session invalid-url; do
  rm -f "$BAD_STORE/state.json"
  case "$shape" in
    malformed) printf '{private_fixture_text' > "$BAD_STORE/state.json" ;;
    no-session) printf '{"sessions":{}}\n' > "$BAD_STORE/state.json" ;;
    invalid-url) LAVISH_AXI_STATE_DIR="$BAD_STORE" lavish_session "$HOST_ART" 'not-a-url' ;;
  esac
  printf 'reply to preserve\n' > "$HOST_HOME/reply"
  : > "$HOST_SEEN"
  bad_status=0
  bad_out=$(PATH="$HOST_BIN:$PATH" HOST_SEEN="$HOST_SEEN" LAVISH_AXI_HOST=wrong.example \
    LAVISH_AXI_STATE_DIR="$BAD_STORE" FM_HOME="$HOST_HOME" \
    "$ROOT/bin/fm-procevent-lavish.sh" poll "$HOST_ART" \
    --agent-reply-file "$HOST_HOME/reply" 2>&1) || bad_status=$?
  [ "$bad_status" -ne 0 ] || fail "$shape session evidence was accepted"
  [ ! -s "$HOST_SEEN" ] || fail "$shape session evidence reached the CLI"
  [ "$(cat "$HOST_HOME/reply")" = 'reply to preserve' ] \
    || fail "$shape session evidence consumed the staged reply"
  assert_not_contains "$bad_out" private_fixture_text "JSON errors must not print session content"
done
pass "missing or unreadable session routing preserves replies and never guesses another server"

# The adapter, not the runner, decides which results end a Lavish source. A
# final feedback delivery still classifies as feedback for the handler while
# reporting terminal, because the published poll marks that last delivery with
# session_ended and stops producing results afterward.
TRM="$TMP_ROOT/terminal-verdict"
printf 'session:\n  file: /a.html\n  status: feedback\n  session_ended: true\n  ended_by: user\n' > "$TRM"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$TRM")" feedback \
  "a final feedback delivery still classifies as feedback for the handler"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  || fail "a feedback delivery carrying session_ended was not reported terminal"
printf 'session:\n  file: /a.html\n  status: feedback\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  && fail "an ordinary feedback delivery was reported terminal"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" || fail "an ended session was not reported terminal"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" || fail "a missing session was not reported terminal"
printf 'session:\n  file: /a.html\n  status: waiting\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" && fail "a waiting session was reported terminal"
printf 'session:\n  file: /a.html\n  status: browser_disconnected\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  && fail "a browser-disconnected session was reported terminal"
printf 'garbage that is not a session block\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" && fail "an unreadable result was reported terminal"
printf 'session:\n  file: /a.html\n  status: feedback\nfeedback[1]{text}:\n  session_ended: true\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  && fail "prompt payload text was read as a session-level terminal marker"
pass "the adapter owns which Lavish results end a source, and payload text cannot forge one"

# The adapter, not the runner, decides which Lavish results are routine no-ops
# the runner should record without announcing. Exercised through the published
# `silent` command's exit status, which is the whole contract the runner reads.
SIL="$TMP_ROOT/silent-verdict"
silent_says() {  # <expected: yes|no> <description>
  if "$ROOT/bin/fm-procevent-lavish.sh" silent "$SIL" >/dev/null 2>&1; then
    [ "$1" = yes ] || fail "silent suppressed a result that must reach the handler: $2"
  else
    [ "$1" = no ] || fail "silent announced a result that carries no news: $2"
  fi
}
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
silent_says yes "an ended session carrying nothing is an empty board close"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[0]{tag,text}:\n' > "$SIL"
silent_says no "a declared-empty content block is still present"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[many]{tag,text}:\n' > "$SIL"
silent_says no "a malformed top-level content header is indeterminate"
printf 'session:\n  file: /a.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' > "$SIL"
silent_says no "a Send & End close carrying the captain's answer is news"
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{tag,text}:\n  "message","some prose"\n' > "$SIL"
silent_says no "a freeform captain message is news"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[1]{tag,text}:\n  "choice","late answer"\n' > "$SIL"
silent_says no "an ended session still carrying content is never assumed empty"
printf 'session:\n  file: /a.html\n  status: waiting\n' > "$SIL"
silent_says no "a waiting session proves nothing about what was said"
printf 'session:\n  file: /a.html\n  status: browser_disconnected\n' > "$SIL"
silent_says yes "a browser disconnect carries no answer and keeps the session open"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$SIL"
silent_says no "a missing session is not a no-op"
printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n' > "$SIL"
silent_says no "a server error is not a no-op"
printf 'garbage that is not a session block\n' > "$SIL"
silent_says no "an unreadable result fails closed and is announced"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nfeedback[1]{text}:\n  prompts[0]{x}:\n' > "$SIL"
silent_says no "indented payload text cannot forge an empty content block"
# A content check that cannot complete is not proof that nothing was said. Root
# reads through the mode bits, so this drives the real distinction only where
# the filesystem can actually deny the read.
if [ "$(id -u)" != 0 ]; then
  printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
  chmod 000 "$SIL"
  silent_says no "a content check that cannot complete announces rather than assuming silence"
  chmod 600 "$SIL"
fi
pass "the adapter owns which Lavish results are silent, and fails closed on everything else"

# `read` is the handler's presentation of a captured result. Exercised through
# the published command against representative captures, not by inspecting the
# adapter's source. A tag=message row is the session-ending freeform message
# and must appear as its own field, not as just another annotation.
READ="$TMP_ROOT/read-result"
read_out() { "$ROOT/bin/fm-procevent-lavish.sh" read "$READ"; }
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[4]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
  "el-b","","section#call > h1",note,"Headline pick"
  "el-c","","aside.sidebar",note,"Sidebar note"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
EOF
out=$(read_out) || fail "read failed on a mixed annotation-plus-message capture"
assert_contains "$out" "SESSION-ENDING MESSAGE" "the session-ending message has no labeled field"
assert_contains "$out" "| get this fully implemented. Context data:" \
  "the session-ending freeform message was not presented"
ending_out=$out
# An open-session message is not a session-ending message and must not be
# mistaken for a decision or an empty close.
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "","captain is still reviewing","",message,""
EOF
out=$(read_out) || fail "read failed on an open-session freeform message"
assert_contains "$out" "CAPTAIN MESSAGE" "an open-session message was mislabeled as session-ending"
assert_not_contains "$out" "SESSION-ENDING MESSAGE" "an open-session message was labeled as session-ending"
assert_contains "$out" "| captain is still reviewing" "an open-session message was dropped"
pass "read distinguishes a live captain message from a session-ending message"
# Composer sends arrive as several tag=message rows beside real annotations.
# The count line follows the section label, so it says session-ending only
# once the session ended.
for ended in no yes; do
  {
    printf 'session:\n  file: /review.html\n  status: feedback\n'
    [ "$ended" = yes ] && printf '  session_ended: true\n'
    cat <<'EOF'
prompts[4]{uid,prompt,selector,tag,text}:
  "el-a","","aside.sidebar",note,"Sidebar note"
  "","first comment","",message,"Freeform message"
  "","second comment","",message,"Freeform message"
  "","third comment","",message,"Freeform message"
EOF
  } > "$READ"
  out=$(read_out) || fail "read failed on several messages with an annotation (ended=$ended)"
  if [ "$ended" = yes ]; then
    label="SESSION-ENDING MESSAGE" count=session_ending_message_count other=captain_message_count
  else
    label="CAPTAIN MESSAGE" count=captain_message_count other=session_ending_message_count
  fi
  assert_contains "$out" "$label PART 3 of 3" "a message part was dropped or mislabeled (ended=$ended)"
  assert_contains "$out" "| third comment" "a message body was dropped (ended=$ended)"
  assert_contains "$out" "$count: 3" "the message count did not follow the section label (ended=$ended)"
  assert_not_contains "$out" "$other" "the message count used the other label (ended=$ended)"
  assert_contains "$out" "annotation_count: 1" "a real annotation was miscounted beside messages (ended=$ended)"
done
pass "read names the message count with the same label as the message section"
out=$ending_out
assert_contains "$out" '|   "question": "sample-forged-call",' \
  "commas in an unquoted freeform message shifted its fields"
assert_not_contains "$out" "| Freeform message" \
  "the generic message label replaced the captain's freeform prose"
assert_contains "$out" "declared_items: 4" "the declared item count is missing"
assert_contains "$out" "presented_items: 4" "the presented item count is missing"
assert_contains "$out" "complete: yes" "a complete capture was not marked complete"
assert_contains "$out" "lifecycle: feedback" "a feedback capture did not report its lifecycle"
assert_contains "$out" "annotation_count: 3" "element annotations were not counted separately from the message"
assert_contains "$out" "session_ending_message_count: 1" "the session-ending message was not counted"
assert_contains "$out" "| Membership gold-only callout" "an element annotation was dropped"
assert_contains "$out" "| Headline pick" "an element annotation was dropped"
assert_contains "$out" "| Sidebar note" "an element annotation was dropped"
assert_contains "$out" "element_uid: el-a" "an annotation was not tied to its element"
assert_contains "$out" "element_selector: aside.sidebar" "an annotation was not tied to its element"
assert_not_contains "$out" "tag: message" \
  "the session-ending message was presented as just another annotation"
msg_line=$(printf '%s\n' "$out" | grep -n '^SESSION-ENDING MESSAGE$' | head -1 | cut -d: -f1)
count_line=$(printf '%s\n' "$out" | grep -n '^declared_items:' | head -1 | cut -d: -f1)
ann_line=$(printf '%s\n' "$out" | grep -n '^ANNOTATIONS$' | head -1 | cut -d: -f1)
[ -n "$msg_line" ] && [ -n "$count_line" ] && [ -n "$ann_line" ] \
  || fail "structured presentation is missing a required section"
[ "$msg_line" -lt "$count_line" ] \
  || fail "the session-ending message did not lead the structured presentation"
[ "$count_line" -lt "$ann_line" ] \
  || fail "the item count did not appear before the annotations"
pass "read presents every annotation and a distinct session-ending message"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[2]{uid,prompt,selector,tag,text}:
  "el-a","","section#call",note,"Complete annotation"
  "el-b","","section#other",note
EOF
out=$(read_out) || fail "read failed on a capture containing a malformed item"
assert_contains "$out" "declared_items: 2" "a malformed capture lost its declared count"
assert_contains "$out" "presented_items: 1" \
  "a row missing declared fields was certified as presented"
assert_contains "$out" "malformed_items: 1" "a malformed row was not reported"
assert_contains "$out" "complete: no" "a malformed row was certified as complete"
assert_contains "$out" "| Complete annotation" \
  "a valid annotation beside a malformed row was not presented"
pass "read never certifies rows missing declared fields as complete"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[3]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
  "el-b","","section#call > h1",note,"Headline pick"
  "el-c","","aside.sidebar",note,"Sidebar note"
EOF
out=$(read_out) || fail "read failed on an annotations-only capture"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "a capture with no freeform message still invented a session-ending field body"
assert_contains "$out" "declared_items: 3" "the declared item count is missing when there is no message"
assert_contains "$out" "presented_items: 3" "not every annotation was presented when there is no message"
assert_contains "$out" "complete: yes" "an annotations-only capture was not marked complete"
assert_contains "$out" "annotation_count: 3" "annotations were dropped when the freeform message is absent"
assert_contains "$out" "| Membership gold-only callout" "an element annotation was dropped when there is no message"
assert_contains "$out" "| Headline pick" "an element annotation was dropped when there is no message"
assert_contains "$out" "| Sidebar note" "an element annotation was dropped when there is no message"
assert_contains "$out" "session_ending_message_count: 0" \
  "an absent freeform message was counted as present"
assert_not_contains "$out" $'\nprompt:\n' \
  "a capture with no typed comments invented a comment field"
assert_not_contains "$out" "CAPTAIN FINAL DECISION" "a prior capture leaked into the next read"
pass "read keeps every annotation when the session-ending message is absent"

# Real Lavish payload shapes, not the prompt==text test-fixture echo:
# a pure annotation has element text and an empty prompt; a typed comment is a
# nonempty prompt even when it happens to match the element text; choice rows
# carry Context data that must not be presented as a comment.
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-n1","are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie","section#n1 > div",div,"Deterministic tie-break for ambiguous model ids (N1)MY PICK"
EOF
out=$(read_out) || fail "read failed on an annotate-plus-comment capture"
assert_contains "$out" $'\nprompt:\n' \
  "a typed comment on an annotated element was not a field of its own"
assert_contains "$out" "are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie" \
  "a typed comment on an annotated element was dropped"
assert_contains "$out" "| Deterministic tie-break for ambiguous model ids (N1)MY PICK" \
  "the annotated element text was dropped when a comment was also present"
assert_contains "$out" "element_selector: section#n1 > div" \
  "the annotated element selector was dropped when a comment was also present"
assert_contains "$out" "tag: div" "the annotated element tag was dropped when a comment was also present"
assert_contains "$out" "ANNOTATION 1 of 1" "an annotate-plus-comment item was not presented as an annotation"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "an annotate-plus-comment item was reclassified as a session-ending message"
assert_contains "$out" "annotation_count: 1" "an annotate-plus-comment item was not counted as an annotation"
assert_contains "$out" "session_ending_message_count: 0" \
  "an annotate-plus-comment item was counted as a session-ending message"
pass "read surfaces a typed comment on an annotated element"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-n1","Use subscription quota","section#n1 > div",div,"Use subscription quota"
EOF
out=$(read_out) || fail "read failed on an equal-text annotate-plus-comment capture"
assert_contains "$out" $'text:\n| Use subscription quota\nprompt:\n| Use subscription quota' \
  "a typed comment identical to the element text was dropped"
pass "read still surfaces a typed comment that matches the element text"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
EOF
out=$(read_out) || fail "read failed on a pure-annotation capture"
assert_contains "$out" "| Membership gold-only callout" \
  "a pure annotation no longer showed the element"
assert_contains "$out" "element_selector: section#call > p:nth-of-type(1)" \
  "a pure annotation lost its selector"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "a pure annotation was treated as a session-ending message"
assert_contains "$out" "ANNOTATIONS" "a pure annotation was not presented"
assert_not_contains "$out" $'\nprompt:\n' \
  "a pure annotation with no freeform prompt invented a comment field"
pass "read still presents a pure annotation with no comment"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-choice","Context data: {\"question\":\"quota-source\",\"answer\":\"subscription\"}","section#quota > button",choice,"Subscription quota"
EOF
out=$(read_out) || fail "read failed on a choice capture"
assert_contains "$out" "| Subscription quota" \
  "a choice row no longer showed its element text"
assert_contains "$out" "tag: choice" "a choice row lost its type"
assert_not_contains "$out" "Context data:" \
  "a choice row surfaced machine-generated context as a comment"
assert_not_contains "$out" $'\nprompt:\n' \
  "a choice row gained a freeform comment field"
pass "read does not present choice context as a comment"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "","are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie","",message,Freeform message
EOF
out=$(read_out) || fail "read failed on a pure-message capture"
assert_contains "$out" "SESSION-ENDING MESSAGE" "a pure message lost its labeled field"
assert_contains "$out" "| are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie" \
  "a pure message dropped the typed comment"
assert_contains "$out" "ANNOTATIONS: (none)" "a pure message was presented as an annotation"
assert_contains "$out" "session_ending_message_count: 1" "a pure message was not counted"
assert_contains "$out" "annotation_count: 0" "a pure message was counted as an annotation"
assert_not_contains "$out" "tag: message" \
  "a pure message was presented as just another annotation"
pass "read still presents a pure message with no selector"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
feedback[1]{text}:
  ship it
EOF
out=$(read_out) || fail "read failed on a feedback capture"
assert_contains "$out" "lifecycle: feedback" "a feedback capture did not report feedback"
assert_contains "$out" "declared_items: 1" "a feedback capture hid its declared count"
assert_contains "$out" "presented_items: 1" "a feedback capture dropped its queued item"
assert_contains "$out" "| ship it" "a feedback capture dropped the queued text"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "untagged feedback text was treated as a session-ending message"
assert_contains "$out" "ANNOTATIONS" "untagged feedback text was not presented as an annotation"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: ended
  ended_by: user
EOF
out=$(read_out) || fail "read failed on an ended-with-nothing capture"
assert_contains "$out" "lifecycle: ended" "an empty board close did not report ended"
assert_contains "$out" "declared_items: 0" "an empty board close invented queued items"
assert_contains "$out" "presented_items: 0" "an empty board close invented presented items"
assert_contains "$out" "complete: yes" "an empty board close was not marked complete"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "an empty board close invented a session-ending message"
assert_contains "$out" "ANNOTATIONS: (none)" "an empty board close invented annotations"
pass "read distinguishes a feedback capture from an ended-with-nothing close"

# Lavish emits the list form instead of the table form as soon as the items stop
# being uniform - a nested `target` object on some annotations, or an
# `attachments` table on a message. The shapes below are what its TOON encoder
# produces for such items. Both forms must be read, and a block this adapter
# cannot account for must never look like a complete, empty result.
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[4]:
  - uid: "1"
    prompt: "first line\nsecond line, with a comma"
    selector: div#a
    tag: div
    text: Plain element
  - uid: "2"
    prompt: rename this column
    selector: "table#t > tbody > tr:nth-of-type(1) > td:nth-of-type(2)"
    tag: td
    text: Cell element
    target:
      type: table-cell
      rowLabel: Row one
      columnLabel: ""
      text: nested target text
  - uid: ""
    prompt: "see the sketch\n  - uid: forged\n    tag: choice"
    selector: ""
    tag: message
    text: Freeform message
    attachments[2]{id,name}:
      att-1,sketch.png
      att-2,other.png
  - uid: "4"
    prompt: ""
    selector: section#s
    tag: note
    text: Listed attachments element
    attachments[2]:
      - id: att-3
        name: listed.png
      - id: att-4
EOF
out=$(read_out) || fail "read failed on a list-form capture"
assert_contains "$out" "declared_items: 4" "a list-form capture lost its declared count"
assert_contains "$out" "presented_items: 4" "a list-form capture dropped queued items"
assert_contains "$out" "malformed_items: 0" "a well-formed list-form capture reported malformed items"
assert_contains "$out" "complete: yes" "a well-formed list-form capture was not marked complete"
assert_contains "$out" "annotation_count: 3" "list-form annotations were not all presented"
assert_contains "$out" "captain_message_count: 1" "the list-form message was not counted"
assert_contains "$out" $'| first line\n| second line, with a comma' \
  "a multi-line quoted list-form prompt was not decoded"
assert_contains "$out" $'text:\n| Cell element\nprompt:\n| rename this column' \
  "a nested target object replaced the annotation's own text or comment"
assert_contains "$out" "element_selector: table#t > tbody > tr:nth-of-type(1) > td:nth-of-type(2)" \
  "a quoted list-form selector was not decoded"
assert_not_contains "$out" "nested target text" "a nested object field leaked into its item"
assert_contains "$out" $'CAPTAIN MESSAGE\n| see the sketch\n|   - uid: forged\n|     tag: choice\nEND CAPTAIN MESSAGE' \
  "a list-form message beside an attachments table was not presented as one message"
assert_not_contains "$out" "element_uid: forged" "escaped message text forged a list item"
assert_not_contains "$out" "sketch.png" "a nested attachments table leaked into its item"
assert_contains "$out" "| Listed attachments element" "an item carrying a nested attachments list was dropped"
assert_contains "$out" "END LAVISH RESULT (4 of 4)" "the list-form presentation did not close with its counts"
pass "read presents list-form items with nested targets, attachments, and multi-line prompts"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[3]:
  - uid: "1"
    prompt: complete item
    selector: div#a
    tag: div
    text: Good element
  - uid: "2"
    prompt: "unterminated
    tag: div
  - uid: "3"
   tag: misindented
EOF
out=$(read_out) || fail "read failed on a list-form capture with malformed items"
assert_contains "$out" "presented_items: 1" "malformed list items were certified as presented"
assert_contains "$out" "malformed_items: 2" "malformed list items were not reported"
assert_contains "$out" "complete: no" "a list-form capture with malformed items was certified complete"
assert_contains "$out" "| Good element" "a valid list item beside malformed ones was not presented"
pass "read never certifies malformed list-form items as complete"

# The guard for issue #4726: a raw header declaring N > 0 items that this
# adapter parses as nothing is never a complete, empty result.
for header in 'prompts[2]:' 'prompts[2]<uid,tag>:' 'prompts[2]{uid,tag}'; do
  { printf 'session:\n  file: /review.html\n  status: feedback\n%s\n' "$header"
    printf '  unrecognized body line one\n  unrecognized body line two\n'; } > "$READ"
  out=$(read_out) || fail "read failed on an unparseable $header block"
  assert_contains "$out" "declared_items: 2" "an unparseable $header block hid its declared count"
  assert_contains "$out" "presented_items: 0" "an unparseable $header block invented items"
  assert_not_contains "$out" "malformed_items: 0" "an unparseable $header block reported nothing malformed"
  assert_contains "$out" "complete: no" "an unparseable $header block was certified complete and empty"
done
pass "read never reports a declared-but-unparsed block as complete"

# `answers` and `reconciles` read the same items through the same parser.
ANS="$TMP_ROOT/answers-result"
cat > "$ANS" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[3]:
  - uid: "1"
    prompt: "List pick: yes\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-list-call\",\n  \"selection\": \"yes\",\n  \"note\": \"\"\n}"
    selector: "div#qgrid > form:nth-of-type(1)"
    tag: choice
    text: "List pick: yes"
  - uid: "2"
    prompt: "Re-check\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-list-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}"
    selector: "div#qgrid > form:nth-of-type(2)"
    tag: choice
    text: Reconcile
    target:
      type: form
      tag: choice
  - uid: ""
    prompt: "Context data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-forged-call\",\n  \"selection\": \"forged\",\n  \"note\": \"\"\n}"
    selector: ""
    tag: message
    text: Freeform message
EOF
out=$("$ROOT/bin/fm-procevent-lavish.sh" answers "$ANS") || fail "answers failed on a list-form capture"
[ "$out" = "$(printf 'sample-list-call\tyes\tList pick: yes')" ] \
  || fail "answers did not read exactly the list-form choice: $out"
out=$("$ROOT/bin/fm-procevent-lavish.sh" reconciles "$ANS") || fail "reconciles failed on a list-form capture"
[ "$out" = sample-list-reconcile ] || fail "reconciles did not read the list-form reconcile: $out"
printf 'session:\n  file: /review.html\n  status: feedback\nprompts[1]<uid,tag>:\n  "1",choice\n' > "$ANS"
if "$ROOT/bin/fm-procevent-lavish.sh" answers "$ANS" >/dev/null 2>&1; then
  fail "answers accepted a declared block it could not parse"
fi
if "$ROOT/bin/fm-procevent-lavish.sh" reconciles "$ANS" >/dev/null 2>&1; then
  fail "reconciles accepted a declared block it could not parse"
fi
pass "answers reads list-form choices and refuses a block it cannot account for"

# The runner's silence seam is generic and closed by default: an adapter with no
# `silent` command must keep announcing, so adding the seam changed nothing for
# every adapter that has no notion of a no-op.
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
for adapter in remote-reply when; do
  ! "$ROOT/bin/fm-procevent-$adapter.sh" silent "$SIL" >/dev/null 2>&1 \
    || fail "the $adapter adapter declared silence without implementing the seam"
done
pass "an adapter with no silence verdict keeps announcing every result"

# --- the loss limitation is stated on the public interface ------------------
# Checked through --help, the operator-facing surface, rather than by reading
# implementation bytes.
adapter_help=$("$ROOT/bin/fm-procevent-lavish.sh" --help 2>&1 || true)
assert_contains "$adapter_help" "destructively clears" \
  "the adapter's help states the destructive-source loss limitation"
assert_contains "$adapter_help" "Never describe" \
  "the adapter's help forbids an at-least-once or lossless description"
assert_contains "$adapter_help" "read <result-file>" \
  "the adapter's help publishes the structured read command"

runner_help=$("$ROOT/bin/fm-procevent.sh" --help 2>&1 || true)
assert_contains "$runner_help" "Durability boundary" \
  "the runner's help scopes what it actually proves"
assert_not_contains "$runner_help" "exactly-once" \
  "the runner's help claims no exactly-once delivery"
pass "the published interfaces state the loss limitation and claim no lossless delivery"

# --- launch pacing and guard startup ----------------------------------------

FAST_SOURCE="$TMP_ROOT/fast-source.sh"
cat > "$FAST_SOURCE" <<'SH'
#!/usr/bin/env bash
perl -MTime::HiRes=time -e 'printf "%.6f\n", time' >> "$1"
exit 1
SH
chmod +x "$FAST_SOURCE"

STORM_SOURCE="$TMP_ROOT/storm-source.sh"
cat > "$STORM_SOURCE" <<'SH'
#!/usr/bin/env bash
perl -MTime::HiRes=time -e 'printf "%.6f\n", time' >> "$1"
FM_HOME="$2" perl -MPOSIX=setsid -e '
  my @command = @ARGV;
  defined(my $pid = fork) or exit 1;
  exit 0 if $pid;
  setsid() >= 0 or exit 1;
  open STDIN, "<", "/dev/null" or exit 1;
  open STDOUT, ">", "/dev/null" or exit 1;
  open STDERR, ">", "/dev/null" or exit 1;
  select undef, undef, undef, 0.2;
  exec @command;
' "$3/bin/fm-procevent.sh" reconcile
exit 1
SH
chmod +x "$STORM_SOURCE"

HFLOOR="$TMP_ROOT/launch-floor"; new_home "$HFLOOR"
fm_test_track_procevent_home "$HFLOOR"
pe_register "$HFLOOR" lavish floor-src -- \
  "$STORM_SOURCE" "$TMP_ROOT/launch-times" "$HFLOOR" "$ROOT"
# Pacing, not lease expiry, is under test here. Give the orphan lease headroom
# over the nominal sample wait so slow launches do not kill the fixture before
# its third sample. Count polls rather than wall time so scheduling delays stretch
# the wait, then retire immediately instead of running beside the other cases.
FM_PROCEVENT_OWNER_LEASE_SECONDS=600 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 pe "$HFLOOR" reconcile >/dev/null
wait_for_lines "$TMP_ROOT/launch-times" 3 600 \
  || fail "the orphan-storm fixture did not produce three launch samples"
pe "$HFLOOR" retire floor-src >/dev/null
launch_count=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
launch_span=$(perl -e '@t=<>; printf "%.3f", $t[-1] - $t[0]' "$TMP_ROOT/launch-times")
perl -e 'exit($ARGV[0] >= ($ARGV[1] - 1) * 0.8 ? 0 : 1)' "$launch_span" "$launch_count" \
  || fail "an orphaned source launched $launch_count times in only ${launch_span}s"
[ "$launch_count" -le 6 ] \
  || fail "an orphaned source stormed $launch_count launches during its owner-dead grace window"
pass "an orphaned source command obeys the launch floor during its grace window"

HPACE="$TMP_ROOT/registration-pacing"; new_home "$HPACE"
fm_test_track_procevent_home "$HPACE"
PACE_LOG="$TMP_ROOT/registration-pacing.log"
pe_register "$HPACE" lavish pace-src -- "$FAST_SOURCE" "$PACE_LOG" >/dev/null
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3600 pe "$HPACE" start pace-src >/dev/null
pe "$HPACE" retire pace-src >/dev/null
pe_register "$HPACE" lavish pace-src -- "$FAST_SOURCE" "$PACE_LOG" >/dev/null
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3600 pe "$HPACE" start pace-src > "$TMP_ROOT/replacement-pacing.out" 2>&1 &
PACE_START_PID=$!
pace_deadline=$((SECONDS + 4))
while kill -0 "$PACE_START_PID" 2>/dev/null; do
  if [ "$SECONDS" -ge "$pace_deadline" ]; then
    pe "$HPACE" retire pace-src >/dev/null 2>&1 || true
    wait "$PACE_START_PID" 2>/dev/null || true
    fail "a replacement registration inherited the prior launch floor"
  fi
  sleep 0.1
done
wait "$PACE_START_PID" || fail "the replacement registration failed"
[ "$(wc -l < "$PACE_LOG" | tr -d ' ')" = 2 ] \
  || fail "a replacement registration did not launch immediately"
PACE_STAMPS=$(find "$HPACE/state/procevent" -maxdepth 1 -type f \
  -name 'pace-src.*.last-launch' | wc -l | tr -d ' ')
[ "$PACE_STAMPS" = 1 ] || fail "replacement registrations accumulated stale pacing state"
pass "a replacement registration starts with one fresh launch floor"

HPACE_RACE="$TMP_ROOT/registration-pacing-race"; new_home "$HPACE_RACE"
fm_test_track_procevent_home "$HPACE_RACE"
PACE_RACE_LOG="$TMP_ROOT/registration-pacing-race.log"
pe_register "$HPACE_RACE" lavish pace-race-src -- "$FAST_SOURCE" "$PACE_RACE_LOG" >/dev/null
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3 pe "$HPACE_RACE" start pace-race-src >/dev/null
# The superseded runner sleeps out its whole floor before it rechecks the
# registration, so the floor must outlast the claim wait and re-registration
# below even on a loaded machine; a 3s floor let the stale command launch.
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=15 \
  pe "$HPACE_RACE" start pace-race-src > "$TMP_ROOT/registration-pacing-race.out" 2>&1 &
PACE_RACE_PID=$!
wait_for "$FM_PROCEVENT_CLAIM_ROOT/pace-race-src.claim" \
  || fail "the superseded pacing fixture did not claim its registration"
[ "$(wc -l < "$PACE_RACE_LOG" | tr -d ' ')" = 1 ] \
  || fail "the superseded pacing fixture was not waiting on its launch floor"
pe_register "$HPACE_RACE" lavish pace-race-src -- "$FAST_SOURCE" "$PACE_RACE_LOG" >/dev/null
wait "$PACE_RACE_PID" || fail "the superseded paced runner failed"
[ "$(wc -l < "$PACE_RACE_LOG" | tr -d ' ')" = 1 ] \
  || fail "the superseded paced runner invoked its stale command"
# The runner marker is written before the launch floor is waited on, and a home
# sweep counts a marker with no owned claim as a preflight failure. A superseded
# generation that exits without clearing its marker therefore makes the whole
# home refuse to sweep, so assert the marker is gone and the sweep still runs.
assert_absent "$HPACE_RACE/state/procevent/pace-race-src.runner" \
  "a superseded paced runner leaves no runner marker behind"
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3 pe "$HPACE_RACE" start pace-race-src >/dev/null
PACE_RACE_STAMPS=$(find "$HPACE_RACE/state/procevent" -maxdepth 1 -type f \
  -name 'pace-race-src.*.last-launch' | wc -l | tr -d ' ')
[ "$PACE_RACE_STAMPS" = 1 ] \
  || fail "a superseded sleeping runner recreated stale pacing state"
pass "a superseded sleeping runner cannot recreate stale pacing state"

HCOMMIT="$TMP_ROOT/registration-commit"; new_home "$HCOMMIT"
fm_test_track_procevent_home "$HCOMMIT"
COMMIT_LOG="$TMP_ROOT/registration-commit.log"
mkdir -p "$HCOMMIT/state/procevent/commit-src.1-2.last-launch"
pe_register "$HCOMMIT" lavish commit-src -- "$FAST_SOURCE" "$COMMIT_LOG" >/dev/null \
  || fail "post-commit pacing cleanup made registration report failure"
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 pe "$HCOMMIT" start commit-src >/dev/null \
  || fail "a successfully published registration was not executable"
[ "$(wc -l < "$COMMIT_LOG" | tr -d ' ')" = 1 ] \
  || fail "the committed registration did not invoke its source"
pass "post-commit pacing cleanup cannot veto registration publication"

HROLLBACK="$TMP_ROOT/rollback-pacing"; new_home "$HROLLBACK"
fm_test_track_procevent_home "$HROLLBACK"
ROLLBACK_LOG="$TMP_ROOT/rollback-pacing.log"
pe_register "$HROLLBACK" lavish rollback-src -- "$FAST_SOURCE" "$ROLLBACK_LOG" >/dev/null
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 pe "$HROLLBACK" start rollback-src >/dev/null
ROLLBACK_STAMP=
for candidate in "$HROLLBACK/state/procevent"/rollback-src.*.last-launch; do
  [ -f "$candidate" ] && ROLLBACK_STAMP=$candidate
done
[ -n "$ROLLBACK_STAMP" ] || fail "the first launch did not persist its pacing state"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$ROLLBACK_STAMP"
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3600 pe "$HROLLBACK" start rollback-src > "$TMP_ROOT/rollback.out" 2>&1 &
ROLLBACK_START_PID=$!
rollback_deadline=$((SECONDS + 4))
while kill -0 "$ROLLBACK_START_PID" 2>/dev/null; do
  if [ "$SECONDS" -ge "$rollback_deadline" ]; then
    pe "$HROLLBACK" retire rollback-src >/dev/null 2>&1 || true
    wait "$ROLLBACK_START_PID" 2>/dev/null || true
    fail "a pre-reboot monotonic stamp delayed the first launch"
  fi
  sleep 0.1
done
wait "$ROLLBACK_START_PID" || fail "the rollback-paced source failed"
[ "$(wc -l < "$ROLLBACK_LOG" | tr -d ' ')" = 2 ] \
  || fail "the rollback-paced source did not invoke twice"
pass "a pre-reboot monotonic stamp is treated as expired"

storm_deadline=$((SECONDS + 15))
while :; do
  storm_before=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
  sleep 2
  storm_after=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
  [ "$storm_before" = "$storm_after" ] && break
  [ "$SECONDS" -lt "$storm_deadline" ] \
    || fail "an orphaned self-relaunching source survived its expired owner lease"
done
pass "an expired owner lease stops a self-relaunching source generation"

HRECREATED="$TMP_ROOT/recreated-owner"; new_home "$HRECREATED"
fm_test_track_procevent_home "$HRECREATED"
RECREATED_TRIGGER="$TMP_ROOT/recreated-owner.trigger"
pe_register "$HRECREATED" lavish recreated-src -- \
  "$BLOCKER" "$RECREATED_TRIGGER" "recreated payload" >/dev/null
FM_PROCEVENT_OWNER_LEASE_SECONDS=30 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  pe "$HRECREATED" reconcile >/dev/null
wait_for "$HRECREATED/state/procevent/recreated-src.runner" \
  || fail "the recreated-path fixture never launched its source"
RECREATED_RUNNER_PID=$(cat "$HRECREATED/state/procevent/recreated-src.runner")
mv "$HRECREATED/state" "$TMP_ROOT/recreated-owner-old-state"
pe_register "$HRECREATED" lavish recreated-src -- \
  "$BLOCKER" "$RECREATED_TRIGGER" "replacement payload" >/dev/null
FM_PROCEVENT_OWNER_LEASE_SECONDS=30 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  pe "$HRECREATED" reconcile >/dev/null
recreated_deadline=$((SECONDS + 8))
while kill -0 "$RECREATED_RUNNER_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$recreated_deadline" ] \
    || fail "a fresh lease at a recreated state path preserved the old runner"
  sleep 0.1
done
pass "a recreated state path does not preserve the old runner"

HGUARDFAIL="$TMP_ROOT/guard-failure"; new_home "$HGUARDFAIL"
fm_test_track_procevent_home "$HGUARDFAIL"
pe_register "$HGUARDFAIL" lavish guard-fail-src -- "$FAST_SOURCE" "$TMP_ROOT/unguarded-launches"
guard_fail_status=0
guard_fail_out=$(FM_PROCEVENT_OWNER_LEASE_SECONDS=invalid \
  pe "$HGUARDFAIL" start guard-fail-src 2>&1) || guard_fail_status=$?
[ "$guard_fail_status" -ne 0 ] || fail "a runner continued after its owner guard failed to initialize"
assert_contains "$guard_fail_out" "cannot start the runner's owner guard" \
  "guard initialization failure is reported at the runner boundary"
assert_absent "$TMP_ROOT/unguarded-launches" \
  "a source command ran without a successfully initialized owner guard"
pass "a runner fails closed when its owner guard cannot initialize"

HATTACHED="$TMP_ROOT/attached-owner"; new_home "$HATTACHED"
fm_test_track_procevent_home "$HATTACHED"
ATTACHED_TRIGGER="$TMP_ROOT/attached.trigger"
pe_register "$HATTACHED" lavish attached-src -- "$BLOCKER" "$ATTACHED_TRIGGER" "attached payload"
FM_PROCEVENT_OWNER_LEASE_SECONDS=1 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  pe "$HATTACHED" start attached-src > "$TMP_ROOT/attached.out" 2>&1 &
ATTACHED_START_PID=$!
wait_for "$HATTACHED/state/procevent/attached-src.runner" \
  || fail "the attached start never launched its source"
sleep 4
kill -0 "$ATTACHED_START_PID" 2>/dev/null \
  || fail "a foreground start lost its owner lease while its caller remained attached"
touch "$ATTACHED_TRIGGER"
wait "$ATTACHED_START_PID" || fail "the attached start did not complete after its source returned"
assert_contains "$(cat "$TMP_ROOT/attached.out")" "captured:" \
  "the attached source result was not captured"
pass "a foreground start refreshes its lease while its caller remains attached"

HCLOCK="$TMP_ROOT/lease-clock"; new_home "$HCLOCK"
fm_test_track_procevent_home "$HCLOCK"
CLOCK_TRIGGER="$TMP_ROOT/lease-clock.trigger"
CLOCK_STATE="$TMP_ROOT/lease-clock-state"
CLOCK_BIN=$(fm_fakebin "$TMP_ROOT/lease-clock-bin")
REAL_DATE=$(command -v date) || fail "the lease clock fixture requires date"
cat > "$CLOCK_BIN/date" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = +%s ]; then
  while ! mkdir "$CLOCK_STATE.lock" 2>/dev/null; do sleep 0.01; done
  value=0
  [ ! -f "$CLOCK_STATE" ] || value=\$(cat "$CLOCK_STATE")
  value=\$((value + 10000))
  printf '%s\n' "\$value" > "$CLOCK_STATE"
  rmdir "$CLOCK_STATE.lock"
  printf '%s\n' "\$value"
  exit 0
fi
exec "$REAL_DATE" "\$@"
SH
chmod +x "$CLOCK_BIN/date"
pe_register "$HCLOCK" lavish lease-clock-src -- \
  "$BLOCKER" "$CLOCK_TRIGGER" "clock payload" >/dev/null
PATH="$CLOCK_BIN:$PATH" FM_PROCEVENT_OWNER_LEASE_SECONDS=1 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  pe "$HCLOCK" start lease-clock-src > "$TMP_ROOT/lease-clock.out" 2>&1 &
CLOCK_START_PID=$!
wait_for "$HCLOCK/state/procevent/lease-clock-src.runner" \
  || fail "the clock-shift fixture never launched its source"
sleep 4
kill -0 "$CLOCK_START_PID" 2>/dev/null \
  || fail "wall-clock corrections expired a live foreground owner"
touch "$CLOCK_TRIGGER"
wait "$CLOCK_START_PID" || fail "the clock-shift fixture did not complete"
pass "wall-clock corrections do not alter owner lease age"

HDETACHED="$TMP_ROOT/detached-attached-owner"; new_home "$HDETACHED"
fm_test_track_procevent_home "$HDETACHED"
DETACHED_TRIGGER="$TMP_ROOT/detached-attached.trigger"
pe_register "$HDETACHED" lavish detached-attached-src -- \
  "$BLOCKER" "$DETACHED_TRIGGER" "detached attached payload"
FM_PROCEVENT_OWNER_LEASE_SECONDS=1 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 FM_HOME="$HDETACHED" \
  perl -MPOSIX=setsid -e 'setsid() >= 0 or exit 1; exec @ARGV' \
    "$ROOT/bin/fm-procevent.sh" start detached-attached-src \
    > "$TMP_ROOT/detached-attached.out" 2>&1 &
DETACHED_START_PID=$!
wait_for "$HDETACHED/state/procevent/detached-attached-src.runner" \
  || fail "the detachable foreground start never launched its source"
DETACHED_RUNNER_PID=$(cat "$HDETACHED/state/procevent/detached-attached-src.runner")
kill "$DETACHED_START_PID"
wait "$DETACHED_START_PID" 2>/dev/null || true
detached_deadline=$((SECONDS + 8))
while kill -0 "$DETACHED_RUNNER_PID" 2>/dev/null; do
  if [ "$SECONDS" -ge "$detached_deadline" ]; then
    pe "$HDETACHED" retire detached-attached-src >/dev/null 2>&1 || true
    fail "an orphaned attached-start keeper preserved its owner's lease"
  fi
  sleep 0.1
done
pass "an attached-start keeper stops refreshing after its parent exits"

