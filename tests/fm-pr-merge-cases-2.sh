# shellcheck shell=bash
# Test cases for fm-pr-merge, split out of tests/fm-pr-merge.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-pr-merge.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner



test_gitlab_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in glab jq; do
    if [ "$tool" = glab ]; then other=jq; else other=glab; fi
    case_dir=$(make_gitlab_case "gitlab-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    # One tool absent, the other still answered by this case's own mock, so the
    # refusal names exactly one tool on a host that ships neither.
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "gitlab-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$case_dir/glab.log" \
    FM_TEST_GLAB_JSON="$case_dir/mr.json" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a GitLab merge request requires $tool on PATH" \
      "$case_dir/stderr" "gitlab-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when glab or jq is absent"
}

# tea_merge_line <tea.log> [n]: the nth (default: last) merge invocation logged
# against a .../pulls/<n>/merge endpoint, or empty if none.
tea_merge_line() {
  grep -F '/merge' "$1" 2>/dev/null | tail -1
}

test_forgejo_url_resolves_and_merges() {
  local case_dir rc merge_line
  case_dir=$(make_forgejo_case forgejo-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-merges: a well-formed pull request URL should merge, not error"
  assert_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
    "forgejo-merges: pr= was not recorded before merging"
  assert_grep "--login $FJ_LOGIN --repo $FJ_OWNER/$FJ_REPO /repos/{owner}/{repo}/pulls/9" "$case_dir/tea.log" \
    "forgejo-merges: the pre-merge state was not read through the resolved login and repo slug"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"--login $FJ_LOGIN --repo $FJ_OWNER/$FJ_REPO -X POST /repos/{owner}/{repo}/pulls/9/merge -f Do=merge -f head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "forgejo-merges: unexpected merge invocation: '$merge_line'" ;;
  esac
  assert_grep "successful combined status at head $FJ_HEAD" "$case_dir/stderr" \
    "forgejo-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "forgejo-merges: a pull request reached the GitHub CLI"
  pass "fm-pr-merge merges a Forgejo pull request through tea api instead of refusing it"
}

test_forgejo_login_resolves_from_the_host() {
  local case_dir rc host url
  host=git.self-hosted.example
  url="https://$host/$FJ_OWNER/$FJ_REPO/pulls/12"
  case_dir=$(make_forgejo_case forgejo-login-from-host)
  write_tea_logins_json "$case_dir/tea-logins.json" \
    other "https://unrelated.example" "$FJ_LOGIN" "https://$host:3000"

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-login-from-host: the matching login (port stripped) should be resolved and merge"
  assert_grep "--login $FJ_LOGIN --repo $FJ_OWNER/$FJ_REPO /repos/{owner}/{repo}/pulls/12" "$case_dir/tea.log" \
    "forgejo-login-from-host: the login was not resolved from the URL's host"
  assert_no_grep 'other' "$case_dir/tea.log" \
    "forgejo-login-from-host: an unrelated login name leaked into a tea invocation"
  pass "fm-pr-merge resolves the tea login by matching the PR's host against every registered login"
}

test_forgejo_refuses_when_login_is_ambiguous() {
  local case_dir rc name
  for name in none two; do
    case_dir=$(make_forgejo_case "forgejo-login-$name")
    case "$name" in
      none) write_tea_logins_json "$case_dir/tea-logins.json" unrelated "https://elsewhere.example" ;;
      two) write_tea_logins_json "$case_dir/tea-logins.json" a "https://$FJ_HOST" b "https://$FJ_HOST" ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "forgejo-login-$name: fm-pr-merge should refuse"
    assert_grep "requires exactly one 'tea login' registered for that host" "$case_dir/stderr" \
      "forgejo-login-$name: refusal did not name the login requirement"
    assert_no_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
      "forgejo-login-$name: a PR reference was recorded despite the ambiguous login"
    [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
      || fail "forgejo-login-$name: a merge was attempted with an unresolved login"
  done
  pass "fm-pr-merge refuses when zero or more than one tea login matches the pull request's host"
}

test_forgejo_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "mergeable|mergeable=false|mergeable is \"false\", not true" \
    "draft|draft=true|the pull request is a draft"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_forgejo_case "forgejo-refuse-$name" "${spec%%|*}")

    set +e
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "forgejo-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $FJ_URL" "$case_dir/stderr" \
      "forgejo-refuse-$name: refusal did not name the pull request"
    assert_grep "$expected" "$case_dir/stderr" \
      "forgejo-refuse-$name: refusal did not name the failing condition"
    [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
      || fail "forgejo-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
      "forgejo-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "forgejo-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each Forgejo pre-merge condition independently"
}

test_forgejo_unconfigured_ci_refuses_as_none() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-ci-none)
  write_forgejo_status_json "$case_dir/tea-status.json" total_count=0

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-ci-none: an open, mergeable PR with no configured CI should still refuse"
  assert_grep 'the combined commit status is "none", not success' "$case_dir/stderr" \
    "forgejo-ci-none: an absent combined status was not reported as none"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-ci-none: a merge was attempted with no configured CI"
  pass "fm-pr-merge treats an unconfigured Forgejo combined status as none, refusing rather than skipping the check"
}

# The combined status endpoint computes its state from one page of contexts,
# so a failing context on a later page must still refuse the merge, and a
# head whose every page is green must still merge.
test_forgejo_combined_status_reads_every_page() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-status-page2-red)
  write_forgejo_status_json "$case_dir/tea-status-page2.json" state=failure

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-status-page2-red: a failing context on page 2 should refuse"
  assert_grep 'the combined commit status is "failure", not success' "$case_dir/stderr" \
    "forgejo-status-page2-red: the later page's failure was not reported"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-status-page2-red: a merge was attempted past a failing later page"

  case_dir=$(make_forgejo_case forgejo-status-page2-green)
  write_forgejo_status_json "$case_dir/tea-status-page2.json"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-status-page2-green: every green page should merge"
  assert_grep 'page=2' "$case_dir/tea.log" \
    "forgejo-status-page2-green: the second status page was never read"
  pass "fm-pr-merge reads every Forgejo combined-status page before merging"
}

test_forgejo_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_forgejo_case forgejo-stale-head)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a Forgejo task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$FJ_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $FJ_STALE_HEAD disagrees with the live head $FJ_HEAD" \
    "$case_dir/stderr" "forgejo-stale-head: the stale recorded head was trusted silently"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "forgejo-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$FJ_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "forgejo-stale-head: the recording step no longer drops an unresolvable Forgejo head"
  pass "fm-pr-merge reports a stale recorded head and binds the merge to the live one instead"
}

test_forgejo_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the Forgejo pull request head commit before merging' \
    "$case_dir/stderr" "forgejo-invalid-head: refusal did not name the unreadable head"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a Forgejo head commit it cannot validate"
}

test_forgejo_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in tea jq; do
    if [ "$tool" = tea ]; then other=jq; else other=tea; fi
    case_dir=$(make_forgejo_case "forgejo-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "forgejo-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_TEA_LOG="$case_dir/tea.log" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "forgejo-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a Forgejo pull request requires $tool on PATH" \
      "$case_dir/stderr" "forgejo-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
      "forgejo-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "forgejo-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when tea or jq is absent"
}

# The single most consequential finding in docs/forgejo-tea-integration.md:
# "tea api" reports an HTTP-level failure (a head-out-of-date rejection
# included) with exit status 0, verified against a real instance. A rejected
# merge here must therefore be caught only by the follow-up confirm read, not
# by trusting this mock's own (successful) exit status.
test_forgejo_rejected_merge_is_never_trusted_by_exit_status() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-rejected-merge)
  : > "$case_dir/tea-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-rejected-merge: a rejected merge must fail even though tea api itself exits 0"
  assert_grep "Forgejo did not confirm $FJ_URL as merged" "$case_dir/stderr" \
    "forgejo-rejected-merge: refusal did not report the unconfirmed merge"
  assert_grep '"message":"merge failed"' "$case_dir/stderr" \
    "forgejo-rejected-merge: the forge's own rejection body was not quoted"
  [ ! -e "$case_dir/tea-merged" ] || fail "forgejo-rejected-merge: the mock recorded a landed merge"
  pass "fm-pr-merge never trusts tea api's exit status alone; a rejected merge is caught by the confirm read"
}

test_forgejo_transient_confirm_read_failure_still_persists_authority() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-confirm-retry)
  printf '2\n' > "$case_dir/tea-post-merge-view-failures"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-confirm-retry: a landed merge must not fail on a transient read-back failure"
  [ -e "$case_dir/tea-merged" ] || fail "forgejo-confirm-retry: the mock did not record the merge"
  [ "$(cat "$case_dir/tea-post-merge-view-failures")" = 0 ] \
    || fail "forgejo-confirm-retry: the confirmation read was not retried"
  [ "$(sed -n 6p "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)" = attended ] \
    || fail "forgejo-confirm-retry: the merge authority was not persisted: $(cat "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)"
  if grep -q "did not confirm" "$case_dir/stderr"; then
    fail "forgejo-confirm-retry: a landed merge was reported as unconfirmed"
  fi
  pass "fm-pr-merge retries a failed Forgejo confirmation read and persists the merge authority"
}

test_forgejo_merge_method_and_extra_args() {
  local case_dir rc merge_line style variant

  # With no method named, the repository's own default_merge_style decides,
  # whichever style it is.
  for style in squash rebase merge; do
    case_dir=$(make_forgejo_case "forgejo-default-method-$style")
    printf '{"default_merge_style":"%s"}\n' "$style" > "$case_dir/tea-repo.json"
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "forgejo-default-method-$style: an unqualified merge should succeed: $(cat "$case_dir/stderr")"
    [ "$(cat "$case_dir/tea-merge-do" 2>/dev/null)" = "$style" ] \
      || fail "forgejo-default-method-$style: the unqualified merge did not use the repository's default style"
  done

  # A named method wins without the repository read deciding anything.
  case_dir=$(make_forgejo_case forgejo-named-beats-default)
  printf '{"default_merge_style":"rebase"}\n' > "$case_dir/tea-repo.json"
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "forgejo-named-beats-default: --merge should succeed"
  [ "$(cat "$case_dir/tea-merge-do" 2>/dev/null)" = merge ] \
    || fail "forgejo-named-beats-default: a named method was overridden by the repository default"

  # An unreadable or unrecognized default refuses before any merge.
  for variant in unreadable unknown missing; do
    case_dir=$(make_forgejo_case "forgejo-default-$variant")
    case "$variant" in
      unreadable) : > "$case_dir/tea-repo-fails" ;;
      unknown) printf '{"default_merge_style":"manually-merged"}\n' > "$case_dir/tea-repo.json" ;;
      missing) printf '{"message":"not found"}\n' > "$case_dir/tea-repo.json" ;;
    esac
    set +e
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "forgejo-default-$variant: a merge with no readable default style must be refused"
    assert_grep "the repository's default merge style could not be read" "$case_dir/stderr" \
      "forgejo-default-$variant: refusal did not name the unreadable default style"
    [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
      || fail "forgejo-default-$variant: a merge was attempted without a readable default style"
  done

  case_dir=$(make_forgejo_case forgejo-squash-method)
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "forgejo-squash-method: --squash should succeed"
  [ "$(cat "$case_dir/tea-merge-do" 2>/dev/null)" = squash ] \
    || fail "forgejo-squash-method: --squash did not select Do=squash"

  case_dir=$(make_forgejo_case forgejo-unsupported-arg)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --admin-something-unrecognized \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "forgejo-unsupported-arg: an unrecognized extra argument must be refused"
  assert_grep 'extra merge arguments are not yet supported for Forgejo merges' "$case_dir/stderr" \
    "forgejo-unsupported-arg: refusal did not name the unsupported-argument reason"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-unsupported-arg: a merge was attempted despite the unsupported argument"

  pass "fm-pr-merge maps --squash/--rebase to Forgejo's Do field, defaults to the repository's default merge style, and refuses any other extra argument"
}

test_gitlab_head_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-head-override)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --sha "$MR_STALE_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-head-override: fm-pr-merge should refuse a caller head override"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "gitlab-head-override: refusal did not explain the head override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-head-override: the URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-head-override: a head override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-head-override: glab was invoked despite the head override"
  pass "fm-pr-merge refuses a GitLab head override before recording state"
}

test_github_still_forwards_sha_arg() {
  local case_dir rc
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-sha-arg: a caller --sha must be refused on GitHub too"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "github-sha-arg: refusal did not name the head override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-sha-arg: gh pr merge ran despite the head override"
  pass "fm-pr-merge refuses a caller --sha on GitHub because the head comes from the live read"
}

# --expected-head is optional. These cases pin the caller-supplied commit on
# every forge the script merges, and they refuse when that commit is not the
# one the forge write would bind.
test_expected_head_matching_reaches_each_forge() {
  local case_dir rc merge_line old long
  old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  long=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  [ "${#old}" -eq 40 ] || fail "expected-head-match: fixture sha is not 40 characters"
  [ "${#long}" -eq 64 ] || fail "expected-head-match: fixture sha is not 64 characters"

  case_dir=$(make_case expected-head-gh-match)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$old"
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/201 \
    --expected-head "$old" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-head-gh-match: a matching head should merge: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 201 example/repo --squash
  assert_grep "green at head $old" "$case_dir/stderr" \
    "expected-head-gh-match: the verified line did not name the supplied head"

  case_dir=$(make_case expected-head-gh-match-64)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$long"
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/202 \
    --expected-head "$long" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-head-gh-match-64: a 64-character head should merge: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 202 example/repo --squash

  case_dir=$(make_gitlab_case expected-head-gl-match)
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --expected-head "$MR_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-head-gl-match: a matching head should merge: $(cat "$case_dir/stderr")"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "expected-head-gl-match: the forge was not bound to the supplied head: '$merge_line'"

  case_dir=$(make_forgejo_case expected-head-fj-match)
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-head-fj-match: a matching head should merge: $(cat "$case_dir/stderr")"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "expected-head-fj-match: the forge was not bound to the supplied head: '$merge_line'" ;;
  esac
  pass "fm-pr-merge sends a matching --expected-head to each forge"
}

test_expected_head_mismatch_refuses_before_merge() {
  local case_dir rc old new
  old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  new=dddddddddddddddddddddddddddddddddddddddd

  case_dir=$(make_case expected-head-gh-before)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$new"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/203 \
    --expected-head "$old" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gh-before: a replaced head must refuse"
  assert_grep "the live head is \"$new\", not the expected head $old" "$case_dir/stderr" \
    "expected-head-gh-before: the refusal did not name both heads"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-gh-before: gh pr merge ran after the live head moved"

  case_dir=$(make_gitlab_case expected-head-gl-before \
    head="$MR_STALE_HEAD" pipeline_sha="$MR_STALE_HEAD")
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --expected-head "$MR_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gl-before: a replaced head must refuse"
  assert_grep "the live head is \"$MR_STALE_HEAD\", not the expected head $MR_HEAD" \
    "$case_dir/stderr" "expected-head-gl-before: the refusal did not name both heads"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "expected-head-gl-before: glab mr merge ran after the live head moved"

  case_dir=$(make_forgejo_case expected-head-fj-before head="$FJ_STALE_HEAD")
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-fj-before: a replaced head must refuse"
  assert_grep "the live head is \"$FJ_STALE_HEAD\", not the expected head $FJ_HEAD" \
    "$case_dir/stderr" "expected-head-fj-before: the refusal did not name both heads"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "expected-head-fj-before: a Forgejo merge ran after the live head moved"
  pass "fm-pr-merge refuses before any merge write when the live head differs from --expected-head"
}

test_expected_head_push_after_verify_is_refused_by_the_forge() {
  local case_dir rc merge_line old new
  old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  new=dddddddddddddddddddddddddddddddddddddddd

  case_dir=$(make_case expected-head-gh-after)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$old"
  printf '%s\n' "$new" > "$case_dir/github-head-after-view"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/204 \
    --expected-head "$old" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gh-after: the forge must refuse the stale supplied head"
  assert_logged_gh_merge "$case_dir" 204 example/repo --squash
  assert_grep 'head out of date' "$case_dir/stderr" \
    "expected-head-gh-after: the forge refusal was not surfaced"
  assert_no_grep "--match-head-commit $new" "$case_dir/gh.log" \
    "expected-head-gh-after: the merge was bound to the head that landed after verification"

  case_dir=$(make_gitlab_case expected-head-gl-after)
  printf '%s\n' "$MR_STALE_HEAD" > "$case_dir/glab-head-after-view"
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --expected-head "$MR_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gl-after: the forge must refuse the stale supplied head"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "expected-head-gl-after: the forge was not asked for the supplied head: '$merge_line'"
  assert_grep 'head out of date' "$case_dir/stderr" \
    "expected-head-gl-after: the forge refusal was not surfaced"

  case_dir=$(make_forgejo_case expected-head-fj-after)
  printf '%s\n' "$FJ_STALE_HEAD" > "$case_dir/tea-head-after-view"
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-fj-after: the forge must refuse the stale supplied head"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "expected-head-fj-after: the forge was not asked for the supplied head: '$merge_line'" ;;
  esac
  assert_no_grep "head_commit_id=$FJ_STALE_HEAD" "$case_dir/tea.log" \
    "expected-head-fj-after: the merge was bound to the head that landed after verification"
  assert_grep 'Forgejo did not confirm' "$case_dir/stderr" \
    "expected-head-fj-after: a rejected forge match was treated as merged"
  pass "fm-pr-merge binds the forge write to the supplied head after that head moves"
}

test_expected_head_later_preflight_does_not_adopt_a_new_head() {
  local case_dir rc old new
  old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  new=dddddddddddddddddddddddddddddddddddddddd
  case_dir=$(make_case expected-head-gh-preflight)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$old"
  printf '%s\n' UNKNOWN MERGEABLE > "$case_dir/mergeable-sequence"
  printf '%s\n' "$old" "$new" > "$case_dir/github-head-by-call"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/205 \
    --expected-head "$old" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gh-preflight: a head that moves between preflight reads must refuse"
  assert_grep "the live head is \"$new\", not the expected head $old" "$case_dir/stderr" \
    "expected-head-gh-preflight: the later read was not compared with the supplied head"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-gh-preflight: a later preflight adopted the new head and merged it"
  [ "$(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")" -eq 2 ] \
    || fail "expected-head-gh-preflight: expected exactly 2 live reads, got $(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")"
  pass "fm-pr-merge does not replace --expected-head when a later preflight reads a new head"
}

test_expected_head_bad_inputs_refuse_before_effects() {
  local case_dir rc name code needle full other
  full=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  other=dddddddddddddddddddddddddddddddddddddddd
  for name in malformed short7 short12 upper missing equals equals-full twice \
    conflict-sha conflict-match; do
    case_dir=$(make_case "expected-head-bad-$name")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$full"
    : > "$case_dir/gh-axi.log"
    case "$name" in
      malformed)
        code=2
        needle='full lowercase commit sha'
        set -- --expected-head 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
        ;;
      short7)
        code=2
        needle='full lowercase commit sha'
        set -- --expected-head abc1234
        ;;
      short12)
        code=2
        needle='full lowercase commit sha'
        set -- --expected-head abcdef123456
        ;;
      upper)
        code=2
        needle='full lowercase commit sha'
        set -- --expected-head BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        ;;
      missing)
        code=2
        needle='requires a full commit sha'
        set -- --expected-head
        ;;
      equals)
        code=2
        needle='separate full commit sha argument'
        set -- --expected-head=
        ;;
      equals-full)
        code=2
        needle='separate full commit sha argument'
        set -- "--expected-head=$full"
        ;;
      twice)
        code=2
        needle='may be specified only once'
        set -- --expected-head "$full" --expected-head "$other"
        ;;
      conflict-sha)
        code=1
        needle='must not override the head commit'
        set -- --expected-head "$full" -- --sha "$other"
        ;;
      conflict-match)
        code=1
        needle='must not override the head commit'
        set -- --expected-head "$full" -- --match-head-commit "$other"
        ;;
    esac
    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/210 "$@" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code "$code" "$rc" "expected-head-bad-$name"
    assert_grep "$needle" "$case_dir/stderr" \
      "expected-head-bad-$name: refusal did not name the bad input"
    assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
      "expected-head-bad-$name: state was recorded before the bad input was refused"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "expected-head-bad-$name: a bad input armed a merge poll"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "expected-head-bad-$name: gh pr merge ran for a bad input"
  done
  pass "fm-pr-merge refuses a malformed, abbreviated, missing, or conflicting --expected-head before any effect"
}

test_expected_head_keeps_existing_refusals() {
  local case_dir rc head
  head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

  case_dir=$(make_case expected-head-draft)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  jq -c '.isDraft = true' "$case_dir/github-view.json" > "$case_dir/github-view.tmp"
  mv "$case_dir/github-view.tmp" "$case_dir/github-view.json"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/211 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-draft: a draft must still refuse"
  assert_grep 'the pull request is a draft' "$case_dir/stderr" \
    "expected-head-draft: the draft refusal was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-draft: gh pr merge ran on a draft"

  case_dir=$(make_case expected-head-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/212 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-red: a red check must still refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "expected-head-red: the red check was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-red: gh pr merge ran on a red check"

  case_dir=$(make_case expected-head-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" classic:ci classic:validate
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/213 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-required: a missing required check must still refuse"
  assert_grep "required check 'validate' has not reported at head $head" "$case_dir/stderr" \
    "expected-head-required: the missing required check was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-required: gh pr merge ran with a required check unreported"

  case_dir=$(make_case expected-head-hold)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  # Queued is enough. The hold check reads the captain-hold mark, and
  # fm-tasks-axi.sh refuses add --start without a dispatch record.
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-tasks-axi.sh" add task-x1 "Held merge" --kind ship --repo example \
    > "$case_dir/hold-add.out" 2> "$case_dir/hold-add.err" \
    || fail "expected-head-hold: could not add the task: $(cat "$case_dir/hold-add.err")"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-captain-hold.sh" hold task-x1 --reason "captain merge approval pending" \
    > "$case_dir/hold.out" 2> "$case_dir/hold.err" \
    || fail "expected-head-hold: could not hold the task: $(cat "$case_dir/hold.err")"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/214 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-hold: a captain hold must still refuse"
  assert_grep 'still held for the captain' "$case_dir/stderr" \
    "expected-head-hold: the hold refusal was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-hold: gh pr merge ran while the task was held"

  case_dir=$(make_gitlab_case expected-head-review discussions=false)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --expected-head "$MR_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-review: unresolved review discussion must still refuse"
  assert_grep 'blocking_discussions_resolved is "false", not true' "$case_dir/stderr" \
    "expected-head-review: the discussion refusal was skipped"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "expected-head-review: glab mr merge ran with review discussion open"

  case_dir=$(make_forgejo_case expected-head-fj-draft draft=true)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-fj-draft: a Forgejo draft must still refuse"
  assert_grep 'the pull request is a draft' "$case_dir/stderr" \
    "expected-head-fj-draft: the draft refusal was skipped"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "expected-head-fj-draft: a Forgejo merge ran on a draft"

  case_dir=$(make_forgejo_case expected-head-fj-status)
  write_forgejo_status_json "$case_dir/tea-status.json" state=failure
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-fj-status: a failed combined status must still refuse"
  assert_grep 'the combined commit status is "failure", not success' "$case_dir/stderr" \
    "expected-head-fj-status: the status refusal was skipped"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "expected-head-fj-status: a Forgejo merge ran on a failed status"

  case_dir=$(make_case expected-head-away)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/215 \
    --expected-head "$head" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "expected-head-away: an attended-only waiver while away must still refuse"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "expected-head-away: the authority refusal was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-away: gh pr merge ran against the away authority"

  case_dir=$(make_case expected-head-identity)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '\npr=https://github.com/example/repo/pull/99\n' >> "$case_dir/state/task-x1.meta"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/216 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-identity: a different recorded PR must still refuse"
  assert_grep 'is bound to https://github.com/example/repo/pull/99' "$case_dir/stderr" \
    "expected-head-identity: the task identity refusal was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-identity: gh pr merge ran for a task bound to another PR"
  pass "fm-pr-merge keeps draft, hold, review, check, authority, and identity refusals when --expected-head matches"
}

# --- durable merge outcome ---------------------------------------------------
# A merge that lands must leave a record outside the merging agent's memory.
# bin/fm-merge-outcome-lib.sh owns where that record goes; these cases pin the
# behavior through the real merge entrypoint.

# make_home_case <name> [<route> [<parent-home>]]: a case dir whose home is a
# secondmate home bound to a parent, or a plain main home when no route is
# given. Echoes the case dir; the home is "$case_dir/home".
make_home_case() {
  local name=$1 route=${2:-} parent=${3:-} case_dir home
  case_dir=$(make_case "$name")
  home="$case_dir/home"
  mkdir -p "$home" "$case_dir/wt"
  if [ -n "$route" ]; then
    printf '%s\n' mate-x >"$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=%s\n' "$route"
      [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
    } >"$home/.fm-secondmate-parent"
  fi
  printf '%s\n' "$case_dir"
}

parent_reply_lines() {  # <file> <url>
  grep -c -F "$2" "$1" 2>/dev/null || true
}

test_secondmate_merge_reports_upward_once() {
  local case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" <(sed -E 's/ \[at=[0-9]+\]//' "$replies") \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward merge line"
  # The merge path registers the PR first, and that registration publishes the
  # child's ready line on the same channel from fm-pr-check itself.
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url" <(sed -E 's/ \[at=[0-9]+\]//' "$replies") \
    "secondmate-merge-reports: the registration's ready line was not reported upward"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 2 ] \
    || fail "secondmate-merge-reports: a repeat merge changed the upward lines: $(cat "$replies")"
  pass "a merge a secondmate home performs itself is reported upward exactly once"
}

test_secondmate_merge_reports_on_the_local_route() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/62
  case_dir=$(make_home_case secondmate-merge-local local "$TMP_ROOT/secondmate-merge-local/parent")
  mkdir -p "$TMP_ROOT/secondmate-merge-local/parent/state"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : >"$case_dir/gh-axi.log"
  parent_status="$TMP_ROOT/secondmate-merge-local/parent/state/mate-x.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-local: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" <(sed -E 's/ \[at=[0-9]+\]//' "$parent_status") \
    "secondmate-merge-local: the landed PR did not reach the parent home's channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "secondmate-merge-local: a local-route report also wrote the remote reply channel"
  pass "a locally routed secondmate home reports the landed PR into its parent's own channel"
}

test_failed_merge_reports_nothing() {
  local case_dir rc
  case_dir=$(make_home_case failed-merge-silent remote)
  add_gh_mocks_merge_fails "$case_dir"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  # The registration's ready line is a fact of its own; only a merge line
  # would misreport the unlanded merge.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "failed-merge-silent: a merge that never landed was reported as landed"
  pass "a refused or failed merge reports no outcome"
}

test_gitlab_refusal_reports_nothing() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-refusal-silent state=merged)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refusal-silent: a refused GitLab merge should exit non-zero"
  # Registration succeeds before the later GitLab pre-merge refusal, so the
  # PR-ready fact is expected; only a merged outcome would be false.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "gitlab-refusal-silent: a refused merge request was reported as landed"
  pass "a GitLab merge refused before the forge call reports no outcome"
}

test_gitlab_merge_reports_upward() {
  local case_dir url
  case_dir=$(make_gitlab_case gitlab-merge-reports)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"
  url=$MR_URL

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "gitlab-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    <(sed -E 's/ \[at=[0-9]+\]//' "$case_dir/state/parent-replies.status") \
    "gitlab-merge-reports: a landed merge request was not reported upward"
  pass "a landed GitLab merge request is reported upward on the same channel"
}

test_queued_gitlab_merge_leaves_the_poll_armed() {
  local case_dir
  case_dir=$(make_gitlab_case queued-gitlab-merge)
  mkdir -p "$case_dir/home"
  : >"$case_dir/glab-stays-open"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-gitlab-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-gitlab-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-gitlab-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-gitlab-merge: a queued merge was marked as reported"
  pass "a queued GitLab merge stays silent and leaves confirmation to the armed poll"
}

test_main_home_merge_leaves_a_durable_wake() {
  local case_dir url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_home_case main-merge-wake)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "main-merge-wake: merge failed"

  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "main-merge-wake: a merge this home performed left no durable record naming the PR"
  [ "$(grep -c -F "$url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "main-merge-wake: one merge produced more than one durable record"
  assert_absent "$case_dir/state/parent-replies.status" \
    "main-merge-wake: a main home wrote a parent reply channel it does not have"
  pass "a merge a main home performs itself leaves one durable wake naming the PR"
}

test_queued_github_merge_leaves_the_poll_armed() {
  local case_dir url
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  write_github_outcome "$case_dir" OPEN false true main
  : >"$case_dir/gh-axi.log"

  FM_TEST_GH_MERGE_STATE=open FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-github-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge stays silent and leaves confirmation to the armed poll"
}

test_distinct_merged_prs_keep_distinct_wakes() {
  local case_dir first_url second_url
  first_url=https://github.com/example/repo/pull/68
  second_url=https://github.com/example/repo/pull/69
  case_dir=$(make_home_case distinct-merge-wakes)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$first_url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "distinct-merge-wakes: first merge failed"
  rm -f "$case_dir/state/task-x1.check.sh" \
    "$case_dir/state/task-x1.pr-poll" \
    "$case_dir/state/task-x1.pr-poll-registration"
  # The first PR's merge is already confirmed (the notified marker
  # fm_merge_outcome_report wrote), so the task's next PR is accepted with
  # pr= still bound to the first URL; no hand-edit of the recorded identity.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$second_url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "distinct-merge-wakes: second merge failed"

  [ "$(grep -c -F "$first_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: first merge wake was missing or duplicated"
  [ "$(grep -c -F "$second_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: second merge wake was missing or duplicated"
  FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-wake-drain.sh" \
    >"$case_dir/drain.out" 2>"$case_dir/drain.err" \
    || fail "distinct-merge-wakes: wake drain failed"
  assert_grep "$first_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the first PR"
  assert_grep "$second_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the second PR"
  pass "distinct merged PRs for one task retain distinct captain-facing wakes"
}

test_uncommitted_marker_retry_is_never_silent() {
  local case_dir url count
  url=https://github.com/example/repo/pull/67
  case_dir=$(make_home_case uncommitted-wake-retry)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : >"$case_dir/gh-axi.log"
  cat >"$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.pr-poll-merge-notified)
    if mkdir "$FM_TEST_MARKER_FAILURE.claim" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  export FM_TEST_MARKER_FAILURE="$case_dir/marker-failure"
  export FM_TEST_REAL_MV
  FM_TEST_REAL_MV=$(command -v mv)

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "uncommitted-wake-retry: landed merge was reported as failed"
  assert_grep 'could not record the outcome' "$case_dir/stderr-1" \
    "uncommitted-wake-retry: failed marker commit was not loud"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "uncommitted-wake-retry: failed commit disarmed the retry poll"
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: failed marker commit lost the durable outcome"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: failed marker commit was treated as complete"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "uncommitted-wake-retry: retry failed"
  unset FM_TEST_MARKER_FAILURE FM_TEST_REAL_MV
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: retry left the merge silent"
  [ -f "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: retry did not commit the canonical marker"
  pass "an uncommitted marker retry preserves at least one durable outcome"
}

test_secondmate_without_parent_binding_is_loud() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/65
  case_dir=$(make_home_case unbound-secondmate)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : >"$case_dir/gh-axi.log"
  # A secondmate identity with no parent binding: exactly the seeding gap that
  # let three real merges land in silence.
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unbound-secondmate: the merge itself landed and must not be reported as failed"
  assert_grep 'could not report it upward' "$case_dir/stderr" \
    "unbound-secondmate: a merge that could not be reported upward said nothing about it"
  assert_absent "$case_dir/state/.wake-queue" \
    "unbound-secondmate: a secondmate home fell back to the main-home record"
  pass "a secondmate home that cannot report upward says so instead of merging in silence"
}

test_github_behind_update_refuses_concurrent_head_change() {
  local case_dir rc scenario old_head raced_head updated_head actual_head
  old_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  raced_head=cccccccccccccccccccccccccccccccccccccccc
  updated_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  for scenario in no-pin expected-pin; do
    case_dir=$(make_case "github-behind-concurrent-$scenario")
    add_gh_mocks "$case_dir" "$old_head"
    jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/view.tmp"
    mv "$case_dir/view.tmp" "$case_dir/github-view.json"
    jq --arg head "$updated_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head' \
      "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
    printf '%s\n' "$raced_head" > "$case_dir/github-head-after-view"
    printf '%s\n' "$updated_head" > "$case_dir/github-head-after-update"
    set -- --update-branch
    [ "$scenario" != expected-pin ] || set -- "$@" --expected-head "$old_head"
    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6189 "$@" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    actual_head=$(cat "$case_dir/github-server-head")
    [ "$actual_head" = "$raced_head" ] \
      || fail "github-behind-concurrent-$scenario: unchecked replacement head was changed to $actual_head; expected $raced_head"
    expect_code 1 "$rc" "github-behind-concurrent-$scenario: a concurrent push must refuse"
    assert_grep 'HTTP 422' "$case_dir/stderr" \
      "github-behind-concurrent-$scenario: refusal must surface the head-mismatch response"
    assert_absent "$case_dir/github-update-done" \
      "github-behind-concurrent-$scenario: the rejected update changed the source branch"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-behind-concurrent-$scenario: merged after the head mismatch"
    [ "$(grep -c '/pulls/6189/update-branch' "$case_dir/gh.log")" -eq 1 ] \
      || fail "github-behind-concurrent-$scenario: must make one bound request without retrying the replacement head"
    assert_grep "api --method PUT repos/example/repo/pulls/6189/update-branch -f expected_head_sha=$old_head" \
      "$case_dir/gh.log" "github-behind-concurrent-$scenario: update did not name the preflight head"
  done
  pass "fm-pr-merge refuses a concurrent source-head change before updating, with or without --expected-head"
}

test_github_updated_head_other_refusals_stop_waiting() {
  local case_dir rc blocker waiting visibility visible_head reason reads advice violations=''
  local old_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local new_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  for visibility in updated delayed; do
    visible_head=$new_head
    [ "$visibility" != delayed ] || visible_head=$old_head
    for blocker in draft closed conflict required-source; do
      for waiting in pending missing; do
        case_dir=$(make_case "github-behind-blocker-$visibility-$blocker-$waiting")
        add_gh_mocks "$case_dir" "$old_head"
        write_github_required "$case_dir" ruleset:ci
        jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/view.tmp"
        mv "$case_dir/view.tmp" "$case_dir/github-view.json"
        jq --arg head "$visible_head" --arg waiting "$waiting" --arg blocker "$blocker" '
          .mergeStateStatus = "CLEAN" | .headRefOid = $head |
          .statusCheckRollup = (if $waiting == "pending" then
            [{"__typename":"CheckRun","name":"ci","status":"IN_PROGRESS","conclusion":null}]
          else [] end) |
          if $blocker == "draft" then .isDraft = true
          elif $blocker == "closed" then .state = "CLOSED"
          elif $blocker == "conflict" then .mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"
          else . end' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
        printf '%s\n' "$visible_head" > "$case_dir/github-head-after-update"
        case "$blocker" in
          draft) reason='the pull request is a draft' ;;
          closed) reason='state is "CLOSED", not open' ;;
          conflict) reason='mergeStateStatus is DIRTY' ;;
          required-source)
            reason='the branch protection summary for base branch main could not be read'
            printf '%s\n' 'HTTP 502: required-check source unavailable' > "$case_dir/github-branch-fail-after-update"
            ;;
        esac
        set +e
        FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 \
          run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6190 --update-branch \
          > "$case_dir/stdout" 2> "$case_dir/stderr"
        rc=$?
        set -e
        expect_code 1 "$rc" "$visibility-$blocker-$waiting: the updated head must refuse"
        assert_grep "$reason" "$case_dir/stderr" "$visibility-$blocker-$waiting: missing the actual refusal reason"
        assert_no_grep 'pr merge' "$case_dir/gh.log" "$visibility-$blocker-$waiting: merged despite a blocker"
        assert_absent "$case_dir/state/.control-task-x1.lock" "$visibility-$blocker-$waiting: task control lock remained held"
        assert_absent "$case_dir/state/.afk-contract.lock" "$visibility-$blocker-$waiting: away-authority lock remained held"
        [ "$(grep -c '/pulls/6190/update-branch' "$case_dir/gh.log")" -eq 1 ] \
          || fail "$visibility-$blocker-$waiting: the update request was repeated"
        reads=$(grep -c 'statusCheckRollup' "$case_dir/gh.log")
        advice=false
        if grep -q 'checks are not ready\|once its checks pass' "$case_dir/stderr"; then advice=true; fi
        printf 'observation: visibility=%s blocker=%s waiting=%s preflight_reads=%s retry_advice=%s\n' \
          "$visibility" "$blocker" "$waiting" "$reads" "$advice"
        # Collect every masking combination before reporting a regression failure.
        [ "$reads" -eq 2 ] || violations="$violations $visibility-$blocker-$waiting retried after the blocker;"
        [ "$advice" = false ] || violations="$violations $visibility-$blocker-$waiting suggested waiting for checks;"
      done
    done
  done
  [ -z "$violations" ] || fail "$violations"
  pass "fm-pr-merge immediately refuses draft, closed, conflicting, or unreadable updated heads despite pending or missing checks"
}

test_github_updated_head_other_refusals_stop_waiting
test_github_behind_update_refuses_concurrent_head_change
test_github_zero_exit_queue_required_refuses_with_exact_retry
test_github_closed_unqueued_outcome_omits_retry_flags
test_github_agreeing_queue_rules_keep_retry_guidance
test_github_conflicting_queue_rules_report_ambiguity
test_verified_merge_records_pr_and_head
test_pr_metadata_is_recorded_before_the_forge_call
test_merge_failure_propagates_after_recording
test_github_open_unqueued_outcome_refuses
test_github_mergeable_unknown_retries_then_succeeds
test_github_mergeable_unknown_exhausts_bound_and_reports_pending
test_github_mergeable_unknown_retry_rechecks_checks
test_github_mergeable_conflicting_is_not_retried
test_github_unreadable_outcome_keeps_pr_bookkeeping
test_github_refusal_quotes_the_forge_output
test_github_unreadable_outcome_refusal_quotes_the_forge_output
test_github_accepted_queue_flags_do_not_echo_back_the_same_command
test_github_mismatched_queue_flags_still_name_the_retry
test_github_unrecognised_queue_method_still_names_the_queue
test_github_unreadable_queue_rules_are_not_reported_as_no_queue
test_github_plan_gated_403_reads_as_no_queue
test_github_no_queue_rule_says_nothing_about_a_queue
test_github_unmerged_fallback_cannot_replace_queue_aware_read
test_github_auto_merge_without_queue_refuses_legibly
test_github_failed_merge_never_claims_armed_auto_merge
test_github_failed_merge_with_queue_flags_never_claims_acceptance
test_github_failed_gh_read_falls_back_to_gh_axi
test_github_failed_merge_names_an_observed_landed_state
test_github_without_gh_still_uses_gh_axi_merge
test_github_without_gh_failed_read_keeps_bookkeeping
test_github_merged_outcome_is_verified
test_github_verified_merge_requires_poll_recording
test_github_queued_outcome_is_verified
test_github_queue_required_refusal_names_retry_flags
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_help_prints_usage_and_exits_zero
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_bundled_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_github_still_forwards_sha_arg
test_gitlab_url_resolves_and_merges
test_gitlab_host_comes_from_the_url
test_gitlab_imposes_no_merge_method
test_gitlab_extra_args_forwarded
test_gitlab_merge_failure_propagates
test_gitlab_each_condition_refuses_independently
test_gitlab_reports_every_failing_condition
test_gitlab_stale_recorded_head_is_reported
test_gitlab_unreadable_state_refuses
test_gitlab_invalid_head_refuses
test_gitlab_missing_tool_refuses_before_recording
test_forgejo_url_resolves_and_merges
test_forgejo_login_resolves_from_the_host
test_forgejo_refuses_when_login_is_ambiguous
test_forgejo_each_condition_refuses_independently
test_forgejo_unconfigured_ci_refuses_as_none
test_forgejo_combined_status_reads_every_page
test_forgejo_stale_recorded_head_is_reported
test_forgejo_invalid_head_refuses
test_forgejo_missing_tool_refuses_before_recording
test_forgejo_rejected_merge_is_never_trusted_by_exit_status
test_forgejo_transient_confirm_read_failure_still_persists_authority
test_forgejo_merge_method_and_extra_args

# The merge gate asks whether the task is still held for the captain. A home
# that carries no backlog records no captain calls at all, so nothing can be
# held and the merge must proceed; a backlog that EXISTS but cannot be read may
# hide a live hold, so that one must refuse. The two states are distinct and
# only the second is a refusal.
test_absent_backlog_still_merges() {
  local case_dir rc
  case_dir=$(make_case absent-backlog-merges)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/data/backlog.md"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absent-backlog-merges: a home with no backlog must still merge"
  assert_no_grep 'held for the captain' "$case_dir/stderr" \
    "absent-backlog-merges: an absent backlog was read as a captain hold"
  assert_logged_gh_merge "$case_dir" 61 example/repo --squash
  pass "fm-pr-merge proceeds when the home carries no backlog at all"
}

test_unreadable_backlog_refuses_the_merge() {
  local case_dir rc
  case_dir=$(make_case unreadable-backlog-refuses)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6262626262626262626262626262626262626262
  : > "$case_dir/gh-axi.log"
  chmod 000 "$case_dir/home/data/backlog.md"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$case_dir/home/data/backlog.md"

  expect_code 1 "$rc" "unreadable-backlog-refuses: an unreadable authority record must refuse"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "unreadable-backlog-refuses: the refusal did not say it refused to merge"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-backlog-refuses: the forge merge ran despite an unreadable record"
  pass "fm-pr-merge refuses when the backlog exists but cannot be read"
}

test_unreadable_backend_config_refuses_the_merge() {
  local case_dir rc
  case_dir=$(make_case unreadable-backend-config-refuses)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6363636363636363636363636363636363636363
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/data/backlog.md"
  chmod 000 "$case_dir/home/.tasks.toml"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$case_dir/home/.tasks.toml"

  expect_code 1 "$rc" "unreadable-backend-config-refuses: an unreadable authority route must refuse"
  assert_grep 'tasks-axi backend configuration cannot be read' "$case_dir/stderr" \
    "unreadable-backend-config-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-backend-config-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its configured backend cannot be read"
}

test_unreadable_user_backend_config_refuses_the_merge() {
  local case_dir rc user_config
  case_dir=$(make_case unreadable-user-backend-config-refuses)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6464646464646464646464646464646464646464
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "$user_config"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$user_config"

  expect_code 1 "$rc" "unreadable-user-backend-config-refuses: an unreadable authority route must refuse"
  assert_grep "tasks-axi backend configuration cannot be read at $user_config" "$case_dir/stderr" \
    "unreadable-user-backend-config-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-user-backend-config-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its user backend configuration cannot be read"
}

test_untraversable_user_backend_config_directory_refuses_the_merge() {
  local case_dir rc user_config
  case_dir=$(make_case untraversable-user-backend-config-directory-refuses)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "${user_config%/*}"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 755 "${user_config%/*}"

  expect_code 1 "$rc" "untraversable-user-backend-config-directory-refuses: an unreadable authority route must refuse"
  assert_grep "tasks-axi backend configuration cannot be read at $user_config" "$case_dir/stderr" \
    "untraversable-user-backend-config-directory-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "untraversable-user-backend-config-directory-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its user backend configuration directory cannot be traversed"
}

test_absent_user_backend_config_directory_and_backlog_still_merge() {
  local case_dir rc
  case_dir=$(make_case absent-user-backend-config-directory-and-backlog-merges)
  mkdir -p "$case_dir/wt" "$case_dir/user-home"
  add_gh_mocks "$case_dir" 6767676767676767676767676767676767676767
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absent-user-backend-config-directory-and-backlog-merges: sound defaults and no backlog must permit merging"
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "absent-user-backend-config-directory-and-backlog-merges: the forge must merge exactly once"
  assert_logged_gh_merge "$case_dir" 67 example/repo --squash
  pass "fm-pr-merge proceeds once when its user configuration directory and backlog are genuinely absent"
}

test_backend_override_bypasses_unreadable_user_config() {
  local case_dir rc user_config
  case_dir=$(make_case backend-override-bypasses-unreadable-user-config)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6565656565656565656565656565656565656565
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "$user_config"

  set +e
  TASKS_AXI_BACKEND=markdown FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$user_config"

  expect_code 0 "$rc" "backend-override-bypasses-unreadable-user-config: an explicit backend must bypass config"
  assert_logged_gh_merge "$case_dir" 65 example/repo --squash
  pass "fm-pr-merge honors a backend override over an unreadable user configuration"
}

test_github_behind_update_requires_opt_in_and_passing_guards() {
  local case_dir rc scenario head
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  for scenario in no-consent red draft unreadable-authority away-queue; do
    case_dir=$(make_case "github-behind-guard-$scenario")
    add_gh_mocks "$case_dir" "$head"
    jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/view.tmp"
    mv "$case_dir/view.tmp" "$case_dir/github-view.json"
    case "$scenario" in
      red)
        jq '.statusCheckRollup[0].conclusion = "FAILURE"' "$case_dir/github-view.json" > "$case_dir/view.tmp"
        mv "$case_dir/view.tmp" "$case_dir/github-view.json"
        ;;
      draft)
        jq '.isDraft = true' "$case_dir/github-view.json" > "$case_dir/view.tmp"
        mv "$case_dir/view.tmp" "$case_dir/github-view.json"
        ;;
      unreadable-authority) chmod 000 "$case_dir/home/data/backlog.md" ;;
      away-queue)
        printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
        write_away_record "$case_dir" --words 'merge task-x1 when green'
        ;;
    esac
    set +e
    if [ "$scenario" = no-consent ]; then
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6184 \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    else
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6184 --update-branch \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    fi
    rc=$?
    set -e
    chmod 644 "$case_dir/home/data/backlog.md"
    [ "$rc" -ne 0 ] || fail "github-behind-guard-$scenario: the merge must refuse"
    assert_no_grep '/update-branch' "$case_dir/gh.log" \
      "github-behind-guard-$scenario: a refused merge changed the source branch"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-behind-guard-$scenario: a refused merge reached the forge"
    [ "$(cat "$case_dir/github-head")" = "$head" ] \
      || fail "github-behind-guard-$scenario: the source head changed"
    if [ "$scenario" = no-consent ]; then
      assert_grep 'requires explicit --update-branch consent' "$case_dir/stderr" \
        "github-behind-guard-no-consent: refusal did not explain the opt-in"
    fi
  done
  pass "fm-pr-merge updates behind branches only with explicit opt-in after all guards pass"
}

test_github_behind_update_keeps_expected_head_pin() {
  local case_dir rc scenario expected old_head new_head
  old_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  new_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  for scenario in initial-mismatch updated-mismatch; do
    case_dir=$(make_case "github-behind-expected-$scenario")
    add_gh_mocks "$case_dir" "$old_head"
    jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/view.tmp"
    mv "$case_dir/view.tmp" "$case_dir/github-view.json"
    jq --arg head "$new_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head' \
      "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
    printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"
    expected=$old_head
    [ "$scenario" != initial-mismatch ] || expected=cccccccccccccccccccccccccccccccccccccccc
    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6188 \
      --update-branch --expected-head "$expected" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-behind-expected-$scenario: a mismatched head must refuse"
    assert_grep "not the expected head $expected" "$case_dir/stderr" \
      "github-behind-expected-$scenario: refusal must retain the caller's head pin"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-behind-expected-$scenario: merged a head the caller did not pin"
    if [ "$scenario" = initial-mismatch ]; then
      assert_no_grep '/update-branch' "$case_dir/gh.log" \
        "github-behind-expected-$scenario: updated before the caller's head matched"
      [ "$(cat "$case_dir/github-head")" = "$old_head" ] \
        || fail "github-behind-expected-$scenario: changed the unapproved source head"
    else
      assert_grep "api --method PUT repos/example/repo/pulls/6188/update-branch -f expected_head_sha=$old_head" "$case_dir/gh.log" \
        "github-behind-expected-$scenario: explicit consent should permit the update"
      [ "$(cat "$case_dir/github-head")" = "$new_head" ] \
        || fail "github-behind-expected-$scenario: the consented update did not advance"
    fi
  done
  pass "fm-pr-merge retains --expected-head before and after a consented behind-branch update"
}

test_github_updated_head_failure_refuses_without_waiting_for_pending() {
  local case_dir rc kind old_head new_head
  old_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  new_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  for kind in check-run status-context; do
    case_dir=$(make_case "github-behind-failed-and-pending-$kind")
    add_gh_mocks "$case_dir" "$old_head"
    jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/view.tmp"
    mv "$case_dir/view.tmp" "$case_dir/github-view.json"
    jq --arg head "$new_head" --arg kind "$kind" '
      .mergeStateStatus = "CLEAN" | .headRefOid = $head |
      .statusCheckRollup = (if $kind == "check-run" then
        [{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"},
         {"__typename":"CheckRun","name":"slow","status":"IN_PROGRESS","conclusion":null}]
      else
        [{"__typename":"StatusContext","context":"ci","state":"FAILURE"},
         {"__typename":"StatusContext","context":"slow","state":"PENDING"}]
      end)' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
    printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"
    set +e
    FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6185 --update-branch \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-behind-failed-and-pending-$kind: a failed check must refuse"
    assert_grep "check 'ci' is not green" "$case_dir/stderr" \
      "github-behind-failed-and-pending-$kind: refusal did not name the failure"
    assert_no_grep 'checks are not ready' "$case_dir/stderr" \
      "github-behind-failed-and-pending-$kind: refusal obscured failure with a timeout"
    [ "$(grep -c 'statusCheckRollup' "$case_dir/gh.log")" -eq 2 ] \
      || fail "github-behind-failed-and-pending-$kind: retried after a known failure"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-behind-failed-and-pending-$kind: merged the failed head"
  done
  pass "fm-pr-merge refuses failed updated checks immediately while other checks are pending"
}

test_github_behind_updates_and_rechecks_before_merge() {
  local case_dir rc old_head new_head
  old_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  new_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  case_dir=$(make_case github-behind-green)
  add_gh_mocks "$case_dir" "$old_head"
  write_github_required "$case_dir" classic:ci
  jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  mv "$case_dir/github-view-after-update.json" "$case_dir/github-view.json"
  jq --arg head "$new_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head' \
    "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6178 --update-branch -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-behind-green: green updated head should merge: $(cat "$case_dir/stderr")"
  assert_grep "api --method PUT repos/example/repo/pulls/6178/update-branch -f expected_head_sha=$old_head" "$case_dir/gh.log" \
    "github-behind-green: the branch was not updated"
  assert_logged_gh_merge "$case_dir" 6178 example/repo --merge
  grep -qxF "pr_head=$new_head" "$case_dir/meta-at-merge" \
    || fail "github-behind-green: the updated head was not recorded before the merge"

  case_dir=$(make_case github-behind-delayed-head)
  add_gh_mocks "$case_dir" "$old_head"
  write_github_required "$case_dir" classic:ci
  jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/view.tmp"
  mv "$case_dir/view.tmp" "$case_dir/github-view.json"
  cp "$case_dir/github-view.json" "$case_dir/github-view-after-update.json"
  jq --arg head "$new_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head' \
    "$case_dir/github-view.json" > "$case_dir/github-view-after-update-final.json"
  printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6178 --update-branch -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-behind-delayed-head: the old visible head should be awaited: $(cat "$case_dir/stderr")"
  [ "$(grep -c 'statusCheckRollup' "$case_dir/gh.log")" -eq 3 ] \
    || fail "github-behind-delayed-head: did not wait for the new head"
  assert_grep "--match-head-commit $new_head" "$case_dir/gh.log" \
    "github-behind-delayed-head: did not merge the verified new head"
  grep -qxF "pr_head=$new_head" "$case_dir/meta-at-merge" \
    || fail "github-behind-delayed-head: the updated head was not recorded before merging"

  case_dir=$(make_case github-behind-pending-after-update)
  add_gh_mocks "$case_dir" "$old_head"
  write_github_required "$case_dir" classic:ci
  jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  mv "$case_dir/github-view-after-update.json" "$case_dir/github-view.json"
  jq --arg head "$new_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head | .statusCheckRollup[0].status = "IN_PROGRESS" | .statusCheckRollup[0].conclusion = null' \
    "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  jq '.statusCheckRollup[0].status = "COMPLETED" | .statusCheckRollup[0].conclusion = "SUCCESS"' \
    "$case_dir/github-view-after-update.json" > "$case_dir/github-view-after-update-final.json"
  printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6180 --update-branch -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-behind-pending-after-update: pending new check should be awaited: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 6180 example/repo --merge

  case_dir=$(make_case github-behind-red-after-update)
  add_gh_mocks "$case_dir" "$old_head"
  write_github_required "$case_dir" classic:ci
  jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  mv "$case_dir/github-view-after-update.json" "$case_dir/github-view.json"
  jq --arg head "$new_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head | .statusCheckRollup[0].conclusion = "FAILURE"' \
    "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6179 --update-branch -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-behind-red-after-update: failed new check must refuse"
  assert_grep "api --method PUT repos/example/repo/pulls/6179/update-branch -f expected_head_sha=$old_head" "$case_dir/gh.log" \
    "github-behind-red-after-update: the branch was not updated"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-behind-red-after-update: the failed new check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-behind-red-after-update: the failed updated head was merged"
  grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "github-behind-red-after-update: the updated head was not recorded"
  case_dir=$(make_case github-behind-default-squash)
  add_gh_mocks "$case_dir" "$old_head"
  write_github_required "$case_dir" classic:ci
  jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  mv "$case_dir/github-view-after-update.json" "$case_dir/github-view.json"
  jq --arg head "$new_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head' \
    "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6181 --update-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-behind-default-squash: default method should update and merge: $(cat "$case_dir/stderr")"
  assert_grep "api --method PUT repos/example/repo/pulls/6181/update-branch -f expected_head_sha=$old_head" "$case_dir/gh.log" \
    "github-behind-default-squash: the branch was not updated"
  assert_logged_gh_merge "$case_dir" 6181 example/repo --squash

  case_dir=$(make_case github-behind-unknown-after-update)
  add_gh_mocks "$case_dir" "$old_head"
  write_github_required "$case_dir" classic:ci
  jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  mv "$case_dir/github-view-after-update.json" "$case_dir/github-view.json"
  jq --arg head "$new_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head | .mergeable = "UNKNOWN"' \
    "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  jq '.mergeable = "MERGEABLE"' "$case_dir/github-view-after-update.json" \
    > "$case_dir/github-view-after-update-final.json"
  printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6182 --update-branch -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-behind-unknown-after-update: transient UNKNOWN should be awaited: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 6182 example/repo --squash

  case_dir=$(make_case github-behind-unknown-after-waived-red)
  add_gh_mocks "$case_dir" "$old_head"
  jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  mv "$case_dir/github-view-after-update.json" "$case_dir/github-view.json"
  jq --arg head "$new_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head | .mergeable = "UNKNOWN" | .statusCheckRollup[0].conclusion = "FAILURE"' \
    "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  jq '.mergeable = "MERGEABLE"' "$case_dir/github-view-after-update.json" \
    > "$case_dir/github-view-after-update-final.json"
  printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6186 --update-branch --allow-red ci -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-behind-unknown-after-waived-red: UNKNOWN beside a waived failure should be awaited: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 6186 example/repo --squash

  case_dir=$(make_case github-behind-unreadable-after-update)
  add_gh_mocks "$case_dir" "$old_head"
  jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  mv "$case_dir/github-view-after-update.json" "$case_dir/github-view.json"
  printf '[]\n' > "$case_dir/github-view-after-update.json"
  printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"
  set +e
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6187 --update-branch -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-behind-unreadable-after-update: an unreadable updated state must refuse"
  assert_grep 'could not read the GitHub pull request state' "$case_dir/stderr" \
    "github-behind-unreadable-after-update: the read failure was not reported"
  assert_no_grep 'head moved again' "$case_dir/stderr" \
    "github-behind-unreadable-after-update: a read failure was reported as a head change"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-behind-unreadable-after-update: an unverified head was merged"

  case_dir=$(make_case github-behind-pending-cap)
  add_gh_mocks "$case_dir" "$old_head"
  write_github_required "$case_dir" classic:ci
  jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  mv "$case_dir/github-view-after-update.json" "$case_dir/github-view.json"
  jq --arg head "$new_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head | .statusCheckRollup[0].status = "IN_PROGRESS" | .statusCheckRollup[0].conclusion = null' \
    "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
  printf '%s\n' "$new_head" > "$case_dir/github-head-after-update"
  set +e
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6183 --update-branch -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-behind-pending-cap: checks still pending past the cap must stop"
  assert_grep "api --method PUT repos/example/repo/pulls/6183/update-branch -f expected_head_sha=$old_head" "$case_dir/gh.log" \
    "github-behind-pending-cap: the branch was not updated"
  assert_grep "was updated to $new_head but its checks are not ready; run the merge again once its checks pass" "$case_dir/stderr" \
    "github-behind-pending-cap: the stop message was not printed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-behind-pending-cap: an unverified head was merged"
  pass "fm-pr-merge updates a green behind branch and merges only after the new head is green"
}

test_github_red_checks_refuse_and_allow_red_waives_named() {
  local case_dir rc head
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  case_dir=$(make_case github-red-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/80 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-red: a red check must refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "github-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-red: gh pr merge ran on a red PR"

  case_dir=$(make_case github-allow-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/81 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-allow-red: named waiver should merge"
  assert_logged_gh_merge "$case_dir" 81 example/repo --squash
  pass "fm-pr-merge refuses red GitHub checks and waives only a named --allow-red check"
}

# A draft cannot be merged, and neither can a pull request whose draft state the
# forge did not report as a boolean; both refuse before any merge call.
test_github_draft_or_unreadable_draft_state_refuses() {
  local case_dir rc head label filter
  head=dddddddddddddddddddddddddddddddddddddddd
  for label in draft unreadable; do
    case_dir=$(make_case "github-$label")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    case "$label" in
      draft) filter='.isDraft = true' ;;
      *) filter='del(.isDraft)' ;;
    esac
    jq -c "$filter" "$case_dir/github-view.json" > "$case_dir/github-view.tmp"
    mv "$case_dir/github-view.tmp" "$case_dir/github-view.json"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-$label: a pull request not read as non-draft must refuse"
    assert_grep "the pull request is a draft" "$case_dir/stderr" \
      "github-$label: the draft state was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-$label: gh pr merge ran without a non-draft reading"
    assert_no_grep 'declare a wait instead of done' "$case_dir/stderr" \
      "github-$label: the arm-time draft refusal preempted the merge refusal"
    grep -qxF 'pr=https://github.com/example/repo/pull/82' "$case_dir/state/task-x1.meta" \
      || fail "github-$label: pr= was not recorded before the merge refusal"
  done
  pass "fm-pr-merge refuses a draft pull request and one with no boolean draft state"
}

# When the base branch advances, GitHub cancels a pull request's in-flight run
# and re-triggers it, leaving the cancelled run in the rollup beside the passing
# re-run while reporting the pull request itself CLEAN. The merge must follow the
# current run rather than the one that re-run replaced.
test_superseded_failed_check_run_no_longer_refuses() {
  local case_dir head
  head=cccccccccccccccccccccccccccccccccccccccc
  case_dir=$(make_case github-superseded-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED CANCELLED 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/90 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-superseded-red: a failed run replaced by a passing re-run must merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 90 example/repo --squash
  pass "fm-pr-merge merges when a failed check run was replaced by a passing re-run"
}

# Legacy status contexts remain independent from check runs, even when their
# reported names match.
test_check_runs_never_supersede_status_contexts() {
  local case_dir rc head
  head=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  case_dir=$(make_case github-cross-check-kind)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(status_context ci FAILURE)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-cross-check-kind: a failing status context must refuse"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-cross-check-kind: the status context was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-cross-check-kind: a passing check run hid a failing status context"
  pass "fm-pr-merge never lets a check run supersede a legacy status context"
}

# The inverse, and the one that matters most: a check whose current run failed is
# still red however many earlier runs of it passed.
test_current_failed_check_run_still_refuses() {
  local case_dir rc head
  head=dddddddddddddddddddddddddddddddddddddddd
  case_dir=$(make_case github-current-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/91 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-current-red: a currently failing check must refuse"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-current-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-current-red: gh pr merge ran on a currently failing check"
  pass "fm-pr-merge still refuses when a check's current run failed after an earlier pass"
}

# Run generation follows startedAt rather than the order overlapping runs finish.
test_late_finishing_old_success_does_not_hide_current_failure() {
  local case_dir rc head
  head=dededededededededededededededededededede
  case_dir=$(make_case github-old-success-finishes-last)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:01Z 2026-01-01T00:00:10Z)" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:09Z 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/98 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-old-success-finishes-last: the later-started failure must refuse"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-old-success-finishes-last: the current failure was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-old-success-finishes-last: completion order hid the current failure"
  pass "fm-pr-merge uses start order when the old success finishes last"
}

# A cancelled old run may settle after the passing re-run that superseded it.
test_late_finishing_old_cancellation_is_superseded() {
  local case_dir head
  head=dfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdf
  case_dir=$(make_case github-old-cancellation-finishes-last)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED CANCELLED 2026-01-01T00:00:01Z 2026-01-01T00:00:10Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z 2026-01-01T00:00:09Z)"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/99 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-old-cancellation-finishes-last: the passing re-run must merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 99 example/repo --squash
  pass "fm-pr-merge supersedes an old cancellation that finishes last"
}

# A re-run that has not finished proves nothing, so it can neither be superseded
# nor supersede: the check stays red whether the run it replaces passed or failed.
test_unfinished_rerun_keeps_a_check_red() {
  local case_dir rc head prior
  head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  for prior in FAILURE SUCCESS; do
    case_dir=$(make_case "github-pending-rerun-$prior")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED "$prior" 2026-01-01T00:00:01Z)" \
      "$(check_run ci IN_PROGRESS - -)"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/92 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-pending-rerun-$prior: an unfinished re-run must refuse"
    assert_grep "check 'ci' is not green" "$case_dir/stderr" \
      "github-pending-rerun-$prior: the pending check was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-pending-rerun-$prior: gh pr merge ran with a re-run still in flight"
  done
  pass "fm-pr-merge keeps a check red while its re-run is still in flight"
}

# Supersession is scoped to one check name, which is also the name --allow-red
# matches, so a newer passing check never clears a different check's failure.
test_supersession_never_crosses_check_names() {
  local case_dir rc head
  head=ffffffffffffffffffffffffffffffffffffffff
  case_dir=$(make_case github-cross-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/93 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-cross-name: another check passing must not clear this failure"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "github-cross-name: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-cross-name: gh pr merge ran on a red check of a different name"
  pass "fm-pr-merge never lets one check's pass clear another check's failure"
}

# Supersession has to be proven from the forge's own start timestamps, so a run
# GitHub dated in any other way is treated as undated and clears nothing.
test_undated_runs_never_supersede() {
  local case_dir rc spec label older newer
  local head=0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a
  set -- \
    'undated-failure|-|2026-01-01T00:00:09Z' \
    'undated-pass|2026-01-01T00:00:01Z|-' \
    'fractional-pass|2026-01-01T00:00:01Z|2026-01-01T00:00:09.500Z' \
    'offset-pass|2026-01-01T00:00:01Z|2026-01-01T00:00:09+00:00'
  for spec in "$@"; do
    label=${spec%%|*}
    older=${spec#*|}
    older=${older%%|*}
    newer=${spec##*|}
    case_dir=$(make_case "github-undated-$label")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED FAILURE "$older")" \
      "$(check_run ci COMPLETED SUCCESS "$newer")"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/94 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-undated-$label: an unproven supersession must refuse"
    assert_grep "check 'ci' is not green" "$case_dir/stderr" \
      "github-undated-$label: the red check was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-undated-$label: gh pr merge ran on an unproven supersession"
  done
  pass "fm-pr-merge clears a failure only on a proven later pass of the same check"
}

# A superseded failure changes nothing about the waiver: --allow-red still covers
# exactly the named check, still needs every other check green, and the merge is
# still bound to the verified head.
test_allow_red_still_waives_only_the_current_failure() {
  local case_dir rc head
  head=0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b
  case_dir=$(make_case github-superseded-allow-red-wrong-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    --allow-red ci > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "superseded-allow-red-wrong-name: waiving the green check must not merge"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "superseded-allow-red-wrong-name: the unwaived red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "superseded-allow-red-wrong-name: gh pr merge ran with an unwaived red check"

  case_dir=$(make_case github-superseded-allow-red-named)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    --allow-red lint > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "superseded-allow-red-named: the named waiver should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 96 example/repo --squash
  pass "fm-pr-merge keeps --allow-red scoped to its named check beside a superseded failure"
}

test_allow_red_is_refused_while_away() {
  local case_dir rc head
  head=abababababababababababababababababababab
  case_dir=$(make_case github-allow-red-away)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-away: --allow-red must be refused while away"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "github-allow-red-away: refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-away: gh pr merge ran despite away --allow-red"

  case_dir=$(make_case github-allow-red-away-after-view)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  mv "$case_dir/state/.afk-contract" "$case_dir/away-record-after-view"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-away-after-view: late away publication must refuse --allow-red"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "github-allow-red-away-after-view: late refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-away-after-view: gh pr merge ran after late away publication"
  pass "fm-pr-merge rechecks away presence before an attended red merge"
}

# A quiet-mode record is a present captain, not an away posture: the attended
# red-check waiver still works and the merge is recorded as attended.
test_quiet_record_keeps_merges_attended() {
  local case_dir head url
  head=adadadadadadadadadadadadadadadadadadadad
  url=https://github.com/example/repo/pull/84
  case_dir=$(make_case quiet-allow-red)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  FM_AFK_MODE=quiet write_away_record "$case_dir"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "quiet-allow-red: the attended waiver was refused under quiet mode: $(cat "$case_dir/stderr")"
  assert_no_grep 'attended-only' "$case_dir/stderr" \
    "quiet-allow-red: quiet mode was treated as away"
  assert_logged_gh_merge "$case_dir" 84 example/repo --squash
  [ "$(sed -n 6p "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)" = attended ] \
    || fail "quiet-allow-red: the persisted merge authority is not attended: $(cat "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)"
  pass "fm-pr-merge keeps a quiet-mode home's merges attended, the named red-check waiver included"
}

test_allow_red_requires_one_separate_name() {
  local case_dir rc head
  head=afafafafafafafafafafafafafafafafafafafaf

  case_dir=$(make_case github-allow-red-equals)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/87 \
    --allow-red=lint > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-equals: equals form must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-equals: gh pr merge ran for the equals alias"

  case_dir=$(make_case github-allow-red-duplicate)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/88 \
    --allow-red lint --allow-red unit > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-duplicate: duplicate waiver must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-duplicate: gh pr merge ran for duplicate waivers"
  pass "fm-pr-merge accepts exactly one separately named red-check waiver"
}

test_away_record_permits_any_green_merge_under_away_authority() {
  local case_dir rc url head
  head=acacacacacacacacacacacacacacacacacacacac
  url=https://github.com/example/repo/pull/83

  # No yolo, no per-task grant: the record's presence is the whole mechanical
  # fact, so a green merge proceeds and the ledger tags it away.
  case_dir=$(make_case away-green)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge the windows fix when green'
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-green: a green merge under the record should succeed: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 83 example/repo --squash
  assert_grep "merge landed: task-x1 $url away" "$case_dir/state/.wake-queue" \
    "away-green: the durable outcome did not tag away"
  assert_no_grep 'away-grant' "$case_dir/state/.wake-queue" \
    "away-green: the retired away-grant tag reappeared"
  [ "$(sed -n 6p "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)" = away ] \
    || fail "away-green: the persisted merge authority is not away: $(cat "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)"

  # A yolo=on task merges under the same away authority: the posture, not the
  # task's standing autonomy, is what the ledger records while away.
  case_dir=$(make_case away-yolo)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  printf '\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
  write_away_record "$case_dir"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-yolo: yolo green merge should succeed"
  assert_grep "merge landed: task-x1 $url away" "$case_dir/state/.wake-queue" \
    "away-yolo: the durable outcome did not tag away"

  # --attended-override re-enables forge flags for an explicit instruction; it
  # never skips the record read, and the merge still lands under away authority.
  case_dir=$(make_case away-attended-override)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge it when green'
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" --attended-override \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-attended-override: a green merge should succeed: $(cat "$case_dir/stderr")"
  assert_grep "merge landed: task-x1 $url away" "$case_dir/state/.wake-queue" \
    "away-attended-override: the durable outcome did not tag away"

  # Without the record the merge is attended and the ledger row stays untagged.
  case_dir=$(make_case attended-untagged)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "attended-untagged: an attended green merge should succeed"
  case "$(grep -F "merge landed: task-x1 $url" "$case_dir/state/.wake-queue")" in
    *"$url") ;;
    *) fail "attended-untagged: the attended outcome carried an authority tag: $(grep -F 'merge landed' "$case_dir/state/.wake-queue")" ;;
  esac
  pass "while the away-posture record exists any green merge lands under away authority, yolo or not, and attended merges stay untagged"
}

# While the away-posture record exists main is parked, so the supervision
# branch actor may reach the merge gate - and meets exactly the gate main
# would: any task merges green at its live head under away authority, a red
# one is refused whatever the words say, and without the record the branch is
# refused at the role partition before any forge call
# (docs/pi-supervision-branch.md "Postures").
test_away_branch_actor_merges_green_under_the_record() {
  local case_dir rc url head
  head=dadadadadadadadadadadadadadadadadadadada
  url=https://github.com/example/repo/pull/93

  case_dir=$(make_case away-branch-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  set +e
  FM_SUPERVISION_ACTOR=branch run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 6 "$rc" "away-branch-attended: an attended branch must be refused at the partition"
  assert_grep 'the supervision branch never performs this action' "$case_dir/stderr" \
    "away-branch-attended: refusal lost the partition wording"
  [ ! -e "$case_dir/gh.log" ] || assert_no_grep 'pr ' "$case_dir/gh.log" \
    "away-branch-attended: gh ran for an attended branch merge"

  # No yolo and no grant list: the record alone relocates the green merge.
  case_dir=$(make_case away-branch-green)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge the windows fix when green'
  FM_SUPERVISION_ACTOR=branch FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "away-branch-green: a green merge must succeed for the branch under the record: $(cat "$case_dir/stderr")"
  assert_grep 'main is parked' "$case_dir/stderr" \
    "away-branch-green: the relocation note was not printed"
  assert_logged_gh_merge "$case_dir" 93 example/repo --squash
  assert_grep "merge landed: task-x1 $url away" "$case_dir/state/.wake-queue" \
    "away-branch-green: the durable outcome did not tag away"

  # The green gate is absolute in this posture for the branch as for main: a
  # red check refuses on its own, and the attended waiver is refused too.
  case_dir=$(make_case away-branch-red)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    '{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-01T00:00:00Z"}'
  write_away_record "$case_dir" --words 'merge task-x1 even if lint is red'
  set +e
  FM_SUPERVISION_ACTOR=branch FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-branch-red: a red check must refuse the branch whatever the words say"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "away-branch-red: refusal did not name the red check"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-branch-red: gh pr merge ran for a red branch merge while away"
  set +e
  FM_SUPERVISION_ACTOR=branch FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-branch-red: --allow-red must stay attended-only for the branch"
  assert_grep 'allow-red is attended-only' "$case_dir/stderr" \
    "away-branch-red: refusal did not name the attended-only waiver"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-branch-red: gh pr merge ran for a waived red branch merge while away"
  pass "under the away-posture record the branch merges a green task, is refused on a red check with or without --allow-red, and is refused at the partition while attended"
}
