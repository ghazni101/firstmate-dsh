# shellcheck shell=bash
# spawn preflight, secondmate dispatch, and delivery rigor.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

# Claude Code path-checks the Read/Glob/Grep file tools (and an Edit's
# mandatory prior Read) against its working directories: the pane cwd plus
# every --add-dir. Since 2.1.257 the first outside read in --permission-mode
# auto parks the pane on a one-time interactive question instead of reading,
# and any "Block" answer on the machine lands
# permissions.blockReadsOutsideWorkingDirectories in user settings, which
# then refuses the same reads under --dangerously-skip-permissions too. A
# Firstmate worker always reads outside its cwd - a secondmate's steers live
# in the PARENT home's state/<id>.inbox, and a ship or scout worker's launch
# record, steers, and brief live in this home's state/operational-inbox,
# state/<id>.inbox, and data/<id>, plus the code root's .agents/skills so the
# worker can read the skill file the launch role names as the fallback for a
# session where the skill name does not resolve - so every Claude launch,
# fresh spawn and relaunch, in both permission modes, grants exactly those
# task-channel directories. The skills grant is that directory, not the
# checkout root, so the grant does not open the whole checkout. Paths resolve
# the way rovo_config_override_flag resolves them
# (real paths under the task's home). The state channel dirs are created
# lazily by their first record, so they are made here: an --add-dir naming a
# directory that does not exist at launch would leave the channel created
# later outside the grant. The grant never covers the whole state/ (watcher
# internals live there) or anything wider.
claude_add_dirs_flag() {  # <kind> <state-dir> <data-dir> <code-root> <task-id>
  local kind=$1 state_dir=$2 data_dir=$3 code_root=$4 id=$5
  local state_real data_real root_real out='' d
  local dirs=()
  state_real=$(cd "$state_dir" && pwd -P) || return 1
  case "$kind" in
  secondmate)
    mkdir -p "$state_real/$id.inbox/handled" || return 1
    dirs=("$state_real/$id.inbox")
    ;;
  *)
    data_real=$(cd "$data_dir" && pwd -P) || return 1
    root_real=$(cd "$code_root" && pwd -P) || return 1
    [ -d "$root_real/.agents/skills" ] || return 1
    mkdir -p "$state_real/operational-inbox" "$state_real/$id.inbox/handled" "$data_real/$id" || return 1
    dirs=("$state_real/operational-inbox" "$state_real/$id.inbox" "$data_real/$id" "$root_real/.agents/skills")
    ;;
  esac
  for d in "${dirs[@]}"; do
    out="$out--add-dir $(shell_quote "$d") "
  done
  printf '%s' "$out"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || {
    echo "error: firstmate home does not exist or is not a directory: $path" >&2
    return 1
  }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
  projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
  *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
  "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

spawn_validate_secondmate_dispatch() {

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && { [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; }; then
    fm_backlog_record_present "$STATE/$ID.meta" "task record" "$STATE" || {
      echo "error: secondmate task record is unsafe: $FM_BACKLOG_TRANSITION_ERROR" >&2
      exit 1
    }
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || {
    echo "error: no firstmate home supplied or registered for $ID" >&2
    exit 1
  }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  if [ -e "$DATA/secondmates.md" ] || [ -L "$DATA/secondmates.md" ]; then
    if ! secondmate_registry_validate_bindings "$DATA/secondmates.md" resolve_path "$ID" "$FIRSTMATE_HOME"; then
      echo "error: $SECONDMATE_REGISTRY_ERROR" >&2
      exit 1
    fi
    SECONDMATE_PROJECTS=$SECONDMATE_REGISTRY_MATCH_PROJECTS
  fi
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
# repo and already holds the commit. The same guarded path can reconcile a clean
# divergence already present at the target; a dirty, uniquely diverged, or
# wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  # On a remote host this spawn is the host-local leg of a launch whose parent has
  # already synced the home to ITS primary commit, and $FM_ROOT here is only that
  # host's own Firstmate copy; syncing again would target the wrong checkout, so
  # the caller turns this step off (bin/fm-remote-secondmate-control.sh).
  if [ "${FM_SKIP_SECONDMATE_SYNC:-0}" = 1 ]; then
    :
  elif sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes "$ID" "$STATE" 2>&1 || true)
    case "$sm_ff_out" in
    *': skipped:'*)
      sm_ff_line=$(first_line "$sm_ff_out")
      sm_ff_prefix="secondmate $ID: skipped: "
      sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
      echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
      ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  mkdir -p "$PROJ_ABS/state" || {
    echo "error: could not create secondmate state directory for $PROJ_ABS" >&2
    exit 1
  }
  if [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ]; then
    CONFIG_INHERIT_LOCK=$(fm_config_inherit_lock_path "$PROJ_ABS") || {
      echo "error: could not resolve secondmate inheritance lock for $PROJ_ABS" >&2
      exit 1
    }
    if ! fm_lock_acquire_wait "$CONFIG_INHERIT_LOCK"; then
      echo "error: could not acquire secondmate inheritance lock for $PROJ_ABS" >&2
      exit 1
    fi
    CONFIG_INHERIT_LOCK_HELD=1
    # Inheritance propagation: push the primary-authoritative live-safe local inheritance
    # surface into this secondmate home (fm-config-inherit-lib.sh).
    FM_CONFIG_INHERIT_LIVE=1 \
      propagate_secondmate_inheritance "$FM_HOME" "$PROJ_ABS" "$CONFIG" "$DATA" ||
      echo "warning: secondmate $ID inheritance failed for $PROJ_ABS" >&2
  fi
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" != secondmate ] &&
  git -C "$PROJ_ABS" rev-parse --git-dir >/dev/null 2>&1 &&
  ! git -C "$PROJ_ABS" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  echo "error: spawn refused: project $PROJ_ABS has no commit yet (unborn HEAD), so there is nothing to branch a worktree from; make one commit in the project, for example 'git -C $PROJ_ABS commit --allow-empty -m \"chore: initial commit\"', then spawn again" >&2
  exit 1
fi
# Project capacity admission (bin/fm-project-capacity-lib.sh owns the
# declaration, what holds a place, and why this is race-safe). A fresh worker
# for a project whose declared capacity is already held is deferred here, before
# any brief render, endpoint, worktree, record, or backlog move exists, so the
# deferral leaves the task exactly as queued as it was. A relaunch replaces a
# worker that already holds a place, and a secondmate is not a worker.
SPAWN_PROJECT_CAPACITY=
SPAWN_PROJECT_CAPACITY_ANY=
if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" != secondmate ]; then
  SPAWN_CAPACITY_CONFIG=$(fm_project_capacity_config_dir "$FM_HOME" "$CONFIG") || {
    echo "error: could not resolve the root Firstmate home that declares project capacity for $PROJ_ABS" >&2
    exit 1
  }
  if ! fm_project_capacity_lookup "$SPAWN_CAPACITY_CONFIG" "$(basename "$PROJ_ABS")"; then
    echo "error: spawn refused: the project capacity declaration is unreadable ($FM_PROJECT_CAPACITY_ERROR); fix it so the captain's worker limits are known (docs/configuration.md \"Project capacity\")" >&2
    exit 1
  fi
  SPAWN_PROJECT_CAPACITY=$FM_PROJECT_CAPACITY
  SPAWN_PROJECT_CAPACITY_ANY=$FM_PROJECT_CAPACITY_ANY
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" != secondmate ] &&
  { [ "$BACKEND" != orca ] || [ -n "$SPAWN_PROJECT_CAPACITY_ANY" ]; }; then
  SPAWN_TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$PROJ_ABS") || {
    echo "error: could not resolve the shared Treehouse project lock for $PROJ_ABS" >&2
    exit 1
  }
  if ! fm_lock_try_acquire "$SPAWN_TREEHOUSE_PROJECT_LOCK"; then
    if [ "$BACKEND" = orca ]; then
      echo "error: another spawn or cleanup holds the shared project lock for $PROJ_ABS; refusing to race its capacity admission" >&2
    else
      echo "error: another Treehouse slot allocation or return is in progress for $PROJ_ABS; refusing to race it" >&2
    fi
    exit 1
  fi
  SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=1
fi
if [ -n "$SPAWN_PROJECT_CAPACITY" ]; then
  if ! fm_project_capacity_occupants "$SPAWN_TREEHOUSE_PROJECT_LOCK" "$PROJ_ABS" "$STATE" "$ID"; then
    echo "error: spawn refused: project $(basename "$PROJ_ABS") declares a capacity of $SPAWN_PROJECT_CAPACITY, but this machine's task records cannot all be read to count it ($FM_PROJECT_CAPACITY_ERROR)" >&2
    exit 1
  fi
  if [ "$FM_PROJECT_CAPACITY_OCCUPANTS" -ge "$SPAWN_PROJECT_CAPACITY" ]; then
    echo "deferred: project $(basename "$PROJ_ABS") admits $SPAWN_PROJECT_CAPACITY worker(s) at once on this machine ($FM_PROJECT_CAPACITY_FILE) and $FM_PROJECT_CAPACITY_OCCUPANTS already hold a place ($FM_PROJECT_CAPACITY_OCCUPANT_IDS); task $ID was not launched and its backlog item stays queued - dispatch it again once one of them records its ready PR or is cleaned up" >&2
    exit "$FM_PROJECT_CAPACITY_DEFER_EXIT"
  fi
fi
# Lane capacity admission (opt-in; bin/fm-capacity.sh owns the verdict and
# --spawn-gate exits 0 unless config/lane-capacity declares admit-spawns). A
# fresh ship or scout asks it under one machine-wide lane-admission lock in the
# local root home, held until the task record is published, so two spawns on
# this machine can never take the same open lane. A deferral leaves the task
# exactly as queued as it was, like a project-capacity deferral.
if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" != secondmate ] && [ -e "$CONFIG/lane-capacity" ] &&
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
    "$SCRIPT_DIR/fm-capacity.sh" --spawn-gate-enabled </dev/null 2>/dev/null; then
  SPAWN_LANE_ROOT=$(fm_firstmate_root_home "$FM_HOME") || {
    echo "error: could not resolve the root Firstmate home that holds the lane admission lock for $FM_HOME" >&2
    exit 1
  }
  SPAWN_LANE_ADMISSION_LOCK="$SPAWN_LANE_ROOT/state/.lane-admission.lock"
  if ! fm_lock_acquire_wait_max "$SPAWN_LANE_ADMISSION_LOCK" 120; then
    echo "deferred: another spawn on this machine held the lane admission lock for 120 s; task $ID was not launched and its backlog item stays queued - dispatch it again" >&2
    exit "$FM_PROJECT_CAPACITY_DEFER_EXIT"
  fi
  SPAWN_LANE_ADMISSION_LOCK_HELD=1
  SPAWN_LANE_RC=0
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
    "$SCRIPT_DIR/fm-capacity.sh" --spawn-gate </dev/null || SPAWN_LANE_RC=$?
  case "$SPAWN_LANE_RC" in
    0) ;;
    75)
      echo "deferred: task $ID was not launched and its backlog item stays queued - dispatch it again once this machine's lane capacity admits another lane" >&2
      exit "$FM_PROJECT_CAPACITY_DEFER_EXIT"
      ;;
    *)
      echo "error: spawn refused: this home's lane capacity cannot be read (bin/fm-capacity.sh --spawn-gate exited $SPAWN_LANE_RC); fix config/lane-capacity so the captain's limits are known (docs/configuration.md \"Lane capacity\")" >&2
      exit 1
      ;;
  esac
fi
[ -f "$BRIEF" ] || {
  echo "error: task $ID has no brief at inaccessible data path $BRIEF" >&2
  exit 1
}
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  HERDR_LIFECYCLE_BRIEF_GUARD=$(fm_config_source_present "$CONFIG/herdr-lifecycle-spawn-guard") || exit 1
  if [ "$HERDR_LIFECYCLE_BRIEF_GUARD" = 1 ]; then
    HERDR_LIFECYCLE_COMMAND=$(perl -ne '
      if (m{(bin/fm-herdr-lab\.sh|(?<![[:alnum:]_])herdr[[:space:]]+(?:session|server)[[:space:]]+(?:start|stop|delete|restart|reload-config|live-handoff)(?![[:alnum:]_-]))}) { print $1; exit }
    ' -- "$BRIEF")
    if [ -n "$HERDR_LIFECYCLE_COMMAND" ] && ! grep -Fq '# Herdr isolation - HARD SAFETY CONTRACT' "$BRIEF"; then
      echo "error: $BRIEF names the Herdr lifecycle command \`$HERDR_LIFECYCLE_COMMAND\` but lacks the Herdr isolation contract; regenerate it with bin/fm-brief.sh --herdr-lab" >&2
      exit 1
    fi
  fi
  if fm_brief_task_placeholders_present "$BRIEF"; then
    echo "error: $BRIEF still contains {TASK} or {FIRSTMATE_SPEC}; fill ## Captain's intent and ## Firstmate spec before spawn" >&2
    exit 1
  fi
  if ! fm_brief_task_content_valid "$BRIEF"; then
    echo "error: $BRIEF must contain nonempty ## Captain's intent and ## Firstmate spec subsections (or a nonempty legacy # Task body) before spawn" >&2
    exit 1
  fi
  if ADDRESS_LINE=$(fm_brief_intent_address_line "$BRIEF"); then
    echo "error: $BRIEF ## Captain's intent has an operator-address line: $ADDRESS_LINE; write the captain's actual words without a Captain label or address before spawn, since the heading already records provenance" >&2
    exit 1
  fi
  if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
    if fm_brief_task_heading_present "$BRIEF" "## Captain's intent"; then
      CAPTAIN_INTENT=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent")
    else
      LEGACY_TASK_BODY=$(fm_brief_heading_body "$BRIEF" "# Task")
      CAPTAIN_INTENT=$(fm_brief_marked_captain_words "$LEGACY_TASK_BODY")
      if [ -z "$(printf '%s' "$CAPTAIN_INTENT" | tr -d '[:space:]')" ]; then
        echo "error: legacy mixed # Task brief has no provenance-marked captain words for no-mistakes --intent; add [captain] lines or migrate to ## Captain's intent and ## Firstmate spec" >&2
        exit 1
      fi
    fi
  fi
  if [ "$RELAUNCH" -eq 1 ]; then
    BASE_BRANCH=$(fm_meta_get "$RELAUNCH_META" base_branch)
  elif [ "$BASE_BRANCH_SET" -eq 1 ]; then
    [ -n "$BASE_BRANCH" ] || {
      echo "error: --base-branch requires a branch name" >&2
      exit 1
    }
    BASE_FORGE=$("$FM_ROOT/bin/fm-project-mode.sh" --forge "$(basename "$PROJ_ABS")") || exit 1
    fm_base_branch_valid "$BASE_BRANCH" "$MODE" "${BASE_FORGE:-none}" "fm-spawn.sh --base-branch" || exit 1
    if ! fm_brief_base_branches "$BRIEF" >/dev/null || fm_brief_base_branches "$BRIEF" | grep -vxF -- "$BASE_BRANCH" >/dev/null; then
      echo "error: $BRIEF must record Base branch: $BASE_BRANCH and no other Base branch line to spawn with --base-branch $BASE_BRANCH; scaffold it with bin/fm-brief.sh --base-branch $BASE_BRANCH" >&2
      exit 1
    fi
  elif fm_brief_base_branches "$BRIEF" >/dev/null; then
    echo "error: $BRIEF records a Base branch line but the spawn has no --base-branch; pass the brief's base with --base-branch or re-scaffold the brief without one" >&2
    exit 1
  fi
  # Use the existing launch-brief overlay for every worker kind, including
  # pre-scope briefs and relaunches. Charters never enter this worker path.
  SOURCE_BRIEF=$BRIEF
  BRIEF="$DATA/$ID/launch-brief.md"
  BRIEF_TMP="$DATA/$ID/.launch-brief.md.${BASHPID:-$$}"
  {
    fm_brief_worker_role "$STATE" "$ID" "$FM_ROOT" &&
      printf '\n' &&
      cat "$SOURCE_BRIEF" &&
      if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
        fm_brief_intent_overlay "$CAPTAIN_INTENT"
      fi
  } >"$BRIEF_TMP" || {
    rm -f -- "$BRIEF_TMP"
    echo "error: could not render current launch contract for $SOURCE_BRIEF" >&2
    exit 1
  }
  if ! mv "$BRIEF_TMP" "$BRIEF"; then
    rm -f -- "$BRIEF_TMP"
    echo "error: could not publish current launch contract for $SOURCE_BRIEF" >&2
    exit 1
  fi
fi

}

delivery_rigor_rank() { # <mode> -> 3 (most rigor) .. 1 (least); 0 = not a task mode
  case "$1" in
  no-mistakes) echo 3 ;;
  direct-PR) echo 2 ;;
  local-only) echo 1 ;;
  *) echo 0 ;;
  esac
}

spawn_check_delivery_agreement() {

# Brief/spawn delivery agreement, checked before any endpoint exists.
# fm-brief.sh records a ship brief's mode as a fixed "Delivery contract: mode=<mode>"
# line, with " forge=<forge>" appended on a bound forge. A spawn that disagrees
# would launch a worker whose instructions and whose recorded task delivery
# differ, which is the exact drift this contract prevents.
if [ "$KIND" = ship ]; then
  PROJ_NAME=$(basename "$PROJ_ABS")
  # The parser's own refusal reaches the operator here rather than being
  # discarded: an entry it refuses (an unknown forge token, or a forge on
  # local-only) resolves to no posture at all, and launching on the silent
  # default is how a mistyped forge would hand a Gerrit project the
  # pull-request contract.
  if ! STANDING_FORGE=$("$FM_ROOT/bin/fm-project-mode.sh" --forge "$PROJ_NAME" 2>/dev/null); then
    "$FM_ROOT/bin/fm-project-mode.sh" --forge "$PROJ_NAME" >/dev/null || true
    echo "error: $ID cannot launch: the registry entry for $PROJ_NAME does not resolve to a delivery posture (see the refusal above); correct data/projects.md and spawn again" >&2
    exit 1
  fi
  [ -n "$STANDING_FORGE" ] || STANDING_FORGE=none
  STANDING_MODE=$("$FM_ROOT/bin/fm-project-mode.sh" --raw "$PROJ_NAME" 2>/dev/null | cut -d' ' -f1) || STANDING_MODE=
  BRIEF_MODE=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  BRIEF_FORGE=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]forge=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  [ -n "$BRIEF_FORGE" ] || BRIEF_FORGE=none
  BRIEF_BRANCH=$(sed -n 's/^Ship branch: //p' "$BRIEF" | head -n 1)
  if [ -n "$BRIEF_BRANCH" ]; then
    [ "$BRIEF_BRANCH" = "$BRANCH" ] || {
      echo "error: branch mismatch for $ID: the brief says branch=$BRIEF_BRANCH but this spawn selected branch=$BRANCH" >&2
      exit 1
    }
  elif [ "$BRANCH" != "fm/$ID" ]; then
    # A relaunch's branch comes from the meta record (--branch-prefix is refused
    # there), so a promoted scout whose brief never carried a Ship branch line
    # must relaunch on that recorded branch rather than be refused.
    if [ "$RELAUNCH" -eq 1 ]; then
      echo "warning: $BRIEF records no ship branch; relaunching on the task's recorded branch $BRANCH" >&2
    else
      echo "error: $BRIEF records no ship branch; regenerate it with --branch-prefix before spawning $BRANCH" >&2
      exit 1
    fi
  else
    echo "warning: $BRIEF records no ship branch; defaulting to legacy branch $BRANCH" >&2
  fi
  if [ -z "$BRIEF_MODE" ]; then
    echo "warning: $BRIEF records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode $MODE - confirm its definition of done matches" >&2
  elif [ "$BRIEF_MODE" != "$MODE" ]; then
    echo "error: delivery mismatch for $ID: the brief says mode=$BRIEF_MODE but this spawn passed --mode $MODE; correct the flag or re-scaffold the brief so the worker's instructions and the task record agree" >&2
    exit 1
  fi
  # A firstmate-repository contribution records its one-task publication consent
  # as an upstream-consent= token on that same line; like mode and forge, the
  # brief and the spawn flag must agree so the worker's contract and the task
  # record carry the same authority.
  BRIEF_CONSENT=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]upstream-consent=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  if [ "$BRIEF_CONSENT" != "$UPSTREAM_CONSENT" ]; then
    echo "error: upstream-consent mismatch for $ID: $BRIEF records upstream-consent=${BRIEF_CONSENT:-none} but this spawn passed ${UPSTREAM_CONSENT:-none}; correct the flag or re-scaffold the brief so the worker's contract and the task record agree" >&2
    exit 1
  fi
  # The registered forge is the captain's confirmed binding (bin/fm-project-mode.sh)
  # and is never inferred here from a remote, host, or protocol. A brief that
  # disagrees with it would tell the worker to open a pull request a Gerrit
  # server does not have, or to publish a change to a forge that is not Gerrit.
  if [ "$BRIEF_FORGE" != "$STANDING_FORGE" ]; then
    if [ "$STANDING_FORGE" = none ]; then
      forge_scaffold="fm-brief.sh $ID $PROJ_NAME --mode $MODE"
    else
      forge_scaffold="fm-brief.sh $ID $PROJ_NAME --mode $MODE --forge $STANDING_FORGE"
    fi
    echo "error: forge mismatch for $ID: $PROJ_NAME is registered forge=$STANDING_FORGE but $SOURCE_BRIEF records forge=$BRIEF_FORGE; keep the filled ## Captain's intent and ## Firstmate spec bodies, remove $SOURCE_BRIEF, re-scaffold it with $forge_scaffold, then re-fill those two subsections, so the worker's publication matches the project's forge" >&2
    exit 1
  fi
  # The registered PR-text binding is read the same way: a brief that disagrees
  # would hand the pipeline's pr step the text a person owns, or the worker text
  # the pipeline owns. direct-PR already leaves the text to the worker, so a
  # conditional-policy project's direct-PR task expects none.
  if ! STANDING_PR=$("$FM_ROOT/bin/fm-project-mode.sh" --pr "$PROJ_NAME" 2>/dev/null); then
    "$FM_ROOT/bin/fm-project-mode.sh" --pr "$PROJ_NAME" >/dev/null || true
    echo "error: $ID cannot launch: the registry entry for $PROJ_NAME does not resolve to a delivery posture (see the refusal above); correct data/projects.md and spawn again" >&2
    exit 1
  fi
  [ -n "$STANDING_PR" ] || STANDING_PR=auto
  [ "$MODE" = no-mistakes ] || STANDING_PR=auto
  BRIEF_PR=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]pr=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  [ -n "$BRIEF_PR" ] || BRIEF_PR=auto
  if [ "$BRIEF_PR" != "$STANDING_PR" ]; then
    pr_scaffold="fm-brief.sh $ID $PROJ_NAME --mode $MODE"
    [ "$STANDING_FORGE" = none ] || pr_scaffold="$pr_scaffold --forge $STANDING_FORGE"
    [ "$STANDING_PR" = auto ] || pr_scaffold="$pr_scaffold --pr $STANDING_PR"
    echo "error: PR-text mismatch for $ID: $PROJ_NAME is registered pr=$STANDING_PR but $SOURCE_BRIEF records pr=$BRIEF_PR; keep the filled ## Captain's intent and ## Firstmate spec bodies, remove $SOURCE_BRIEF, re-scaffold it with $pr_scaffold, then re-fill those two subsections, so the worker owns the PR text exactly when the project says so" >&2
    exit 1
  fi
  # Merge authority on a Gerrit forge is refused rather than quietly dropped, on
  # the captain's decision of 2026-09-15: a Code-Review+2 is a positive
  # attributed claim that a named human approved, and firstmate must not
  # manufacture one.
  if [ "$STANDING_FORGE" = gerrit ] && [ "$YOLO" = on ]; then
    echo "error: --yolo on is refused for $ID: $PROJ_NAME is registered forge=gerrit, where yolo is inactive because a Code-Review+2 is a positive attributed claim that a named human approved and firstmate must not manufacture one (captain's decision 2026-09-15); spawn with --yolo off" >&2
    exit 1
  fi
  # An external review tool uploads its own snapshot, so this task must never
  # push a task branch to the shared origin (docs/external-review-forge.md).
  # Every protection the captain configured is validated before any endpoint
  # exists, so a worker never launches without it.
  if [ "$STANDING_FORGE" = external ]; then
    if [ "$YOLO" = on ]; then
      echo "error: --yolo on is refused for $ID: $PROJ_NAME is registered forge=external, where firstmate can neither observe nor perform the review tool's approval or merge; spawn with --yolo off" >&2
      exit 1
    fi
    fm_external_review_adapter_body "$CONFIG" >/dev/null || exit 1
    fm_external_review_backup "$CONFIG" || exit 1
    EXTERNAL_REVIEW=1
    EXTERNAL_BACKUP_REMOTE=$FM_REVIEW_BACKUP_REMOTE
    EXTERNAL_BACKUP_PREFIX=$FM_REVIEW_BACKUP_PREFIX
    if [ -n "$EXTERNAL_BACKUP_REMOTE" ]; then
      fm_external_review_prefix_disjoint "$EXTERNAL_BACKUP_PREFIX" "$(fm_ship_branch_prefix "$BRANCH" "$ID")" || exit 1
      backup_urls=$(fm_external_review_remote_urls "$PROJ_ABS" "$EXTERNAL_BACKUP_REMOTE")
      if [ -z "$backup_urls" ]; then
        echo "error: $ID cannot launch: config/external-review-backup names the remote $EXTERNAL_BACKUP_REMOTE, which $PROJ_ABS does not have; add it with git remote add, or remove the file to ship without a backup" >&2
        exit 1
      fi
      shared_urls=$(fm_external_review_remote_urls "$PROJ_ABS" origin)
      if [ -n "$shared_urls" ] && printf '%s\n' "$backup_urls" | grep -Fqx -f <(printf '%s\n' "$shared_urls"); then
        echo "error: $ID cannot launch: the backup remote $EXTERNAL_BACKUP_REMOTE points at the project's shared origin; a durable copy must go to storage only the captain controls" >&2
        exit 1
      fi
    fi
  fi
  # Self-repository publication gate (bin/fm-role-lib.sh): a ship task whose
  # project is firstmate's own repository may launch a publishing contract only
  # under an explicit grant - this home's maintainer scope in
  # config/firstmate-role, or this one task's recorded upstream consent. Every
  # other project passes through unchanged; local-only publishes nothing and
  # never reaches this gate.
  if [ "$MODE" != local-only ]; then
    gate_rc=0
    fm_role_gate_self_publish "$FM_HOME" "$CONFIG" "$PROJ_ABS" "$FM_ROOT" "$UPSTREAM_CONSENT" || gate_rc=$?
    case $gate_rc in
    0 | 2) ;;
    *)
      echo "error: spawn refused for $ID: $FM_ROLE_PUB_DENIAL" >&2
      echo "error: to let this home publish to ${FM_ROLE_PUB_TARGET:-that repository}, write 'maintainer ${FM_ROLE_PUB_TARGET:-<host>/<owner>/<repo>}' into $CONFIG/firstmate-role (docs/configuration.md \"Firstmate role\"), or pass --upstream-consent ${FM_ROLE_PUB_TARGET:-<host>/<owner>/<repo>} for this one task with the captain's explicit approval" >&2
      exit 1
      ;;
    esac
  fi
  # The registry holds the captain's standing posture, so dropping below it is
  # allowed (a current explicit captain instruction wins) but never silent. An
  # unregistered project resolves to the same no-mistakes standing default, which
  # is why the notice names the standing posture rather than the registry line. A
  # conditional policy is excluded: both of its legs are legitimate classifications.
  if [ -n "$STANDING_MODE" ] && [ "$STANDING_MODE" != no-mistakes-prod-only ] &&
    [ "$(delivery_rigor_rank "$MODE")" -lt "$(delivery_rigor_rank "$STANDING_MODE")" ]; then
    echo "notice: $ID ships mode=$MODE while the standing posture for $PROJ_NAME is $STANDING_MODE - less rigor than the captain's standing posture; proceed only on a current explicit captain instruction or an intake judgment you can state" >&2
  fi
  # The registered ship-branch prefix (bin/fm-project-mode.sh) is the captain's
  # answer to "should this project's branches read as firstmate-authored", so a
  # spawn that ships the legacy fm/ prefix past a registered override is
  # announced, not refused: the brief-vs-spawn agreement above already
  # guarantees the worker's instructions match the branch this spawn selected.
  STANDING_BRANCH=$("$FM_ROOT/bin/fm-project-mode.sh" --branch-prefix "$PROJ_NAME" 2>/dev/null) || STANDING_BRANCH=
  if [ "$BRANCH" != "$STANDING_BRANCH$ID" ]; then
    echo "notice: $ID ships branch=$BRANCH while $PROJ_NAME registers the ship-branch prefix '$STANDING_BRANCH' (branch $STANDING_BRANCH$ID) - the task's branch and PR will read as firstmate-authored; proceed only on a current explicit captain instruction or an intake judgment you can state" >&2
  fi
fi

BRIEF_DIR_REAL=$(cd "$(dirname "$BRIEF")" && pwd -P)
BRIEF_REAL="$BRIEF_DIR_REAL/$(basename "$BRIEF")"

# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
# Every backend's own current-path read (tmux's pane_current_path, herdr's
# foreground_cwd, tern's foreground cwd from `tern process`, zellij/cmux's
# active pwd probe against the live shell) can report the OS-level,
# physically-resolved cwd, so comparing it against a
# still-symlinked PROJ_ABS can misfire both ways: false-negative (the poll
# below never notices the pane left the project) or false-positive (the
# isolation guard refuses a spawn that never actually tangled). Canonicalize
# once here so every downstream comparison uses the same physical form
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"

}
