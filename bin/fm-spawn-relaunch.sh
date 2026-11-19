# shellcheck shell=bash
# relaunch state preservation.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

preserve_relaunch_meta() {
  awk -F= '
    BEGIN {
      split("window endpoint_task_id worktree project harness hermes_profile hermes_home kind mode yolo branch tasktmp base_branch upstream_consent forge backup_remote backup_prefix model effort opencode_version account account_provider omp_profile busy_gen spawn_gen approval_mode traceparent backend herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id zellij_session zellij_tab_id zellij_pane_id orca_worktree_id terminal cmux_workspace_id cmux_surface_id paseo_terminal_id paseo_workspace_id rex_server rex_session_id rex_window_id rex_block_id t3_thread_id t3_project_id tern_session_id tern_tab_id tern_block_id hc_session hc_terminal home projects control_relaunch_tx polytoken_session polytoken_port polytoken_credential", keys, " ")
      for (i in keys) owned[keys[i]] = 1
    }
    !($1 in owned)
  ' "$RELAUNCH_META"
}

spawn_preserve_relaunch_state() {
{
  echo "window=$META_WINDOW"
  echo "endpoint_task_id=$ID"
  # Owning interactive DSH session, passed by the native command channel. It
  # scopes routine supervision traffic to this session's own crews. A relaunch
  # with no channel owner preserves the recorded line below.
  if [ -n "${FM_SESSION_OWNER:-}" ]; then
    case "$FM_SESSION_OWNER" in
      *[!A-Za-z0-9._:-]*)
        echo "error: FM_SESSION_OWNER for $ID is not a valid session id" >&2
        exit 1
        ;;
    esac
    [ "${#FM_SESSION_OWNER}" -le 128 ] || {
      echo "error: FM_SESSION_OWNER for $ID is too long" >&2
      exit 1
    }
    echo "dsh_session=$FM_SESSION_OWNER"
  fi
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  if [ "$RAW_LAUNCH" = 0 ]; then
    case "$HARNESS" in
      claude) echo "approval_mode=$CLAUDE_PERMISSION_MODE" ;;
      codex) echo "approval_mode=$CODEX_APPROVAL_MODE" ;;
    esac
  fi
  echo "kind=$KIND"
  [ -z "$MODE" ] || echo "mode=$MODE"
  [ -z "$YOLO" ] || echo "yolo=$YOLO"
  [ -z "${BRANCH:-}" ] || echo "branch=$BRANCH"
  echo "tasktmp=$TASK_TMP"
  [ -z "$BASE_BRANCH" ] || echo "base_branch=$BASE_BRANCH"
  [ -z "$UPSTREAM_CONSENT" ] || echo "upstream_consent=$UPSTREAM_CONSENT"
  # Read by bin/fm-dod-lib.sh's ready-report gate; absent on every other forge.
  [ "$EXTERNAL_REVIEW" = 0 ] || echo "forge=external"
  [ -z "$EXTERNAL_BACKUP_REMOTE" ] || echo "backup_remote=$EXTERNAL_BACKUP_REMOTE"
  [ -z "$EXTERNAL_BACKUP_REMOTE" ] || echo "backup_prefix=$EXTERNAL_BACKUP_PREFIX"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  [ -z "$DISPATCH_OVERRIDE" ] || printf 'dispatch_override=%s\n' "$DISPATCH_OVERRIDE"
  # The detected OpenCode major, recorded so fm-control sends the exit key this
  # agent's TUI understands. Written only when a version was resolved, so a
  # non-opencode or undetectable task record stays byte-identical.
  [ -z "$OPENCODE_VERSION" ] || echo "opencode_version=$OPENCODE_VERSION"
  # The worker account pin, only when this home declares one, so an unpinned
  # task record stays byte-identical.
  [ -z "$WORKER_ACCOUNT" ] || echo "account=$WORKER_ACCOUNT_DECLARED"
  [ -z "$WORKER_ACCOUNT_PROVIDER" ] || echo "account_provider=$WORKER_ACCOUNT_PROVIDER"
  # The per-secondmate omp profile pin, only when one applies, so every other
  # task record stays byte-identical.
  [ -z "$OMP_PROFILE_PIN" ] || echo "omp_profile=$OMP_PROFILE_PIN"
  [ "$HARNESS" != hermes ] || { echo "hermes_profile=$HERMES_PROFILE"; echo "hermes_home=$HERMES_PROFILE_HOME"; }
  [ -z "${BUSY_GEN:-}" ] || echo "busy_gen=$BUSY_GEN"
  echo "spawn_gen=$SPAWN_GEN"
  # Default-off writes no traceparent= line.
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  # backend_detect= records which Herdr app signal auto-selected hc, so the
  # task record carries the reason, not just the result. Every other
  # selection (explicit, default, or another detected backend) writes none.
  case "$BACKEND:${FM_BACKEND_DETECT_SIGNAL:-}" in
    hc:app-terminal) echo "backend_detect=$FM_BACKEND_DETECT_SIGNAL" ;;
  esac
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$BACKEND" = zellij ]; then
    echo "zellij_session=$ZELLIJ_SES"
    echo "zellij_tab_id=$ZELLIJ_TAB_ID"
    echo "zellij_pane_id=$ZELLIJ_PANE_ID"
  fi
  if [ "$BACKEND" = orca ]; then
    echo "orca_worktree_id=$ORCA_WORKTREE_ID"
    echo "terminal=$ORCA_TERMINAL"
  fi
  if [ "$BACKEND" = cmux ]; then
    echo "cmux_workspace_id=$CMUX_WORKSPACE_ID"
    echo "cmux_surface_id=$CMUX_SURFACE_ID"
  fi
  if [ "$BACKEND" = paseo ]; then
    echo "paseo_terminal_id=$FM_PASEO_TASK_TERMINAL_ID"
    echo "paseo_workspace_id=$FM_PASEO_TASK_WORKSPACE_ID"
  fi
  if [ "$BACKEND" = rex ]; then
    echo "rex_server=$FM_REX_TASK_SERVER"
    echo "rex_session_id=$FM_REX_TASK_SESSION_ID"
    echo "rex_window_id=$FM_REX_TASK_WINDOW_ID"
    echo "rex_block_id=$FM_REX_TASK_BLOCK_ID"
  fi
  if [ "$BACKEND" = t3code ]; then
    echo "t3_thread_id=$T"
    echo "t3_project_id=$T3CODE_PROJECT_ID"
  fi
  if [ "$BACKEND" = tern ]; then
    echo "tern_session_id=$TERN_SESSION_ID"
    echo "tern_tab_id=$TERN_TAB_ID"
    echo "tern_block_id=$TERN_BLOCK_ID"
  fi
  if [ "$BACKEND" = hc ]; then
    echo "hc_session=$HC_SES"
    echo "hc_terminal=$HC_TERMINAL"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
  if [ "$SPAWN_CONTROL_PARENT" = 1 ] && [ -n "${FM_CONTROL_RELAUNCH_TX:-}" ]; then
    echo "control_relaunch_tx=$FM_CONTROL_RELAUNCH_TX"
  fi
  # Preserved lines go last so an armed pr= identity block stays last, as
  # fm_pr_metadata_identity_parse (bin/fm-pr-lib.sh) requires; otherwise the
  # armed merge poll stops validating relaunched lanes.
  if [ "$RELAUNCH" -eq 1 ]; then
    preserve_relaunch_meta
  fi
} >"$SPAWN_META_PATH" || {
  echo "error: task record for $ID could not be prepared at $SPAWN_META_PATH" >&2
  exit 1
}
if [ "$RELAUNCH" -eq 0 ]; then
  if ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE"; then
    echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  SPAWN_META_TMP=
fi

}
