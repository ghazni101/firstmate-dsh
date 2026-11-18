# shellcheck shell=bash
# harness binary and model resolution.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

secondmate_registry_value() {
  secondmate_registry_field "$DATA/secondmates.md" "$1" "$2"
}

resolve_kimi_binary() {
  local candidate dir fallback
  candidate=$(command -v kimi 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
    /*)
      printf '%s\n' "$candidate"
      return 0
      ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
      if [ -n "$dir" ]; then
        printf '%s/%s\n' "$dir" "$(basename "$candidate")"
        return 0
      fi
      ;;
    esac
  fi
  fallback="${HOME:-}/.kimi-code/bin/kimi"
  if [ -n "${HOME:-}" ] && [ -x "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  echo "error: kimi executable not found; searched PATH for 'kimi' and fallback '$fallback'" >&2
  return 1
}

resolve_muse_binary() {
  local candidate dir
  candidate=$(command -v muse 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
    /*)
      printf '%s\n' "$candidate"
      return 0
      ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
      if [ -n "$dir" ]; then
        printf '%s/%s\n' "$dir" "$(basename "$candidate")"
        return 0
      fi
      ;;
    esac
  fi
  echo "error: muse executable not found on PATH; install Muse Code or select a different verified harness" >&2
  return 1
}

resolve_rovo_binary() {
  local candidate dir fallback
  candidate=$(command -v rovo 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
    /*)
      printf '%s\n' "$candidate"
      return 0
      ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
      if [ -n "$dir" ]; then
        printf '%s/%s\n' "$dir" "$(basename "$candidate")"
        return 0
      fi
      ;;
    esac
  fi
  fallback="${HOME:-}/.local/bin/rovo"
  if [ -n "${HOME:-}" ] && [ -x "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  echo "error: rovo executable not found; searched PATH for 'rovo' and fallback '$fallback'" >&2
  return 1
}

# muse_credential_present: 0 when a launched muse pane can reach its provider
# without an interactive login. muse offers exactly two credential paths
# (verified, muse 0.1.0-R708.1): the META_API_KEY environment variable, which
# always takes priority, and a stored credential written by `muse auth set` or
# `muse login` into <config>/muse/auth.json. This is a PREFLIGHT rather than a
# rendered-screen check because an unauthenticated pane does not exit - it sits
# on an OAuth device-code prompt ("Sign in at this page ... Waiting for
# approval...") waiting for a human who is not there, which would look to
# supervision like a wedged worker rather than a missing credential.
muse_worker_meta_api_key_present() {
  local session worker_env
  if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
    case $'\n'"$LAUNCH_ENV_NAMES"$'\n' in
    *$'\nMETA_API_KEY\n'*) ;;
    *) return 1 ;;
    esac
  fi
  [ "$BACKEND" = tmux ] || return 1
  if [ -n "${TMUX:-}" ]; then
    fm_backend_source tmux >/dev/null 2>&1 || return 1
    session=$(fm_backend_tmux_own_session 2>/dev/null) || return 1
  else
    tmux has-session -t firstmate 2>/dev/null || return 1
    session=firstmate
  fi
  worker_env=$(tmux show-environment -t "$session" META_API_KEY 2>/dev/null) || return 1
  case "$worker_env" in
  META_API_KEY=?*) return 0 ;;
  esac
  return 1
}

muse_credential_present() {
  local auth=$1
  [ -s "$auth" ] || muse_worker_meta_api_key_present
}

# relaunch_resume_args: the launch arguments that keep a RELAUNCH bound to the
# agent session this endpoint's runtime already reports, so the runtime's own
# status authority survives the replacement.
#
# Why this exists, and why it is relaunch-only: some runtimes bind a pane's
# agent status to one session identity and ignore reports carrying another (the
# defect fixed 2026-09-21 for Herdr-backed Pi workers - docs/herdr-backend.md
# "Agent status authority and relaunch"). A fresh replacement session is
# exactly such a report, so the pane freezes at the previous agent's last
# reported state. Passing the SAME session back to the replacement keeps that
# identity, and the authority with it; no fresh spawn needs this because nothing
# is bound yet.
#
# The reference is read from the endpoint's own runtime record, never guessed
# from what looks recent, and only for an adapter with a verified resume form
# whose own agent label reported it
# (bin/fm-control-lib.sh's fm_control_relaunch_resume_flag owns both rules, and
# bin/backends/herdr.sh's fm_backend_herdr_pane_agent_session_ref owns the
# read). Every other combination prints nothing, so the launch stays exactly
# what it was before this existed: a fresh session.
#
# Prints the arguments with the single leading space that appends them to the
# launch line, so an empty result leaves every other launch byte-identical.
#
# Only the Herdr backend is asked: it is the one adapter whose runtime records a
# per-pane agent session, and on every other backend the pane carries no such
# identity for a replacement to preserve. An unreadable registration - no
# agent, a stale one, a malformed reference - degrades to that same
# fresh-session launch rather than refusing, because nothing here is a safety
# property; it preserves a display and supervision signal.
relaunch_resume_args() {  # <harness> <backend> <target>
  local harness=${1-} backend=${2-} target=${3-} identity agent ref flag
  [ "$backend" = herdr ] || return 0
  [ -n "$target" ] || return 0
  fm_backend_herdr_parse_target "$target" || return 0
  identity=$(fm_backend_herdr_pane_agent_session_ref "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE") || return 0
  agent=${identity%%$'\t'*}
  ref=${identity#*$'\t'}
  flag=$(fm_control_relaunch_resume_flag "$harness" "$agent") || return 0
  [ -n "$flag" ] && [ -n "$ref" ] || return 0
  printf -- ' %s %s' "$flag" "$(shell_quote "$ref")"
}

model_flag_for_harness() {
  local harness=$1 model=$2 oc_major=${3:-}
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
  opencode)
    # OpenCode 1.x takes the model as an interactive --model flag; 2.x removed
    # it, so there the model rides OPENCODE_CONFIG_CONTENT via
    # effort_flag_for_harness instead. The caller normalizes an undetected
    # (empty/unparseable) major to 1, so only a parsed major >= 2 omits --model.
    [ "$oc_major" = 1 ] || return 0
    printf -- '--model %s ' "$(shell_quote "$model")"
    ;;
  claude | codex | pi | pi-signed | grok | kimi | cursor | gemini | muse | rovo | omp | agy | devin | commandcode | cortex | kiro)
    printf -- '--model %s ' "$(shell_quote "$model")"
    ;;
  # polytoken encodes reasoning effort inside the model reference, so the
  # flag carries the composed reference fm_polytoken_model_ref validated
  # above, including the model-scoped reasoning level, never an unpinned
  # fallback to the bare model axis.
  polytoken)
    printf -- '--model %s ' "$(shell_quote "${POLYTOKEN_MODEL_REF:-$model}")"
    ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2 model=${3:-} oc_major=${4:-}
  if [ "$harness" != opencode ]; then
    [ -n "$effort" ] && [ "$effort" != default ] || return 0
  fi
  case "$harness" in
  claude)
    case "$effort" in
    low | medium | high | xhigh | max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
    esac
    ;;
  codex)
    # The installed codex config schema uses model_reasoning_effort. The
    # installed model catalog supports max for gpt-5.6-luna; keep that level
    # scoped to the model whose catalog entry advertises it.
    case "$effort" in
    low | medium | high | xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
    max)
      [ "$model" = gpt-5.6-luna ] || return 0
      printf -- '-c %s ' "$(shell_quote 'model_reasoning_effort="max"')"
      ;;
    esac
    ;;
  grok)
    # grok exposes both --effort and --reasoning-effort; firstmate's profile
    # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
    # only low|medium|high and rejects both xhigh and max, so omit those rather
    # than passing a known-bad value.
    case "$effort" in
    low | medium | high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
    esac
    ;;
  cortex)
    # cortex 1.1.104 --effort accepts minimal|low|medium|high|max (verified
    # from --help), so xhigh is omitted rather than passed as a known-bad
    # value (record-and-omit).
    case "$effort" in
    low | medium | high | max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
    esac
    ;;
  agy)
    # agy 1.2.0 --effort accepts exactly low|medium|high, so xhigh and max are
    # omitted rather than passed as known-bad values (record-and-omit).
    case "$effort" in
    low | medium | high) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
    esac
    ;;
  kiro)
    # kiro-cli 2.21.4 --effort accepts the full shared vocabulary
    # (low|medium|high|xhigh|max, per `kiro-cli chat --help`), so every level
    # passes through.
    case "$effort" in
    low | medium | high | xhigh | max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
    esac
    ;;
  commandcode)
    # Command Code's --effort set is model-scoped and an unknown value exits
    # the launch (verified, 1.74.1). DeepSeek V4.1 Flash accepts
    # off|low|high|max, so medium and xhigh are omitted there, and every other
    # model, whose set is unverified, keeps its own default (record-and-omit).
    case "$model:$effort" in
    deepseek/deepseek-v4.1-flash:low | deepseek/deepseek-v4.1-flash:high | deepseek/deepseek-v4.1-flash:max)
      printf -- '--effort %s ' "$(shell_quote "$effort")"
      ;;
    esac
    ;;
  pi | pi-signed)
    # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
    # its --thinking flag.
    case "$effort" in
    ultra)
      "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
      printf -- '--codex-effort %s ' "$(shell_quote ultra)"
      ;;
    low | medium | high | xhigh | max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
    esac
    ;;
  omp)
    # omp 18.1.11 --thinking accepts off|minimal|low|medium|high|xhigh|max|auto,
    # a superset of the shared vocabulary, so every level maps straight across.
    case "$effort" in
    low | medium | high | xhigh | max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
    esac
    ;;
  opencode)
    # opencode's interactive `opencode --prompt` launch has no effort flag
    # (`opencode run --variant` is a different, non-interactive mode), so the
    # reasoning axis rides the OPENCODE_CONFIG_CONTENT JSON the launch already
    # writes, keyed per-model as a variant. The variant is emitted only when the
    # resolved model's provider is known to expose that effort (`anthropic/*`:
    # high|max, `openai/*`: low|medium|high|xhigh); other providers, absent
    # effort, or out-of-family efforts omit it (record-and-omit, as codex and
    # grok do). Without a resolved model there is nothing to key to. The
    # fragment lands inside the launch's single-quoted assignment, so a literal
    # quote in the model id must close and reopen that quoting. The config SHAPE
    # is version-sensitive: 1.x carries the effort as agent.build.variant only
    # (the model still arrives via --model, config schema verified on 1.18.32);
    # 2.x dropped --model, so there the model is pinned both globally and on the
    # build agent alongside the variant (re-verified on 2.0.21). The caller
    # normalizes an undetected (empty/unparseable) major to 1, so only a parsed
    # major >= 2 takes the 2.x shape.
    [ -n "$model" ] && [ "$model" != default ] || return 0
    local model_json variant_fragment=
    model_json=$(json_escape "$model")
    model_json=${model_json//\'/\'\\\'\'}
    case "${model%%/*}:$effort" in
    anthropic:high | anthropic:max | openai:low | openai:medium | openai:high | openai:xhigh)
      variant_fragment=",\"variant\":\"$effort\""
      ;;
    esac
    if [ "$oc_major" = 1 ]; then
      # 1.x: the build agent carries model + variant only for a recognized
      # effort; with no variant the launch keeps its permission-only config.
      [ -n "$variant_fragment" ] || return 0
      printf ',"agent":{"build":{"model":"%s"%s}}' "$model_json" "$variant_fragment"
    else
      printf ',"model":"%s","agent":{"build":{"model":"%s"%s}}' "$model_json" "$model_json" "$variant_fragment"
    fi
    ;;
  muse)
    # muse 0.1.0-R708.1 --reasoning-effort accepts none|minimal|low|medium|
    # high|xhigh|ultra and defaults to high, so low..xhigh map straight across.
    # ultra is muse's max-CLASS level, so firstmate's max maps onto it - but
    # only ever as an EXPLICIT captain choice, never as a fallback, because
    # AGENTS.md section 4 forbids selecting max without captain preference and
    # the omitted effort here leaves muse on its own high default. muse's extra
    # none/minimal levels sit below firstmate's shared vocabulary and are
    # deliberately unreachable rather than remapped onto low.
    case "$effort" in
    low | medium | high | xhigh) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
    max) printf -- '--reasoning-effort %s ' "$(shell_quote ultra)" ;;
    esac
    ;;
    # rovo has no --effort flag on `run`; its effort mapping rides
    # --config-override, but that flag is single-value (see
    # rovo_config_override_flag below) so it is built there, merged with the
    # mandatory allowedExternalPaths grant, rather than here.
    # kimi provider catalogs expose supported and default effort values, but a
    # launch flag and mapping have not been live-verified; the requested axis
    # stays in task metadata but never reaches the launch command. Cursor encodes
    # effort in model ids such as cursor-grok-4.5-high, so it also receives no
    # separate effort flag.
  esac
}

spawn_validate_harness_binary() {

case "$LAUNCH" in
*__MUSEBIN__*)
  MUSE_BIN=$(resolve_muse_binary) || exit 1
  MUSE_CONFIG_HOME=$(resolve_directory_input XDG_CONFIG_HOME "${XDG_CONFIG_HOME:-${HOME:-}/.config}") || exit 1
  MUSE_DATA_HOME=$(resolve_directory_input XDG_DATA_HOME "${XDG_DATA_HOME:-${HOME:-}/.local/share}") || exit 1
  MUSE_AUTH_FILE="$MUSE_CONFIG_HOME/muse/auth.json"
  if ! muse_credential_present "$MUSE_AUTH_FILE"; then
    if [ -n "${META_API_KEY:-}" ]; then
      echo "error: muse has no worker-reachable credential; META_API_KEY is set for fm-spawn but cannot be proven present in the $BACKEND worker environment. Store the fleet credential at '$MUSE_AUTH_FILE' with 'muse login' or 'muse auth set --api-key-stdin'. The secret will not be copied into the launch command." >&2
    else
      echo "error: muse has no worker-reachable credential; META_API_KEY cannot be proven present in the $BACKEND worker environment and '$MUSE_AUTH_FILE' is absent or empty. Store the fleet credential with 'muse login' or 'muse auth set --api-key-stdin'." >&2
    fi
    exit 1
  fi
  LAUNCH=${LAUNCH//__MUSEBIN__/$(shell_quote "$MUSE_BIN")}
  LAUNCH=${LAUNCH//__MUSECONFIG__/$(shell_quote "$MUSE_CONFIG_HOME")}
  LAUNCH=${LAUNCH//__MUSEDATA__/$(shell_quote "$MUSE_DATA_HOME")}
  ;;
esac

case "$LAUNCH" in
*__KIMIBIN__*)
  KIMI_BIN=$(resolve_kimi_binary) || exit 1
  LAUNCH=${LAUNCH//__KIMIBIN__/$(shell_quote "$KIMI_BIN")}
  fm_backend_visible_capture_supported "$BACKEND" || {
    echo "error: refusing Kimi spawn because backend '$BACKEND' has no verified viewport-bounded capture; Kimi 2.0.0 gates a fresh worktree on a trust dialog that can only be answered and confirmed cleared from a scrollback-free read of the live pane" >&2
    exit 1
  }
  if [ "$KIND" != secondmate ]; then
    "$FM_ROOT/bin/fm-kimi-turnend-hook.sh" install || {
      echo "error: refusing Kimi spawn because the global turn-end hook could not be installed safely" >&2
      exit 1
    }
  fi
  ;;
esac

case "$LAUNCH" in
*__ROVOBIN__*)
  ROVO_BIN=$(resolve_rovo_binary) || exit 1
  LAUNCH=${LAUNCH//__ROVOBIN__/$(shell_quote "$ROVO_BIN")}
  ;;
esac

}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# rovo confines every file-tool operation (open_files, create_file, grep, ...)
# to its worktree by default; toolPermissions.allowedExternalPaths
# (~/.rovo/config.yml) is the only lift, and it must be granted at launch
# through --config-override since there is no per-session escalation once
# the process is running. rovo's bash tool is NOT covered by this grant and
# stays confined to the worktree regardless (confirmed live) - the standard
# crewmate flow's literal `echo ... >> status file` bash line therefore still
# fails under rovo, but the worker recovers by falling back to its own file
# tools for the same append (confirmed live), which the grant below does cover.
# --config-override itself is single-value (a second occurrence silently
# discards the first, confirmed live), so this is the ONE place that must
# also fold in agent.efficiencyLevel when a supported effort was requested.
# Granted paths are real (symlink-resolved) directories/files under this
# task's home, matching BRIEF_REAL's own resolution: the brief dir (covers
# brief.md/launch-brief.md/report.md), the steering inbox directory (covers
# every steer and its handled/ acknowledgement), and the status file itself.
rovo_config_override_flag() {
  local effort=$1 data_dir=$2 state_dir=$3 id=$4
  local data_real state_real agent_json paths_json config_json
  data_real=$(cd "$data_dir" && pwd -P) || return 1
  state_real=$(cd "$state_dir" && pwd -P) || return 1
  agent_json=
  case "$effort" in
  low | medium | high | max) agent_json="\"agent\":{\"efficiencyLevel\":\"$(json_escape "$effort")\"}," ;;
  esac
  paths_json=$(printf '"%s","%s","%s"' \
    "$(json_escape "$data_real/$id")" \
    "$(json_escape "$state_real/$id.inbox")" \
    "$(json_escape "$state_real/$id.status")")
  config_json="{${agent_json}\"toolPermissions\":{\"allowedExternalPaths\":[$paths_json]}}"
  printf -- '--config-override %s ' "$(shell_quote "$config_json")"
}
