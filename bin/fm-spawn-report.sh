# shellcheck shell=bash
# spawn report, backlog transition, and launch records.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

# Fuse the backlog In-flight transition into the publication that just created
# the record (bin/fm-backlog-transition-lib.sh owns the invariant). It runs under
# this task's own meta lock, so a steer or teardown racing the same id stays
# serialized exactly as before. The call itself is deferred to the final commit
# point below so every earlier launch-delivery failure remains unwindable.
spawn_commit_backlog_transition() {
  [ "$BACKLOG_TRANSITION" = 1 ] || return 0
  fm_backlog_atomic_transition dispatch "$STATE/$ID.meta" "$DATA" "$ID" "$STATE"
}

# The deferred-signal exit path's preservation report. A claim about preserved
# state is only trustworthy if that state is read back after the commit: the
# commit's own exit status has been observed to agree with a row that did not
# actually move (fm-yi4j evidence, 2026-09-05). This re-reads the paired record
# and the backlog row under the same per-task lock as the commit, repairs a row
# the commit believed it moved, and sets SPAWN_PRESERVED_CLAIM to exactly what
# was verified or attempted - never intent phrased as outcome.
spawn_report_preserved_state() {
  local repair_error=
  if ! fm_backlog_record_present "$STATE/$ID.meta" "task record" "$STATE"; then
    SPAWN_PRESERVED_CLAIM="preservation could not be verified: its paired task record is missing; close out its backlog item by hand"
    return 1
  fi
  if ! fm_backlog_row_probe "$DATA" "$ID"; then
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item was not found; close out its paired task record by hand"
    else
      SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item state is unreadable (${FM_BACKLOG_ROW_ERROR:-no error recorded}); close out its paired task record and backlog item by hand"
    fi
    return 1
  fi
  if [ "$FM_BACKLOG_ROW_STATE" = "in_flight no no" ]; then
    SPAWN_PRESERVED_CLAIM="verified preserved: its paired task record is present and its backlog item is In flight"
    return 0
  fi
  # The commit reported success, but the row does not read back In flight:
  # move it now under the same lock and verify the result before naming it.
  fm_backlog_start "$DATA" "$ID" || repair_error=$FM_BACKLOG_TRANSITION_ERROR
  if [ -z "$repair_error" ] &&
    fm_backlog_row_probe "$DATA" "$ID" &&
    [ "$FM_BACKLOG_ROW_STATE" = "in_flight no no" ]; then
    SPAWN_PRESERVED_CLAIM="its backlog item did not read back In flight after the commit; it was moved to In flight now and verified, together with its paired task record"
    return 0
  fi
  SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item reads ${FM_BACKLOG_ROW_STATE:-unreadable}${repair_error:+, and moving it to In flight failed ($repair_error)}; close out its paired task record and backlog item by hand"
  return 1
}

spawn_finalize_record() {

if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_PUBLISH_STARTED=1
  if ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE"; then
    echo "error: replacement task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  RELAUNCH_REPLACEMENT_PENDING=0
  SPAWN_META_PUBLISH_STARTED=0
  SPAWN_META_TMP=
fi
# A dispatch or relaunch keeps the per-task meta lock through launch delivery.
# The backlog mutation is deliberately the final fallible commit below, so
# teardown cannot remove a relaunched record while its replacement worker is
# still being delivered, cannot observe or complete a fresh provisional record
# between its state check and `tasks-axi start`, and a delivery failure cannot
# follow a committed In-flight transition.
if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
  SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
  fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK"
fi
if [ "$SPAWN_LANE_ADMISSION_LOCK_HELD" = 1 ]; then
  SPAWN_LANE_ADMISSION_LOCK_HELD=0
  fm_lock_release "$SPAWN_LANE_ADMISSION_LOCK" || true
fi
if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
  # The record is published, so this task is now part of the set a teardown
  # enumerates and locks per task. The set lock is only needed across that
  # publication.
  SPAWN_TASK_SET_LOCK_HELD=0
  fm_lock_release "$SPAWN_TASK_SET_LOCK"
fi
"$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
sq_ompext=$(shell_quote "$STATE/$ID.omp-ext.ts")
sq_ompcfg=$(shell_quote "${OMP_WORKER_CFG:-$FM_ROOT/.omp/fm-worker-overlay.yml}")
sq_opinput=$(shell_quote "$FM_ROOT/bin/fm-operational-input.sh")
sq_worktree=$(shell_quote "$WT")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL" "$OPENCODE_MAJOR")
# A pinned Pi launch confines Pi's model lookup to the declared provider.
[ -z "$WORKER_ACCOUNT_PROVIDER" ] || MODELFLAG="--provider $(shell_quote "$WORKER_ACCOUNT_PROVIDER") $MODELFLAG"
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT" "$MODEL" "$OPENCODE_MAJOR") || exit 1
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
# Relaunch session continuity. Computed here, where the adopted endpoint (T) is
# known, and substituted only into the Pi-family template's `__PIRESUME__`
# placeholder; an empty value leaves every other launch byte-identical.
RESUME_ARGS=
if [ "$RELAUNCH" -eq 1 ]; then
  RESUME_ARGS=$(relaunch_resume_args "$HARNESS" "$BACKEND" "$T") || RESUME_ARGS=
fi
LAUNCH=${LAUNCH//__PIRESUME__/$RESUME_ARGS}
LAUNCH=${LAUNCH//__CLAUDEPERMFLAG__/$CLAUDE_PERM_FLAG}
CLAUDE_EXCLUDE=
[ -z "$EXCLUDE_TOOLS" ] || [ "$HARNESS" != claude ] || CLAUDE_EXCLUDE="--disallowedTools $(shell_quote "$EXCLUDE_TOOLS") "
LAUNCH=${LAUNCH//__CLAUDEEXCLUDE__/$CLAUDE_EXCLUDE}
case "$LAUNCH" in
*__CLAUDESETTINGS__*)
  if [ "$KIND" = secondmate ]; then
    LAUNCH=${LAUNCH//__CLAUDESETTINGS__/$(shell_quote "$STATE_REAL/$ID.claude-settings.json")}
  else
    claude_settings="'{\"feedbackDrafts\":\"off\"__CLAUDEATTRIBUTION__}'"
    LAUNCH=${LAUNCH//__CLAUDESETTINGS__/$claude_settings}
  fi
  ;;
esac
LAUNCH=${LAUNCH//__CODEXAPPROVALFLAG__/$CODEX_APPROVAL_FLAG}
if [ "$KEEP_AI_TRAILERS" = 1 ]; then
  LAUNCH=${LAUNCH//__CLAUDEATTRIBUTION__/}
else
  LAUNCH=${LAUNCH//__CLAUDEATTRIBUTION__/,'"attribution":{"commit":"","pr":"","sessionUrl":false}'}
fi
if [ "$HARNESS" = rovo ]; then
  ROVOCONFIGOVERRIDE=$(rovo_config_override_flag "$EFFORT" "$DATA" "$STATE" "$ID") || {
    echo "error: could not resolve this task's home paths for rovo's allowedExternalPaths grant" >&2
    exit 1
  }
  LAUNCH=${LAUNCH//__ROVOCONFIGOVERRIDE__/$ROVOCONFIGOVERRIDE}
fi
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
LAUNCH=${LAUNCH//__OMPEXT__/$sq_ompext}
LAUNCH=${LAUNCH//__OMPWORKERCFG__/$sq_ompcfg}
LAUNCH=${LAUNCH//__OPINPUT__/$sq_opinput}
case "$HARNESS" in
pi | pi-signed) LAUNCH=${LAUNCH//__PIBIN__/"$(shell_quote "$PI_BIN")"} ;;
cursor) LAUNCH=${LAUNCH//__CURSORBIN__/"$(shell_quote "$CURSOR_BIN")"} ;;
gemini) LAUNCH=${LAUNCH//__GEMINISETTINGS__/"$(shell_quote "$STATE_REAL/$ID.gemini-settings.json")"} ;;
omp)
  LAUNCH=${LAUNCH//__OMPBIN__/"$(shell_quote "$OMP_BIN")"}
  OMPPROFILE=
  [ -z "$OMP_PROFILE_PIN" ] || OMPPROFILE=" --profile $(shell_quote "$OMP_PROFILE_PIN")"
  LAUNCH=${LAUNCH//__OMPPROFILE__/$OMPPROFILE}
  ;;
devin)
  LAUNCH=${LAUNCH//__DEVINBIN__/"$(shell_quote "$DEVIN_BIN")"}
  LAUNCH=${LAUNCH//__DEVINCONFIG__/"$(shell_quote "$STATE_REAL/$ID.devin-config.json")"}
  ;;
commandcode)
  LAUNCH=${LAUNCH//__COMMANDCODEBIN__/"$(shell_quote "$COMMANDCODE_BIN")"}
  COMMANDCODEMOD=
  if [ -n "${BUSY_GEN:-}" ]; then
    COMMANDCODEMOD="--mod $(shell_quote "$FM_ROOT/bin/fm-commandcode-mod.ts")"
    COMMANDCODEMOD="$COMMANDCODEMOD --mod-option $(shell_quote "fmWriter=$FM_ROOT/bin/fm-busy-event.sh")"
    COMMANDCODEMOD="$COMMANDCODEMOD --mod-option $(shell_quote "fmState=$STATE_REAL")"
    COMMANDCODEMOD="$COMMANDCODEMOD --mod-option $(shell_quote "fmId=$ID")"
    COMMANDCODEMOD="$COMMANDCODEMOD --mod-option $(shell_quote "fmGen=$BUSY_GEN") "
  fi
  LAUNCH=${LAUNCH//__COMMANDCODEMOD__/$COMMANDCODEMOD}
  ;;
hermes)
  HERMES_PROFILE_FLAG=
  [ -z "$HERMES_PROFILE" ] || HERMES_PROFILE_FLAG="-p $(shell_quote "$HERMES_PROFILE") "
  LAUNCH=${LAUNCH//__HERMESBIN__/"$(shell_quote "$HERMES_BIN")"}
  LAUNCH=${LAUNCH//__HERMESHOME__/"$(shell_quote "$HERMES_PROFILE_HOME")"}
  LAUNCH=${LAUNCH//__HERMESPROFILE__/$HERMES_PROFILE_FLAG}
  LAUNCH=${LAUNCH//__HERMESHOOKS__/"$(shell_quote "$STATE_REAL/$ID.hermes-hooks")"}
  ;;
cortex)
  LAUNCH=${LAUNCH//__CORTEXBIN__/"$(shell_quote "$CORTEX_BIN")"}
  LAUNCH=${LAUNCH//__CORTEXPLUGIN__/"$(shell_quote "$STATE_REAL/$ID.cortex-plugin")"}
  ;;
agy) LAUNCH=${LAUNCH//__AGYBIN__/"$(shell_quote "$AGY_BIN")"} ;;
opencode)
  # The resolved absolute path probed for the version gate above, so the pane
  # runs exactly the binary whose major was recorded. An unresolved executable
  # keeps the bare `opencode` the pane resolves itself (pre-gate fallback).
  # A detected OpenCode 2 also gets --standalone: its default launch attaches to
  # the shared background service, which hosts plugins with the service's own
  # environment and ignores this pane's OPENCODE_CONFIG_CONTENT, so per-worker
  # model, permissions, FM_HOME, and lock ancestry would be wrong.
  if [ -n "$OPENCODE_BIN" ]; then
    oc_launch_bin=$(shell_quote "$OPENCODE_BIN")
  else
    oc_launch_bin=opencode
  fi
  [ "$OPENCODE_MAJOR" -lt 2 ] || oc_launch_bin="$oc_launch_bin --standalone"
  LAUNCH=${LAUNCH//__OPENCODEBIN__/"$oc_launch_bin"}
  ;;
polytoken)
  LAUNCH=${LAUNCH//__POLYTOKENBIN__/"$(shell_quote "$POLYTOKEN_BIN")"}
  LAUNCH=${LAUNCH//__POLYTOKENCONFIG__/"$(shell_quote "$(fm_polytoken_config_dir "$STATE_REAL" "$ID")")"}
  LAUNCH=${LAUNCH//__POLYTOKENSESSIONS__/"$(shell_quote "$(fm_polytoken_sessions_root "$STATE_REAL" "$ID")")"}
  LAUNCH=${LAUNCH//__POLYTOKENFACETS__/"$(shell_quote "$WT/.polytoken/facets")"}
  ;;
kiro)
  LAUNCH=${LAUNCH//__KIROBIN__/"$(shell_quote "$KIRO_BIN")"}
  LAUNCH=${LAUNCH//__KIROHOME__/"$(shell_quote "$STATE_REAL/$ID.kiro-home")"}
  ;;
esac
LAUNCH=${LAUNCH//__WORKTREE__/$sq_worktree}
# A record-backed launch brief is published into the state dir of the pane
# receiving it, which for a secondmate is its own home, not this primary's.
case "$LAUNCH" in
*__BRIEFDOORBELL__*)
  case "$KIND" in
    secondmate) brief_opstate="$PROJ_ABS/state" ;;
    *) brief_opstate=$STATE ;;
  esac
  brief_doorbell=$(FM_STATE_OVERRIDE="$brief_opstate" "$FM_ROOT/bin/fm-operational-input.sh" record launch-brief <"$BRIEF") || {
    echo "error: could not publish the launch brief for $ID as an operational-inbox record under $brief_opstate; $HARNESS strips the typed operational marker, so the worker was not launched" >&2
    exit 1
  }
  LAUNCH=${LAUNCH//__BRIEFDOORBELL__/"$(shell_quote "$brief_doorbell")"}
  ;;
esac
case "$LAUNCH" in
*__CLAUDEADDDIRS__*)
  CLAUDE_ADD_DIRS=$(claude_add_dirs_flag "$KIND" "$STATE" "$DATA" "$FM_ROOT" "$ID") || {
    echo "error: could not resolve the task-channel directories for $ID's claude --add-dir grant" >&2
    exit 1
  }
  LAUNCH=${LAUNCH//__CLAUDEADDDIRS__/$CLAUDE_ADD_DIRS}
  ;;
esac
case "$HARNESS" in
claude | codex | opencode | pi | pi-signed | grok | kimi | gemini | muse | rovo | agy | devin | commandcode | cortex | kiro | hermes)
  LAUNCH="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI $LAUNCH"
  ;;
esac
# Crewmate panes are created by a long-lived tmux/herdr daemon that does not
# inherit firstmate's current environment, so a bare `claude` in the pane falls
# back to the default ~/.claude store even when firstmate itself runs under a
# different CLAUDE_CONFIG_DIR (for example a work-vs-personal subscription split).
# Forward firstmate's own resolved store onto the claude launch so the crewmate
# uses the same credential/config firstmate is authenticated with. Only when set;
# an unset value is the single-store default and needs no prefix.
# A home's worker account pin replaces that forwarding: the launch names the
# pinned root (or unsets the variable for the ordinary Claude account) and
# sheds the environment credentials Claude ranks above the root's login.
if [ -n "$WORKER_ACCOUNT" ]; then
  case "$HARNESS" in
  claude)
    if [ -n "$WORKER_ACCOUNT_ROOT" ]; then
      LAUNCH="$(fm_worker_account_claude_shed) CLAUDE_CONFIG_DIR=$(shell_quote "$WORKER_ACCOUNT_ROOT") $LAUNCH"
    else
      LAUNCH="$(fm_worker_account_claude_shed) -u CLAUDE_CONFIG_DIR $LAUNCH"
    fi
    ;;
  pi | pi-signed)
    LAUNCH="PI_CODING_AGENT_DIR=$(shell_quote "$WORKER_ACCOUNT_ROOT") $LAUNCH"
    ;;
  esac
elif [ "$HARNESS" = claude ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  LAUNCH="CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_CONFIG_DIR") $LAUNCH"
fi
# Like CLAUDE_CONFIG_DIR above, FM_HOME cannot be left to pane inheritance:
# every worker gets its home explicitly, or its bin/*.sh scripts fall back to
# their own code root as the home.
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  sq_primary_home=$(shell_quote "$FM_HOME")
  # Keep this in step with fm_supervision_model (bin/fm-wake-lib.sh): Claude's
  # Stop auto-arm and Cursor's stop-hook park both run the watcher only BETWEEN
  # turns, so a fresh beacon with no live watcher is their healthy mid-turn state.
  # Pi and pi-signed secondmates previously received persistent here and now
  # receive extension to match fm_supervision_model's own table, so their pull
  # guard tolerates the extension hand-off exactly as a Pi primary does.
  case "$HARNESS" in
  claude | cursor | agy) supervision_model=autoarm ;;
  pi | pi-signed | omp) supervision_model=extension ;;
  *) supervision_model=persistent ;;
  esac
  # Deliver the primary's EFFECTIVE trace-context decision as a normalized on/off
  # literal (never the raw FM_TRACE_CONTEXT string) so a FM_TRACE_CONTEXT override
  # on the primary reaches the secondmate's OWN workers, not just the copied
  # config/trace-context file: otherwise off would not disable them and on would
  # not enable them across the launch boundary (bin/fm-trace-context-lib.sh header).
  # Reuse the single frozen decision from the carrier resolution above so the
  # injected carrier and this on/off snapshot are guaranteed to agree.
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$sq_primary_home FM_HOME=$sq_home FM_TRACE_CONTEXT=$SPAWN_TRACE_EFFECTIVE FM_SUPERVISION_MODEL=$supervision_model $LAUNCH"
else
  # A ship or scout works for the active home itself.
  LAUNCH="export FM_HOME=$(shell_quote "$FM_HOME"); $LAUNCH"
fi
}

# Implement the launch-delivery contract in this script's header. The full
# home-identity hash isolates equal task ids across homes, and the spawn token in
# the final filename keeps a buffered source line bound to this incarnation.
spawn_launch_home_token() {
  local home=$1 root hash
  root=$(cd "$home" 2>/dev/null && pwd -P) || root=$home
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in
    *[!0-9a-fA-F]*|'') return 1 ;;
  esac
  printf '%s' "$hash"
}

spawn_launch_home_token_step() {
LAUNCH_HOME_TOKEN=$(spawn_launch_home_token "$FM_HOME") || LAUNCH_HOME_TOKEN=
if [ -z "$LAUNCH_HOME_TOKEN" ]; then
  echo "error: could not derive a home identity for the staged launch file" >&2
  exit 1
fi
case "$SPAWN_GEN" in
  *[!A-Za-z0-9.]*|'') echo "error: spawn incarnation token is not a usable launch-file nonce" >&2; exit 1 ;;
esac
LAUNCH_DIR="/tmp/fm-$ID+$LAUNCH_HOME_TOKEN"
# Pane-scoped override: git in this worker reads our commit-msg strip without
# rewriting the project's core.hooksPath. GIT_CONFIG_* takes precedence over
# config files and is inherited by child git processes. When the home opts in
# to keeping trailers, leave core.hooksPath alone so the repository's hooks run
# directly. An export statement inside the pane command carries the override
# across every step of a compound raw launch while firstmate's own git is unchanged.
# The helper appends after the GIT_CONFIG_COUNT entries the worker actually
# inherits (after any launch environment filtering), so credential.helper and
# other inherited entries survive, and writes a plain export statement into the
# private launch directory. The pane shell, fish included, only parses a simple
# command, &&, || and that export list. A bad inherited count returns from the
# sourced launch file before the worker runs, preserving the interactive pane
# and its visible error for inspection.
if [ "$GIT_HOOKS_INSTALLED" = 1 ]; then
  GIT_CONFIG_ENV_FILE=$(shell_quote "$LAUNCH_DIR/git-config.$SPAWN_GEN.sh")
  LAUNCH="$(shell_quote "$FM_ROOT/bin/fm-git-strip-ai-trailers.sh") env-file $(shell_quote "$GIT_HOOKS_DIR") $GIT_CONFIG_ENV_FILE && . $GIT_CONFIG_ENV_FILE || return 1 2>/dev/null || exit 1; $LAUNCH"
fi
# Every agent this fleet launches - crewmate, scout, and secondmate, on a fresh
# spawn and on a relaunch alike - runs with the compact-adviser kill switch on.
# This is an export statement rather than a forwarded ambient name or a
# command-prefix assignment, so it carries the value across an entire compound
# raw launch expression. A pane that never had it, and a remote host whose
# transport never carried it, both still start the agent with it set. It is
# unconditional, with no config file or flag gating it, and is inserted outside
# every generated launch prefix; relaunch trace cleanup may execute first but
# cannot change this value. The cleared-environment floor in the
# LAUNCH_ENV_PREFIX construction below sets it again at the `env -i` boundary,
# so under an enabled allowlist the switch is established before the wrapping
# `/bin/sh` starts rather than only inside the command that shell runs.
# Arm the worker-side OSC 7501 status reporter (bin/fm-osc7501.sh) inside the
# launch before the agent command, so the reporter's parent is the pane shell
# that runs the agent. The reporter header owns eligibility and native-version
# gates; pass the executable the launch runs so the native probe reads its
# version. A raw launch command establishes it only as a simple command whose
# first word is a plain path to a harness with a launch template; a wrapper,
# assignment prefix, quoted or expanded path, compound command, or unknown
# adapter hides what actually runs, so it passes none and gets no reporter.
# Its stderr stays on the pane so a config warning reaches the user. The `disarm` after the agent
# command retires the reporter when the agent exits, because the pane shell
# that sourced the launch outlives it. Newlines, not `;`, delimit the agent
# command, so a raw launch ending in a separator or a comment stays intact.
OSC7501_AGENT_BIN=
if [ "$RAW_LAUNCH" = 0 ]; then
  case "$HARNESS" in
    pi | pi-signed) OSC7501_AGENT_BIN=${PI_BIN:-} ;;
    muse) OSC7501_AGENT_BIN=${MUSE_BIN:-} ;;
    *) OSC7501_AGENT_BIN=$HARNESS ;;
  esac
else
  read -r osc7501_word _ <<<"$RAW_COMMAND"
  case "$RAW_COMMAND" in
    *[\;\&\|]* | *$'\n'*) ;;
    *)
      case "$osc7501_word" in
        '' | *[!A-Za-z0-9._/+-]*) ;;
        *) (launch_template "$HARNESS" "$KIND") >/dev/null 2>&1 && OSC7501_AGENT_BIN=$osc7501_word ;;
      esac
      ;;
  esac
fi
LAUNCH="$(shell_quote "$FM_ROOT/bin/fm-osc7501.sh") arm --task $(shell_quote "$ID") --harness $(shell_quote "$HARNESS") --backend $(shell_quote "$BACKEND") --kind $(shell_quote "$KIND") --state $(shell_quote "$STATE_REAL") --config $(shell_quote "$CONFIG") --target $(shell_quote "$T") --agent-bin $(shell_quote "$OSC7501_AGENT_BIN") >/dev/null || true
$LAUNCH
$(shell_quote "$FM_ROOT/bin/fm-osc7501.sh") disarm --state $(shell_quote "$STATE_REAL") >/dev/null 2>/dev/null || true"
if [ "$LAVISH_AXI_HOST_CONFIG_PRESENT" = 1 ]; then
  LAUNCH="export LAVISH_AXI_HOST=$(shell_quote "$LAVISH_AXI_HOST"); $LAUNCH"
fi
# Every launch also exports the absolute path of this task's steering inbox, so
# the constant doorbell line (bin/fm-task-inbox-lib.sh) can name
# "$FM_TASK_INBOX" instead of a path that grows with the home's depth. Like the
# kill switch below it is an export statement, so it survives a compound raw
# launch and the launch-env-allowlist `env -i` wrapper.
LAUNCH="export FM_TASK_INBOX=$(shell_quote "$STATE_REAL/$ID.inbox"); $LAUNCH"
LAUNCH="export COMPACT_ADVISER_DISABLE=1; $LAUNCH"
# When the live-harness gate has exported DISABLE_AUTOUPDATER into this spawn's
# own environment, carry it into the launch command text so Claude Code's
# auto-updater cannot rewrite the shared binary during a live run. Embedding the
# assignment - like COMPACT_ADVISER_DISABLE above - rather than leaning on
# ambient inheritance is what survives a pre-existing backend daemon that
# constructs the pane command without the gate's environment. It is gated on the
# value being set here so ordinary spawns are unchanged.
if [ -n "${DISABLE_AUTOUPDATER:-}" ]; then
  LAUNCH="export DISABLE_AUTOUPDATER=$(shell_quote "$DISABLE_AUTOUPDATER"); $LAUNCH"
fi
if [ -z "$SPAWN_TRACEPARENT" ] && [ "$RELAUNCH" -eq 1 ]; then
  LAUNCH="unset TRACEPARENT; $LAUNCH"
fi

}

spawn_record_traceparent() {
  local meta="$STATE/$ID.meta" status=0 acquired=0
  # Fresh publication still owns the lock. Relaunch deliberately uses a short
  # independent critical section so other metadata interfaces can serialize.
  if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
    SPAWN_META_LOCK=$(fm_meta_lock_path "$meta") || return 1
    fm_lock_acquire_wait "$SPAWN_META_LOCK"
    SPAWN_META_LOCK_HELD=1
    acquired=1
  fi
  SPAWN_META_TMP="$STATE/.$ID.meta.trace.${BASHPID:-$$}"
  if [ ! -f "$meta" ] || [ ! -w "$meta" ] ||
    ! spawn_meta_rewrite_before_pr "$meta" "$SPAWN_META_TMP" traceparent \
      "traceparent=$SPAWN_TRACEPARENT" ||
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

spawn_post_launch_report() {

if [ "$BACKEND" = t3code ]; then
  # No pane to export into: the same facts, under the same conditions as the
  # pane path below, become the launch directory's harness config
  # (spawn_t3code_env_install). TRACEPARENT is delivered only once its meta
  # record exists, the same delivered-implies-recorded invariant the pane path
  # keeps by unsetting it when the record fails.
  T3CODE_ENV=("GOTMPDIR=$TASK_TMP/gotmp" COMPACT_ADVISER_DISABLE=1 "FM_TASK_INBOX=$STATE_REAL/$ID.inbox")
  if [ "$GIT_HOOKS_INSTALLED" = 1 ]; then
    T3CODE_ENV+=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath "GIT_CONFIG_VALUE_0=$GIT_HOOKS_DIR")
  fi
  if [ "$LAVISH_AXI_HOST_CONFIG_PRESENT" = 1 ]; then
    T3CODE_ENV+=("LAVISH_AXI_HOST=$LAVISH_AXI_HOST")
  fi
  if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
    T3CODE_ENV+=("FM_TASK_ID=$ID" "FM_HOME=$FM_HOME")
  fi
  if [ -n "$SPAWN_TRACEPARENT" ] && spawn_record_traceparent; then
    T3CODE_ENV+=("TRACEPARENT=$SPAWN_TRACEPARENT")
  fi
  if [ "$KIND" = secondmate ]; then
    # The secondmate launch prefix above, value for value, plus the supervisor
    # identity its own away daemon cannot discover from inside a T3 thread.
    T3CODE_ENV+=(FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= \
      "FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$FM_HOME" "FM_HOME=$PROJ_ABS" "FM_TRACE_CONTEXT=$SPAWN_TRACE_EFFECTIVE" \
      "FM_SUPERVISION_MODEL=$supervision_model" FM_SUPERVISOR_BACKEND=t3code "FM_SUPERVISOR_TARGET=$T")
  fi
  spawn_t3code_env_install "$HARNESS" "${T3CODE_ENV[@]}" || {
    echo "error: could not write the $HARNESS environment config for $ID into $WT" >&2
    exit 1
  }
  if [ "$HARNESS" = claude ] && [ "$KIND" != secondmate ]; then
    spawn_t3code_claude_channel_install || {
      echo "error: could not write the Claude task-worker channel statement for $ID into $WT" >&2
      exit 1
    }
  fi
else
# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
# Export the compact-adviser kill switch into the pane shell through the same
# pre-launch channel, so later commands in that shell inherit it too. The launch
# command independently establishes the value for the agent process itself.
spawn_send_text_line "$T" "export COMPACT_ADVISER_DISABLE=1"
if [ "$LAVISH_AXI_HOST_CONFIG_PRESENT" = 1 ]; then
  spawn_send_text_line "$T" "export LAVISH_AXI_HOST=$(shell_quote "$LAVISH_AXI_HOST")"
fi
# Mark the pane as a task worker so bin/fm-test-run.sh can refuse to run the
# suite in the repository's primary checkout. Ship and scout workers are the
# ones assigned an isolated worktree; a secondmate runs its own home instead.
# The id reached a validated bare-slug charset above, so it carries no shell
# syntax of its own.
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  spawn_send_text_line "$T" "export FM_TASK_ID=$ID"
fi
# Send through the exact pane channel that already ships GOTMPDIR, so every pane
# backend and harness - ship, scout, and secondmate - gets it before launch. Skipped
# entirely when trace context is off.
if [ -n "$SPAWN_TRACEPARENT" ]; then
  if spawn_send_text_line "$T" "export TRACEPARENT=$SPAWN_TRACEPARENT"; then
    if ! spawn_record_traceparent; then
      LAUNCH="unset TRACEPARENT; $LAUNCH"
    fi
  else
    TRACE_SEND_STATUS=$?
    if [ "$TRACE_SEND_STATUS" -eq 2 ]; then
      echo "error: trace-context input could not be cleared for $W; refusing to append the launch command" >&2
      exit 1
    fi
    LAUNCH="unset TRACEPARENT; $LAUNCH"
  fi
fi
fi
if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
  LAUNCH_ENV_PREFIX='/usr/bin/env -i'
  # A configured Orca source replaces destination expansion of allowlisted
  # names, so a name the source leaves unset cannot revive a personal pane value.
  LAUNCH_ENV_FORWARD_NAMES=$LAUNCH_ENV_NAMES
  [ "$ORCA_LAUNCH_ENV_ENABLED" != 1 ] || LAUNCH_ENV_FORWARD_NAMES=
  # COMPACT_ADVISER_DISABLE is the intentional declarative floor-membership
  # entry; the explicit COMPACT_ADVISER_DISABLE=1 assignment below is the
  # authoritative setter.
  for env_name in HOME PATH USER LOGNAME SHELL TERM COLORTERM LANG LC_ALL LC_CTYPE \
    TMPDIR TMP TEMP GOTMPDIR TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH \
    HERDR_PANE_ID CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_TAB_ID CMUX_PANEL_ID \
    CMUX_SOCKET_PATH ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID FM_ZELLIJ_SESSION \
    TERM_PROGRAM REX_SESSION REX_BLOCK REX_SERVER REX_BIN_DIR \
    TERN_IDENTITY TERN_PANE TERN_PANE_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET \
    HC_SESSION HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE \
    FM_TASK_ID COMPACT_ADVISER_DISABLE LAVISH_AXI_HOST \
    $LAUNCH_ENV_FORWARD_NAMES; do
    if [ "$ORCA_LAUNCH_ENV_ENABLED" = 1 ]; then
      case $'\n'"$LAUNCH_ENV_NAMES"$'\n' in
        *$'\n'"$env_name"$'\n'*) continue ;;
      esac
    fi
    # Only validated names enter shell syntax. Values expand once, quoted, in
    # the pane shell and never become source text or spawn-process snapshots.
    # shellcheck disable=SC2016
    printf -v env_arg '${%s+"%s=$%s"}' "$env_name" "$env_name" "$env_name"
    LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX $env_arg"
  done
  if [ "$ORCA_LAUNCH_ENV_ENABLED" = 1 ]; then
    LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX $ORCA_LAUNCH_ENV_ARGS GIT_CONFIG_NOSYSTEM=1"
  fi
  # COMPACT_ADVISER_DISABLE is retained by the floor loop above, which forwards
  # whatever the pane export set, and then pinned here to the one value Firstmate
  # launches on. The literal assignment comes last deliberately: `env` applies
  # assignments left to right, so this one wins over a forwarded pane value, and
  # it still delivers the switch on a pane whose export never landed. Unlike the
  # trace carrier below it carries no gate, so it is appended unconditionally.
  # Setting it here rather than relying on the assignment already carried by
  # $LAUNCH is what gives the wrapping `/bin/sh` itself the switch, not only the
  # agent command it runs.
  LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX COMPACT_ADVISER_DISABLE=1"
  if [ -n "$SPAWN_TRACEPARENT" ]; then
    # shellcheck disable=SC2016
    LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX "'${TRACEPARENT+"TRACEPARENT=$TRACEPARENT"}'
  fi
  LAUNCH="$LAUNCH_ENV_PREFIX /bin/sh -c $(shell_quote "$LAUNCH")"
fi
if [ "$BACKEND" = t3code ]; then
  # No pane: the launch is the thread's first message, carrying the same
  # encoded brief the LAUNCH template embeds; MODEL/EFFORT were fixed as the
  # thread's model selection at launch instead of CLI flags, so nothing is
  # staged for a shell to source.
  T3CODE_BRIEF_TEXT=$("$FM_ROOT/bin/fm-operational-input.sh" encode launch-brief < "$BRIEF") || exit 1
  SPAWN_LAUNCH_SENT=1
  fm_backend_t3code_turn_start "$T" "$T3CODE_BRIEF_TEXT" "$T3CODE_MODEL_SELECTION" || {
    if [ "$?" -ne 7 ]; then
      echo "error: T3 refused the launch turn for $ID on thread $T; inspect the thread in T3 Code" >&2
      exit 1
    fi
    T3CODE_LAUNCH_UNCONFIRMED=1
  }
  T3CODE_ABORT_CLEANUP=0
  T3CODE_LEASED=0
  T3CODE_HOME_ENV=0
else
  if ! (umask 077 && mkdir "$LAUNCH_DIR") 2>/dev/null; then
    if [ -L "$LAUNCH_DIR" ] || [ ! -d "$LAUNCH_DIR" ] || [ ! -O "$LAUNCH_DIR" ] ||
      [ -n "$(find "$LAUNCH_DIR" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] ||
      ! chmod 700 "$LAUNCH_DIR"; then
      echo "error: task launch directory $LAUNCH_DIR already exists and is not a private directory owned by this user; refusing to stage the launch command there; inspect and remove it, then retry" >&2
      exit 1
    fi
  fi
  LAUNCH_FILE="$LAUNCH_DIR/launch.$SPAWN_GEN.sh"
  LAUNCH_STAGE="$LAUNCH_DIR/.launch.$SPAWN_GEN.tmp"
  if [ "$ORCA_LAUNCH_ENV_ENABLED" = 1 ]; then
    # The sourcing shell already holds the open file; unlink the credentials
    # before launching the worker, including on a later command failure.
    LAUNCH="command rm -- $(shell_quote "$LAUNCH_FILE") || { echo 'error: cannot remove private launch file; refusing worker launch' >&2; return 1 2>/dev/null || exit 1; }; $LAUNCH"
  fi
  if [ -e "$LAUNCH_FILE" ] || [ -L "$LAUNCH_FILE" ]; then
    echo "error: task launch file $LAUNCH_FILE already exists; refusing to replace it" >&2
    exit 1
  fi
  if ! (umask 077 && printf '%s\n' "$LAUNCH" >"$LAUNCH_STAGE" &&
    chmod 0600 "$LAUNCH_STAGE" && mv -f "$LAUNCH_STAGE" "$LAUNCH_FILE"); then
    rm -f "$LAUNCH_STAGE"
    echo "error: could not stage the launch command at $LAUNCH_FILE" >&2
    exit 1
  fi
  SPAWN_STAGED_LAUNCH_FILE=$LAUNCH_FILE
  if [ "$ORCA_LAUNCH_ENV_ENABLED" = 1 ]; then
    # Bash runs the EXIT trap for an untrapped fatal signal with status 0, which
    # abort cleanup reads as success, so exit with the signal's status instead
    # until the pane has consumed the published launch file.
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
  sleep 0.3
  spawn_orca_launch_send_fail() {
    rm -f -- "$LAUNCH_FILE" 2>/dev/null || true
    kimi_spawn_fail "launch command could not be delivered to Orca terminal $T"
    rovo_endpoint_cleanup
    exit 1
  }
  # Orca source mode: the pane unlinks the credential-bearing file as it starts
  # sourcing it. A pane that accepted the text but never ran it, or ran it and
  # could not unlink it, would otherwise leave the file until teardown, so wait a
  # bounded time and reclaim it. The worker never started, but the interactive
  # pane stays open.
  spawn_orca_wait_launch_consumed() {
    local i=0 max=${FM_ORCA_LAUNCH_CONSUME_POLLS:-150} reclaim_status=0
    while [ -e "$LAUNCH_FILE" ]; do
      i=$((i + 1))
      if [ "$i" -gt "$max" ]; then
        spawn_orca_reclaim_launch_file || reclaim_status=$?
        [ "$reclaim_status" != 1 ] || return 0
        kimi_spawn_fail "Orca terminal $T did not run the launch command or could not remove the launch file; refused the worker launch"
        exit 1
      fi
      sleep 0.2
    done
  }
  SPAWN_LAUNCH_SENT=1
  # errexit is on here: a failed send still exits, and Orca source mode first
  # removes the credential-bearing file the pane never received.
  LAUNCH_SOURCE_TEXT=". $(shell_quote "$LAUNCH_FILE")"
  if [ "$ORCA_LAUNCH_ENV_ENABLED" = 1 ]; then
    # A refused source-mode launch fails the source command, and some shells exit
    # under errexit on sourcing a file spawn already reclaimed even inside ||, so
    # keep an errexit pane shell open in both cases.
    LAUNCH_SOURCE_TEXT="if [ -e $(shell_quote "$LAUNCH_FILE") ]; then $LAUNCH_SOURCE_TEXT || true; else echo 'error: private launch file was already removed; refusing worker launch' >&2; fi"
  fi
  if ! spawn_send_literal "$T" "$LAUNCH_SOURCE_TEXT"; then
    [ "$ORCA_LAUNCH_ENV_ENABLED" != 1 ] || spawn_orca_launch_send_fail
    exit 1
  fi
  sleep 0.3
  if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
    HERDR_PROJECTION_ABORT_CLEANUP=0
    spawn_herdr_presentation_order_lock_release
  fi
  if ! spawn_send_key "$T" Enter; then
    [ "$ORCA_LAUNCH_ENV_ENABLED" != 1 ] || spawn_orca_launch_send_fail
    exit 1
  fi
  if [ "$ORCA_LAUNCH_ENV_ENABLED" = 1 ]; then
    spawn_orca_wait_launch_consumed
    trap - HUP INT TERM
  fi
fi
if [ "$HARNESS" = hermes ] && [ "$RAW_LAUNCH" -eq 0 ]; then
  HERMES_READY=0
  HERMES_DECLINED=0
  for ((HERMES_POLL=0; HERMES_POLL<${FM_HERMES_READY_POLLS:-180}; HERMES_POLL++)); do
    HERMES_SCREEN=$(fm_backend_capture "$BACKEND" "$T" 120 "$W" 2>/dev/null || true)
    case "$(fm_hermes_startup_screen "$HERMES_SCREEN")" in
      decline)
        if [ "$HERMES_DECLINED" = 0 ]; then
          spawn_send_key "$T" Enter || break
          HERMES_DECLINED=1
        fi
        ;;
      ready) HERMES_READY=1; break ;;
    esac
    case "$(fm_busy_classify "$BACKEND" "$T" hermes "$ID" "$STATE_REAL")" in
      'busy hermes-hook'|'idle hermes-hook') HERMES_READY=1; break ;;
    esac
    sleep "${FM_HERMES_POLL_INTERVAL:-0.5}"
  done
  if [ "$HERMES_READY" != 1 ]; then
    echo "error: Hermes did not reach its TUI or process its brief in $T; inspect profile setup, provider errors, and first-run consent (only an already-selected No thanks is answered)" >&2
    rovo_endpoint_cleanup
    if [ "$SPAWN_ENDPOINT_CLOSED" != 1 ]; then
      # Hermes may still finish starting there, so the record stays for
      # supervision and teardown instead of being rolled back.
      SPAWN_FRESH_COMMIT_PENDING=0
      echo "warning: could not close endpoint $T after the failed Hermes launch of $ID; its task record is kept so the worker stays reachable - inspect it, then tear it down" >&2
    fi
    exit 1
  fi
fi
if [ "$HARNESS" = kimi ]; then
  if ! kimi_wait_for_ready; then
    kimi_spawn_fail "$KIMI_READY_FAILURE_DETAIL"
    exit 1
  fi
  KIMI_POINTER="Read the brief at $BRIEF_REAL and follow it exactly."
  KIMI_SUBMIT_RETRIES=${FM_KIMI_SUBMIT_RETRIES:-3}
  KIMI_SUBMIT_SLEEP=${FM_KIMI_SUBMIT_SLEEP:-${FM_KIMI_POLL_INTERVAL:-0.5}}
  KIMI_SUBMIT_SETTLE=${FM_KIMI_SUBMIT_SETTLE:-0}
  if ! KIMI_SUBMIT_VERDICT=$(fm_backend_send_text_submit \
    "$BACKEND" "$T" "$KIMI_POINTER" "$KIMI_SUBMIT_RETRIES" \
    "$KIMI_SUBMIT_SLEEP" "$KIMI_SUBMIT_SETTLE" "$W"); then
    kimi_spawn_fail "kimi brief pointer could not be submitted"
    exit 1
  fi
  if [ "$KIMI_SUBMIT_VERDICT" = send-failed ]; then
    kimi_spawn_fail "kimi brief pointer could not be submitted"
    exit 1
  fi
  if ! kimi_wait_for_delivery; then
    kimi_spawn_fail "kimi brief pointer delivery was not confirmed"
    exit 1
  fi
fi
if [ "$HARNESS" = rovo ]; then
  if ! rovo_wait_for_ready; then
    rovo_spawn_fail "rovo did not show a verified ready signal before brief delivery in window $T"
    exit 1
  fi
  ROVO_POINTER="Read the brief at $BRIEF_REAL and follow it exactly."
  ROVO_SUBMIT_RETRIES=${FM_ROVO_SUBMIT_RETRIES:-3}
  ROVO_SUBMIT_SLEEP=${FM_ROVO_SUBMIT_SLEEP:-${FM_ROVO_POLL_INTERVAL:-0.5}}
  ROVO_SUBMIT_SETTLE=${FM_ROVO_SUBMIT_SETTLE:-0}
  if ! ROVO_SUBMIT_VERDICT=$(fm_backend_send_text_submit \
    "$BACKEND" "$T" "$ROVO_POINTER" "$ROVO_SUBMIT_RETRIES" \
    "$ROVO_SUBMIT_SLEEP" "$ROVO_SUBMIT_SETTLE" "$W"); then
    rovo_spawn_fail "rovo brief pointer could not be submitted into window $T"
    exit 1
  fi
  if [ "$ROVO_SUBMIT_VERDICT" = send-failed ]; then
    rovo_spawn_fail "rovo brief pointer could not be submitted into window $T"
    exit 1
  fi
  if ! rovo_wait_for_delivery; then
    rovo_spawn_fail "rovo brief pointer delivery was not confirmed in window $T"
    exit 1
  fi
fi
if [ "$HARNESS" = opencode ] && [ "$OPENCODE_MAJOR" -ge 2 ]; then
  if ! opencode2_wait_for_delivery; then
    printf '%s\n' "$(status_stamp_line "failed: opencode $OPENCODE_VERSION did not start the brief turn in window $T")" >>"$STATE/$ID.status"
    echo "error: opencode $OPENCODE_VERSION did not start the brief turn; inspect window $T" >&2
    rovo_endpoint_cleanup
    exit 1
  fi
fi
if [ "$HARNESS" = agy ]; then
  if ! agy_wait_for_working; then
    if [ "$AGY_TRUST_ANSWERED" -eq 1 ]; then
      agy_spawn_fail "agy did not start processing its brief after the folder-trust dialog was answered in window $T"
    elif [ "$AGY_TRUST_PREREGISTERED" -eq 1 ]; then
      agy_spawn_fail "agy did not start processing its brief in the pre-trusted worktree in window $T"
    else
      agy_spawn_fail "agy never showed its folder-trust dialog on an unregistered worktree in window $T, so the brief could not be confirmed to run there"
    fi
    exit 1
  fi
fi
# polytoken's gate is semantic and scoped to the canonical template: a raw
# launch command never carries the generated wiring's flags, so it is gated
# off exactly like the arm above. The failure detail names the one known
# first-start blocker (the license dialog) so a supervisor can tell a
# blocked launch from a wedged one.
if [ "$HARNESS" = polytoken ] && [ "$RAW_LAUNCH" -eq 0 ]; then
  if ! polytoken_wait_for_ready; then
    polytoken_spawn_fail "polytoken did not start processing its brief in window $T (a first-start license dialog is the one known blocker; it is never auto-accepted)"
    exit 1
  fi
  if ! spawn_record_polytoken_session; then
    polytoken_spawn_fail "polytoken session binding could not be recorded for $ID"
    exit 1
  fi
fi

if [ "$KIND" = secondmate ] && [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ]; then
  if ! fm_config_reread_discard_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
    if fm_config_reread_quarantine_pending "$PROJ_ABS" "$ID" "$FM_HOME"; then
      echo "CONFIG_REREAD: secondmate $ID: quarantined pre-relaunch generations after cleanup failure (destination=$PROJ_ABS/state/.fm-inherited-config-reread-quarantine source=$FM_HOME/state/.fm-inherited-config-reread-quarantine)" >&2
    else
      echo "CONFIG_REREAD: secondmate $ID: cleanup failed; pre-relaunch generations were force-cleared where possible (destination=$PROJ_ABS source=$FM_HOME)" >&2
    fi
  fi
fi

# This is the commit point: all endpoint and harness delivery that can reject
# the spawn has succeeded. Re-read and transition while holding the same
# per-task lock as metadata publication, then and only then report success.
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
SPAWN_DEFERRED_SIGNAL=
if [ "$BACKLOG_TRANSITION" = 1 ]; then
  trap 'SPAWN_DEFERRED_SIGNAL=HUP' HUP
  trap 'SPAWN_DEFERRED_SIGNAL=INT' INT
  trap 'SPAWN_DEFERRED_SIGNAL=TERM' TERM
fi
SPAWN_BACKLOG_COMMIT_STATUS=0
# Both the commit and its preservation read-back run under this task's meta
# lock, so an unresponsive tasks-axi there would hold the lock - and every
# lifecycle operation waiting on it - open ended, with even the deferred
# signals parked in a trap. Bound each invocation
# (bin/fm-backlog-transition-lib.sh's fm_tasks_axi): a timed-out call
# fails through the ordinary error plumbing, and the interrupted exit path
# reports it as the reason the preservation could not be verified.
FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-30}
if spawn_commit_backlog_transition; then
  SPAWN_FRESH_COMMIT_PENDING=0
else
  SPAWN_BACKLOG_COMMIT_STATUS=$?
  if spawn_commit_backlog_transition; then
    SPAWN_BACKLOG_COMMIT_STATUS=0
    SPAWN_FRESH_COMMIT_PENDING=0
  fi
fi
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  if [ "$RELAUNCH" -eq 0 ]; then
    if spawn_fresh_commit_rollback; then
      echo "error: task $ID's backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); its record was removed so no worker is left that the backlog does not own - close out endpoint $T and local copy $WT by hand, then re-run the spawn" >&2
    else
      echo "error: task $ID's backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR), and failed-dispatch cleanup is incomplete; the provisional record may remain at $STATE/$ID.meta - close out endpoint $T and local copy $WT by hand, then remove the record and busy state before retrying" >&2
    fi
  else
    echo "error: task $ID was republished but its backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); fix the backlog and re-run the relaunch" >&2
  fi
fi
trap - HUP INT TERM
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  exit "$SPAWN_BACKLOG_COMMIT_STATUS"
fi
if [ -n "$SPAWN_DEFERRED_SIGNAL" ]; then
  case "$SPAWN_DEFERRED_SIGNAL" in
  HUP) SPAWN_DEFERRED_SIGNAL_STATUS=129 ;;
  INT) SPAWN_DEFERRED_SIGNAL_STATUS=130 ;;
  TERM) SPAWN_DEFERRED_SIGNAL_STATUS=143 ;;
  esac
  # Keep deferring further signals so the read-back below cannot itself be
  # killed halfway through verifying or correcting the preserved state.
  trap 'SPAWN_DEFERRED_SIGNAL=$SPAWN_DEFERRED_SIGNAL' HUP INT TERM
  # Deliberately unguarded against errexit: a failed verification still set
  # the honest attempted-preservation claim the exit below reports.
  spawn_report_preserved_state || true
  trap - HUP INT TERM
  echo "error: spawn of $ID was interrupted after launch delivery began; $SPAWN_PRESERVED_CLAIM" >&2
  exit "$SPAWN_DEFERRED_SIGNAL_STATUS"
fi
fm_lock_release "$SPAWN_META_LOCK"
SPAWN_META_LOCK_HELD=0

if [ "$T3CODE_LAUNCH_UNCONFIRMED" = 1 ]; then
  echo "error: the launch brief for $ID may already have been delivered to T3 thread $T: its outcome is unproven (a lost reply or a T3 error that can follow a commit). The task record is kept; inspect the thread in T3 Code, and if the brief is absent resend only the identical brief text, which reuses its request id within the hour" >&2
  exit 1
fi

SPAWN_DELIVERY=
[ -z "$MODE" ] || SPAWN_DELIVERY=" mode=$MODE yolo=$YOLO"
SPAWN_ACCOUNT=
[ -z "$WORKER_ACCOUNT" ] || SPAWN_ACCOUNT=" account=$WORKER_ACCOUNT_DECLARED"
[ -z "$WORKER_ACCOUNT_PROVIDER" ] || SPAWN_ACCOUNT="$SPAWN_ACCOUNT account_provider=$WORKER_ACCOUNT_PROVIDER"
[ -z "$OMP_PROFILE_PIN" ] || SPAWN_ACCOUNT="$SPAWN_ACCOUNT omp_profile=$OMP_PROFILE_PIN"
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "$CONFIG/fleet-ledger" ] || [ "$RELAUNCH" -eq 1 ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-fleet-ledger.sh" dispatched "$ID" "$KIND" "${PROJ_ABS##*/}" "$HARNESS" "$MODEL" || true
# Opt-in Herdr project groups (docs/herdr-backend.md "Project groups") tag the
# new endpoint now rather than at the next watcher poll; off costs one file test.
[ ! -e "$CONFIG/herdr-project-groups" ] || [ "$BACKEND" != herdr ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-herdr-groups.sh" sync "$ID" || true
echo "spawned $ID harness=$HARNESS kind=$KIND$SPAWN_DELIVERY window=$META_WINDOW worktree=$WT$SPAWN_ACCOUNT"
}
