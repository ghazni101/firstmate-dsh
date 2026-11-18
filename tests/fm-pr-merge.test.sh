#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must record pr= and any available pr_head= into the task's meta so
# fm-teardown.sh's landed-check has a PR reference to verify against, even on
# repos with no PR CI where the usual "checks green" fm-pr-check.sh trigger
# never fires.
#
# The test_* functions below name the covered merge, refusal, live-head,
# away-authority, outcome-publication, and recovery behavior directly.
# shellcheck disable=SC2034 # suite setup is read by the -cases-* modules

set -u

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)
BASE_PATH=$PATH

# The GitLab fixture. A placeholder host that resolves nowhere, and a namespace
# deeper than one group, because a GitLab project has no owner/repository pair.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"
MR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MR_STALE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# The Forgejo fixture. A placeholder host that resolves nowhere, exactly two
# path segments (owner/repository, no subgroup nesting), and the plural
# "pulls" route Forgejo/Gitea use.
FJ_HOST=forgejo.example
FJ_OWNER=fixture
FJ_REPO=fixture-repo
FJ_LOGIN=fm-fixture
FJ_URL="https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/9"
FJ_HEAD=cccccccccccccccccccccccccccccccccccccccc
FJ_STALE_HEAD=dddddddddddddddddddddddddddddddddddddddd

JQ_BIN=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"
REAL_MV=$(command -v mv) || fail "these tests need mv to simulate a failed poll publish"

# Cases live in definition-only modules so each is its own lint root; this
# file owns the setup and the run order.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-pr-merge-cases-1.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-pr-merge-cases-2.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-pr-merge-cases-3.sh"

test_squash_summary_uses_title_and_what_changed
test_squash_summary_reads_crlf_bodies
test_squash_summary_falls_back_to_repository_default
test_squash_summary_caller_commit_text_wins
test_squash_summary_leaves_gitlab_and_forgejo_untouched
test_squash_summary_ignores_headings_inside_code_fences
