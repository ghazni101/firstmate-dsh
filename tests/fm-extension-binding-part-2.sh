# shellcheck shell=bash
# Part 2 of tests/fm-extension-binding.test.sh, split so no single ShellCheck root
# carries the whole suite. This file is sourced, in order, by that
# runner: it is executable test code, not a definition-only module, and
# it shares the runner's shell state and counters.
# shellcheck disable=SC2034,SC2153,SC2329 # state is shared across the sourced parts

if section_enabled matrix matrix-runtime; then
P_MATRIX="$PACKAGES/matrix"
make_package "$P_MATRIX" org.example.matrix ext-matrix
H_MATRIX="$HOMES/matrix"; new_home "$H_MATRIX"
bind_package "$H_MATRIX" "$P_MATRIX" ext-matrix --timeout-ms 5000 >/dev/null
resolution=$(FM_HOME="$H_MATRIX" "$HOST" resolve-process-event ext-matrix)
IFS=$'\t' read -r resolution_schema resolution_id resolution_version resolution_cap resolution_package resolution_binding resolution_extra <<< "$resolution"
[ "$resolution_schema" = fm-extension-process-event-resolution.v1 ] && [ -z "$resolution_extra" ] \
  || fail "resolution record is malformed: $resolution"

invoke_matrix() {  # <config-ref> [request-id]
  local config_ref=$1 request_id=${2:-} args=()
  [ -z "$request_id" ] || args+=(--request-id "$request_id")
  FM_HOME="$H_MATRIX" "$HOST" process-event ext-matrix source.poll \
    --source-id matrix-source --config-ref "$config_ref" \
    --expect-extension "$resolution_id" --expect-version "$resolution_version" \
    --expect-capability-version "$resolution_cap" \
    --expect-package-digest "$resolution_package" \
    --expect-binding-digest "$resolution_binding" ${args[@]+"${args[@]}"}
}

state_root="$H_MATRIX/state/extensions/org.example.matrix"
if section_enabled matrix; then
shell_sentinel="$TMP_ROOT/extension-shell-sentinel"
literal_ref="\$(touch $shell_sentinel); one arg; *"
literal_out=$(invoke_matrix "$literal_ref")
assert_contains "$literal_out" "$literal_ref" "configuration reference was re-split or interpreted instead of JSON encoded"
assert_absent "$shell_sentinel" "configuration reference unexpectedly executed through a shell"
pass "source configuration references cross one JSON envelope with no shell interpretation"

matrix_cases="$TMP_ROOT/matrix-cases"
mkdir -p "$matrix_cases"
for scenario in malformed invalid-utf8 bom control multiple duplicate wrong-id unknown oversize stderr-oversize nonzero crash leak foreground-leak error-injection authority; do
  rc=0
  out=$(invoke_matrix "$scenario" 2>&1) || rc=$?
  printf '%s\n' "$rc" > "$matrix_cases/$scenario.rc"
  printf '%s' "$out" > "$matrix_cases/$scenario.out"
done
for scenario in malformed invalid-utf8 bom control multiple duplicate wrong-id unknown oversize stderr-oversize nonzero crash leak foreground-leak error-injection authority; do
  rc=$(cat "$matrix_cases/$scenario.rc")
  out=$(cat "$matrix_cases/$scenario.out")
  [ "$rc" -ne 0 ] || fail "invalid extension response was accepted: $scenario"
  assert_contains "$out" 'firstmate.process-event-extension-error.v1' "invalid source response did not become bounded host evidence: $scenario"
  assert_not_contains "$out" "merge_authorized" "authority-shaped extension bytes escaped strict response validation"
  assert_not_contains "$out" "MERGE NOW" "extension diagnostic text escaped into host evidence"
done
leaked_pid=$(cat "$H_MATRIX/state/extensions/org.example.matrix/leaked.pid")
for _ in $(seq 1 50); do
  kill -0 "$leaked_pid" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$leaked_pid" 2>/dev/null && fail "a successful response left its background descendant alive"
rapid_pid=$(cat "$H_MATRIX/state/extensions/org.example.matrix/foreground-leak.pid")
for _ in $(seq 1 50); do
  kill -0 "$rapid_pid" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$rapid_pid" 2>/dev/null && fail "a foreground descendant escaped invocation-group cleanup"
pass "malformed, invalid UTF-8, BOM, control, multiple, duplicate, unknown, oversized, crash, nonzero, stderr, and foreground leaked-process responses are rejected"

overlap_out="$TMP_ROOT/overlap.out"
invoke_matrix overlap >"$overlap_out" &
overlap_invoke_pid=$!
wait_for_file "$state_root/overlap-ready" || fail "overlap fixture never entered its invocation window"
unrelated_pid_file="$TMP_ROOT/unrelated-daemon.pid"
python3 - "$unrelated_pid_file" <<'PY' &
import os, subprocess, sys
child = subprocess.Popen(["/bin/sleep", "300"], cwd="/", start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         env={"LANG":"C", "LC_ALL":"C", "PATH":"/usr/bin:/bin"})
with open(sys.argv[1], "w", encoding="utf-8") as output: output.write(f"{child.pid}\n")
PY
unrelated_launcher_pid=$!
wait_for_file "$unrelated_pid_file" || fail "unrelated daemon launcher never published its child"
unrelated_daemon_pid=$(cat "$unrelated_pid_file")
touch "$state_root/overlap-release"
wait "$overlap_invoke_pid" || {
  cat "$overlap_out" >&2
  fail "a proven-unrelated daemon made a valid extension invocation fail"
}
assert_contains "$(cat "$overlap_out")" "overlap complete" "overlap fixture did not return its valid result"
kill -0 "$unrelated_daemon_pid" 2>/dev/null || fail "extension cleanup terminated an unrelated same-user daemon"
wait "$unrelated_launcher_pid"
unrelated_launcher_pid=
kill -KILL "$unrelated_daemon_pid" 2>/dev/null || true
unrelated_daemon_pid=
pass "process cleanup never adopts a proven-unrelated same-user process"
fi

if section_enabled matrix-runtime; then
fixed_request="sha256:$(printf '1%.0s' $(seq 1 64))"
out_one=$(invoke_matrix replay "$fixed_request")
out_two=$(invoke_matrix replay "$fixed_request")
[ "$out_one" = "$out_two" ] || fail "replaying one exact request identity changed its result"
[ "$(cat "$state_root/side-effect-count")" = 1 ] || fail "the reference adapter applied one replay identity more than once"
pass "an exact request id is matched and supports idempotent replay"

H_CORE_REPLAY="$HOMES/core-replay"; new_home "$H_CORE_REPLAY"
bind_package "$H_CORE_REPLAY" "$P_MATRIX" ext-matrix >/dev/null
core_registration=$(FM_HOME="$H_CORE_REPLAY" "$PROCEVENT" register-extension ext-matrix replay-source --config-ref replay-no-result)
core_token=$(printf '%s\n' "$core_registration" | sed -n 's/^owner-token: //p')
FM_HOME="$H_CORE_REPLAY" "$PROCEVENT" start replay-source >/dev/null
FM_HOME="$H_CORE_REPLAY" "$PROCEVENT" start replay-source >/dev/null
core_request_ids="$H_CORE_REPLAY/state/extensions/org.example.matrix/request-ids"
[ "$(wc -l < "$core_request_ids" | tr -d ' ')" = 2 ] || fail "core replay fixture did not receive two requests"
[ "$(sort -u "$core_request_ids" | wc -l | tr -d ' ')" = 1 ] \
  || fail "retry before durable capture changed the request identity"
[ "$(cat "$H_CORE_REPLAY/state/extensions/org.example.matrix/side-effect-count")" = 1 ] \
  || fail "stable core retry identity applied the fixture effect twice"
FM_HOME="$H_CORE_REPLAY" "$PROCEVENT" retire replay-source --if-owner "$core_token" >/dev/null
pass "the generic runner reuses one request id until that source sequence is durably captured"

P_TIMEOUT="$PACKAGES/timeout"
make_package "$P_TIMEOUT" org.example.timeout ext-timeout
H_TIMEOUT="$HOMES/timeout"; new_home "$H_TIMEOUT"
bind_package "$H_TIMEOUT" "$P_TIMEOUT" ext-timeout --timeout-ms 500 >/dev/null
timeout_resolution=$(FM_HOME="$H_TIMEOUT" "$HOST" resolve-process-event ext-timeout)
IFS=$'\t' read -r timeout_schema timeout_id timeout_version timeout_cap timeout_package timeout_binding timeout_extra <<< "$timeout_resolution"
[ "$timeout_schema" = fm-extension-process-event-resolution.v1 ] && [ -z "$timeout_extra" ] \
  || fail "timeout resolution record is malformed: $timeout_resolution"
rc=0
out=$(FM_HOME="$H_TIMEOUT" "$HOST" process-event ext-timeout source.poll \
  --source-id timeout-source --config-ref timeout \
  --expect-extension "$timeout_id" --expect-version "$timeout_version" \
  --expect-capability-version "$timeout_cap" \
  --expect-package-digest "$timeout_package" --expect-binding-digest "$timeout_binding" 2>/dev/null) || rc=$?
[ "$rc" -ne 0 ] || fail "timed-out extension invocation succeeded"
assert_contains "$out" '"code":"timeout"' "timeout did not produce deterministic bounded evidence"
timeout_state_root="$H_TIMEOUT/state/extensions/org.example.timeout"
wait_for_file "$timeout_state_root/descendant.pid" || fail "timeout fixture never started its descendant"
descendant=$(cat "$timeout_state_root/descendant.pid")
for _ in $(seq 1 50); do
  kill -0 "$descendant" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$descendant" 2>/dev/null && fail "timed-out extension left its descendant alive"
pass "timeout escalates through invocation-group cleanup and reaps descendants"

# A missing installed executable is actionable evidence, never fallback to a
# similarly named command or another adapter.
P_MISSING="$PACKAGES/missing"
make_package "$P_MISSING" org.example.missing ext-missing
H_MISSING="$HOMES/missing"; new_home "$H_MISSING"
bind_package "$H_MISSING" "$P_MISSING" ext-missing >/dev/null
missing_root=$(binding_value "$H_MISSING" org.example.missing package_root)
chmod 0755 "$missing_root"
rm -f "$missing_root/entrypoint.py"
chmod 0555 "$missing_root"
resolution_missing=$(FM_HOME="$H_MISSING" "$HOST" inspect org.example.missing 2>&1 || true)
assert_contains "$resolution_missing" "manifest entrypoint is missing" "missing executable was not diagnosed"
pass "a missing package executable refuses instead of falling back"
fi
fi

# --- repeated host failures remain bounded without blocking recovery --------
if section_enabled lifecycle-host-errors; then
host_error_case() {
  local shape=$1 case_root="$TMP_ROOT/host-error-$1" home package installed binding_file saved_binding
  local source="host-error-$1" expected_code poll_count result_count command round log runner_pid result
  local HOME XDG_STATE_HOME FM_PROCEVENT_CLAIM_ROOT PROCEVENT=$PROCEVENT
  mkdir -p "$case_root/user-home"
  export HOME="$case_root/user-home" XDG_STATE_HOME="$case_root/xdg"
  export FM_PROCEVENT_CLAIM_ROOT="$XDG_STATE_HOME/firstmate/procevent-claims"
  export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=10
  home="$case_root/home"; new_home "$home"
  package="$case_root/package"
  make_package "$package" "org.example.$shape" ext-host-error
  bind_package "$home" "$package" ext-host-error >/dev/null || fail "cannot bind $shape fixture"
  installed=$(binding_value "$home" "org.example.$shape" package_root)
  binding_file="$home/config/extensions.d/org.example.$shape.json"
  fm_test_track_procevent_home "$home" "$FM_PROCEVENT_CLAIM_ROOT"
  FM_HOME="$home" "$PROCEVENT" register-extension ext-host-error "$source" --config-ref replay-no-result >/dev/null \
    || fail "cannot register $shape fixture"
  FM_HOME="$home" "$PROCEVENT" start "$source" > "$case_root/healthy.out" \
    || fail "healthy $shape fixture failed"
  poll_count="$home/state/extensions/org.example.$shape/request-ids"
  [ "$(wc -l < "$poll_count" | tr -d ' ')" -eq 1 ] || fail "healthy poll did not reach adapter"
  case "$shape" in
    package)
      mv "$installed" "$installed.saved"
      expected_code='package-missing'
      ;;
    conflict)
      make_package "$case_root/other-package" org.example.other ext-other
      node -e 'const fs=require("fs"); const p=process.argv[1]; const m=JSON.parse(fs.readFileSync(p)); m.capabilities[0].adapter_names.push("ext-host-error"); fs.writeFileSync(p,JSON.stringify(m)+"\n");' \
        "$case_root/other-package/firstmate-extension.json"
      bind_package "$home" "$case_root/other-package" ext-other >/dev/null
      cp "$home/config/extensions.d/org.example.other.json" "$case_root/other-binding.saved"
      node -e 'const fs=require("fs"); const p=process.argv[1]; const b=JSON.parse(fs.readFileSync(p)); b.capabilities[0].adapter_names=["ext-host-error"]; fs.writeFileSync(p,JSON.stringify(b)+"\n");' \
        "$home/config/extensions.d/org.example.other.json"
      expected_code='adapter-conflict'
      ;;
    barrier)
      mkdir -p "$case_root/code"
      cp -R "$ROOT/bin" "$case_root/code/bin"
      mv "$case_root/code/bin/fm-extension-launch-barrier.mjs" "$case_root/code/bin/fm-extension-launch-barrier.original.mjs"
      printf '%s\n' 'await new Promise(resolve => setTimeout(resolve, 15000));' \
        'await import("./fm-extension-launch-barrier.original.mjs");' > "$case_root/code/bin/fm-extension-launch-barrier.mjs"
      PROCEVENT="$case_root/code/bin/fm-procevent.sh"
      expected_code=timeout
      ;;
  esac
  for round in 1 2 3 4 5; do
    command=start
    [ "$round" -lt 3 ] || command=reconcile
    log="$case_root/$round.out"
    if [ "$command" = start ]; then
      FM_HOME="$home" "$PROCEVENT" start "$source" > "$log" 2>&1 || fail "$shape start failed: $(cat "$log")"
    else
      FM_HOME="$home" "$PROCEVENT" reconcile > "$log" 2>&1 || fail "$shape reconcile failed: $(cat "$log")"
      assert_contains "$(cat "$log")" 'started=1' "$shape reconcile did not launch a recovery poll"
    fi
    # Reconcile confirms a launch, not completion. Wait on this private source's
    # recorded runner and claim, so the next command exercises a settled retry.
    for _ in $(seq 1 600); do
      runner_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/$source.claim" 2>/dev/null || true)
      if [ ! -e "$home/state/procevent/$source.runner" ] && [ -z "$runner_pid" ]; then break; fi
      sleep 0.05
    done
    [ -z "$runner_pid" ] || fail "$shape runner did not settle"
    result_count=0
    for result in "$home/state/procevent-inbox/$source".*.result; do
      [ -f "$result" ] || continue
      result_count=$((result_count + 1))
      assert_grep "\"code\":\"$expected_code\"" "$result" "$shape captured the wrong failure"
      assert_absent "${result%.result}.handled" "$shape retry acknowledged its earlier failure"
    done
    [ "$result_count" -eq 1 ] || fail "$shape retry $round allocated $result_count distinct errors"
    [ "$(wc -l < "$poll_count" | tr -d ' ')" -eq 1 ] || fail "$shape failure entered adapter polling"
  done
  assert_contains "$(wake_payloads "$home")" "procevent ext-host-error $source 1" "$shape first failure was suppressed"
  case "$shape" in
    package) mv "$installed.saved" "$installed" ;;
    conflict) cp "$case_root/other-binding.saved" "$home/config/extensions.d/org.example.other.json" ;;
    barrier) mv "$case_root/code/bin/fm-extension-launch-barrier.original.mjs" "$case_root/code/bin/fm-extension-launch-barrier.mjs" ;;
  esac
  FM_HOME="$home" "$PROCEVENT" start "$source" > "$case_root/recovery.out" 2>&1 || fail "$shape recovery failed"
  assert_contains "$(cat "$case_root/recovery.out")" 'no-result:' "$shape recovery did not complete"
  [ "$(wc -l < "$poll_count" | tr -d ' ')" -eq 2 ] || fail "$shape recovery was blocked by old evidence"
  assert_absent "$home/state/procevent-inbox/$source.2.result" "$shape recovery allocated another error"
  assert_absent "$home/state/procevent-inbox/$source.1.handled" "$shape recovery acknowledged old evidence"

  # A changed host failure retains its own durable identity.
  saved_binding="$case_root/binding.saved"
  mv "$binding_file" "$saved_binding"
  FM_HOME="$home" "$PROCEVENT" start "$source" > "$case_root/changed.out" 2>&1 || fail "$shape changed poll failed"
  assert_present "$home/state/procevent-inbox/$source.2.result" "$shape changed host failure was suppressed"
  cmp -s "$home/state/procevent-inbox/$source.1.result" "$home/state/procevent-inbox/$source.2.result" \
    && fail "$shape changed failure was not distinguishable"
  mv "$saved_binding" "$binding_file"
  pass "$shape host failures coalesce across two starts and three reconciles, with recovery and changed evidence"
}
for host_error_shape in package conflict barrier; do
  host_error_case "$host_error_shape" || exit 1
done

# Adapter results may contain the host evidence schema verbatim. Their success
# status must keep identical genuine results distinct and unhandled.
P_IDENTICAL="$PACKAGES/identical"
make_package "$P_IDENTICAL" org.example.identical ext-identical keep-armed
H_IDENTICAL="$HOMES/identical"; new_home "$H_IDENTICAL"
bind_package "$H_IDENTICAL" "$P_IDENTICAL" ext-identical >/dev/null
FM_HOME="$H_IDENTICAL" "$PROCEVENT" register-extension ext-identical identical-source --config-ref host-error-output >/dev/null
for _ in 1 2; do
  FM_HOME="$H_IDENTICAL" "$PROCEVENT" start identical-source > "$TMP_ROOT/identical-start.out" \
    || fail "identical adapter result failed"
done
cmp "$H_IDENTICAL/state/procevent-inbox/identical-source.1.result" "$H_IDENTICAL/state/procevent-inbox/identical-source.2.result" \
  || fail "identical adapter fixture did not emit identical host-shaped bytes"
assert_absent "$H_IDENTICAL/state/procevent-inbox/identical-source.1.handled" "first adapter result was acknowledged"
assert_absent "$H_IDENTICAL/state/procevent-inbox/identical-source.2.handled" "second adapter result was acknowledged"
pass "successful identical adapter results retain distinct sequences even with host-shaped output"
identical_installed=$(binding_value "$H_IDENTICAL" org.example.identical package_root)
mv "$identical_installed" "$identical_installed.saved"
for _ in 1 2; do
  FM_HOME="$H_IDENTICAL" "$PROCEVENT" start identical-source > "$TMP_ROOT/identical-failure.out" \
    || fail "host failure after genuine evidence failed"
done
cmp "$H_IDENTICAL/state/procevent-inbox/identical-source.1.result" "$H_IDENTICAL/state/procevent-inbox/identical-source.3.result" \
  || fail "host and genuine result fixtures did not emit identical bytes"
assert_absent "$H_IDENTICAL/state/procevent-inbox/identical-source.4.result" "repeated host failure allocated another result"
FM_HOME="$H_IDENTICAL" "$PROCEVENT" handled identical-source 3 >/dev/null
FM_HOME="$H_IDENTICAL" "$PROCEVENT" start identical-source > "$TMP_ROOT/identical-after-handled.out" \
  || fail "host failure after acknowledgement failed"
assert_present "$H_IDENTICAL/state/procevent-inbox/identical-source.4.result" "handled host evidence suppressed a fresh failure"
assert_absent "$H_IDENTICAL/state/procevent-inbox/identical-source.4.handled" "fresh failure inherited acknowledgement"
pass "genuine evidence cannot suppress the first host error, and handled errors do not suppress fresh failures"
fi

# --- registration, invocation, unhandled capture, and binding retirement -----
if section_enabled lifecycle-flow; then
P_FLOW="$PACKAGES/flow"
make_package "$P_FLOW" org.example.flow ext-flow
H_FLOW="$HOMES/flow"; new_home "$H_FLOW"
flow_bind=$(bind_package "$H_FLOW" "$P_FLOW" ext-flow)
flow_binding_digest=$(printf '%s\n' "$flow_bind" | sed -n 's/^binding-digest: //p')
case "$flow_binding_digest" in sha256:*) ;; *) fail "local bind returned no binding retirement identity" ;; esac
registration=$(FM_HOME="$H_FLOW" "$PROCEVENT" register-extension ext-flow flow-source --config-ref good)
assert_contains "$registration" "org.example.flow@1.2.3" "extension registration omits its exact owner identity"
owner_one=$(printf '%s\n' "$registration" | sed -n 's/^owner-token: //p')
case "$owner_one" in
  sha256:*) [ "${#owner_one}" -eq 71 ] || fail "registration emitted a malformed owner token" ;;
  *) fail "registration emitted no bounded owner token" ;;
esac
expect_failure "still owns process-event registration" env FM_HOME="$H_FLOW" "$HOST" retire-binding org.example.flow --if-binding-digest "$flow_binding_digest"
assert_grep 'extension_id=org.example.flow' "$H_FLOW/state/procevent/flow-source.source" "registration did not retain extension identity"
assert_grep 'capability_version=1' "$H_FLOW/state/procevent/flow-source.source" "registration did not retain capability version"
assert_grep 'package_digest=sha256:' "$H_FLOW/state/procevent/flow-source.source" "registration did not retain package digest"

FM_HOME="$H_FLOW" "$PROCEVENT" start flow-source > "$TMP_ROOT/flow-start.out"
result=$(first_result "$H_FLOW" flow-source) || fail "external source produced no captured result"
assert_contains "$(wake_payloads "$H_FLOW")" "procevent ext-flow flow-source 1" "external source did not publish the existing bounded event"
assert_absent "${result%.result}.handled" "external evidence was silently treated as handled"
COLLISION_ROOT="$TMP_ROOT/collision-root"
mkdir -p "$COLLISION_ROOT/bin"
cat > "$COLLISION_ROOT/bin/fm-procevent-ext-flow.sh" <<'SH'
#!/usr/bin/env bash
printf 'wrong-built-in-owner\n'
exit 0
SH
chmod +x "$COLLISION_ROOT/bin/fm-procevent-ext-flow.sh"
classification=$(FM_ROOT_OVERRIDE="$COLLISION_ROOT" FM_HOME="$H_FLOW" "$PROCEVENT" classify "$result")
assert_contains "$classification" "external-ready" "captured evidence could not be classified through its immutable owner"
assert_not_contains "$classification" "wrong-built-in-owner" "a later same-name built-in reinterpreted extension evidence"
assert_absent "$H_FLOW/state/procevent/flow-source.source" "terminal external source stayed registered"
FM_HOME="$H_FLOW" "$PROCEVENT" retire flow-source --if-owner "$owner_one" >/dev/null
pass "one external adapter registers, invokes, captures unhandled evidence, classifies, and terminally retires end to end"
FM_HOME="$H_FLOW" "$PROCEVENT" register-extension ext-flow crash-silent-source --config-ref crash-silent >/dev/null
FM_HOME="$H_FLOW" "$PROCEVENT" start crash-silent-source > "$TMP_ROOT/crash-silent-start.out" 2>&1 &
crash_silent_start_pid=$!
for _ in $(seq 1 400); do
  if [ -f "$TMP_ROOT/claims/crash-silent-source.claim" ]; then
    # The successful crash-recovery path may release this durable claim between
    # the observation above and this best-effort cleanup PID read.
    crash_silent_runner_pid=$(sed -n '2p' "$TMP_ROOT/claims/crash-silent-source.claim" 2>/dev/null || true)
  fi
  kill -0 "$crash_silent_start_pid" 2>/dev/null || break
  sleep 0.01
done
if kill -0 "$crash_silent_start_pid" 2>/dev/null; then
  kill -TERM "$crash_silent_start_pid" 2>/dev/null || true
  [ -z "$crash_silent_runner_pid" ] || kill -TERM -"$crash_silent_runner_pid" 2>/dev/null || true
  wait "$crash_silent_start_pid" 2>/dev/null || true
  crash_silent_start_pid=
  crash_silent_runner_pid=
  fail "inner host crash during result.silent wedged its runner before result.terminal"
fi
wait "$crash_silent_start_pid" || fail "runner did not recover from inner result.silent crash"
crash_silent_start_pid=
crash_silent_runner_pid=
assert_present "$H_FLOW/state/procevent-inbox/crash-silent-source.1.result" "crashed silent invocation discarded captured evidence"
assert_absent "$H_FLOW/state/procevent/crash-silent-source.source" "terminal retry did not retire the crashed silent source"
assert_absent "$H_FLOW/state/procevent/.extension-binding-lifecycle.lock" "inner host crash left a lifecycle lock behind"
FM_HOME="$H_FLOW" "$PROCEVENT" handled crash-silent-source 1 >/dev/null
pass "inner result.silent host crash releases the parent lifecycle lock before terminal retry"
wrong_binding_digest="sha256:$(printf '0%.0s' {1..64})"
expect_failure "expected binding identity" env FM_HOME="$H_FLOW" "$HOST" retire-binding org.example.flow --if-binding-digest "$wrong_binding_digest"
assert_present "$H_FLOW/config/extensions.d/org.example.flow.json" "stale identity retired the local binding"
expect_failure "unhandled process-event result" env FM_HOME="$H_FLOW" "$HOST" retire-binding org.example.flow --if-binding-digest "$flow_binding_digest"
FM_HOME="$H_FLOW" "$PROCEVENT" handled flow-source 1 >/dev/null
FM_HOME="$H_FLOW" "$HOST" retire-binding org.example.flow --if-binding-digest "$flow_binding_digest" >/dev/null
assert_absent "$H_FLOW/config/extensions.d/org.example.flow.json" "exact local binding retirement left discovery enabled"
assert_present "$H_FLOW/data/extensions/retired-bindings/org.example.flow/${flow_binding_digest#sha256:}.json" "local binding retirement was not reversible"
expect_failure "no home-local extension binding" env FM_HOME="$H_FLOW" "$HOST" resolve-process-event ext-flow
pass "local binding retirement requires its exact identity and disables invocation"
fi

# --- registration against reconcile of an unhandled extension result ---------
# Re-registering a source while reconcile republishes its unhandled extension
# result must not deadlock. Registration holds binding resolution open here, so
# reconcile reaches the source before registration asks for it.
if section_enabled lifecycle-order; then
P_ORDER="$PACKAGES/lock-order"
order_marker="$TMP_ROOT/lock-order.marker"
order_release="$TMP_ROOT/lock-order.release"
make_package "$P_ORDER" org.example.lock-order ext-lock-order "$(printf 'handshake-block\n%s\n%s' "$order_marker" "$order_release")"
H_ORDER="$HOMES/lock-order"; new_home "$H_ORDER"
touch "$order_release"
bind_package "$H_ORDER" "$P_ORDER" ext-lock-order >/dev/null
FM_HOME="$H_ORDER" "$PROCEVENT" register-extension ext-lock-order order-source --config-ref good >/dev/null
FM_HOME="$H_ORDER" "$PROCEVENT" start order-source > "$TMP_ROOT/lock-order-start.out" 2>&1 \
  || fail "lock-order source did not capture its result"
assert_absent "$H_ORDER/state/procevent/order-source.source" "lock-order terminal source stayed registered"
assert_absent "$H_ORDER/state/procevent-inbox/order-source.1.handled" "lock-order result was not left unhandled"
rm -f "$order_marker" "$order_release"
FM_HOME="$H_ORDER" "$PROCEVENT" register-extension ext-lock-order order-source --config-ref no-result \
  > "$TMP_ROOT/lock-order-register.out" 2>&1 &
order_register_pid=$!
wait_for_file "$order_marker" || fail "lock-order registration never entered binding resolution"
FM_HOME="$H_ORDER" "$PROCEVENT" reconcile > "$TMP_ROOT/lock-order-reconcile.out" 2>&1 &
order_reconcile_pid=$!
for _ in $(seq 1 200); do
  [ -L "$FM_PROCEVENT_CLAIM_ROOT/order-source.lock" ] && break
  sleep 0.01
done
[ -L "$FM_PROCEVENT_CLAIM_ROOT/order-source.lock" ] || fail "neither lock-order contender took the source lock"
sleep 0.2
touch "$order_release"
order_deadline=$((SECONDS + 12))
while kill -0 "$order_register_pid" 2>/dev/null || kill -0 "$order_reconcile_pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$order_deadline" ]; then
    # Killing registration lets lock recovery free reconcile for cleanup.
    kill -KILL "$order_register_pid" 2>/dev/null || true
    wait "$order_register_pid" 2>/dev/null || true
    order_register_pid=
    wait "$order_reconcile_pid" 2>/dev/null || true
    order_reconcile_pid=
    fail "register-extension and reconcile deadlocked on an unhandled extension result"
  fi
  sleep 0.05
done
order_register_rc=0
wait "$order_register_pid" || order_register_rc=$?
order_register_pid=
wait "$order_reconcile_pid" 2>/dev/null || true
order_reconcile_pid=
order_release=
[ "$order_register_rc" -eq 0 ] || fail "lock-order registration failed: $(cat "$TMP_ROOT/lock-order-register.out")"
assert_contains "$(cat "$TMP_ROOT/lock-order-reconcile.out")" "reconciled:" "lock-order reconcile did not complete its cycle"
order_owner=$(sed -n 's/^owner-token: //p' "$TMP_ROOT/lock-order-register.out")
FM_HOME="$H_ORDER" "$PROCEVENT" retire order-source --if-owner "$order_owner" >/dev/null
FM_HOME="$H_ORDER" "$PROCEVENT" handled order-source 1 >/dev/null
pass "register-extension and reconcile of an unhandled extension result take their locks in one order"
fi

# --- registration and retirement serialization plus lock recovery -------------
if section_enabled lifecycle-lock; then
wrong_binding_digest="sha256:$(printf '0%.0s' {1..64})"
P_RETIRE_RACE="$PACKAGES/retire-race"
race_marker="$TMP_ROOT/retire-race.marker"
race_release="$TMP_ROOT/retire-race.release"
make_package "$P_RETIRE_RACE" org.example.retire-race ext-retire-race "$(printf 'handshake-block\n%s\n%s' "$race_marker" "$race_release")"
H_RETIRE_RACE="$HOMES/retire-race"; new_home "$H_RETIRE_RACE"
touch "$race_release"
race_bind=$(bind_package "$H_RETIRE_RACE" "$P_RETIRE_RACE" ext-retire-race)
race_binding_digest=$(printf '%s\n' "$race_bind" | sed -n 's/^binding-digest: //p')
rm -f "$race_marker" "$race_release"
FM_HOME="$H_RETIRE_RACE" "$PROCEVENT" register-extension ext-retire-race race-source --config-ref good > "$TMP_ROOT/retire-race-register.out" 2>&1 &
race_register_pid=$!
wait_for_file "$race_marker" || fail "registration race fixture never entered binding resolution"
FM_HOME="$H_RETIRE_RACE" "$HOST" retire-binding org.example.retire-race --if-binding-digest "$race_binding_digest" > "$TMP_ROOT/retire-race-retire.out" 2>&1 &
race_retire_pid=$!
sleep 0.2
kill -0 "$race_retire_pid" 2>/dev/null || fail "binding retirement bypassed an in-flight registration"
touch "$race_release"
race_register_rc=0
wait "$race_register_pid" || race_register_rc=$?
race_register_pid=
[ "$race_register_rc" -eq 0 ] || fail "serialized registration did not publish its owner record"
race_retire_rc=0
wait "$race_retire_pid" || race_retire_rc=$?
race_retire_pid=
[ "$race_retire_rc" -ne 0 ] || fail "serialized retirement removed a binding with a new registration"
assert_contains "$(cat "$TMP_ROOT/retire-race-retire.out")" "still owns process-event registration" "serialized retirement did not observe the published registration"
assert_present "$H_RETIRE_RACE/config/extensions.d/org.example.retire-race.json" "registration race left a dangling owner record"
race_owner=$(sed -n 's/^owner-token: //p' "$TMP_ROOT/retire-race-register.out")
FM_HOME="$H_RETIRE_RACE" "$PROCEVENT" retire race-source --if-owner "$race_owner" >/dev/null
FM_HOME="$H_RETIRE_RACE" "$HOST" retire-binding org.example.retire-race --if-binding-digest "$race_binding_digest" >/dev/null
race_release=
pass "registration publication and binding retirement share one lifecycle boundary"

P_PROCESS_RETIRE_RACE="$PACKAGES/process-retire-race"
process_race_marker="$TMP_ROOT/process-retire-race.marker"
process_race_release="$TMP_ROOT/process-retire-race.release"
make_package "$P_PROCESS_RETIRE_RACE" org.example.process-retire-race ext-process-retire-race "$(printf 'handshake-block\n%s\n%s' "$process_race_marker" "$process_race_release")"
H_PROCESS_RETIRE_RACE="$HOMES/process-retire-race"; new_home "$H_PROCESS_RETIRE_RACE"
touch "$process_race_release"
process_race_bind=$(bind_package "$H_PROCESS_RETIRE_RACE" "$P_PROCESS_RETIRE_RACE" ext-process-retire-race)
process_race_binding=$(printf '%s\n' "$process_race_bind" | sed -n 's/^binding-digest: //p')
FM_HOME="$H_PROCESS_RETIRE_RACE" "$PROCEVENT" register-extension ext-process-retire-race process-race-source --config-ref good >/dev/null
rm -f "$process_race_marker" "$process_race_release"
FM_HOME="$H_PROCESS_RETIRE_RACE" "$PROCEVENT" start process-race-source > "$TMP_ROOT/process-retire-race-start.out" 2>&1 &
process_race_start_pid=$!
wait_for_file "$process_race_marker" || fail "process-event race fixture never reached binding resolution"
FM_HOME="$H_PROCESS_RETIRE_RACE" "$HOST" retire-binding org.example.process-retire-race --if-binding-digest "$process_race_binding" > "$TMP_ROOT/process-retire-race-retire.out" 2>&1 &
process_race_retire_pid=$!
sleep 0.2
kill -0 "$process_race_retire_pid" 2>/dev/null || fail "binding retirement bypassed an in-flight process-event resolution"
touch "$process_race_release"
wait "$process_race_start_pid" || fail "lifecycle-locked process-event did not complete after release"
process_race_start_pid=
process_race_retire_rc=0
wait "$process_race_retire_pid" || process_race_retire_rc=$?
process_race_retire_pid=
[ "$process_race_retire_rc" -ne 0 ] || fail "retirement crossed a reserved process-event invocation"
assert_contains "$(cat "$TMP_ROOT/process-retire-race-retire.out")" "still owns process-event registration" "retirement did not observe the reserved process-event registration"
assert_present "$H_PROCESS_RETIRE_RACE/state/procevent-inbox/process-race-source.1.result" "reserved process-event did not capture its result"
pass "process-event resolution reserves the lifecycle before invocation"
process_race_release=

process_race_result="$H_PROCESS_RETIRE_RACE/state/procevent-inbox/process-race-source.1.result"
process_race_resolution=$(FM_HOME="$H_PROCESS_RETIRE_RACE" "$HOST" resolve-process-event ext-process-retire-race)
IFS=$'\t' read -r process_race_schema process_race_id process_race_version process_race_cap process_race_package process_race_resolution_binding process_race_extra <<< "$process_race_resolution"
[ "$process_race_schema" = fm-extension-process-event-resolution.v1 ] && [ -z "$process_race_extra" ] \
  || fail "process-event retirement race resolution was malformed"
for process_race_operation in result.classify result.terminal result.silent; do
  process_race_guard="process-race-${process_race_operation#result.}"
  process_race_registration=$(FM_HOME="$H_PROCESS_RETIRE_RACE" "$PROCEVENT" register-extension ext-process-retire-race "$process_race_guard" --config-ref good)
  process_race_owner=$(printf '%s\n' "$process_race_registration" | sed -n 's/^owner-token: //p')
  rm -f "$process_race_marker" "$process_race_release"
  FM_HOME="$H_PROCESS_RETIRE_RACE" "$HOST" process-event ext-process-retire-race "$process_race_operation" \
    --result-file "$process_race_result" \
    --expect-extension "$process_race_id" --expect-version "$process_race_version" \
    --expect-capability-version "$process_race_cap" \
    --expect-package-digest "$process_race_package" \
    --expect-binding-digest "$process_race_resolution_binding" \
    > "$TMP_ROOT/process-retire-race-${process_race_operation#result.}.out" 2>&1 &
  process_race_start_pid=$!
  wait_for_file "$process_race_marker" || fail "$process_race_operation race fixture never reached binding resolution"
  FM_HOME="$H_PROCESS_RETIRE_RACE" "$HOST" retire-binding org.example.process-retire-race --if-binding-digest "$process_race_binding" \
    > "$TMP_ROOT/process-retire-race-${process_race_operation#result.}-retire.out" 2>&1 &
  process_race_retire_pid=$!
  sleep 0.2
  kill -0 "$process_race_retire_pid" 2>/dev/null || fail "binding retirement bypassed $process_race_operation lifecycle reservation"
  touch "$process_race_release"
  wait "$process_race_start_pid" 2>/dev/null || true
  process_race_start_pid=
  process_race_retire_rc=0
  wait "$process_race_retire_pid" || process_race_retire_rc=$?
  process_race_retire_pid=
  [ "$process_race_retire_rc" -ne 0 ] || fail "retirement crossed a reserved $process_race_operation invocation"
  assert_contains "$(cat "$TMP_ROOT/process-retire-race-${process_race_operation#result.}-retire.out")" "still owns process-event registration" \
    "retirement did not observe the $process_race_operation registration"
  FM_HOME="$H_PROCESS_RETIRE_RACE" "$PROCEVENT" retire "$process_race_guard" --if-owner "$process_race_owner" >/dev/null
done
process_race_release=
pass "every external result operation reserves the lifecycle before invocation"

expect_failure "unknown command" env FM_HOME="$H_RETIRE_RACE" "$HOST" retire-binding-locked org.example.retire-race --if-binding-digest "$race_binding_digest"
expect_failure "unknown command" env FM_HOME="$H_RETIRE_RACE" "$HOST" retire-transfer-locked org.example.retire-race --if-transfer-digest "$wrong_binding_digest" --if-binding-digest "$race_binding_digest"
pass "public extension dispatch exposes no unlocked retirement entry"

P_LOCK_OWNER="$PACKAGES/lock-owner"
make_package "$P_LOCK_OWNER" org.example.lock-owner ext-lock-owner
H_LOCK_OWNER="$HOMES/lock-owner"; new_home "$H_LOCK_OWNER"
owner_bind=$(bind_package "$H_LOCK_OWNER" "$P_LOCK_OWNER" ext-lock-owner)
owner_binding_digest=$(printf '%s\n' "$owner_bind" | sed -n 's/^binding-digest: //p')
owner_lock="$H_LOCK_OWNER/state/procevent/.extension-binding-lifecycle.lock"
FM_HOME="$H_LOCK_OWNER" "$HOST" retire-binding org.example.lock-owner --if-binding-digest "$owner_binding_digest" > "$TMP_ROOT/lock-owner-retire.out" 2>&1 &
owner_retire_pid=$!
owner_worker_pid=
for _ in $(seq 1 400); do
  if [ -e "$owner_lock/pid" ]; then
    candidate=$(cat "$owner_lock/pid" 2>/dev/null || true)
    if [ -n "$candidate" ] && kill -STOP "$candidate" 2>/dev/null; then
      owner_worker_pid=$candidate
      break
    fi
  fi
  sleep 0.005
done
[ -n "$owner_worker_pid" ] || fail "retirement worker never acquired its lifecycle lock"
[ "$owner_worker_pid" != "$owner_retire_pid" ] || fail "retirement fixture did not cross the public wrapper boundary"
kill -TERM "$owner_retire_pid" 2>/dev/null || true
wait "$owner_retire_pid" 2>/dev/null || true
owner_retire_pid=
FM_HOME="$H_LOCK_OWNER" "$PROCEVENT" register-extension ext-lock-owner owner-source --config-ref good > "$TMP_ROOT/lock-owner-register.out" 2>&1 &
owner_register_pid=$!
sleep 0.2
kill -0 "$owner_register_pid" 2>/dev/null || fail "wrapper death released a live retirement worker's lifecycle lock"
kill -KILL "$owner_worker_pid" 2>/dev/null || true
wait "$owner_worker_pid" 2>/dev/null || true
owner_worker_pid=
owner_register_rc=0
wait "$owner_register_pid" || owner_register_rc=$?
owner_register_pid=
[ "$owner_register_rc" -eq 0 ] || fail "registration did not recover the dead retirement worker's lifecycle lock"
assert_present "$H_LOCK_OWNER/config/extensions.d/org.example.lock-owner.json" "dead retirement worker continued mutating after lock recovery"
owner_token=$(sed -n 's/^owner-token: //p' "$TMP_ROOT/lock-owner-register.out")
FM_HOME="$H_LOCK_OWNER" "$PROCEVENT" retire owner-source --if-owner "$owner_token" >/dev/null
FM_HOME="$H_LOCK_OWNER" "$HOST" retire-binding org.example.lock-owner --if-binding-digest "$owner_binding_digest" >/dev/null
pass "retirement worker ownership survives wrapper death and recovers exactly"

P_SIGNAL_LOCK="$PACKAGES/signal-lock"
make_package "$P_SIGNAL_LOCK" org.example.signal-lock ext-signal-lock
H_SIGNAL_LOCK="$HOMES/signal-lock"; new_home "$H_SIGNAL_LOCK"
signal_bind=$(bind_package "$H_SIGNAL_LOCK" "$P_SIGNAL_LOCK" ext-signal-lock)
signal_binding_digest=$(printf '%s\n' "$signal_bind" | sed -n 's/^binding-digest: //p')
signal_lock="$H_SIGNAL_LOCK/state/procevent/.extension-binding-lifecycle.lock"
FM_HOME="$H_SIGNAL_LOCK" "$HOST" retire-binding org.example.signal-lock --if-binding-digest "$signal_binding_digest" > "$TMP_ROOT/signal-lock-retire.out" 2>&1 &
signal_retire_pid=$!
signal_worker_pid=
for _ in $(seq 1 400); do
  if [ -e "$signal_lock/pid" ]; then
    candidate=$(cat "$signal_lock/pid" 2>/dev/null || true)
    if [ -n "$candidate" ] && kill -STOP "$candidate" 2>/dev/null; then
      signal_worker_pid=$candidate
      break
    fi
  fi
  sleep 0.005
done
[ -n "$signal_worker_pid" ] || fail "signal retirement worker never acquired its lifecycle lock"
kill -TERM "$signal_worker_pid" 2>/dev/null || fail "cannot signal retirement worker"
kill -CONT "$signal_worker_pid" 2>/dev/null || fail "cannot resume signalled retirement worker"
for _ in $(seq 1 400); do
  kill -0 "$signal_worker_pid" 2>/dev/null || break
  sleep 0.005
done
kill -0 "$signal_worker_pid" 2>/dev/null && fail "signalled retirement worker did not exit"
signal_worker_pid=
wait "$signal_retire_pid" 2>/dev/null || true
signal_retire_pid=
[ -L "$signal_lock" ] || fail "signalled retirement worker released its lifecycle lock before exit recovery"
signal_registration=$(FM_HOME="$H_SIGNAL_LOCK" "$PROCEVENT" register-extension ext-signal-lock signal-source --config-ref good)
signal_owner=$(printf '%s\n' "$signal_registration" | sed -n 's/^owner-token: //p')
assert_absent "$signal_lock" "registration left a recovered lifecycle lock behind"
FM_HOME="$H_SIGNAL_LOCK" "$PROCEVENT" retire signal-source --if-owner "$signal_owner" >/dev/null
FM_HOME="$H_SIGNAL_LOCK" "$HOST" retire-binding org.example.signal-lock --if-binding-digest "$signal_binding_digest" >/dev/null
pass "signal interruption leaves lifecycle lock recovery to the next owner"
fi

if section_enabled lifecycle-runner; then
P_FLOW="$PACKAGES/flow"
make_package "$P_FLOW" org.example.flow ext-flow
H_ACTIVE_RUNNER="$HOMES/active-runner"; new_home "$H_ACTIVE_RUNNER"
bind_package "$H_ACTIVE_RUNNER" "$P_FLOW" ext-flow >/dev/null
active_runner_marker="$TMP_ROOT/active-runner.marker"
active_runner_release="$TMP_ROOT/active-runner.release"
active_config="active-block|$active_runner_marker|$active_runner_release"
FM_HOME="$H_ACTIVE_RUNNER" "$PROCEVENT" register-extension ext-flow active-source --config-ref "$active_config" >/dev/null
FM_HOME="$H_ACTIVE_RUNNER" "$PROCEVENT" start active-source > "$TMP_ROOT/active-runner.out" 2>&1 &
active_runner_pid=$!
wait_for_file "$active_runner_marker" || fail "active extension runner never entered its poll"
expect_failure "prior runner remains active" env FM_HOME="$H_ACTIVE_RUNNER" "$PROCEVENT" register-extension ext-flow active-source --config-ref replacement
expect_failure "prior runner remains active" env FM_HOME="$H_ACTIVE_RUNNER" "$PROCEVENT" register lavish active-source -- /bin/echo built-in
touch "$active_runner_release"
active_runner_release=
wait "$active_runner_pid" || fail "active extension runner did not complete"
active_runner_pid=
assert_absent "$H_ACTIVE_RUNNER/state/procevent/active-source.source" "terminal extension runner retained its registration"
FM_HOME="$H_ACTIVE_RUNNER" "$PROCEVENT" register lavish active-source -- /bin/echo built-in >/dev/null
FM_HOME="$H_ACTIVE_RUNNER" "$PROCEVENT" retire active-source --if-matches lavish -- /bin/echo built-in >/dev/null
active_replacement=$(FM_HOME="$H_ACTIVE_RUNNER" "$PROCEVENT" register-extension ext-flow active-source --config-ref replacement)
active_replacement_owner=$(printf '%s\n' "$active_replacement" | sed -n 's/^owner-token: //p')
FM_HOME="$H_ACTIVE_RUNNER" "$PROCEVENT" retire active-source --if-owner "$active_replacement_owner" >/dev/null
pass "all registration owner transitions wait for the prior extension runner"
fi

# --- owner tokens, overridden state, sweep, and legacy compatibility --------
if section_enabled lifecycle-state; then
P_FLOW="$PACKAGES/flow"
make_package "$P_FLOW" org.example.flow ext-flow
H_OWNER_SAFE="$HOMES/owner-safe"; new_home "$H_OWNER_SAFE"
bind_package "$H_OWNER_SAFE" "$P_FLOW" ext-flow >/dev/null
first=$(FM_HOME="$H_OWNER_SAFE" "$PROCEVENT" register-extension ext-flow replace-source --config-ref first)
first_token=$(printf '%s\n' "$first" | sed -n 's/^owner-token: //p')
second=$(FM_HOME="$H_OWNER_SAFE" "$PROCEVENT" register-extension ext-flow replace-source --config-ref second)
second_token=$(printf '%s\n' "$second" | sed -n 's/^owner-token: //p')
[ "$first_token" != "$second_token" ] || fail "replacement registration reused its owner generation"
expect_failure "requires its exact --if-owner token" env FM_HOME="$H_OWNER_SAFE" "$PROCEVENT" retire replace-source
expect_failure "does not match the expected owner" env FM_HOME="$H_OWNER_SAFE" "$PROCEVENT" retire replace-source --if-owner "$first_token"
assert_present "$H_OWNER_SAFE/state/procevent/replace-source.source" "stale owner retired the replacement"
FM_HOME="$H_OWNER_SAFE" "$PROCEVENT" retire replace-source --if-owner "$second_token" >/dev/null
assert_absent "$H_OWNER_SAFE/state/procevent/replace-source.source" "current owner could not retire its own registration"
pass "owner-matched retirement refuses a stale generation and accepts the current one"

H_STATE_OVERRIDE="$HOMES/state-override"; new_home "$H_STATE_OVERRIDE"
STATE_OVERRIDE="$TMP_ROOT/overridden-state"
override_bind=$(bind_package "$H_STATE_OVERRIDE" "$P_FLOW" ext-flow)
override_bind_digest=$(printf '%s\n' "$override_bind" | sed -n 's/^binding-digest: //p')
override_registration=$(FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" "$PROCEVENT" register-extension ext-flow override-source --config-ref silent-result)
override_owner=$(printf '%s\n' "$override_registration" | sed -n 's/^owner-token: //p')
override_resolution=$(FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" "$HOST" resolve-process-event ext-flow)
IFS=$'\t' read -r override_schema override_id override_version override_cap override_package override_binding override_extra <<< "$override_resolution"
[ "$override_schema" = fm-extension-process-event-resolution.v1 ] && [ -z "$override_extra" ] \
  || fail "overridden-state resolution record is malformed"
expect_failure "still owns process-event registration" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" "$HOST" retire-binding org.example.flow --if-binding-digest "$override_bind_digest"
assert_present "$H_STATE_OVERRIDE/config/extensions.d/org.example.flow.json" "overridden-state dependency did not preserve its binding"
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" "$PROCEVENT" start override-source >/dev/null
override_result="$STATE_OVERRIDE/procevent-inbox/override-source.1.result"
assert_present "$override_result" "overridden-state runner did not capture its result"
assert_present "$STATE_OVERRIDE/procevent-inbox/override-source.1.handled" "overridden-state silent verdict was not recorded"
assert_absent "$STATE_OVERRIDE/procevent/override-source.source" "overridden-state terminal verdict did not retire its registration"
assert_contains "$(FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" "$PROCEVENT" classify "$override_result")" "external-ready" \
  "overridden-state result could not be classified"
mkdir "$TMP_ROOT/override-outside"
cp "$override_result" "$TMP_ROOT/override-outside/override-source.1.result"
cp "$STATE_OVERRIDE/procevent-inbox/override-source.1.adapter" "$TMP_ROOT/override-outside/override-source.1.adapter"
cp "$STATE_OVERRIDE/procevent-inbox/override-source.1.extension" "$TMP_ROOT/override-outside/override-source.1.extension"
chmod 0600 "$TMP_ROOT/override-outside/override-source.1.result"
chmod 0600 "$TMP_ROOT/override-outside/override-source.1.adapter" "$TMP_ROOT/override-outside/override-source.1.extension"
expect_failure "directly inside" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" classify "$TMP_ROOT/override-outside/override-source.1.result"
mkdir "$TMP_ROOT/forged-pinned-result"
printf 'forged extension evidence\n' > "$TMP_ROOT/forged-pinned-result/forged-source.1.result"
chmod 0600 "$TMP_ROOT/forged-pinned-result/forged-source.1.result"
# shellcheck disable=SC2016 # Child shell intentionally expands its positional parameters.
expect_failure "directly inside" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  FM_PROCEVENT_CAPTURE_PINNED_RESULT=1 sh -c '
    cd "$1" || exit 1
    exec "$2" process-event "$3" result.classify --result-file ./forged-source.1.result \
      --expect-extension "$4" --expect-version "$5" --expect-capability-version "$6" \
      --expect-package-digest "$7" --expect-binding-digest "$8"
  ' sh "$TMP_ROOT/forged-pinned-result" "$HOST" ext-flow "$override_id" "$override_version" \
  "$override_cap" "$override_package" "$override_binding"
# shellcheck disable=SC2016 # Child shell intentionally expands its positional parameters.
expect_failure "directly inside" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  sh -c '
    cd "$1" || exit 1
    authority=$(mktemp .forged-authority.XXXXXXXX) || exit 1
    dd if=/dev/urandom of="$authority" bs=32 count=1 2>/dev/null || exit 1
    chmod 0600 "$authority" || exit 1
    exec 7<"$authority"
    rm -f -- "$authority"
    exec 8<.
    exec "$2" extension-process-event "$3" result.classify --result-file ./forged-source.1.result \
      --expect-extension "$4" --expect-version "$5" --expect-capability-version "$6" \
      --expect-package-digest "$7" --expect-binding-digest "$8"
  ' sh "$TMP_ROOT/forged-pinned-result" "$PROCEVENT" ext-flow "$override_id" "$override_version" \
  "$override_cap" "$override_package" "$override_binding"
# shellcheck disable=SC2016 # Child shell intentionally expands its positional parameters.
expect_failure "directly inside" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  FM_PROCEVENT_INTERNAL_CAPTURE_RESERVATION="$(printf 'd%.0s' {1..64})" \
  FM_PROCEVENT_INTERNAL_CAPTURE_CLAIM_PID="$$" \
  FM_PROCEVENT_INTERNAL_CAPTURE_CLAIM_IDENTITY=forged-identity \
  FM_PROCEVENT_INTERNAL_CAPTURE_CLAIM_TOKEN=forged-claim \
  FM_PROCEVENT_INTERNAL_CAPTURE_SOURCE_ID=forged-source \
  FM_PROCEVENT_INTERNAL_CAPTURE_SEQUENCE=1 \
  FM_PROCEVENT_INTERNAL_CAPTURE_PARENT_PID="$$" sh -c '
    cd "$1" || exit 1
    exec 6<.
    exec 7<.
    exec 8<.
    exec "$2" extension-process-event "$3" result.silent --result-file ./forged-source.1.result \
      --expect-extension "$4" --expect-version "$5" --expect-capability-version "$6" \
      --expect-package-digest "$7" --expect-binding-digest "$8"
  ' sh "$TMP_ROOT/forged-pinned-result" "$PROCEVENT" ext-flow "$override_id" "$override_version" \
  "$override_cap" "$override_package" "$override_binding"
forged_reservation_root="$TMP_ROOT/forged-capture-reservations"
mkdir "$forged_reservation_root"
forged_reservation_token=$(printf 'c%.0s' {1..64})
forged_claim_identity=$(FM_HOME="$TMP_ROOT/forged-identity-home" FM_STATE_OVERRIDE="$TMP_ROOT/forged-identity-state" \
  bash -c '. "$1"; fm_pid_identity "$2"' sh "$ROOT/bin/fm-wake-lib.sh" "$$")
printf '%s\n' '{"schema":"fm-procevent-capture-reservation.v1","token":"'"$forged_reservation_token"'","operation":"result.silent","source_id":"forged-source","sequence":1,"inbox_device":"1","inbox_inode":"1","result_device":"1","result_inode":"1","claim_pid":"'"$$"'","claim_identity":"'"$forged_claim_identity"'","claim_token":"forged-claim","binding_digest":"'"$override_binding"'"}' \
  > "$forged_reservation_root/.extension-capture-forged-claim.$forged_reservation_token.json"
chmod 0600 "$forged_reservation_root/.extension-capture-forged-claim.$forged_reservation_token.json"
# shellcheck disable=SC2016 # Child shell intentionally expands its positional parameters.
expect_failure "reservation" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  FM_PROCEVENT_CLAIM_ROOT="$forged_reservation_root" sh -c '
    cd "$1" || exit 1
    exec "$2" extension-process-event "$3" result.silent --result-file ./forged-source.1.result \
      --expect-extension "$4" --expect-version "$5" --expect-capability-version "$6" \
      --expect-package-digest "$7" --expect-binding-digest "$8" \
      --capture-reservation "$9"
  ' sh "$TMP_ROOT/forged-pinned-result" "$PROCEVENT" ext-flow "$override_id" "$override_version" \
  "$override_cap" "$override_package" "$override_binding" "$forged_reservation_token"
printf 'forged adapter\n' > "$TMP_ROOT/forged-pinned-result/forged-source.1.adapter"
chmod 0600 "$TMP_ROOT/forged-pinned-result/forged-source.1.adapter"
# shellcheck disable=SC2016 # Child shell intentionally expands its positional parameters.
expect_failure "cannot durably" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  FM_PROCEVENT_CAPTURE_PINNED_INBOX=1 sh -c '
    cd "$1" || exit 1
    exec "$2" handled forged-source 1
  ' sh "$TMP_ROOT/forged-pinned-result" "$PROCEVENT"
assert_absent "$TMP_ROOT/forged-pinned-result/forged-source.1.handled" \
  "caller environment forged a handled acknowledgement"
pass "caller environment, descriptors, and lifecycle entry cannot forge capture authority"
reservation_records=$(find "$STATE_OVERRIDE/procevent-capture-reservations" -type f -print 2>/dev/null | wc -l | tr -d '[:space:]')
[ "$reservation_records" -eq 0 ] || fail "completed extension capture left residual reservation state"
pass "extension capture reservations are bounded to their runner lifecycle"
state_path_decoy="$H_STATE_OVERRIDE/state/procevent-capture-reservations/.extension-capture-control-path-decoy.json"
mkdir -p "${state_path_decoy%/*}"
chmod 0700 "$H_STATE_OVERRIDE/state" "${state_path_decoy%/*}"
printf 'decoy\n' > "$state_path_decoy"
chmod 0600 "$state_path_decoy"
for control_kind in tab newline; do
  case "$control_kind" in
    tab) control_state="$TMP_ROOT/control-state"$'\t'"tab" ;;
    newline) control_state="$TMP_ROOT/control-state"$'\n'"newline" ;;
  esac
  control_source="control-${control_kind}-state-source"
  mkdir -p "$control_state"
  chmod 0700 "$control_state"
  FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$control_state" \
    "$PROCEVENT" register lavish "$control_source" -- /bin/echo control >/dev/null
  expect_failure "cannot acquire source ownership" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$control_state" \
    "$PROCEVENT" start "$control_source"
  assert_absent "$TMP_ROOT/claims/$control_source.claim" "control-byte state root created a malformed claim"
  assert_absent "$control_state/procevent-capture-reservations" "control-byte state root created reservation state"
  assert_present "$state_path_decoy" "control-byte state root touched unrelated reservation state"
done
pass "control-byte state roots cannot serialize claims or reservations"
override_crash_marker="$TMP_ROOT/override-crash.marker"
override_crash_release="$TMP_ROOT/override-crash.release"
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" register-extension ext-flow override-crash-source \
  --config-ref "silent-block|$override_crash_marker|$override_crash_release" >/dev/null
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" start override-crash-source > "$TMP_ROOT/override-crash-start.out" 2>&1 &
override_crash_start_pid=$!
wait_for_file "$override_crash_marker" || fail "overridden-state crash fixture never reached its reservation handoff"
override_crash_claim="$TMP_ROOT/claims/override-crash-source.claim"
assert_present "$override_crash_claim" "overridden-state crash fixture did not retain its claim"
override_crash_runner_pid=$(sed -n '2p' "$override_crash_claim")
override_crash_token=$(sed -n '3p' "$override_crash_claim")
override_crash_records=$(find "$STATE_OVERRIDE/procevent-capture-reservations" -type f \
  -name ".extension-capture-$override_crash_token.*" -print | wc -l | tr -d '[:space:]')
[ "$override_crash_records" -eq 2 ] || fail "overridden-state crash fixture did not create both immediate reservations"
mkdir -p "$H_STATE_OVERRIDE/state/procevent-capture-reservations"
chmod 0700 "$H_STATE_OVERRIDE/state" "$H_STATE_OVERRIDE/state/procevent-capture-reservations"
override_crash_decoy="$H_STATE_OVERRIDE/state/procevent-capture-reservations/.extension-capture-$override_crash_token.decoy.json"
printf 'decoy\n' > "$override_crash_decoy"
chmod 0600 "$override_crash_decoy"
kill -KILL -"$override_crash_runner_pid" 2>/dev/null || fail "could not terminate overridden-state runner"
wait "$override_crash_start_pid" 2>/dev/null || true
override_crash_start_pid=
override_crash_runner_pid=
FM_HOME="$H_STATE_OVERRIDE" "$PROCEVENT" reconcile >/dev/null
assert_absent "$override_crash_claim" "reconcile retained a dead overridden-state claim"
override_crash_records=$(find "$STATE_OVERRIDE/procevent-capture-reservations" -type f \
  -name ".extension-capture-$override_crash_token.*" -print -quit)
[ -z "$override_crash_records" ] || fail "reconcile left reservations in the recorded overridden state root"
assert_present "$override_crash_decoy" "reconcile removed reservations from the current default state root"
pass "crash recovery revalidates and cleans only the recorded state root"
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" register-extension ext-flow inbox-swap-source --config-ref good >/dev/null
mkdir "$TMP_ROOT/inbox-link-target"
mv "$STATE_OVERRIDE/procevent-inbox" "$TMP_ROOT/override-real-inbox"
ln -s "$TMP_ROOT/inbox-link-target" "$STATE_OVERRIDE/procevent-inbox"
expect_failure "cannot durably capture the extension result" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" start inbox-swap-source
[ -z "$(find "$TMP_ROOT/inbox-link-target" -mindepth 1 -print -quit)" ] \
  || fail "a post-registration inbox symlink received extension evidence"
rm "$STATE_OVERRIDE/procevent-inbox"
mv "$TMP_ROOT/override-real-inbox" "$STATE_OVERRIDE/procevent-inbox"
pass "post-registration inbox symlink substitution cannot redirect extension evidence"
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" register-extension ext-flow registry-swap-source --config-ref good >/dev/null
mkdir "$TMP_ROOT/registry-link-target"
mv "$STATE_OVERRIDE/procevent" "$TMP_ROOT/registry-link-target"
REGISTRY_LINK_TARGET="$TMP_ROOT/registry-link-target/procevent"
registry_entries_before=$(find "$REGISTRY_LINK_TARGET" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
ln -s "$REGISTRY_LINK_TARGET" "$STATE_OVERRIDE/procevent"
expect_failure "cannot safely prepare the external registry staging boundary" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" start registry-swap-source
registry_entries_after=$(find "$REGISTRY_LINK_TARGET" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
[ "$registry_entries_before" = "$registry_entries_after" ] \
  || fail "a post-registration registry symlink received external evidence"
rm "$STATE_OVERRIDE/procevent"
mv "$REGISTRY_LINK_TARGET" "$STATE_OVERRIDE/procevent"
pass "post-registration registry symlink substitution cannot redirect external evidence"
registry_race_marker="$TMP_ROOT/registry-race.marker"
registry_race_release="$TMP_ROOT/registry-race.release"
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" register-extension ext-flow registry-race-source \
  --config-ref "active-block|$registry_race_marker|$registry_race_release" >/dev/null
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" start registry-race-source > "$TMP_ROOT/registry-race.out" 2>&1 &
registry_race_pid=$!
wait_for_file "$registry_race_marker" || fail "registry race fixture never reached its pinned staging boundary"
mkdir "$TMP_ROOT/registry-race-outside"
mv "$STATE_OVERRIDE/procevent" "$TMP_ROOT/registry-race-real"
ln -s "$TMP_ROOT/registry-race-outside" "$STATE_OVERRIDE/procevent"
touch "$registry_race_release"
registry_race_rc=0
wait "$registry_race_pid" || registry_race_rc=$?
registry_race_pid=
[ "$registry_race_rc" -eq 0 ] || fail "registry swap race did not complete through its pinned staging directory"
[ -z "$(find "$TMP_ROOT/registry-race-outside" -mindepth 1 -print -quit)" ] \
  || fail "a registry directory swap received external evidence"
rm "$STATE_OVERRIDE/procevent"
mv "$TMP_ROOT/registry-race-real" "$STATE_OVERRIDE/procevent"
pass "external staging remains descriptor-bound across a registry directory swap"
registry_race_release=
leaf_race_marker="$TMP_ROOT/leaf-race.marker"
leaf_race_release="$TMP_ROOT/leaf-race.release"
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" register-extension ext-flow leaf-race-source \
  --config-ref "active-block|$leaf_race_marker|$leaf_race_release" >/dev/null
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" start leaf-race-source > "$TMP_ROOT/leaf-race.out" 2>&1 &
leaf_race_pid=$!
wait_for_file "$leaf_race_marker" || fail "leaf race fixture never entered its staged invocation"
leaf_stage=$(find "$STATE_OVERRIDE/procevent" -maxdepth 1 -name '.leaf-race-source.*.output' -print -quit)
leaf_runner="$STATE_OVERRIDE/procevent/leaf-race-source.runner"
[ -n "$leaf_stage" ] && [ -f "$leaf_runner" ] || fail "leaf race fixture did not create both protected leaves"
mkdir "$TMP_ROOT/leaf-race-outside"
mv "$leaf_stage" "$TMP_ROOT/leaf-race-real-output"
mv "$leaf_runner" "$TMP_ROOT/leaf-race-real-runner"
ln -s "$TMP_ROOT/leaf-race-outside/output" "$leaf_stage"
ln -s "$TMP_ROOT/leaf-race-outside/runner" "$leaf_runner"
touch "$leaf_race_release"
leaf_race_rc=0
wait "$leaf_race_pid" || leaf_race_rc=$?
leaf_race_pid=
[ "$leaf_race_rc" -eq 0 ] || fail "leaf substitution race did not complete through held descriptors"
[ ! -e "$TMP_ROOT/leaf-race-outside/output" ] && [ ! -e "$TMP_ROOT/leaf-race-outside/runner" ] \
  || fail "a substituted staging leaf received external evidence"
rm -f "$leaf_stage" "$leaf_runner"
pass "external staging leaves remain no-follow descriptor-bound through capture"
leaf_race_release=
publication_race_marker="$TMP_ROOT/publication-race.marker"
publication_race_release="$TMP_ROOT/publication-race.release"
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" register-extension ext-flow publication-race-source \
  --config-ref "silent-block|$publication_race_marker|$publication_race_release" >/dev/null
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" start publication-race-source > "$TMP_ROOT/publication-race.out" 2>&1 &
publication_race_pid=$!
wait_for_file "$publication_race_marker" || fail "publication race fixture never reached result handoff"
mkdir "$TMP_ROOT/publication-race-outside"
mv "$STATE_OVERRIDE/procevent-inbox" "$TMP_ROOT/publication-race-real-inbox"
ln -s "$TMP_ROOT/publication-race-outside" "$STATE_OVERRIDE/procevent-inbox"
touch "$publication_race_release"
publication_race_rc=0
wait "$publication_race_pid" || publication_race_rc=$?
publication_race_pid=
[ "$publication_race_rc" -eq 0 ] || fail "publication race did not complete through its pinned inbox"
assert_present "$TMP_ROOT/publication-race-real-inbox/publication-race-source.1.result" \
  "pinned inbox lost the captured result during publication"
assert_present "$TMP_ROOT/publication-race-real-inbox/publication-race-source.1.handled" \
  "pinned inbox lost its handled acknowledgement during publication"
[ -z "$(find "$TMP_ROOT/publication-race-outside" -mindepth 1 -print -quit)" ] \
  || fail "post-capture inbox substitution redirected extension evidence or metadata"
rm "$STATE_OVERRIDE/procevent-inbox"
mv "$TMP_ROOT/publication-race-real-inbox" "$STATE_OVERRIDE/procevent-inbox"
pass "external publication remains descriptor-bound after capture"
publication_race_release=
capture_signal_state="$TMP_ROOT/capture-signal-state"
capture_signal_registry="$capture_signal_state/procevent"
mkdir -p "$capture_signal_registry" "$capture_signal_state/procevent-inbox"
chmod 0700 "$capture_signal_state" "$capture_signal_registry" "$capture_signal_state/procevent-inbox"
exec 9<"$capture_signal_registry"
exec 6<"$capture_signal_registry"
exec 8<"$capture_signal_state/procevent-inbox"
capture_signal_authority=$(mktemp "$capture_signal_registry/.authority.XXXXXXXX")
dd if=/dev/urandom of="$capture_signal_authority" bs=32 count=1 2>/dev/null
chmod 0600 "$capture_signal_authority"
exec 7<"$capture_signal_authority"
rm "$capture_signal_authority"
capture_signal=$(perl "$ROOT/bin/fm-procevent-extension-capture.pl" \
  9 8 6 capture-signal-source ext-flow org.example.flow 1.2.3 1 \
  "sha256:$(printf 'a%.0s' {1..64})" "sha256:$(printf 'b%.0s' {1..64})" signal-token \
  capture-signal-source.runner .capture-signal.output "$$" "$forged_claim_identity" 1024 -- perl -e 'kill "KILL", $$')
exec 9<&-
exec 6<&-
exec 8<&-
exec 7<&-
[ "$capture_signal" = $'failure\t0' ] || fail "signal-terminated extension invocation was not reported as failure"
[ -z "$(find "$capture_signal_registry" "$capture_signal_state/procevent-inbox" -mindepth 1 -print -quit)" ] \
  || fail "signal-terminated extension invocation left staged or successful evidence"
pass "signal-terminated extension capture cannot publish an empty success"
capture_swap_state="$TMP_ROOT/capture-swap-state"
capture_swap_registry="$capture_swap_state/procevent"
capture_swap_inbox="$capture_swap_state/procevent-inbox"
mkdir -p "$capture_swap_registry" "$capture_swap_inbox" "$TMP_ROOT/capture-swap-outside"
chmod 0700 "$capture_swap_state" "$capture_swap_registry" "$capture_swap_inbox" "$TMP_ROOT/capture-swap-outside"
exec 9<"$capture_swap_registry"
exec 6<"$capture_swap_registry"
exec 8<"$capture_swap_inbox"
capture_swap_authority=$(mktemp "$capture_swap_registry/.authority.XXXXXXXX")
dd if=/dev/urandom of="$capture_swap_authority" bs=32 count=1 2>/dev/null
chmod 0600 "$capture_swap_authority"
exec 7<"$capture_swap_authority"
rm "$capture_swap_authority"
mv "$capture_swap_inbox" "$TMP_ROOT/capture-swap-real-inbox"
ln -s "$TMP_ROOT/capture-swap-outside" "$capture_swap_inbox"
capture_swap=$(perl "$ROOT/bin/fm-procevent-extension-capture.pl" \
  9 8 6 capture-swap-source ext-flow org.example.flow 1.2.3 1 \
  "sha256:$(printf 'a%.0s' {1..64})" "sha256:$(printf 'b%.0s' {1..64})" swap-token \
  capture-swap-source.runner .capture-swap.output "$$" "$forged_claim_identity" 1024 -- /bin/printf 'pinned helper result')
exec 9<&-
exec 6<&-
exec 8<&-
exec 7<&-
IFS=$'\t' read -r capture_swap_state capture_swap_result capture_swap_rc capture_swap_truncated _ <<< "$capture_swap"
[ "$capture_swap_state" = captured ] && [ "$capture_swap_result" = capture-swap-source.1.result ] \
  && [ "$capture_swap_rc" = 0 ] && [ "$capture_swap_truncated" = 0 ] \
  || fail "pinned capture helper did not report its captured result"
assert_present "$TMP_ROOT/capture-swap-real-inbox/capture-swap-source.1.result" \
  "pinned capture helper lost evidence after an inbox substitution"
[ -z "$(find "$TMP_ROOT/capture-swap-outside" -mindepth 1 -print -quit)" ] \
  || fail "capture helper reopened a substituted inbox pathname"
pass "capture helper retains the inherited inbox descriptor before publication"
H_LEGACY_LINK="$HOMES/legacy-link"; new_home "$H_LEGACY_LINK"
LEGACY_REAL_STATE="$TMP_ROOT/legacy-real-state"
LEGACY_LINK_STATE="$TMP_ROOT/legacy-state-link"
mkdir "$LEGACY_REAL_STATE"
ln -s "$LEGACY_REAL_STATE" "$LEGACY_LINK_STATE"
FM_HOME="$H_LEGACY_LINK" FM_STATE_OVERRIDE="$LEGACY_LINK_STATE" \
  "$PROCEVENT" register lavish legacy-link-source -- /bin/echo legacy-link >/dev/null
FM_HOME="$H_LEGACY_LINK" FM_STATE_OVERRIDE="$LEGACY_LINK_STATE" \
  "$PROCEVENT" start legacy-link-source >/dev/null
assert_present "$LEGACY_REAL_STATE/procevent-inbox/legacy-link-source.1.result" \
  "an absent-registry built-in capture no longer accepts its legacy state path"
pass "absent-registry built-in capture retains its legacy state-path behavior"
mv "$STATE_OVERRIDE/procevent-inbox" "$TMP_ROOT/override-real-inbox"
ln -s "$TMP_ROOT/override-real-inbox" "$STATE_OVERRIDE/procevent-inbox"
expect_failure "traverses a symbolic link" env FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" \
  "$PROCEVENT" classify "$STATE_OVERRIDE/procevent-inbox/override-source.1.result"
rm "$STATE_OVERRIDE/procevent-inbox"
mv "$TMP_ROOT/override-real-inbox" "$STATE_OVERRIDE/procevent-inbox"
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" "$PROCEVENT" retire override-source --if-owner "$override_owner" >/dev/null
FM_HOME="$H_STATE_OVERRIDE" FM_STATE_OVERRIDE="$STATE_OVERRIDE" "$HOST" retire-binding org.example.flow --if-binding-digest "$override_bind_digest" >/dev/null
pass "overridden state confines extension work and captured-result operations"

H_SWEEP="$HOMES/sweep"; new_home "$H_SWEEP"
bind_package "$H_SWEEP" "$P_FLOW" ext-flow >/dev/null
FM_HOME="$H_SWEEP" "$PROCEVENT" register-extension ext-flow sweep-source --config-ref good >/dev/null
assert_contains "$(FM_HOME="$H_SWEEP" "$PROCEVENT" sweep-home)" "swept: attempted=1" \
  "home sweep did not use the extension registration's owner identity"
assert_absent "$H_SWEEP/state/procevent/sweep-source.source" "home sweep retained an extension registration"
pass "bounded home sweep retires an extension source through its exact owner token"

H_LEGACY="$HOMES/legacy"; mkdir -p "$H_LEGACY/state"
FM_HOME="$H_LEGACY" "$PROCEVENT" register lavish legacy-source -- /bin/echo legacy >/dev/null
expect_failure "does not match the expected owner" env FM_HOME="$H_LEGACY" "$PROCEVENT" retire legacy-source --if-matches lavish -- /bin/echo replacement
assert_present "$H_LEGACY/state/procevent/legacy-source.source" "legacy conditional mismatch retired the registration"
FM_HOME="$H_LEGACY" "$PROCEVENT" retire legacy-source --if-matches lavish -- /bin/echo legacy >/dev/null
pass "legacy built-in registrations retain behavior and gain exact conditional retirement"
fi

# --- static launch barrier and signal/crash cleanup --------------------------
