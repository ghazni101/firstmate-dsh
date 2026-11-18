# shellcheck shell=bash
# herdr projection, slot arbitration, and backlog preflight.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

herdr_projection_meta_field_exact() { # <meta> <key>
  local meta=$1 key=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-
}

# A stale presentation journal never grants launch authority.
# Under the session lock, authoritative metadata must identify one positively
# dead or agent-free endpoint before token inspection may allow flat fallback.
# Exact Herdr fields are retained for the narrower version 2 reclaim path.
herdr_projection_existing_meta_allows_flat() { # <meta>
  local meta=$1 old_backend old_target old_session old_pane old_state target_session target_pane
  HERDR_RECOVERY_BACKEND=""
  HERDR_RECOVERY_WORKSPACE_ID=""
  HERDR_RECOVERY_TAB_ID=""
  HERDR_RECOVERY_PANE_ID=""
  old_backend=$(fm_backend_of_meta "$meta")
  old_target=$(fm_backend_target_of_meta "$meta")
  [ -n "$old_target" ] || {
    echo "error: existing metadata for $ID has no endpoint; refusing duplicate launch while its herdr presentation journal is quarantined" >&2
    return 1
  }
  HERDR_RECOVERY_BACKEND=$old_backend
  if [ "$old_backend" = herdr ]; then
    fm_backend_herdr_parse_target "$old_target" || {
      echo "error: existing herdr endpoint for $ID is malformed; refusing duplicate launch" >&2
      return 1
    }
    target_session=$FM_BACKEND_HERDR_SESSION
    target_pane=$FM_BACKEND_HERDR_PANE
    old_session=$(herdr_projection_meta_field_exact "$meta" herdr_session) || {
      echo "error: existing herdr metadata for $ID has an ambiguous session; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_WORKSPACE_ID=$(herdr_projection_meta_field_exact "$meta" herdr_workspace_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous workspace; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_TAB_ID=$(herdr_projection_meta_field_exact "$meta" herdr_tab_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous tab; refusing duplicate launch" >&2
      return 1
    }
    old_pane=$(herdr_projection_meta_field_exact "$meta" herdr_pane_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous pane; refusing duplicate launch" >&2
      return 1
    }
    [ "$target_session" = "$old_session" ] && [ "$target_pane" = "$old_pane" ] || {
      echo "error: existing herdr metadata for $ID has inconsistent endpoint identities; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_PANE_ID=$old_pane
    fm_backend_herdr_server_ensure "$old_session" || {
      echo "error: existing herdr endpoint for $ID could not be inspected; refusing duplicate launch" >&2
      return 1
    }
    old_state=$(fm_backend_herdr_pane_agent_state "$old_session" "$old_pane")
    case "$old_state" in
    # A stale registration over a shell-only pane is agent-free for RECOVERY
    # (--relaunch reuses the pane, issue #4115), but the duplicate-launch
    # corridor keeps refusing it like every other non-husk state, so a fresh
    # spawn is refused here consistently with the reclaim and presentation
    # gates downstream.
    dead | no-agent) return 0 ;;
    live | stale-agent | unknown)
      echo "error: existing herdr endpoint for $ID is $old_state; refusing duplicate launch" >&2
      return 1
      ;;
    esac
  fi
  old_state=$(fm_backend_agent_alive "$old_backend" "$old_target")
  case "$old_state" in
  dead) return 0 ;;
  alive | unknown)
    echo "error: existing $old_backend endpoint for $ID is $old_state; refusing duplicate launch" >&2
    return 1
    ;;
  esac
}

spawn_backlog_preflight() {

# Backlog preflight (bin/fm-backlog-transition-lib.sh). This spawn is about to
# become the sole owner of the row's In-flight transition, so prove the row is
# transitionable BEFORE any endpoint, worktree, or record exists: a refusal here
# costs nothing to unwind, while the same refusal after publication would strand
# a live pane. The authoritative mutation still runs under the meta lock below.
BACKLOG_TRANSITION=0
BACKLOG_ROW_STATE=
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  BACKLOG_TRANSITION=1
  if fm_backlog_row_probe "$DATA" "$ID"; then
    BACKLOG_ROW_STATE=$FM_BACKLOG_ROW_STATE
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    echo "error: task $ID has no backlog item in this home, so dispatching it would leave a worker no record owns; add it first (bin/fm-tasks-axi.sh add $ID '<title>' --kind $KIND) and re-run" >&2
    exit 1
  else
    echo "error: task $ID's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)" >&2
    exit 1
  fi
  if ! fm_backlog_row_dispatchable "$BACKLOG_ROW_STATE"; then
    echo "error: this home's backlog item $ID is not dispatchable in state $BACKLOG_ROW_STATE; refusing before creating its endpoint or local copy" >&2
    exit 1
  fi
else
  BACKLOG_GATE_STATUS=$?
  if [ "$BACKLOG_GATE_STATUS" -eq 2 ]; then
    echo "error: task $ID cannot be dispatched because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
fi

if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
if [ -e "$STATE/$ID.backlog-close" ] || [ -L "$STATE/$ID.backlog-close" ]; then
  echo "error: task $ID has a pending authoritative backlog close at $STATE/$ID.backlog-close; finish or repair that close before dispatching a new worker" >&2
  exit 1
fi

W="fm-$ID"
if [ "$RELAUNCH" -eq 1 ]; then
  # A secondmate's home already resolved WT above through the same validation a
  # fresh secondmate spawn uses; every other kind takes the recorded worktree.
  # Either way the worktree is REUSED, never re-created: its branch, commits and
  # uncommitted changes are exactly as the previous agent left them, and nothing
  # below may touch them.
  [ "$KIND" = secondmate ] || WT=$RELAUNCH_WT
  if [ "$RELAUNCH_REBIND" -eq 0 ]; then
    # Adopt the recorded endpoint instead of creating one. This is what keeps a
    # relaunch a REPLACEMENT rather than a second copy of the task: no new
    # terminal, no second worktree, and every uncommitted change left exactly
    # where the previous agent left it.
    T=$RELAUNCH_TARGET
    WT_TARGET=$T
    SES=${T%%:*}
  elif [ "$BACKEND" = rex ]; then
    # The recorded endpoint is authoritatively gone, so there is nothing to
    # adopt: create ONE fresh endpoint for the same task, opened directly in the
    # recorded worktree. The record published below writes window= and the rex
    # ids from these values, which is the whole rebind - the task id, brief,
    # worktree, armed poll and status log are untouched.
    #
    # Rex reaches here only on a PROVEN-gone block: its never-reused ids
    # answer a structured not-found from the server the record names
    # (fm_control_endpoint_absence_verdict owns that argument). The tab is
    # re-created in the RECORDED session while that session survives. A Rex
    # session never survives its server, so when the session itself is gone
    # the task goes where an ordinary spawn from this seat would put it; that
    # is the reclaim that recovers a server restart. Both placements open the
    # tab in reclaim mode, so a bare-shell husk an earlier refused reclaim left
    # carrying this task's label is replaced rather than blocking every retry.
    fm_backend_rex_container_ensure || exit 1
    FM_REX_TASK_SERVER=$(fm_backend_rex_server_endpoint) || {
      echo "error: could not read the Rex server endpoint to record for $W" >&2
      exit 1
    }
    rex_rebind_status=0
    REX_TASK_IDS=$(fm_backend_rex_create_task_in_session "$FM_REX_TASK_SESSION_ID" "$W" "$WT") \
      || rex_rebind_status=$?
    case "$rex_rebind_status" in
      0) ;;
      2) REX_TASK_IDS=$(fm_backend_rex_create_task "$W" "$WT" launcher-home reclaim) || exit 1 ;;
      *)
        echo "error: task $ID's endpoint could not be re-created in its recorded Rex session $FM_REX_TASK_SESSION_ID; see the refusal above for what failed" >&2
        exit 1
        ;;
    esac
    read -r FM_REX_TASK_SESSION_ID FM_REX_TASK_WINDOW_ID FM_REX_TASK_BLOCK_ID <<EOF
$REX_TASK_IDS
EOF
    if [ -z "$FM_REX_TASK_SESSION_ID" ] || [ -z "$FM_REX_TASK_BLOCK_ID" ]; then
      echo "error: rex did not return a session/block id for $W" >&2
      exit 1
    fi
    T=$(fm_backend_rex_target "$FM_REX_TASK_SESSION_ID" "$FM_REX_TASK_BLOCK_ID")
    SES=${T%%:*}
    WT_TARGET=$T
  else
    # The recorded endpoint is authoritatively gone, so there is nothing to
    # adopt: create ONE fresh endpoint for the same task, opened directly in the
    # recorded worktree. The record published below writes window= (and herdr's
    # ids) from these values, which is the whole rebind - the task id, brief,
    # worktree, armed poll and status log are untouched.
    #
    # Herdr reaches here only on a PROVEN-gone pane: its every read is scoped to
    # the session the record names (fm_control_endpoint_absence_verdict owns
    # that argument). tmux and every secondmate were already refused, and rex
    # took the branch above, so there is no dispatch left to make.
    #
    # This deliberately uses the FLAT container shape rather than Herdr's
    # presentation projection: projection is a presentation-only layout that is
    # never endpoint or ownership authority, and flat is already the documented
    # fallback for every recovery it cannot bind exactly
    # (docs/herdr-backend.md "Presentation spaces").
    #
    # KNOWN LIMITATION (bead fm-herdr-rebind-leak-20260913): the tab minted
    # below is registered with no abort cleanup, so a later refusal leaves that
    # pane behind and a retry mints another. Documented in
    # docs/agent-control.md rather than fixed here, because the remedy is
    # machinery the ordinary flat spawn path does not have either.
    #
    # Re-create the tab under the RECORDED herdr session. Without the explicit
    # session the container would resolve from the AMBIENT one
    # (${HERDR_SESSION:-default}), so reclaiming a task recorded on a named
    # session from a seat that is not in it would silently relocate the task
    # onto another herdr server - an identity change, published as a
    # self-consistent but wrong record.
    HERDR_REBIND_SES=${RELAUNCH_TARGET%%:*}
    HERDR_CONTAINER_RAW=$(HERDR_PANE_ID="$RELAUNCH_LAUNCHER_PANE_ID" \
      fm_backend_herdr_container_ensure "$PROJ_ABS" launcher-home "$HERDR_REBIND_SES") || {
      # container_ensure returns 1 for several unrelated reasons - a failed
      # version check, a server that will not start, an ambiguous workspace
      # label, a cross-session launcher identity, a failed workspace create -
      # and each already printed its own accurate message. Add only what this
      # layer actually knows, and name the session mismatch solely when there
      # IS one, rather than asserting a cause this condition cannot establish.
      #
      # A seat with NO herdr pane never reaches the cross-session guard at all:
      # fm_backend_herdr_launcher_identity returns 2 for it and the placement
      # falls back to the recorded session's labeled container, which is what
      # makes a plain ssh or cron reclaim work. Its ambient session still reads
      # `default` (fm_backend_herdr_session's fallback), so the inequality alone
      # would fire for EVERY named-session task reclaimed from a plain shell and
      # send the operator chasing a session mismatch that was never the cause.
      HERDR_AMBIENT_SES=$(fm_backend_herdr_session)
      if [ -n "$RELAUNCH_LAUNCHER_PANE_ID" ] && [ "$HERDR_AMBIENT_SES" != "$HERDR_REBIND_SES" ]; then
        echo "error: task $ID's endpoint could not be re-created in its recorded herdr session '$HERDR_REBIND_SES'; this seat is running in herdr session '$HERDR_AMBIENT_SES', and a reclaim never moves a task to another session" >&2
      else
        echo "error: task $ID's endpoint could not be re-created in its recorded herdr session '$HERDR_REBIND_SES'; see the refusal above for what failed" >&2
      fi
      exit 1
    }
    CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
    HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
    HERDR_SES=${CONTAINER%%:*}
    HERDR_WORKSPACE_ID=${CONTAINER#*:}
    HERDR_TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$W" "$WT" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
    read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    SES=$HERDR_SES
    WT_TARGET=$T
  fi
else
  case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    # #134 robustness (tmux): fm_backend_tmux_create_task captures a stable window
    # id and pins the window name (automatic-rename/allow-rename off) so a captain's
    # non-default tmux config cannot rename the window away from fm-<id> once
    # treehouse cd's into the worktree. WT_TARGET carries that stable id for the
    # rename-critical worktree-detection steps below; the persisted window= handle
    # stays $T (the name form), which is safe now that rename is disabled.
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS") || exit 1
    WT_TARGET="$WID"
    ;;
  herdr)
    # fm_backend_herdr_workspace_label resolves the target workspace from
    # FM_HOME. For every KIND except secondmate, this process's own FM_HOME is
    # already the right home (the primary spawning its own crewmate/scout, or
    # a secondmate spawning ITS OWN crewmate/scout from its own process's
    # FM_HOME - the latter needs no glue at all). A --secondmate spawn is the
    # one case that does: it is the PRIMARY's own fm-spawn.sh process
    # launching a DIFFERENT home (PROJ_ABS, already validated above as the
    # secondmate's home), so FM_HOME here still names the primary. Shadow it
    # to PROJ_ABS for just these two calls (bash restores it automatically
    # after each prefixed simple-command call) so the secondmate's tab lands
    # in the secondmate's own workspace, not the primary home's own one.
    #
    # Placement, separately from labeling: a crewmate/scout belongs in the
    # EXACT herdr workspace this launching process is itself running in, which
    # only its own herdr pane identity can name (a same-labeled sibling
    # workspace must never be adopted). A --secondmate launch is the exception -
    # it stands up a DIFFERENT home's own workspace by design - so it asks for
    # the per-home container instead of inheriting this launcher's.
    HERDR_LABEL_HOME=$FM_HOME
    HERDR_LAUNCHER_RELATIONSHIP=launcher-home
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
      HERDR_LAUNCHER_RELATIONSHIP=other-home
    fi
    HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
    HERDR_PROJECTED=0
    if [ "$KIND" != secondmate ] && fm_backend_herdr_presentation_enabled "$CONFIG" "$STATE"; then
      HERDR_SES=$(fm_backend_herdr_session)
      HERDR_PARENT_LABEL=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_workspace_label) || exit 1
      if [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
        fm_backend_herdr_server_ensure "$HERDR_SES" || {
          echo "error: herdr presentation recovery could not ensure its exact named session" >&2
          exit 1
        }
        # Refuse-by-default on contention. Wait only when the caller opted in
        # with --herdr-resume-lock-wait (see header).
        if [ "$HERDR_RESUME_LOCK_WAIT" = 1 ]; then
          spawn_herdr_presentation_order_lock_acquire "$HERDR_SES" wait || {
            echo "error: herdr presentation recovery could not resolve its session lock" >&2
            exit 1
          }
        else
          spawn_herdr_presentation_order_lock_acquire "$HERDR_SES" || {
            echo "error: herdr presentation recovery could not acquire its session lock; refusing a concurrent resume" >&2
            exit 1
          }
        fi
        if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
          herdr_projection_existing_meta_allows_flat "$STATE/$ID.meta" || exit 1
        fi
        fm_backend_herdr_projection_recovery_allows_flat \
          "$HERDR_SES" "$HERDR_PRESENTATION_JOURNAL" "$ID" || exit 1
        if [ "${HERDR_RECOVERY_BACKEND:-}" = herdr ]; then
          set +e
          FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_reclaim_task \
            "$HERDR_SES" "$HERDR_PRESENTATION_JOURNAL" "$ID" "$HERDR_LABEL_HOME" \
            "$HERDR_RECOVERY_WORKSPACE_ID" "$HERDR_RECOVERY_TAB_ID" "$HERDR_RECOVERY_PANE_ID" \
            "$HERDR_PARENT_LABEL" "$W" "$PROJ_ABS"
          HERDR_RECLAIM_STATUS=$?
          set -e
          case "$HERDR_RECLAIM_STATUS" in
          0)
            HERDR_PROJECTED=1
            HERDR_WORKSPACE_ID=$HERDR_RECOVERY_WORKSPACE_ID
            HERDR_SEEDED_DEFAULT_TAB_ID=""
            HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
            HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
            HERDR_PROJECTION_ABORT_CLEANUP=1
            HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
            HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
            HERDR_PROJECTION_ABORT_SEEDED_PANE=""
            HERDR_PROJECTION_ABORT_WORKSPACE=$HERDR_WORKSPACE_ID
            HERDR_PROJECTION_ABORT_TASK_TAB=$HERDR_TAB_ID
            HERDR_PROJECTION_ABORT_SEEDED_TAB=""
            ;;
          2)
            spawn_herdr_presentation_order_lock_release
            ;;
          *) exit 1 ;;
          esac
        else
          spawn_herdr_presentation_order_lock_release
        fi
      elif [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
        # Session lock path resolution and exact parent binding both need a
        # live named-session socket before journal publication.
        if ! fm_backend_herdr_server_ensure "$HERDR_SES"; then
          echo "warning: herdr presentation could not ensure its session server; using the ordinary flat layout without projection" >&2
        elif [ "${FM_BACKEND_HERDR_PRESENTATION_PREFERENCE:-default}" = default ] &&
          ! fm_backend_herdr_presentation_default_supported "$STATE" "$HERDR_SES"; then
          :
        elif spawn_herdr_presentation_order_lock_acquire "$HERDR_SES"; then
          # The projected child is placed and bound UNDER this launcher's exact
          # parent workspace. Its own herdr pane identity names that workspace
          # directly; the label lookup is only the fallback for a launcher with
          # no herdr ancestry at all. A claimed-but-broken identity refuses here
          # rather than projecting under a guessed parent.
          set +e
          fm_backend_herdr_launcher_identity "$HERDR_SES"
          HERDR_LAUNCHER_STATUS=$?
          set -e
          case "$HERDR_LAUNCHER_STATUS" in
          0) HERDR_PARENT_WORKSPACE_ID=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID ;;
          2) HERDR_PARENT_WORKSPACE_ID=$(fm_backend_herdr_projection_parent_workspace_exact \
            "$HERDR_SES" "$HERDR_PARENT_LABEL" 2>/dev/null || true) ;;
          *)
            spawn_herdr_presentation_order_lock_release
            exit 1
            ;;
          esac
          if [ -z "$HERDR_PARENT_WORKSPACE_ID" ]; then
            echo "warning: herdr presentation parent is absent or ambiguous; using the ordinary flat layout without projection" >&2
            spawn_herdr_presentation_order_lock_release
          else
            HERDR_PROJECTION_ID=$(fm_backend_herdr_projection_journal_create "$STATE" "$ID") || exit 1
            HERDR_PROJECTION_LABEL=$(fm_backend_herdr_projection_workspace_label "$ID" "$HERDR_PROJECTION_ID")
            if ! FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_create_task \
              "$PROJ_ABS" "$HERDR_PROJECTION_LABEL" "$W"; then
              if [ "${FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE:-0}" = 1 ]; then
                HERDR_PROJECTION_ABORT_CLEANUP=1
                HERDR_PROJECTION_ABORT_SESSION=$FM_BACKEND_HERDR_PROJECTION_SESSION
                HERDR_PROJECTION_ABORT_TASK_PANE=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
                HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
                HERDR_PROJECTION_ABORT_WORKSPACE=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
                HERDR_PROJECTION_ABORT_TASK_TAB=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
                HERDR_PROJECTION_ABORT_SEEDED_TAB=$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
              fi
              exit 1
            fi
            HERDR_PROJECTED=1
            HERDR_SES=$FM_BACKEND_HERDR_PROJECTION_SESSION
            HERDR_WORKSPACE_ID=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
            HERDR_SEEDED_DEFAULT_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
            HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
            HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
            HERDR_PROJECTION_ABORT_CLEANUP=1
            HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
            HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
            HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
            HERDR_PROJECTION_ABORT_WORKSPACE=$HERDR_WORKSPACE_ID
            HERDR_PROJECTION_ABORT_TASK_TAB=$HERDR_TAB_ID
            HERDR_PROJECTION_ABORT_SEEDED_TAB=$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
            # Opt-in project groups (docs/herdr-backend.md "Project groups"):
            # an empty key keeps the block-end placement. Off costs one file test.
            HERDR_GROUP_ORDER_KEY=
            [ ! -e "$CONFIG/herdr-project-groups" ] || HERDR_GROUP_ORDER_KEY=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
              "$SCRIPT_DIR/fm-herdr-groups.sh" order-key "$ID" "$PROJ_ABS" 2>/dev/null) || HERDR_GROUP_ORDER_KEY=
            fm_backend_herdr_projection_order_best_effort \
              "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_LABEL" "$HERDR_PARENT_WORKSPACE_ID" "$HERDR_GROUP_ORDER_KEY"
            HERDR_HOME_ID=$(fm_backend_herdr_projection_home_identity "$HERDR_LABEL_HOME" 2>/dev/null || true)
            if [ -n "$HERDR_HOME_ID" ] &&
              fm_backend_herdr_projection_live_binding_matches \
                "$HERDR_SES" "$HERDR_PROJECTION_ID" "$HERDR_WORKSPACE_ID" \
                "$HERDR_TAB_ID" "$HERDR_PANE_ID" "$HERDR_PARENT_WORKSPACE_ID" \
                "$HERDR_PARENT_LABEL" "$HERDR_PROJECTION_LABEL" "$W" &&
              fm_backend_herdr_projection_journal_bind \
                "$HERDR_PRESENTATION_JOURNAL" "$ID" "$HERDR_HOME_ID" "$HERDR_SES" \
                "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID" \
                "$HERDR_PARENT_WORKSPACE_ID" "$HERDR_PARENT_LABEL" "$HERDR_PROJECTION_LABEL" "$W"; then
              :
            else
              echo "warning: herdr presentation could not publish an exact restart binding; this task will use flat fallback after a restart" >&2
            fi
          fi
        else
          echo "warning: herdr presentation focus lock unavailable; using the ordinary flat layout without projection" >&2
        fi
      fi
    fi
    if [ "$HERDR_PROJECTED" -ne 1 ]; then
      HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS" "$HERDR_LAUNCHER_RELATIONSHIP") || exit 1
      # fm_backend_herdr_container_ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>"
      # (the second field empty when this call ADOPTED a pre-existing workspace
      # rather than creating a fresh one). Split on the guaranteed single tab
      # character; the seeded tab id is threaded through to create_task
      # untouched, which is the only function permitted to prune it (never
      # re-derived from labels - see docs/herdr-backend.md "Default-tab prune").
      CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
      HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
      HERDR_SES=${CONTAINER%%:*}
      HERDR_WORKSPACE_ID=${CONTAINER#*:}
      HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$PROJ_ABS" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
      read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    fi
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ;;
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
    ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$PROJ_ABS") || exit 1
    read -r ZELLIJ_TAB_ID ZELLIJ_PANE_ID <<EOF
$ZELLIJ_TASK_IDS
EOF
    if [ -z "$ZELLIJ_TAB_ID" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
      echo "error: zellij did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$ZELLIJ_SES:$ZELLIJ_PANE_ID"
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
    CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$PROJ_ABS") || exit 1
    read -r CMUX_WORKSPACE_ID CMUX_SURFACE_ID <<EOF
$CMUX_TASK_IDS
EOF
    if [ -z "$CMUX_WORKSPACE_ID" ] || [ -z "$CMUX_SURFACE_ID" ]; then
      echo "error: cmux did not return a workspace/surface id for $W" >&2
      exit 1
    fi
    T="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
    ;;
  paseo)
    fm_backend_paseo_container_ensure || exit 1
    PASEO_TASK_IDS=$(fm_backend_paseo_create_task "$W" "$PROJ_ABS") || exit 1
    read -r FM_PASEO_TASK_TERMINAL_ID FM_PASEO_TASK_WORKSPACE_ID <<EOF
$PASEO_TASK_IDS
EOF
    if [ -z "$FM_PASEO_TASK_TERMINAL_ID" ] || [ -z "$FM_PASEO_TASK_WORKSPACE_ID" ]; then
      echo "error: paseo did not return a terminal/workspace id for $W" >&2
      exit 1
    fi
    T="$FM_PASEO_TASK_TERMINAL_ID:$FM_PASEO_TASK_WORKSPACE_ID"
    ;;
  rex)
    # A --secondmate launch stands up the OTHER home's own Rex session, so it
    # shadows FM_HOME for the session label exactly as herdr does; every other
    # kind goes beside this launcher (bin/backends/rex.sh owns placement).
    fm_backend_rex_container_ensure || exit 1
    FM_REX_TASK_SERVER=$(fm_backend_rex_server_endpoint) || {
      echo "error: could not read the Rex server endpoint to record for $W" >&2
      exit 1
    }
    # The session lock follows the shadowed home too, so the secondmate's own
    # cleanup serializes against this launch on the same lock file.
    REX_LABEL_HOME=$FM_HOME
    REX_LABEL_ROOT=$FM_ROOT
    REX_LABEL_STATE=$STATE
    REX_LAUNCHER_RELATIONSHIP=launcher-home
    if [ "$KIND" = secondmate ]; then
      REX_LABEL_HOME=$PROJ_ABS
      REX_LABEL_ROOT=$PROJ_ABS
      REX_LABEL_STATE=$PROJ_ABS/state
      REX_LAUNCHER_RELATIONSHIP=other-home
    fi
    REX_TASK_IDS=$(FM_HOME="$REX_LABEL_HOME" FM_ROOT="$REX_LABEL_ROOT" STATE="$REX_LABEL_STATE" fm_backend_rex_create_task "$W" "$PROJ_ABS" "$REX_LAUNCHER_RELATIONSHIP") || exit 1
    read -r FM_REX_TASK_SESSION_ID FM_REX_TASK_WINDOW_ID FM_REX_TASK_BLOCK_ID <<EOF
$REX_TASK_IDS
EOF
    if [ -z "$FM_REX_TASK_SESSION_ID" ] || [ -z "$FM_REX_TASK_BLOCK_ID" ]; then
      echo "error: rex did not return a session/block id for $W" >&2
      exit 1
    fi
    T=$(fm_backend_rex_target "$FM_REX_TASK_SESSION_ID" "$FM_REX_TASK_BLOCK_ID")
    ;;
  tern)
    TERN_SESSION_ID=$(fm_backend_tern_container_ensure) || exit 1
    TERN_TASK_IDS=$(fm_backend_tern_create_task "$W" "$PROJ_ABS") || exit 1
    read -r TERN_TAB_ID TERN_BLOCK_ID <<EOF
$TERN_TASK_IDS
EOF
    if ! fm_backend_endpoint_u64_valid "$TERN_SESSION_ID" ||
      ! fm_backend_endpoint_u64_valid "$TERN_TAB_ID" ||
      ! fm_backend_endpoint_u64_valid "$TERN_BLOCK_ID"; then
      echo "error: tern did not return a numeric session/tab/block id for $W" >&2
      exit 1
    fi
    T="$TERN_SESSION_ID:$TERN_BLOCK_ID"
    ;;
  hc)
    HC_SES=$(fm_backend_hc_container_ensure) || exit 1
    HC_TERMINAL=$(fm_backend_hc_create_task "$HC_SES" "$W" "$PROJ_ABS") || exit 1
    T="$HC_SES:$HC_TERMINAL"
    ;;
  orca)
    set +e
    ORCA_WT_RAW=$(fm_backend_orca_worktree_create "$PROJ_ABS" "$W")
    ORCA_WT_STATUS=$?
    set -e
    if [ "$ORCA_WT_STATUS" -ne 0 ]; then
      if [ "$ORCA_WT_STATUS" -eq 2 ] && [ -n "$ORCA_WT_RAW" ]; then
        if parse_orca_worktree_result "$ORCA_WT_RAW" && [ -n "$ORCA_WORKTREE_ID" ]; then
          ORCA_ABORT_CLEANUP=1
        fi
      fi
      exit 1
    fi
    parse_orca_worktree_result "$ORCA_WT_RAW" || true
    ORCA_ABORT_CLEANUP=1
    if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ]; then
      echo "error: orca did not return a worktree id/path for $W" >&2
      exit 1
    fi
    validate_spawn_worktree "orca worktree create" "$W"
    if [ -z "$ORCA_TERMINAL" ]; then
      ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
    fi
    T="$ORCA_TERMINAL"
    ;;
  t3code)
    # Validate the project policy before the first T3 or Treehouse mutation;
    # installation rechecks the actual leased worktree's configuration. A
    # worker's leased worktree shares only tracked files with this checkout, so
    # an untracked config here is checked only for a secondmate, whose launch
    # directory this checkout is.
    if [ "$HARNESS" = codex ] && { [ "$KIND" = secondmate ] || git -C "$PROJ_ABS" ls-files --error-unmatch .codex/config.toml >/dev/null 2>&1; }; then
      echo 'error: t3code was removed from the opinionated stack' >&2; exit 1
    fi
    if [ "$HARNESS" = codex ] && ! fm_backend_t3code_codex_trusted "$PROJ_ABS" "$KIND"; then
      echo "warning: could not confirm that ${CODEX_HOME:-$HOME/.codex}/config.toml trusts $PROJ_ABS; Codex ignores an untrusted project's .codex/config.toml, so this T3 Codex thread would run without FM_TASK_ID, FM_TASK_INBOX, GOTMPDIR, and the core.hooksPath push guard Firstmate writes there; trust the project in the Codex configuration T3 uses ([projects.\"<main checkout>\"] trust_level = \"trusted\", see docs/t3code-backend.md#setup)" >&2
    fi
    if [ "$HARNESS" = claude ] && [ "$KIND" != secondmate ] && git -C "$PROJ_ABS" ls-files --error-unmatch CLAUDE.local.md >/dev/null 2>&1; then
      echo "error: $PROJ_ABS tracks CLAUDE.local.md, which backend=t3code writes as the Claude task-worker channel statement; refusing to overwrite project instructions" >&2
      exit 1
    fi
    # The T3 project is the directory the agent runs in: the project for a
    # worker, the home itself for a secondmate.
    T3CODE_PROJECT_ID=$(fm_backend_t3code_project_ensure "$PROJ_ABS") || exit 1
    T3CODE_MODEL_SELECTION=$(fm_backend_t3code_model_selection "$HARNESS" "${MODEL:-default}" "${EFFORT:-default}" "$T3CODE_PROJECT_ID") || exit 1
    if [ "$KIND" = secondmate ]; then
      # The home's own daemon and crew call the same server, so they read the
      # primary's credential through a link rather than a copy of the secret.
      T3CODE_HOME_ENV=1
      if ! { mkdir -p "$PROJ_ABS/config" &&
        ln -sfn "$(cd "$CONFIG" && pwd -P)/t3code-token" "$PROJ_ABS/config/t3code-token"; }; then
        echo "error: could not link the T3 credential into $PROJ_ABS/config for $ID" >&2
        exit 1
      fi
      # No worktree of its own: the root workspace strategy runs the thread in
      # the project's workspaceRoot, the home, on whatever branch it is on.
      T3CODE_CREATE_UNCERTAIN=1
      T=$(fm_backend_t3code_thread_create "$T3CODE_PROJECT_ID" "$W" \
        "$(git -C "$PROJ_ABS" branch --show-current 2>/dev/null || true)" "" "$T3CODE_MODEL_SELECTION") || {
          [ "$?" -eq 1 ] || T3CODE_CREATE_UNCERTAIN=0
          exit 1
        }
      T3CODE_CREATE_UNCERTAIN=0
    else
      # A durable lease (bin/fm-home-seed.sh's pattern): there is no pane to run
      # the interactive `treehouse get` in, and a slot a live T3 thread points at
      # must never be handed on while that thread could re-create it.
      WT=$(cd "$PROJ_ABS" && treehouse get --lease --lease-holder "$ID") || {
        echo "error: treehouse get --lease failed to lease a worktree for $ID from $PROJ_ABS" >&2
        exit 1
      }
      [ -n "$WT" ] || { echo "error: treehouse get --lease did not report a worktree for $ID" >&2; exit 1; }
      validate_spawn_worktree "treehouse get --lease" "$WT (leased to $ID; once inspected, release it with 'treehouse return --force $WT' from $PROJ_ABS)"
      T3CODE_LEASED=1
      freshen_spawn_worktree_base "$WT" "$BASE_BRANCH" "$PROJ_ABS" "$MODE" || {
        if [ "$?" -eq 2 ]; then
          T3CODE_LEASED=0
          echo "error: $WT stays leased to $ID; once inspected, release it with 'treehouse return --force $WT' from $PROJ_ABS" >&2
        fi
        exit 1
      }
      T3CODE_CREATE_UNCERTAIN=1
      T=$(fm_backend_t3code_thread_create "$T3CODE_PROJECT_ID" "$W" \
        "$(git -C "$WT" branch --show-current 2>/dev/null || true)" "$WT" "$T3CODE_MODEL_SELECTION") || {
          [ "$?" -eq 1 ] || T3CODE_CREATE_UNCERTAIN=0
          exit 1
        }
      T3CODE_CREATE_UNCERTAIN=0
    fi
    T3CODE_ABORT_CLEANUP=1
    ;;
  esac
  # Orca and the Herdr projection own their own abort cleanup above; every other
  # endpoint a fresh polytoken spawn opened is closed by spawn_abort_cleanup when
  # the spawn ends with no record before its launch is delivered.
  if [ "$HARNESS" = polytoken ] && [ "$BACKEND" != orca ] && [ "${HERDR_PROJECTED:-0}" -ne 1 ]; then
    SPAWN_FRESH_ENDPOINT_OPENED=1
  fi
fi
if [ "$KIND" = secondmate ]; then
  FM_INHERITABLE_CONFIG=trace-context \
    propagate_inheritable_config "$CONFIG" "$PROJ_ABS/config" ||
    echo "warning: secondmate $ID trace-context inheritance failed for $PROJ_ABS" >&2
fi
# #134 robustness: only tmux needs a worktree-detection target distinct from $T -
# its rename-safe stable window id, set as WT_TARGET=$WID in the tmux branch above.
# Every other backend addresses its pane/surface by the id already in $T, so default
# WT_TARGET to $T for them (and for any future backend) - the shared treehouse-get +
# worktree-detection steps below must never reference an unbound WT_TARGET under set -u.
: "${WT_TARGET:=$T}"
}
