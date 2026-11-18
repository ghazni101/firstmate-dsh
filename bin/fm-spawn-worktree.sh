# shellcheck shell=bash
# worktree location, validation, and base freshening.
#
# Sourced only by bin/fm-spawn.sh, after SCRIPT_DIR is set: this file defines
# functions and must never run on its own. bin/fm-spawn.sh owns the spawn
# sequence, its execution order, and the shared globals these functions read.
# A phase block from that sequence appears here as a spawn_step_* function,
# called from its original position; its body keeps its original indentation so
# heredocs and literal output stay byte-identical.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; bin/fm-spawn.sh owns the split contract

real_path_or_raw() { # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

spawn_ensure_session_provider() {

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-HOME,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5 as refined by
# docs/herdr-backend.md's "workspace-per-home" pass, AGENTS.md task
# herdr-sm-spaces-k4). Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).

# True when <path> is an isolated worktree of the spawning project: a real
# directory that is its own worktree root, is not the spawning project itself,
# and has a git dir distinct from the project repository's common git dir.
# SPAWN_WT_TOP is left holding the worktree root the check read, and
# SPAWN_WT_REASON a short phrase naming why a rejected path failed, both for
# the refusal messages.
#
# The worktree-discovery poll below reads this same predicate, so it can never
# adopt a path the guard would then refuse. That matters because a pane's cwd
# read is a snapshot of whatever process is in the foreground: while `treehouse
# get` is still fetching and checking a slot out, it reports the REPOSITORY's
# primary checkout as its own cwd. That path differs from a linked spawning
# project, so a poll comparing only against the project accepted it, and the
# guard then refused a launch whose slot treehouse went on to create normally.
# A read like that is a transient, not a destination: the poll keeps waiting.
SPAWN_WT_TOP=
SPAWN_WT_REASON=
}

spawn_worktree_isolated() { # <path>
  local path=$1 wt_real wt_top_real wt_git_dir proj_common
  SPAWN_WT_TOP=
  SPAWN_WT_REASON=
  wt_real=
  if ! wt_real=$(cd "$path" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  if [ -z "$wt_real" ]; then
    SPAWN_WT_REASON="it is not a readable directory"
    return 1
  fi
  SPAWN_WT_TOP=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
  # A path in no repository leaves the toplevel empty, and that empty value must
  # never reach `cd`: bash before 5.3 accepts `cd ""` as a successful no-op, so
  # it would resolve to fm-spawn's OWN cwd and report the path as a subdirectory
  # of whatever checkout firstmate happens to be running from.
  wt_top_real=
  if [ -n "$SPAWN_WT_TOP" ] && ! wt_top_real=$(cd "$SPAWN_WT_TOP" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_top_real" ]; then
    SPAWN_WT_REASON="it is not inside a git worktree"
    return 1
  fi
  if [ "$wt_real" != "$wt_top_real" ]; then
    SPAWN_WT_REASON="it is a subdirectory of worktree root '$wt_top_real', not a worktree root"
    return 1
  fi
  if [ "$wt_real" = "$PROJ_ABS_REAL" ]; then
    SPAWN_WT_REASON="it is the spawning project itself"
    return 1
  fi
  # The primary checkout uses the repository's common git dir as its own git
  # dir. A linked spawning home has a different top-level, but the same common
  # dir, so comparing only the two working directories cannot protect primary.
  wt_git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) &&
    wt_git_dir=$(cd "$wt_git_dir" 2>/dev/null && pwd -P) || wt_git_dir=
  proj_common=$(git -C "$PROJ_ABS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    proj_common=$(cd "$proj_common" 2>/dev/null && pwd -P) || proj_common=
  if [ -z "$wt_git_dir" ] || [ -z "$proj_common" ]; then
    SPAWN_WT_REASON="its git directory could not be resolved"
    return 1
  fi
  if [ "$wt_git_dir" = "$proj_common" ]; then
    SPAWN_WT_REASON="it is the repository's primary checkout (its git dir is the spawning project's common git dir)"
    return 1
  fi
  return 0
}

# spawn_endpoint_hint: the operator pointer for a pre-launch refusal. Only a
# fresh polytoken spawn closes its endpoint on abort, so only it points away
# from the window; every other harness keeps the plain inspect pointer.
spawn_endpoint_closes_on_abort() {
  [ "$SPAWN_FRESH_ENDPOINT_OPENED" = 1 ] && [ "$SPAWN_LAUNCH_SENT" = 0 ]
}

spawn_endpoint_hint() {
  if spawn_endpoint_closes_on_abort; then
    printf 'window %s is closed on exit, returning any pool slot it held' "$T"
  else
    printf 'inspect window %s' "$T"
  fi
}

validate_spawn_worktree() { # <source> <inspect-target>
  local source=$1 inspect_target=$2
  if ! spawn_worktree_isolated "$WT"; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${SPAWN_WT_TOP:-none}'; spawning project '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

# A pooled slot whose only deviation is a submodule gitlink is stale, not dirty:
# an earlier refresh moved the superproject and left the submodule checkout on
# the pin the previous base recorded. The refusal still stands and this gate
# never touches the slot; it only names the cause, because "is not clean" while
# the operator's own `git status` reads clean gives neither a cause nor a remedy.
# A pin is only reported as stale when the commit the slot holds is already
# contained in one of the submodule's remotes. Anything that cannot be proven
# contained - an unpushed commit, a submodule with no remote, a git error - falls
# through to the conservative uncommitted-work refusal, as does any entry that is
# not exactly a clean submodule sitting on a different pin. The diagnosis is
# buffered and only emitted once every entry qualifies, so it can never
# contradict the verdict.
#
# No remedy command is printed, deliberately. That containment check reads local
# refs only and never fetches, because this gate has to stay usable offline. A
# remote-tracking ref that has gone stale - its upstream branch deleted or
# force-pushed, and never pruned - therefore still reads as containment, so a
# commit that is really unpushed can look contained. Naming the submodule and both
# pins is what the operator actually needs; printing a checkout command on a
# judgement that can be fooled could cost them that commit, so the remedy is left
# to the operator, who can see the whole picture.
describe_stale_submodule_pins() { # <worktree> <status>
  local worktree=$1 status=$2 line path want have unpushed lines=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in ' M '*) path=${line#' M '} ;; *) return 1 ;; esac
    [ "$(git -C "$worktree" ls-files --stage -- "$path" 2>/dev/null | cut -c1-6)" = 160000 ] || return 1
    [ -z "$(git -C "$worktree/$path" status --porcelain 2>/dev/null)" ] || return 1
    want=$(git -C "$worktree" rev-parse --verify --quiet "HEAD:$path" 2>/dev/null) || return 1
    have=$(git -C "$worktree/$path" rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
    [ "$want" != "$have" ] || return 1
    unpushed=$(git -C "$worktree/$path" log --format=%H --max-count=1 "$have" --not --remotes -- 2>/dev/null) || return 1
    [ -z "$unpushed" ] || return 1
    lines+="error: submodule '$path' is checked out at $have, but this base records $want"$'\n'
  done <<EOF
$status
EOF
  [ -n "$lines" ] || return 1
  printf '%s' "$lines" >&2
}

spawn_worktree_has_origin_config() { # <worktree>
  # Resolved remote.origin.* variables cover Git's effective include/includeIf chain; raw headers are also detected in the worktree config and any included file Git names through another variable. Git cannot enumerate a variable-less included file, so an empty origin section that is its only content remains indistinguishable from absence and intentionally proceeds rather than reimplementing Git's config parser.
  local worktree=$1 config origin key seen=$'\n'
  git -C "$worktree" config --get-regexp '^remote\.origin\.' >/dev/null 2>&1 && return 0
  while IFS=$'\t' read -r origin key; do
    case $origin in file:*) config=${origin#file:} ;; *) continue ;; esac
    [ -f "$config" ] || continue
    case $seen in *$'\n'"$config"$'\n'*) continue ;; esac
    seen+="$config"$'\n'
    awk '/^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee][[:space:]]+"origin"[[:space:]]*\][[:space:]]*([#;].*)?$/ || /^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee]\.origin[[:space:]]*\][[:space:]]*([#;].*)?$/ { found=1 } END { exit !found }' "$config" && return 0
  done < <(git -C "$worktree" config --list --show-origin 2>/dev/null || true)
  return 1
}

spawn_base_from_primary_checkout() { # <worktree> <project> <default> <origin-rev> <mode>
  local worktree=$1 project=$2 default=$3 origin_rev=$4 mode=$5 primary_rev ahead behind
  SPAWN_PRIMARY_BASE_REV=
  if [ -z "$project" ] || fm_mode_publishes "$mode"; then
    return 1
  fi
  primary_rev=$(git -C "$project" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null) || return 1
  ahead=$(git -C "$worktree" rev-list --count "$origin_rev..$primary_rev" 2>/dev/null) || return 1
  behind=$(git -C "$worktree" rev-list --count "$primary_rev..$origin_rev" 2>/dev/null) || return 1
  [ "$ahead" -gt 0 ] || return 1
  if [ "$behind" -eq 0 ]; then
    SPAWN_PRIMARY_BASE_REV=$primary_rev
    return 0
  fi
  echo "note: pooled worktree '$worktree': $default in the primary checkout has diverged from origin/$default (ahead by $ahead, behind by $behind); starting from origin's tip" >&2
  return 1
}

freshen_spawn_worktree_base() { # <worktree> <base-branch> <project> <mode>; 2 when the worktree is not clean
  local worktree=$1 base=${2:-} project=${3:-} mode=${4:-} default target expected reset_ref actual status
  status=$(git -C "$worktree" -c core.quotePath=false status --porcelain) || {
    echo "error: could not inspect pooled worktree '$worktree' before refreshing its base" >&2
    return 1
  }
  if [ -n "$status" ]; then
    if describe_stale_submodule_pins "$worktree" "$status"; then
      echo "error: pooled worktree '$worktree' has a stale submodule checkout, not uncommitted work; refusing to launch and leaving it untouched" >&2
    else
      echo "error: pooled worktree '$worktree' is not clean; refusing to discard uncommitted work while refreshing its base" >&2
    fi
    return 2
  fi
  if ! spawn_worktree_has_origin_config "$worktree"; then
    [ -z "$base" ] || {
      echo "error: pooled worktree '$worktree' has no origin, so it cannot start from base branch '$base'" >&2
      return 1
    }
    return 0
  fi
  if ! git -C "$worktree" fetch --quiet origin; then
    echo "error: could not fetch origin for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  if [ -n "$base" ]; then
    default=$base
  else
    if ! git -C "$worktree" remote set-head origin --auto >/dev/null 2>&1; then
      echo "error: could not resolve origin's current default branch for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
      return 1
    fi
    default=$(default_branch "$worktree") || {
      echo "error: could not determine origin's default branch for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
      return 1
    }
  fi
  target="origin/$default"
  if ! git -C "$worktree" fetch --quiet origin "+refs/heads/$default:refs/remotes/origin/$default"; then
    echo "error: could not fetch '$target' for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  expected=$(git -C "$worktree" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    echo "error: '$target' is not a commit for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  }
  reset_ref=$target
  if [ -z "$base" ] && [ -e "$CONFIG/spawn-base-primary-checkout" ] \
    && spawn_base_from_primary_checkout "$worktree" "$project" "$default" "$expected" "$mode"; then
    target="$default in the primary checkout"
    expected=$SPAWN_PRIMARY_BASE_REV
    reset_ref=$expected
  fi
  if ! git -C "$worktree" reset --hard "$reset_ref" >/dev/null; then
    echo "error: could not reset pooled worktree '$worktree' to '$target'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ "$actual" != "$expected" ]; then
    echo "error: pooled worktree '$worktree' is at '${actual:-unknown}', not current '$target' ('$expected'); refusing to launch" >&2
    return 1
  fi
}
