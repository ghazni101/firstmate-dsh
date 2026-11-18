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

kimi_capture() {
  fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true
}

# Trust decisions read the visible pane only. The dialog is a TUI frame, so a
# scrollback-backed capture keeps reporting it long after Kimi redrew past it -
# which would storm Enter into a live composer and then fail an already trusted
# spawn for a dialog that did clear. There is deliberately no fallback to the
# bounded capture: the spawn refuses at preflight on a backend that cannot read
# the viewport, a read that fails outright fails readiness with its exit status
# and the backend's own error on stderr, and only a successful empty read is
# absence of evidence, which the poll loop treats as a skipped poll.
kimi_visible_capture() {
  fm_backend_visible_capture "$BACKEND" "$T" "$W"
}

# Kimi launch-readiness and delivery route their composer-emptiness half
# through the shared classifier (bin/fm-composer-lib.sh via
# fm_backend_composer_state), the same owner every steer and injection guard
# reads. This retired a fourth, spawn-local copy of composer shape knowledge -
# a hardcoded bordered `│ > │` regex that would have silently broken kimi
# spawn readiness fleet-wide the day kimi's TUI goes borderless the way
# claude's did. The banner and brief-echo greps below are launch-progress
# signals, not composer shapes, so they stay here.
kimi_composer_is_empty() {
  [ "$(fm_backend_composer_state "$BACKEND" "$T" "$W" 2>/dev/null)" = empty ]
}

# A successful key send is not evidence that Kimi accepted trust. Only the
# ordinary readiness signals in a later capture prove advancement.
kimi_ready_signal_is_present() { # <plain-pane-capture>
  case "$1" in *'Welcome to Kimi Code!'*) return 0 ;; esac
  kimi_composer_is_empty
}

kimi_wait_for_ready() {
  local pane capture_rc i=0 max=${FM_KIMI_READY_POLLS:-60} interval=${FM_KIMI_POLL_INTERVAL:-0.5}
  local trust_enters=0 trust_seen=0 trust_still_visible=0 trust_markers_pending=0
  local trust_affirmative='' trust_negative='' ready_captures=0
  KIMI_READY_FAILURE_DETAIL='kimi did not show a verified ready signal before brief delivery'
  while [ "$i" -lt "$max" ]; do
    capture_rc=0
    pane=$(kimi_visible_capture) || capture_rc=$?
    if [ "$capture_rc" -ne 0 ]; then
      KIMI_READY_FAILURE_DETAIL="kimi readiness could not read the visible viewport of backend '$BACKEND' (viewport capture exited $capture_rc), so the trust dialog could neither be answered nor ruled out"
      return 1
    fi
    if [ -z "$pane" ]; then
      ready_captures=0
      i=$((i + 1))
      [ "$i" -ge "$max" ] || sleep "$interval"
      continue
    fi
    # Both refusals come before the complete-dialog test on purpose: the
    # announcing prompt and the paged prompt are complete dialogs, and the
    # only thing that keeps Enter off them is deciding here first.
    if kimi_pane_announces_project_mcp_servers "$pane"; then
      KIMI_READY_FAILURE_DETAIL="kimi's folder prompt announces project MCP servers, so Firstmate did not answer it and did not send the brief; answering would start those servers without a consent decision that covers them. Remove the project MCP servers this directory declares (the prompt's Config line names the file), or wait for a later consent design."
      return 1
    fi
    if kimi_trust_prompt_is_paged "$pane"; then
      KIMI_READY_FAILURE_DETAIL="kimi's folder prompt pages what trusting would activate, so Firstmate could not read all of it and did not answer it; give the worker pane more rows and relaunch."
      return 1
    fi
    if kimi_trust_dialog_is_visible "$pane"; then
      trust_seen=1
      trust_still_visible=1
      trust_markers_pending=0
      ready_captures=0
      trust_affirmative=$KIMI_TRUST_AFFIRMATIVE
      trust_negative=$KIMI_TRUST_NEGATIVE
      # Kimi swallows keypresses during its startup window - the same hazard
      # FM_KIMI_SUBMIT_RETRIES covers for the brief pointer - so the
      # affirmative selection is re-sent on every poll the complete dialog is
      # still on screen. The dialog's own disappearance is the postcondition:
      # once it clears, this branch cannot fire again.
      if ! spawn_send_key "$T" Enter; then
        KIMI_READY_FAILURE_DETAIL="kimi trust dialog was seen but the affirmative selection could not be submitted"
        return 1
      fi
      trust_enters=$((trust_enters + 1))
    else
      trust_still_visible=0
      if kimi_trust_marker_is_present "$pane"; then
        trust_markers_pending=1
        ready_captures=0
      else
        trust_markers_pending=0
        # The banner prints before the dialog paints its first frame, so one
        # ready-looking capture cannot be told apart from a pane whose dialog is
        # one redraw away. Two consecutive captures that are each ready and free
        # of dialog text can; any capture that is not ready restarts the count.
        if kimi_ready_signal_is_present "$pane"; then
          ready_captures=$((ready_captures + 1))
          [ "$ready_captures" -lt 2 ] || return 0
        else
          ready_captures=0
        fi
      fi
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  if [ "$trust_still_visible" -eq 1 ]; then
    KIMI_READY_FAILURE_DETAIL="kimi trust dialog did not clear after selecting '$trust_affirmative' on $trust_enters poll(s); saw 'Trust this folder?', the navigation hint, selected '$trust_affirmative', and the negative $trust_negative option"
  elif [ "$trust_seen" -eq 1 ]; then
    KIMI_READY_FAILURE_DETAIL="kimi trust dialog was answered but the pane never advanced to a verified ready signal; saw 'Trust this folder?', the navigation hint, selected '$trust_affirmative', and the negative $trust_negative option"
  elif [ "$trust_markers_pending" -eq 1 ]; then
    KIMI_READY_FAILURE_DETAIL="kimi did not show a verified ready signal before brief delivery; trust dialog text stayed on screen without the complete dialog, so the pane was never safe to answer or to treat as ready"
  fi
  return 1
}

kimi_delivery_is_confirmed() { # <plain-pane-capture>
  local pane=$1
  kimi_composer_is_empty || return 1
  if { printf '%s\n' "$pane" | grep -Fq '✨' &&
    printf '%s\n' "$pane" | grep -Fq 'Read the brief at'; } ||
    printf '%s\n' "$pane" |
    grep -qiE 'context:[[:space:]]*(0\.[0-9]*[1-9][0-9]*|[1-9][0-9]*([.][0-9]+)?)[[:space:]]*%'; then
    return 0
  fi
  return 1
}

kimi_wait_for_delivery() {
  local pane i=0 max=${FM_KIMI_DELIVERY_POLLS:-40} interval=${FM_KIMI_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    pane=$(kimi_capture)
    kimi_delivery_is_confirmed "$pane" && return 0
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

kimi_spawn_fail() { # <detail>
  printf '%s\n' "$(status_stamp_line "failed: $1")" >>"$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
}

# rovo mirrors kimi's launch-then-send shape exactly: a positional brief is
# dead-on-arrival, so rovo launches bare and takes its brief pointer only after a
# readiness gate, then a delivery-confirmation gate. Both route their
# composer-emptiness half through the shared classifier (fm_backend_composer_state)
# like kimi. The banner and context-usage greps are launch-progress signals, not
# composer shapes.
rovo_capture() {
  fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true
}

rovo_composer_is_empty() {
  [ "$(fm_backend_composer_state "$BACKEND" "$T" "$W" 2>/dev/null)" = empty ]
}

rovo_wait_for_ready() {
  local pane i=0 max=${FM_ROVO_READY_POLLS:-60} interval=${FM_ROVO_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    pane=$(rovo_capture)
    # Lead with rovo's fresh-launch ASCII welcome banner (confirmed live), the
    # same primary evidence kimi's own 'Welcome to Kimi Code!' match uses. The
    # composer-empty fallback is WEAKER for rovo than for kimi: rovo's idle
    # composer renders an inline placeholder chip (luminance ~163, above the
    # ghost-strip threshold) that bin/fm-composer-lib.sh does not currently strip
    # (see the deliberately-unfixed composer-ghost gap in rovo.md), so it can read
    # non-empty - hence the banner is the primary signal.
    if printf '%s\n' "$pane" | grep -Fq 'Welcome to Rovo!' ||
      rovo_composer_is_empty; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

rovo_delivery_is_confirmed() { # <plain-pane-capture>
  local pane=$1
  rovo_composer_is_empty || return 1
  # rovo's real footer is `Context: <bar> N.N% NN.NK/NNNK` (e.g.
  # "Context: ▎ 3.3% 30.1K/922K"). Confirm delivery when the sent pointer has
  # scrolled into view OR the context-usage PERCENTAGE has advanced off zero. The
  # regex tolerates the bar glyph and arbitrary spacing between the colon and the
  # number (the [^%]* runs, unlike kimi's exact spacing) but is anchored to the
  # digits BEFORE the % sign, so the always-nonzero total in the denominator
  # (e.g. .../922K) can never masquerade as a nonzero usage percentage.
  if printf '%s\n' "$pane" | grep -Fq 'Read the brief at' ||
    printf '%s\n' "$pane" | grep -qiE 'context:[^%]*[1-9][^%]*%'; then
    return 0
  fi
  return 1
}

rovo_wait_for_delivery() {
  local pane i=0 max=${FM_ROVO_DELIVERY_POLLS:-40} interval=${FM_ROVO_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    pane=$(rovo_capture)
    rovo_delivery_is_confirmed "$pane" && return 0
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

rovo_spawn_fail() { # <detail>
  printf '%s\n' "$(status_stamp_line "failed: $1")" >>"$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
  rovo_endpoint_cleanup
}

# The launch-then-confirm gates run after the task record is published, when
# ORCA_ABORT_CLEANUP is already cleared and neither the abort trap nor a
# teardown owns this endpoint yet, so a gate failure must close the launched
# process here or it keeps running as an orphaned autonomous agent outside
# task control. Mirrors fm-teardown.sh's own generic kill call. On orca only
# the exact terminal is closed: that stops the CLI while its worktree stays
# for the record's own teardown, which owns worktree deletion.
rovo_endpoint_cleanup() {
  if [ "$BACKEND" = orca ]; then
    fm_backend_kill orca "$T" 2>/dev/null && SPAWN_ENDPOINT_CLOSED=1 || true
    return 0
  fi
  local tab_id=
  [ "$BACKEND" = zellij ] && tab_id=$ZELLIJ_TAB_ID
  fm_backend_kill "$BACKEND" "$T" "$tab_id" "fm-$ID" 2>/dev/null && SPAWN_ENDPOINT_CLOSED=1 || true
}

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
opencode2_turn_started() {
  local rec
  rec=$(fm_busy_record_read "$STATE_REAL" "$ID" 2>/dev/null) || return 1
  set -f
  # shellcheck disable=SC2086 # the record is four space-separated tokens
  set -- $rec
  set +f
  [ "${2:-}" = opencode-plugin ]
}

opencode2_wait_for_delivery() {
  local i=0 max=${FM_OPENCODE_DELIVERY_POLLS:-120} interval=${FM_OPENCODE_POLL_INTERVAL:-0.5}
  local settle=${FM_OPENCODE_SUBMIT_SETTLE_POLLS:-20} deadline=${FM_OPENCODE_SUBMIT_DEADLINE_POLLS:-80}
  local sent=0 composer
  while [ "$i" -lt "$max" ]; do
    opencode2_turn_started && return 0
    if [ "$sent" -eq 0 ] && [ "$i" -ge "$settle" ]; then
      composer=$(fm_backend_composer_state "$BACKEND" "$T" "$W" 2>/dev/null)
      if [ "$composer" != unknown ] || [ "$i" -ge "$deadline" ]; then
        sent=1
        if [ "$composer" != empty ]; then
          spawn_send_key "$T" Enter || return 1
        fi
      fi
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  opencode2_turn_started
}

spawn_agy_launch_delivery() {

# agy carries its brief on the launch command, so it needs no delivery gate,
# but a worktree agy does not trust parks the TUI on the folder-trust dialog
# and an unanswered dialog sends the turn into agy's scratch directory instead
# of the worktree. The trust is pre-registered before launch
# (bin/fm-agy-trust.sh, verified to remove the dialog), and this gate is the
# backstop in the rovo/kimi launch-then-confirm shape: answer the dialog once
# with the preselected safe default if it renders anyway, then require
# positive proof that the brief is being processed - the same verdict the
# supervisor reads (Herdr's native working state or the pinned `esc to cancel`
# status row through fm_busy_classify) - before the spawn reports success.
# The gate is strict about ordering because on Herdr the native working
# verdict is known to coexist with an unanswered dialog: a busy verdict counts
# only when the path was pre-registered or the dialog has been seen and
# answered; on an unregistered path it keeps polling for the dialog instead.
AGY_TRUST_DIALOG='Do you trust the contents of this project?'
AGY_TRUST_ANSWERED=0

}

agy_capture() {
  fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true
}

agy_pane_shows_trust_dialog() {  # <plain-pane-capture>
  printf '%s\n' "$1" | grep -Fq "$AGY_TRUST_DIALOG"
}

agy_pane_is_working() {  # <plain-pane-capture>
  case "$(fm_busy_classify "$BACKEND" "$T" agy "$ID" "$STATE" "$1")" in
    busy*) return 0 ;;
  esac
  return 1
}

agy_wait_for_working() {
  local pane i=0 max=${FM_AGY_READY_POLLS:-60} interval=${FM_AGY_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    pane=$(agy_capture)
    if agy_pane_shows_trust_dialog "$pane"; then
      if [ "$AGY_TRUST_ANSWERED" -eq 0 ]; then
        spawn_send_key "$T" Enter
        AGY_TRUST_ANSWERED=1
      fi
    elif [ "$AGY_TRUST_PREREGISTERED" -eq 1 ] || [ "$AGY_TRUST_ANSWERED" -eq 1 ]; then
      agy_pane_is_working "$pane" && return 0
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

agy_spawn_fail() {  # <detail>
  printf '%s\n' "$(status_stamp_line "failed: $1")" >>"$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
  rovo_endpoint_cleanup
}

spawn_polytoken_launch_delivery() {

# polytoken's launch-then-confirm gate, in the same shape as agy's: the brief
# rides the launch command (--prompt submits it after the TUI attaches), so
# readiness is positive proof the brief is being processed rather than proof a
# key was typed. The proof is semantic, not a screen scrape: the busy record
# must advance past the fm-spawn seed to a polytoken-hook event (pre_user_prompt
# fires the moment the brief turn is submitted, verified live), which is exactly
# the verdict the supervisor reads. A pane parked on a first-start dialog the
# launch cannot get past - the license dialog, which the captain's decision
# (2026-10-07) makes a blocker that fleet spawns never auto-accept - never posts
# the first hook event, so the gate fails loudly there. Session discovery is
# folded into the same poll: `polytoken sessions --format json` scoped to this
# task's config and sessions roots binds the pane's session id, port, and
# credential file (a TUI-attached launch never prints them on the spawning
# side, verified live).
POLYTOKEN_SESSION_ID=
POLYTOKEN_SESSION_PORT=
POLYTOKEN_SESSION_CREDENTIAL=

}

polytoken_wait_for_ready() {
  local discovered record i=0 max=${FM_POLYTOKEN_READY_POLLS:-120} interval=${FM_POLYTOKEN_POLL_INTERVAL:-0.5}
  while [ "$i" -lt "$max" ]; do
    if [ -z "$POLYTOKEN_SESSION_ID" ]; then
      discovered=$(fm_polytoken_session_for_project "$POLYTOKEN_BIN" \
        "$(fm_polytoken_config_dir "$STATE_REAL" "$ID")" \
        "$(fm_polytoken_sessions_root "$STATE_REAL" "$ID")" \
        "$WT") || discovered=
      if [ -n "$discovered" ]; then
        # The listing row carries a fourth field (the daemon pid); a trailing
        # throwaway variable consumes it so it is never glued onto the
        # credential path the control verbs address.
        IFS=$'\t' read -r POLYTOKEN_SESSION_ID POLYTOKEN_SESSION_PORT POLYTOKEN_SESSION_CREDENTIAL _ <<EOF
$discovered
EOF
      fi
    fi
    if [ -n "$POLYTOKEN_SESSION_ID" ]; then
      record=$(fm_busy_record_read "$STATE_REAL" "$ID" 2>/dev/null) || record=
      case "$record" in
        *" polytoken-hook "*) return 0 ;;
      esac
    fi
    i=$((i + 1))
    [ "$i" -ge "$max" ] || sleep "$interval"
  done
  return 1
}

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
spawn_record_polytoken_session() {
  local meta="$STATE/$ID.meta" status=0 acquired=0
  if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
    SPAWN_META_LOCK=$(fm_meta_lock_path "$meta") || return 1
    fm_lock_acquire_wait "$SPAWN_META_LOCK"
    SPAWN_META_LOCK_HELD=1
    acquired=1
  fi
  SPAWN_META_TMP="$STATE/.$ID.meta.polytoken.${BASHPID:-$$}"
  if [ ! -f "$meta" ] || [ ! -w "$meta" ] ||
    ! spawn_meta_rewrite_before_pr "$meta" "$SPAWN_META_TMP" "polytoken_session polytoken_port polytoken_credential" \
      "polytoken_session=$POLYTOKEN_SESSION_ID" "polytoken_port=$POLYTOKEN_SESSION_PORT" \
      "polytoken_credential=$POLYTOKEN_SESSION_CREDENTIAL" ||
    ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$meta" "task record" "$STATE"; then
    status=1
    rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  fi
  SPAWN_META_TMP=
  if [ "$acquired" = 1 ]; then
    fm_lock_release "$SPAWN_META_LOCK" || status=1
    SPAWN_META_LOCK_HELD=0
  fi
  return "$status"
}

polytoken_spawn_fail() {  # <detail>
  printf '%s\n' "$(status_stamp_line "failed: $1")" >>"$STATE/$ID.status"
  echo "error: $1; inspect window $T" >&2
  # A failed gate leaves nothing running or recorded: reap this launch's exact
  # session daemon (scoped to this task's sessions root), retire the per-task
  # wiring (the sessions roots, config dir, worktree hook layer, facet, and
  # busy writer), then close the endpoint exactly like the agy gate.
  if [ -n "$POLYTOKEN_SESSION_ID" ]; then
    "$POLYTOKEN_BIN" --config-dir "$(fm_polytoken_config_dir "$STATE_REAL" "$ID")" \
      reap "$POLYTOKEN_SESSION_ID" --force \
      --sessions-dir "$(fm_polytoken_sessions_root "$STATE_REAL" "$ID")" >/dev/null 2>&1 || true
  fi
  clear_relaunch_harness_wiring polytoken "$WT" "$STATE_REAL" "$ID" || true
  rovo_endpoint_cleanup
}

spawn_orca_relaunch_projection() {

if [ "$RELAUNCH" -eq 1 ] && [ "$BACKEND" = orca ]; then
  [ "$KIND" = secondmate ] || validate_spawn_worktree "relaunch" "$T"
elif [ "$RELAUNCH" -eq 1 ]; then
  # No worktree is acquired: the recorded one is reused as-is. What must be
  # proven instead is that the adopted endpoint's shell is actually sitting in
  # that worktree, so the replacement agent starts where the work is rather
  # than wherever the pane happened to drift.
  relaunch_wt_real=$(real_path_or_raw "$WT")
  relaunch_seen=
  for _ in $(seq 1 10); do
    relaunch_seen=$(spawn_current_path "$WT_TARGET" || true)
    [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ] || break
    sleep 0.5
  done
  if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
    if [ "$BACKEND" != herdr ] && [ "$BACKEND" != rex ]; then
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}', not its recorded worktree '$WT'; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    fi
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
    if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}' and did not return to its recorded worktree '$WT' when told to; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    fi
  fi
  [ "$KIND" = secondmate ] || validate_spawn_worktree "relaunch" "$T"
elif [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
  # A t3code slot was leased and validated in its target branch above.
  if [ "$BACKEND" = t3code ]; then
    :
  elif [ "$BACKEND" = herdr ]; then
    spawn_lease_herdr_slot
  else
    spawn_send_text_line "$WT_TARGET" 'treehouse get'

    # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
    # Target the stable window id, not the name: if the name is ever lost (e.g. an
    # automatic-rename slips through), display-message -t <bad-name> falls back to the
    # active client's window, which would misread firstmate's OWN pane path as the
    # worktree and tangle a hook into the primary checkout. The window id never lies.
    # The project comparison is physical: spawn_worktree_isolated screens each
    # read against PROJ_ABS_REAL, not PROJ_ABS, because a symlinked project prefix
    # would otherwise make the pane's OS-level cwd read differ from PROJ_ABS on
    # the very first poll, before the pane has actually moved.
    #
    # A single read that already looks isolated is not proof the pane settled
    # there: on some tmux/WSL setups a brand-new window's pane_current_path
    # transiently reports an unrelated stale path (seen live as another real git
    # checkout entirely) before the shell catches up with treehouse get's cd. That
    # stale path passes spawn_worktree_isolated too (it resolves to a real,
    # distinct worktree top-level), so accepting it on one read alone silently
    # records the wrong worktree= in state/<id>.meta. Require two consecutive
    # reads to agree on the same isolated path before accepting it; a mismatch
    # just becomes the new candidate rather than resetting the wait, so a pane
    # that is already settled by the first real read only costs the one existing
    # inter-poll sleep as confirmation, not a whole extra cycle on top.
    #
    # Every candidate is screened with the isolation guard's own predicate, so a
    # read of the project itself or of the repository primary checkout is treated
    # as the transient it is and the wait continues, instead of being adopted and
    # then refused by the guard.
    # A candidate the screen rejects is never adopted, so a host where the pane
    # never reaches an isolated worktree spends the whole window before refusing.
    # That wait is deliberate - telling a transient apart from a terminal
    # misconfiguration would need machinery this path does not want - so the
    # refusal has to be self-explaining instead: carry the last path seen and the
    # reason it was rejected, and report both at the deadline.
    candidate=""
    last_seen=""
    last_reason="the pane reported no path"
    for _ in $(seq 1 60); do
      p=$(spawn_current_path "$WT_TARGET" || true)
      [ -z "$p" ] || last_seen="$p"
      if [ -n "$p" ] && spawn_worktree_isolated "$p"; then
        p_real=$(real_path_or_raw "$p")
        last_reason="it is an isolated worktree, but no second read agreed with it"
        if [ -n "$candidate" ] && [ "$p_real" = "$candidate" ]; then
          WT="$p"
          break
        fi
        candidate="$p_real"
      else
        candidate=""
        [ -z "$p" ] || last_reason=$SPAWN_WT_REASON
      fi
      sleep 1
    done
    if [ -z "$WT" ]; then
      echo "error: treehouse get did not enter an isolated worktree within 60s (last seen '${last_seen:-none}': $last_reason; spawning project '$PROJ_ABS'); $(spawn_endpoint_hint)" >&2
      exit 1
    fi

    if spawn_endpoint_closes_on_abort; then
      validate_spawn_worktree "treehouse get" "$WT ($(spawn_endpoint_hint))"
    else
      validate_spawn_worktree "treehouse get" "$T"
    fi
  fi

  # Claim the pool slot for this task. Except on Herdr, whose slot
  # spawn_lease_herdr_slot leased durably, the interactive `treehouse get` sent
  # to the pane above records only a process lease, so Treehouse cannot say
  # which task a slot belongs to once that task's worker exits - and that is
  # exactly when the slot is handed on and this task's worktree= line goes
  # stale. The claim is what lets
  # bin/fm-teardown.sh leave a slot that has since been reassigned untouched, so
  # a slot that cannot be claimed is refused here, at the cheapest point, rather
  # than launching a worker whose slot teardown could later release out from
  # under its successor.
  # Written under the Treehouse project lock held from before slot allocation
  # through metadata publication, so no other spawn or return sees a half-claim.
  if fm_treehouse_pool_slot "$PROJ_ABS" "$WT"; then
    if ! fm_treehouse_slot_owner_claim "$WT" "$ID" "$FM_HOME"; then
      echo "error: could not claim Treehouse pool slot $WT for task $ID; refusing to launch a worker whose slot cannot later be proved to be its own; $(spawn_endpoint_hint)" >&2
      exit 1
    fi
    SPAWN_SLOT_CLAIMED=1
  fi
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" != secondmate ] && [ "$BACKEND" != t3code ]; then
  freshen_spawn_worktree_base "$WT" "$BASE_BRANCH" "$PROJ_ABS" "$MODE" || exit 1
fi

# Re-assert the durable task copy after either treehouse acquisition or endpoint
# adoption. This also updates Herdr's restored pane shell before any harness is
# started, so a later host restart inherits the task worktree rather than the
# tab's original project directory.
spawn_enter_recorded_worktree
spawn_assert_agent_worktree

# Pre-register Claude's workspace trust for the directory this launch starts in,
# at the first point that directory is known and before any per-task state is
# created below. The dialog gates the pane before the brief is ever read, and it
# also gates loading the project settings written further down, so nothing armed
# below takes effect without it. EVERY claude launch needs it, a secondmate's
# included: its home is just as unseen by Claude as a fresh worktree, and
# skipping the step for that kind left a standalone-clone secondmate home with
# nothing registered and a pane wedged on a dialog firstmate cannot answer.
# bin/fm-claude-trust.sh owns the structural scope test for both shapes and
# refuses anything that is neither this project's own isolated worktree nor a
# seeded secondmate home marked for this id; a refusal blocks the spawn rather
# than launching a worker that would wedge. Refusing here rather than beside the
# arm keeps this in the same class as the two worktree refusals just above: no
# temp root, no retired relaunch wiring and no busy record exists yet to strand,
# so the refusal names the endpoint the same way they do and leaves nothing else
# behind.
# agy gates a fresh worktree or secondmate home behind its own folder-trust
# dialog and honours a trustedWorkspaces entry written ahead of launch
# (bin/fm-agy-trust.sh), so the same pre-registration removes the dialog for it.
# Unlike claude's dialog, agy's preselects the safe answer, so a failed
# registration is not fatal here: the post-launch gate (agy_wait_for_working)
# answers the dialog itself and, on a path that was not pre-registered, refuses
# to count a busy turn as ready until it has done so.
AGY_TRUST_PREREGISTERED=0
case "$HARNESS" in
claude*)
  if [ "$KIND" = secondmate ]; then
    spawn_trust_args=(--secondmate-home "$PROJ_ABS" "$ID")
  else
    spawn_trust_args=("$WT" "$PROJ_ABS")
  fi
  if ! "$FM_ROOT/bin/fm-claude-trust.sh" "${spawn_trust_args[@]}" >/dev/null; then
    echo "error: could not pre-register Claude workspace trust for $WT; refusing to launch a claude worker that would wedge on the trust dialog; $(spawn_endpoint_hint)" >&2
    exit 1
  fi
  ;;
agy)
  if [ "$KIND" = secondmate ]; then
    spawn_trust_args=(--secondmate-home "$PROJ_ABS" "$ID")
  else
    spawn_trust_args=("$WT" "$PROJ_ABS")
  fi
  if "$FM_ROOT/bin/fm-agy-trust.sh" "${spawn_trust_args[@]}" >/dev/null; then
    AGY_TRUST_PREREGISTERED=1
  else
    echo "warning: could not pre-register agy workspace trust for $WT; the launch will answer the folder-trust dialog in window $T instead" >&2
  fi
  ;;
esac

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
# The root is private (0700) because its path is predictable under a shared
# /tmp: a root that already exists is reused only as a real directory owned by
# this user and writable by nobody else, then tightened, so no other local user
# can plant or swap a file in it. The staged launch command lives in a sibling
# directory namespaced by home identity, not in this shared per-id root.
TASK_TMP="/tmp/fm-$ID"
if (umask 077 && mkdir "$TASK_TMP") 2>/dev/null; then
  [ "$HARNESS" != polytoken ] || SPAWN_TASK_TMP_CREATED=1
else
  if [ -L "$TASK_TMP" ] || [ ! -d "$TASK_TMP" ] || [ ! -O "$TASK_TMP" ] ||
    [ -n "$(find "$TASK_TMP" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] ||
    ! chmod 700 "$TASK_TMP"; then
    echo "error: task temp root $TASK_TMP already exists and is not a private directory owned by this user; refusing to stage the launch command there; inspect and remove it, then retry" >&2
    exit 1
  fi
fi
mkdir -p "$TASK_TMP/gotmp"

# Per-harness turn-end hook where enabled: a file that touches
# state/<id>.turn-ended when the agent finishes a turn. Worktree-resident hooks
# and token pointers stay out of git's view so they never block teardown's dirty
# check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
}
