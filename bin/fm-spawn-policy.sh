# shellcheck shell=bash
# spawn admission policy and relaunch preflight.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

spawn_refuse_if_away_spend_cap() {
  local cap live
  [ "$RELAUNCH" -ne 1 ] || return 0
  [ "$KIND" != secondmate ] || return 0
  [ -f "$STATE/.afk-contract" ] || return 0
  FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1 || return 0
  [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" = away ] || return 0
  cap=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" field spend_max_concurrent_workers 2>/dev/null || true)
  case "$cap" in
  '' | *[!0-9]* | 0) return 0 ;;
  esac
  live=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" live-workers 2>/dev/null || true)
  case "$live" in
  '' | *[!0-9]*)
    echo "error: spawn refused - the away-posture record caps concurrent workers at $cap and this home's live ordinary task count could not be read; task $ID stays queued (spend cap: bin/fm-afk-contract.sh)" >&2
    exit 1
    ;;
  esac
  if [ "$live" -ge "$cap" ]; then
    echo "error: spawn refused - the away-posture record caps concurrent workers at $cap and $live ordinary task(s) are live in this home; task $ID stays queued for the captain's return or for a worker to finish (spend cap: bin/fm-afk-contract.sh)" >&2
    exit 1
  fi
}

spawn_admission_preflight() {
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_CONTROL_LOCK="$STATE/.control-$ID.lock"
  control_owner=$(cat "$SPAWN_CONTROL_LOCK/pid" 2>/dev/null || true)
  if [ "$control_owner" = "$PPID" ] && fm_pid_alive "$control_owner"; then
    SPAWN_CONTROL_PARENT=1
  elif fm_lock_try_acquire "$SPAWN_CONTROL_LOCK"; then
    SPAWN_CONTROL_LOCK_HELD=1
  else
    echo "error: another lifecycle action is already running for task $ID" >&2
    exit 1
  fi
fi
ORCA_LAUNCH_ENV_ENABLED=0
ORCA_LAUNCH_ENV_ARGS=
if [ "$RELAUNCH" -eq 0 ]; then
  mkdir -p "$STATE" || {
    echo "error: could not create parent state directory" >&2
    exit 1
  }
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  # A FRESH spawn changes which tasks this home has, so it must not interleave
  # with a forced teardown that has already enumerated that set: a record
  # published inside the enumerate-then-remove window is invisible to the
  # teardown's per-task preflight but visible to its cleanup, and gets mutated
  # while never lifecycle-locked (bin/fm-wake-lib.sh's fm_task_set_lock_path
  # owns the evidence; bin/fm-teardown.sh holds the same lock from enumeration
  # through cleanup). Taken before this task's own locks, matching the
  # acquisition order documented there, and held through publication.
  #
  # A relaunch is exempt: it republishes a task that already exists, so it is
  # already covered by that task's control lock, which the teardown preflight
  # tests.
  #
  # Refusing rather than waiting is the fail-closed direction: the home may be
  # moments from removal, so there is nothing worth waiting for.
  SPAWN_TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || {
    echo "error: could not resolve the task-set lock for $STATE" >&2
    exit 1
  }
  if ! fm_lock_try_acquire "$SPAWN_TASK_SET_LOCK"; then
    case "$(fm_lock_role "$SPAWN_TASK_SET_LOCK" 2>/dev/null || true)" in
      task-spawn)
        echo "error: this home's task set is locked by another spawn; refusing to create task $ID rather than racing it" >&2
        ;;
      forced-teardown)
        echo "error: this home's task set is locked by a forced teardown; refusing to create task $ID rather than racing it" >&2
        ;;
      *)
        echo "error: this home's task set is locked by another operation; refusing to create task $ID rather than racing it" >&2
        ;;
    esac
    exit 1
  fi
  if ! fm_lock_set_role "$SPAWN_TASK_SET_LOCK" task-spawn; then
    fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
    echo "error: could not record task-set lock holder for spawn of $ID" >&2
    exit 1
  fi
  SPAWN_TASK_SET_LOCK_HELD=1
  spawn_refuse_if_away_spend_cap
fi
if [ "$KIND" = secondmate ]; then
  if spawn_remote_secondmate "$ID"; then
    exit 0
  else
    remote_spawn_rc=$?
  fi
  [ "$remote_spawn_rc" -eq 3 ] || exit "$remote_spawn_rc"
fi
# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown or
# non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$RELAUNCH" -eq 0 ]; then
  if [ "$BACKEND_SET" -eq 1 ]; then
    BACKEND=$BACKEND_ARG
    FM_BACKEND_DETECT_SIGNAL=""
  else
    # Called directly so the one detection that chose BACKEND also leaves
    # FM_BACKEND_DETECT_SIGNAL for the meta's backend_detect= line below.
    fm_backend_resolve
    BACKEND=$FM_BACKEND_RESOLVED
  fi
  fm_backend_validate_spawn "$BACKEND" || exit 1
  fm_backend_source "$BACKEND" || exit 1
  if [ "$BACKEND" = orca ] && [ "$KIND" = secondmate ]; then
    echo "error: backend=orca does not support --secondmate spawns yet" >&2
    exit 1
  fi
  if [ "$BACKEND" = cmux ] && [ "$KIND" = secondmate ]; then
    echo "error: backend=cmux does not support --secondmate spawns yet" >&2
    exit 1
  fi
  if [ "$BACKEND" = paseo ] && [ "$KIND" = secondmate ]; then
    echo "error: backend=paseo does not support --secondmate spawns yet" >&2
    exit 1
  fi
  if [ "$BACKEND" = tern ] && [ "$KIND" = secondmate ]; then
    echo "error: backend=tern does not support --secondmate spawns yet" >&2
    exit 1
  fi
  if [ "$BACKEND" = hc ] && [ "$KIND" = secondmate ]; then
    echo "error: backend=hc does not support --secondmate spawns yet" >&2
    exit 1
  fi
  fm_backend_runtime_check "$BACKEND" || exit 1
  if [ "$BACKEND" = rex ]; then
    fm_backend_rex_local_server_ensure || exit 1
  fi
  if [ "$BACKEND" = orca ]; then
    ORCA_LAUNCH_ENV_ENABLED=$(fm_config_source_present "$CONFIG/launch-env-tmux-session") || exit 1
    if [ "$ORCA_LAUNCH_ENV_ENABLED" = 1 ]; then
      if [ "$LAUNCH_ENV_ENABLED" != 1 ]; then
        echo "error: config/launch-env-tmux-session requires config/launch-env-allowlist; refusing Orca launch" >&2
        exit 1
      fi
      if [ ! -f "$CONFIG/launch-env-tmux-session" ] || [ ! -r "$CONFIG/launch-env-tmux-session" ]; then
        echo "error: config/launch-env-tmux-session must be a readable regular file" >&2
        exit 1
      fi
      ORCA_LAUNCH_ENV_SESSION=$(cat "$CONFIG/launch-env-tmux-session") || exit 1
      case "$ORCA_LAUNCH_ENV_SESSION" in
        ''|*[!A-Za-z0-9_-]*)
          echo "error: config/launch-env-tmux-session must contain one session name (letters, digits, underscores or hyphens)" >&2
          exit 1
          ;;
      esac
      ORCA_LAUNCH_ENV_ARGS=$(fm_backend_orca_launch_env_args \
        "$ORCA_LAUNCH_ENV_SESSION" "$LAUNCH_ENV_NAMES") || exit 1
    elif [ -n "$LAUNCH_ENV_NAMES" ]; then
      echo "warning: backend=orca resolves config/launch-env-allowlist names from the Orca terminal's own environment, not this home's; set config/launch-env-tmux-session to take them from a scoped tmux session" >&2
    fi
  fi
fi
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
  echo "error: another spawn is already creating task $ID" >&2
  exit 1
fi
SPAWN_TASK_LOCK_HELD=1
PROJ=
ARG3=
FIRSTMATE_HOME=
RAW_LAUNCH=0

# --relaunch adoption: every identity axis comes from the task's own validated
# durable record, never from the command line, so a relaunch can only ever
# re-launch the task it names. The endpoint identity check is the same shared
# validation teardown uses, so a malformed, ambiguous, or foreign record
# refuses here exactly as it refuses there.
RELAUNCH_PRIOR_HARNESS=
# 1 when the recorded endpoint is authoritatively gone and this relaunch must
# create a fresh one for the task rather than adopt its recorded address.
RELAUNCH_REBIND=0
if [ "$RELAUNCH" -eq 1 ]; then
  [ "${#POS[@]}" -eq 1 ] || {
    echo "error: --relaunch takes the task id only; its project or home comes from the task's own record" >&2
    exit 1
  }
  RELAUNCH_META="$STATE/$ID.meta"
  if [ ! -e "$RELAUNCH_META" ] && [ ! -L "$RELAUNCH_META" ]; then
    echo "error: --relaunch needs an existing task record; no $RELAUNCH_META" >&2
    exit 1
  fi
  fm_backlog_record_present "$RELAUNCH_META" "task record" "$STATE" || {
    echo "error: --relaunch refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  SPAWN_META_LOCK=$(fm_meta_lock_path "$RELAUNCH_META") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
  fm_backlog_record_present "$RELAUNCH_META" "task record" "$STATE" || {
    echo "error: --relaunch refused after locking: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  fm_backend_validate_task_endpoint "$RELAUNCH_META" "$ID" || exit 1
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  RELAUNCH_TARGET=$FM_BACKEND_VALIDATED_TARGET
  fm_backend_validate_spawn "$BACKEND" || exit 1
  fm_backend_source "$BACKEND" || exit 1
  # A relaunch must PROVE the previous agent is gone before it launches another
  # one into the same endpoint, and only a backend with a recovery-grade
  # classifier can (bin/fm-control-lib.sh owns that capability table).
  fm_control_backend_state_verified "$BACKEND" || {
    echo "error: backend '$BACKEND' has no recovery-grade agent-state classifier, so a relaunch cannot prove the previous agent exited; refusing rather than risking two agents in one endpoint" >&2
    exit 1
  }
  # The same table refuses a backend that cannot host a REPLACEMENT at all:
  # a T3 thread keeps its conversation, so a turn or a provider change on it
  # continues the same agent instead of launching a new one.
  fm_control_backend_relaunch_supported "$BACKEND" || {
    echo "error: backend '$BACKEND' cannot launch a replacement agent into an existing endpoint (a T3 thread keeps its conversation, so a turn or a provider change on it continues the same agent); refusing to relaunch $ID" >&2
    exit 1
  }
  # Two states are agent-free, and both license a relaunch:
  #   dead    - the endpoint exists and confidently holds no agent. The
  #             endpoint is ADOPTED, so the task keeps its exact address.
  #   missing - the endpoint itself is gone. There is no endpoint AND therefore
  #             no agent, so a relaunch cannot adopt it: it CREATES a fresh
  #             endpoint in the recorded worktree and the published record
  #             rebinds to it.
  # `missing` is NOT one state, and that is what the duplicate-agent argument
  # turns on. fm_backend_agent_state's per-backend `missing` conflates "the
  # endpoint was DESTROYED" with "the endpoint is UNREACHABLE from here right
  # now", and an unreachable endpoint can still hold the live agent this
  # relaunch would duplicate. So absence is PROVEN before it may rebind, never
  # inferred from a failed read - and only HERDR and REX can prove it:
  #   herdr - the recorded session's server is started, and the recorded pane is
  #           RE-READ through that session's own socket. `dead` means the pane
  #           survived the restart and is adopted after all; `alive` means the
  #           agent came back and refuses; only a second `missing` proves the
  #           pane itself did not survive.
  #   rex   - the recorded block is re-read on the server the record names
  #           (rex_server); Rex never reuses an id, so its structured
  #           not-found there proves the block itself is gone. A Rex
  #           `unreadable` is rechecked too, because a stopped Rex server
  #           reads as unreachable to a read that never starts it
  #           (fm_control_absence_recheck_applies owns that rule).
  #   tmux  - REFUSES, always. A task record carries no socket identity for its
  #           endpoint, and a server-wide inventory describes only the server
  #           this process addresses, so no read available here can tell "gone"
  #           from "on a server I cannot see". A tmux `missing` therefore stays
  #           as deadlocked as it was before this change - deliberately, and
  #           with the reason stated rather than guessed past.
  # Every transient or self-contradicting read stays `unreadable`/`ambiguous`
  # and refuses as it always did (bin/fm-backend.sh's fm_backend_agent_state
  # owns that vocabulary). The proof itself lives in one place for the whole
  # control plane - fm_control_endpoint_absence_verdict - so `exit` and
  # `relaunch` cannot reach two different answers about one endpoint.
  RELAUNCH_STATE=$(fm_backend_agent_state "$BACKEND" "$RELAUNCH_TARGET")
  if fm_control_absence_recheck_applies "$BACKEND" "$RELAUNCH_STATE"; then
    RELAUNCH_ABSENCE=$(fm_control_endpoint_absence_verdict "$BACKEND" "$RELAUNCH_TARGET" "$RELAUNCH_META")
    case "${RELAUNCH_ABSENCE%%$'\t'*}" in
      gone) RELAUNCH_STATE=missing ;;
      dead) RELAUNCH_STATE=dead ;;
      alive) RELAUNCH_STATE=alive ;;
      *)
        echo "error: task $ID's recorded endpoint $RELAUNCH_TARGET reads '$RELAUNCH_STATE', but ${RELAUNCH_ABSENCE#*$'\t'}. An endpoint that cannot be proven absent may still hold a live agent on this task's worktree; refusing rather than launching a second agent into it" >&2
        exit 1
        ;;
    esac
  fi
  case "$RELAUNCH_STATE" in
    dead) ;;
    missing) RELAUNCH_REBIND=1 ;;
    *)
      echo "error: task $ID's endpoint reads '$RELAUNCH_STATE'; a relaunch requires a positively agent-free endpoint (stop the agent first with bin/fm-control.sh $ID exit)" >&2
      exit 1
      ;;
  esac
  RELAUNCH_PRIOR_HARNESS=$(fm_meta_get "$RELAUNCH_META" harness)
  KIND=$(fm_meta_get "$RELAUNCH_META" kind)
  [ -n "$KIND" ] || KIND=ship
  # A secondmate whose endpoint is gone already has ONE owner for that
  # recovery: the session-start liveness sweep respawns it with
  # `fm-spawn.sh <id> --secondmate`, which stands its home's own workspace back
  # up (bin/fm-bootstrap.sh; the secondmate-provisioning skill). Rebinding one
  # here as well would be a second path to the same outcome, so this refuses
  # and names the one that owns it.
  if [ "$RELAUNCH_REBIND" -eq 1 ] && [ "$KIND" = secondmate ]; then
    echo "error: secondmate $ID's recorded endpoint is gone; its recovery is owned by the secondmate respawn path, not by relaunch (run bin/fm-spawn.sh $ID --secondmate, or let the session-start liveness sweep do it)" >&2
    exit 1
  fi
  MODE=$(fm_meta_get "$RELAUNCH_META" mode)
  YOLO=$(fm_meta_get "$RELAUNCH_META" yolo)
  UPSTREAM_CONSENT=$(fm_meta_get "$RELAUNCH_META" upstream_consent)
  if [ "$KIND" = ship ]; then
    BRANCH=$(fm_meta_get "$RELAUNCH_META" branch)
    [ -n "$BRANCH" ] || BRANCH="fm/$ID"
    if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
      echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
      exit 1
    fi
  fi
  RELAUNCH_WT=$(fm_meta_get "$RELAUNCH_META" worktree)
  [ -n "$RELAUNCH_WT" ] && [ -d "$RELAUNCH_WT" ] || {
    echo "error: task $ID's recorded worktree '${RELAUNCH_WT:-none}' is missing; refusing to relaunch without the local copy its work lives in" >&2
    exit 1
  }
  if [ "$KIND" = secondmate ]; then
    FIRSTMATE_HOME=$(fm_meta_get "$RELAUNCH_META" home)
    [ -n "$FIRSTMATE_HOME" ] || FIRSTMATE_HOME=$RELAUNCH_WT
  else
    PROJ=$(fm_meta_get "$RELAUNCH_META" project)
    [ -n "$PROJ" ] || {
      echo "error: task $ID has no recorded project; refusing to relaunch" >&2
      exit 1
    }
    # A worker must come back in its own disposable worktree, never in a
    # primary home or the recorded project repository's primary checkout:
    # refuse rather than fall back to wherever the restored pane happens to
    # sit. The checkout test is fresh spawn's own boundary
    # (spawn_worktree_isolated): the copy's git dir may not be the recorded
    # project's common git dir. A standalone clone clears it because its own
    # git dir is distinct from the recorded project's common git dir.
    relaunch_wt_real=$(cd "$RELAUNCH_WT" 2>/dev/null && pwd -P) || relaunch_wt_real=$RELAUNCH_WT
    relaunch_primary=
    for relaunch_cand in "$FM_HOME" "$FM_ROOT"; do
      relaunch_cand_real=$(cd "$relaunch_cand" 2>/dev/null && pwd -P) || continue
      [ "$relaunch_wt_real" = "$relaunch_cand_real" ] && relaunch_primary=$relaunch_cand
    done
    if [ -z "$relaunch_primary" ]; then
      # Probe both directories' own layouts in one scrubbed subshell: an
      # inherited GIT_DIR naming a linked worktree with GIT_WORK_TREE naming
      # the primary checkout would otherwise make the two answers differ and
      # pass the primary checkout.
      relaunch_gdc=$(
        unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
          GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
          GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
          GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT
        relaunch_probe_gd=$(git -C "$RELAUNCH_WT" rev-parse --absolute-git-dir 2>/dev/null) &&
          relaunch_probe_pc=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
          relaunch_probe_gd=$(cd "$relaunch_probe_gd" 2>/dev/null && pwd -P) &&
          relaunch_probe_pc=$(cd "$relaunch_probe_pc" 2>/dev/null && pwd -P) &&
          printf '%s\n%s\n' "$relaunch_probe_gd" "$relaunch_probe_pc"
      ) || relaunch_gdc=
      relaunch_wt_gd=${relaunch_gdc%%$'\n'*}
      case "$relaunch_gdc" in
        *$'\n'*) relaunch_proj_common=${relaunch_gdc#*$'\n'} ;;
        *) relaunch_proj_common= ;;
      esac
      [ -z "$relaunch_wt_gd" ] || [ -z "$relaunch_proj_common" ] ||
        [ "$relaunch_wt_gd" != "$relaunch_proj_common" ] ||
        relaunch_primary="the recorded project repository's primary checkout"
    fi
    [ -z "$relaunch_primary" ] || {
      echo "error: task $ID's recorded worktree '$RELAUNCH_WT' is the primary home or checkout ($relaunch_primary), not an isolated task worktree; refusing to relaunch a worker there" >&2
      exit 1
    }
  fi
  if [ "$BACKEND" = herdr ]; then
    # fm-spawn uses HERDR_PANE_ID for the TASK's pane, while the herdr adapter
    # reads that SAME name as the pane THIS process is itself running in
    # (fm_backend_herdr_launcher_identity). The record is about to overwrite it,
    # so keep what herdr actually injected: a rebind still has to prove its own
    # launcher identity, and a task's recorded pane is not it.
    RELAUNCH_LAUNCHER_PANE_ID=${HERDR_PANE_ID:-}
    HERDR_SES=$(fm_meta_get "$RELAUNCH_META" herdr_session)
    HERDR_WORKSPACE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_workspace_id)
    HERDR_TAB_ID=$(fm_meta_get "$RELAUNCH_META" herdr_tab_id)
    HERDR_PANE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_pane_id)
  fi
  if [ "$BACKEND" = rex ]; then
    FM_REX_TASK_SESSION_ID=$(fm_meta_get "$RELAUNCH_META" rex_session_id)
    FM_REX_TASK_WINDOW_ID=$(fm_meta_get "$RELAUNCH_META" rex_window_id)
    FM_REX_TASK_BLOCK_ID=$(fm_meta_get "$RELAUNCH_META" rex_block_id)
    FM_REX_TASK_SERVER=$(fm_meta_get "$RELAUNCH_META" rex_server)
  fi
  # With no explicit harness, a relaunch reuses the harness already recorded
  # for this task. It must NOT fall through to the fresh-spawn config
  # resolution, which would silently move an existing task onto whatever the
  # crew or secondmate default currently says. Choosing a different harness is
  # the caller's explicit decision, made with --harness (bin/fm-control.sh
  # resolves that decision, including a secondmate's durable pin).
  ARG3=${HARNESS_ARG:-$RELAUNCH_PRIOR_HARNESS}
  [ -n "$ARG3" ] || {
    echo "error: task $ID has no recorded harness; pass --harness to relaunch it" >&2
    exit 1
  }
elif [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
  '' | claude | codex | opencode | pi | pi-signed | grok | kimi | cursor | gemini | muse | rovo | omp | agy | devin | commandcode | polytoken | cortex | kiro | hermes)
    ARG3=${POS[1]:-}
    ;;
  *' '*)
    if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
    else
      ARG3=${POS[1]}
    fi
    ;;
  *)
    FIRSTMATE_HOME=${POS[1]}
    ARG3=${POS[2]:-}
    ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

}
