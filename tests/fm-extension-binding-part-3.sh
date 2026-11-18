# shellcheck shell=bash
# Part 3 of tests/fm-extension-binding.test.sh, split so no single ShellCheck root
# carries the whole suite. This file is sourced, in order, by that
# runner: it is executable test code, not a definition-only module, and
# it shares the runner's shell state and counters.
# shellcheck disable=SC2034,SC2153,SC2329 # state is shared across the sourced parts

if section_enabled lifecycle-invocation-cleanup; then
P_INVOCATION_CLEANUP="$PACKAGES/invocation-cleanup"
make_package "$P_INVOCATION_CLEANUP" org.example.invocation-cleanup ext-invocation-cleanup
H_INVOCATION_CLEANUP="$HOMES/invocation-cleanup"; new_home "$H_INVOCATION_CLEANUP"
cleanup_bind=$(bind_package "$H_INVOCATION_CLEANUP" "$P_INVOCATION_CLEANUP" ext-invocation-cleanup)
cleanup_binding_digest=$(printf '%s\n' "$cleanup_bind" | sed -n 's/^binding-digest: //p')
cleanup_resolution=$(FM_HOME="$H_INVOCATION_CLEANUP" "$HOST" resolve-process-event ext-invocation-cleanup)
IFS=$'\t' read -r cleanup_schema cleanup_id cleanup_version cleanup_cap cleanup_package cleanup_binding cleanup_extra <<< "$cleanup_resolution"
[ "$cleanup_schema" = fm-extension-process-event-resolution.v1 ] && [ -z "$cleanup_extra" ] \
  || fail "cleanup resolution record is malformed: $cleanup_resolution"

invoke_cleanup() {  # <config-ref> [host command...]
  local config_ref=$1
  shift
  FM_HOME="$H_INVOCATION_CLEANUP" "$@" process-event ext-invocation-cleanup source.poll \
    --source-id invocation-cleanup-source --config-ref "$config_ref" \
    --expect-extension "$cleanup_id" --expect-version "$cleanup_version" \
    --expect-capability-version "$cleanup_cap" \
    --expect-package-digest "$cleanup_package" --expect-binding-digest "$cleanup_binding"
}

first_invocation_owner() {  # <home>
  local candidate
  for candidate in "$1/state/extension-invocations"/*.owner.json; do
    [ -f "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

wait_for_invocation_owner() {  # <home>
  local candidate
  for _ in $(seq 1 200); do
    candidate=$(first_invocation_owner "$1" 2>/dev/null || true)
    [ -n "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    sleep 0.01
  done
  return 1
}

owner_group_pid() {  # <owner-file>
  node -e 'const fs=require("fs");const value=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(value.phase!=="group"||!Number.isSafeInteger(value.group_pid))process.exit(1);process.stdout.write(String(value.group_pid));' "$1"
}

guarded_out=$(invoke_cleanup guarded node --disallow-code-generation-from-strings "$HOST")
assert_contains "$guarded_out" "external evidence: guarded" \
  "the tracked static launch barrier failed under Node's no-dynamic-code guard"
pass "extension launch uses a tracked static core barrier without dynamic code evaluation"

signal_state="$H_INVOCATION_CLEANUP/state/extensions/org.example.invocation-cleanup"
rm -f "$signal_state/descendant.pid"
FM_HOME="$H_INVOCATION_CLEANUP" "$HOST" process-event ext-invocation-cleanup source.poll \
  --source-id invocation-cleanup-source --config-ref timeout \
  --expect-extension "$cleanup_id" --expect-version "$cleanup_version" \
  --expect-capability-version "$cleanup_cap" \
  --expect-package-digest "$cleanup_package" --expect-binding-digest "$cleanup_binding" \
  > "$TMP_ROOT/invocation-signal.out" 2>&1 &
signal_cleanup_host_pid=$!
wait_for_file "$signal_state/descendant.pid" || fail "signal cleanup fixture never started its descendant"
signal_owner=$(wait_for_invocation_owner "$H_INVOCATION_CLEANUP") \
  || fail "signal cleanup fixture published no invocation owner"
signal_cleanup_group_pid=$(owner_group_pid "$signal_owner") \
  || fail "signal cleanup fixture published no exact process group"
kill -TERM "$signal_cleanup_host_pid" 2>/dev/null || fail "cannot interrupt the active extension host"
signal_cleanup_rc=0
wait "$signal_cleanup_host_pid" || signal_cleanup_rc=$?
signal_cleanup_host_pid=
[ "$signal_cleanup_rc" -ne 0 ] || fail "interrupted extension host unexpectedly succeeded"
if kill -0 -"$signal_cleanup_group_pid" 2>/dev/null; then
  fail "interrupted extension host exited before its exact process group was gone"
fi
signal_descendant=$(cat "$signal_state/descendant.pid")
kill -0 "$signal_descendant" 2>/dev/null && fail "signal cleanup left the extension descendant alive"
signal_cleanup_group_pid=
if first_invocation_owner "$H_INVOCATION_CLEANUP" >/dev/null 2>&1; then
  fail "successful signal cleanup retained stale invocation ownership"
fi
pass "signal interruption proves exact invocation-group extinction before host exit"

crash_marker="$TMP_ROOT/invocation-crash.marker"
crash_cleanup_release="$TMP_ROOT/invocation-crash.release"
crash_config="active-block|$crash_marker|$crash_cleanup_release"
FM_HOME="$H_INVOCATION_CLEANUP" "$HOST" process-event ext-invocation-cleanup source.poll \
  --source-id invocation-cleanup-source --config-ref "$crash_config" \
  --expect-extension "$cleanup_id" --expect-version "$cleanup_version" \
  --expect-capability-version "$cleanup_cap" \
  --expect-package-digest "$cleanup_package" --expect-binding-digest "$cleanup_binding" \
  > "$TMP_ROOT/invocation-crash.out" 2>&1 &
crash_cleanup_host_pid=$!
wait_for_file "$crash_marker" || fail "crash cleanup fixture never entered extension code"
crash_owner=$(wait_for_invocation_owner "$H_INVOCATION_CLEANUP") \
  || fail "crash cleanup fixture published no invocation owner"
crash_cleanup_group_pid=$(owner_group_pid "$crash_owner") \
  || fail "crash cleanup fixture published no exact process group"
crash_entry_pid=$(cat "$crash_marker")
kill -KILL "$crash_cleanup_host_pid" 2>/dev/null || fail "cannot stop the extension host at the crash cut"
wait "$crash_cleanup_host_pid" 2>/dev/null || true
crash_cleanup_host_pid=
kill -0 -"$crash_cleanup_group_pid" 2>/dev/null \
  || fail "host crash did not leave the tracked invocation group for recovery"
FM_HOME="$H_INVOCATION_CLEANUP" "$HOST" retire-binding org.example.invocation-cleanup \
  --if-binding-digest "$cleanup_binding_digest" >/dev/null
if kill -0 -"$crash_cleanup_group_pid" 2>/dev/null; then
  fail "binding retirement completed while its tracked invocation group survived"
fi
kill -0 "$crash_entry_pid" 2>/dev/null && fail "binding retirement left the crashed host's extension process alive"
crash_cleanup_group_pid=
crash_cleanup_release=
assert_absent "$H_INVOCATION_CLEANUP/config/extensions.d/org.example.invocation-cleanup.json" \
  "identity-safe retirement retained the recovered binding"
pass "host-crash recovery retires only after exact invocation-group extinction"
fi

if section_enabled lifecycle-flow lifecycle-orphan-readiness; then
# Ownerless readiness records have no source selector or signalling authority.
# Use only private fixture groups, and keep an unrelated live PID as a reuse case.
P_INVOCATION_CLEANUP="$PACKAGES/orphan-cleanup"
make_package "$P_INVOCATION_CLEANUP" org.example.invocation-cleanup ext-invocation-cleanup
H_ORPHAN_READY="$HOMES/orphan-ready"; new_home "$H_ORPHAN_READY"
fm_test_track_procevent_home "$H_ORPHAN_READY" "$FM_PROCEVENT_CLAIM_ROOT"
bind_package "$H_ORPHAN_READY" "$P_INVOCATION_CLEANUP" ext-invocation-cleanup >/dev/null
for orphan_source in orphan-first orphan-second; do
  FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" register-extension ext-invocation-cleanup "$orphan_source" --config-ref silent-result >/dev/null
done
orphan_root="$H_ORPHAN_READY/state/extension-invocations"
mkdir -p "$orphan_root"
chmod 0700 "$orphan_root"
orphan_token="sha256:$(printf 'a%.0s' {1..64})"
orphan_ready="$orphan_root/${orphan_token#sha256:}.ready.json"
write_orphan_ready() {  # <token> <pid> <identity>
  node - "$orphan_ready" "$1" "$2" "$3" <<'JS'
const fs = require("fs");
const [file, token, pid, identity] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({schema: "firstmate.extension-invocation-ready.v1",
  token, group_pid: Number(pid), group_identity: identity}) + "\n", {mode: 0o600});
JS
}
crash_cleanup_group_pid=$(node - "$ROOT/bin/fm-extension-launch-barrier.mjs" "$orphan_token" <<'JS'
const {spawn} = require("child_process");
const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)", ...process.argv.slice(2)],
  {detached: true, stdio: "ignore"});
console.log(child.pid);
child.unref();
JS
)
write_orphan_ready "$orphan_token" "$crash_cleanup_group_pid" "barrier-token:$orphan_token"
expect_failure "process-cleanup-failed" env FM_HOME="$H_ORPHAN_READY" "$HOST" cleanup-invocations
kill -0 -"$crash_cleanup_group_pid" 2>/dev/null || fail "ownerless cleanup signalled a live fixture group"
assert_present "$orphan_ready" "ownerless cleanup discarded a live group's readiness"
write_orphan_ready "$orphan_token" "$$" "barrier-token:$orphan_token"
expect_failure "process-cleanup-failed" env FM_HOME="$H_ORPHAN_READY" "$HOST" cleanup-invocations
kill -0 "$$" 2>/dev/null || fail "ownerless cleanup signalled a reused PID"
kill -0 -"$crash_cleanup_group_pid" 2>/dev/null || fail "ownerless cleanup signalled an unrelated group"
orphan_dead_pid=$crash_cleanup_group_pid
kill -TERM -"$crash_cleanup_group_pid" 2>/dev/null || fail "cannot stop private orphan fixture group"
for _ in $(seq 1 200); do
  kill -0 -"$crash_cleanup_group_pid" 2>/dev/null || break
  sleep 0.1
done
kill -0 -"$crash_cleanup_group_pid" 2>/dev/null && fail "private orphan fixture group did not exit"
crash_cleanup_group_pid=
write_orphan_ready "sha256:$(printf 'b%.0s' {1..64})" "$orphan_dead_pid" "barrier-token:$orphan_token"
expect_failure "process-cleanup-failed" env FM_HOME="$H_ORPHAN_READY" "$HOST" cleanup-invocations
write_orphan_ready "$orphan_token" "$orphan_dead_pid" "unprovable-identity"
expect_failure "process-cleanup-failed" env FM_HOME="$H_ORPHAN_READY" "$HOST" cleanup-invocations
write_orphan_ready "$orphan_token" "$orphan_dead_pid" "barrier-token:$orphan_token"
chmod 0644 "$orphan_ready"
expect_failure "private host-owned file" env FM_HOME="$H_ORPHAN_READY" "$HOST" cleanup-invocations
chmod 0600 "$orphan_ready"
mv "$orphan_ready" "$TMP_ROOT/orphan-outside.json"
ln -s "$TMP_ROOT/orphan-outside.json" "$orphan_ready"
expect_failure "private host-owned file" env FM_HOME="$H_ORPHAN_READY" "$HOST" cleanup-invocations
assert_present "$TMP_ROOT/orphan-outside.json" "cleanup followed an unsafe readiness symlink"
mv "$orphan_ready" "$TMP_ROOT/orphan-symlink"
mv "$TMP_ROOT/orphan-outside.json" "$orphan_ready"
orphan_cleaned=$(FM_HOME="$H_ORPHAN_READY" "$HOST" cleanup-invocations --source-id orphan-first)
assert_contains "$orphan_cleaned" "cleaned-invocations: 1" "dead exact-token orphan readiness was not reclaimed"
assert_absent "$orphan_ready" "dead orphan readiness survived successful cleanup"
pass "ownerless readiness recovers only dead exact-token groups and refuses unsafe or unproved ownership"

# One malformed residue must neither silently disable both sources nor wake on
# every reconcile.
write_orphan_ready "$orphan_token" "$orphan_dead_pid" "unprovable-identity"
for _ in 1 2; do
  orphan_reconcile=$(FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" reconcile)
  assert_contains "$orphan_reconcile" "uncertain=2" "unsafe residue did not preserve both sources"
done
for orphan_source in orphan-first orphan-second; do
  orphan_wakes=$(wake_payloads "$H_ORPHAN_READY" | grep -c "source $orphan_source .*cleanup" || true)
  [ "$orphan_wakes" -eq 1 ] || fail "cleanup uncertainty must wake once per source failure episode: $orphan_wakes"
done
write_orphan_ready "$orphan_token" "$orphan_dead_pid" "barrier-token:$orphan_token"
orphan_reconcile=$(FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" reconcile)
assert_contains "$orphan_reconcile" "started=2" "dead orphan readiness blocked recovery of two extension sources"
assert_contains "$orphan_reconcile" "uncertain=0" "recovered extension sources remained uncertain"
# Reconcile confirms each launch, not its completion. Each recovered runner owns
# its poll, capture, silent verdict, and terminal retirement, and the two take
# their verdicts in turn under this home's extension lifecycle lock, so a loaded
# host stretches the pair past any fixed marker poll. Wait for the recorded
# runner groups to exit instead, and stop any survivor before failing.
orphan_runners=()
for orphan_source in orphan-first orphan-second; do
  orphan_runner=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/$orphan_source.claim" 2>/dev/null || true)
  [ -z "$orphan_runner" ] || orphan_runners+=("$orphan_source:$orphan_runner")
done
orphan_wait_seconds=$EXTENSION_SECTION_LANE_MAX_SECONDS
if [ -n "${FM_EXTENSION_BINDING_LANE_DEADLINE_EPOCH:-}" ]; then
  orphan_remaining=$((FM_EXTENSION_BINDING_LANE_DEADLINE_EPOCH - $(date +%s) - 3))
  [ "$orphan_remaining" -ge "$orphan_wait_seconds" ] || orphan_wait_seconds=$orphan_remaining
  [ "$orphan_wait_seconds" -ge 1 ] || orphan_wait_seconds=1
fi
orphan_deadline=$((SECONDS + orphan_wait_seconds))
while :; do
  orphan_live=()
  for orphan_runner in "${orphan_runners[@]+"${orphan_runners[@]}"}"; do
    kill -0 -"${orphan_runner#*:}" 2>/dev/null && orphan_live+=("$orphan_runner")
  done
  [ "${#orphan_live[@]}" -gt 0 ] && [ "$SECONDS" -lt "$orphan_deadline" ] || break
  sleep 0.1
done
if [ "${#orphan_live[@]}" -gt 0 ]; then
  # Killing the runner groups strands their detached invocation groups, which
  # the home sweep's invocation cleanup then reclaims as host-crash residue.
  for orphan_runner in "${orphan_live[@]}"; do
    kill -KILL -"${orphan_runner#*:}" 2>/dev/null || true
  done
  FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" sweep-home >/dev/null 2>&1 || true
  fail "recovered source ${orphan_live[*]%%:*} did not finish within ${orphan_wait_seconds}s"
fi
for orphan_source in orphan-first orphan-second; do
  assert_present "$H_ORPHAN_READY/state/procevent-inbox/$orphan_source.1.handled" \
    "recovered source $orphan_source never handled its private result"
  assert_absent "$H_ORPHAN_READY/state/procevent/$orphan_source.source" "recovered terminal source did not retire"
  assert_absent "$FM_PROCEVENT_CLAIM_ROOT/$orphan_source.claim" "recovered terminal source retained its claim"
done
assert_absent "$orphan_ready" "reconcile did not reclaim dead orphan readiness"
pass "reconcile durably announces cleanup uncertainty once and recovers both extension sources"

surface_orphan_wakes() {
  FM_HOME="$H_ORPHAN_READY" bash -c '
    . "$1/bin/fm-watch.sh"
    procevent_surface_queued
  ' _ "$ROOT"
}
for orphan_recovery in attached live; do
  orphan_source="orphan-$orphan_recovery"
  orphan_config=no-result
  if [ "$orphan_recovery" = live ]; then
    active_runner_marker="$TMP_ROOT/orphan-live.marker"
    active_runner_release="$TMP_ROOT/orphan-live.release"
    orphan_config="no-result-block|$active_runner_marker|$active_runner_release"
  fi
  orphan_registration=$(FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" register-extension ext-invocation-cleanup "$orphan_source" --config-ref "$orphan_config") \
    || fail "could not register $orphan_source"
  orphan_owner=$(printf '%s\n' "$orphan_registration" | sed -n 's/^owner-token: //p')
  [ -n "$orphan_owner" ] || fail "registration returned no retirement identity for $orphan_source"
  write_orphan_ready "$orphan_token" "$orphan_dead_pid" "unprovable-identity"
  for _ in 1 2; do
    orphan_reconcile=$(FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" reconcile)
    assert_contains "$orphan_reconcile" "uncertain=1" "cleanup episode did not preserve $orphan_source"
  done
  orphan_wakes=$(wake_payloads "$H_ORPHAN_READY" | grep -c "source $orphan_source .*cleanup" || true)
  [ "$orphan_wakes" -eq 1 ] || fail "first cleanup episode must wake once for $orphan_source: $orphan_wakes"
  orphan_headline=$(surface_orphan_wakes) || fail "watcher could not deliver cleanup failure wakes"
  assert_contains "$orphan_headline" "process-event source failed to start:" "cleanup failure delivered the wrong headline"
  assert_not_contains "$orphan_headline" "process-event result captured:" "cleanup uncertainty was presented as captured evidence"
  assert_contains "$orphan_headline" "procevent:$orphan_source:launch-failed:" "watcher omitted $orphan_source cleanup failure"
  cp "$H_ORPHAN_READY/state/procevent/.$orphan_source.cleanup-failed" "$TMP_ROOT/orphan.previous-episode" \
    || fail "could not retain the previous cleanup episode"
  write_orphan_ready "$orphan_token" "$orphan_dead_pid" "barrier-token:$orphan_token"
  FM_HOME="$H_ORPHAN_READY" "$HOST" cleanup-invocations >/dev/null
  if [ "$orphan_recovery" = attached ]; then
    FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" start "$orphan_source" > "$TMP_ROOT/orphan-attached.out" \
      || fail "attached start did not recover after public cleanup"
  else
    FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" start "$orphan_source" > "$TMP_ROOT/orphan-live.out" 2>&1 &
    active_runner_pid=$!
    wait_for_file "$active_runner_marker" || fail "live recovery source never entered extension code"
    cp "$TMP_ROOT/orphan.previous-episode" "$H_ORPHAN_READY/state/procevent/.$orphan_source.cleanup-failed" \
      || fail "could not restore a prior cleanup episode for live-owner recovery"
    orphan_reconcile=$(FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" reconcile)
    assert_contains "$orphan_reconcile" "uncertain=0" "live-owner recovery remained uncertain"
    assert_absent "$H_ORPHAN_READY/state/procevent/.$orphan_source.cleanup-failed" "live-owner recovery retained a prior cleanup episode"
    touch "$active_runner_release"
    wait "$active_runner_pid" || fail "live recovery source did not complete successfully"
    active_runner_pid=
    active_runner_release=
  fi
  assert_present "$H_ORPHAN_READY/state/procevent/$orphan_source.source" "no-result recovery replaced its registration"
  assert_absent "$H_ORPHAN_READY/state/procevent/.$orphan_source.cleanup-failed" "$orphan_recovery recovery retained its prior cleanup episode"
  write_orphan_ready "$orphan_token" "$orphan_dead_pid" "unprovable-identity"
  for _ in 1 2; do
    orphan_reconcile=$(FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" reconcile)
    assert_contains "$orphan_reconcile" "uncertain=1" "second cleanup episode did not preserve $orphan_source"
  done
  orphan_wakes=$(wake_payloads "$H_ORPHAN_READY" | grep -c "source $orphan_source .*cleanup" || true)
  [ "$orphan_wakes" -eq 2 ] || fail "second cleanup episode must wake again for $orphan_source: $orphan_wakes"
  orphan_headline=$(surface_orphan_wakes) || fail "watcher could not deliver the second cleanup episode"
  assert_contains "$orphan_headline" "process-event source failed to start:" "second cleanup episode delivered the wrong headline"
  assert_not_contains "$orphan_headline" "process-event result captured:" "second cleanup episode was presented as captured evidence"
  assert_contains "$orphan_headline" "procevent:$orphan_source:launch-failed:" "watcher suppressed $orphan_source second cleanup episode"
  assert_equals "$(surface_orphan_wakes)" "" "watcher delivered a cleanup failure more than once"
  write_orphan_ready "$orphan_token" "$orphan_dead_pid" "barrier-token:$orphan_token"
  FM_HOME="$H_ORPHAN_READY" "$HOST" cleanup-invocations >/dev/null
  FM_HOME="$H_ORPHAN_READY" "$PROCEVENT" retire "$orphan_source" --if-owner "$orphan_owner" >/dev/null \
    || fail "could not retire the recovered $orphan_source fixture"
done
pass "attached start and live-owner recovery renew cleanup failure wakes with delivered failure headlines"
fi

# --- independent remote envelope, lifecycle, and retirement paths -----------
if section_enabled remote-envelope remote-activation remote-lifecycle remote-retirement; then
wrong_binding_digest="sha256:$(printf '0%.0s' {1..64})"
P_REMOTE="$PACKAGES/remote-transport"
make_package "$P_REMOTE" org.example.remote ext-remote
mkdir "$P_REMOTE/nested"
printf 'nested transfer evidence\n' > "$P_REMOTE/nested/evidence.txt"
chmod 0755 "$P_REMOTE/nested"
chmod 0644 "$P_REMOTE/nested/evidence.txt"
H_REMOTE_CONTROL="$HOMES/remote-control"
H_REMOTE="$HOMES/remote-home"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_FAKEBIN=$(fm_fakebin "$TMP_ROOT/remote-fakebin")
REMOTE_SSH_COUNT="$TMP_ROOT/remote-ssh.count"
mkdir -p "$H_REMOTE_CONTROL/data" "$H_REMOTE" "$REMOTE_ROOT/bin"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
for remote_file in \
  fm-extension.mjs fm-extension-deadline.mjs fm-extension-launch-barrier.mjs fm-extension.sh fm-procevent.sh fm-procevent-lib.sh fm-procevent-extension-capture.pl fm-procevent-lavish.sh \
  fm-pr-lib.sh fm-wake-lib.sh fm-path-lib.sh fm-remote-entrypoint.sh fm-remote-job-lib.sh \
  fm-remote-job-worker.sh; do
  cp "$ROOT/bin/$remote_file" "$REMOTE_ROOT/bin/$remote_file"
done
chmod +x "$REMOTE_ROOT/bin"/fm-*.sh "$REMOTE_ROOT/bin/fm-extension.mjs" "$REMOTE_ROOT/bin/fm-extension-launch-barrier.mjs"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote extension fixture'
cat > "$H_REMOTE_CONTROL/data/secondmates.md" <<EOF
- ios - remote extension home (host: remote-mac; root: $REMOTE_ROOT; home: $H_REMOTE; scope: extension test; projects: none; added 2026-08-27)
EOF
cat > "$REMOTE_FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$REMOTE_FAKEBIN/fake-ssh"
remote_on() {
  FM_HOME="$H_REMOTE_CONTROL" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$REMOTE_FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$REMOTE_SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$ROOT/bin/fm-on.sh" --stdin ios "$@"
}
remote_controller() {
  FM_HOME="$H_REMOTE_CONTROL" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$REMOTE_FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$REMOTE_SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$@"
}
remote_receive_file() {
  local file=$1 adapter=$2
  remote_on fm-extension.sh receive-transfer-bind \
    --adapter "$adapter" --trust-same-user-code < "$file"
}
remote_direct() {
  local command=$1
  shift
  FM_HOME="$H_REMOTE" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$REMOTE_ROOT/bin/$command" "$@"
}
remote_receive_file_direct() {
  local file=$1 adapter=$2
  remote_direct fm-extension.sh receive-transfer-bind \
    --adapter "$adapter" --trust-same-user-code < "$file"
}

if section_enabled remote-envelope; then
REMOTE_TRANSFER="$TMP_ROOT/remote-transfer.json"
FM_HOME="$H_REMOTE_CONTROL" "$HOST" pack-transfer "$P_REMOTE" > "$REMOTE_TRANSFER"
mutate_transfer() {
  node - "$REMOTE_TRANSFER" "$1" "$2" <<'JS'
const fs = require("fs");
const crypto = require("crypto");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const scenario = process.argv[3];
if (scenario === "traversal") value.manifest.entries[0].path = "../escape";
if (scenario === "symlink") value.manifest.entries[0].type = "symlink";
if (scenario === "hash") value.payloads[value.payloads.findIndex((entry) => typeof entry === "string")] = "eA==";
if (scenario === "size") value.manifest.entries.find((entry) => entry.type === "file").size = 262145;
if (scenario === "duplicate") value.manifest.entries[1].path = value.manifest.entries[0].path;
if (scenario === "unexpected") {
  const index = value.manifest.entries.findIndex((entry) => entry.type === "directory");
  value.manifest.entries.splice(index, 1);
  value.payloads.splice(index, 1);
  value.manifest.entry_count -= 1;
}
if (scenario !== "hash") {
  const canonical = (entry) => Array.isArray(entry)
    ? `[${entry.map(canonical).join(",")}]`
    : entry && typeof entry === "object"
      ? `{${Object.keys(entry).sort().map((key) => `${JSON.stringify(key)}:${canonical(entry[key])}`).join(",")}}`
      : JSON.stringify(entry);
  value.manifest_sha256 = `sha256:${crypto.createHash("sha256").update(canonical(value.manifest)).digest("hex")}`;
}
fs.writeFileSync(process.argv[4], JSON.stringify(value));
JS
}
for transfer_case in traversal symlink hash size duplicate unexpected; do
  bad_transfer="$TMP_ROOT/remote-transfer-$transfer_case.json"
  mutate_transfer "$transfer_case" "$bad_transfer"
  case "$transfer_case" in
    traversal) transfer_error="path-unsafe" ;;
    symlink) transfer_error="package-invalid" ;;
    hash) transfer_error=integrity-mismatch ;;
    size|duplicate) transfer_error=schema-invalid ;;
    unexpected) transfer_error="package-invalid" ;;
  esac
  expect_failure "$transfer_error" remote_receive_file_direct "$bad_transfer" ext-remote
done
printf '{broken' > "$TMP_ROOT/remote-transfer-malformed.json"
head -c 80 "$REMOTE_TRANSFER" > "$TMP_ROOT/remote-transfer-truncated.json"
expect_failure "package transfer has a non-string object key" remote_receive_file "$TMP_ROOT/remote-transfer-malformed.json" ext-remote
expect_failure "json-invalid" remote_receive_file_direct "$TMP_ROOT/remote-transfer-truncated.json" ext-remote
assert_absent "$H_REMOTE/config/extensions.d/org.example.remote.json" "invalid transfer published a remote binding"
if find "$H_REMOTE/data/extensions/staging" -name '.receive-*' -print 2>/dev/null | grep -q .; then
  fail "invalid transfer left a partial receive directory"
fi
pass "remote receiver rejects malformed, truncated, traversal, link, hash, size, duplicate, and incomplete envelopes"

P_REMOTE_PARTIAL="$PACKAGES/remote-partial"
make_package "$P_REMOTE_PARTIAL" org.example.remote-partial ext-remote-partial handshake-malformed
FM_HOME="$H_REMOTE_CONTROL" "$HOST" pack-transfer "$P_REMOTE_PARTIAL" > "$TMP_ROOT/remote-partial.json"
expect_failure "error[" remote_receive_file_direct "$TMP_ROOT/remote-partial.json" ext-remote-partial
assert_absent "$H_REMOTE/config/extensions.d/org.example.remote-partial.json" "failed remote activation published a binding"
if find "$H_REMOTE/data/extensions/staging/org.example.remote-partial" -mindepth 2 -maxdepth 2 -type d -print 2>/dev/null | grep -q .; then
  fail "failed remote activation left a published staging package"
fi
find "$H_REMOTE/data/extensions/retired-staging/org.example.remote-partial" -mindepth 2 -maxdepth 2 -type d -print 2>/dev/null | grep -q . \
  || fail "failed remote activation was not retained reversibly"
pass "failed activation cannot partially publish and retains exact transfer evidence"

[ "$(cat "$REMOTE_SSH_COUNT")" -eq 1 ] || fail "remote malformed-envelope transport crossing was not retained"
fi

if section_enabled remote-activation; then
remote_bind=$(remote_controller "$ROOT/bin/fm-extension.sh" remote-bind ios "$P_REMOTE" --adapter ext-remote --trust-same-user-code)
assert_contains "$remote_bind" "bound: org.example.remote@1.2.3" "remote transport did not publish the binding"
remote_transfer_digest=$(printf '%s\n' "$remote_bind" | sed -n 's/^transfer-digest: //p')
case "$remote_transfer_digest" in sha256:*) ;; *) fail "remote bind returned no transfer identity" ;; esac
remote_binding_digest=$(printf '%s\n' "$remote_bind" | sed -n 's/^binding-digest: //p')
case "$remote_binding_digest" in sha256:*) ;; *) fail "remote bind returned no binding retirement identity" ;; esac
assert_contains "$(remote_direct fm-extension.sh list)" "org.example.remote" "addressed remote home did not discover the transferred binding"
remote_package_root=$(binding_value "$H_REMOTE" org.example.remote package_root)
case "$remote_package_root" in "$H_REMOTE"/data/extensions/packages/*) ;; *) fail "remote package escaped its addressed home: $remote_package_root" ;; esac
remote_source_root=$(binding_value "$H_REMOTE" org.example.remote source.path)
case "$remote_source_root" in "$H_REMOTE"/data/extensions/staging/*/package) ;; *) fail "remote binding reused a controller-local pathname: $remote_source_root" ;; esac
[ "$remote_source_root" != "$P_REMOTE" ] || fail "remote binding did not cross the serialized path boundary"
remote_active_marker="$TMP_ROOT/remote-active.marker"
remote_active_release="$TMP_ROOT/remote-active.release"
remote_active_config="active-block|$remote_active_marker|$remote_active_release"
remote_direct fm-procevent.sh register-extension ext-remote remote-active-source --config-ref "$remote_active_config" >/dev/null
remote_direct fm-procevent.sh reconcile >/dev/null
wait_for_file "$remote_active_marker" || fail "remote active runner never reached its addressed-home poll"
expect_failure "prior runner remains active" remote_direct fm-procevent.sh register-extension ext-remote remote-active-source --config-ref replacement
expect_failure "prior runner remains active" remote_direct fm-procevent.sh register lavish remote-active-source -- /bin/echo remote-built-in
touch "$remote_active_release"
remote_active_release=
for _ in $(seq 1 400); do
  [ ! -e "$H_REMOTE/state/procevent/remote-active-source.source" ] && break
  sleep 0.01
done
assert_absent "$H_REMOTE/state/procevent/remote-active-source.source" "remote terminal runner retained its registration"
remote_direct fm-procevent.sh handled remote-active-source 1 >/dev/null
remote_direct fm-procevent.sh register lavish remote-active-source -- /bin/echo remote-built-in >/dev/null
remote_direct fm-procevent.sh retire remote-active-source --if-matches lavish -- /bin/echo remote-built-in >/dev/null
remote_active_replacement=$(remote_direct fm-procevent.sh register-extension ext-remote remote-active-source --config-ref replacement)
remote_active_owner=$(printf '%s\n' "$remote_active_replacement" | sed -n 's/^owner-token: //p')
remote_direct fm-procevent.sh retire remote-active-source --if-owner "$remote_active_owner" >/dev/null
pass "remote registration owner transitions observe the active runner boundary"
fi

if section_enabled remote-lifecycle; then
remote_bind=$(remote_controller "$ROOT/bin/fm-extension.sh" remote-bind ios "$P_REMOTE" --adapter ext-remote --trust-same-user-code)
assert_contains "$remote_bind" "bound: org.example.remote@1.2.3" "remote transport did not publish the binding"
remote_transfer_digest=$(printf '%s\n' "$remote_bind" | sed -n 's/^transfer-digest: //p')
case "$remote_transfer_digest" in sha256:*) ;; *) fail "remote bind returned no transfer identity" ;; esac
remote_binding_digest=$(printf '%s\n' "$remote_bind" | sed -n 's/^binding-digest: //p')
case "$remote_binding_digest" in sha256:*) ;; *) fail "remote bind returned no binding retirement identity" ;; esac
assert_contains "$(remote_direct fm-extension.sh list)" "org.example.remote" "addressed remote home did not discover the transferred binding"
remote_package_root=$(binding_value "$H_REMOTE" org.example.remote package_root)
case "$remote_package_root" in "$H_REMOTE"/data/extensions/packages/*) ;; *) fail "remote package escaped its addressed home: $remote_package_root" ;; esac
remote_source_root=$(binding_value "$H_REMOTE" org.example.remote source.path)
case "$remote_source_root" in "$H_REMOTE"/data/extensions/staging/*/package) ;; *) fail "remote binding reused a controller-local pathname: $remote_source_root" ;; esac
[ "$remote_source_root" != "$P_REMOTE" ] || fail "remote binding did not cross the serialized path boundary"
remote_registration=$(remote_direct fm-procevent.sh register-extension ext-remote remote-source --config-ref remote-result)
remote_owner=$(printf '%s\n' "$remote_registration" | sed -n 's/^owner-token: //p')
expect_failure "still owns process-event registration" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest"
remote_resolution=$(remote_direct fm-extension.sh resolve-process-event ext-remote)
IFS=$'\t' read -r _remote_schema remote_id remote_version remote_capability remote_package remote_binding remote_extra <<< "$remote_resolution"
[ -z "$remote_extra" ] || fail "remote resolution returned extra fields"
remote_result=$(remote_direct fm-extension.sh process-event ext-remote source.poll \
  --expect-extension "$remote_id" \
  --expect-version "$remote_version" \
  --expect-capability-version "$remote_capability" \
  --expect-package-digest "$remote_package" \
  --expect-binding-digest "$remote_binding" \
  --source-id remote-source \
  --config-ref remote-result \
  --request-id "sha256:$(printf '6%.0s' {1..64})")
assert_contains "$remote_result" "external evidence: remote-result" "addressed remote invocation returned no extension evidence"
remote_direct fm-procevent.sh start remote-source >/dev/null
assert_present "$H_REMOTE/state/procevent-inbox/remote-source.1.result" "remote runner did not capture its extension result"
remote_direct fm-procevent.sh retire remote-source --if-owner "$remote_owner" >/dev/null
assert_absent "$H_REMOTE/state/procevent/remote-source.source" "remote owner-matched retirement left its registration"
expect_failure "unhandled process-event result" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest"
remote_direct fm-procevent.sh handled remote-source 1 >/dev/null
remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest" >/dev/null
assert_absent "$H_REMOTE/config/extensions.d/org.example.remote.json" "remote lifecycle retirement left its binding discoverable"
[ "$(cat "$REMOTE_SSH_COUNT")" -eq 1 ] || fail "remote lifecycle transport crossing count diverged"
pass "serialized remote binding crosses fm-on through addressed-home capture and retirement"
fi

if section_enabled remote-retirement; then
REMOTE_TRANSFER="$TMP_ROOT/remote-retirement-transfer.json"
FM_HOME="$H_REMOTE_CONTROL" "$HOST" pack-transfer "$P_REMOTE" > "$REMOTE_TRANSFER"
remote_bind=$(remote_receive_file_direct "$REMOTE_TRANSFER" ext-remote)
remote_transfer_digest=$(printf '%s\n' "$remote_bind" | sed -n 's/^transfer-digest: //p')
remote_binding_digest=$(printf '%s\n' "$remote_bind" | sed -n 's/^binding-digest: //p')
case "$remote_transfer_digest:$remote_binding_digest" in sha256:*:sha256:*) ;; *) fail "direct remote binding returned incomplete identities" ;; esac
remote_source_root=$(binding_value "$H_REMOTE" org.example.remote source.path)
remote_registration=$(remote_direct fm-procevent.sh register-extension ext-remote remote-source --config-ref remote-result)
remote_owner=$(printf '%s\n' "$remote_registration" | sed -n 's/^owner-token: //p')
remote_resolution=$(remote_direct fm-extension.sh resolve-process-event ext-remote)
IFS=$'\t' read -r _remote_schema remote_id remote_version remote_capability remote_package remote_binding remote_extra <<< "$remote_resolution"
[ -z "$remote_extra" ] || fail "remote retirement resolution returned extra fields"
remote_result=$(remote_direct fm-extension.sh process-event ext-remote source.poll \
  --expect-extension "$remote_id" --expect-version "$remote_version" \
  --expect-capability-version "$remote_capability" --expect-package-digest "$remote_package" \
  --expect-binding-digest "$remote_binding" --source-id remote-source --config-ref remote-result \
  --request-id "sha256:$(printf '6%.0s' {1..64})")
assert_contains "$remote_result" "external evidence: remote-result" "retirement fixture did not invoke its addressed extension"
remote_direct fm-procevent.sh start remote-source >/dev/null
assert_present "$H_REMOTE/state/procevent-inbox/remote-source.1.result" "retirement fixture did not capture its result"
remote_direct fm-procevent.sh retire remote-source --if-owner "$remote_owner" >/dev/null
assert_absent "$H_REMOTE/state/procevent/remote-source.source" "retirement fixture owner retirement left its registration"
remote_stage_root=${remote_source_root%/package}
remote_receipt="$remote_stage_root/receipt.json"
wrong_binding_digest="sha256:$(printf '0%.0s' {1..64})"
expect_failure "unhandled process-event result" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest"
remote_direct fm-procevent.sh handled remote-source 1 >/dev/null
expect_failure "expected binding identity" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$wrong_binding_digest"
assert_present "$H_REMOTE/config/extensions.d/org.example.remote.json" "stale binding identity retired the remote binding"
expect_failure "no unique staged package" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$wrong_binding_digest" --if-binding-digest "$remote_binding_digest"
cp "$remote_receipt" "$TMP_ROOT/remote-receipt.json"
node - "$remote_receipt" <<'JS'
const fs = require("fs");
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.package_digest = `sha256:${"f".repeat(64)}`;
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
JS
chmod 0600 "$remote_receipt"
expect_failure "staged package identity" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest"
cp "$TMP_ROOT/remote-receipt.json" "$remote_receipt"
chmod 0600 "$remote_receipt"
cp "$remote_source_root/helper.txt" "$TMP_ROOT/remote-helper.txt"
printf 'drifted staged bytes\n' > "$remote_source_root/helper.txt"
expect_failure "staged package identity" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest"
cp "$TMP_ROOT/remote-helper.txt" "$remote_source_root/helper.txt"
chmod 0644 "$remote_source_root/helper.txt"
remote_version_root=${remote_stage_root%/*}
remote_wrong_version="${remote_version_root%/*}/9.9.9"
mv "$remote_version_root" "$remote_wrong_version"
expect_failure "version directory" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest"
mv "$remote_wrong_version" "$remote_version_root"
P_REMOTE_OTHER="$PACKAGES/remote-other"
make_package "$P_REMOTE_OTHER" org.example.remote-other ext-remote-other
REMOTE_OTHER_TRANSFER="$TMP_ROOT/remote-other-transfer.json"
FM_HOME="$H_REMOTE_CONTROL" "$HOST" pack-transfer "$P_REMOTE_OTHER" > "$REMOTE_OTHER_TRANSFER"
remote_other_bind=$(remote_receive_file_direct "$REMOTE_OTHER_TRANSFER" ext-remote-other)
remote_other_transfer=$(printf '%s\n' "$remote_other_bind" | sed -n 's/^transfer-digest: //p')
remote_other_binding=$(printf '%s\n' "$remote_other_bind" | sed -n 's/^binding-digest: //p')
remote_binding_path="$H_REMOTE/config/extensions.d/org.example.remote.json"
remote_partial_binding="$remote_stage_root/binding.json"
cp "$remote_binding_path" "$remote_partial_binding"
expect_failure "enabled and partial binding state" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest"
rm -f "$remote_partial_binding"
cp "$remote_binding_path" "$TMP_ROOT/remote-binding.json"
mv "$remote_binding_path" "$remote_partial_binding"
printf ' ' >> "$remote_partial_binding"
expect_failure "partial binding does not match" remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest"
cp "$TMP_ROOT/remote-binding.json" "$remote_partial_binding"
chmod 0600 "$remote_partial_binding"
remote_direct fm-extension.sh retire-transfer org.example.remote \
  --if-transfer-digest "$remote_transfer_digest" --if-binding-digest "$remote_binding_digest" >/dev/null
assert_absent "$H_REMOTE/data/extensions/staging/org.example.remote/1.2.3/${remote_transfer_digest#sha256:}" "remote staged package was not retired"
assert_present "$H_REMOTE/data/extensions/retired-staging/org.example.remote/1.2.3/${remote_transfer_digest#sha256:}/package" "remote staged package retirement was not reversible"
assert_present "$H_REMOTE/data/extensions/retired-staging/org.example.remote/1.2.3/${remote_transfer_digest#sha256:}/binding.json" "remote enabled binding was not retained with its exact transfer"
assert_absent "$H_REMOTE/config/extensions.d/org.example.remote.json" "remote enabled binding remained discoverable after retirement"
expect_failure "no home-local extension binding" remote_direct fm-extension.sh resolve-process-event ext-remote
assert_contains "$(remote_direct fm-extension.sh list)" "org.example.remote-other" "retirement changed an unrelated remote binding"
remote_direct fm-extension.sh verify org.example.remote-other >/dev/null
pass "remote retirement refuses ambiguous drift and resumes an exact crash cut"
remote_direct fm-extension.sh retire-transfer org.example.remote-other \
  --if-transfer-digest "$remote_other_transfer" --if-binding-digest "$remote_other_binding" >/dev/null
assert_absent "$H_REMOTE_CONTROL/config/extensions.d/org.example.remote.json" "remote binding was published into the local control home"
pass "remote retirement and refusal checks run against an isolated addressed home"
fi
fi

# --- shipped runnable example ------------------------------------------------
if section_enabled example; then
P_EXAMPLE="$PACKAGES/file-signal-example"
cp -R "$ROOT/docs/examples/process-event-extension" "$P_EXAMPLE"
chmod 0755 "$P_EXAMPLE" "$P_EXAMPLE/file-signal.mjs"
chmod 0644 "$P_EXAMPLE/firstmate-extension.json"
H_EXAMPLE="$HOMES/example"; new_home "$H_EXAMPLE"
bind_package "$H_EXAMPLE" "$P_EXAMPLE" file-signal --consent artifact-references >/dev/null
SIGNAL_FILE="$TMP_ROOT/example-result.txt"
example_registration=$(FM_HOME="$H_EXAMPLE" "$PROCEVENT" register-extension file-signal example-file --config-ref "file:$SIGNAL_FILE")
example_token=$(printf '%s\n' "$example_registration" | sed -n 's/^owner-token: //p')
FM_HOME="$H_EXAMPLE" "$PROCEVENT" start example-file > "$TMP_ROOT/example-start.out" &
example_start=$!
for _ in $(seq 1 100); do
  [ -f "$FM_PROCEVENT_CLAIM_ROOT/example-file.claim" ] && break
  sleep 0.05
done
assert_present "$FM_PROCEVENT_CLAIM_ROOT/example-file.claim" "example source never started waiting"
printf 'build 42 completed successfully\n' > "$SIGNAL_FILE"
wait "$example_start" || fail "example source failed after its file appeared"
example_result=$(first_result "$H_EXAMPLE" example-file) || fail "example captured no file result"
assert_grep 'build 42 completed successfully' "$example_result" "example did not preserve external evidence"
assert_contains "$(FM_HOME="$H_EXAMPLE" "$PROCEVENT" classify "$example_result")" "file-signal" "example result did not classify through the package"
assert_absent "$H_EXAMPLE/state/procevent/example-file.source" "example terminal result did not retire its source"
FM_HOME="$H_EXAMPLE" "$PROCEVENT" retire example-file --if-owner "$example_token" >/dev/null
pass "the shipped file-signal package is a runnable end-to-end external adapter"

# The same home spelled through a symlinked ancestor must capture external
# evidence identically, including the external capture path's pinned staging,
# inbox, and reservation boundaries.
ln -s "$HOMES" "$TMP_ROOT/homes-through-symlink"
H_EXAMPLE_SYMLINKED="$TMP_ROOT/homes-through-symlink/example"
SIGNAL_FILE_SYMLINKED="$TMP_ROOT/example-symlinked-result.txt"
symlinked_registration=$(FM_HOME="$H_EXAMPLE_SYMLINKED" "$PROCEVENT" register-extension file-signal example-symlinked \
  --config-ref "file:$SIGNAL_FILE_SYMLINKED")
symlinked_token=$(printf '%s\n' "$symlinked_registration" | sed -n 's/^owner-token: //p')
FM_HOME="$H_EXAMPLE_SYMLINKED" "$PROCEVENT" start example-symlinked > "$TMP_ROOT/example-symlinked-start.out" &
symlinked_start=$!
for _ in $(seq 1 100); do
  [ -f "$FM_PROCEVENT_CLAIM_ROOT/example-symlinked.claim" ] && break
  sleep 0.05
done
assert_present "$FM_PROCEVENT_CLAIM_ROOT/example-symlinked.claim" \
  "a home reached through a symlinked ancestor never started its external source"
printf 'build 43 completed successfully\n' > "$SIGNAL_FILE_SYMLINKED"
wait "$symlinked_start" \
  || fail "a home reached through a symlinked ancestor failed its external source"
symlinked_result=$(first_result "$H_EXAMPLE" example-symlinked) \
  || fail "a home reached through a symlinked ancestor captured no external result"
assert_grep 'build 43 completed successfully' "$symlinked_result" \
  "the symlinked-ancestor home did not preserve external evidence"
FM_HOME="$H_EXAMPLE_SYMLINKED" "$PROCEVENT" retire example-symlinked --if-owner "$symlinked_token" >/dev/null
pass "a home reached through a symlinked ancestor captures external evidence normally"

P_HANDSHAKE_ORPHAN="$PACKAGES/handshake-orphan"
P_HANDSHAKE_RECOVER="$PACKAGES/handshake-recover"
handshake_orphan_pid_file="$TMP_ROOT/handshake-orphan.pid"
make_package "$P_HANDSHAKE_ORPHAN" org.example.handshake-orphan ext-handshake-orphan "$(printf 'handshake-leak\n%s' "$handshake_orphan_pid_file")"
make_package "$P_HANDSHAKE_RECOVER" org.example.handshake-orphan ext-handshake-orphan
H_HANDSHAKE_ORPHAN="$HOMES/handshake-orphan"; new_home "$H_HANDSHAKE_ORPHAN"
handshake_orphan_rc=0
handshake_orphan_out=$(bind_package "$H_HANDSHAKE_ORPHAN" "$P_HANDSHAKE_ORPHAN" ext-handshake-orphan 2>&1) || handshake_orphan_rc=$?
wait_for_file "$handshake_orphan_pid_file" || fail "handshake leak fixture did not start its foreground child"
handshake_orphan_pid=$(cat "$handshake_orphan_pid_file")
[ "$handshake_orphan_rc" -ne 0 ] || fail "a handshake orphan was accepted as a successful binding"
assert_contains "$handshake_orphan_out" "process-leak" "handshake leak did not reject binding publication"
assert_absent "$H_HANDSHAKE_ORPHAN/config/extensions.d/org.example.handshake-orphan.json" "handshake orphan published an enabled binding"
kill -0 "$handshake_orphan_pid" 2>/dev/null && fail "handshake leak escaped invocation-group cleanup"
for _ in $(seq 1 50); do
  kill -0 "$handshake_orphan_pid" 2>/dev/null || break
  sleep 0.05
done
handshake_orphan_pid=
bind_package "$H_HANDSHAKE_ORPHAN" "$P_HANDSHAKE_RECOVER" ext-handshake-orphan >/dev/null
assert_contains "$(FM_HOME="$H_HANDSHAKE_ORPHAN" "$HOST" verify org.example.handshake-orphan)" "verified: org.example.handshake-orphan@1.2.3" \
  "cleaned handshake state did not permit safe binding"
pass "handshake execution rejects and reaps foreground descendants"
fi

printf '\nall extension-binding tests passed\n'
