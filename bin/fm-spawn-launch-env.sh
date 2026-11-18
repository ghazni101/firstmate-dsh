# shellcheck shell=bash
# launch environment and t3code wiring.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

exclude_path() {
  local rel=$1 EXCL
  # git rev-parse --git-path is relative to the repository, not to this
  # process's cwd. A caller sitting in another worktree must not mkdir
  # against its own .git file.
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  case "$EXCL" in
    /*) ;;
    *) EXCL="$WT/$EXCL" ;;
  esac
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >>"$EXCL"
}

# spawn_t3code_env_install <harness> NAME=VALUE... - the t3code channel for the
# exports a pane shell would receive before launch. T3 sets environment per
# provider instance, never per thread, but each harness reads its own
# per-directory config from the thread's cwd ($WT): Claude's
# .claude/settings.local.json `env` block (merged into the file so the busy
# hooks written above and a secondmate home's own env entries survive;
# FM_T3CODE_ENV_KEYS names the keys Firstmate wrote, which a respawn replaces
# so it never inherits a stale value; a symlinked file is refused) and Codex's
# .codex/config.toml
# `[shell_environment_policy] set` table (TOML basic strings). Both files are
# git-excluded when untracked; tracked Codex overlays are owned by
# fm-t3code-codex-env.sh, including their Git protection and exact restoration.
# spawn_t3code_claude_channel_install - the t3code carrier for the Claude
# task-worker channel statement (spawn_claude_task_channel_statement). T3 owns
# the system prompt, and its Claude sessions read the launch directory's
# CLAUDE.local.md as instructions, so a ship or scout worker gets the statement
# there; git-excluded like every other per-task harness file and removed by
# fm-teardown.sh. Verified live: the same operator brief a worker refused as
# prompt injection without the file was followed with it.
# On a T3 server older than the first build whose pull-request tools were
# verified safe for Claude (fm_backend_t3code_claude_pr_tools_verified), the
# carrier adds one clause steering the worker off them, since they crashed a
# Claude session on a pre-V2 build; Firstmate records the PR from the worker's
# `done: PR <url>` status line either way.


spawn_install_launch_environment() {
if [ "$RELAUNCH" -eq 1 ]; then
  # Retire the previous incarnation's per-task harness wiring before arming the
  # new one. Without this, a harness switch would leave the old adapter's hook
  # files and turn-end token registry entries behind, and even a same-harness
  # relaunch would orphan the retired busy generation's token
  # (bin/fm-control-lib.sh owns where those artifacts live).
  clear_relaunch_harness_wiring "$RELAUNCH_PRIOR_HARNESS" "$WT" "$STATE_REAL" "$ID" "$KIND" || {
    echo "error: could not retire $RELAUNCH_PRIOR_HARNESS wiring for task $ID; refusing to arm the replacement" >&2
    exit 1
  }
fi
if [ "$HARNESS" = polytoken ] && [ "$RAW_LAUNCH" -eq 0 ]; then
  fm_polytoken_require_hooks_free "$WT" || exit 1
  fm_polytoken_require_handler_path "$(fm_polytoken_busy_script "$STATE_REAL" "$ID")" || exit 1
fi
[ "$RELAUNCH" -eq 1 ] || [ "$HARNESS" != polytoken ] || SPAWN_FRESH_WIRING_PENDING=1
if [ "$RELAUNCH" -eq 1 ]; then
  RELAUNCH_REPLACEMENT_PENDING=1
  RELAUNCH_REPLACEMENT_HARNESS=$HARNESS
  RELAUNCH_REPLACEMENT_STATE=$STATE_REAL
  RELAUNCH_REPLACEMENT_WT=$WT
fi
# OpenCode changed its interactive launch surface, its composer exit key, and
# its plugin surface between the 1.x and 2.x lines: 2.x dropped the top-level
# --model flag (the model rides OPENCODE_CONFIG_CONTENT instead), exits on a raw
# Ctrl-C, and reports activity through session.execution.* events from a plugin
# that exports a default definition; 1.x takes --model, exits on /exit, and
# reports through session.status/session.idle. Detect the installed major once,
# here, before the busy-state plugin is provisioned below, so the plugin shape,
# the launch shape, and fm-control's recorded exit mechanics all key off the one
# resolved version. Only a parsed major >= 2 selects the 2.x shape: an
# undetectable probe (opencode unresolvable, or --version without a parseable
# x.y.z) falls back to the 1.x shape everywhere - --model, the 1.x config and
# busy-state plugin, and the version-agnostic /exit - matching the pre-gate
# behavior.
# Resolve the opencode executable exactly once, to the absolute path the worker
# pane's launch will run (baked into the launch command as __OPENCODEBIN__
# below). The probe reads that same binary, so the recorded major can never
# describe a different executable than the pane starts: a PATH that resolves one
# opencode here and another in the pane can no longer make the launch drop
# --model or fm-control pick the wrong exit key. An unresolvable executable
# leaves the version empty - the probe records no version (1.x launch/exit
# defaults) and the launch falls back to a bare `opencode` the pane resolves
# itself, exactly as before this gate existed.
OPENCODE_BIN=
OPENCODE_VERSION=
if [ "$HARNESS" = opencode ]; then
  OPENCODE_BIN=$(resolve_pi_executable opencode) || OPENCODE_BIN=
  if [ -n "$OPENCODE_BIN" ]; then
    OPENCODE_VERSION=$("$OPENCODE_BIN" --version 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  fi
fi
# The effective major the launch, plugin, and exit shapes branch on. A resolved
# x.y.z yields its numeric major (the grep above guarantees digits); an empty or
# unparseable probe falls back to 1, so only a genuine major >= 2 ever takes the
# 2.x path.
case "$OPENCODE_VERSION" in
'') OPENCODE_MAJOR=1 ;;
*) OPENCODE_MAJOR=${OPENCODE_VERSION%%.*} ;;
esac

# Arm the semantic busy-state contract (bin/fm-busy-lib.sh) for every
# adapter with a verified semantic source, including a --secondmate launch.
# The parent watcher reads this home's record; skipping the arm left a
# tmux-backed mate's active-turn gate unable to return busy. The launch
# brief sent below IS a submitted turn, so the seed record is busy/fm-spawn.
# The minted gen is embedded into each adapter's wiring so an event from a
# superseded incarnation is rejected as stale. Grok and rovo stay on their
# isolated rendered-tail fallbacks and standalone Kimi stays unknown until
# fm_busy_kimi_verified opens, so none of the three is armed here. Gemini IS
# armed: its BeforeAgent / AfterAgent / SessionEnd hooks are a verified
# open-close pair. A secondmate's hooks update this record and do not touch
# the parent's turn-ended marker; parent turn-end wiring for grok and kimi
# stays on the ordinary-task path below. A raw launch command for a claude,
# pi, pi-signed, or omp secondmate is not armed: those four reach their
# wiring only through a launch-template flag (--settings, -e) that a raw
# command does not carry, so the record would never be updated.
busy_notify_turnend=true
WIRING_HARNESS=$HARNESS
if [ "$KIND" = secondmate ]; then
  busy_notify_turnend=false
  if [ "$RAW_LAUNCH" -ne 0 ]; then
    case "$HARNESS" in
    claude* | pi | pi-signed | omp)
      WIRING_HARNESS=
      if [ -e "$STATE_REAL/$ID.busy-gen" ]; then
        "$FM_ROOT/bin/fm-busy-event.sh" retire "$STATE_REAL" "$ID" --current-gen || {
          echo "error: failed to retire the earlier busy-state contract for $ID" >&2
          exit 1
        }
      fi
      ;;
    esac
    case "$HARNESS" in
    claude*) rm -f "$WT/.fm-busy-stop" ;;
    esac
  fi
fi
BUSY_GEN=
  case "$WIRING_HARNESS" in
  codex*)
    if fm_busy_codex_semantic_source; then
      echo "error: codex semantic busy-state wiring is not implemented; extend the probe only together with verified wiring" >&2
      exit 1
    fi
    ;;
  esac
  case "$WIRING_HARNESS" in
  claude* | opencode* | pi | pi-signed | omp)
    # opencode arms on every detected major: OpenCode 2 and the OpenCode 1 /
    # undetected->1.x path both provision a busy-state plugin below that needs
    # this gen, so gating the arm on major >= 2 would leave OpenCode 1 without
    # the busy-state wiring it had before the OpenCode 2 port.
    BUSY_GEN=$("$FM_ROOT/bin/fm-busy-event.sh" arm "$STATE_REAL" "$ID") || {
      echo "error: failed to arm the busy-state contract for $ID" >&2
      exit 1
    }
    [ "$RELAUNCH" -ne 1 ] || RELAUNCH_REPLACEMENT_BUSY_GEN=$BUSY_GEN
    ;;
  gemini | devin | commandcode | polytoken | cortex | kiro | hermes)
    if [ "$RAW_LAUNCH" -eq 0 ]; then
      BUSY_GEN=$("$FM_ROOT/bin/fm-busy-event.sh" arm "$STATE_REAL" "$ID") || {
        echo "error: failed to arm the busy-state contract for $ID" >&2
        exit 1
      }
      [ "$RELAUNCH" -ne 1 ] || RELAUNCH_REPLACEMENT_BUSY_GEN=$BUSY_GEN
    fi
    ;;
  kimi*)
    # Standalone Kimi stays unknown until fm_busy_kimi_verified opens on a
    # live-verified installed version (bin/fm-busy-lib.sh owns the gate and
    # the required evidence). Arming without wiring would seed a busy record
    # nothing can ever clear, so the arm waits for the wiring.
    if fm_busy_kimi_verified; then
      echo "error: kimi semantic busy-state wiring is not implemented; open the gate only together with verified wiring" >&2
      exit 1
    fi
    ;;
  esac
  case "$WIRING_HARNESS" in
  claude*)
    # Semantic busy-state hooks (bin/fm-busy-lib.sh): UserPromptSubmit opens
    # a turn; Stop (normal completion), StopFailure (API-error turn end),
    # and SessionEnd (process shutdown) all close it, so an abnormal end can
    # never leave a stale busy record. Claude fires no hook for a manual
    # interrupt: fm-control preserves the adapter-owned state, while the
    # legacy fm-send --key Escape path records idle/fm-interrupt. Stop keeps
    # the turn-ended NOTIFICATION touch for the watcher. A secondmate gets no
    # Stop hook here: its home's tracked Stop guard (bin/fm-turnend-guard.sh)
    # can block a Stop into a continuation that fires no UserPromptSubmit,
    # and Claude runs Stop hooks in parallel, so the guard is that mate's only
    # Stop writer, reading this gen from .fm-busy-stop. A home whose guard
    # predates .fm-busy-stop would never close the turn, so that launch keeps
    # the ordinary Stop idle hook, without the parent turn-ended touch. Every
    # hook command tolerates a refused event (|| true) so a stale-gen writer
    # can never break Claude's own lifecycle.
    # A crewmate writes those hooks into the disposable worktree's
    # .claude/settings.local.json. A secondmate does not: that file in a
    # persistent home is where Claude Code stores the captain's "don't ask
    # again" rules, and rewriting it drops them. The secondmate hooks go in
    # a firstmate-owned state/<id>.claude-settings.json passed through
    # --settings. Claude Code merges hook entries across settings files
    # (https://code.claude.com/docs/en/hooks) and keeps any key
    # the flag omits (https://code.claude.com/docs/en/cli-reference), so the
    # home's tracked Stop guard and its settings.local.json both stay.
    busy_cmd_prefix="$(shell_quote "$FM_ROOT/bin/fm-busy-event.sh") apply $(shell_quote "$STATE_REAL") $(shell_quote "$ID")"
    busy_suffix="--gen $(shell_quote "$BUSY_GEN") --source claude-hook"
    j_submit=$(json_escape "$busy_cmd_prefix busy $busy_suffix --event user-prompt-submit 2>/dev/null || true")
    j_stopfail=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event stop-failure 2>/dev/null || true")
    j_sessionend=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event session-end 2>/dev/null || true")
    stop_entry=
    if [ "$KIND" = secondmate ] && grep -qF '.fm-busy-stop' "$WT/bin/fm-turnend-guard.sh" 2>/dev/null; then
      {
        printf 'writer=%s\n' "$FM_ROOT/bin/fm-busy-event.sh"
        printf 'state=%s\n' "$STATE_REAL"
        printf 'id=%s\n' "$ID"
        printf 'gen=%s\n' "$BUSY_GEN"
      } >"$WT/.fm-busy-stop"
      exclude_path '.fm-busy-stop'
    else
      stop_turnend=
      if [ "$busy_notify_turnend" = true ]; then
        stop_turnend="touch $(shell_quote "$TURNEND"); "
      fi
      j_stop=$(json_escape "${stop_turnend}$busy_cmd_prefix idle $busy_suffix --event stop 2>/dev/null || true")
      stop_entry="\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$j_stop\"}]}],"
    fi
    hooks_json="\"hooks\":{\"UserPromptSubmit\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$j_submit\"}]}],${stop_entry}\"StopFailure\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$j_stopfail\"}]}],\"SessionEnd\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$j_sessionend\"}]}]}"
    if [ "$KIND" = secondmate ]; then
      session_keys='"feedbackDrafts":"off",'
      if [ "$KEEP_AI_TRAILERS" != 1 ]; then
        session_keys='"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false},'
      fi
      printf '{%s%s}\n' "$session_keys" "$hooks_json" >"$STATE_REAL/$ID.claude-settings.json"
    else
      mkdir -p "$WT/.claude"
      printf '{%s}\n' "$hooks_json" >"$WT/.claude/settings.local.json"
      exclude_path '.claude/settings.local.json'
    fi
    ;;
  devin)
    if [ "$RAW_LAUNCH" -eq 0 ]; then
      echo 'error: devin was removed from the opinionated stack' >&2; exit 1
    fi
    ;;
  commandcode)
    # Command Code's busy wiring rides the launch command (__COMMANDCODEMOD__).
    # Its taste learning, which has no per-process switch, seeds
    # .commandcode/taste/ in the project on every start (verified, 1.74.1) and
    # learns into it, so that vendor runtime state stays out of worker commits.
    exclude_path '.commandcode/taste/'
    ;;
  hermes)
    if [ "$RAW_LAUNCH" -eq 0 ]; then
      fm_hermes_write_hooks "$HERMES_BIN" "$HERMES_PROFILE_HOME" "$STATE_REAL" "$ID" "$BUSY_GEN" || exit 1
    fi
    ;;
  cortex)
    if [ "$RAW_LAUNCH" -eq 0 ]; then
      echo 'error: cortex was removed from the opinionated stack' >&2; exit 1
    fi
    ;;
  gemini)
    if [ "$RAW_LAUNCH" -eq 0 ]; then
      # Semantic busy-state hooks (bin/fm-busy-lib.sh): BeforeAgent opens a
      # turn and AfterAgent closes it, with SessionEnd closing on process
      # shutdown so an abnormal end can never leave a stale busy record.
      # Verified live on gemini-cli 0.58.0 as a clean open/close pair:
      # mid-turn only BeforeAgent had fired, and AfterAgent followed at turn
      # end. AfterAgent ALSO fires on a manual Escape interrupt (carrying
      # prompt_response "[no response text]"), so unlike Claude a cancelled
      # gemini turn closes its own record instead of leaving it busy.
      # SessionEnd was observed firing TWICE for one /quit; the busy writer is
      # idempotent for a repeated idle event, so the duplicate is harmless and
      # deliberately not de-duplicated here.
      # These are written into a FIRSTMATE-OWNED settings file under state/,
      # reached through GEMINI_CLI_SYSTEM_SETTINGS_PATH on the launch command,
      # never into the worktree's own .gemini/settings.json - that path is the
      # PROJECT's committed settings file, so writing it would clobber a
      # project's configuration and retiring it would delete a tracked file.
      # Hook arrays MERGE across gemini's settings layers rather than
      # overriding, so a project's own hooks still run alongside these.
      # AfterAgent keeps the turn-ended NOTIFICATION touch for the watcher.
      # Every hook command tolerates a refused event (|| true) so a stale-gen
      # writer can never break gemini's own lifecycle, and each prints the
      # empty JSON object gemini's hook contract requires on stdout.
      busy_cmd_prefix="$(shell_quote "$FM_ROOT/bin/fm-busy-event.sh") apply $(shell_quote "$STATE_REAL") $(shell_quote "$ID")"
      busy_suffix="--gen $(shell_quote "$BUSY_GEN") --source gemini-hook"
      g_before=$(json_escape "$busy_cmd_prefix busy $busy_suffix --event before-agent >/dev/null 2>&1 || true; printf '{}'")
      g_after=$(json_escape "touch $(shell_quote "$TURNEND"); $busy_cmd_prefix idle $busy_suffix --event after-agent >/dev/null 2>&1 || true; printf '{}'")
      g_sessionend=$(json_escape "$busy_cmd_prefix idle $busy_suffix --event session-end >/dev/null 2>&1 || true; printf '{}'")
      cat >"$STATE_REAL/$ID.gemini-settings.json" <<EOF
{"hooks":{"BeforeAgent":[{"hooks":[{"type":"command","command":"$g_before"}]}],"AfterAgent":[{"hooks":[{"type":"command","command":"$g_after"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"$g_sessionend"}]}]}}
EOF
    fi
    ;;
  kiro)
    if [ "$RAW_LAUNCH" -eq 0 ]; then
      # Semantic busy-state hooks (bin/fm-busy-lib.sh): the V2 agent-config
      # userPromptSubmit hook opens a turn and the stop hook closes it, with the
      # stop hook also keeping the turn-ended NOTIFICATION touch for the watcher.
      # Verified live on kiro-cli 2.21.4 as a clean per-turn pair in both the
      # non-interactive run and the interactive TUI (userPromptSubmit fired on
      # submit, stop fired at turn end). Like Claude's Stop hook, kiro's stop
      # does NOT fire on a manual Escape interrupt, so fm-control preserves the
      # adapter-owned record there (fm_control_interrupt_ack_source is none). kiro
      # V2 exposes no verified StopFailure/SessionEnd equivalent, so an abnormal
      # turn end leaves the record busy until the next userPromptSubmit re-opens
      # it, and the supervisor reads that record as provably working. Nothing
      # rescues it: the rendered `Kiro is working` footer is a delivery guard
      # only (bin/fm-composer-lib.sh), never a worker state source.
      #
      # These are written into a FIRSTMATE-OWNED per-task agent config under
      # state/<id>.kiro-home/agents/, reached by relocating KIRO_HOME onto that
      # home on the launch command, never into the worktree's own .kiro/ - that
      # dir belongs to the project, and --agent is name-only so a config path is
      # not an option. The same per-task home carries a settings/cli.json seeding
      # chat.disableTrustAllConfirmation, which suppresses --trust-all-tools's
      # otherwise blocking confirmation modal (verified on AL2: the modal is the
      # only blocker there, and auth stays in the XDG data dir unaffected by
      # KIRO_HOME; macOS auth location is unestablished, docs/verification/kiro.md).
      #
      # Each hook command is a single-token absolute path to a generated script
      # under the same per-task home, so the hooks behave identically whether
      # kiro hands the command to a shell or splits it into argv - a vendor fact
      # nothing here has to depend on. The redirect, the refused-event tolerance
      # (|| true) and the turn-end touch all live inside the scripts, where the
      # interpreter is fixed by their own shebang, so a stale-gen writer still
      # cannot break kiro's lifecycle. No stdout contract applies.
      #
      # A raw launch command carries no KIRO_HOME and no --agent, so neither hook
      # could ever fire; arming and writing the config anyway would seed a busy
      # record nothing can clear. The gemini arm above skips both for the same
      # reason, and for the same reason claude does not: its hooks land in the
      # worktree, which a raw claude launch still reads.
      KIRO_HOME_DIR="$STATE_REAL/$ID.kiro-home"
      mkdir -p "$KIRO_HOME_DIR/agents" "$KIRO_HOME_DIR/settings" "$KIRO_HOME_DIR/hooks"
      printf '{"chat.disableTrustAllConfirmation":true}\n' >"$KIRO_HOME_DIR/settings/cli.json"
      busy_cmd_prefix="$(shell_quote "$FM_ROOT/bin/fm-busy-event.sh") apply $(shell_quote "$STATE_REAL") $(shell_quote "$ID")"
      busy_suffix="--gen $(shell_quote "$BUSY_GEN") --source kiro-hook"
      k_submit="$KIRO_HOME_DIR/hooks/user-prompt-submit"
      k_stop="$KIRO_HOME_DIR/hooks/stop"
      cat >"$k_submit" <<EOF
#!/bin/sh
$busy_cmd_prefix busy $busy_suffix --event user-prompt-submit 2>/dev/null || true
exit 0
EOF
      cat >"$k_stop" <<EOF
#!/bin/sh
touch $(shell_quote "$TURNEND")
$busy_cmd_prefix idle $busy_suffix --event stop 2>/dev/null || true
exit 0
EOF
      chmod +x "$k_submit" "$k_stop"
      cat >"$KIRO_HOME_DIR/agents/firstmate.json" <<EOF
{"name":"firstmate","description":"Firstmate per-task crewmate agent (busy-state and turn-end hooks)","tools":["*"],"allowedTools":["*"],"hooks":{"userPromptSubmit":[{"command":"$(json_escape "$k_submit")"}],"stop":[{"command":"$(json_escape "$k_stop")"}]}}
EOF
    fi
    ;;
  opencode*)
    # The worker's generated busy-state plugin is version-keyed off the major
    # resolved above. A detected OpenCode 2 (major >= 2) gets the
    # session.execution.* plugin that exports a default definition with setup();
    # OpenCode 1.x and an undetected install that falls back to 1.x get the
    # pre-port session.status / session.idle plugin, so OpenCode 1 keeps the
    # busy-state wiring it had before the OpenCode 2 port. OpenCode 1 genuinely
    # needs a busy plugin, so gating it off entirely would regress OpenCode 1
    # from its pre-port behavior; only the plugin SHAPE is version-gated.
    mkdir -p "$WT/.opencode/plugins"
    if [ "$OPENCODE_MAJOR" -ge 2 ]; then
      cat >"$WT/.opencode/plugins/fm-busy-state.js" <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state comes from OpenCode 2's session.execution.started and terminal
// session.execution.* events, with the OpenCode 1 session.status/session.idle
// names retained as legacy inputs. Scoping latches the first session that
// reports activity and ignores other sessions until the latched session settles,
// so a child's terminal event can never clear the worker's busy state. The
// turn-ended touch stays the watcher's wake NOTIFICATION, never current-state
// truth. Every event applies strictly in emission order through one queue
// shared by the server hook and the setup subscription: the record serializes
// only on its lock, so a turn's terminal busy - emitted a millisecond before
// its idle, delivered without awaiting this hook - would otherwise be free to
// win the last write and leave an idle worker recorded busy.
import { execFile } from "node:child_process";
const notifyTurnEnd = $busy_notify_turnend;
const busyEvent = (state, event) =>
  new Promise((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "opencode-plugin", "--event", event,
    ], () => resolve());
  });
const touchTurnEnded = () =>
  new Promise((resolve) => {
    execFile("touch", ["$TURNEND"], () => resolve());
  });
const eventType = (event) => event && (event.type || event.name) || "";
const eventProperties = (event) => event && (event.properties || event.data) || {};
const sessionID = (event) => {
  const properties = eventProperties(event);
  return properties.sessionID || properties.sessionId || (properties.session && properties.session.id) || properties.id || "";
};
const setupEventSubscription = (ctx, handler) => {
  if (!ctx || !ctx.event || !ctx.event.subscribe) return false;
  const controller = new AbortController();
  void (async () => {
    try {
      const stream = await ctx.event.subscribe({ signal: controller.signal, onActivity() {} });
      for await (const event of stream) await handler(event);
    } catch {
    }
  })();
  return true;
};
const makeHandler = () => {
  let activeSession = null;
  let queue = Promise.resolve();
  const apply = async (event) => {
    const type = eventType(event);
    const id = sessionID(event);
    if (type === "session.execution.started") {
      if (activeSession === null) activeSession = id;
      if (id === activeSession) await busyEvent("busy", "session-execution-started");
      return;
    }
    if (type === "session.execution.succeeded" || type === "session.execution.interrupted" || type === "session.execution.failed") {
      if (id === activeSession) {
        activeSession = null;
        await busyEvent("idle", type.replace(/\./g, "-"));
      }
      if (notifyTurnEnd) await touchTurnEnded();
      return;
    }
    if (type === "session.status") {
      const properties = eventProperties(event);
      const statusType = properties.status && properties.status.type;
      if (statusType === "busy" || statusType === "retry") {
        if (activeSession === null) activeSession = id;
        if (id === activeSession) await busyEvent("busy", "session-" + statusType);
        return;
      }
      if (statusType === "idle" && id === activeSession) {
        activeSession = null;
        await busyEvent("idle", "session-status-idle");
      }
      return;
    }
    if (type === "session.idle") {
      if (id === activeSession) {
        activeSession = null;
        await busyEvent("idle", "session-idle");
      }
      if (notifyTurnEnd) await touchTurnEnded();
    }
  };
  return (event) => {
    queue = queue.then(() => apply(event), () => apply(event));
    return queue;
  };
};
const handleEvent = makeHandler();
export const FmBusyState = async () => {
  return {
    event: async ({ event }) => handleEvent(event),
  };
};

export default {
  id: "fm.busy-state",
  server: FmBusyState,
  setup(ctx) {
    setupEventSubscription(ctx, handleEvent);
  },
};
EOF
    else
      cat >"$WT/.opencode/plugins/fm-busy-state.js" <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state comes from OpenCode's session.status events: busy and retry
// are active, idle is inactive. Scoping latches the first session that
// reports activity (the worker's main session - a subagent child session can
// only start while the main session is already busy) and ignores other
// sessions' status until the latched session settles, so a child's idle can
// never clear the worker's busy state. The session.idle touch stays the
// watcher's wake NOTIFICATION, never current-state truth. Every event applies
// strictly in emission order through one queue: the record serializes only on
// its lock, so a turn's terminal busy - emitted a millisecond before its idle,
// delivered without awaiting this hook - would otherwise be free to win the
// last write and leave an idle worker recorded busy.
import { execFile } from "node:child_process";
const notifyTurnEnd = $busy_notify_turnend;
const busyEvent = (state, event) =>
  new Promise((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "opencode-plugin", "--event", event,
    ], () => resolve());
  });
export const FmBusyState = async () => {
  let activeSession = null;
  let queue = Promise.resolve();
  const apply = async (event) => {
    if (event.type === "session.status") {
      const sessionID = event.properties.sessionID;
      const statusType = event.properties.status && event.properties.status.type;
      if (statusType === "busy" || statusType === "retry") {
        if (activeSession === null) activeSession = sessionID;
        if (sessionID === activeSession) await busyEvent("busy", "session-" + statusType);
        return;
      }
      if (statusType === "idle" && sessionID === activeSession) {
        activeSession = null;
        await busyEvent("idle", "session-status-idle");
      }
      return;
    }
    if (event.type === "session.idle") {
      if (event.properties.sessionID === activeSession) {
        activeSession = null;
        await busyEvent("idle", "session-idle");
      }
      if (notifyTurnEnd) {
        await new Promise((resolve) => {
          execFile("touch", ["$TURNEND"], () => resolve());
        });
      }
    }
  };
  return {
    event: ({ event }) => {
      queue = queue.then(() => apply(event), () => apply(event));
      return queue;
    },
  };
};
EOF
    fi
    exclude_path '.opencode/plugins/fm-busy-state.js'
    ;;
  pi | pi-signed)
    # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
    # loaded from inside the project (verified live), but an explicit -e path
    # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
    pi_stream_monitoring=false
    if [ "$(fm_busy_stream_seconds "${FM_STREAM_SILENT_MAX_SECS:-}")" -gt 0 ]; then
      pi_stream_version=$(fm_run_timed 5 "$PI_BIN" --version 2>/dev/null || true)
      if fm_busy_pi_stream_version_supported "$pi_stream_version"; then
        pi_stream_monitoring=true
      else
        echo "warning: $HARNESS model-stream observation unavailable for version ${pi_stream_version:-unknown}; verified version: 1.2.0; existing busy bound remains active" >&2
      fi
    fi
    cat >"$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate semantic busy-state events, turn-end notification, and - when this
// worker was launched with opted-in stream observation - foreground model-stream
// evidence; written by fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_settled" -> idle only when ctx.isIdle() confirms Pi will not
// continue automatically - auto-retries, auto-compaction retries, tool
// loops, and queued continuations all keep the run un-settled, and a settle
// that raced another extension's fresh run keeps state busy via isIdle().
// "turn_end" fires at every inner turn boundary (one LLM response plus its
// tool calls) and stays a wake NOTIFICATION touch for the watcher, never
// current-state truth.
import { execFile } from "node:child_process";
import { appendFileSync } from "node:fs";
const notifyTurnEnd = $busy_notify_turnend;
const streamMonitoring = $pi_stream_monitoring;
const excludeTools = "$EXCLUDE_TOOLS".split(",").filter(Boolean);
const excludeFile = $(perl -MJSON::PP -MEncode=decode_utf8 -e 'print encode_json(decode_utf8($ARGV[0]))' -- "$CONFIG/crew-exclude-tools");
const statusFile = $(perl -MJSON::PP -MEncode=decode_utf8 -e 'print encode_json(decode_utf8($ARGV[0]))' -- "$STATE/$ID.status");
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "pi-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  let checkedExclusions = false;
  let request = 0;
  let activeRequest = 0;
  let lastStreamProgress = -Infinity;
  let lastContent = "";
  let streamWrites: Promise<void> = Promise.resolve();
  const streamEvent = (operation: string, current: number) => {
    streamWrites = streamWrites.then(() => new Promise<void>((resolve) => {
      execFile("bash", [
        "-c", '. "\$1"; shift; fm_exec_timed 5 1 "\$@"', "fm-stream-observation",
        "$FM_ROOT/bin/fm-timeout-lib.sh", "$FM_ROOT/bin/fm-busy-event.sh",
        "stream", "$STATE_REAL", "$ID", operation,
        "--gen", "$BUSY_GEN", "--request", String(current),
      ], (error) => {
        if (error) console.error("Firstmate model-stream observation write failed; inspect worker instrumentation.");
        resolve();
      });
    }));
    return streamWrites;
  };
  const closeStream = () => {
    const current = activeRequest;
    activeRequest = 0;
    return current ? streamEvent("close", current) : streamWrites;
  };
  if (streamMonitoring) {
    // Foreground context excludes Pi's background provider/cache-warming calls.
    pi.on("context", () => {
      request = Math.max(request + 1, Date.now());
      activeRequest = request;
      lastStreamProgress = -Infinity;
      lastContent = "";
      return streamEvent("open", request);
    });
    pi.on("message_update", (event: any) => {
      if (!activeRequest || event.message?.role !== "assistant") return streamWrites;
      const now = Date.now();
      if (now - lastStreamProgress < 1000) return streamWrites;
      const content = (event.message.content || []).map((part: any) => {
        if (part.type === "text" && part.text) return ["text", part.text];
        if (part.type === "thinking" && (part.thinking || part.thinkingSignature)) {
          return ["thinking", part.thinking || "", part.thinkingSignature || ""];
        }
        if (part.type === "toolCall" && part.name) return ["toolCall", part.name, part.arguments];
        return null;
      }).filter(Boolean);
      if (!content.length) return streamWrites;
      const signature = JSON.stringify(content);
      if (signature === lastContent) return streamWrites;
      lastContent = signature;
      lastStreamProgress = now;
      return streamEvent("progress", activeRequest);
    });
    pi.on("message_end", (event: any) => {
      if (event.message?.role === "assistant") return closeStream();
    });
    pi.on("tool_execution_start", closeStream);
  }
  pi.on("agent_start", async () => {
    await busyEvent("busy", "agent-start");
    // Verify only this worker's registry, never connect servers from Firstmate.
    // Check before actions so the warning cannot supersede this turn's terminal status.
    if (!checkedExclusions && excludeTools.length) {
      const loaded = new Set(pi.getAllTools().map((tool: any) => tool.name));
      const unmatched = excludeTools.filter((name) => !loaded.has(name));
      if (unmatched.length) {
        appendFileSync(statusFile, "note [at=" + Math.floor(Date.now() / 1000) + "]: warning: " + excludeFile
          + " unmatched exclusion entries (unverified: absent from the worker's loaded-tool registry; excluded tools or unavailable servers cannot be verified): "
          + unmatched.join(", ") + "\n");
      }
      checkedExclusions = true;
    }
  });
  pi.on("agent_settled", async (_event: any, ctx: any) => {
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    await closeStream();
    return busyEvent("idle", "agent-settled");
  });
  pi.on("turn_end", () => { if (notifyTurnEnd) execFile("touch", ["$TURNEND"]); });
  // A native harness can make progress inside one Pi turn. This separate
  // marker prevents false wedge alarms without fabricating a completed turn.
  let lastProgress = 0;
  pi.events?.on?.("codex-native:progress", () => {
    const now = Date.now();
    if (now - lastProgress < 1000) return;
    lastProgress = now;
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "progress", "$STATE_REAL", "$ID", "--gen", "$BUSY_GEN",
    ]);
  });
}
EOF
    ;;
  omp)
    # Written OUTSIDE the worktree like Pi's, but for a different reason: omp
    # has no trust gate, yet its cwd-only extension auto-discovery would load a
    # worktree-resident copy a SECOND time next to the explicit -e (verified,
    # omp 18.1.11). Lives in state/, cleaned by teardown.
    cat >"$STATE/$ID.omp-ext.ts" <<EOF
// Firstmate semantic busy-state events + turn-end notification for omp (Oh My
// Pi); written by fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_end" -> idle only when event.willContinue is not true. omp has no
// agent_settled at all (verified, omp 18.1.2 and 18.1.11: zero occurrences in
// the binary); agent_end is its loop boundary and willContinue is the reliable
// "another loop is coming" flag, covering auto-retries, compaction retries,
// queued follow-ups, and a session_stop-forced continuation. ctx.isIdle() is
// deliberately NOT consulted: at a natural TUI agent_end it still reads false
// because session_stop is awaited before the session settles, so gating on it
// would leave every completed turn recorded busy. "turn_end" fires at every
// inner turn boundary and stays a wake NOTIFICATION touch for the watcher,
// never current-state truth.
import { execFile } from "node:child_process";
const notifyTurnEnd = $busy_notify_turnend;
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "omp-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_end", (event: any) => {
    if (event && event.willContinue === true) return;
    return busyEvent("idle", "agent-end");
  });
  pi.on("turn_end", () => { if (notifyTurnEnd) execFile("touch", ["$TURNEND"]); });
}
EOF
    ;;
  codex*)
    # Semantic busy-state source negotiation (bin/fm-busy-lib.sh owns the
    # probes and the evidence). Neither Codex path is usable on the
    # installed binary: a pane worker's turns are not observable through
    # the app-server protocol, and its lifecycle hooks did not fire for a
    # firstmate-launched worker. Codex therefore classifies unknown with
    # an explicit reason rather than falling back to idle, and no busy
    # wiring is installed. The turn-end NOTIFICATION marker still rides
    # the launch command via -c notify=[...] and __TURNEND__.
    ;;
  grok*)
    # Parent turn-end wiring only. A secondmate already classifies through the
    # rendered-tail fallback, and a parent turn-ended marker is not its signal.
    if [ "$KIND" != secondmate ]; then
    # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
    # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
    # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
    # after the folder is granted hook-trust, which is not automatic and which
    # firstmate cannot establish at launch without editing grok's own managed
    # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
    # always trusted and load on first launch with no gate. So the turn-end hook
    # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
    # guarded no-op for every non-firstmate grok session: it fires only when the
    # current workspace holds a .fm-grok-turnend token pointer that matches the
    # firstmate-owned hook registry. firstmate then drops that per-task pointer
    # (gitignored, like the other harnesses' worktree hook files).
    # Result: the hook is outside the worktree, needs no trust grant, and never
    # touches grok's managed config - only firstmate-owned files.
    GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
    GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
    mkdir -p "$GROK_AUTH_DIR"
    old_umask=$(umask)
    umask 077
    auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
    umask "$old_umask"
    printf '%s\n' "$TURNEND" >"$auth_file"
    printf '%s\n' "${auth_file##*/}" >"$STATE/$ID.grok-turnend-token"
    sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
    cat >"$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
    chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
    hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
    printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" >"$GROK_HOOKS_DIR/fm-turn-end.json"
    printf 'token=%s\n' "${auth_file##*/}" >"$WT/.fm-grok-turnend"
    exclude_path '.fm-grok-turnend'
    fi
    ;;
  muse*)
    # muse's turn lifecycle is neither a hook nor a launch flag: its plugin
    # engine (the only hook surface) is disabled in the default build, so
    # firstmate reads muse's own durable session event log instead
    # (bin/fm-busy-lib.sh owns the fold). That is a PULL
    # source with no writer, so nothing is armed and no record is seeded -
    # exactly the reason standalone Kimi is not armed either.
    # This sidecar is the whole binding: it pins the sessions root, the
    # workspace root that muse records in each log's metadata, this pane's
    # binding identity, and every matching main log that predates this pane.
    # The classifier then accepts only one new matching log, so it never
    # guesses between pane incarnations. Recording the resolved root here
    # also means a later change to XDG_DATA_HOME cannot silently re-point an
    # already-running task at a different log tree.
    MUSE_SESSIONS_ROOT="${MUSE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/muse/sessions"
    MUSE_BINDING_ID="$$.$RANDOM.$(date +%s)"
    rm -f "$STATE/$ID.muse-session-current"
    {
      printf 'sessions_root=%s\n' "$MUSE_SESSIONS_ROOT"
      printf 'workspace_root=%s\n' "$WT"
      printf 'binding_id=%s\n' "$MUSE_BINDING_ID"
      while IFS= read -r MUSE_PRIOR_LOG; do
        [ -n "$MUSE_PRIOR_LOG" ] && printf 'prior_log=%s\n' "$MUSE_PRIOR_LOG"
      done <<EOF
$(fm_busy_muse_matching_logs "$MUSE_SESSIONS_ROOT" "$WT" || true)
EOF
    } >"$STATE/$ID.muse-session"
    ;;
  cursor*)
    # Cursor's turn lifecycle is neither a hook nor a launch flag: it writes
    # its own durable per-conversation transcript and brackets every turn
    # there (bin/fm-busy-lib.sh owns the fold). Like muse that is a PULL
    # source with no writer, so nothing is armed and no record is seeded.
    # This sidecar is the whole binding. It pins the projects root and the
    # exact workspace path cursor records in each project's
    # .workspace-trusted, plus every conversation that already exists for
    # that workspace, so a relaunch into a reused worktree folds its OWN
    # conversation instead of its predecessor's. The classifier then accepts
    # only one remaining conversation and never guesses between incarnations.
    CURSOR_PROJECTS_ROOT="${CURSOR_PROJECTS_ROOT_OVERRIDE:-$HOME/.cursor/projects}"
    {
      printf 'projects_root=%s\n' "$CURSOR_PROJECTS_ROOT"
      printf 'workspace_root=%s\n' "$WT"
      if CURSOR_PRIOR_PROJECT=$(fm_busy_cursor_project_dir "$CURSOR_PROJECTS_ROOT" "$WT" 2>/dev/null); then
        for CURSOR_PRIOR_DIR in "$CURSOR_PRIOR_PROJECT"/agent-transcripts/*/; do
          [ -d "$CURSOR_PRIOR_DIR" ] || continue
          printf 'prior_conversation=%s\n' "$(basename -- "${CURSOR_PRIOR_DIR%/}")"
        done
      fi
    } >"$STATE/$ID.cursor-session"
    ;;
  kimi*)
    # Parent turn-end token only. Kimi is not armed, and a secondmate must
    # not publish a parent turn-ended marker.
    if [ "$KIND" != secondmate ]; then
    # Kimi's Stop hook is global, but it is inert unless cwd contains this
    # task's token pointer and the token resolves through Firstmate's private
    # registry. The installer above owns the format-preserving config edit and
    # the always-zero, silent hook script.
    KIMI_AUTH_DIR="$HOME/.kimi-code/fm-turn-end.d"
    old_umask=$(umask)
    umask 077
    auth_file=$(mktemp "$KIMI_AUTH_DIR/fm.XXXXXXXXXXXX")
    umask "$old_umask"
    printf '%s\n' "$TURNEND" >"$auth_file"
    printf '%s\n' "${auth_file##*/}" >"$STATE/$ID.kimi-turnend-token"
    printf 'token=%s\n' "${auth_file##*/}" >"$WT/.fm-kimi-turnend"
    exclude_path '.fm-kimi-turnend'
    fi
    ;;
  polytoken)
    # Semantic busy-state wiring (bin/fm-busy-lib.sh; bin/fm-polytoken-lib.sh
    # owns every generated artifact's content). Four pieces, all verified live:
    # the per-task config dir (mirrored operator config with the unattended
    # permission posture enforced - the one launch-time autonomy surface), the
    # worker role-contract facet in the worktree's `.polytoken/facets/` (the
    # project facet discovery layer), the generated no-argv busy writer in
    # state/ (hook handlers receive no argv, verified live), and the worktree
    # `.polytoken/hooks.json` binding the three busy events to that writer.
    # post_model_turn is deliberately NOT wired as a close: it fires per model
    # response - verified mid-turn, between tool phases - so closing on it
    # would flap the record idle while a long tool call still runs. The
    # worktree files stay out of git's view so they never block teardown's
    # dirty check or leak into a commit; an existing `.polytoken/hooks.json`
    # refused the spawn above, before any wiring or relaunch cleanup was armed,
    # rather than clobbering a project's own hook layer.
    # Gated on the canonical template like gemini and devin, because a raw
    # launch command never carries this wiring's flags or cwd contract.
    if [ "$RAW_LAUNCH" -eq 0 ]; then
      if ! fm_polytoken_write_config "$(fm_polytoken_config_dir "$STATE_REAL" "$ID")" \
        || ! fm_polytoken_write_facet "$WT" "$STATE_REAL/$ID.inbox" \
        || ! fm_polytoken_write_busy_script "$FM_ROOT" "$STATE_REAL" "$ID" "$BUSY_GEN" "$TURNEND" \
        || ! fm_polytoken_write_hooks "$WT" "$(fm_polytoken_busy_script "$STATE_REAL" "$ID")"; then
        echo "error: could not arm the polytoken busy-state wiring for $ID" >&2
        exit 1
      fi
      exclude_path '.polytoken/hooks.json'
      exclude_path '.polytoken/facets/firstmate-worker.md'
    fi
    ;;
  esac

# Per-task git hooksPath that strips AI commit trailers at the commit object.
# Installed for every kind, including secondmate, unless the home opts in to
# keeping trailers. Cursor and other non-Claude runtimes inject the trailer
# after the typed message, so the typed message is not the object. When
# installed, the pane receives this directory via GIT_CONFIG_* below, which
# overrides a project's husky core.hooksPath without rewriting it; the installer
# chains the previous hooks so they still run. Real secondmate
# homes are firstmate clones; a launch whose worktree is not git fails closed
# rather than shipping a runtime that cannot strip.
# A forge=external ship always gets this directory, because its pre-push
# wrapper carries the guard that keeps task branches off the shared origin; a
# home that keeps trailers gets a commit-msg wrapper that only chains.
GIT_HOOKS_DIR="$STATE_REAL/$ID.git-hooks"
GIT_HOOKS_INSTALLED=0
if [ "$EXTERNAL_REVIEW" = 1 ]; then
  PUSH_GUARD_FILE="$STATE_REAL/$ID.push-guard"
  guard_args=("$PUSH_GUARD_FILE" "$WT" "$BRANCH" "$(fm_ship_branch_prefix "$BRANCH" "$ID")")
  [ -z "$EXTERNAL_BACKUP_REMOTE" ] || guard_args+=("$EXTERNAL_BACKUP_REMOTE" "$EXTERNAL_BACKUP_PREFIX")
  strip_args=()
  [ "$KEEP_AI_TRAILERS" = 0 ] || strip_args=(--no-strip)
  { "$FM_ROOT/bin/fm-git-push-guard.sh" write "${guard_args[@]}" \
    && "$FM_ROOT/bin/fm-git-strip-ai-trailers.sh" install "${strip_args[@]+"${strip_args[@]}"}" \
      --push-guard "$PUSH_GUARD_FILE" "$GIT_HOOKS_DIR" "$WT"; } || {
    echo "error: could not install the external-review push guard hooks for $ID" >&2
    exit 1
  }
  GIT_HOOKS_INSTALLED=1
elif [ "$KEEP_AI_TRAILERS" = 0 ]; then
  "$FM_ROOT/bin/fm-git-strip-ai-trailers.sh" install "$GIT_HOOKS_DIR" "$WT" || {
    echo "error: could not install the AI-trailer strip hooks for $ID" >&2
    exit 1
  }
  GIT_HOOKS_INSTALLED=1
fi

# Delivery posture recorded in meta so fm-teardown's safety check and the
# validate/merge stages can branch on it. A ship task carries the explicit
# per-task decision validated above; a secondmate's posture is fixed; a scout
# records none at all, because its deliverable is a report rather than a merge
# (fm-teardown.sh defaults an absent mode to no-mistakes, and fm-promote.sh
# requires an explicit mode when a scout is promoted to a ship task).
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  : "${SECONDMATE_PROJECTS:=}"
elif [ "$KIND" = scout ]; then
  MODE=
  YOLO=
fi

# Resolve the optional default-off W3C trace context (bin/fm-trace-context-lib.sh,
# docs/configuration.md): the one carrier both recorded in meta and injected into
# the pane, so an observer reads exactly what the child receives. Empty only when
# disabled or on entropy/validation failure. Reuses this task's already-recorded
# value on relaunch; any other spawn roots a fresh trace, never adopting this
# process's own ambient TRACEPARENT, so each routed task is its own trace
# boundary even under a persistent supervisor. Never aborts the spawn and adds
# only the cost of reading a few bytes of entropy.
#
# The session-start path owns input resolution. Spawn consumes only the frozen
# home-session state and reuses it for the carrier and Secondmate launch prefix.
#
# A remote secondmate launch is the one case where this process is not the home
# that owns the task's identity: the parent home resolved and will record the
# carrier, and this host only delivers it. The validated --traceparent value
# then IS the decision, so the enablement snapshot handed to the new Secondmate
# agrees with the carrier it receives exactly as on the local path.
if [ "$TRACEPARENT_SET" -eq 1 ]; then
  SPAWN_TRACE_EFFECTIVE=on
  SPAWN_TRACEPARENT=$TRACEPARENT_ARG
else
  SPAWN_TRACE_EFFECTIVE=$(fm_trace_context_session_effective "$STATE/.trace-context-effective" "$(fm_harness_ancestry_pid 2>/dev/null || true)")
  if [ "$SPAWN_TRACE_EFFECTIVE" = on ]; then
    SPAWN_TRACEPARENT=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CONFIG" "$STATE/$ID.meta" || true)
  else
    SPAWN_TRACEPARENT=
  fi
fi

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
[ "$BACKEND" = t3code ] && META_WINDOW=$W
SPAWN_GEN="s$(date +%s).${BASHPID:-$$}.$RANDOM"
SPAWN_META_PATH="$STATE/$ID.meta"
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_TMP="$STATE/.$ID.meta.relaunch.${BASHPID:-$$}"
else
  SPAWN_META_TMP="$STATE/.$ID.meta.spawn.${BASHPID:-$$}"
  SPAWN_FRESH_COMMIT_PENDING=1
fi
SPAWN_META_PATH=$SPAWN_META_TMP
}
