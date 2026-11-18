# shellcheck shell=bash
# abort cleanup, orca reclaim, and batch dispatch.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

spawn_fresh_commit_rollback() {
  if fm_backlog_atomic_transition rollback "$STATE/$ID.meta" \
    "$FM_ROOT/bin/fm-busy-event.sh" "$STATE" "$ID" "${BUSY_GEN:-}"; then
    SPAWN_FRESH_COMMIT_PENDING=0
    return 0
  fi
  echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2
  return 1
}


# Non-forced unlink arbitration for a delivered Orca source-mode launch file:
# the pane unlinks it before launching the worker and refuses when that unlink
# fails, so exactly one side's unlink succeeds. Returns 0 when this spawn removed
# it (the worker is refused), 1 when the pane already had, and 2 when the file
# could not be removed.

spawn_abort_cleanup() {
  local status=$?
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ] &&
    [ "$SPAWN_META_PUBLISH_STARTED" = 1 ] &&
    [ -n "$SPAWN_META_TMP" ] &&
    [ ! -e "$SPAWN_META_TMP" ] &&
    [ ! -L "$SPAWN_META_TMP" ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
  fi
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
    if ! clear_relaunch_harness_wiring \
      "$RELAUNCH_REPLACEMENT_HARNESS" \
      "$RELAUNCH_REPLACEMENT_WT" \
      "$RELAUNCH_REPLACEMENT_STATE" \
      "$ID" \
      "$KIND"; then
      echo "warning: could not remove replacement wiring after aborted relaunch of $ID" >&2
    fi
    if [ -n "$RELAUNCH_REPLACEMENT_BUSY_GEN" ]; then
      if ! "$FM_ROOT/bin/fm-busy-event.sh" retire \
        "$RELAUNCH_REPLACEMENT_STATE" "$ID" \
        --gen "$RELAUNCH_REPLACEMENT_BUSY_GEN"; then
        echo "warning: could not retire replacement busy generation after aborted relaunch of $ID" >&2
      fi
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] &&
    [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
    if ! spawn_herdr_presentation_order_lock_acquire "${HERDR_PROJECTION_ABORT_SESSION:-}"; then
      echo "warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup" >&2
      HERDR_PROJECTION_ABORT_CLEANUP=0
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ]; then
    HERDR_PROJECTION_ABORT_CLEANUP=0
    if fm_backend_herdr_projection_cleanup_exact \
      "$HERDR_PROJECTION_ABORT_SESSION" \
      "$HERDR_PROJECTION_ABORT_TASK_PANE" \
      "$HERDR_PROJECTION_ABORT_SEEDED_PANE" \
      "$HERDR_PROJECTION_ABORT_WORKSPACE" \
      "$HERDR_PROJECTION_ABORT_TASK_TAB" \
      "$HERDR_PROJECTION_ABORT_SEEDED_TAB" \
      "$W"; then
      SPAWN_ENDPOINT_CLOSED=1
    fi
  fi
  if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ]; then
    HERDR_PRESENTATION_ORDER_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
  fi
  if [ "$ORCA_ABORT_CLEANUP" = 1 ]; then
    ORCA_ABORT_CLEANUP=0
    if [ -n "${ORCA_TERMINAL:-}" ]; then
      fm_backend_kill orca "$ORCA_TERMINAL" 2>/dev/null && SPAWN_ENDPOINT_CLOSED=1 || true
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
      if ! fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" 2>/dev/null; then
        if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ]; then
          if ! spawn_fresh_commit_rollback; then
            status=1
          fi
          SPAWN_FRESH_COMMIT_PENDING=0
        fi
        mkdir -p "$STATE" 2>/dev/null || true
        if [ -d "$STATE" ]; then
          SPAWN_META_TMP="$STATE/.$ID.meta.orca-recovery.${BASHPID:-$$}"
          {
            echo "window=$W"
            echo "endpoint_task_id=$ID"
            echo "cleanup_recovery=orca"
            echo "worktree=${WT:-}"
            echo "project=$PROJ_ABS"
            echo "harness=$HARNESS"
            echo "kind=$KIND"
            [ -z "${MODE:-}" ] || echo "mode=$MODE"
            [ -z "${YOLO:-}" ] || echo "yolo=$YOLO"
            [ -z "${BRANCH:-}" ] || echo "branch=$BRANCH"
            echo "tasktmp=${TASK_TMP:-}"
            echo "model=${MODEL:-default}"
            echo "effort=${EFFORT:-default}"
            echo "backend=orca"
            echo "orca_worktree_id=$ORCA_WORKTREE_ID"
            [ -z "${ORCA_TERMINAL:-}" ] || echo "terminal=$ORCA_TERMINAL"
          } >"$SPAWN_META_TMP" 2>/dev/null &&
            fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE" ||
            true
        fi
      fi
    fi
  fi
  # Nothing has run in a leased slot or secondmate home until T3 accepts the
  # launch turn, so an abort before that, including one after T3 refused the
  # turn, archives the thread (it must never act in a returned slot), removes
  # the environment files the spawn wrote there as teardown does, and hands a
  # lease back only once both succeeded; once T3 accepted the turn, or its
  # outcome is unproven, the agent may be working there, so both are left in
  # place.
  if [ "$T3CODE_CREATE_UNCERTAIN" = 1 ]; then
    # t3_thread_launch has no idempotency key, so a launch whose outcome was
    # lost may have left a thread whose id never came back.
    T3CODE_CREATE_UNCERTAIN=0
    T3CODE_HOME_ENV=0
    if [ "$T3CODE_LEASED" = 1 ]; then
      T3CODE_LEASED=0
      echo "warning: the T3 thread launch for $ID did not report an outcome; the leased worktree $WT stays leased until any thread T3 bound to it is found in T3 Code and archived, then run 'treehouse return --force $WT' from $PROJ_ABS" >&2
    else
      echo "warning: the T3 thread launch for $ID did not report an outcome; find and archive any thread it left in T3 Code, then remove the $PROJ_ABS/config/t3code-token link this spawn added, before reusing its home" >&2
    fi
  elif [ "$T3CODE_ABORT_CLEANUP" = 1 ]; then
    T3CODE_ABORT_CLEANUP=0
    if ! fm_backend_kill t3code "$T"; then
      T3CODE_HOME_ENV=0
      if [ "$T3CODE_LEASED" = 1 ]; then
        T3CODE_LEASED=0
        local t3_env_files="$WT/.claude/settings.local.json"
        [ "$T3CODE_CLAUDE_CHANNEL_WRITTEN" != 1 ] || t3_env_files="$t3_env_files and $WT/CLAUDE.local.md"
        echo "warning: could not stop and archive T3 thread $T for $ID, so the leased worktree $WT stays leased; archive the thread in T3 Code, undo the T3 environment this spawn wrote with '$SCRIPT_DIR/fm-t3code-codex-env.sh cleanup $WT' and by removing $t3_env_files, then run 'treehouse return --force $WT' from $PROJ_ABS" >&2
      else
        echo "warning: could not stop and archive T3 thread $T for $ID; archive it in T3 Code, then remove the T3 environment this spawn wrote into $PROJ_ABS: run '$SCRIPT_DIR/fm-t3code-codex-env.sh cleanup $PROJ_ABS', remove the keys FM_T3CODE_ENV_KEYS lists, and FM_T3CODE_ENV_KEYS itself, from its .claude/settings.local.json, and remove its config/t3code-token link" >&2
      fi
    fi
  fi
  if [ "$T3CODE_HOME_ENV" = 1 ]; then
    T3CODE_HOME_ENV=0
    fm_backend_t3code_home_env_cleanup "$PROJ_ABS" \
      || echo "warning: could not remove the T3 environment this spawn wrote into $PROJ_ABS for $ID; remove it before the home runs again" >&2
  fi
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ]; then
    if ! spawn_fresh_commit_rollback; then
      status=1
    fi
  fi
  if [ "$SPAWN_META_LOCK_HELD" = 1 ]; then
    SPAWN_META_LOCK_HELD=0
    fm_lock_release "$SPAWN_META_LOCK" || true
  fi
  # A fresh polytoken spawn that fails and leaves no record must leave the pool
  # as it found it. Before its launch is delivered, the endpoint it opened holds nothing but
  # the shell whose `treehouse get` leases the slot, so closing it returns the
  # slot to the pool and leaves no window or tab for a retry to trip over; the
  # Firstmate wiring, task temp root, and staged launch file it wrote go with it.
  # Once a launch was delivered into an endpoint still open, a worker may be
  # running there, so those stay for the operator, as the refusal says.
  if [ "$status" -ne 0 ] && [ "${HARNESS:-}" = polytoken ] &&
    { [ "$SPAWN_FRESH_ENDPOINT_OPENED" = 1 ] || [ "$SPAWN_FRESH_WIRING_PENDING" = 1 ] ||
      [ "$SPAWN_TASK_TMP_CREATED" = 1 ] || [ -n "$SPAWN_STAGED_LAUNCH_FILE" ]; } &&
    [ "$RELAUNCH" -eq 0 ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
    if [ "$SPAWN_FRESH_ENDPOINT_OPENED" = 1 ] && [ "$SPAWN_LAUNCH_SENT" = 0 ] && [ -n "${T:-}" ]; then
      SPAWN_FRESH_ENDPOINT_OPENED=0
      local abort_tab_id=
      [ "$BACKEND" != zellij ] || abort_tab_id=${ZELLIJ_TAB_ID:-}
      if fm_backend_kill "$BACKEND" "$T" "$abort_tab_id" "fm-$ID" 2>/dev/null; then
        SPAWN_ENDPOINT_CLOSED=1
      else
        echo "warning: could not close endpoint $T after the failed spawn of $ID; close it by hand so its slot returns to the pool" >&2
      fi
    fi
    # These paths are per task id, so the per-id spawn lock is retaken for them
    # exactly as for the strip dir below: a retry of the same id that took the
    # lock meanwhile may already be reusing them.
    if { [ "$SPAWN_LAUNCH_SENT" = 0 ] || [ "$SPAWN_ENDPOINT_CLOSED" = 1 ]; } &&
      { [ "$SPAWN_FRESH_WIRING_PENDING" = 1 ] || [ "$SPAWN_TASK_TMP_CREATED" = 1 ] ||
        [ -n "$SPAWN_STAGED_LAUNCH_FILE" ]; }; then
      if fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
        if [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
          if [ "$SPAWN_FRESH_WIRING_PENDING" = 1 ] && [ -n "${WT:-}" ] && [ -n "${STATE_REAL:-}" ]; then
            SPAWN_FRESH_WIRING_PENDING=0
            clear_relaunch_harness_wiring "$HARNESS" "$WT" "$STATE_REAL" "$ID" "$KIND" ||
              echo "warning: could not remove $HARNESS wiring after the failed spawn of $ID" >&2
          fi
          if [ "$SPAWN_TASK_TMP_CREATED" = 1 ] && [ -n "${TASK_TMP:-}" ]; then
            SPAWN_TASK_TMP_CREATED=0
            rm -rf -- "$TASK_TMP" 2>/dev/null || true
          fi
          if [ -n "$SPAWN_STAGED_LAUNCH_FILE" ] && [ "${ORCA_LAUNCH_ENV_ENABLED:-0}" != 1 ]; then
            rm -f -- "$SPAWN_STAGED_LAUNCH_FILE" 2>/dev/null || true
            rmdir -- "$(dirname "$SPAWN_STAGED_LAUNCH_FILE")" 2>/dev/null || true
          fi
        fi
        fm_lock_release "$SPAWN_TASK_LOCK" || true
      else
        echo "warning: another spawn of $ID holds its spawn lock; leaving its $HARNESS wiring, temp root, and staged launch file in place" >&2
      fi
    fi
  fi
  # A durable Herdr lease outlives the pane, unlike the process lease the
  # interactive command used to take, so an abort that leaves no record returns
  # it, whether or not the launch was sent. Only a pane Herdr reports gone and a
  # copy with no uncommitted work prove nothing is left to inspect there; any
  # other keeps the lease and names the command, as the pane used to hold the
  # slot for the operator.
  if [ "$HERDR_LEASED" = 1 ] && [ "$status" -ne 0 ] && [ -n "${WT:-}" ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
    HERDR_LEASED=0
    local herdr_slot_status
    if [ "$SPAWN_ENDPOINT_CLOSED" = 1 ] && fm_backend_herdr_endpoint_confirmed_gone "${T:-}" &&
      herdr_slot_status=$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null) &&
      [ -z "$herdr_slot_status" ] &&
      (cd "$PROJ_ABS" && treehouse return --force "$WT") >/dev/null 2>&1; then
      :
    else
      echo "warning: the worktree $WT stays leased to $ID after the failed spawn; once inspected, run 'treehouse return --force $WT' from $PROJ_ABS" >&2
    fi
  fi
  # A spawn that aborts after claiming its slot but before its record survives
  # must not leave a claim naming a task no record describes. The release is a
  # read-then-remove, so it runs only while the project lock that wrote the
  # claim is still held (aborts before metadata publication); a later abort has
  # already released that lock and leaves the claim for the next spawn's
  # atomic replacement rather than racing it. A polytoken spawn instead retakes
  # that lock once for a later failure whose record was rolled back. The
  # release itself never removes another task's claim.
  if [ "$SPAWN_SLOT_CLAIMED" = 1 ] && [ -n "${WT:-}" ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] &&
    fm_treehouse_pool_slot "$PROJ_ABS" "$WT"; then
    SPAWN_SLOT_CLAIMED=0
    if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
      fm_treehouse_slot_owner_release "$WT" "$ID" || true
    elif [ "${HARNESS:-}" = polytoken ] && [ -n "$SPAWN_TREEHOUSE_PROJECT_LOCK" ] &&
      fm_lock_try_acquire "$SPAWN_TREEHOUSE_PROJECT_LOCK"; then
      fm_treehouse_slot_owner_release "$WT" "$ID" || true
      fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK" || true
    else
      echo "warning: leaving task $ID's slot claim on $WT in place; the Treehouse project lock is no longer held, so the next spawn's claim replaces it" >&2
    fi
  fi
  if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
    SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
    fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK" || true
  fi
  if [ "$SPAWN_LANE_ADMISSION_LOCK_HELD" = 1 ]; then
    SPAWN_LANE_ADMISSION_LOCK_HELD=0
    fm_lock_release "$SPAWN_LANE_ADMISSION_LOCK" || true
  fi
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
  fi
  if [ "$SPAWN_CONTROL_LOCK_HELD" = 1 ]; then
    SPAWN_CONTROL_LOCK_HELD=0
    fm_lock_release "$SPAWN_CONTROL_LOCK" || true
  fi
  [ -z "$SPAWN_META_TMP" ] || rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  if [ "$status" -ne 0 ] && [ "${ORCA_LAUNCH_ENV_ENABLED:-0}" = 1 ] && [ -n "$SPAWN_STAGED_LAUNCH_FILE" ]; then
    if [ "$SPAWN_LAUNCH_SENT" = 0 ] || [ "$SPAWN_ENDPOINT_CLOSED" = 1 ]; then
      rm -f -- "$SPAWN_STAGED_LAUNCH_FILE" 2>/dev/null || true
    else
      # The open terminal may still source the delivered file, and no other
      # owner is left to remove it once this spawn exits, so arbitrate exactly
      # as the consume deadline does.
      local reclaim_status=0
      spawn_orca_reclaim_launch_file || reclaim_status=$?
      case "$reclaim_status" in
        0) kimi_spawn_fail "spawn ended before Orca terminal $T ran the launch command; removed the launch file and refused the worker launch" || true ;;
        2) echo "warning: could not remove Orca launch file $SPAWN_STAGED_LAUNCH_FILE; remove it by hand" >&2 ;;
      esac
    fi
  fi
  if [ "$CONFIG_INHERIT_LOCK_HELD" = 1 ]; then
    CONFIG_INHERIT_LOCK_HELD=0
    fm_lock_release "$CONFIG_INHERIT_LOCK" || true
  fi
  # The per-id spawn lock is retaken so a concurrent spawn of the same id, which
  # reinstalls this strip dir, is never undone. A launched agent whose endpoint
  # was not closed may still be committing, so it keeps its strip.
  if [ "$status" -ne 0 ] && [ -n "$GIT_HOOKS_DIR" ] &&
    { [ "$SPAWN_LAUNCH_SENT" = 0 ] || [ "$SPAWN_ENDPOINT_CLOSED" = 1 ]; } &&
    fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
    if [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
      chmod u+w "$GIT_HOOKS_DIR" 2>/dev/null || true
      rm -rf "$GIT_HOOKS_DIR" 2>/dev/null || true
    fi
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  return "$status"
}

# One lock per live Herdr session/socket, shared across all homes. <session>
# is required so secondmate and primary spawns serialize against the same
# session without writing any other home's state directory.
#
# Default mode is one BOUNDED attempt. A clean create uses that default and
# falls back to the ordinary flat layout on contention. An exact resume also
# defaults to the bounded attempt and hard-refuses on contention (it does not
# degrade flat). Passing mode `wait` makes this call WAIT for the lock instead
# (`fm_lock_acquire_wait`, the same unbounded-wait idiom this file already uses
# for its other fleet-shared locks). Only the recovery path under the explicit
# --herdr-resume-lock-wait opt-in passes `wait`, so unbounded blocking on a
# third-party session lock never becomes the default for every caller.
# Dead-owner reclaim inside `fm_lock_try_acquire` still bounds a wait against a
# holder that crashed mid-hold.
spawn_herdr_presentation_order_lock_acquire() {
  local session=${1:-} mode=${2:-} attempt lock_path
  [ -n "$session" ] || session=$(fm_backend_herdr_session)
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  HERDR_PRESENTATION_ORDER_LOCK="$lock_path"
  if [ "$mode" = wait ]; then
    fm_lock_acquire_wait "$HERDR_PRESENTATION_ORDER_LOCK"
    HERDR_PRESENTATION_ORDER_LOCK_HELD=1
    return 0
  fi
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$HERDR_PRESENTATION_ORDER_LOCK"; then
      HERDR_PRESENTATION_ORDER_LOCK_HELD=1
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

clear_relaunch_harness_wiring() {
  local harness=$1 wt=$2 state=$3 id=$4 kind=${5-} token_path token auth_path path
  # The wiring arms above match on harness PREFIXES, because a task launched
  # from a raw command records that command's basename rather than the exact
  # adapter name. The retirement tables are keyed by the exact adapter, so the
  # recorded value is resolved to its adapter first; otherwise a task recorded
  # as, say, `grok-2` would have wiring armed and never retired. An
  # unrecognized value resolves to no adapter, which is also the case in which
  # no wiring was armed to begin with.
  harness=$(fm_control_harness_family "$harness") || harness=
  token_path=$(fm_control_harness_turnend_token_path "$harness" "$state" "$id") || return 1
  token=
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token <"$token_path" || [ -n "$token" ] || return 1
  fi
  auth_path=$(fm_control_harness_turnend_auth_path "$harness" "$token") || return 1
  if [ -n "$auth_path" ]; then
    rm -f -- "$auth_path" || return 1
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ "$harness" = polytoken ]; then
      case "$path" in
        "$wt"/*) git -C "$wt" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 && continue ;;
      esac
    fi
    rm -f -- "$path" || return 1
  done <<EOF
$(fm_control_harness_wiring_paths "$harness" "$wt" "$state" "$id" "$kind")
EOF
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -rf -- "$path" || return 1
  done <<EOF
$(fm_control_harness_wiring_dirs "$harness" "$state" "$id")
EOF
}

spawn_herdr_presentation_order_lock_release() {
  [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ] || return 0
  HERDR_PRESENTATION_ORDER_LOCK_HELD=0
  fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
}

spawn_batch_dispatch() {

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "$RELAUNCH" -eq 1 ] && [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ]; then
  echo "error: --relaunch is single-task only; relaunch each task explicitly" >&2
  exit 1
fi
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac then
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$DISPATCH_OVERRIDE" ] || shared_args+=(--dispatch-override "$DISPATCH_OVERRIDE")
  [ "$HERMES_PROFILE_SET" -eq 0 ] || shared_args+=(--hermes-profile "$HERMES_PROFILE")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  # One delivery contract applies to every pair in a batch, exactly like the shared
  # harness. Each pair still re-validates it against its own brief, so a batch
  # spanning several modes is two invocations rather than a silent mixed dispatch.
  [ "$MODE_SET" -eq 0 ] || shared_args+=(--mode "$MODE")
  [ "$YOLO_SET" -eq 0 ] || shared_args+=(--yolo "$YOLO")
  [ "$BRANCH_PREFIX_SET" -eq 0 ] || shared_args+=(--branch-prefix "$BRANCH_PREFIX")
  [ "$BASE_BRANCH_SET" -eq 0 ] || shared_args+=(--base-branch "$BASE_BRANCH")
  [ "$HERDR_RESUME_LOCK_WAIT" -eq 0 ] || shared_args+=(--herdr-resume-lock-wait)
  [ "$ACCOUNT_SET" -eq 0 ] || shared_args+=(--account "$ACCOUNT_ARG")
  for pair in "${POS[@]}"; do
    case "$pair" in
    *=*) : ;;
    *)
      echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2
      rc=2
      continue
      ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    fi
    pair_args=("${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}")
    [ "$KIND" != scout ] || pair_args+=(--scout)
    pair_rc=0
    FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair_args[@]}" || pair_rc=$?
    if [ "$pair_rc" -eq "$FM_PROJECT_CAPACITY_DEFER_EXIT" ]; then
      echo "batch: DEFERRED ${pair%%=*} (${pair#*=}) - its project or this machine's lanes are at capacity, so it stays queued" >&2
      [ "$rc" -ne 0 ] || rc=$FM_PROJECT_CAPACITY_DEFER_EXIT
    elif [ "$pair_rc" -ne 0 ]; then
      echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2
      rc=1
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || {
  echo "error: invalid task id" >&2
  exit 2
}
if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" = ship ]; then
  BRANCH="$BRANCH_PREFIX$ID"
  if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
    echo "error: --branch-prefix and task id must form a valid git branch (got '$BRANCH')" >&2
    exit 1
  fi
fi
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
elif [ "$RELAUNCH" -eq 1 ]; then
  echo "error: spawn refused: state directory does not exist at $STATE" >&2
  exit 1
fi
# Role partition: spawning NEW work is MAIN-owned. A relaunch of an existing
# task is legitimate branch recovery (fm-control drives it through this same
# entrypoint), so only a fresh spawn refuses the branch actor
# (contract: bin/fm-lease-lib.sh; a no-op in a native home, which has no branch
# actor). Queued means a dispatchable backlog item:
# one already queued at entry, or one the branch filed itself because the
# captain's away words explicitly call for that work (its backlog note cites
# the words); filing the item the captain asked for is not inventing work.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-lease-lib.sh"
if [ "$RELAUNCH" -ne 1 ]; then
  fm_lease_forbid_branch "new-task spawn (fm-spawn)"
fi
}
