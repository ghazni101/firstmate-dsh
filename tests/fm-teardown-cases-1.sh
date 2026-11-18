# shellcheck shell=bash
# Test cases for fm-teardown, split out of tests/fm-teardown.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-teardown.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Default hermetic no-mistakes stub: `axi status` answers FM_FAKE_AXI_STATUS
  # verbatim (empty by default, i.e. no active run - the pre-teardown run-abort
  # step is then a no-op), `axi abort` appends one line to
  # FM_FAKE_NM_ABORT_LOG when set, the top-level `runs` listing answers
  # FM_FAKE_NM_RUNS_LIST verbatim (the real `no-mistakes runs --limit N` is
  # plain text with no run id and no quoting - see the ledger fixtures below),
  # and `runs` appends its own invocation to FM_FAKE_NM_RUNS_LOG when set, so
  # a test can prove whether the ledger fallback ever engaged.
  # The bare `axi` overview answers FM_FAKE_AXI_OVERVIEW verbatim (empty by
  # default, so no repository resolves and the pipeline-spend record is
  # written as unavailable).
  # This keeps every case hermetic - without it, `command -v no-mistakes`
  # would fall through to whatever real binary happens to be on the test
  # runner's own PATH. Tests exercising the run-abort path override
  # FM_FAKE_AXI_STATUS/FM_FAKE_NM_ABORT_LOG/FM_FAKE_NM_RUNS_LIST before
  # run_teardown.
  # When FM_FAKE_NM_EXPECT_HOME is set, the stub sees runs only from that
  # NM_HOME, as a per-workspace daemon would: any other home answers no run
  # and records no abort.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_NM_EXPECT_HOME:-}" ] && [ "${NM_HOME:-}" != "$FM_FAKE_NM_EXPECT_HOME" ]; then
  exit 0
fi
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      '')
        printf '%s\n' "${FM_FAKE_AXI_OVERVIEW:-}" ;;
      status)
        shift
        run_id=""
        if [ "${1:-}" = --run ]; then run_id=${2:-}; fi
        if [ -n "${FM_FAKE_NM_ABORT_LOG:-}" ] \
           && grep -Fxq "abort --run $run_id" "$FM_FAKE_NM_ABORT_LOG" 2>/dev/null \
           && [ "${FM_FAKE_NM_ABORT_NOOP:-0}" != 1 ]; then
          if [ "${FM_FAKE_NM_NOT_FOUND_AFTER_ABORT:-0}" = 1 ]; then
            printf 'error: "run \\"%s\\" not found"\n' "$run_id" >&2
            exit 1
          elif [ "${FM_FAKE_NM_EMPTY_AFTER_ABORT:-0}" = 1 ]; then
            exit 0
          elif [ -n "${FM_FAKE_AXI_STATUS_AFTER_ABORT:-}" ]; then
            printf '%s\n' "$FM_FAKE_AXI_STATUS_AFTER_ABORT"
          else
            printf 'run:\n  id: "%s"\n  outcome: cancelled\n' "$run_id"
          fi
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
        fi
        ;;
      abort)
        shift
        [ -z "${FM_FAKE_NM_ABORT_LOG:-}" ] || printf 'abort %s\n' "$*" >> "$FM_FAKE_NM_ABORT_LOG"
        exit 0 ;;
    esac
    ;;
  runs)
    [ -z "${FM_FAKE_NM_RUNS_LOG:-}" ] || printf 'runs %s\n' "$*" >> "$FM_FAKE_NM_RUNS_LOG"
    printf '%s\n' "${FM_FAKE_NM_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# Write a meta file for the task. Args: case_dir mode kind [worktree]
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  local wt=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=teardown-test-task-x1"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' 'MERGED' '$head' 'https://github.com/example/repo/pull/7' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Squash-merged history whose pipeline rebased the branch onto a newer main that
# edited the same shared file. A local copy left behind by that rebase holds
# different content for the shared file, so its per-commit patch ids against the
# PR head differ and merge-tree against main conflicts; teardown refuses it on
# purpose rather than reading a shared path as proof the local content landed.
# local_mode: rebased | stale | rebased-plus-unlanded
# Echoes: <pr_head>
setup_squash_rebased_history() {
  local case_dir=$1 local_mode=$2 tmp local_head pr_head
  tmp="$case_dir/_shared_base"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "shared base"
  git -C "$tmp" push -q origin main
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" reset -q --hard origin/main
  rm -rf "$tmp"

  wt_commit_file "$case_dir" feature.txt hello "add feature"
  printf '%s\n' base feature-edit > "$case_dir/wt/shared.txt"
  git -C "$case_dir/wt" add -- shared.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  tmp="$case_dir/_main_move"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base main-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main edits shared"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1
  printf '%s\n' hello > "$tmp/feature.txt"
  git -C "$tmp" add -- feature.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add feature"
  printf '%s\n' base main-edit feature-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --squash fm/task-x1 >/dev/null
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "feat: squash (#7)"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/wt" fetch -q origin "refs/pull/7/head:refs/fm-test/pr-head"
  case "$local_mode" in
    rebased)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      ;;
    stale)
      git -C "$case_dir/wt" reset -q --hard "$local_head"
      ;;
    rebased-plus-unlanded)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      wt_commit_file "$case_dir" later.txt local-only "local follow-up"
      ;;
    *)
      fail "setup_squash_rebased_history: unknown local_mode $local_mode"
      ;;
  esac
  printf '%s\n' "$pr_head"
}

# A refusal must leave every recovery route intact: the isolated copy, its task
# branch still at the unlanded commit, and the durable task record. A completed
# teardown detaches and deletes that branch and removes the record, so these hold
# only while nothing destructive ran before the refusal was reported.
# Args: case_dir label head-before-teardown
assert_refusal_retained_task_state() {
  local case_dir=$1 label=$2 head=$3
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = fm/task-x1 ] \
    || fail "$label: refusal dropped the task branch"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD 2>/dev/null)" = "$head" ] \
    || fail "$label: refusal moved the task branch off the unlanded commit"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "$label: refusal erased the durable task record"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone. The cwd scan is a
# separate successful empty query.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  # FM_DATA_OVERRIDE is pinned to the case dir because teardown closes this
  # home's backlog item itself; without it $DATA would resolve to the real
  # repo's own home and a test could mutate live records.
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

# Seed a real backlog carrying task-x1 as In flight, so a teardown in this case
# has a row to close. Uses the real tasks-axi (the fixture's default fakebin has
# no tasks-axi stub, so PATH resolves the installed one).
seed_backlog_in_flight() {
  local case_dir=$1 kind=${2:-ship}
  mkdir -p "$case_dir/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "teardown fixture task" --kind "$kind" \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
}

backlog_row_state() {
  local case_dir=$1
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Build the teardown test's executable search path without lsof, regardless of
# whether the host installs it in /usr/bin, /usr/sbin, or a package-manager bin.
make_path_without_lsof() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-lsof" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # The supervision branch's bounded per-task outcome cache is a footprint of
  # the retired task, not a record anything reads after it is gone.
  printf 'fm-branch-outcome-index-v1\t5\t0\t-\n' > "$case_dir/state/.task-x1.branch-outcome-index"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: teardown left the task's branch outcome index behind"
  # The supervision branch reports the teardown it just performed AFTER the
  # task's records are gone (bin/fm-branch-prompt.sh); that report must be
  # stored, must publish its ready sequence, and must not recreate the index.
  post_seq=$(FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-x1 --verdict captain --summary 'PR merged and cleaned up') \
    || fail "fork-allow: post-teardown branch report was refused"
  [ "$post_seq" = 1 ] || fail "fork-allow: post-teardown branch report got seq $post_seq, expected 1"
  grep -q '"task":"task-x1"' "$case_dir/state/branch-outcomes.jsonl" \
    || fail "fork-allow: post-teardown branch report was not stored"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: post-teardown branch report recreated the retired task index"
  [ "$(cat "$case_dir/state/.branch-outcome-index-ready")" = 1 ] \
    || fail "fork-allow: post-teardown branch report did not publish its ready sequence"
  jq -e --arg id task-x1 '
    .schema == "fm-secondmate-home-summary.v1"
    and all(.endpoints[]; .id != $id)
  ' "$case_dir/state/home-summary.json" >/dev/null \
    || fail "successful task teardown did not publish the task's removal from the home summary ledger"
  pass "local-only worktree with HEAD on a fork remote is torn down and the home summary is refreshed"
}

test_teardown_closes_the_backlog_item_itself() {
  local case_dir out
  case_dir=$(make_case tasks-axi-close)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with a real backlog"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown returned success while its backlog item was still open: $(backlog_row_state "$case_dir")"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "closed backlog item did not record the task's PR"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed close left its pending-close record behind"
  printf '%s\n' "$out" | grep -F 'bin/fm-tasks-axi.sh ready' >/dev/null \
    || fail "teardown dropped the dependency-cleared follow-up: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'Run tasks-axi done' >/dev/null \
    && fail "teardown still asked a later turn to close the item it already closed: $out"
  pass "teardown closes its own backlog item before reporting success"
}

test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note() {
  local case_dir out real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  case_dir=$(make_case tasks-axi-close-gerrit)
  write_meta "$case_dir" no-mistakes ship
  printf 'pr=%s\n' "$gerrit_url" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  # Pin the refusal tasks-axi applies to a --pr link that is not a canonical
  # GitHub pull request, so this case keeps reproducing whatever the installed
  # release accepts.
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"

  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed Gerrit task failed: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown left a landed Gerrit task's backlog item at $(backlog_row_state "$case_dir"): $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" --full \
    | grep -F "body: \"Gerrit change $gerrit_url\"" >/dev/null \
    || fail "closed Gerrit backlog item did not record its change URL as a note"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed Gerrit close left its pending-close record behind"

  case_dir=$(make_case tasks-axi-close-github-under-refusal)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  cp "$TMP_ROOT/tasks-axi-close-gerrit/fakebin/tasks-axi" "$case_dir/fakebin/tasks-axi"
  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed GitHub task failed: $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" \
    | grep -F 'links: "pr:https://github.com/example/repo/pull/7"' >/dev/null \
    || fail "a GitHub pull request no longer closed as the item's pr link"
  pass "teardown closes a landed Gerrit task with its change URL as a note and a GitHub task with --pr"
}

test_teardown_closes_a_gitlab_task_with_its_merge_request_url_as_a_note() {
  local case_dir out real_tasks_axi url forge
  local gitlab_url=https://gitlab.example.com/group/sub/repo/-/merge_requests/12
  case_dir=$(make_case tasks-axi-close-gitlab)
  write_meta "$case_dir" no-mistakes ship
  printf 'pr=%s\n' "$gitlab_url" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  # Pin the refusal tasks-axi applies to a --pr link that is neither a GitHub
  # nor a Forgejo pull request, so this case keeps reproducing whatever the
  # installed release accepts.
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://[^/]+/[^/]+/[^/]+/pulls?/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"

  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed GitLab task failed: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown left a landed GitLab task's backlog item at $(backlog_row_state "$case_dir"): $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" --full \
    | grep -F "body: \"GitLab merge request $gitlab_url\"" >/dev/null \
    || fail "closed GitLab backlog item did not record its merge request URL as a note"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed GitLab close left its pending-close record behind"

  for url in https://github.com/example/repo/pull/7 https://forgejo.example.com/example/repo/pulls/7; do
    forge=${url#https://}
    case_dir=$(make_case "tasks-axi-close-pr-under-gitlab-refusal-${forge%%.*}")
    write_meta "$case_dir" no-mistakes ship
    printf 'pr=%s\n' "$url" >> "$case_dir/state/task-x1.meta"
    seed_backlog_in_flight "$case_dir"
    cp "$TMP_ROOT/tasks-axi-close-gitlab/fakebin/tasks-axi" "$case_dir/fakebin/tasks-axi"
    out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed task with $url failed: $out"
    tasks-axi show task-x1 --file "$case_dir/data/backlog.md" \
      | grep -F "links: \"pr:$url\"" >/dev/null \
      || fail "$url no longer closed as the item's pr link"
  done
  pass "teardown closes a landed GitLab task with its merge request URL as a note and GitHub and Forgejo tasks with --pr"
}

test_teardown_manual_backend_leaves_the_backlog_to_the_operator() {
  local case_dir out backlog_path
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "manual backlog backend was mutated by teardown anyway"
  backlog_path=$(cd "$case_dir/data" && pwd -P)/backlog.md
  printf '%s\n' "$out" | grep -F "Update $backlog_path - move task-x1 to Done" >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  pass "teardown honors config/backlog-backend=manual and still finishes cleanly"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

# A merge-time cleanup request belongs to the detached cleanup that runs this
# teardown: only that cleanup removes it, after its outcome report is saved, so
# a cleanup that dies mid-teardown is still retried by the next park tick.
test_teardown_leaves_the_merge_cleanup_request_to_its_cleanup() {
  local case_dir wt_head rc
  case_dir=$(make_case keep-cleanup-request)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'pr=https://github.com/example/repo/pull/7\n' > "$case_dir/state/task-x1.review-park-land"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "keep-cleanup-request: teardown should succeed when work is merged into local main"
  assert_present "$case_dir/state/task-x1.review-park-land" "teardown removed the merge cleanup request its cleanup still owns"
  pass "teardown leaves a merge cleanup request for the detached cleanup that owns it"
}

# Send the task branch's commits to <target> on origin from a separate clone, so
# the task copy's tracking refs do not show them. Args: case_dir target
land_task_commits_from_other_clone() {
  local case_dir=$1 target=$2 other
  other="$case_dir/_other"
  git clone -q "$case_dir/origin.git" "$other"
  git -C "$other" fetch -q "$case_dir/project" fm/task-x1
  git -C "$other" push -q origin "FETCH_HEAD:refs/heads/$target"
  rm -rf "$other"
  [ -n "$(git -C "$case_dir/wt" log --oneline HEAD --not --remotes --)" ] \
    || fail "fixture: tracking refs already show the task commits"
}

# Log every git fetch to $case_dir/fetch.log; FM_TEST_FETCH_HANG makes it hang,
# and FM_TEST_FETCH_WRITES names a file it saves first.
add_fetch_logging_git() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = fetch ]; then
    printf '%s\n' "\$*" >> "$case_dir/fetch.log"
    [ -z "\${FM_TEST_FETCH_WRITES:-}" ] || printf 'saved during fetch\n' > "\$FM_TEST_FETCH_WRITES"
    [ -z "\${FM_TEST_FETCH_HANG:-}" ] || sleep 120
    break
  fi
done
exec "\$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$case_dir/fakebin/git"
}

test_landed_on_other_origin_branch_with_stale_refs_allows() {
  local mode case_dir rc
  for mode in local-only direct-PR no-mistakes; do
    case_dir=$(make_case "stale-refs-$mode")
    write_meta "$case_dir" "$mode" ship
    wt_commit_file "$case_dir" feature.txt landed
    land_task_commits_from_other_clone "$case_dir" release

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" "stale-refs-$mode: work on origin should be proven landed"
    ! grep -q REFUSED "$case_dir/stderr" || fail "stale-refs-$mode: teardown printed a REFUSED line"
  done
  pass "work landed on another origin branch from another clone is proven after a refresh"
}

test_refresh_failure_does_not_read_as_landed() {
  local case_dir rc
  case_dir=$(make_case stale-refs-fetch-fails)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt landed
  land_task_commits_from_other_clone "$case_dir" release
  git -C "$case_dir/project" remote set-url origin "$case_dir/missing.git"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-refs-fetch-fails: a failed refresh must refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-refs-fetch-fails: no REFUSED line"
  grep -q 'Could not refresh remote: origin' "$case_dir/stderr" || fail "stale-refs-fetch-fails: refusal does not name the remote"
  [ -d "$case_dir/wt" ] || fail "stale-refs-fetch-fails: worktree was removed"

  case_dir=$(make_case stale-refs-fetch-fails-pr)
  write_meta "$case_dir" direct-PR ship
  wt_commit_file "$case_dir" feature.txt landed
  land_task_commits_from_other_clone "$case_dir" release
  git -C "$case_dir/project" remote set-url origin "$case_dir/missing.git"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-refs-fetch-fails-pr: a failed refresh must refuse"
  grep -q 'Could not refresh remote: origin' "$case_dir/stderr" || fail "stale-refs-fetch-fails-pr: refusal does not name the remote"
  pass "a failed refresh refuses and names the remote it could not reach"
}

test_refreshed_refs_still_refuse_unreachable_commits() {
  local case_dir rc
  case_dir=$(make_case refreshed-unreachable)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt never-landed
  land_on_origin_main "$case_dir" other.txt unrelated
  add_fetch_logging_git "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "refreshed-unreachable: unreachable commits must refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "refreshed-unreachable: no REFUSED line"
  [ -s "$case_dir/fetch.log" ] || fail "refreshed-unreachable: no refresh ran, so the case proves nothing"
  ! grep -q 'Could not refresh' "$case_dir/stderr" || fail "refreshed-unreachable: reported a failure for a working remote"
  pass "commits on no remote branch still refuse after a successful refresh"
}

test_uncommitted_work_refuses_even_when_commits_landed() {
  local case_dir rc
  case_dir=$(make_case stale-refs-dirty)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt landed
  land_task_commits_from_other_clone "$case_dir" release
  printf 'unsaved\n' > "$case_dir/wt/unsaved.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-refs-dirty: uncommitted work must refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-refs-dirty: no REFUSED line"
  [ -f "$case_dir/wt/unsaved.txt" ] || fail "stale-refs-dirty: uncommitted file was lost"
  pass "uncommitted work refuses even when the commits have landed"
}

test_edit_saved_during_refresh_refuses() {
  local mode case_dir rc
  for mode in local-only direct-PR no-mistakes; do
    case_dir=$(make_case "edit-during-refresh-$mode")
    write_meta "$case_dir" "$mode" ship
    wt_commit_file "$case_dir" feature.txt landed
    land_task_commits_from_other_clone "$case_dir" release
    add_fetch_logging_git "$case_dir"

    set +e
    FM_TEST_FETCH_WRITES="$case_dir/wt/saved-during-fetch.txt" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "edit-during-refresh-$mode: an edit saved during the refresh must refuse"
    grep -q REFUSED "$case_dir/stderr" || fail "edit-during-refresh-$mode: no REFUSED line"
    [ -f "$case_dir/wt/saved-during-fetch.txt" ] || fail "edit-during-refresh-$mode: the saved file was lost"
  done
  pass "a file saved during the refresh refuses teardown and survives"
}

test_no_remote_project_refuses_without_fetching() {
  local case_dir rc
  case_dir=$(make_case no-remote-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt never-landed
  git -C "$case_dir/project" remote remove origin
  add_fetch_logging_git "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-remote-unpushed: unlanded work must refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "no-remote-unpushed: no REFUSED line"
  [ ! -e "$case_dir/fetch.log" ] || fail "no-remote-unpushed: a project with no remote ran a fetch"
  ! grep -q 'Could not refresh' "$case_dir/stderr" || fail "no-remote-unpushed: reported a refresh failure with no remote"
  pass "a project with no remote refuses as before and fetches nothing"
}

test_refresh_never_prunes_a_dropped_branch() {
  local case_dir rc
  case_dir=$(make_case refresh-no-prune)
  write_meta "$case_dir" local-only ship
  git -C "$case_dir/project" config fetch.prune true
  git -C "$case_dir/origin.git" update-ref refs/heads/dropped refs/heads/main
  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/origin.git" update-ref -d refs/heads/dropped
  wt_commit_file "$case_dir" feature.txt never-landed

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "refresh-no-prune: unlanded work must refuse"
  git -C "$case_dir/project" rev-parse --verify -q refs/remotes/origin/dropped >/dev/null \
    || fail "refresh-no-prune: the refresh pruned a branch the remote dropped"
  pass "the refresh keeps a dropped branch's tracking ref even with fetch.prune set"
}

test_reachable_work_needs_no_fetch() {
  local case_dir rc
  case_dir=$(make_case reachable-no-fetch)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt pushed
  git -C "$case_dir/wt" push -q origin fm/task-x1
  add_fetch_logging_git "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "reachable-no-fetch: reachable work should be torn down"
  [ ! -e "$case_dir/fetch.log" ] || fail "reachable-no-fetch: work the refs already show still paid for a fetch"
  pass "work the tracking refs already show adds no network call"
}

test_hung_fetch_is_bounded_and_refuses() {
  local case_dir rc started elapsed
  case_dir=$(make_case hung-fetch)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt landed
  land_task_commits_from_other_clone "$case_dir" release
  add_fetch_logging_git "$case_dir"

  started=$(date +%s)
  set +e
  FM_TEST_FETCH_HANG=1 run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started ))

  expect_code 1 "$rc" "hung-fetch: a hung refresh must refuse"
  grep -q 'Could not refresh remote: origin' "$case_dir/stderr" || fail "hung-fetch: refusal does not name the remote"
  [ "$elapsed" -ge 29 ] || fail "hung-fetch: teardown gave up after ${elapsed}s, before the 30-second bound"
  [ "$elapsed" -lt 60 ] || fail "hung-fetch: teardown waited ${elapsed}s, past the 30-second bound"
  pass "a hung refresh is cut off at its bound and refuses"
}

test_gate_remote_is_not_refreshed_into_landed() {
  local case_dir rc
  case_dir=$(make_case gate-not-refreshed)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt validating
  git init -q --bare "$case_dir/gate.git"
  git -C "$case_dir/project" remote add no-mistakes "$case_dir/gate.git"
  git -C "$case_dir/wt" push -q "$case_dir/gate.git" fm/task-x1

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-not-refreshed: commits only on the gate must refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "gate-not-refreshed: no REFUSED line"
  pass "commits held only by the no-mistakes gate are not refreshed into landed"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_no_mistakes_mirror_only_branch_refuses() {
  local case_dir rc local_head
  case_dir=$(make_case nm-mirror-only)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "mirror-only work"
  # A branch pushed only to the local pipeline mirror is not on a forge.
  git init -q --bare "$case_dir/mirror.git"
  git -C "$case_dir/project" remote add no-mistakes "$case_dir/mirror.git"
  git -C "$case_dir/wt" push -q no-mistakes fm/task-x1
  git -C "$case_dir/project" fetch -q no-mistakes
  git -C "$case_dir/wt" rev-parse --verify -q refs/remotes/no-mistakes/fm/task-x1 >/dev/null \
    || fail "nm-mirror-only: mirror remote-tracking ref was not created"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "nm-mirror-only: teardown should refuse mirror-only work"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-mirror-only: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" nm-mirror-only "$local_head"
  pass "branch pushed only to the no-mistakes mirror is refused as unlanded"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  seed_backlog_in_flight "$case_dir"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "no-pr-branch-discovery: resolved PR URL was not recorded on completion"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_patch_matching_preserves_indentation() {
  local case_dir mode rc pr_head local_head expected
  for mode in exact amended old-git; do
    case_dir=$(make_case "pr-indentation-$mode")
    write_meta "$case_dir" no-mistakes ship
    # A pushed parent makes the YAML patch the only unpushed commit, while
    # giving the local replay a different parent from the recorded PR head.
    wt_commit_file "$case_dir" local-parent.txt parent "local parent"
    git -C "$case_dir/wt" push -q origin HEAD:refs/heads/fm/task-x1
    git -C "$case_dir/project" fetch -q origin fm/task-x1
    wt_commit_file "$case_dir" config.yml $'a:\n  b: 1' "add YAML"
    append_pr_meta_url "$case_dir"
    pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head config.yml $'a:\n  b: 1' "add YAML")
    printf 'pr_head=%s\n' "$pr_head" >> "$case_dir/state/task-x1.meta"
    add_gh_pr_merged_for_head "$case_dir" "$pr_head"
    if [ "$mode" = amended ]; then
      printf 'a:\nb: 1\n' > "$case_dir/wt/config.yml"
      git -C "$case_dir/wt" add -- config.yml
      git -C "$case_dir/wt" commit -q --amend --no-edit
    elif [ "$mode" = old-git ]; then
      cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = patch-id ]; then
  printf '%s\n' "$*" >> "$FM_PATCH_ID_LOG"
  if [ "${2:-}" = --verbatim ]; then
    echo 'error: unknown option `verbatim`' >&2
    exit 129
  fi
fi
exec "$REAL_GIT_FOR_TEST" "$@"
SH
      chmod +x "$case_dir/fakebin/git"
    fi
    local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
    [ "$local_head" != "$pr_head" ] || fail "$mode: fixture did not diverge"

    set +e
    FM_PATCH_ID_LOG="$case_dir/patch-id.log" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expected=1
    [ "$mode" != exact ] || expected=0
    expect_code "$expected" "$rc" "pr-indentation-$mode: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
    if [ "$expected" = 1 ]; then
      assert_grep REFUSED "$case_dir/stderr" "$mode: no refusal diagnostic"
      assert_refusal_retained_task_state "$case_dir" "$mode" "$local_head"
    fi
    if [ "$mode" = old-git ]; then
      assert_grep 'patch-id --verbatim' "$case_dir/patch-id.log" "old-git: capability rejection was not exercised"
      ! grep -q -- --stable "$case_dir/patch-id.log" || fail "old-git: fell back to whitespace-insensitive matching"
    fi
  done
  pass "merged PR patch matching preserves indentation, allows exact replays, and refuses unsupported Git"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_squash_merged_rebased_branch_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-rebased)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-rebased: teardown should succeed when the worktree followed the pipeline rebase"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased: teardown printed a REFUSED line"
  pass "squash-merged task whose local branch followed the pipeline rebase is torn down"
}

# Override tea to answer one login for git.example.org and a pull request
# read through "tea api" with the supplied merged flag and head.
add_tea_pull_for_head() {
  local case_dir=$1 merged=$2 head=$3
  cat > "$case_dir/fakebin/tea" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tea.log"
if [ "\${1:-} \${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "fj",\n    "url": "https://git.example.org"\n  }\n]\n'
  exit 0
fi
[ "\${1:-}" = api ] || exit 1
printf '{"state":"closed","merged":%s,"head":{"sha":"%s"}}\n' '$merged' '$head'
SH
  chmod +x "$case_dir/fakebin/tea"
}

# A Forgejo task whose default branch moved on after the squash merge, editing
# the same lines, leaves the content check inconclusive, so only the forge's
# merged record can prove the work landed. With the record merged teardown
# proceeds; with it unmerged the same history refuses.
test_squash_merged_forgejo_pr_allows_when_main_moved_on() {
  local case_dir rc pr_head tmp merged expected
  for merged in true false; do
    case_dir=$(make_case "forgejo-merged-$merged")
    write_meta "$case_dir" no-mistakes ship
    pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
    tmp="$case_dir/_main_later"
    git clone -q "$case_dir/origin.git" "$tmp"
    printf '%s\n' base main-edit feature-edit-reworded > "$tmp/shared.txt"
    git -C "$tmp" add -- shared.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main rewords shared"
    git -C "$tmp" push -q origin main
    rm -rf "$tmp"
    printf '%s\n' \
      'pr=https://git.example.org/team/repo/pulls/7' \
      "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
    add_gh_axi_error "$case_dir"
    add_tea_pull_for_head "$case_dir" "$merged" "$pr_head"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expected=1
    [ "$merged" = false ] || expected=0
    expect_code "$expected" "$rc" "forgejo-merged-$merged: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
    grep -qF -- 'api --login fj --repo team/repo /repos/{owner}/{repo}/pulls/7' "$case_dir/tea.log" \
      || fail "forgejo-merged-$merged: teardown did not read the Forgejo pull request through tea"
  done
  pass "teardown proves a Forgejo task landed from the merged pull request when the content check is inconclusive"
}

add_glab_mr_for_head() {
  local case_dir=$1 state=$2 head=$3
  cat > "$case_dir/fakebin/glab" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/glab.log"
[ "\${1:-} \${2:-}" = "mr view" ] || exit 1
printf '{"state":"%s","sha":"%s","squash_commit_sha":"%s"}\n' '$state' '$head' 0000000000000000000000000000000000000001
SH
  chmod +x "$case_dir/fakebin/glab"
}

# A GitLab merge request squash-merged (or merged by a merge train) lands a
# commit on main that is not the MR head, and main then moved on over the same
# lines, so the content check is inconclusive. The MR's own head is published
# only as refs/merge-requests/<n>/head, which this copy never fetched. With
# config/park-on-review or config/auto-land present, teardown must read the MR
# through glab, fetch that ref, and accept the merged record; the same history
# with the MR still open refuses. With neither flag the merged MR is never read
# through glab and teardown refuses on the inconclusive content check.
test_squash_merged_gitlab_mr_allows_when_main_moved_on() {
  local case_dir rc local_head pr_head tmp scenario state expected
  for scenario in merged:park-on-review merged:auto-land opened:park-on-review merged:; do
    state=${scenario%%:*}
    case_dir=$(make_case "gitlab-mr-$state-${scenario#*:}")
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
    tmp="$case_dir/_pipeline"
    git clone -q "$case_dir/origin.git" "$tmp"
    git -C "$tmp" fetch -q "$case_dir/wt" "fm/task-x1:fm/task-x1"
    git -C "$tmp" checkout -q fm/task-x1
    printf '%s\n' pipeline > "$tmp/fix.txt"
    git -C "$tmp" add -- fix.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "no-mistakes fix"
    pr_head=$(git -C "$tmp" rev-parse HEAD)
    git -C "$tmp" push -q origin "HEAD:refs/merge-requests/7/head"
    git -C "$tmp" checkout -q main
    printf '%s\n' reworded > "$tmp/feature.txt"
    git -C "$tmp" add -- feature.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash then main rewords"
    git -C "$tmp" push -q origin main
    rm -rf "$tmp"
    ! git -C "$case_dir/wt" cat-file -e "$pr_head^{commit}" 2>/dev/null \
      || fail "gitlab-mr-$state: test setup bug, the MR head is already local"
    printf '%s\n' 'pr=https://gitlab.example.com/team/sub/repo/-/merge_requests/7' \
      >> "$case_dir/state/task-x1.meta"
    add_gh_axi_error "$case_dir"
    add_glab_mr_for_head "$case_dir" "$state" "$pr_head"
    [ -z "${scenario#*:}" ] || : > "$case_dir/config/${scenario#*:}"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    if [ -z "${scenario#*:}" ]; then
      expect_code 1 "$rc" "gitlab-mr-no-flag: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
      [ ! -e "$case_dir/glab.log" ] || fail "gitlab-mr-no-flag: teardown read the merge request through glab without an opt-in flag"
      grep -q REFUSED "$case_dir/stderr" || fail "gitlab-mr-no-flag: no REFUSED line in stderr"
      assert_refusal_retained_task_state "$case_dir" gitlab-mr-no-flag "$local_head"
      continue
    fi
    expected=1
    [ "$state" != merged ] || expected=0
    expect_code "$expected" "$rc" "gitlab-mr-$scenario: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
    grep -qF -- 'mr view 7 -R https://gitlab.example.com/team/sub/repo -F json' "$case_dir/glab.log" \
      || fail "gitlab-mr-$scenario: teardown did not read the merge request through glab"
    if [ "$state" = merged ]; then
      ! grep -q REFUSED "$case_dir/stderr" || fail "gitlab-mr-merged: teardown printed a REFUSED line"
    else
      grep -q REFUSED "$case_dir/stderr" || fail "gitlab-mr-opened: no REFUSED line in stderr"
      assert_refusal_retained_task_state "$case_dir" gitlab-mr-opened "$local_head"
    fi
  done
  pass "teardown proves a squash- or train-merged GitLab MR landed from the MR head only with an opt-in flag, and refuses an open one"
}

test_squash_merged_same_file_different_content_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-same-path-diverged)
  write_meta "$case_dir" no-mistakes ship
  # The pipeline rebase produced a different blob for shared.txt than the stale
  # local still holds, then squash-merged. Same path is not proof the local
  # content landed.
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-same-path-diverged: teardown should refuse when the same file has different content"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-same-path-diverged: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-same-path-diverged "$local_head"
  pass "squash-merged same-path different content still refuses"
}

# The local branch followed the pipeline rebase, so without later.txt this is the
# q2 ALLOW case exactly. The one unlanded follow-up commit is the sole difference
# and must be the sole reason teardown refuses.
test_squash_merged_rebased_local_with_unlanded_commit_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-rebased-unlanded)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased-plus-unlanded)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-rebased-unlanded: teardown should refuse extra local commits that never landed"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased-unlanded: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-rebased-unlanded "$local_head"
  pass "squash-merged rebased local still refuses a genuinely unlanded follow-up commit"
}

test_squash_merged_stale_local_refuses_when_forge_unreachable() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-stale-offline)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-stale-offline: teardown should refuse when the forge is down and trees conflict"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-stale-offline: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-stale-offline "$local_head"
  pass "squash-merged stale local still refuses when the forge is unreachable"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

# Exercise Git's capability/error boundary through the real teardown entry point.
# Only merge-tree is intercepted; history, fetches, and preservation checks are real.
test_content_fallback_git_capability_boundary() {
  local mode case_dir rc head
  for mode in unsupported contained conflict unlanded error; do
    case_dir=$(make_case "content-git-$mode")
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    case "$mode" in
      conflict) land_on_origin_main "$case_dir" feature.txt different ;;
      unlanded) ;;
      *) land_on_origin_main "$case_dir" feature.txt hello ;;
    esac
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
args=("$@")
if [ "${1:-}" = -C ]; then shift 2; fi
if [ "${1:-}" = merge-tree ]; then
  printf '%s\n' "$*" >> "${FM_TEST_MERGE_TREE_LOG:?}"
  case "${FM_TEST_MERGE_TREE_MODE:?}" in
    unsupported)
      echo "error: unknown option 'write-tree'" >&2
      exit 129 ;;
    error)
      echo 'fatal: unable to read tree object' >&2
      exit 128 ;;
  esac
fi
exec "$REAL_GIT_FOR_TEST" "${args[@]}"
SH
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_TREEHOUSE_LOG:?}"
exit 0
SH
    chmod +x "$case_dir/fakebin/git" "$case_dir/fakebin/treehouse"

    set +e
    FM_TEST_MERGE_TREE_MODE="$mode" \
      FM_TEST_MERGE_TREE_LOG="$case_dir/merge-tree.log" \
      FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    grep -q -- 'merge-tree --write-tree' "$case_dir/merge-tree.log" \
      || fail "content-git-$mode: never attempted the containment proof"
    if [ "$mode" = contained ]; then
      expect_code 0 "$rc" "content-git-contained: supported containment should allow cleanup"
      assert_present "$case_dir/treehouse.log" "content-git-contained: cleanup never ran"
      assert_absent "$case_dir/state/task-x1.meta" "content-git-contained: task record survived cleanup"
      continue
    fi
    expect_code 1 "$rc" "content-git-$mode: teardown must refuse"
    assert_refusal_retained_task_state "$case_dir" "content-git-$mode" "$head"
    assert_absent "$case_dir/treehouse.log" "content-git-$mode: cleanup ran despite refusal"
    case "$mode" in
      unsupported|error)
        grep -q 'content-landed proof unavailable' "$case_dir/stderr" \
          || fail "content-git-$mode: unavailable proof was reported as unlanded work"
        ! grep -q 'not landed' "$case_dir/stderr" \
          || fail "content-git-$mode: unavailable proof still claims work is not landed"
        if [ "$mode" = unsupported ]; then
          grep -q -- 'merge-tree --write-tree.*Git 2.38' "$case_dir/stderr" \
            || fail 'content-git-unsupported: missing capability and Git requirement were not named'
        else
          grep -q 'Git exit 128' "$case_dir/stderr" \
            || fail 'content-git-error: unrelated Git failure was not identified'
          ! grep -q 'Git 2.38' "$case_dir/stderr" \
            || fail 'content-git-error: unrelated failure was mislabeled as old Git'
        fi
        ;;
      *)
        grep -q 'not landed' "$case_dir/stderr" \
          || fail "content-git-$mode: genuine unlanded-work refusal changed"
        ! grep -q 'proof unavailable' "$case_dir/stderr" \
          || fail "content-git-$mode: supported Git was reported as unavailable"
        ;;
    esac
  done
  pass 'content fallback distinguishes unavailable Git proof, containment, conflicts, and unlanded content'
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_TEST_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  assert_present "$case_dir/treehouse.log" \
    "content-landed: teardown never reached destructive worktree cleanup"
  assert_absent "$case_dir/state/task-x1.meta" \
    "content-landed: teardown left task metadata after destructive cleanup"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

# A task recording base_branch= landed when its content reached that branch, not
# the default branch: a squash merge into the base branch is the landing.
test_content_fallback_uses_recorded_base_branch() {
  local case_dir rc landed tmp
  for landed in base default; do
    case_dir=$(make_case "content-base-$landed")
    write_meta "$case_dir" direct-PR ship
    printf 'base_branch=feature/hub\n' >> "$case_dir/state/task-x1.meta"
    tmp="$case_dir/_hub"
    git clone -q "$case_dir/origin.git" "$tmp"
    git -C "$tmp" push -q origin HEAD:refs/heads/feature/hub
    rm -rf "$tmp"
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    if [ "$landed" = base ]; then
      tmp="$case_dir/_land"
      git clone -q "$case_dir/origin.git" "$tmp"
      git -C "$tmp" checkout -q feature/hub
      printf 'hello\n' > "$tmp/feature.txt"
      git -C "$tmp" add feature.txt
      git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash feature.txt"
      git -C "$tmp" push -q origin HEAD:feature/hub
      rm -rf "$tmp"
    else
      land_on_origin_main "$case_dir" feature.txt hello
    fi
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    if [ "$landed" = base ]; then
      expect_code 0 "$rc" "content-base: content squashed into the recorded base branch should count as landed"
      assert_absent "$case_dir/state/task-x1.meta" "content-base: teardown kept the record of landed work"
    else
      [ "$rc" -ne 0 ] || fail "content-base: content only on the default branch passed for a task based on feature/hub"
      assert_present "$case_dir/state/task-x1.meta" "content-base: a refused teardown removed the task record"
    fi
  done
  pass "the content-landed fallback checks a task's recorded base branch, not the default branch"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_hidden_untracked_work_refuses_before_return() {
  local case_dir rc head state
  for state in dirty clean; do
    case_dir=$(make_case "hidden-untracked-$state")
    write_meta "$case_dir" no-mistakes ship
    git -C "$case_dir/wt" config status.showUntrackedFiles no
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    cp "$case_dir/state/task-x1.meta" "$case_dir/meta-before"
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  printf '%s\n' return >> "$FM_STATE_OVERRIDE/returned"
fi
exit 0
SH
    if [ "$state" = dirty ]; then
      mkdir "$case_dir/wt/new directory"
      printf '%s\n' 'unadded work' > "$case_dir/wt/new directory/newfile.txt"
      [ -z "$(git -C "$case_dir/wt" status --porcelain)" ] \
        || fail "hidden-untracked: fixture did not hide the unadded file"
    fi

    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$state" = dirty ]; then
      expect_code 1 "$rc" "hidden-untracked: teardown must refuse hidden unadded work"
      assert_grep 'REFUSED: worktree' "$case_dir/stderr" "hidden-untracked: no refusal"
      assert_grep 'uncommitted changes' "$case_dir/stderr" "hidden-untracked: no dirty-state diagnostic"
      assert_grep 'new directory/newfile.txt' "$case_dir/stderr" "hidden-untracked: unadded path not named"
      assert_absent "$case_dir/state/returned" "hidden-untracked: pool return ran before refusal"
      assert_refusal_retained_task_state "$case_dir" hidden-untracked "$head"
      cmp -s "$case_dir/meta-before" "$case_dir/state/task-x1.meta" \
        || fail "hidden-untracked: refusal changed task metadata"
      [ "$(cat "$case_dir/wt/new directory/newfile.txt")" = 'unadded work' ] \
        || fail "hidden-untracked: refusal changed or erased unadded work"
    else
      expect_code 0 "$rc" "hidden-untracked: clean control should complete teardown"
      assert_grep 'return' "$case_dir/state/returned" "hidden-untracked: clean control never reached pool return"
      assert_absent "$case_dir/state/task-x1.meta" "hidden-untracked: clean control kept task metadata"
    fi
  done
  pass "hidden untracked work is refused before return while a clean control returns"
}

assert_dirty_diagnostic() {
  local kind=$1 mode=$2 case_dir rc before n
  case_dir=$(make_case "dirty-$kind-$mode")
  write_meta "$case_dir" "$mode" ship
  wt_commit_file "$case_dir" feature.txt hello
  # Exercise both dirty refusal sites: remote-reachable work and local-only
  # work merged into local main but absent from every remote.
  if [ "$mode" = local-only ]; then
    git -C "$case_dir/project" merge -q --ff-only fm/task-x1
  else
    git -C "$case_dir/wt" push -q origin fm/task-x1
  fi
  if [ "$kind" != untracked ]; then
    printf '%s\n' 'uncommitted edit' > "$case_dir/wt/feature.txt"
    # Cover index edits as well as unstaged edits.
    [ "$mode" != local-only ] || git -C "$case_dir/wt" add feature.txt
  fi
  if [ "$kind" != tracked ]; then
    mkdir "$case_dir/wt/00 proof scratch"
    printf '%s\n' 'manual server log' > "$case_dir/wt/00 proof scratch/server.log"
    for n in 01 02 03 04 05 06 07 08 09 10 11; do
      touch "$case_dir/wt/$n-scratch.txt"
    done
    # Preserve the existing exemptions without counting them as leftovers.
    mkdir "$case_dir/wt/.claude"
    touch "$case_dir/wt/.claude/settings.local.json" "$case_dir/wt/.fm-grok-turnend"
  fi
  before=$(git -C "$case_dir/wt" status --porcelain)
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$kind/$mode: dirty teardown must still refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "$kind/$mode: no refusal"
  if [ "$kind" = untracked ]; then
    grep -Fq 'uncommitted changes present (untracked-only leftovers)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing untracked-only classification"
    ! grep -q 'includes tracked edits' "$case_dir/stderr" || fail "$kind/$mode: misclassified as tracked"
  else
    grep -Fq 'uncommitted changes present (includes tracked edits)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing tracked-edit classification"
    ! grep -q 'untracked-only' "$case_dir/stderr" || fail "$kind/$mode: misclassified as untracked-only"
  fi
  if [ "$kind" != tracked ]; then
    grep -Fq '00 proof scratch/' "$case_dir/stderr" || fail "$kind/$mode: scratch folder not named"
    grep -Fxq '  09-scratch.txt' "$case_dir/stderr" || fail "$kind/$mode: tenth path missing"
    ! grep -q '10-scratch.txt\|11-scratch.txt\|\.claude/\|\.fm-grok-turnend' "$case_dir/stderr" \
      || fail "$kind/$mode: path list exceeded its bound or included exempt files"
    grep -Fq 'additional untracked paths omitted' "$case_dir/stderr" || fail "$kind/$mode: no truncation notice"
  else
    ! grep -q 'untracked paths' "$case_dir/stderr" || fail "$kind/$mode: invented untracked paths"
  fi
  [ -f "$case_dir/state/task-x1.meta" ] || fail "$kind/$mode: task metadata removed"
  [ "$before" = "$(git -C "$case_dir/wt" status --porcelain)" ] || fail "$kind/$mode: worktree changed"
  pass "$kind/$mode: dirty refusal classifies leftovers and preserves work"
}

test_untracked_only_refusal_diagnostic() {
  assert_dirty_diagnostic untracked no-mistakes
  assert_dirty_diagnostic untracked local-only
}

test_tracked_edit_refusal_diagnostic() {
  assert_dirty_diagnostic tracked no-mistakes
  assert_dirty_diagnostic tracked local-only
}

test_mixed_refusal_diagnostic() {
  assert_dirty_diagnostic mixed no-mistakes
  assert_dirty_diagnostic mixed local-only
}

# Treehouse's return runs `git clean -fd` (one -f). A nested repository stays.
add_treehouse_clean_fd() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Return succeeds, then plants a nested repository the pre-return scrub cannot
# have removed. The post-return check must name that residue.
add_treehouse_that_leaves_residue() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
    git init -q "$wt/left-behind-clone"
    git -C "$wt/left-behind-clone" commit -q --allow-empty -m residue
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

prepare_scout_teardown() {
  local case_dir=$1
  mkdir -p "$case_dir/data/task-x1"
  printf '%s\n' 'Scout report.' > "$case_dir/data/task-x1/report.md"
  printf '%s\n' 'decisions_reviewed=1' >> "$case_dir/state/task-x1.meta"
}

# Clone a nested repository into the copy and add one plain scratch file.
seed_nested_clone_and_scratch() {
  local case_dir=$1 wt=$2
  git init -q "$case_dir/nested-src"
  printf 'payload\n' > "$case_dir/nested-src/payload.txt"
  git -C "$case_dir/nested-src" add payload.txt
  git -C "$case_dir/nested-src" -c user.email=t@t -c user.name=t commit -q -m payload
  git clone -q "$case_dir/nested-src" "$wt/scratch-clone"
  printf 'scratch\n' > "$wt/scratch.txt"
}

# Move the case worktree to pool/<slot>/repo so teardown sees a Treehouse slot.
move_case_to_pool_slot() {
  local case_dir=$1 slot=$2 dest
  dest="$case_dir/pool/$slot/repo"
  mkdir -p "$case_dir/pool/$slot"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$dest"
  printf '{"worktrees":[{"name":"%s","path":"%s"}]}\n' "$slot" "$dest" \
    > "$case_dir/pool/treehouse-state.json"
  printf '%s\n' "$dest"
}

test_scout_nested_clone_returns_with_no_untracked_entries() {
  local case_dir wt rc
  case_dir=$(make_case scout-nested-clean)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-nested-clean: teardown should return the scratch copy"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-nested-clean: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  assert_absent "$wt/scratch-clone" "scout-nested-clean: nested clone survived return"
  assert_absent "$wt/scratch.txt" "scout-nested-clean: scratch file survived return"
  pass "scout copy with a nested clone and a scratch file returns with no untracked entries"
}

test_ship_nested_clone_is_refused_and_bytes_stay() {
  local case_dir wt rc head before after
  case_dir=$(make_case ship-nested-refuse)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes ship
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  before=$(cksum "$wt/scratch-clone/payload.txt")
  head=$(git -C "$wt" rev-parse HEAD)
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ship-nested-refuse: teardown should refuse a nested clone"
  assert_grep "REFUSED" "$case_dir/stderr" "ship-nested-refuse: no REFUSED line"
  assert_grep "uncommitted changes" "$case_dir/stderr" \
    "ship-nested-refuse: refusal did not cite uncommitted changes"
  after=$(cksum "$wt/scratch-clone/payload.txt")
  [ "$before" = "$after" ] || fail "ship-nested-refuse: nested clone bytes changed"
  assert_present "$wt/scratch-clone/.git" "ship-nested-refuse: nested repository was removed"
  assert_present "$wt/scratch.txt" "ship-nested-refuse: scratch file was removed"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "ship-nested-refuse: refusal returned the copy: $(cat "$case_dir/treehouse.log")"
  assert_refusal_retained_task_state "$case_dir" "ship-nested-refuse" "$head"
  pass "ship copy with a nested clone is refused and its bytes stay"
}

test_dirty_return_warns_which_slot_was_lost() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return)
  wt=$(move_case_to_pool_slot "$case_dir" 9)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_leaves_residue "$case_dir"

  set +e
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 4 "$rc" "dirty-return: a lost slot should exit 4 after cleanup"
  assert_grep "pool slot 9" "$case_dir/stderr" "dirty-return: warning did not name the slot"
  assert_grep "left-behind-clone" "$case_dir/stderr" "dirty-return: warning did not name the remaining path"
  assert_grep "lost this slot" "$case_dir/stderr" "dirty-return: warning did not say the pool lost the slot"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "dirty-return: stdout still reported a clean return"
  assert_grep "Backlog: task-x1" "$case_dir/stdout" \
    "dirty-return: the finished teardown skipped its backlog reminder"
  assert_absent "$case_dir/state/task-x1.meta" "dirty-return: task record was not removed"
  pass "a return that leaves residue names the lost slot and the remaining paths"
}

test_dirty_return_warns_even_when_a_later_step_refuses() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return-later-refusal)
  wt=$(move_case_to_pool_slot "$case_dir" 8)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_leaves_residue "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window) exit 1 ;;
  list-windows) printf '%s\n' fm-task-x1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-return-later-refusal: the endpoint refusal should fail teardown"
  assert_grep "could not be closed" "$case_dir/stderr" \
    "dirty-return-later-refusal: fixture did not reach the endpoint close refusal"
  assert_grep "pool slot 8" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the lost-slot warning"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the remaining paths"
  pass "a dirty return is reported even when a later teardown step refuses"
}

test_forced_secondmate_child_scout_nested_clone_returns_clean() {
  local case_dir home child_wt rc
  case_dir=$(make_case secondmate-child-nested-clean)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/child-scout-wt"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  fm_write_meta "$home/state/child-scout.meta" \
    "window=firstmate:fm-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  seed_nested_clone_and_scratch "$case_dir" "$child_wt"
  add_treehouse_clean_fd "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "secondmate-child-nested-clean: forced secondmate teardown should succeed"
  [ -z "$(git -C "$child_wt" status --porcelain --untracked-files=all)" ] \
    || fail "secondmate-child-nested-clean: untracked entries remain: $(git -C "$child_wt" status --porcelain --untracked-files=all)"
  assert_absent "$child_wt/scratch-clone" "secondmate-child-nested-clean: nested clone survived return"
  assert_absent "$child_wt/scratch.txt" "secondmate-child-nested-clean: scratch file survived return"
  assert_no_grep "lost this slot" "$case_dir/stderr" \
    "secondmate-child-nested-clean: a clean child return was reported as a lost slot"
  pass "a forced secondmate teardown returns a child scout copy with a nested clone clean"
}

# Return succeeds but leaves no readable worktree behind to verify.
add_treehouse_that_removes_copy() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  for a in "$@"; do wt=$a; done
  rm -f "$wt/.git"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# The remote host runs exactly this forced secondmate teardown for
# `fm-remote-secondmate-control.sh retire --force`; the local side finishes the
# route, record, and reply-source cleanup when it exits 0 or 4 (lost slot).
test_forced_secondmate_dirty_child_return_warns_and_completes() {
  local case_dir home child_wt rc
  case_dir=$(make_case secondmate-child-dirty-return)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/pool/6/repo"
  mkdir -p "$case_dir/pool/6"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  printf '{"worktrees":[{"name":"6","path":"%s"}]}\n' "$child_wt" \
    > "$case_dir/pool/treehouse-state.json"
  fm_write_meta "$home/state/child-scout.meta" \
    "window=firstmate:fm-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  add_treehouse_that_leaves_residue "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "secondmate-child-dirty-return: a lost child slot should exit 4 after retirement"
  assert_grep "lost this slot" "$case_dir/stderr" \
    "secondmate-child-dirty-return: no lost-slot warning for the dirty child return"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "secondmate-child-dirty-return: warning did not name the remaining path"
  assert_absent "$case_dir/state/task-x1.meta" "secondmate-child-dirty-return: task record was not removed"
  assert_absent "$home" "secondmate-child-dirty-return: secondmate home was not removed"
  pass "a forced secondmate teardown warns about a dirty child return and still completes"
}

test_return_that_removes_copy_warns_cannot_verify() {
  local case_dir wt rc
  case_dir=$(make_case return-removes-copy)
  wt=$(move_case_to_pool_slot "$case_dir" 7)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_removes_copy "$case_dir"

  rc=0
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "return-removes-copy: an unverified slot should exit 4 after cleanup"
  assert_grep "lost this slot" "$case_dir/stderr" "return-removes-copy: no lost-slot warning"
  assert_grep "cannot verify" "$case_dir/stderr" "return-removes-copy: warning did not say the slot is unverified"
  assert_grep "$wt" "$case_dir/stderr" "return-removes-copy: warning did not name the copy"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "return-removes-copy: stdout still reported a clean return"
  assert_absent "$case_dir/state/task-x1.meta" "return-removes-copy: task record was not removed"
  pass "a return that leaves no readable copy reports the slot as unverified, not clean"
}

test_scout_ignored_files_survive_scratch_clean() {
  local case_dir wt rc
  case_dir=$(make_case scout-ignored-survives)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  printf '%s\n' 'ignored-cache/' > "$wt/.gitignore"
  git -C "$wt" add .gitignore
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m "ignore cache"
  mkdir -p "$wt/ignored-cache"
  printf 'keep-me\n' > "$wt/ignored-cache/blob"
  printf 'scratch\n' > "$wt/scratch.txt"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-ignored: teardown should succeed"
  [ "$(cat "$wt/ignored-cache/blob")" = "keep-me" ] \
    || fail "scout-ignored: ignored file was removed or changed"
  assert_absent "$wt/scratch.txt" "scout-ignored: scratch file survived"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-ignored: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  pass "ignored files survive the scratch clean and plain scratch does not"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

# Write a meta that predates the spawn_gen field entirely. Args: case_dir mode kind
write_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

# Count spawn_gen fields in the task's meta, so a refusal can prove it left the
# record byte-equivalent rather than stamped.
legacy_meta_gen_count() {
  local case_dir=$1
  awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' \
    "$case_dir/state/task-x1.meta" 2>/dev/null || printf '0\n'
}
