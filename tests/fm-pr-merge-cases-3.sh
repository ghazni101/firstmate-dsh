# shellcheck shell=bash
# Test cases for fm-pr-merge, split out of tests/fm-pr-merge.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-pr-merge.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner



# The race this closes: a branch merge passes the opening partition
# because the live record exists, then the captain returns and archives that
# record during the slow forge preflight. The locked authority recheck must
# treat that archive as absence and refuse the branch before gh pr merge.
# An empty away-record-after-view file is the mock's archive-during-view hook.
test_away_branch_refuses_when_record_archived_during_preflight() {
  local case_dir rc url head
  head=a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7
  url=https://github.com/example/repo/pull/127

  case_dir=$(make_case away-branch-archived-during-preflight)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  : > "$case_dir/away-record-after-view"
  set +e
  FM_SUPERVISION_ACTOR=branch FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 6 "$rc" "away-branch-archived-during-preflight: an archived record must refuse the branch under the lock"
  assert_grep 'main is parked' "$case_dir/stderr" \
    "away-branch-archived-during-preflight: the opening partition never saw the live record"
  assert_grep 'the supervision branch never performs this action' "$case_dir/stderr" \
    "away-branch-archived-during-preflight: refusal lost the partition wording"
  assert_grep 'pr view' "$case_dir/gh.log" \
    "away-branch-archived-during-preflight: the forge preflight never ran"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-branch-archived-during-preflight: gh pr merge ran after the record was archived"
  pass "a branch merge refuses under the lock when the away record is archived during preflight"
}

test_away_posture_refuses_asynchronous_merge_paths() {
  local case_dir rc url head merge_line
  head=abababababababababababababababababababab
  url=https://github.com/example/repo/pull/89

  case_dir=$(make_case away-auto-refused)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-auto-refused: auto-merge must be attended-only"
  assert_grep '--auto is attended-only' "$case_dir/stderr" \
    "away-auto-refused: refusal did not name the asynchronous flag"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-auto-refused: gh pr merge ran for an away auto-merge request"

  case_dir=$(make_case away-queue-refused)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-queue-refused: a required merge queue must refuse before submission"
  assert_grep 'merge-queue state does not prove an immediate merge' "$case_dir/stderr" \
    "away-queue-refused: refusal did not explain the away restriction"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-queue-refused: gh received a merge that could enter its queue"

  case_dir=$(make_gitlab_case away-gitlab-auto)
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --attended-override -- --auto-merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-gitlab-auto: GitLab auto-merge must refuse"
  assert_grep 'GitLab auto-merge is attended-only' "$case_dir/stderr" \
    "away-gitlab-auto: refusal did not name auto-merge"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "away-gitlab-auto: glab received an asynchronous merge"

  case_dir=$(make_gitlab_case away-gitlab-configured merge_when_pipeline_succeeds=true)
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-gitlab-configured: configured auto-merge must refuse"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "away-gitlab-configured: glab received a configured asynchronous merge"

  case_dir=$(make_gitlab_case away-gitlab-sync)
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "away-gitlab-sync: an immediate merge under the record should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *" --auto-merge=false") ;;
    *) fail "away-gitlab-sync: the final glab flag did not force an immediate merge: '$merge_line'" ;;
  esac
  pass "away posture permits immediate merges but refuses every asynchronous path"
}

test_away_record_does_not_bypass_red_or_identity() {
  local case_dir rc head
  head=adadadadadadadadadadadadadadadadadadadad
  case_dir=$(make_case away-record-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-record-red: the record must not waive red checks"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "away-record-red: C1 did not refuse the red check"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-record-red: gh pr merge ran on a red PR while away"

  case_dir=$(make_case pr-identity-mismatch)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '\npr=https://github.com/example/repo/pull/99\n' >> "$case_dir/state/task-x1.meta"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/85 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "pr-identity: a different recorded URL must refuse"
  assert_grep 'is bound to https://github.com/example/repo/pull/99' "$case_dir/stderr" \
    "pr-identity: refusal did not name the recorded URL"
  pass "the away record does not bypass red checks, and a recorded pr= must match the URL"
}

test_unreadable_away_record_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case away-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae
  printf 'not-a-contract\n' > "$case_dir/state/.afk-contract"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/86 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-unreadable: an unreadable away record must refuse"
  assert_grep 'away-posture record could not be read' "$case_dir/stderr" \
    "away-unreadable: refusal did not fail closed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-unreadable: gh pr merge ran despite an unreadable record"
  pass "an unreadable away-posture record refuses the merge instead of skipping the record"
}

# The race this closes: the away record is read for merge authority and the
# forge is called afterwards, so an archive (the captain's return) or a
# replacement of the words landing in between would merge on authority that no
# longer holds.
# away_change_script writes the change the gh mock attempts from inside the
# forge call, which IS that window. Its body drives the real away-record
# commands /afk and the return use, never a file edit, and takes a one-second
# lock bound so a contended case refuses quickly instead of waiting.
away_change_script() {  # <case-dir> <name>; script body on stdin
  local case_dir=$1 name=$2 path
  path="$case_dir/$name"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -eu\n'
    printf 'export FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1\n'
    printf 'CONTRACT="%s/bin/fm-afk-contract.sh"\n' "$ROOT"
    cat
  } > "$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

# Two away-record changes, each attempted from inside the merge's critical
# section: the archive a captain return performs, and the replacement /afk with
# new words performs. Neither may land there, and the merge must still complete
# on the authority it read.
test_away_record_cannot_change_between_the_authority_read_and_the_merge() {
  local case_dir rc mutate
  case_dir=$(make_case away-archive-at-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  mutate=$(away_change_script "$case_dir" archive-at-merge <<'SH'
"$CONTRACT" archive
SH
  )

  export FM_TEST_AWAY_MUTATE_AT_MERGE="$mutate"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AWAY_MUTATE_AT_MERGE

  expect_code 0 "$rc" "away-archive-at-merge: the green merge should still land"
  [ -s "$case_dir/away-mutate-rc" ] \
    || fail "away-archive-at-merge: the archive was never attempted inside the merge"
  [ "$(cat "$case_dir/away-mutate-rc")" != 0 ] \
    || fail "away-archive-at-merge: the archive landed inside the merge's critical section"
  assert_grep 'locked by live process' "$case_dir/away-mutate-output" \
    "away-archive-at-merge: the refused archive did not name the live holder"
  assert_equals 'merge task-x1 when green' "$(cat "$case_dir/away-words-at-merge" 2>/dev/null || true)" \
    "away-archive-at-merge: the record this merge read was not still standing at the forge call"
  assert_grep "merge landed: task-x1 https://github.com/example/repo/pull/71 away" \
    "$case_dir/state/.wake-queue" \
    "away-archive-at-merge: the landed merge was not recorded under the away authority it read"
  # The lock goes with the merge rather than leaking: the captain's return
  # archives the record on its first try once the merge is done.
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null \
    || fail "away-archive-at-merge: the record stayed locked after the merge"

  case_dir=$(make_case away-replace-at-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  mutate=$(away_change_script "$case_dir" replace-at-merge <<'SH'
"$CONTRACT" enter --words 'hold everything for my return'
SH
  )
  export FM_TEST_AWAY_MUTATE_AT_MERGE="$mutate"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AWAY_MUTATE_AT_MERGE

  expect_code 0 "$rc" "away-replace-at-merge: the green merge should still land"
  [ "$(cat "$case_dir/away-mutate-rc" 2>/dev/null || true)" != 0 ] \
    || fail "away-replace-at-merge: the replacement landed inside the critical section"
  assert_equals 'merge task-x1 when green' "$(cat "$case_dir/away-words-at-merge" 2>/dev/null || true)" \
    "away-replace-at-merge: the words were replaced inside the merge's critical section"
  pass "no away-record archive or replacement lands between the authority read and the merge"
}

# The same serialization from the other side. A record change that wins the
# race lands BEFORE the in-lock authority read, and the merge then answers to
# what it finds there: an unreadable record refuses rather than merging on the
# record the opening partition saw. The lock decides an order, it never lets a
# stale read through.
test_a_record_made_unreadable_before_the_merge_refuses_it() {
  local case_dir rc
  case_dir=$(make_case away-unreadable-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d
  printf 'not-a-contract\n' > "$case_dir/away-record-after-view"
  write_away_record "$case_dir" --words 'merge task-x1 when green'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "away-unreadable-before-merge: a record made unreadable before the authority read must refuse"
  assert_grep 'away-posture record could not be read' "$case_dir/stderr" \
    "away-unreadable-before-merge: refusal did not fail closed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-unreadable-before-merge: gh pr merge ran on a record that could not be read"
  pass "a record made unreadable before the merge's own authority read refuses the merge"
}

# Fail closed. The lock is what makes the authority read and the merge one
# action, so a merge that cannot take it has no locked window to merge in and
# refuses - including on this attended case, where the record is absent and
# there is no away authority to read at all.
test_merge_refuses_when_the_away_record_cannot_be_locked() {
  local case_dir rc holder_pid i lock
  case_dir=$(make_case away-lock-unavailable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e
  lock="$case_dir/state/.afk-contract.lock"

  FM_STATE_OVERRIDE="$case_dir/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 10
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$case_dir/holder.ready" "$case_dir/release-holder" &
  holder_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$case_dir/holder.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$case_dir/holder.ready" ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "away-lock-unavailable: the fixture never took the record lock"; }

  export FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT
  : > "$case_dir/release-holder"
  wait "$holder_pid" || fail "away-lock-unavailable: the fixture holder did not release cleanly"

  expect_code 1 "$rc" "away-lock-unavailable: an unlockable away record must refuse the merge"
  assert_grep 'could not be locked for the merge' "$case_dir/stderr" \
    "away-lock-unavailable: refusal did not name the lock it could not take"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-lock-unavailable: gh pr merge ran without the away-record lock"
  pass "a merge that cannot lock the away record refuses instead of merging unlocked"
}

test_allow_red_refused_on_gitlab() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-allow-red)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "gitlab-allow-red: --allow-red must not apply on GitLab"
  assert_grep '--allow-red does not apply to GitLab' "$case_dir/stderr" \
    "gitlab-allow-red: refusal did not name GitLab"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-allow-red: glab ran despite --allow-red"
  pass "fm-pr-merge refuses --allow-red on GitLab"
}

# A required check that never reported has no entry in the rollup at all, so
# it can only be found missing by reading the forge's own required set. Each
# case drives the GitHub path through the public entrypoint with a faked forge.
# Args: case_dir pr_number [merge args]...; sets RC.
run_required_case() {
  local case_dir=$1 number=$2
  shift 2
  set +e
  run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$number" "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  RC=$?
  set -e
}

test_required_producer_identity() {
  local case_dir head kind variant expected app
  head=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
  for kind in classic ruleset; do
    for variant in wrong correct unreadable malformed stale waived; do
      case_dir=$(make_case "required-producer-$kind-$variant")
      add_gh_mocks "$case_dir" "$head"
      write_github_required "$case_dir" "$kind:ci"
      if [ "$kind" = classic ]; then
        jq '.protection.required_status_checks.checks[0].app_id = 15368' \
          "$case_dir/github-branch.json" > "$case_dir/updated.json"
        mv "$case_dir/updated.json" "$case_dir/github-branch.json"
      else
        jq '.[1].parameters.required_status_checks[0].integration_id = 15368' \
          "$case_dir/github-required-rules.json" > "$case_dir/updated.json"
        mv "$case_dir/updated.json" "$case_dir/github-required-rules.json"
      fi
      app=42
      [ "$variant" != correct ] || app=15368
      printf '{"check_runs":[{"name":"ci","app":{"id":%s},"head_sha":"%s"}]}\n' \
        "$app" "$head" > "$case_dir/github-runs.json"
      case "$variant" in
        unreadable) rm "$case_dir/github-runs.json" ;;
        malformed) printf '{}' > "$case_dir/github-runs.json" ;;
        stale) printf '{"check_runs":[{"name":"ci","app":{"id":15368},"head_sha":"bbbb"}]}' > "$case_dir/github-runs.json" ;;
      esac
      expected=1
      if [ "$variant" = waived ]; then
        run_required_case "$case_dir" 110 --attended-override --allow-missing ci -- --admin
        expected=0
      else
        run_required_case "$case_dir" 110 --attended-override -- --admin
        [ "$variant" != correct ] || expected=0
      fi
      expect_code "$expected" "$RC" "producer-$kind-$variant: $(cat "$case_dir/stderr")"
      if [ "$expected" = 1 ]; then
        assert_grep "required check 'ci' has not reported" "$case_dir/stderr" "producer absence not reported"
        assert_no_grep 'pr merge' "$case_dir/gh.log" "wrong producer reached merge"
      else
        assert_grep 'pr merge' "$case_dir/gh.log" "accepted producer did not merge"
      fi
      case "$variant" in
        unreadable|malformed|stale)
          assert_grep 'required check producers at head' "$case_dir/stderr" "producer read error not reported" ;;
      esac
    done
  done
  pass "fm-pr-merge enforces required producer identity and named waivers"
}

# A commit status carries no app id to compare, so an app-bound required context
# that arrives as a green status matches by name, while the same context left
# unreported still refuses.
test_app_bound_required_status_context_matches_by_name() {
  local case_dir head kind variant
  head=a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7
  for kind in classic ruleset; do
    for variant in reported absent; do
      case_dir=$(make_case "required-app-status-$kind-$variant")
      add_gh_mocks "$case_dir" "$head"
      if [ "$variant" = reported ]; then
        write_github_rollup_json "$case_dir" "$head" \
          "$(check_run ci COMPLETED SUCCESS)" \
          "$(status_context 'license/cla' SUCCESS)"
      fi
      write_github_required "$case_dir" "$kind:license/cla"
      if [ "$kind" = classic ]; then
        jq '.protection.required_status_checks.checks[0].app_id = 865473' \
          "$case_dir/github-branch.json" > "$case_dir/updated.json"
        mv "$case_dir/updated.json" "$case_dir/github-branch.json"
      else
        jq '.[1].parameters.required_status_checks[0].integration_id = 865473' \
          "$case_dir/github-required-rules.json" > "$case_dir/updated.json"
        mv "$case_dir/updated.json" "$case_dir/github-required-rules.json"
      fi
      printf '{"check_runs":[{"name":"ci","app":{"id":42},"head_sha":"%s"}]}\n' \
        "$head" > "$case_dir/github-runs.json"
      run_required_case "$case_dir" 111
      if [ "$variant" = reported ]; then
        expect_code 0 "$RC" "app-status-$kind-reported: a green app-bound status must merge: $(cat "$case_dir/stderr")"
        assert_logged_gh_merge "$case_dir" 111 example/repo --squash
      else
        expect_code 1 "$RC" "app-status-$kind-absent: an unreported app-bound status must refuse"
        assert_grep "required check 'license/cla' has not reported" "$case_dir/stderr" \
          "app-status-$kind-absent: the unreported status was not named"
        assert_no_grep 'pr merge' "$case_dir/gh.log" \
          "app-status-$kind-absent: gh pr merge ran with the status unreported"
      fi
    done
  done
  pass "fm-pr-merge matches an app-bound required commit status by name"
}

test_required_partial_reads_report_all_failures() {
  local case_dir head variant
  head=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
  for variant in branch rules both; do
    case_dir=$(make_case "required-partial-$variant")
    add_gh_mocks "$case_dir" "$head"
    write_github_required "$case_dir" classic:validate ruleset:lint
    case "$variant" in
      branch|both) printf 'read failed' > "$case_dir/github-branch-fail" ;;
    esac
    case "$variant" in
      rules|both) printf 'read failed' > "$case_dir/github-required-rules-fail" ;;
    esac
    run_required_case "$case_dir" 111
    expect_code 1 "$RC" "partial-$variant must refuse"
    case "$variant" in
      branch|both) assert_grep 'branch protection summary for base branch main could not be read' "$case_dir/stderr" "lost branch error" ;;
    esac
    case "$variant" in
      rules|both) assert_grep 'branch rules for base branch main could not be read' "$case_dir/stderr" "lost rules error" ;;
    esac
    case "$variant" in
      branch) assert_grep "required check 'lint' has not reported" "$case_dir/stderr" "lost rules requirement" ;;
      rules) assert_grep "required check 'validate' has not reported" "$case_dir/stderr" "lost classic requirement" ;;
    esac
    assert_no_grep 'pr merge' "$case_dir/gh.log" "partial read reached merge"
  done
  pass "fm-pr-merge reports known missing checks and all independent read errors"
}

test_required_check_that_never_reported_refuses() {
  local case_dir head kind
  head=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
  for kind in classic ruleset; do
    case_dir=$(make_case "github-required-absent-$kind")
    add_gh_mocks "$case_dir" "$head"
    write_github_required "$case_dir" "$kind:ci" "$kind:validate"
    run_required_case "$case_dir" 90
    expect_code 1 "$RC" "required-absent-$kind: an unreported required check must refuse"
    assert_grep "required check 'validate' has not reported at head $head" "$case_dir/stderr" \
      "required-absent-$kind: the unreported required check was not named"
    assert_grep 'these required checks have not reported: validate' "$case_dir/stderr" \
      "required-absent-$kind: the summary did not name the unreported check"
    assert_no_grep "required check 'ci'" "$case_dir/stderr" \
      "required-absent-$kind: a reported green required check was called missing"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "required-absent-$kind: gh pr merge ran with a required check unreported"
    assert_no_grep 'verified: ' "$case_dir/stderr" \
      "required-absent-$kind: the refusal still claimed a verified head"
  done
  pass "fm-pr-merge refuses when a required check from branch protection or a ruleset never reported"
}

test_required_checks_reported_and_green_merge() {
  local case_dir head
  head=a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2
  case_dir=$(make_case github-required-present)
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS)" \
    "$(status_context 'license/cla' SUCCESS)"
  write_github_required "$case_dir" classic:ci ruleset:license/cla ruleset:ci
  run_required_case "$case_dir" 91
  expect_code 0 "$RC" "required-present: every required check reported and green must merge: $(cat "$case_dir/stderr")"
  assert_grep 'api repos/example/repo/branches/main' "$case_dir/gh.log" \
    "required-present: the branch protection summary was not read"
  assert_grep 'api --paginate repos/example/repo/rules/branches/main' "$case_dir/gh.log" \
    "required-present: the branch rules were not read"
  assert_grep "every unwaived required check reported and every unwaived check green at head $head" \
    "$case_dir/stderr" "required-present: the verified line did not state the required checks reported"
  assert_logged_gh_merge "$case_dir" 91 example/repo --squash
  pass "fm-pr-merge merges when every required check reported and is green"
}

test_red_and_unreported_checks_are_reported_together() {
  local case_dir head
  head=a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3
  case_dir=$(make_case github-red-and-unreported)
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run lint COMPLETED FAILURE)"
  sed 's/"isDraft":false/"isDraft":true/' "$case_dir/github-view.json" > "$case_dir/view.tmp"
  mv "$case_dir/view.tmp" "$case_dir/github-view.json"
  write_github_required "$case_dir" classic:lint ruleset:validate
  run_required_case "$case_dir" 92
  expect_code 1 "$RC" "red-and-unreported: must refuse"
  assert_grep 'the pull request is a draft' "$case_dir/stderr" \
    "red-and-unreported: the draft condition was dropped"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "red-and-unreported: the red check was dropped"
  assert_grep "required check 'validate' has not reported" "$case_dir/stderr" \
    "red-and-unreported: the unreported required check was dropped"
  assert_grep 'these checks are not green: lint' "$case_dir/stderr" \
    "red-and-unreported: the red summary was dropped"
  assert_grep 'these required checks have not reported: validate' "$case_dir/stderr" \
    "red-and-unreported: the unreported summary was dropped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "red-and-unreported: gh pr merge ran"
  pass "fm-pr-merge reports a red check and an unreported required check together with every other failure"
}

test_unreadable_required_set_refuses() {
  local case_dir head label
  head=a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4
  for label in branch-read-fails branch-shape rules-read-fails rules-forbidden rules-shape; do
    case_dir=$(make_case "github-required-unreadable-$label")
    add_gh_mocks "$case_dir" "$head"
    case "$label" in
      branch-read-fails)
        printf 'gh: Not Found (HTTP 404)\n' > "$case_dir/github-branch-fail"
        ;;
      branch-shape)
        printf '{"name":"main","protected":true}\n' > "$case_dir/github-branch.json"
        ;;
      rules-read-fails)
        printf 'gh: Not Found (HTTP 404)\n' > "$case_dir/github-required-rules-fail"
        ;;
      rules-forbidden)
        printf 'gh: Resource not accessible by personal access token (HTTP 403)\n' \
          > "$case_dir/github-required-rules-fail"
        ;;
      rules-shape)
        printf '[{"type":"required_status_checks","parameters":{}}]\n' \
          > "$case_dir/github-required-rules.json"
        ;;
    esac
    # A waiver names one check, so it can never stand in for a required set
    # that could not be read.
    run_required_case "$case_dir" 93 --allow-missing validate
    expect_code 1 "$RC" "required-unreadable-$label: an unreadable required set must refuse"
    case "$label" in
      branch-*)
        assert_grep 'the branch protection summary for base branch main could not be read, so a required check that has not reported cannot be ruled out' \
          "$case_dir/stderr" "required-unreadable-$label: the refusal did not name the unreadable source"
        ;;
      rules-*)
        assert_grep 'the branch rules for base branch main could not be read, so a required check that has not reported cannot be ruled out' \
          "$case_dir/stderr" "required-unreadable-$label: the refusal did not name the unreadable source"
        ;;
    esac
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "required-unreadable-$label: gh pr merge ran on an unreadable required set"
  done

  # GitHub's plan-gated refusal means the repository cannot have branch rules
  # at all, which is a readable answer, so the classic set alone decides.
  case_dir=$(make_case github-required-plan-gated)
  add_gh_mocks "$case_dir" "$head"
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)\n' \
    > "$case_dir/github-required-rules-fail"
  run_required_case "$case_dir" 94
  expect_code 0 "$RC" "required-plan-gated: a plan without branch rules must not read as unreadable: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 94 example/repo --squash

  case_dir=$(make_case github-required-plan-gated-classic-absent)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" classic:validate
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)\n' \
    > "$case_dir/github-required-rules-fail"
  run_required_case "$case_dir" 95
  expect_code 1 "$RC" "required-plan-gated-classic-absent: a classic required check must still be enforced"
  assert_grep "required check 'validate' has not reported" "$case_dir/stderr" \
    "required-plan-gated-classic-absent: the unreported classic check was not named"
  pass "fm-pr-merge refuses when the required checks cannot be read, and tells a plan without rules apart"
}

test_allow_missing_waives_only_the_named_unreported_check() {
  local case_dir head
  head=a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5

  case_dir=$(make_case github-allow-missing-named)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" classic:ci ruleset:validate
  run_required_case "$case_dir" 96 --allow-missing validate
  expect_code 0 "$RC" "allow-missing-named: the named waiver should merge: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 96 example/repo --squash

  case_dir=$(make_case github-allow-missing-other-missing)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate ruleset:e2e
  run_required_case "$case_dir" 97 --allow-missing validate
  expect_code 1 "$RC" "allow-missing-other-missing: another unreported check must still refuse"
  assert_grep "required check 'e2e' has not reported" "$case_dir/stderr" \
    "allow-missing-other-missing: the other unreported check was not named"
  assert_no_grep "required check 'validate'" "$case_dir/stderr" \
    "allow-missing-other-missing: the waived check was still reported"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-other-missing: gh pr merge ran with an unwaived unreported check"

  case_dir=$(make_case github-allow-missing-other-red)
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_github_required "$case_dir" ruleset:validate
  run_required_case "$case_dir" 98 --allow-missing validate
  expect_code 1 "$RC" "allow-missing-other-red: a red check must still refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "allow-missing-other-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-other-red: gh pr merge ran with a red check"

  # The waiver covers absence only: a required check that did report red is
  # not missing, and waiving it takes --allow-red.
  case_dir=$(make_case github-allow-missing-names-red)
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_github_required "$case_dir" classic:lint
  run_required_case "$case_dir" 99 --allow-missing lint
  expect_code 1 "$RC" "allow-missing-names-red: a reported red check must not be waived as missing"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "allow-missing-names-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-names-red: gh pr merge ran with a red required check"
  pass "fm-pr-merge --allow-missing waives only its named unreported check"
}

test_allow_missing_follows_the_allow_red_rules() {
  local case_dir head
  head=a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6

  case_dir=$(make_case github-allow-missing-equals)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate
  run_required_case "$case_dir" 100 --allow-missing=validate
  expect_code 2 "$RC" "allow-missing-equals: the equals form must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-equals: gh pr merge ran for the equals form"

  case_dir=$(make_case github-allow-missing-duplicate)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate ruleset:e2e
  run_required_case "$case_dir" 101 --allow-missing validate --allow-missing e2e
  expect_code 2 "$RC" "allow-missing-duplicate: a second waiver must be refused"
  assert_grep '--allow-missing may be specified only once' "$case_dir/stderr" \
    "allow-missing-duplicate: the refusal did not say single use"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-duplicate: gh pr merge ran for two waivers"

  case_dir=$(make_case github-allow-missing-away)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  run_required_case "$case_dir" 102 --allow-missing validate
  expect_code 2 "$RC" "allow-missing-away: the waiver must be refused while away"
  assert_grep '--allow-missing is attended-only' "$case_dir/stderr" \
    "allow-missing-away: the refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-away: gh pr merge ran despite an away waiver"

  case_dir=$(make_case github-allow-missing-away-after-view)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  mv "$case_dir/state/.afk-contract" "$case_dir/away-record-after-view"
  run_required_case "$case_dir" 102 --allow-missing validate
  expect_code 2 "$RC" "allow-missing-away-after-view: late away publication must refuse the waiver"
  assert_grep '--allow-missing is attended-only' "$case_dir/stderr" \
    "allow-missing-away-after-view: the late refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-away-after-view: gh pr merge ran after late away publication"

  case_dir=$(make_case github-unreported-away)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  run_required_case "$case_dir" 103
  expect_code 1 "$RC" "unreported-away: the away record must not waive an unreported check"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreported-away: gh pr merge ran with an unreported check while away"

  case_dir=$(make_gitlab_case gitlab-allow-missing)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-missing validate \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  RC=$?
  set -e
  expect_code 2 "$RC" "gitlab-allow-missing: the waiver must not apply on GitLab"
  assert_grep '--allow-missing does not apply to GitLab' "$case_dir/stderr" \
    "gitlab-allow-missing: the refusal did not name GitLab"
  assert_grep '--allow-no-pipeline waives only a merge request with no head pipeline' "$case_dir/stderr" \
    "gitlab-allow-missing: the refusal did not point at the GitLab no-pipeline waiver"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-allow-missing: glab ran despite the waiver"
  pass "fm-pr-merge --allow-missing is single use, attended-only, and GitHub-only like --allow-red"
}

test_allow_red_refused_on_forgejo() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-allow-red)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "forgejo-allow-red: --allow-red must not apply on Forgejo"
  assert_grep '--allow-red does not apply to Forgejo' "$case_dir/stderr" \
    "forgejo-allow-red: refusal did not name Forgejo"
  [ ! -s "$case_dir/tea.log" ] || fail "forgejo-allow-red: tea ran despite --allow-red"
  pass "fm-pr-merge refuses --allow-red on Forgejo"
}

test_allow_missing_refused_on_forgejo() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-allow-missing)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --allow-missing validate \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "forgejo-allow-missing: --allow-missing must not apply on Forgejo"
  assert_grep '--allow-missing does not apply to Forgejo' "$case_dir/stderr" \
    "forgejo-allow-missing: refusal did not name Forgejo"
  [ ! -s "$case_dir/tea.log" ] || fail "forgejo-allow-missing: tea ran despite --allow-missing"
  pass "fm-pr-merge refuses --allow-missing on Forgejo"
}

# --allow-no-pipeline is for a GitLab repository that deliberately runs no merge
# request pipeline: it waives only a head_pipeline GitLab reports as null, and
# the merge stays bound to the verified head.
test_allow_no_pipeline_merges_only_a_null_head_pipeline() {
  local case_dir rc merge_line name spec expected
  case_dir=$(make_gitlab_case gitlab-no-pipeline-waived pipeline=null)
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-no-pipeline \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-no-pipeline-waived: a merge request with no head pipeline should merge: $(cat "$case_dir/stderr")"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "gitlab-no-pipeline-waived: unexpected merge invocation: '$merge_line'"
  assert_grep "at head $MR_HEAD, with no head pipeline, waived by --allow-no-pipeline" "$case_dir/stderr" \
    "gitlab-no-pipeline-waived: the waived verification was not reported"

  case_dir=$(make_gitlab_case gitlab-no-pipeline-flag-absent pipeline=null)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-no-pipeline-flag-absent: no head pipeline must still refuse by default"
  assert_grep 'the head pipeline status is "none", not success' "$case_dir/stderr" \
    "gitlab-no-pipeline-flag-absent: the refusal did not name the missing pipeline"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-no-pipeline-flag-absent: a merge was attempted without the waiver"

  # A pipeline that exists is a verdict, never an absence, so the waiver does
  # not reach it; and every other condition still holds beside the waiver.
  set -- \
    "failed|pipeline_status=failed|the head pipeline status is \"failed\", not success" \
    "running|pipeline_status=running|the head pipeline status is \"running\", not success" \
    "canceled|pipeline_status=canceled|the head pipeline status is \"canceled\", not success" \
    "stale|pipeline_sha=$MR_STALE_HEAD|the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD" \
    "not-mergeable|pipeline=null detail=ci_must_pass|detailed_merge_status is \"ci_must_pass\", not mergeable" \
    "discussions|pipeline=null discussions=false|blocking_discussions_resolved is \"false\", not true" \
    "conflicts|pipeline=null conflicts=true|has_conflicts is \"true\", not false"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    # shellcheck disable=SC2086 # the field list is deliberately word-split
    case_dir=$(make_gitlab_case "gitlab-no-pipeline-refuse-$name" ${spec%%|*})
    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-no-pipeline \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "gitlab-no-pipeline-refuse-$name: the waiver must not merge"
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-no-pipeline-refuse-$name: the refusal did not name the failing condition"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-no-pipeline-refuse-$name: a merge was attempted despite the refusal"
  done

  # An absent head_pipeline field is unreadable state, not a reported absence.
  case_dir=$(make_gitlab_case gitlab-no-pipeline-field-missing)
  "$JQ_BIN" -c 'del(.head_pipeline)' "$case_dir/mr.json" > "$case_dir/mr.json.new"
  mv "$case_dir/mr.json.new" "$case_dir/mr.json"
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-no-pipeline \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-no-pipeline-field-missing: an unread pipeline field must not be waived"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-no-pipeline-field-missing: a merge was attempted on an unread pipeline field"
  pass "fm-pr-merge --allow-no-pipeline waives only a null GitLab head pipeline and keeps every other condition"
}

test_allow_no_pipeline_is_attended_only_and_gitlab_only() {
  local case_dir rc head
  case_dir=$(make_gitlab_case gitlab-no-pipeline-away pipeline=null)
  write_away_record "$case_dir" --words 'merge task-x1'
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-no-pipeline \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "gitlab-no-pipeline-away: the waiver must be refused while away"
  assert_grep '--allow-no-pipeline is attended-only' "$case_dir/stderr" \
    "gitlab-no-pipeline-away: the refusal did not name attended-only"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-no-pipeline-away: glab merged despite an away waiver"

  case_dir=$(make_gitlab_case gitlab-no-pipeline-equals pipeline=null)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-no-pipeline=true \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "gitlab-no-pipeline-equals: a value must be refused"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-no-pipeline-equals: glab ran for a valued flag"

  head=abababababababababababababababababababab
  case_dir=$(make_case github-no-pipeline)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/88 --allow-no-pipeline \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-no-pipeline: the waiver must not apply on GitHub"
  assert_grep '--allow-no-pipeline applies only to GitLab' "$case_dir/stderr" \
    "github-no-pipeline: the refusal did not name GitLab"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-no-pipeline: gh pr merge ran despite the waiver"

  case_dir=$(make_forgejo_case forgejo-no-pipeline)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --allow-no-pipeline \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "forgejo-no-pipeline: the waiver must not apply on Forgejo"
  assert_grep '--allow-no-pipeline applies only to GitLab' "$case_dir/stderr" \
    "forgejo-no-pipeline: the refusal did not name GitLab"
  [ ! -s "$case_dir/tea.log" ] || fail "forgejo-no-pipeline: tea ran despite the waiver"
  pass "fm-pr-merge --allow-no-pipeline is attended-only, takes no value, and applies only to GitLab"
}

test_gitlab_head_override_args_refuse_before_recording
test_secondmate_merge_reports_upward_once
test_secondmate_merge_reports_on_the_local_route
test_gitlab_merge_reports_upward
test_queued_gitlab_merge_leaves_the_poll_armed
test_failed_merge_reports_nothing
test_gitlab_refusal_reports_nothing
test_main_home_merge_leaves_a_durable_wake
test_queued_github_merge_leaves_the_poll_armed
test_distinct_merged_prs_keep_distinct_wakes
test_uncommitted_marker_retry_is_never_silent
test_secondmate_without_parent_binding_is_loud
test_absent_backlog_still_merges
test_unreadable_backlog_refuses_the_merge
test_unreadable_backend_config_refuses_the_merge
test_unreadable_user_backend_config_refuses_the_merge
test_untraversable_user_backend_config_directory_refuses_the_merge
test_absent_user_backend_config_directory_and_backlog_still_merge
test_backend_override_bypasses_unreadable_user_config
test_github_behind_update_requires_opt_in_and_passing_guards
test_github_behind_update_keeps_expected_head_pin
test_github_updated_head_failure_refuses_without_waiting_for_pending
test_github_behind_updates_and_rechecks_before_merge
test_github_red_checks_refuse_and_allow_red_waives_named
test_github_draft_or_unreadable_draft_state_refuses
test_superseded_failed_check_run_no_longer_refuses
test_check_runs_never_supersede_status_contexts
test_current_failed_check_run_still_refuses
test_late_finishing_old_success_does_not_hide_current_failure
test_late_finishing_old_cancellation_is_superseded
test_unfinished_rerun_keeps_a_check_red
test_supersession_never_crosses_check_names
test_undated_runs_never_supersede
test_allow_red_still_waives_only_the_current_failure
test_allow_red_is_refused_while_away
test_quiet_record_keeps_merges_attended
test_allow_red_requires_one_separate_name
test_away_record_permits_any_green_merge_under_away_authority
test_away_branch_actor_merges_green_under_the_record
test_away_branch_refuses_when_record_archived_during_preflight
test_away_posture_refuses_asynchronous_merge_paths
test_away_plan_gated_403_does_not_block_the_merge
test_away_record_does_not_bypass_red_or_identity
test_unreadable_away_record_refuses_merge
test_away_record_cannot_change_between_the_authority_read_and_the_merge
test_a_record_made_unreadable_before_the_merge_refuses_it
test_merge_refuses_when_the_away_record_cannot_be_locked
test_allow_red_refused_on_gitlab
test_required_check_that_never_reported_refuses
test_required_checks_reported_and_green_merge
test_red_and_unreported_checks_are_reported_together
test_unreadable_required_set_refuses
test_allow_missing_waives_only_the_named_unreported_check
test_allow_missing_follows_the_allow_red_rules

test_required_producer_identity
test_app_bound_required_status_context_matches_by_name
test_required_partial_reads_report_all_failures
test_allow_red_refused_on_forgejo
test_allow_missing_refused_on_forgejo
test_allow_no_pipeline_merges_only_a_null_head_pipeline
test_allow_no_pipeline_is_attended_only_and_gitlab_only
test_expected_head_matching_reaches_each_forge
test_expected_head_mismatch_refuses_before_merge
test_expected_head_push_after_verify_is_refused_by_the_forge
test_expected_head_later_preflight_does_not_adopt_a_new_head
test_expected_head_bad_inputs_refuse_before_effects
test_expected_head_keeps_existing_refusals

# The squash-summary cases. A no-mistakes PR body: the operator intent first,
# then the drafted summary, then the appendix and its attestation comment.
SQUASH_TITLE='fix: wake once when a ready PR degrades'
SQUASH_BODY=$'## Intent\n\nraw operator brief with ~/private/paths\n\n## What Changed\n\n- Wake the merge poll once when a ready PR degrades.\n- Add shared PR polling helpers.\n\n  Indented detail line.\n### Notes\n- A subheading stays in the section.\n\n## Risk Assessment\n\nlow\n\n## Pipeline\n\n<!-- no-mistakes-pipeline-attestation:v1 {} -->\n'
SQUASH_SECTION=$'- Wake the merge poll once when a ready PR degrades.\n- Add shared PR polling helpers.\n\n  Indented detail line.\n### Notes\n- A subheading stays in the section.'

# Args: case_dir title body. Writes the PR title and body gh reports.
write_github_text() {
  jq -n --arg t "$2" --arg b "$3" '{title: $t, body: $b}' > "$1/github-text.json"
}

# The value gh pr merge received for one flag, or the literal ABSENT.
# Args: case_dir flag
github_merge_flag_value() {
  local arg prev='' found=ABSENT
  while IFS= read -r -d '' arg; do
    if [ "$prev" = "$2" ]; then
      found=$arg
    fi
    prev=$arg
  done < "$1/github-merge-args"
  printf '%s' "$found"
}

test_squash_summary_uses_title_and_what_changed() {
  local case_dir
  case_dir=$(make_case squash-summary)
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/home/config/pr-squash-summary"
  write_github_text "$case_dir" "$SQUASH_TITLE" "$SQUASH_BODY"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  expect_code 0 "$?" "squash-summary: the merge should succeed: $(cat "$case_dir/stderr")"
  set -e
  grep -qzx -- '--squash' "$case_dir/github-merge-args" \
    || fail "squash-summary: the default squash method was dropped"
  [ "$(github_merge_flag_value "$case_dir" --subject)" = "$SQUASH_TITLE (#61)" ] \
    || fail "squash-summary: unexpected subject '$(github_merge_flag_value "$case_dir" --subject)'"
  [ "$(github_merge_flag_value "$case_dir" --body)" = "$SQUASH_SECTION" ] \
    || fail "squash-summary: unexpected body: '$(github_merge_flag_value "$case_dir" --body)'"
  pass "fm-pr-merge squash-merges with the PR title and only its What Changed section when opted in"
}

test_squash_summary_reads_crlf_bodies() {
  local case_dir
  case_dir=$(make_case squash-summary-crlf)
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/home/config/pr-squash-summary"
  write_github_text "$case_dir" "$SQUASH_TITLE" "${SQUASH_BODY//$'\n'/$'\r\n'}"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  expect_code 0 "$?" "squash-summary-crlf: the merge should succeed: $(cat "$case_dir/stderr")"
  set -e
  [ "$(github_merge_flag_value "$case_dir" --body)" = "$SQUASH_SECTION" ] \
    || fail "squash-summary-crlf: a web-edited CRLF body did not yield the bare section"
  pass "fm-pr-merge reads the What Changed section from a CRLF PR body"
}

# Every case where the summary must not be applied leaves today's merge line.
test_squash_summary_falls_back_to_repository_default() {
  local case_dir label
  for label in no-flag no-section empty-section unreadable merge-method rebase-method; do
    case_dir=$(make_case "squash-fallback-$label")
    add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
    [ "$label" = no-flag ] || : > "$case_dir/home/config/pr-squash-summary"
    case "$label" in
      no-section) write_github_text "$case_dir" "$SQUASH_TITLE" $'## Summary\n\nno drafted section\n' ;;
      empty-section) write_github_text "$case_dir" "$SQUASH_TITLE" $'## What Changed\n\n\n## Testing\n\nok\n' ;;
      unreadable) ;;
      *) write_github_text "$case_dir" "$SQUASH_TITLE" "$SQUASH_BODY" ;;
    esac
    set +e
    if [ "$label" = merge-method ]; then
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 -- --merge \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    elif [ "$label" = rebase-method ]; then
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 -- --rebase \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    else
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    fi
    expect_code 0 "$?" "squash-fallback-$label: the merge should still succeed: $(cat "$case_dir/stderr")"
    set -e
    if [ "$label" = merge-method ]; then
      assert_logged_gh_merge "$case_dir" 63 example/repo --merge
    elif [ "$label" = rebase-method ]; then
      assert_logged_gh_merge "$case_dir" 63 example/repo --rebase
    else
      assert_logged_gh_merge "$case_dir" 63 example/repo --squash
    fi
    if [ "$label" = no-flag ]; then
      # Without the flag the run is today's: the exact merge line above, no
      # read of the PR text, and nothing new on stderr.
      assert_no_grep 'title,body' "$case_dir/gh.log" \
        "squash-fallback-no-flag: the PR text was read without the opt-in"
      assert_no_grep 'squash commit' "$case_dir/stderr" \
        "squash-fallback-no-flag: the opt-in reported on a run without it"
    fi
    if [ "$label" = unreadable ]; then
      assert_grep 'keeps the repository default' "$case_dir/stderr" \
        "squash-fallback-unreadable: the unread PR text was not reported"
    fi
  done
  pass "fm-pr-merge keeps the repository's squash text when not opted in, the section is absent or empty, the PR text is unreadable, or the method is merge or rebase"
}

test_squash_summary_caller_commit_text_wins() {
  local case_dir spelling
  for spelling in subject subject-eq body body-file short-t short-b short-cluster-b short-F; do
    case_dir=$(make_case "squash-caller-$spelling")
    add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
    : > "$case_dir/home/config/pr-squash-summary"
    write_github_text "$case_dir" "$SQUASH_TITLE" "$SQUASH_BODY"
    set -- --squash
    case "$spelling" in
      subject) set -- "$@" --subject 'caller subject' ;;
      subject-eq) set -- "$@" '--subject=caller subject' ;;
      body) set -- "$@" --body 'caller body' ;;
      body-file) set -- "$@" --body-file /dev/null ;;
      short-t) set -- "$@" -t 'caller subject' ;;
      short-b) set -- "$@" -b 'caller body' ;;
      short-cluster-b) set -- "$@" -sb 'caller body' ;;
      short-F) set -- "$@" -F /dev/null ;;
    esac
    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 -- "$@" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    expect_code 0 "$?" "squash-caller-$spelling: the merge should succeed: $(cat "$case_dir/stderr")"
    set -e
    assert_logged_gh_merge "$case_dir" 64 example/repo "$@"
    assert_no_grep 'What Changed\|Wake the merge poll' "$case_dir/gh.log" \
      "squash-caller-$spelling: the PR summary was added beside the caller's own commit text"
  done
  pass "fm-pr-merge never adds the PR summary when the caller passed its own subject or body"
}

test_squash_summary_leaves_gitlab_and_forgejo_untouched() {
  local case_dir merge_line
  case_dir=$(make_gitlab_case squash-gitlab)
  : > "$case_dir/home/config/pr-squash-summary"
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "squash-gitlab: the merge should succeed: $(cat "$case_dir/stderr")"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "squash-gitlab: the opt-in changed the GitLab merge: '$merge_line'"
  case_dir=$(make_forgejo_case squash-forgejo)
  : > "$case_dir/home/config/pr-squash-summary"
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "squash-forgejo: the merge should succeed: $(cat "$case_dir/stderr")"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"/pulls/9/merge -f Do=merge -f head_commit_id=$FJ_HEAD") : ;;
    *) fail "squash-forgejo: the opt-in changed the Forgejo merge: '$merge_line'" ;;
  esac
  pass "fm-pr-merge leaves GitLab and Forgejo merges unchanged under the squash-summary opt-in"
}

# Fenced code is never read as a heading: a fenced "## What Changed" in the
# intent is not the section, and a "## " line inside a ``` or ~~~ block in the
# section does not end it (CommonMark: a fence closes only on a run of the
# same character at least as long as the one that opened it).
test_squash_summary_ignores_headings_inside_code_fences() {
  local case_dir label body want
  for label in fenced-heading-in-section fenced-section-before-real-one \
    inline-code-in-section inline-code-before-section; do
    case "$label" in
      # A backtick run whose info string holds a backtick is inline code
      # (CommonMark), so it opens no fence that could hide a heading.
      inline-code-in-section)
        body=$'## What Changed\n\n```fm --help``` now lists the flag.\n- Keep the rest.\n\n## Risk Assessment\n\nlow\n\n<!-- no-mistakes-pipeline-attestation:v1 {} -->\n'
        want=$'```fm --help``` now lists the flag.\n- Keep the rest.'
        ;;
      inline-code-before-section)
        body=$'## Intent\n\nRun ```fm --help``` first.\n\n## What Changed\n\n- Real summary.\n\n## Testing\n\nok\n'
        want='- Real summary.'
        ;;
      fenced-heading-in-section)
        body=$'## What Changed\n\n- Document the config file.\n\n````md\n## Usage\n```\nfm --help\n````\n\n~~~\n## Not a heading\n~~~\n- Keep the rest.\n\n## Risk Assessment\n\nlow\n'
        want=$'- Document the config file.\n\n````md\n## Usage\n```\nfm --help\n````\n\n~~~\n## Not a heading\n~~~\n- Keep the rest.'
        ;;
      fenced-section-before-real-one)
        body=$'## Intent\n\nExample body:\n\n```\n## What Changed\n- fake summary\n```\n\n## What Changed\n\n- Real summary.\n\n## Testing\n\nok\n'
        want='- Real summary.'
        ;;
    esac
    case_dir=$(make_case "squash-fence-$label")
    add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
    : > "$case_dir/home/config/pr-squash-summary"
    write_github_text "$case_dir" "$SQUASH_TITLE" "$body"
    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    expect_code 0 "$?" "squash-fence-$label: the merge should succeed: $(cat "$case_dir/stderr")"
    set -e
    [ "$(github_merge_flag_value "$case_dir" --body)" = "$want" ] \
      || fail "squash-fence-$label: unexpected body: '$(github_merge_flag_value "$case_dir" --body)'"
  done
  pass "fm-pr-merge ignores headings inside fenced code, and treats a backtick run holding a backtick as inline code, when reading the What Changed section"
}
