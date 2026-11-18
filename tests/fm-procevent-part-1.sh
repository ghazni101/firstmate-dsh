# shellcheck shell=bash
# Part 1 of tests/fm-procevent.test.sh, split so no single ShellCheck root
# carries the whole suite. This file is sourced, in order, by that
# runner: it is executable test code, not a definition-only module, and
# it shares the runner's shell state and counters.
# shellcheck disable=SC2034,SC2153,SC2154,SC2329 # state is shared across the sourced parts

set -u

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR"

# Lavish owns this persisted session contract. The fake CLI fixtures exercise
# its published poll and synchronous reply command boundaries without starting a server.
lavish_session() {  # <artifact> [session-url]
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact, $url) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = {
      key => $key, file => decode("UTF-8", $real), status => "open", url => $url,
    };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1" "${2:-http://127.0.0.1:14387/session/0123456789abcdef}"
}

BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
# Blocks until the trigger exists, then emits its payload. Completion is the
# event; nothing here polls on a schedule. The wait is bounded so a stub that
# escapes its test cannot keep spawning processes indefinitely.
trigger=$1; shift
while [ ! -e "$trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
[ -n "${BLOCKER_STDERR:-}" ] && printf 'noise on stderr\n' >&2
[ -n "${BLOCKER_EXIT:-}" ] && exit "$BLOCKER_EXIT"
printf '%s\n' "$@"
SH
chmod +x "$BLOCKER"

# Records that the wrapped command actually started, then becomes it. A claim
# only proves its runner got as far as claiming; a test that needs the runner
# already inside its source command waits for this marker instead of a settle
# window, because a runner still short of that command retires itself when its
# registration goes away.
STARTED_BLOCKER="$TMP_ROOT/started-blocker.sh"
cat > "$STARTED_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' > "$1"
shift
exec "$@"
SH
chmod +x "$STARTED_BLOCKER"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# Every home this suite registers a source in is tracked so teardown can stop
# its runners. A runner started by reconcile is detached and reparented, so a
# source that never completes outlives the suite unless its home is swept -
# removing the fixture directory does not stop an already-running child.
# tests/lib.sh owns that sweep and runs it from every cleanup path.
pe_register() {  # <home> <adapter> <source-id> -- <argv>...
  local home=$1 adapter=$2 id=$3
  shift 3
  fm_test_track_procevent_home "$home"
  pe "$home" register "$adapter" "$id" "$@"
}
new_home() { mkdir -p "$1/state"; }
# A worker-owned board can only be armed for a task whose endpoint metadata the
# runner can ring, so every fixture worker needs the same durable record a real
# spawn leaves behind.
new_task_endpoint() {  # <home> <task-id>
  mkdir -p "$1/state"
  printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' "$2" "$1" "$2" \
    > "$1/state/$2.meta"
}
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

# The wake queue is a durable tab-separated record firstmate consumes:
# <epoch> <sequence> <kind> <key> <payload>. These read the rows reconcile
# publishes for a source it stranded, keyed by that source and its claim
# generation.
stranded_wake_keys() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":stranded:") == 1 { print $4 }' \
    "$1/state/.wake-queue"
}
stranded_wake_count() {  # <home> <source-id>
  stranded_wake_keys "$1" "$2" | grep -c . || true
}
stranded_wake_payloads() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":stranded:") == 1 { print $5 }' \
    "$1/state/.wake-queue"
}
# The same rows for a launch reconcile could not confirm, keyed by that source
# and the registration identity the launch ran under.
launch_failed_wake_keys() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":launch-failed:") == 1 { print $4 }' \
    "$1/state/.wake-queue"
}
launch_failed_wake_count() {  # <home> <source-id>
  launch_failed_wake_keys "$1" "$2" | grep -c . || true
}
launch_failed_wake_payloads() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":launch-failed:") == 1 { print $5 }' \
    "$1/state/.wake-queue"
}

first_result() {  # <home> <source-id>: print the first captured result, if any
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

count_results() {  # <home> <source-id>
  local g n=0
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

# --- detached startup refreshes owner presence after slow caller work -------
LEASE_ADAPTERS="$TMP_ROOT/lease-adapters"
mkdir -p "$LEASE_ADAPTERS/bin"
cat > "$LEASE_ADAPTERS/bin/fm-procevent-leaseplain.sh" <<'SH'
#!/usr/bin/env bash
exit 2
SH
cat > "$LEASE_ADAPTERS/bin/fm-procevent-leasepublish.sh" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  silent)
    printf 'publishing\n' > "$LEASE_PUBLISH_READY"
    while [ ! -e "$LEASE_PUBLISH_RELEASE" ]; do
      [ "$SECONDS" -lt 30 ] || exit 2
      sleep 0.05
    done
    exit 1
    ;;
esac
exit 2
SH
chmod +x "$LEASE_ADAPTERS/bin/"*.sh

lease_pe() {
  FM_ROOT_OVERRIDE="$LEASE_ADAPTERS" FM_PROCEVENT_OWNER_LEASE_SECONDS=2 \
    FM_PROCEVENT_OWNER_CHECK_SECONDS=1 pe "$@"
}
wait_stale_lease() {  # <home>
  local lease="$1/state/procevent/.owner-lease" n
  for n in $(seq 1 100); do
    if perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e '
      open my $in, "<", $ARGV[0] or exit 1;
      my $stamp = <$in>;
      exit(clock_gettime(CLOCK_MONOTONIC) - $stamp >= 3 ? 0 : 1);
    ' "$lease"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

for lease_entry in reconcile ensure-listening; do
  LEASE_HOME="$TMP_ROOT/lease-$lease_entry"; new_home "$LEASE_HOME"
  fm_test_track_procevent_home "$LEASE_HOME"
  lease_id="lease-$lease_entry-src"
  lease_started="$TMP_ROOT/$lease_id.started"
  lease_pe "$LEASE_HOME" register leaseplain "$lease_id" -- \
    "$STARTED_BLOCKER" "$lease_started" "$BLOCKER" "$TMP_ROOT/$lease_id.trigger" payload >/dev/null
  if [ "$lease_entry" = reconcile ]; then
    mkdir -p "$LEASE_HOME/state/procevent-inbox"
    printf 'old payload\n' > "$LEASE_HOME/state/procevent-inbox/lease-old.1.result"
    printf 'leasepublish\n' > "$LEASE_HOME/state/procevent-inbox/lease-old.1.adapter"
    chmod 600 "$LEASE_HOME/state/procevent-inbox/lease-old.1."*
    export LEASE_PUBLISH_READY="$TMP_ROOT/lease-publish.ready"
    export LEASE_PUBLISH_RELEASE="$TMP_ROOT/lease-publish.release"
    lease_pe "$LEASE_HOME" reconcile > "$TMP_ROOT/lease-reconcile.out" 2>&1 &
    lease_caller=$!
    wait_for "$LEASE_PUBLISH_READY" || fail "reconcile never reached pre-launch publication"
    wait_stale_lease "$LEASE_HOME" || fail "publication did not outlast the fixture lease"
    touch "$LEASE_PUBLISH_RELEASE"
    wait "$lease_caller" || fail "reconcile failed after slow publication"
  else
    wait_stale_lease "$LEASE_HOME" || fail "the readiness fixture lease never expired"
    lease_pe "$LEASE_HOME" ensure-listening "$lease_id" \
      > "$TMP_ROOT/lease-ensure-listening.out" 2>&1 \
      || fail "ensure-listening failed with an old caller lease"
  fi
  wait_for "$lease_started" \
    || fail "$lease_entry confirmed a detached start without running the source command"
  assert_contains "$(lease_pe "$LEASE_HOME" list)" "live" \
    "$lease_entry leaves a live source owner after refreshing at launch"
  # No further owner-presence operation runs. The launch refresh must not keep
  # renewing itself after the caller has returned.
  lease_runner=$(cat "$LEASE_HOME/state/procevent/$lease_id.runner")
  lease_deadline=$((SECONDS + 10))
  while kill -0 "$lease_runner" 2>/dev/null; do
    [ "$SECONDS" -lt "$lease_deadline" ] \
      || fail "$lease_entry kept its runner alive after the owning home's lease expired"
    sleep 0.1
  done
  lease_pe "$LEASE_HOME" retire "$lease_id" >/dev/null
  pass "$lease_entry refreshes at detached launch and still stops after owner lease expiry"
done

# An ordinary runner descendant may request a detached launch, but may never
# turn that launch into new owner-presence activity for its missing home.
LEASE_INHERITED="$TMP_ROOT/lease-inherited"; new_home "$LEASE_INHERITED"
fm_test_track_procevent_home "$LEASE_INHERITED"
lease_pe "$LEASE_INHERITED" register leaseplain lease-inherited-src -- \
  "$STARTED_BLOCKER" "$TMP_ROOT/lease-inherited.started" /bin/sleep 30 >/dev/null
wait_stale_lease "$LEASE_INHERITED" || fail "the inherited caller fixture lease never expired"
lease_before=$(cat "$LEASE_INHERITED/state/procevent/.owner-lease")
FM_PROCEVENT_IN_RUNNER=1 lease_pe "$LEASE_INHERITED" ensure-listening lease-inherited-src \
  > "$TMP_ROOT/lease-inherited.out" 2>&1 || true
[ "$(cat "$LEASE_INHERITED/state/procevent/.owner-lease")" = "$lease_before" ] \
  || fail "a runner descendant refreshed the owning lease at detached launch"
assert_absent "$TMP_ROOT/lease-inherited.started" \
  "a runner descendant cannot start a source under its expired owning lease"
lease_pe "$LEASE_INHERITED" retire lease-inherited-src >/dev/null
pass "inherited runner callers cannot renew owner presence at detached startup"

# Arm now starts the listener, so a later start would poll again. Wait for the
# capture that listener is already producing, and for its runner to release the
# claim: the result lands before the runner publishes and exits, and a retire or
# re-arm in that gap meets a live claim the synchronous start never left behind.
wait_capture() {  # <home> <source-id> [tries]
  local home=$1 id=$2 n=${3:-100}
  local _
  for _ in $(seq 1 "$n"); do
    if first_result "$home" "$id" >/dev/null 2>&1 \
      && [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/$id.claim" ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# <file> <count> [tries]: wait until <file> holds at least <count> lines. A
# detached runner appends its execution marker after the command that started it
# has already returned, so a caller that needs that append must wait for it
# rather than assume a fixed settle window covered it on a loaded machine.
wait_for_lines() {
  local f=$1 want=$2 n=${3:-100} have
  for _ in $(seq 1 "$n"); do
    if [ -f "$f" ]; then
      have=$(wc -l < "$f" | tr -d ' ')
    else
      have=0
    fi
    case "$have" in ''|*[!0-9]*) have=0 ;; esac
    [ "$have" -ge "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

hold_source_lock() {  # <source-id> <ready-file> <release-file>
  local id=$1 ready=$2 release=$3 parent=$$
  FM_HOME="$TMP_ROOT/lock-helper-home" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do
      kill -0 "$5" 2>/dev/null || exit 0
      sleep 0.02
    done
  ' _ "$ROOT" "$id" "$ready" "$release" "$parent" &
  HOLDER_PID=$!
}

hold_source_lock_then_handle() {  # <home> <source-id> <sequence> <ready-file> <release-file>
  local home=$1 id=$2 seq=$3 ready=$4 release=$5 parent=$$
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    printf "ready\n" > "$4"
    while [ ! -e "$5" ]; do
      kill -0 "$6" 2>/dev/null || exit 1
      sleep 0.02
    done
    fm_procevent_mark_handled "$3/state" "$2" "$7"
  ' _ "$ROOT" "$id" "$home" "$ready" "$release" "$parent" "$seq" &
  HOLDER_PID=$!
}

# --- inert with nothing configured ------------------------------------------
IDLE="$TMP_ROOT/idle"; mkdir -p "$IDLE"
out=$(pe "$IDLE" list)
assert_contains "$out" "no sources registered" "an unconfigured home reports no sources"
out=$(pe "$IDLE" reconcile)
assert_contains "$out" "published=0 started=0" "reconcile is a no-op with nothing registered"
[ -z "$(ls -A "$IDLE/state" 2>/dev/null)" ] || fail "an unconfigured home generated state: $(ls -A "$IDLE/state")"
pass "no configured source means no generated state and no process"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$IDLE/state")
assert_contains "$sup" no "an unconfigured home does not need supervision"

# --- a blocking source completes into exactly one normalized event ----------
H1="$TMP_ROOT/h1"; mkdir -p "$H1"
TRIG="$TMP_ROOT/trigger-one"
out=$(pe_register "$H1" lavish src-one -- "$BLOCKER" "$TRIG" "payload one")
assert_contains "$out" "registered: src-one" "register records a source"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$H1/state")
assert_contains "$sup" yes "a registered source needs supervision with no task metadata"

pe "$H1" reconcile >/dev/null
# Reconcile's replacement runner is detached, so ownership is recorded after
# reconcile has already returned. Wait for the claim itself: a duplicate start
# only has an owner to lose to once that claim exists.
wait_for "$FM_PROCEVENT_CLAIM_ROOT/src-one.claim" || fail "reconcile never claimed the registered source"
out=$(pe "$H1" start src-one)
assert_contains "$out" "already owned" "a duplicate start loses instead of running a second child"

: > "$TRIG"
wait_for "$H1/state/.wake-queue" || fail "no event was published after the source completed"
payload=$(wake_payloads "$H1")
assert_contains "$payload" "procevent lavish src-one 1" "completion publishes the committed result sequence"
assert_not_contains "$payload" "payload one" "source output never reaches the event line"
[ "$(printf '%s\n' "$payload" | grep -c .)" = 1 ] || fail "expected exactly one event, got: $payload"
pass "one blocking completion yields exactly one bounded normalized event"

RESULT=$(first_result "$H1" src-one || true)
[ -n "$RESULT" ] || fail "no durable result was captured"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$RESULT")
assert_contains "$mode" 600 "the captured result is private"
assert_grep 'payload one' "$RESULT" "the captured result holds the source output verbatim"
assert_grep 'lavish' "${RESULT%.result}.adapter" "the captured result retains its immutable adapter"
assert_absent "${RESULT%.result}.handled" "publication alone never marks a result handled"

# --- a home spelled through a symlinked ancestor still runs its sources ------
# Such a home must run process-event sources exactly like a physically spelled
# one: reconcile's detached runner discards its own stderr, so a refusal here is
# invisible to the caller and the source simply never fires.
HPHYS="$TMP_ROOT/symlinked-parent-target"
mkdir -p "$HPHYS"
ln -s "$HPHYS" "$TMP_ROOT/symlinked-parent"
HSYM="$TMP_ROOT/symlinked-parent/home"; new_home "$HSYM"
SYM_TRIGGER="$TMP_ROOT/symlink-trigger"
pe_register "$HSYM" lavish symlinked-src -- "$BLOCKER" "$SYM_TRIGGER" "symlinked payload" >/dev/null
pe "$HSYM" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/symlinked-src.claim" \
  || fail "a home reached through a symlinked ancestor never claimed its source"
: > "$SYM_TRIGGER"
wait_for "$HSYM/state/.wake-queue" \
  || fail "a home reached through a symlinked ancestor published no event"
assert_contains "$(wake_payloads "$HSYM")" "procevent lavish symlinked-src 1" \
  "the symlinked-ancestor home publishes the committed result sequence"
SYM_RESULT=$(first_result "$HSYM" symlinked-src || true)
[ -n "$SYM_RESULT" ] || fail "the symlinked-ancestor home captured no durable result"
assert_grep 'symlinked payload' "$SYM_RESULT" \
  "the symlinked-ancestor home captures the source output verbatim"
pass "a home reached through a symlinked ancestor runs its sources normally"

# --- the public start boundary establishes generation group ownership -------
HPG="$TMP_ROOT/hpg"; new_home "$HPG"
DIRECT_TRIGGER="$TMP_ROOT/direct-trigger"
pe_register "$HPG" lavish direct-src -- "$BLOCKER" "$DIRECT_TRIGGER" "direct result" >/dev/null
pe "$HPG" start direct-src > "$TMP_ROOT/direct-start.out" &
direct_runner=$!
wait_for "$FM_PROCEVENT_CLAIM_ROOT/direct-src.claim" || fail "direct start never claimed its source"
direct_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/direct-src.claim")
direct_group=$(ps -o pgid= -p "$direct_leader" 2>/dev/null | tr -d '[:space:]')
[ "$direct_group" = "$direct_leader" ] \
  || fail "direct start claimed before leading its process group: pid=$direct_leader pgid=$direct_group"
: > "$DIRECT_TRIGGER"
wait "$direct_runner" || fail "direct start failed after its source completed"
assert_contains "$(cat "$TMP_ROOT/direct-start.out")" "captured:" "direct start captures its result"
pass "public start owns the process group recorded by its claim"

SHARED_TRIGGER="$TMP_ROOT/shared-trigger"
SHARED_SIBLING="$TMP_ROOT/shared-sibling"
SHARED_LAUNCHER="$TMP_ROOT/shared-launcher.pl"
cat > "$SHARED_LAUNCHER" <<'PL'
use strict;
use warnings;
my ($sibling_file, @command) = @ARGV;
pipe(my $reader, my $writer) or exit 125;
defined(my $runner = fork) or exit 125;
if ($runner == 0) {
  close $reader;
  setpgrp(0, 0) or exit 125;
  print {$writer} "ready\n";
  close $writer;
  exec @command;
  exit 125;
}
close $writer;
<$reader>;
close $reader;
defined(my $sibling = fork) or exit 125;
if ($sibling == 0) {
  setpgrp(0, $runner) or exit 125;
  open(my $out, '>', $sibling_file) or exit 125;
  print {$out} "$$\n";
  close $out;
  sleep 30;
  exit 0;
}
waitpid($runner, 0);
waitpid($sibling, 0);
exit 0;
PL
pe_register "$HPG" lavish shared-src -- "$BLOCKER" "$SHARED_TRIGGER" "shared result" >/dev/null
FM_HOME="$HPG" perl "$SHARED_LAUNCHER" "$SHARED_SIBLING" \
  "$ROOT/bin/fm-procevent.sh" start shared-src > "$TMP_ROOT/shared-start.out" &
shared_launcher=$!
wait_for "$SHARED_SIBLING" || fail "shared caller group never started its unrelated sibling"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" || fail "shared-group start never claimed its source"
shared_sibling=$(cat "$SHARED_SIBLING")
pe "$HPG" retire shared-src >/dev/null
kill -0 "$shared_sibling" 2>/dev/null || fail "retirement signaled an unrelated caller-group process"
kill "$shared_sibling" 2>/dev/null || true
wait "$shared_launcher" || fail "shared caller-group fixture did not exit cleanly"
pass "public start never claims an inherited caller process group"

# --- an unhandled result remains eligible for re-announcement on restart ----
# A result is durable but nothing has ever acknowledged handling it. Every
# reconcile call - not just the first restart after a crash - must keep
# re-announcing it, because the only thing that stops re-announcement is an
# explicit handled acknowledgement, never a prior publication.
H2="$TMP_ROOT/h2"; new_home "$H2"
future_status=0
future_out=$(pe "$H2" handled src-cut 7 2>&1) || future_status=$?
[ "$future_status" -ne 0 ] || fail "handled accepted a generation that has not been captured"
assert_contains "$future_out" "cannot durably record handling" "premature acknowledgement is rejected through the public interface"
assert_absent "$H2/state/procevent-inbox/src-cut.7.handled" "premature acknowledgement creates no marker for the future generation"
mkdir -p "$H2/state/procevent-inbox"
printf 'stranded result\n' > "$H2/state/procevent-inbox/src-cut.7.result"
printf 'lavish\n' > "$H2/state/procevent-inbox/src-cut.7.adapter"
chmod 0600 "$H2/state/procevent-inbox/src-cut.7.result" "$H2/state/procevent-inbox/src-cut.7.adapter"
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=1" "a durably captured but unhandled result is announced after restart"
assert_contains "$(wake_payloads "$H2")" "procevent lavish src-cut 7" "durable adapter identity survives without a registration"
assert_absent "$H2/state/procevent-inbox/src-cut.7.handled" "recovery alone never marks the recovered result handled"
mv "$H2/state/.wake-queue" "$H2/state/.wake-queue.drained-1"
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=1" "an unhandled result is re-announced on every reconcile, not only the first"
assert_contains "$(wake_payloads "$H2")" "procevent lavish src-cut 7" "the repeat wake preserves its deduplication identity"
[ "$(count_results "$H2" src-cut)" = 1 ] || fail "repeat re-announcement created a second durable copy"
mv "$H2/state/.wake-queue" "$H2/state/.wake-queue.drained-2"

ack_out=$(pe "$H2" handled src-cut 7)
assert_contains "$ack_out" "handled: src-cut 7" "the owned handling interface newly authorizes the first acknowledgement"
assert_present "$H2/state/procevent-inbox/src-cut.7.handled" "acknowledgement durably records handling"
before=$(wake_payloads "$H2" | wc -l | tr -d ' ')
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=0" "reconcile stops re-announcing once a result is durably handled"
[ "$(wake_payloads "$H2" | wc -l | tr -d ' ')" = "$before" ] || fail "a handled result was announced again"

repeat_out=$(pe "$H2" handled src-cut 7)
assert_contains "$repeat_out" "already-handled: src-cut 7" "repeated acknowledgement is safe and reports the repeat distinctly"
case "$repeat_out" in
  handled:*) fail "a repeat acknowledgement re-authorized a second handled effect: $repeat_out" ;;
esac
pass "an unhandled result survives restart and repeat drains, and only explicit acknowledgement stops its re-announcement"

HRACE="$TMP_ROOT/hrace"; new_home "$HRACE"
mkdir -p "$HRACE/state/procevent-inbox"
printf 'racing result\n' > "$HRACE/state/procevent-inbox/racing-src.1.result"
printf 'lavish\n' > "$HRACE/state/procevent-inbox/racing-src.1.adapter"
chmod 0600 "$HRACE/state/procevent-inbox/racing-src.1.result" "$HRACE/state/procevent-inbox/racing-src.1.adapter"
RACE_PUBLISH_READY="$TMP_ROOT/race-publish-ready"
RACE_PUBLISH_RELEASE="$TMP_ROOT/race-publish-release"
RACE_RECONCILE_OUT="$TMP_ROOT/race-reconcile.out"
hold_source_lock_then_handle "$HRACE" racing-src 1 "$RACE_PUBLISH_READY" "$RACE_PUBLISH_RELEASE"
RACE_HANDLE_PID=$HOLDER_PID
wait_for "$RACE_PUBLISH_READY" || fail "publication race barrier did not acquire the source lock"
pe "$HRACE" reconcile > "$RACE_RECONCILE_OUT" &
RACE_RECONCILE_PID=$!
sleep 0.3
assert_absent "$HRACE/state/.wake-queue" "publication bypassed the source serialization boundary"
: > "$RACE_PUBLISH_RELEASE"
wait "$RACE_HANDLE_PID" || fail "publication race barrier could not record handling"
wait "$RACE_RECONCILE_PID" || fail "reconcile failed after the concurrent acknowledgement"
assert_contains "$(cat "$RACE_RECONCILE_OUT")" "published=0" "reconcile rechecks handling at the serialized publication boundary"
assert_present "$HRACE/state/procevent-inbox/racing-src.1.handled" "the concurrent acknowledgement remains durable"
assert_absent "$HRACE/state/.wake-queue" "an acknowledged result was appended after handling completed"
pass "publication cannot race a handled acknowledgement"

HPRIVATE="$TMP_ROOT/hprivate"; new_home "$HPRIVATE"
mkdir -p "$HPRIVATE/state/procevent-inbox"
printf 'private result\n' > "$HPRIVATE/state/procevent-inbox/private-src.1.result"
printf 'lavish\n' > "$HPRIVATE/state/procevent-inbox/private-src.1.adapter"
chmod 0600 "$HPRIVATE/state/procevent-inbox/private-src.1.result" "$HPRIVATE/state/procevent-inbox/private-src.1.adapter"
FAIL_CHMOD_BIN="$TMP_ROOT/fail-chmod-bin"
mkdir -p "$FAIL_CHMOD_BIN"
cat > "$FAIL_CHMOD_BIN/chmod" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAIL_CHMOD_BIN/chmod"
private_status=0
private_out=$(PATH="$FAIL_CHMOD_BIN:$PATH" pe "$HPRIVATE" handled private-src 1 2>&1) || private_status=$?
[ "$private_status" -ne 0 ] || fail "handled succeeded when private mode enforcement failed"
assert_contains "$private_out" "cannot durably record handling" "mode enforcement failure is reported through the owned interface"
assert_absent "$HPRIVATE/state/procevent-inbox/private-src.1.handled" "failed mode enforcement left an authoritative marker"
private_out=$(umask 000; pe "$HPRIVATE" handled private-src 1)
assert_contains "$private_out" "handled: private-src 1" "handling succeeds after private mode enforcement recovers"
private_mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$HPRIVATE/state/procevent-inbox/private-src.1.handled")
assert_contains "$private_mode" 600 "the handled marker is private under a permissive caller umask"
pass "handled acknowledgement creation is private and fails safely"

# --- a terminal result retires its source, on the adapter's verdict alone ----
# The runner must carry no notion of its own about what "done" means for a
# source. It asks that source's adapter whether the captured result ends the
# source, and retires the registration only on that adapter's verdict. Two
# fixture adapters isolate exactly that decision - one that ends on any result,
# one with no terminal knowledge at all - so the observed behavior is proven to
# follow the adapter rather than any condition built into the runner.
ADAPTER_ROOT="$TMP_ROOT/adapter-root"
mkdir -p "$ADAPTER_ROOT/bin"
cat > "$ADAPTER_ROOT/bin/fm-procevent-endnow.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter: every captured result ends this source.
case "${1-}" in
  terminal) [ -f "${2-}" ] && exit 0 || exit 1 ;;
esac
exit 2
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-openended.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter with no terminal knowledge at all: nothing ever ends it.
exit 2
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  autohandle)
    printf '%s %s\n' "$2" "$3" >> "$FM_HOME/state/applied"
    "$FM_PROCEVENT_UNDER_TEST" handled "$2" "$3" >/dev/null
    ;;
  *) exit 2 ;;
esac
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-selfann.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter that declares a durable downstream announcement of its own.
# FM_HOME/state/selfann-fail makes its application fail so the fallback
# publication path stays provable.
case "${1-}" in
  self-announcing) exit 0 ;;
  autohandle)
    [ ! -e "$FM_HOME/state/selfann-fail" ] || exit 1
    printf '%s %s\n' "$2" "$3" >> "$FM_HOME/state/applied"
    "$FM_PROCEVENT_UNDER_TEST" handled "$2" "$3" >/dev/null
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$ADAPTER_ROOT/bin/fm-procevent-endnow.sh" "$ADAPTER_ROOT/bin/fm-procevent-openended.sh" \
  "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" "$ADAPTER_ROOT/bin/fm-procevent-selfann.sh"

pe_adapter() {  # <home> <command>...: run the runner against the fixture adapters
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ADAPTER_ROOT" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" "$@"
}

HPUBLISH="$TMP_ROOT/hpublish"; new_home "$HPUBLISH"
fm_test_track_procevent_home "$HPUBLISH"
pe_adapter "$HPUBLISH" register applying publish-src -- /bin/echo "apply after publish" >/dev/null
mkdir "$HPUBLISH/state/.wake-queue"
out=$(pe_adapter "$HPUBLISH" start publish-src 2>&1)
assert_contains "$out" "not-autohandled: publish-src" "failed publication did not suppress automatic application"
assert_absent "$HPUBLISH/state/applied" "a result was applied before its wake was durably published"
assert_absent "$HPUBLISH/state/procevent-inbox/publish-src.1.handled" "a result was acknowledged before its wake was durably published"
rmdir "$HPUBLISH/state/.wake-queue"
# This source's child returns instantly, so leaving it registered would have the
# recovery reconcile below start a detached poll that races every assertion after
# it for the source claim, the next sequence, and this home's applied record.
# Re-announcement is proven from the durable inbox alone and needs no
# registration, so retire it first - the same retire-before-reconcile discipline
# the blocker-backed sources rely on - and prove no competing poll was started.
pe_adapter "$HPUBLISH" retire publish-src >/dev/null
out=$(pe_adapter "$HPUBLISH" reconcile)
assert_contains "$out" "published=1" "the unpublished capture was not announced on later reconciliation"
assert_contains "$out" "started=0" "reconcile started an always-ready poll that races the recovery assertions"
assert_contains "$(wake_payloads "$HPUBLISH")" "procevent applying publish-src 1" "later reconciliation did not deliver the capture to a handler"
FM_HOME="$HPUBLISH" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
  "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" autohandle publish-src 1 \
    "$HPUBLISH/state/procevent-inbox/publish-src.1.result"
assert_grep 'publish-src 1' "$HPUBLISH/state/applied" "the handler could not apply the later announcement"
assert_present "$HPUBLISH/state/procevent-inbox/publish-src.1.handled" "the later handler application was not acknowledged"
pass "automatic application waits for durable publication and failed publication remains recoverable"

# A self-announcing adapter inverts that order on its own declaration: the
# runner applies first and publishes nothing for a capture the adapter fully
# applied and acknowledged, because the adapter's own durable downstream
# channel is the announcement. The declaration never silences a capture the
# adapter could NOT apply - that one still publishes for the handler.
HSELF="$TMP_ROOT/hself"; new_home "$HSELF"
fm_test_track_procevent_home "$HSELF"
pe_adapter "$HSELF" register selfann self-src -- /bin/echo "self announced" >/dev/null
out=$(pe_adapter "$HSELF" start self-src 2>&1)
assert_contains "$out" "autohandled: self-src" "the self-announcing adapter did not apply its own capture"
assert_not_contains "$out" "not-autohandled" "the applied capture was still reported as left for the handler"
assert_grep 'self-src 1' "$HSELF/state/applied" "the self-announcing capture was not applied"
assert_present "$HSELF/state/procevent-inbox/self-src.1.handled" "the self-announcing application was not acknowledged"
if [ -e "$HSELF/state/.wake-queue" ] && grep -q 'procevent selfann self-src 1' "$HSELF/state/.wake-queue"; then
  fail "a fully autohandled self-announcing capture still published a duplicate check wake"
fi
# This self-announcing source's child returns instantly, so reconcile would
# restart it and that detached poll would race the failing-path start below for
# the source claim - non-deterministically stealing its sequence or the claim
# itself. Retire it before the re-announcement check so reconcile starts no
# competing poll, then re-register for the failing-path capture, the same
# retire-before-reconcile discipline the blocker-backed sources rely on.
pe_adapter "$HSELF" retire self-src >/dev/null
out=$(pe_adapter "$HSELF" reconcile)
assert_contains "$out" "published=0" "reconcile re-announced a capture its adapter already acknowledged"
assert_contains "$out" "started=0" "reconcile restarted an always-ready acknowledged source and raced the next start"
pe_adapter "$HSELF" register selfann self-src -- /bin/echo "self announced" >/dev/null
: > "$HSELF/state/selfann-fail"
out=$(pe_adapter "$HSELF" start self-src 2>&1)
assert_contains "$out" "not-autohandled: self-src" "a failed self-announcing application was reported as applied"
assert_absent "$HSELF/state/procevent-inbox/self-src.2.handled" "a failed self-announcing application was acknowledged anyway"
assert_contains "$(wake_payloads "$HSELF")" "procevent selfann self-src 2" \
  "a capture the self-announcing adapter could not apply lost its check-wake announcement"
rm -f "$HSELF/state/selfann-fail"
pass "a self-announcing adapter applies quietly and still publishes what it could not apply"

HTERM="$TMP_ROOT/hterm"; new_home "$HTERM"
fm_test_track_procevent_home "$HTERM"
pe_adapter "$HTERM" register endnow ends-src -- /bin/echo "terminal payload" >/dev/null
out=$(pe_adapter "$HTERM" start ends-src)
assert_contains "$out" "captured:" "a terminal result is still captured durably"
assert_contains "$out" "retired: ends-src" "the runner reports the adapter-driven retirement"
assert_absent "$HTERM/state/procevent/ends-src.source" "an adapter-classified terminal result retires its registration"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/ends-src.claim" "terminal retirement releases this runner's own claim"
assert_contains "$(wake_payloads "$HTERM")" "procevent endnow ends-src 1" "the terminal result is still announced"
[ "$(count_results "$HTERM" ends-src)" = 1 ] || fail "terminal retirement lost or duplicated the captured result"
TERMINAL_RESULT=$(first_result "$HTERM" ends-src || true)
assert_grep 'terminal payload' "$TERMINAL_RESULT" "automatic retirement retains the captured output verbatim"
out=$(pe_adapter "$HTERM" reconcile)
assert_contains "$out" "started=0" "a retired terminal source is never restarted"
assert_contains "$out" "published=1" "an unhandled terminal result is still re-announced until acknowledged"
[ "$(count_results "$HTERM" ends-src)" = 1 ] || fail "a retired terminal source ran its poll again"
out=$(pe_adapter "$HTERM" retire ends-src)
assert_contains "$out" "retired: ends-src" "explicit retirement stays supported and idempotent after automatic retirement"
ack_out=$(pe_adapter "$HTERM" handled ends-src 1)
assert_contains "$ack_out" "handled: ends-src 1" "a terminal result is acknowledged through the owned interface"
out=$(pe_adapter "$HTERM" reconcile)
assert_contains "$out" "published=0" "an acknowledged terminal result stops being re-announced"
pass "an adapter-classified terminal result is captured once, announced, and retires its source automatically"

HOPEN="$TMP_ROOT/hopen"; new_home "$HOPEN"
fm_test_track_procevent_home "$HOPEN"
pe_adapter "$HOPEN" register openended open-src -- /bin/echo "open payload" >/dev/null
out=$(pe_adapter "$HOPEN" start open-src)
assert_contains "$out" "captured:" "a result from an adapter with no terminal verdict is captured"
assert_not_contains "$out" "retired:" "an adapter with no terminal verdict never retires its source"
assert_present "$HOPEN/state/procevent/open-src.source" "a source with no terminal verdict stays armed"
pe_adapter "$HOPEN" retire open-src >/dev/null
pass "a source stays armed unless its own adapter classifies the result terminal"

HREPLACE="$TMP_ROOT/hreplace"; new_home "$HREPLACE"
fm_test_track_procevent_home "$HREPLACE"
OLD_TRIGGER="$TMP_ROOT/replace-old-trigger"
OLD_STARTED="$TMP_ROOT/replace-old-started"
pe_adapter "$HREPLACE" register endnow replace-src -- \
  "$STARTED_BLOCKER" "$OLD_STARTED" "$BLOCKER" "$OLD_TRIGGER" "old terminal payload" >/dev/null
pe_adapter "$HREPLACE" start replace-src > "$TMP_ROOT/replace-old.out" 2>&1 &
replace_old_pid=$!
wait_for "$OLD_STARTED" || fail "the old registration never started"
pe_adapter "$HREPLACE" register openended replace-src -- /bin/echo "replacement payload" >/dev/null
touch "$OLD_TRIGGER"
wait "$replace_old_pid" || fail "the old terminal runner failed"
assert_contains "$(cat "$TMP_ROOT/replace-old.out")" "cannot retire terminal source" \
  "an old runner refuses to retire a replacement registration"
assert_present "$HREPLACE/state/procevent/replace-src.source" \
  "a replacement registration survives the old runner's terminal result"
assert_contains "$(cat "$HREPLACE/state/procevent/replace-src.source")" "adapter=openended" \
  "the surviving registration is the replacement generation"
out=$(pe_adapter "$HREPLACE" start replace-src)
assert_contains "$out" "captured:" "the replacement registration remains independently runnable"
[ "$(count_results "$HREPLACE" replace-src)" = 2 ] \
  || fail "the replacement generation did not capture its own result"
pe_adapter "$HREPLACE" retire replace-src >/dev/null
pass "terminal retirement preserves and releases a concurrently replaced registration"

HRETFAIL="$TMP_ROOT/hretfail"; new_home "$HRETFAIL"
fm_test_track_procevent_home "$HRETFAIL"
FAIL_RM_BIN=$(fm_fakebin "$TMP_ROOT/retire-fail-bin")
REAL_RM=$(command -v rm)
export REAL_RM
cat > "$FAIL_RM_BIN/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */retire-fail-src.source) exit 1 ;; esac
done
exec "$REAL_RM" "$@"
SH
chmod +x "$FAIL_RM_BIN/rm"
pe_adapter "$HRETFAIL" register endnow retire-fail-src -- /bin/echo "one terminal payload" >/dev/null
out=$(PATH="$FAIL_RM_BIN:$PATH" pe_adapter "$HRETFAIL" start retire-fail-src 2>&1)
assert_contains "$out" "cannot retire terminal source" "a failed registration removal is reported"
assert_present "$HRETFAIL/state/procevent/retire-fail-src.source" \
  "failed retirement preserves the exact registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/retire-fail-src.claim" \
  "failed retirement preserves its terminal ownership claim"
out=$(PATH="$FAIL_RM_BIN:$PATH" pe_adapter "$HRETFAIL" reconcile)
assert_contains "$out" "started=0" "failed terminal retirement never restarts the poll"
[ "$(count_results "$HRETFAIL" retire-fail-src)" = 1 ] \
  || fail "failed retirement allowed recurring terminal capture"
pe_adapter "$HRETFAIL" reconcile >/dev/null
assert_absent "$HRETFAIL/state/procevent/retire-fail-src.source" \
  "repeated retirement removes the same registration once removal recovers"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/retire-fail-src.claim" \
  "the claim releases only after that registration is removed"
[ "$(count_results "$HRETFAIL" retire-fail-src)" = 1 ] \
  || fail "retirement recovery reran the terminal source"
pass "failed terminal retirement is fail-closed and idempotently recoverable"

# --- end-user-aligned regression: one Send & End, one captured result -------
# The dogfood defect: a real armed Lavish source received one human `Send & End`
# action, and the runner captured four results - the human's real feedback, then
# recurring empty ended sessions - because it kept restarting a source whose own
# adapter already knew the session had ended. Driven through the adapter's own
# arm command against a stand-in for the published poll shape, so registration,
# the runner, capture, publication, and retirement all run for real.
HLT="$TMP_ROOT/hlt"; new_home "$HLT"
LAVISH_BIN=$(fm_fakebin "$TMP_ROOT/lavish-stub")
LAVISH_POLL_COUNT="$TMP_ROOT/lavish-poll-count"
export LAVISH_POLL_COUNT
cat > "$LAVISH_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` around a human `Send & End`: the final
# feedback is delivered exactly once carrying session_ended, and every later
# poll returns an empty ended session immediately.
n=$(cat "$LAVISH_POLL_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$LAVISH_POLL_COUNT"
if [ "$n" = 1 ]; then
  printf 'session:\n  file: /review.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n'
else
  printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n'
fi
SH
chmod +x "$LAVISH_BIN/lavish-axi"
REVIEW_ART="$TMP_ROOT/review.html"
printf '<h1>review</h1>\n' > "$REVIEW_ART"
lavish_session "$REVIEW_ART"
lavish_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$REVIEW_ART")
fm_test_track_procevent_home "$HLT"
PATH="$LAVISH_BIN:$PATH" FM_HOME="$HLT" "$ROOT/bin/fm-procevent-lavish.sh" arm "$REVIEW_ART" >/dev/null
for _ in $(seq 1 6); do
  PATH="$LAVISH_BIN:$PATH" pe "$HLT" reconcile >/dev/null
  sleep 0.3
done
[ "$(cat "$LAVISH_POLL_COUNT")" = 1 ] \
  || fail "an ended review kept being polled: $(cat "$LAVISH_POLL_COUNT") polls for one Send & End"
[ "$(count_results "$HLT" "$lavish_id")" = 1 ] \
  || fail "one Send & End produced $(count_results "$HLT" "$lavish_id") captured results"
[ "$(wake_payloads "$HLT" | sort -u | grep -c .)" = 1 ] \
  || fail "one Send & End produced more than one distinct event: $(wake_payloads "$HLT" | sort -u)"
assert_contains "$(wake_payloads "$HLT")" "procevent lavish $lavish_id 1" "the human's final feedback is announced"
assert_absent "$HLT/state/procevent/$lavish_id.source" "the ended review source retires automatically"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/$lavish_id.claim" "the ended review releases its owned claim"
LAVISH_RESULT=$(first_result "$HLT" "$lavish_id" || true)
assert_grep 'ship it' "$LAVISH_RESULT" "automatic retirement retains the human's final feedback"
out=$(PATH="$LAVISH_BIN:$PATH" FM_HOME="$HLT" "$ROOT/bin/fm-procevent-lavish.sh" retire "$REVIEW_ART")
assert_contains "$out" "retired: $lavish_id" "explicit adapter retirement stays supported after automatic retirement"
pass "one Send & End yields exactly one captured result, automatic retirement, and no recurring poll"

# --- end-user-aligned regression: an empty board close is not news ------------
# The captain's report: closing a review surface he had said nothing on still
# put a wake in his chat whose entire content was that nothing happened. The
# adapter now answers the runner's silence seam for exactly that shape, so the
# result is captured and recorded handled without ever being announced. Driven
# through the adapter's own arm command and the real runner, so registration,
# capture, the silence verdict, and retirement all run for real.
HEMPTY="$TMP_ROOT/hempty"; new_home "$HEMPTY"
EMPTY_BIN=$(fm_fakebin "$TMP_ROOT/lavish-empty-stub")
cat > "$EMPTY_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` when the captain closes a board he said
# nothing on: an ended session carrying no queued content at all.
printf 'session:\n  file: /quiet.html\n  status: ended\n  ended_by: user\n'
SH
chmod +x "$EMPTY_BIN/lavish-axi"
QUIET_ART="$TMP_ROOT/quiet-board.html"
printf '<h1>quiet</h1>\n' > "$QUIET_ART"
lavish_session "$QUIET_ART"
quiet_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$QUIET_ART")
fm_test_track_procevent_home "$HEMPTY"
PATH="$EMPTY_BIN:$PATH" FM_HOME="$HEMPTY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$QUIET_ART" >/dev/null
quiet_out=$(PATH="$EMPTY_BIN:$PATH" pe "$HEMPTY" start "$quiet_id" 2>&1)
assert_not_contains "$quiet_out" "not-autohandled" \
  "a durably silenced result was reported as still unacknowledged"
# The handled marker is written at exactly the point the wake would otherwise
# have been appended, so waiting on it - rather than on a fixed sleep - is what
# makes "no wake" a real observation instead of a race the test won by being
# early.
QUIET_HANDLED="$HEMPTY/state/procevent-inbox/$quiet_id.1.handled"
for _ in $(seq 1 100); do
  [ -f "$QUIET_HANDLED" ] && break
  sleep 0.1
done
[ -f "$QUIET_HANDLED" ] \
  || fail "a silenced result was not durably recorded handled, so a later reconcile would announce it"
[ "$(count_results "$HEMPTY" "$quiet_id")" = 1 ] \
  || fail "an empty board close captured $(count_results "$HEMPTY" "$quiet_id") results instead of one"
[ -z "$(wake_payloads "$HEMPTY")" ] \
  || fail "an empty board close woke the captain: $(wake_payloads "$HEMPTY")"
# Re-announcement is exactly what the handled marker exists to stop, so the
# silence has to survive the reconcile that would otherwise republish it.
PATH="$EMPTY_BIN:$PATH" pe "$HEMPTY" reconcile >/dev/null
sleep 0.3
[ -z "$(wake_payloads "$HEMPTY")" ] \
  || fail "a later reconcile re-announced a silenced empty board close: $(wake_payloads "$HEMPTY")"
assert_absent "$HEMPTY/state/procevent/$quiet_id.source" \
  "an empty board close still retires its ended source"
pass "an empty board close is captured and recorded handled without ever waking the captain"

# --- end-user-aligned regression: worker-owned rounds stay open until re-arm -
# One worker-owned board runs three rounds: feedback reaches only the worker's
# inbox, each re-arm acknowledges the prior capture and posts its reply once,
# and a terminal session ends without another automatic poll.
HMULTI="$TMP_ROOT/hmulti"; new_home "$HMULTI"
MULTI_BIN=$(fm_fakebin "$TMP_ROOT/lavish-multi-stub")
MULTI_ROOT="$TMP_ROOT/lavish-multi-root"
mkdir -p "$MULTI_ROOT"
export MULTI_ROOT
cat > "$MULTI_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1-}" != --version ] || { printf '0.1.79\n'; exit 0; }
n=$(cat "$MULTI_ROOT/count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$MULTI_ROOT/count"
printf '%s:%s\n' "${LAVISH_AXI_HOST-unset}" "${LAVISH_AXI_PORT-unset}" >> "$MULTI_ROOT/routes"
for arg in "$@"; do
  case "$arg" in
    --agent-reply) ;;
    --*)
      printf 'error: unknown option %s\ncode: VALIDATION_ERROR\n' "$arg" >&2
      exit 2
      ;;
  esac
done
if [ "${1-}" = poll ] && [ "${3-}" = --agent-reply ]; then
  printf 'poll%s reply: %s\n' "$n" "$4" >> "$MULTI_ROOT/replies"
fi
while [ ! -e "$MULTI_ROOT/trigger$n" ]; do sleep 0.02; done
case "$n" in
  1|2)
    printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","round %s","","message",""\n' "$n"
    ;;
  3)
    printf 'session:\n  status: ended\n  session_ended: true\n'
    ;;
esac
SH
chmod +x "$MULTI_BIN/lavish-axi"
printf 'reply one\n' > "$MULTI_ROOT/reply1"
printf 'reply two\n' > "$MULTI_ROOT/reply2"
printf 'reply three\n' > "$MULTI_ROOT/reply3"
MULTI_ART="$MULTI_ROOT/board.html"
printf '<h1>multi-round</h1>\n' > "$MULTI_ART"
lavish_session "$MULTI_ART"
multi_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$MULTI_ART")
fm_test_track_procevent_home "$HMULTI"
new_task_endpoint "$HMULTI" worker-1
new_task_endpoint "$HMULTI" worker-2
mkdir -p "$HMULTI/config"
printf 'wrong-server.example\n' > "$HMULTI/config/lavish-axi-host"
PATH="$MULTI_BIN:$PATH" LAVISH_AXI_HOST=arming.example LAVISH_AXI_PORT=24387 FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-1 \
  --agent-reply-file "$MULTI_ROOT/reply1" >/dev/null
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" >/dev/null 2>"$MULTI_ROOT/firstmate-arm.err"; then
  fail "firstmate arm replaced a worker-owned board"
fi
assert_contains "$(cat "$MULTI_ROOT/firstmate-arm.err")" "owned by task worker-1" \
  "second armer refusal did not name the worker owner"
list_out=$(FM_HOME="$HMULTI" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$list_out" "task:worker-1/listening" \
  "arm did not leave the worker-owned board with a live listener"
PATH="$MULTI_BIN:$PATH" LAVISH_AXI_HOST=recovery.example LAVISH_AXI_PORT=34387 FM_HOME="$HMULTI" \
  pe "$HMULTI" start "$multi_id" > "$MULTI_ROOT/run1" 2>&1 &
MULTI_RUN=$!
for _ in $(seq 1 100); do [ "$(cat "$MULTI_ROOT/count" 2>/dev/null || true)" = 1 ] && break; sleep 0.02; done
touch "$MULTI_ROOT/trigger1"
for _ in $(seq 1 100); do [ -f "$HMULTI/state/worker-1.inbox/001.msg" ] && break; sleep 0.02; done
[ -f "$HMULTI/state/worker-1.inbox/001.msg" ] \
  || fail "worker-owned feedback did not reach the worker inbox"
[ -z "$(wake_payloads "$HMULTI")" ] \
  || fail "worker-owned feedback woke firstmate: $(wake_payloads "$HMULTI")"

# An open nonterminal round keeps the board with worker-1 through every
# retirement and registration path: the one source record cannot be retired out
# from under that round, and while it stands neither firstmate nor a sibling
# task can register over it or acknowledge worker-1's capture.
open_retire_status=0
PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$MULTI_ART" \
  >/dev/null 2>"$MULTI_ROOT/open-retire.err" || open_retire_status=$?
[ "$open_retire_status" -ne 0 ] \
  || fail "explicit retire removed a worker-owned board with an unacknowledged round"
assert_contains "$(cat "$MULTI_ROOT/open-retire.err")" "unacknowledged" \
  "the refused retire did not say the owner's round is still unacknowledged"
[ -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "a refused retire still removed the worker-owned source record"
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-2 \
  >/dev/null 2>"$MULTI_ROOT/open-sibling.err"; then
  fail "a sibling task registered over an open worker-owned round"
fi
assert_contains "$(cat "$MULTI_ROOT/open-sibling.err")" "owned by task worker-1" \
  "the sibling refusal over an open round did not name the worker owner"
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" \
  >/dev/null 2>"$MULTI_ROOT/open-firstmate.err"; then
  fail "firstmate armed a board with an open worker-owned round"
fi
assert_contains "$(cat "$MULTI_ROOT/open-firstmate.err")" "owned by task worker-1" \
  "the firstmate refusal over an open round did not name the worker owner"
[ ! -f "$HMULTI/state/procevent-inbox/$multi_id.1.handled" ] \
  || fail "a refused retire or registration acknowledged the owner's open round"
[ ! -e "$HMULTI/state/worker-2.inbox" ] \
  || fail "a refused sibling registration took delivery of the owner's feedback"

PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-1 \
  --agent-reply-file "$MULTI_ROOT/reply2" >/dev/null
wait "$MULTI_RUN" || true
for _ in $(seq 1 100); do
  PATH="$MULTI_BIN:$PATH" pe "$HMULTI" reconcile >/dev/null 2>&1 || true
  [ "$(cat "$MULTI_ROOT/count" 2>/dev/null || true)" = 2 ] && break
  sleep 0.03
done
touch "$MULTI_ROOT/trigger2"
for _ in $(seq 1 100); do [ -f "$HMULTI/state/worker-1.inbox/002.msg" ] && break; sleep 0.02; done
[ -f "$HMULTI/state/worker-1.inbox/002.msg" ] \
  || fail "the next worker-owned feedback did not reach the worker inbox"
PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-1 \
  --agent-reply-file "$MULTI_ROOT/reply3" >/dev/null
for _ in $(seq 1 100); do
  PATH="$MULTI_BIN:$PATH" pe "$HMULTI" reconcile >/dev/null 2>&1 || true
  [ "$(cat "$MULTI_ROOT/count" 2>/dev/null || true)" = 3 ] && break
  sleep 0.03
done
touch "$MULTI_ROOT/trigger3"
for _ in $(seq 1 100); do [ -f "$HMULTI/state/worker-1.inbox/003.msg" ] && break; sleep 0.02; done
[ -f "$HMULTI/state/procevent-inbox/$multi_id.1.handled" ] \
  || fail "first worker-owned round was not acknowledged by re-arm"
[ -f "$HMULTI/state/procevent-inbox/$multi_id.2.handled" ] \
  || fail "second worker-owned round was not acknowledged by re-arm"
assert_contains "$(cat "$HMULTI/state/worker-1.inbox/003.msg" 2>/dev/null || true)" \
  "do not re-arm" "terminal worker-owned result instructed the worker to stop"
[ "$(grep -c '^poll[123] reply:' "$MULTI_ROOT/replies" 2>/dev/null || true)" = 3 ] \
  || fail "worker replies were not posted once per round"
assert_contains "$(cat "$MULTI_ROOT/replies")" "poll1 reply: reply one" \
  "the reply staged with the arm was not the one the board received"
printf '%s\n' '127.0.0.1:14387' '127.0.0.1:14387' '127.0.0.1:14387' > "$MULTI_ROOT/expected-routes"
cmp -s "$MULTI_ROOT/expected-routes" "$MULTI_ROOT/routes" \
  || fail "worker replies/polls did not use the opened session server across start and reconcile"
pass "worker board replies and recovered listeners derive their server from the board session"

# The terminal round keeps the board with worker-1 until worker-1 acknowledges
# it, so the one source record stays the only ownership evidence there is: while
# it is open neither firstmate nor a sibling task can arm the board or consume
# the round, and acknowledging it is what concludes and retires the board.
[ -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "the terminal round released the worker's board before it was acknowledged"
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" >/dev/null 2>"$MULTI_ROOT/terminal-arm.err"; then
  fail "firstmate armed a worker-owned board whose terminal round was unacknowledged"
fi
assert_contains "$(cat "$MULTI_ROOT/terminal-arm.err")" "owned by task worker-1" \
  "the refusal over an open terminal round did not name the worker owner"
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-2 \
  >/dev/null 2>"$MULTI_ROOT/sibling-arm.err"; then
  fail "a sibling task took over a worker-owned board whose terminal round was unacknowledged"
fi
assert_contains "$(cat "$MULTI_ROOT/sibling-arm.err")" "owned by task worker-1" \
  "the sibling registration refusal did not name the worker owner"
terminal_retire_status=0
PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$MULTI_ART" \
  >/dev/null 2>"$MULTI_ROOT/terminal-retire.err" || terminal_retire_status=$?
[ "$terminal_retire_status" -ne 0 ] \
  || fail "explicit retire removed a worker-owned board with an unacknowledged terminal round"
[ -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "a refused retire removed the worker-owned record of an open terminal round"
[ ! -f "$HMULTI/state/procevent-inbox/$multi_id.3.handled" ] \
  || fail "a refused sibling registration consumed the owner's terminal round"
[ ! -f "$HMULTI/state/worker-2.inbox/001.msg" ] \
  || fail "a refused sibling registration took delivery of the owner's feedback"
chmod 0500 "$HMULTI/state/procevent"
blocked_handled_status=0
PATH="$MULTI_BIN:$PATH" pe "$HMULTI" handled "$multi_id" 3 \
  >/dev/null 2>"$MULTI_ROOT/blocked-handled.err" || blocked_handled_status=$?
chmod 0700 "$HMULTI/state/procevent"
[ "$blocked_handled_status" -ne 0 ] \
  || fail "an acknowledgement that could not retire the board still reported success"
[ ! -f "$HMULTI/state/procevent-inbox/$multi_id.3.handled" ] \
  || fail "an acknowledgement that could not retire the board still closed the round"
[ -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "a failed conclude left the board unowned"
PATH="$MULTI_BIN:$PATH" pe "$HMULTI" handled "$multi_id" 3 >/dev/null
[ -f "$HMULTI/state/procevent-inbox/$multi_id.3.handled" ] \
  || fail "the owner's acknowledgement of the terminal round was not recorded"
[ ! -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "acknowledging the terminal round did not retire the worker-owned board"
PATH="$MULTI_BIN:$PATH" pe "$HMULTI" reconcile >/dev/null 2>&1 || true
[ "$(cat "$MULTI_ROOT/count")" = 3 ] \
  || fail "the concluded board was polled again: $(cat "$MULTI_ROOT/count") polls"
[ -z "$(wake_payloads "$HMULTI")" ] \
  || fail "worker-owned rounds produced a firstmate wake: $(wake_payloads "$HMULTI")"
pass "worker-owned Lavish rounds deliver to the worker, acknowledge on re-arm, and stop at session end"

# --- end-user-aligned regression: a half-written capture does not wedge -----
# The result file is a capture's commit marker, so an owner sidecar left behind
# at a sequence with no result - a crash between publishing that sidecar and
# committing the result - is replaceable staging state. The next capture takes
# the same sequence and still routes to the owning worker.
HORPHAN="$TMP_ROOT/horphan"; new_home "$HORPHAN"
ORPHAN_BIN=$(fm_fakebin "$TMP_ROOT/lavish-orphan-stub")
ORPHAN_TRIGGER="$TMP_ROOT/lavish-orphan-hold"
export ORPHAN_TRIGGER
cat > "$ORPHAN_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
while [ ! -e "$ORPHAN_TRIGGER" ]; do sleep 0.02; done
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","after the crash","","message",""\n'
SH
chmod +x "$ORPHAN_BIN/lavish-axi"
ORPHAN_ART="$TMP_ROOT/orphan-board.html"
printf '<h1>orphan</h1>\n' > "$ORPHAN_ART"
lavish_session "$ORPHAN_ART"
orphan_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ORPHAN_ART")
fm_test_track_procevent_home "$HORPHAN"
new_task_endpoint "$HORPHAN" worker-4
PATH="$ORPHAN_BIN:$PATH" FM_HOME="$HORPHAN" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ORPHAN_ART" --for worker-4 >/dev/null
(umask 077; mkdir -p "$HORPHAN/state/procevent-inbox")
chmod 0700 "$HORPHAN/state/procevent-inbox"
printf 'worker-4\n' > "$HORPHAN/state/procevent-inbox/$orphan_id.1.owner-task"
chmod 0600 "$HORPHAN/state/procevent-inbox/$orphan_id.1.owner-task"
touch "$ORPHAN_TRIGGER"
PATH="$ORPHAN_BIN:$PATH" pe "$HORPHAN" start "$orphan_id" >/dev/null 2>&1 || true
wait_for "$HORPHAN/state/procevent-inbox/$orphan_id.1.result" \
  || fail "an owner sidecar with no committed result wedged the next capture of its source"
wait_for "$HORPHAN/state/worker-4.inbox/001.msg" \
  || fail "the recovered capture did not reach its owning worker's steering inbox"
[ -f "$HORPHAN/state/procevent-inbox/$orphan_id.1.result" ] \
  || fail "an owner sidecar with no committed result wedged the next capture of its source"
[ -f "$HORPHAN/state/worker-4.inbox/001.msg" ] \
  || fail "the recovered capture did not reach its owning worker's steering inbox"
pass "a capture interrupted before its result commit does not wedge its source"

# --- end-user-aligned regression: confirming a launch leaves the lock free ----
# A runner needs the source lock to claim. A confirmation loop polling that lock
# before any claim exists starves the launch it is waiting for, which on a loaded
# host pushed healthy listeners past the confirm window: arm then retired its own
# registration and reconcile announced a launch failure. The stand-in holds the
# runner at its first process-group check, just before it first takes the lock,
# so anything seen holding the lock during that hold is the confirmation itself.
STALL_BIN=$(fm_fakebin "$TMP_ROOT/ps-stall-stub")
STALL_STARTED="$TMP_ROOT/ps-stall-started"
STALL_RELEASE="$TMP_ROOT/ps-stall-release"
STALL_REAL_PS=$(command -v ps)
export STALL_STARTED STALL_RELEASE STALL_REAL_PS
cat > "$STALL_BIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'-o pgid='*)
    printf 'held\n' > "$STALL_STARTED"
    while [ ! -e "$STALL_RELEASE" ]; do
      [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
      sleep 0.02
    done
    ;;
esac
exec "$STALL_REAL_PS" "$@"
SH
chmod +x "$STALL_BIN/ps"
assert_confirmation_leaves_lock_free() {  # <home> <source-id> <description> <fm-procevent command...>
  local home=$1 id=$2 description=$3 lock pid sample_until touched=0
  shift 3
  rm -f "$STALL_STARTED" "$STALL_RELEASE"
  lock=$(printf '%s/%s.lock' "$FM_PROCEVENT_CLAIM_ROOT" "$id")
  FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=60 PATH="$STALL_BIN:$PATH" pe "$home" "$@" >/dev/null 2>&1 &
  pid=$!
  wait_for "$STALL_STARTED" || fail "the stalled runner never reached its process-group check: $description"
  sample_until=$((SECONDS + 2))
  while [ "$SECONDS" -lt "$sample_until" ]; do
    if [ -e "$lock" ] || [ -L "$lock" ]; then touched=1; fi
  done
  touch "$STALL_RELEASE"
  wait "$pid" || fail "a launch held only by a slow runner was not confirmed: $description"
  [ "$touched" -eq 0 ] || fail "confirmation took the source lock before any claim existed: $description"
  pe "$home" retire "$id" >/dev/null
}
HLOCKFREE="$TMP_ROOT/hlockfree"; new_home "$HLOCKFREE"
LOCKFREE_TRIGGER="$TMP_ROOT/lockfree-hold"
pe_register "$HLOCKFREE" lavish lockfree-src -- "$BLOCKER" "$LOCKFREE_TRIGGER" "lockfree payload" >/dev/null
assert_confirmation_leaves_lock_free "$HLOCKFREE" lockfree-src "ensure-listening" ensure-listening lockfree-src
pe_register "$HLOCKFREE" lavish lockfree-src -- "$BLOCKER" "$LOCKFREE_TRIGGER" "lockfree payload" >/dev/null
assert_confirmation_leaves_lock_free "$HLOCKFREE" lockfree-src "reconcile" reconcile
pass "confirming a launch leaves the source lock free until a claim exists"

# --- end-user-aligned regression: an orphaned capture keeps its owner ---------
# An unacknowledged capture belongs to whoever it was routed to. Retiring the
# board it came from orphans that capture without handing it to anyone, so a
# worker arming the same artifact is refused rather than silently acknowledging
# a round that never reached it.
HADOPT="$TMP_ROOT/hadopt"; new_home "$HADOPT"
ADOPT_BIN=$(fm_fakebin "$TMP_ROOT/lavish-adopt-stub")
cat > "$ADOPT_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","for firstmate","","message",""\n'
SH
chmod +x "$ADOPT_BIN/lavish-axi"
ADOPT_ART="$TMP_ROOT/adopt-board.html"
printf '<h1>adopt</h1>\n' > "$ADOPT_ART"
lavish_session "$ADOPT_ART"
adopt_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ADOPT_ART")
fm_test_track_procevent_home "$HADOPT"
new_task_endpoint "$HADOPT" worker-5
PATH="$ADOPT_BIN:$PATH" FM_HOME="$HADOPT" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ADOPT_ART" >/dev/null
wait_capture "$HADOPT" "$adopt_id" \
  || fail "the firstmate fixture capture never landed"
[ -f "$HADOPT/state/procevent-inbox/$adopt_id.1.result" ] \
  || fail "the firstmate fixture capture never landed"
[ ! -f "$HADOPT/state/procevent-inbox/$adopt_id.1.handled" ] \
  || fail "the firstmate fixture capture was already acknowledged"
PATH="$ADOPT_BIN:$PATH" FM_HOME="$HADOPT" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$ADOPT_ART" >/dev/null
if PATH="$ADOPT_BIN:$PATH" FM_HOME="$HADOPT" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ADOPT_ART" --for worker-5 \
  >/dev/null 2>"$TMP_ROOT/adopt-arm.err"; then
  fail "a worker armed a board carrying another owner's unacknowledged capture"
fi
assert_contains "$(cat "$TMP_ROOT/adopt-arm.err")" "firstmate" \
  "the refusal did not name the owner the orphaned capture belongs to"
[ ! -f "$HADOPT/state/procevent-inbox/$adopt_id.1.handled" ] \
  || fail "a refused arm still acknowledged another owner's capture"
[ ! -e "$HADOPT/state/procevent/$adopt_id.source" ] \
  || fail "a refused arm still published its task-owned registration"
pass "an orphaned capture is not acknowledged by a worker it never reached"

# --- end-user-aligned regression: a board is armed for a reachable owner ------
# Captured feedback goes straight to the owning task's steering inbox, so a task
# id that names no endpoint would strand every round it ever collects. The arm
# path refuses it instead of publishing a registration nobody can be told about.
HNOMETA="$TMP_ROOT/hnometa"; new_home "$HNOMETA"
NOMETA_ART="$TMP_ROOT/nometa-board.html"
printf '<h1>no endpoint</h1>\n' > "$NOMETA_ART"
lavish_session "$NOMETA_ART"
nometa_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$NOMETA_ART")
fm_test_track_procevent_home "$HNOMETA"
if PATH="$ADOPT_BIN:$PATH" FM_HOME="$HNOMETA" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$NOMETA_ART" --for worker-10 \
  >/dev/null 2>"$TMP_ROOT/nometa-arm.err"; then
  fail "a board was armed for a task id that names no endpoint"
fi
assert_contains "$(cat "$TMP_ROOT/nometa-arm.err")" "worker-10" \
  "the refusal did not name the task whose endpoint is missing"
[ ! -e "$HNOMETA/state/procevent/$nometa_id.source" ] \
  || fail "a board armed for an unreachable owner still published its registration"
new_task_endpoint "$HNOMETA" worker-10
PATH="$ADOPT_BIN:$PATH" FM_HOME="$HNOMETA" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$NOMETA_ART" --for worker-10 >/dev/null
[ -e "$HNOMETA/state/procevent/$nometa_id.source" ] \
  || fail "a board was refused for a task that does have an endpoint"
pass "a worker-owned board is only armed for an owner its feedback can reach"

# --- end-user-aligned regression: acknowledging a delivered note stops the ring
# The move into handled/ is the worker's own acknowledgement (the inbox
# contract), so a later reconcile that finds the same captured round must
# never move that note back into the active inbox or ring the worker again:
# only a write that actually creates a fresh record rings, and re-delivery of
# a still-open round is left to the inbox's own re-ring ladder.
HREDELIVER="$TMP_ROOT/hredeliver"; new_home "$HREDELIVER"
RING_BIN=$(fm_fakebin "$TMP_ROOT/ring-tmux-stub")
cat > "$RING_BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows) printf 'fm-worker-6\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$RING_BIN/tmux"
REDELIVER_ART="$TMP_ROOT/redeliver-board.html"
printf '<h1>redeliver</h1>\n' > "$REDELIVER_ART"
lavish_session "$REDELIVER_ART"
redeliver_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$REDELIVER_ART")
fm_test_track_procevent_home "$HREDELIVER"
new_task_endpoint "$HREDELIVER" worker-6
RING_LOG="$TMP_ROOT/redeliver-ring.log"; : > "$RING_LOG"
PATH="$RING_BIN:$ADOPT_BIN:$PATH" FM_SEND_LOG="$RING_LOG" FM_HOME="$HREDELIVER" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REDELIVER_ART" --for worker-6 >/dev/null
wait_capture "$HREDELIVER" "$redeliver_id" \
  || fail "the first worker-owned round was never captured"
[ -f "$HREDELIVER/state/worker-6.inbox/001.msg" ] \
  || fail "the first worker-owned round never reached the worker inbox"
wait_for_lines "$RING_LOG" 1 \
  || fail "the newly captured round never rang its owner's doorbell"
[ "$(wc -l < "$RING_LOG" | tr -d ' ')" = 1 ] \
  || fail "a single newly captured round rang more than once: $(cat "$RING_LOG")"
i=0
while [ "$i" -lt 5 ]; do
  PATH="$RING_BIN:$ADOPT_BIN:$PATH" FM_SEND_LOG="$RING_LOG" pe "$HREDELIVER" reconcile >/dev/null 2>&1 || true
  i=$((i + 1))
done
[ "$(wc -l < "$RING_LOG" | tr -d ' ')" = 1 ] \
  || fail "an unchanged active note re-rang the doorbell on every reconcile: $(cat "$RING_LOG")"
[ -f "$HREDELIVER/state/worker-6.inbox/001.msg" ] \
  || fail "repeated reconciles dropped the still-active note from the inbox"
mv "$HREDELIVER/state/worker-6.inbox/001.msg" \
  "$HREDELIVER/state/worker-6.inbox/handled/001.msg"
i=0
while [ "$i" -lt 5 ]; do
  PATH="$RING_BIN:$ADOPT_BIN:$PATH" FM_SEND_LOG="$RING_LOG" pe "$HREDELIVER" reconcile >/dev/null 2>&1 || true
  i=$((i + 1))
done
[ "$(wc -l < "$RING_LOG" | tr -d ' ')" = 1 ] \
  || fail "acknowledging the note did not stop repeated doorbell rings across reconciles: $(cat "$RING_LOG")"
[ ! -f "$HREDELIVER/state/worker-6.inbox/001.msg" ] \
  || fail "an already-acknowledged note was resurrected into the active inbox"
[ -f "$HREDELIVER/state/worker-6.inbox/handled/001.msg" ] \
  || fail "an already-acknowledged note vanished instead of staying acknowledged"
[ ! -f "$HREDELIVER/state/procevent-inbox/$redeliver_id.1.handled" ] \
  || fail "reconcile closed the round on its own, without the owner's explicit handled call"
pass "an acknowledged note is never resurrected and stops ringing across repeated reconciles"

# --- end-user-aligned regression: a conclude only closes its own round --------
# Acknowledging a terminal round retires the board it belongs to. The same
# acknowledgement repeated later is a no-op on a closed round, so it must not
# reach past it and retire whatever board the artifact carries by then.
HCONC="$TMP_ROOT/hconclude"; new_home "$HCONC"
CONC_BIN=$(fm_fakebin "$TMP_ROOT/lavish-conclude-stub")
cat > "$CONC_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  status: ended\n  session_ended: true\n'
SH
chmod +x "$CONC_BIN/lavish-axi"
CONC_ART="$TMP_ROOT/conclude-board.html"
printf '<h1>conclude</h1>\n' > "$CONC_ART"
lavish_session "$CONC_ART"
conc_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$CONC_ART")
fm_test_track_procevent_home "$HCONC"
new_task_endpoint "$HCONC" worker-7
PATH="$CONC_BIN:$PATH" FM_HOME="$HCONC" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$CONC_ART" --for worker-7 >/dev/null
wait_capture "$HCONC" "$conc_id" \
  || fail "the terminal worker-owned round never landed"
[ -f "$HCONC/state/procevent-inbox/$conc_id.1.result" ] \
  || fail "the terminal worker-owned round never landed"
[ -e "$HCONC/state/procevent/$conc_id.source" ] \
  || fail "the terminal round released the board before its owner acknowledged it"
chmod 0500 "$HCONC/state/procevent-inbox"
unrecordable_status=0
PATH="$CONC_BIN:$PATH" pe "$HCONC" handled "$conc_id" 1 >/dev/null 2>&1 || unrecordable_status=$?
chmod 0700 "$HCONC/state/procevent-inbox"
[ "$unrecordable_status" -ne 0 ] \
  || fail "an acknowledgement that could not be recorded still reported success"
[ ! -f "$HCONC/state/procevent-inbox/$conc_id.1.handled" ] \
  || fail "an acknowledgement that could not be recorded still closed the round"
[ -e "$HCONC/state/procevent/$conc_id.source" ] \
  || fail "an acknowledgement that could not be recorded still released the board it was owed"
conclude_out=$(PATH="$CONC_BIN:$PATH" pe "$HCONC" handled "$conc_id" 1)
assert_contains "$conclude_out" "retired: $conc_id" \
  "acknowledging the terminal round did not report the board retired"
[ ! -e "$HCONC/state/procevent/$conc_id.source" ] \
  || fail "acknowledging the terminal round did not retire the worker-owned board"
PATH="$CONC_BIN:$PATH" FM_HOME="$HCONC" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$CONC_ART" --for worker-7 >/dev/null
repeat_out=$(PATH="$CONC_BIN:$PATH" pe "$HCONC" handled "$conc_id" 1)
assert_contains "$repeat_out" "already-handled: $conc_id 1" \
  "repeating a closed acknowledgement did not report it as already handled"
case "$repeat_out" in
  *retired:*) fail "repeating a closed acknowledgement retired a board it never belonged to" ;;
esac
[ -e "$HCONC/state/procevent/$conc_id.source" ] \
  || fail "repeating a closed acknowledgement retired the board armed after it"
pass "acknowledging a terminal round concludes that round only"

