# shellcheck shell=bash
# harness delivery, readiness, and confirmation.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

# Shared state setup extracted from the former backend-specific relaunch phase.
# These globals are read by later phases for every kept harness and backend.
spawn_state_and_turnend_setup() {
  AGY_TRUST_PREREGISTERED=0
  TASK_TMP="/tmp/fm-$ID"
  mkdir -p "$TASK_TMP/gotmp"
  mkdir -p "$STATE"
  STATE_REAL=$(cd "$STATE" && pwd -P)
  TURNEND="$STATE_REAL/$ID.turn-ended"
}

spawn_send_text_line() { # <target> <text>
  case "$BACKEND" in
  tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
  herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
  zellij) fm_backend_zellij_send_text_line "$1" "$2" "$W" ;;
  orca) fm_backend_orca_send_text_line "$1" "$2" ;;
  cmux) fm_backend_cmux_send_text_line "$1" "$2" "$W" ;;
  paseo) fm_backend_paseo_send_text_line "$1" "$2" "$W" ;;
  rex) fm_backend_rex_send_text_line "$1" "$2" "$W" ;;
  t3code) fm_backend_t3code_send_literal "$1" "$2" ;;
  tern) fm_backend_tern_send_text_line "$1" "$2" "$W" ;;
  hc) fm_backend_hc_send_text_line "$1" "$2" "$W" ;;
  esac
}

spawn_current_path() { # <target>
  case "$BACKEND" in
  tmux) fm_backend_tmux_current_path "$1" ;;
  herdr) fm_backend_herdr_current_path "$1" ;;
  zellij) fm_backend_zellij_current_path "$1" "$W" ;;
  cmux) fm_backend_cmux_current_path "$1" "$W" ;;
  paseo) fm_backend_paseo_current_path "$1" "$W" ;;
  rex) fm_backend_rex_current_path "$1" "$W" ;;
  tern) fm_backend_tern_current_path "$1" "$W" ;;
  hc) fm_backend_hc_current_path "$1" "$W" ;;
  esac
}

spawn_send_literal() { # <target> <text>
  case "$BACKEND" in
  tmux) fm_backend_tmux_send_literal "$1" "$2" ;;
  herdr) fm_backend_herdr_send_literal "$1" "$2" ;;
  zellij) fm_backend_zellij_send_literal "$1" "$2" "$W" ;;
  orca) fm_backend_orca_send_literal "$1" "$2" ;;
  cmux) fm_backend_cmux_send_literal "$1" "$2" "$W" ;;
  paseo) fm_backend_paseo_send_literal "$1" "$2" "$W" ;;
  rex) fm_backend_rex_send_literal "$1" "$2" "$W" ;;
  t3code) fm_backend_t3code_send_literal "$1" "$2" ;;
  tern) fm_backend_tern_send_literal "$1" "$2" "$W" ;;
  # hc has no paste without submit, and its keys cannot type the launch line's
  # `+` or `_`, so the line is pasted and submitted here and the Enter that
  # follows it is consumed below (docs/hc-backend.md "Limits").
  hc) fm_backend_hc_send_text_line "$1" "$2" "$W" && SPAWN_HC_LINE_SUBMITTED=1 ;;
  esac
}

spawn_send_key() { # <target> <key>
  case "$BACKEND" in
  tmux) fm_backend_tmux_send_key "$1" "$2" ;;
  herdr) fm_backend_herdr_send_key "$1" "$2" ;;
  zellij) fm_backend_zellij_send_key "$1" "$2" "$W" ;;
  orca) fm_backend_orca_send_key "$1" "$2" ;;
  cmux) fm_backend_cmux_send_key "$1" "$2" "$W" ;;
  paseo) fm_backend_paseo_send_key "$1" "$2" "$W" ;;
  rex) fm_backend_rex_send_key "$1" "$2" "$W" ;;
  t3code) fm_backend_t3code_send_literal "$1" "$2" ;;
  tern) fm_backend_tern_send_key "$1" "$2" "$W" ;;
  hc)
    if [ "$2" = Enter ] && [ "$SPAWN_HC_LINE_SUBMITTED" = 1 ]; then
      SPAWN_HC_LINE_SUBMITTED=0
    else
      fm_backend_hc_send_key "$1" "$2" "$W"
    fi
    ;;
  esac
}

# Lease the task copy durably instead of typing the interactive `treehouse get`
# into the pane. That command runs a subshell, so the later `cd` lands inside
# it and the pane's top-level shell stays in the project; Herdr restores a pane
# from that top-level shell's cwd, so a host restart reopened every worker in
# the primary clone. A durable lease needs no subshell, which lets the cd in
# spawn_enter_recorded_worktree move the top-level shell itself. A lease
# outlives its pane, so an aborted spawn returns it (spawn_abort_cleanup) and
# bin/fm-teardown.sh returns it for a finished task.
spawn_lease_herdr_slot() {
  WT=$(cd "$PROJ_ABS" && treehouse get --lease --lease-holder "$ID") || {
    echo "error: treehouse get --lease failed to lease a worktree for $ID from $PROJ_ABS; $(spawn_endpoint_hint)" >&2
    exit 1
  }
  [ -n "$WT" ] || { echo "error: treehouse get --lease did not report a worktree for $ID" >&2; exit 1; }
  HERDR_LEASED=1
  validate_spawn_worktree "treehouse get --lease" "$WT (leased to $ID; once inspected, release it with 'treehouse return --force $WT' from $PROJ_ABS)"
}

# Enter the exact copy recorded for this task immediately before trust setup and
# launch. Herdr restores a pane's shell cwd from its durable tab layout, so a
# treehouse subshell's foreground cwd is not enough to keep a later pane restart
# out of the primary checkout. The same explicit cd gives every backend one
# launch boundary and makes a dropped or ignored cwd change a refusal.
spawn_enter_recorded_worktree() {
  [ "$KIND" = secondmate ] && return 0
  # T3 starts the agent in the leased worktree its thread launch bound;
  # there is no shell endpoint to receive a cd command.
  [ "$BACKEND" = t3code ] && return 0
  spawn_send_text_line "$WT_TARGET" "cd -- $(shell_quote "$WT")" || {
    echo "error: task $ID's endpoint could not be moved into its recorded worktree '$WT'; refusing to launch outside the copy holding its work" >&2
    exit 1
  }
}

# Verify the endpoint's cwd after the explicit handoff but before any harness
# starts. Zellij and cmux implement this read with a shell probe, so keeping it
# before launch prevents the probe from becoming input to a live worker.
spawn_assert_agent_worktree() {
  local expected seen i last_poll=19 agent_status
  [ "$KIND" = secondmate ] && return 0
  case "$BACKEND" in orca|t3code) return 0 ;; esac
  expected=$(real_path_or_raw "$WT")
  # The out-of-pane Herdr lease no longer waits for the new shell to process
  # treehouse get. Allow its former minute of startup tolerance here, and
  # repeat the idempotent cd once in case input arrived before shell readiness.
  [ "$BACKEND" != herdr ] || last_poll=120
  for i in $(seq 0 "$last_poll"); do
    [ "$i" -eq 0 ] || sleep 0.5
    seen=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$seen" ] && [ "$(real_path_or_raw "$seen")" = "$expected" ]; then
      return 0
    fi
    if [ "$BACKEND" = herdr ] && [ "$i" -eq 20 ]; then
      spawn_enter_recorded_worktree
    fi
  done
  echo "error: task $ID's worker started in '${seen:-unknown}', not its recorded worktree '$WT'; refusing to continue outside the copy holding its work" >&2
  if [ "$BACKEND" = herdr ] && fm_backend_herdr_parse_target "$WT_TARGET"; then
    agent_status=$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")
    echo "error: Herdr pane '$WT_TARGET': last foreground_cwd='${seen:-unknown}', agent_status='${agent_status:-unknown}'" >&2
  fi
  exit 1
}

# Acquire or adopt this task's durable copy and prove the pane sits in it.
# The modular spawn reconciliation dropped this phase: the endpoint was created
# in the project directory, WT stayed empty, and the launcher then failed at
# the AI-trailer hook install (or, with hooks off, would have started the agent
# outside the copy holding its work). It runs after the endpoint exists and
# before any launch environment is built, for every ship, scout, and
# secondmate.
spawn_acquire_task_copy() {
  [ "$KIND" = secondmate ] && return 0
  local relaunch_wt_real relaunch_seen relaunch_cd_path
  if [ "$RELAUNCH" -eq 1 ]; then
    # No worktree is acquired: the recorded one is reused as-is. Prove the
    # adopted endpoint's shell is actually sitting in it, and move it back when
    # it is not, rather than launching wherever the pane drifted.
    relaunch_wt_real=$(real_path_or_raw "$WT")
    relaunch_seen=
    for _ in $(seq 1 10); do
      relaunch_seen=$(spawn_current_path "$WT_TARGET" || true)
      [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ] || break
      sleep 0.5
    done
    if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
      relaunch_cd_path=${WT//\'/\'\\\'\'}
      spawn_send_text_line "$WT_TARGET" "cd -- '$relaunch_cd_path'" || {
        echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}' and could not be told to return to its recorded worktree '$WT'; refusing to relaunch an agent outside the copy holding its work" >&2
        exit 1
      }
      for _ in $(seq 1 10); do
        relaunch_seen=$(spawn_current_path "$WT_TARGET" || true)
        [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ] || break
        sleep 0.5
      done
    fi
    if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}' and did not return to its recorded worktree '$WT' when told to; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    fi
    validate_spawn_worktree "relaunch" "$T"
  else
    case "$BACKEND" in
    herdr) spawn_lease_herdr_slot ;;
    *) return 0 ;;
    esac
    # Claim the pool slot for this task, so a slot handed on after this worker
    # exits is provably not this task's. Written under the Treehouse project
    # lock the admission phase holds from before slot allocation through record
    # publication.
    if fm_treehouse_pool_slot "$PROJ_ABS" "$WT"; then
      if ! fm_treehouse_slot_owner_claim "$WT" "$ID" "$FM_HOME"; then
        echo "error: could not claim Treehouse pool slot $WT for task $ID; refusing to launch a worker whose slot cannot later be proved to be its own; $(spawn_endpoint_hint)" >&2
        exit 1
      fi
      SPAWN_SLOT_CLAIMED=1
    fi
    freshen_spawn_worktree_base "$WT" "$BASE_BRANCH" "$PROJ_ABS" "$MODE" || exit 1
  fi
  # Re-assert the durable copy after either acquisition or endpoint adoption.
  # This also moves Herdr's restored pane shell before any harness starts, so a
  # later host restart inherits the task worktree rather than the tab's
  # original project directory.
  spawn_enter_recorded_worktree
  spawn_assert_agent_worktree
}


# Trust decisions read the visible pane only. The dialog is a TUI frame, so a
# scrollback-backed capture keeps reporting it long after Kimi redrew past it -
# which would storm Enter into a live composer and then fail an already trusted
# spawn for a dialog that did clear. There is deliberately no fallback to the
# bounded capture: the spawn refuses at preflight on a backend that cannot read
# the viewport, a read that fails outright fails readiness with its exit status
# and the backend's own error on stderr, and only a successful empty read is
# absence of evidence, which the poll loop treats as a skipped poll.

# Kimi launch-readiness and delivery route their composer-emptiness half
# through the shared classifier (bin/fm-composer-lib.sh via
# fm_backend_composer_state), the same owner every steer and injection guard
# reads. This retired a fourth, spawn-local copy of composer shape knowledge -
# a hardcoded bordered `│ > │` regex that would have silently broken kimi
# spawn readiness fleet-wide the day kimi's TUI goes borderless the way
# claude's did. The banner and brief-echo greps below are launch-progress
# signals, not composer shapes, so they stay here.

# A successful key send is not evidence that Kimi accepted trust. Only the
# ordinary readiness signals in a later capture prove advancement.





# rovo mirrors kimi's launch-then-send shape exactly: a positional brief is
# dead-on-arrival, so rovo launches bare and takes its brief pointer only after a
# readiness gate, then a delivery-confirmation gate. Both route their
# composer-emptiness half through the shared classifier (fm_backend_composer_state)
# like kimi. The banner and context-usage greps are launch-progress signals, not
# composer shapes.






# The launch-then-confirm gates run after the task record is published, when
# ORCA_ABORT_CLEANUP is already cleared and neither the abort trap nor a
# teardown owns this endpoint yet, so a gate failure must close the launched
# process here or it keeps running as an orphaned autonomous agent outside
# task control. Mirrors fm-teardown.sh's own generic kill call. On orca only
# the exact terminal is closed: that stops the CLI while its worktree stays
# for the record's own teardown, which owns worktree deletion.

# OpenCode 2 takes its brief on the launch command (--prompt), but some 2.x
# releases (2.0.11) only prefill the composer and never submit it, while later
# ones (2.0.22) submit it on their own. This post-launch gate makes both work:
# the turn has started once the worker's own busy-state plugin has written a
# record (source opencode-plugin; the arm-time record is source fm-spawn), so
# the gate waits for that. If none arrives within the settle window it sends
# one Enter once the shared composer classifier reads the brief as pending -
# skipped when it proves the composer empty, since the brief has then already
# left it - and keeps waiting. An unknown read (a TUI that has not drawn yet)
# keeps polling and only spends the Enter at the later submit deadline, so a
# backend whose classifier can only answer unknown still gets its one Enter.
# The composer is only a veto, never proof of delivery: OpenCode 2's sidebar
# can make an already-submitted composer read pending.










# Rewrite <meta> into <out> without the <owned keys>, placing <line>... ahead
# of the first pr= line so the PR region stays the record's tail that
# fm_pr_metadata_identity_parse requires. Preserved PR metadata must remain
# the record tail or the armed merge poll stops validating relaunched lanes.
spawn_meta_rewrite_before_pr() {  # <meta> <out> <owned keys> <line>...
  local meta=$1 out=$2 keys=$3
  shift 3
  FM_SPAWN_META_LINES=$(printf '%s\n' "$@") awk -F= -v keys="$keys" '
    BEGIN {
      n = split(keys, k, " ")
      for (i = 1; i <= n; i++) owned[k[i]] = 1
      lines = ENVIRON["FM_SPAWN_META_LINES"]
    }
    $1 in owned { next }
    !placed && $1 == "pr" { print lines; placed = 1 }
    { print }
    END { if (!placed) print lines }
  ' "$meta" >"$out"
}

# Bind the discovered session into task metadata (the control verbs' durable
# address), in the same locked-filter-and-publish shape spawn_record_traceparent
# uses: an idempotent rewrite that drops any prior polytoken_* binding before
# writing the fresh one ahead of any PR region.


