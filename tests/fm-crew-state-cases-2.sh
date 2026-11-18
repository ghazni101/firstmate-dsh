# shellcheck shell=bash
# Test cases for fm-crew-state, split out of tests/fm-crew-state.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-crew-state.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner



# The same creation-order rule on the runs-list path itself: `axi status` answers for
# another crew's branch, and this branch's newest row is terminal while an older
# row is still live.
test_runs_list_newer_failure_outranks_older_live_row() {
  reset_fakes
  local d base_head live_head short_base short_live out
  d=$(new_case live-row-beats-terminal-row)
  make_repo_on_branch "$d/wt" fm/feat-liverow
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'live run advanced the tip'
  live_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_live=$(git -C "$d/wt" rev-parse --short=7 "$live_head")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/liverow.meta" "window=fm:fm-liverow" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-05 11:30
  failed     fm/feat-liverow ${short_base}  2026-08-05 11:20
  running    fm/feat-liverow ${short_live}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" liverow)
  assert_contains "$out" "state: failed" "the newest terminal row must not lose to an older live row"
  pass "runs-list selection keeps the newer failure over an older live row"
}

# An unfetched head on the older live row does not change creation order.
# Exact-head compatibility of the newer terminal row is not supersession proof.
test_unfetched_older_live_sibling_does_not_hide_failure() {
  reset_fakes
  local d base_head short_base unfetched out
  d=$(new_case unfetched-live-sibling)
  make_repo_on_branch "$d/wt" fm/feat-unfetched
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  unfetched=0123abc
  git -C "$d/wt" rev-parse --verify --quiet "${unfetched}^{commit}" >/dev/null 2>&1 \
    && fail "the unfetched head must not resolve in the task copy"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unfetched.meta" "window=fm:fm-unfetched" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$base_head"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-unfetched)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-unfetched ${short_base}  2026-08-05 11:20
  running    fm/feat-unfetched ${unfetched}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" unfetched)
  assert_contains "$out" "state: failed" "an older unfetched live head must not hide the newer failure"
  pass "an older unfetched live sibling does not hide a newer failure"
}

# The preference must not widen: candidates of the SAME liveness class keep the
# listing's existing newest-first precedence, so two terminal rows still resolve
# to the newer one rather than to whichever the scan happens to reach last.
test_only_terminal_rows_keep_newest_first_precedence() {
  reset_fakes
  local d base_head older_head short_base short_older out
  d=$(new_case only-terminal-rows)
  make_repo_on_branch "$d/wt" fm/feat-allterminal
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'an earlier terminal run advanced the tip'
  older_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_older=$(git -C "$d/wt" rev-parse --short=7 "$older_head")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/allterminal.meta" "window=fm:fm-allterminal" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-05 11:30
  cancelled  fm/feat-allterminal ${short_base}  2026-08-05 11:20
  completed  fm/feat-allterminal ${short_older}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" allterminal)
  assert_contains "$out" "state: unknown" "the newest cancelled row wins without inventing a verdict"
  assert_contains "$out" "run cancelled" "the newer cancelled row, not the older completed one"
  pass "two terminal rows keep the existing newest-first precedence"
}

# An unclassifiable status word keeps the ledger's own newest-first precedence:
# the creation-order preference must preserve a status whose liveness is
# unknown, so an unexpected newest row is answered as-is instead of being
# displaced by an older running row and reported as working.
test_unknown_status_row_keeps_newest_first_precedence() {
  reset_fakes
  local d base_head live_head short_base short_live out
  d=$(new_case unknown-status-row)
  make_repo_on_branch "$d/wt" fm/feat-unknownrow
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'an older run advanced the tip'
  live_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_live=$(git -C "$d/wt" rev-parse --short=7 "$live_head")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unknownrow.meta" "window=fm:fm-unknownrow" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-05 11:30
  quarantined fm/feat-unknownrow ${short_base}  2026-08-05 11:20
  running    fm/feat-unknownrow ${short_live}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" unknownrow)
  assert_contains "$out" "runs list status: quarantined" "the newest row's unclassifiable status is answered as-is"
  assert_not_contains "$out" "state: working" "an older live row must not displace an unclassifiable newer row"
  pass "an unclassifiable status row keeps the ledger's newest-first precedence"
}

# The other half of the no-widening criterion: a terminal `axi status` run with
# no live sibling on this worktree keeps reporting its own terminal outcome, in
# full run-step detail rather than degraded to the coarse listing.
test_terminal_run_without_live_sibling_is_unchanged() {
  reset_fakes
  local d base_head other_head short_base short_other out
  d=$(new_case terminal-no-live-sibling)
  make_repo_on_branch "$d/wt" fm/feat-nosibling
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'a second terminal run advanced the tip'
  other_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_other=$(git -C "$d/wt" rev-parse --short=7 "$other_head")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nosibling.meta" "window=fm:fm-nosibling" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$base_head"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-nosibling)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-nosibling ${short_base}  2026-08-05 11:20
  completed  fm/feat-nosibling ${short_other}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" nosibling)
  assert_contains "$out" "state: failed" "a terminal run with no live sibling still reports its outcome"
  assert_contains "$out" "source: run-step" "terminal outcome stays an attributed run-step verdict"
  assert_contains "$out" "run failed" "the full axi-status detail is kept, not degraded to the listing"
  pass "a terminal run with no live sibling is unchanged"
}

test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" fm/feat-coarseready
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarseready.meta" "window=fm:fm-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarseready ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: done" "coarse ready status -> done"
  assert_contains "$out" "source: status-log" "coarse ready status remains status-log sourced"
  assert_not_contains "$out" "state: working" "coarse ready status must not be suppressed by another branch log"
  pass "coarse run does not probe another branch's ci log"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" fm/feat-g
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-g.meta" "window=fm:fm-feat-g" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-g
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# A ship done: whose named head lives only in the disposable copy is not
# current-state done (issue 4768). The worker's claim stays a blocked
# preservation failure rather than finished-and-safe.
test_unpushed_ship_done_is_blocked() {
  reset_fakes
  local d sha out
  d=$(new_case unpushed-done)
  make_repo_on_branch "$d/wt" fm/unpushed
  git -C "$d/wt" commit -q --allow-empty -m 'fix only in the worktree'
  sha=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unpushed.meta" \
    "window=fm:fm-unpushed" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'done: PR https://example.test/o/r/pull/9 checks green\n' \
    > "$d/state/unpushed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" unpushed
  out=$(run_crew_state "$d" unpushed)
  assert_contains "$out" "state: blocked" "unpushed ship done: must not read as done"
  assert_contains "$out" "source: status-log" "preservation refusal stays status-log sourced"
  assert_contains "$out" "named head $sha is unreachable outside the worker copy" \
    "refusal must name the unpushed head"
  assert_not_contains "$out" "state: done" "unpushed ship done: must not remain done"
  pass "unpushed ship done: is current-state blocked"
}

# Fleet snapshot hands crew-state a captured meta copy outside state/. The
# poll's merge marker stays in the live state dir, so a squash-merged PR whose
# branch fleet sync pruned still reads done there.
test_merged_pr_reads_done_under_captured_meta() {
  reset_fakes
  local d out
  d=$(new_case merged-captured)
  make_repo_on_branch "$d/wt" fm/merged
  git -C "$d/wt" commit -q --allow-empty -m 'squash-merged fix, branch pruned'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/merged.meta" \
    "window=fm:fm-merged" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude" "pr=https://github.com/o/r/pull/7"
  printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com o/r 7 \
    > "$d/state/merged.pr-poll-merge-notified"
  chmod 600 "$d/state/merged.pr-poll-merge-notified"
  printf 'done: PR https://github.com/o/r/pull/7\n' > "$d/state/merged.status"
  mkdir -p "$d/captured"
  cp "$d/state/merged.meta" "$d/captured/merged.meta"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" merged
  out=$(FM_CREW_STATE_META_OVERRIDE="$d/captured/merged.meta" run_crew_state "$d" merged)
  assert_contains "$out" "state: done" "recorded merged PR must read done under a captured meta"
  assert_not_contains "$out" "state: blocked" "merge marker must be read from the live state dir"
  pass "recorded merged PR reads done under the fleet snapshot's captured meta"
}

test_no_mistakes_prevalidation_done_stays_done() {
  reset_fakes
  local d out
  d=$(new_case preval-done)
  make_repo_on_branch "$d/wt" fm/preval
  git -C "$d/wt" commit -q --allow-empty -m 'fix only in the worktree'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/preval.meta" \
    "window=fm:fm-preval" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'done: implementation complete\n' > "$d/state/preval.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" preval
  out=$(run_crew_state "$d" preval)
  assert_contains "$out" "state: done" "no-mistakes pre-validation done: remains done"
  assert_not_contains "$out" "state: blocked" "pre-validation done: must not be the named-head gate"
  pass "no-mistakes pre-validation done: stays current-state done"
}

test_moved_remote_branch_without_named_head_is_blocked() {
  reset_fakes
  local d main_sha fix_sha out
  d=$(new_case moved-branch)
  make_repo_on_branch "$d/wt" fm/moved
  main_sha=$(git -C "$d/wt" rev-parse refs/remotes/origin/main)
  git -C "$d/wt" commit -q --allow-empty -m 'the actual fix'
  fix_sha=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" update-ref refs/remotes/origin/fm/moved "$main_sha"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/moved.meta" \
    "window=fm:fm-moved" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude"
  printf 'done: PR https://example.test/o/r/pull/8\n' > "$d/state/moved.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" moved
  out=$(run_crew_state "$d" moved)
  assert_contains "$out" "state: blocked" "a moved remote branch must not count as preserved"
  assert_contains "$out" "named head $fix_sha is unreachable outside the worker copy" \
    "refusal must name the missing fix, not the moved branch"
  pass "moved remote branch without the named head is current-state blocked"
}

# forge=external: a review tool uploads its own snapshot, so the review ready
# report is current-state done with HEAD only in the worker copy, and a PR
# report on that project is blocked with the gate's reason.
test_external_review_done_reads_ready() {
  reset_fakes
  local d out
  d=$(new_case external-review)
  make_repo_on_branch "$d/wt" fm/ext
  git -C "$d/wt" commit -q --allow-empty -m 'change only in the copy'
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/config"
  fm_write_meta "$d/state/ext.meta" \
    "window=fm:fm-ext" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "forge=external" "harness=claude"
  printf 'done: review https://review.example.test/r/5 uploaded for review\n' > "$d/state/ext.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" ext
  out=$(FM_CONFIG_OVERRIDE="$d/config" run_crew_state "$d" ext)
  assert_contains "$out" "state: done" "an uploaded external review must read as done"
  printf 'done: PR https://github.com/o/r/pull/9\n' > "$d/state/ext.status"
  out=$(FM_CONFIG_OVERRIDE="$d/config" run_crew_state "$d" ext)
  assert_contains "$out" "state: blocked" "a PR report on an external project must read as blocked"
  assert_contains "$out" "never a PR" "the blocked read must carry the gate's reason"
  pass "forge=external: an uploaded review reads done, and a PR report reads blocked with the gate's reason"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  # No matching run anywhere. The busy verdict comes from the crew's own
  # semantic lifecycle record (bin/fm-busy-lib.sh), not from rendered text.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-h)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy record -> working"
  assert_contains "$out" "source: pane" "busy record -> pane source"
  assert_contains "$out" "claude-hook" "the working verdict names its semantic source"
  pass "no run + a busy semantic record reads working, attributed to its source"
}

# `axi status` answers a no-run worktree with `runs_on_current_branch: 0`;
# that explicit answer is authoritative even when the bare `axi` home table is
# capped (10 of 47 rows) and the complete-inventory sqlite reader is
# unavailable. The no-run answer must let crew-state continue to its ordinary
# pane/log sources instead of reporting an unreadable runs table.
test_no_run_overview_zero_branch_falls_through() {
  reset_fakes
  local d table status home short out
  d=$(new_case explicit-no-run)
  make_repo_on_branch "$d/wt" fm/feat-no-run-overview
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-no-run-overview.meta" "window=fm:fm-feat-no-run-overview" \
    "worktree=$d/wt" "kind=ship" "harness=claude"
  table=$(cat <<'EOF'
count: 10 of 47 total
runs[10]{id,branch,status,head,pr}:
  "01OTHER00",fm/other-0,running,0123456,""
  "01OTHER01",fm/other-1,running,0123456,""
  "01OTHER02",fm/other-2,running,0123456,""
  "01OTHER03",fm/other-3,running,0123456,""
  "01OTHER04",fm/other-4,running,0123456,""
  "01OTHER05",fm/other-5,running,0123456,""
  "01OTHER06",fm/other-6,running,0123456,""
  "01OTHER07",fm/other-7,running,0123456,""
  "01OTHER08",fm/other-8,running,0123456,""
  "01OTHER09",fm/other-9,running,0123456,""
EOF
  )
  status=$(cat <<EOF
current_branch: fm/feat-no-run-overview
runs_on_current_branch: 0
$table
help[2]:
  axi status
  no-mistakes init
EOF
  )
  home=$(cat <<EOF
bin: no-mistakes
repo: $d/wt
current_branch: fm/feat-no-run-overview
daemon: running (pid 4242)
$table
EOF
  )
  FM_FAKE_AXI_STATUS="$status"
  FM_FAKE_AXI_HOME="$home"
  FM_FAKE_RUNS_LIST="  running    fm/feat-no-run-overview $short  2026-09-27 09:00"
  printf 'working: implementation continues\n' > "$d/state/feat-no-run-overview.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-no-run-overview
  out=$(run_crew_state "$d" feat-no-run-overview)
  assert_contains "$out" "state: working" "explicit no-run answer falls through to the current status"
  assert_contains "$out" "source: status-log" "explicit no-run answer reaches the status-log source"
  assert_contains "$out" "implementation continues" "the status-log detail survives the no-run fallback"
  assert_not_contains "$out" "unreadable runs table" "explicit no-run answer avoids the capped-table diagnostic"
  pass "runs_on_current_branch: 0 makes a capped overview fall through to crew-state sources"
}

# A launch pinned at the fm-spawn seed (no hook has posted yet) whose pane
# renders a recognized interactive prompt must read unknown, never working -
# this is the load-bearing link the launch-prompt backstop depends on:
# fm-watch.sh's pause_state_class absorbs a stale pane as "provably working"
# whenever THIS script reports `state: working · source: pane`, so if this
# authoritative read still said working, the watcher would silently swallow
# the wake even though bin/fm-busy-lib.sh's own classifier had already flipped
# to unknown launch-prompt. crew_busy_verdict must therefore capture a real
# tail for every harness, not only grok, so the backstop's own tail-based
# check ever runs here at all.
test_no_run_launch_prompt_parked_is_not_working() {
  reset_fakes
  local d; d=$(new_case launch-prompt)
  make_repo_on_branch "$d/wt" fm/feat-lp
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-lp.meta" "window=fm:fm-feat-lp" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Quick safety check: Is this a project you created or one you trust? ...
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel'
  export FM_FAKE_BUSY_TEXT
  # arm only, never apply: the launch turn has never advanced past the seed
  # fm-spawn.sh writes at spawn time.
  "$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-lp >/dev/null
  local out; out=$(run_crew_state "$d" feat-lp)
  assert_not_contains "$out" "state: working" "a launch parked on its trust dialog must never read working"
  assert_contains "$out" "state: unknown" "a parked launch reads unknown, not busy or idle"
  assert_contains "$out" "launch-prompt" "the unknown verdict names the launch-prompt backstop as its source"
  pass "a launch parked on a recognized interactive prompt never reads working, closing the absorb path a stale watcher poll depends on"
}

# A converted adapter must NOT read working from rendered footer text: the
# redesign removed that dependency, so a pane painting "esc to interrupt" with
# no semantic record is unknown, never working and never silently idle.
test_no_run_footer_text_alone_is_not_working() {
  reset_fakes
  local d; d=$(new_case busy-footer-only)
  make_repo_on_branch "$d/wt" fm/feat-h2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h2.meta" "window=fm:fm-feat-h2" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  printf 'done: stale completion event\n' > "$d/state/feat-h2.status"
  local out; out=$(run_crew_state "$d" feat-h2)
  assert_not_contains "$out" "state: working" "a footer alone must not read working for a converted adapter"
  assert_contains "$out" "state: unknown" "no semantic record -> unknown"
  assert_not_contains "$out" "source: status-log" "unknown semantic state must not fall through to a stale log"
  pass "a converted adapter never reads working from rendered footer text"
}

# Grok keeps its isolated temporary rendered-tail fallback until its structured
# lifecycle is live-verified, so a grok crew still reads working from its own
# verified signature.
test_no_run_grok_uses_isolated_fallback() {
  reset_fakes
  local d; d=$(new_case busy-grok)
  make_repo_on_branch "$d/wt" fm/feat-h3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h3.meta" "window=fm:fm-feat-h3" "worktree=$d/wt" "kind=ship" "harness=grok"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Ctrl+c:cancel'
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-h3)
  assert_contains "$out" "state: working" "grok busy tail -> working"
  assert_contains "$out" "grok-regex" "the grok verdict names its isolated fallback source"
  pass "grok still reads working through its isolated rendered-tail fallback"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr native busy -> working"
  assert_contains "$out" "source: pane" "herdr native busy -> pane source"
  assert_contains "$out" "herdr-native" "the herdr verdict names its native source"
  pass "herdr's native busy verdict reads working with no record present"
}

# Regression (2026-09 G7 stale-claim incident): a herdr CLI that errors or
# stalls under load made pane_readable's capture fail, and the fallback read
# that single failure as "backend target gone" - text the stale sweep matches
# as positive death - so a busy box briefly scored dozens of live claims dead.
# The reader must separate the two outcomes: only a successful herdr answer
# proving the pane absent may say gone; a CLI that failed to answer is unknown
# and unreachable, never death.
test_no_run_herdr_cli_failure_reads_unreachable_not_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr cli-failure fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-cli-dead)
  make_repo_on_branch "$d/wt" fm/feat-herdr-cli
  make_fakebin "$d" >/dev/null
  # A herdr whose server is up but whose endpoint calls cannot answer at all:
  # every pane/agent invocation exits non-zero, the busiest-box form of a
  # stalled CLI (capture and pane get alike fail). `status` still answers so
  # the reader probes the endpoint instead of waiting out a server start.
  cat > "$d/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = status ] && { printf '{"server":{"running":true}}\n'; exit 0; }
exit 1
SH
  chmod +x "$d/fakebin/herdr"
  fm_write_meta "$d/state/feat-herdr-cli.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-herdr-cli)
  assert_contains "$out" "state: unknown" "a failed herdr CLI must stay unknown"
  assert_contains "$out" "source: none" "a failed herdr CLI has no state source"
  assert_contains "$out" "backend unreachable" "a failed herdr CLI must read as unreachable, not gone"
  assert_not_contains "$out" "backend target gone" "a failed herdr CLI is not positive death evidence"
  pass "a herdr CLI that fails to answer reads unknown/unreachable, never gone"
}

# Decision follow-up (2026-09-05 review): an `alive` endpoint answer is
# authoritative even when the heavy scrollback read failed - the live state is
# classified by the normal flow, never discarded as unreachable.
test_no_run_herdr_alive_with_failed_read_stays_live() {
  command -v jq >/dev/null 2>&1 || { pass "herdr alive/read-fail test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-alive-readfail)
  make_repo_on_branch "$d/wt" fm/feat-herdr-alive
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-alive.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  # The 200-line scrollback read fails while the cheap pane get / agent get
  # pair answers: the pane is present and its agent is working.
  FM_FAKE_HERDR_READ_FAIL=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr-alive)
  assert_contains "$out" "state: working" "an alive endpoint with a failed scrollback read stays live"
  assert_not_contains "$out" "backend unreachable" "an authoritative alive answer is never unreachable"
  assert_not_contains "$out" "backend target gone" "an authoritative alive answer is never death"
  pass "an alive endpoint whose scrollback read failed stays working"
}

# Issue #4115: a registration Herdr kept after its Pi exited to a plain shell is
# not an agent. The recovery-grade read proves the process level, so the
# shell-only pane reads as positive agent-gone evidence, never as a live agent
# or as unreachable.
test_no_run_herdr_stale_registration_over_shell_reads_agent_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr stale-registration test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-stale-reg)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stale
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stale.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=pi"
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_READ_FAIL=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_PROCESS=shell
  local out; out=$(run_crew_state "$d" feat-herdr-stale)
  assert_contains "$out" "state: unknown" "a stale registration over a shell-only pane is not a live state"
  assert_contains "$out" "backend target gone" "a stale registration over a shell-only pane must read as positive agent-gone evidence"
  assert_contains "$out" "agent gone, pane shell remains" "the agent-gone reason must name the remaining shell"
  assert_not_contains "$out" "backend unreachable" "a readable shell-only pane is not unreachable"
  pass "herdr stale registration over a shell-only pane reads agent gone, not alive"
}

# The busy half of the same defect: a `working` record Herdr kept after the
# agent was killed mid-turn must never make a shell-only pane read as working.
test_no_run_herdr_stale_working_record_is_never_busy() {
  command -v jq >/dev/null 2>&1 || { pass "herdr stale-working test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-stale-working)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stale-working
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stale-working.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=pi"
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  FM_FAKE_HERDR_PROCESS=shell
  local out; out=$(run_crew_state "$d" feat-herdr-stale-working)
  assert_not_contains "$out" "state: working" "a stale working record over a shell-only pane must never read busy"
  assert_not_contains "$out" "herdr-native" "the native busy verdict must not be trusted for a shell-only pane"
  # The control: the same record with a live harness in the foreground is busy.
  FM_FAKE_HERDR_PROCESS=agent
  out=$(run_crew_state "$d" feat-herdr-stale-working)
  assert_contains "$out" "state: working" "the same working record with a live harness process must still read working"
  pass "herdr stale working record never reports a shell-only pane busy"
}

# Decision follow-up (2026-09-05 review): a husk pane (pane present,
# agent_not_found) is authoritative death evidence - it keeps the gone-class
# text so the stale sweep may still reclaim it, never unknown/unreachable.
test_no_run_herdr_husk_dead_still_reads_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr husk test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-husk-dead)
  make_repo_on_branch "$d/wt" fm/feat-herdr-husk
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-husk.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  # The pane exists and answers pane get, but no agent is registered in it,
  # and the scrollback read fails besides.
  FM_FAKE_HERDR_READ_FAIL=1
  FM_FAKE_HERDR_HUSK=1
  local out; out=$(run_crew_state "$d" feat-herdr-husk)
  assert_contains "$out" "state: unknown" "a husk pane has no live current state"
  assert_contains "$out" "backend target gone" "a husk pane keeps its gone-class death evidence"
  assert_contains "$out" "agent gone, pane shell remains" "the husk verdict names what actually died"
  assert_not_contains "$out" "backend unreachable" "a husk pane is not an unreachable backend"
  pass "a husk pane (agent gone) still reads gone for reclaim"
}

# Regression (2026-07 herdr false-surface incident, now solved semantically):
# herdr's agent.get reports generation state ("working" only while the model is
# actively streaming - docs/herdr-backend.md "Busy state"), not "this crew's
# turn is still in progress". A crew blocked on its own long-running foreground
# `no-mistakes axi run` (no --yes; blocks until a gate or outcome) is not
# generating for that whole span, so agent.get reads idle. The crew's own
# semantic lifecycle record still says busy for the whole turn, and it outranks
# the narrower native verdict - so the crew is no longer misread as not-working.
test_no_run_herdr_idle_agent_status_outranked_by_record() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  # No run attributable (mirrors a no-mistakes run-step lookup that found no
  # matching row within the configured runs-list window): the crew's semantic
  # busy state is the only remaining signal.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-idle)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-idle busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "a busy record with herdr idle agent_status -> working"
  assert_contains "$out" "claude-hook" "the record's source outranks herdr's narrower native verdict"
  pass "a mid-tool-call crew stays working because its record outranks herdr's generation state"
}

# The record must not mask a genuinely idle or human-blocked agent: an idle
# record with idle agent_status still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-record skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-stopped)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-stopped idle --gen "$gen" \
    --source claude-hook --event stop
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "an idle record must not read as busy"
  assert_contains "$out" "source: status-log" "an idle record falls to the status log"
  pass "an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-i
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-keyed
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-pause
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  printf 'The release window opens tomorrow.\n\n' >> "$d/state/feat-pause.status"
  out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "continuation prose and trailing blanks preserve the pause"
  assert_contains "$out" "holding for the upstream tool release" "multiline pause preserves its declared reason"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_secondmate_open_block_survives_unrelated_append() {
  reset_fakes
  local d out suffix gen
  d=$(new_case buried-block)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "harness=claude"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" mate)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" mate busy --gen "$gen" --source claude-hook --event user-prompt-submit
  for suffix in '' 'note: unrelated progress' 'resolved [key=other]: unrelated answer' 'working: continuing another task' 'done: another task completed' 'failed: another task failed' $'done: another task completed\nnote: cleanup complete' $'failed: another task failed\nnote: cleanup complete'; do
    printf 'blocked [key=access]: need release access\n%s\n' "$suffix" > "$d/state/mate.status"
    out=$(run_crew_state "$d" mate)
    assert_contains "$out" "state: blocked" "open blocker survives '$suffix' with a busy endpoint"
    assert_contains "$out" "need release access" "the open blocker's reason remains visible"
  done
  printf 'resolved [key=access]: access granted\n' >> "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "matching resolution clears the blocker"
  assert_not_contains "$out" "need release access" "closed blocker is not resurrected"
  pass "a busy secondmate keeps its open blocker until that exact key closes"
}

test_newest_open_decision_supplies_the_reported_detail() {
  reset_fakes
  local d out gen
  d=$(new_case newest-open-decision)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "harness=claude"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" mate)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" mate busy --gen "$gen" --source claude-hook --event user-prompt-submit
  printf 'blocked [key=a]: staging is down\nneeds-decision [key=b]: pick a rollout order\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: parked" "the newer open decision is the reported state"
  assert_contains "$out" "pick a rollout order" "the newer open decision supplies the detail"
  printf 'blocked [key=c]: the deploy host went away\n' >> "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: blocked" "a newer blocker takes the report back"
  assert_contains "$out" "the deploy host went away" "the newest blocker supplies the detail"
  printf 'resolved [key=c]: host restored\n' >> "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: parked" "closing the newest decision falls back to the next open one"
  assert_contains "$out" "pick a rollout order" "the still-open older decision is not lost"
  pass "the most recently opened decision supplies the reported state and detail"
}

test_single_owner_terminal_declaration_supersedes_stale_decision() {
  reset_fakes
  local d kind opener terminal out key expected
  d=$(new_case terminal-stale-decision)
  make_repo_on_branch "$d/wt" fm/task
  make_fakebin "$d" >/dev/null
  arm_idle_record "$d/state" task
  for kind in scout ship; do
    fm_write_meta "$d/state/task.meta" "window=fm:fm-task" "worktree=$d/wt" "kind=$kind" "harness=claude"
    for opener in needs-decision blocked; do
      for terminal in 'done' failed; do
        printf '%s [key=choice]: an earlier decision\n%s: final outcome\nContinuation prose.\n\n' \
          "$opener" "$terminal" > "$d/state/task.status"
        out=$(run_crew_state "$d" task)
        assert_contains "$out" "state: $terminal" "$kind terminal declaration supersedes stale $opener"
        assert_contains "$out" "final outcome" "the terminal declaration supplies the detail"
        printf 'note: cleanup complete\n' >> "$d/state/task.status"
        out=$(run_crew_state "$d" task)
        assert_contains "$out" "state: unknown" "$kind cleanup note does not revive a pre-terminal $opener"
        assert_not_contains "$out" "an earlier decision" "superseded decision detail stays absent after cleanup"
        expected=parked
        [ "$opener" != blocked ] || expected=blocked
        for key in choice new-choice; do
          printf '%s [key=%s]: reopened after completion\nnote: more cleanup\n' "$opener" "$key" >> "$d/state/task.status"
          out=$(run_crew_state "$d" task)
          assert_contains "$out" "state: $expected" "$kind retains a post-terminal $opener for $key"
          assert_contains "$out" "reopened after completion" "the reopened decision supplies the detail"
          printf 'resolved [key=%s]: answered\n' "$key" >> "$d/state/task.status"
          out=$(run_crew_state "$d" task)
          assert_contains "$out" "state: unknown" "matching resolution clears the reopened decision"
          assert_not_contains "$out" "an earlier decision" "closing a reopened decision cannot revive pre-terminal decisions"
        done
      done
    done
  done
  pass "ship and scout terminal declarations supersede stale decisions"
}

test_latest_status_preserves_legacy_completions() {
  local d event line
  d=$(new_case latest-legacy)
  for event in 'PR ready https://example.com/pull/1' 'checks green' 'ready in branch fm/topic' merged 'PR READY https://example.com/pull/1'; do
    printf 'paused: awaiting release\n%s\nMore detail: cleanup complete.\n\n' "$event" > "$d/state/task.status"
    line=$(last_status_line "$d/state/task.status")
    [ "$line" = "$event" ] || fail "legacy completion '$event' was hidden by an earlier pause"
    status_is_captain_relevant "$line" || fail "legacy completion is no longer captain-relevant"
    status_is_paused "$line" && fail "legacy completion retained pause handling"
    printf 'working: following up on merged work\n' >> "$d/state/task.status"
    line=$(last_status_line "$d/state/task.status")
    [ "$line" = 'working: following up on merged work' ] || fail "later working event did not supersede legacy completion"
    status_is_captain_relevant "$line" && fail "legacy prose made a working event captain-relevant"
    printf 'paused: waiting on upstream PR #123 to land\nOnce it is %s I will rebase and continue.\n\n' "$event" > "$d/state/task.status"
    line=$(last_status_line "$d/state/task.status")
    [ "$line" = 'paused: waiting on upstream PR #123 to land' ] || fail "continuation prose mentioning '$event' hid a multi-line pause: $line"
    status_is_paused "$line" || fail "a multi-line pause lost pause handling behind prose mentioning '$event'"
  done
  (
    shopt -u nocasematch
    FM_CAPTAIN_RE='custom-event:' status_is_captain_relevant 'CUSTOM-EVENT: ready' || fail "custom captain regex lost case-insensitive matching"
    shopt -q nocasematch && fail "captain matching changed caller shell options"
    FM_CAPTAIN_RE='custom-event:' status_is_captain_relevant 'done: ready' && fail "custom captain regex did not replace defaults"
    shopt -s nocasematch
    status_is_captain_relevant 'unrelated prose' && fail "ordinary prose became captain-relevant"
    shopt -q nocasematch || fail "captain matching cleared caller shell options"
  ) || fail "captain matching changed regex or shell-option behavior"
  pass "latest status retains legacy completion events and shared captain matching"
}

test_latest_status_subshell_work_does_not_grow_with_history() {
  local d size i level small large window
  d=$(new_case latest-processes)
  window=${FM_CLASSIFY_EVENT_WINDOW_LINES:-200}
  for size in "$window" "$((window * 10))"; do
    {
      for ((i = 0; i < size; i++)); do
        printf 'working corr=0123456789abcdef [key=phase]: progress\nMore detail: still working.\n'
      done
      printf 'PR ready https://example.com/pull/1\npaused corr=0123456789abcdef [key=release]: awaiting release\n\n'
    } > "$d/state/task.status"
    : > "$d/children-$size"
    (
      level=$BASH_SUBSHELL
      set -T
      trap 'if [ "$BASH_SUBSHELL" -gt "$level" ]; then printf x >> "$d/children-$size"; fi' DEBUG
      last_status_line "$d/state/task.status" > "$d/output"
    )
    [ "$(cat "$d/output")" = 'paused corr=0123456789abcdef [key=release]: awaiting release' ] \
      || fail "latest status lost correlation-token parsing on a long log"
  done
  small=$(wc -c < "$d/children-$window")
  large=$(wc -c < "$d/children-$((window * 10))")
  [ "$large" -le "$((small + 20))" ] || fail "latest status shell work grows with history ($small -> $large)"
  printf 'paused: awaiting a long quiet tail\n' > "$d/state/task.status"
  for ((i = 0; i < 500; i++)); do printf 'continuation prose %s\n' "$i" >> "$d/state/task.status"; done
  [ "$(last_status_line "$d/state/task.status")" = 'paused: awaiting a long quiet tail' ] \
    || fail "a declared pause buried under a long prose tail was hidden"
  pass "latest status subprocess work stays bounded and still reads past a long prose tail"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-custom-pause
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  assert_contains "$out" "backend target gone" "an inventory that omits the window is positive death evidence"
  pass "dead window ignores stale status log"
}

test_gone_window_in_live_session_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case gone-window-live-session)
  make_repo_on_branch "$d/wt" fm/feat-gone
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-gone.meta" "window=fm:fm-feat-gone" "worktree=$d/wt" "kind=ship"
  printf 'working: implementing the widget\n' > "$d/state/feat-gone.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_WINDOW_GONE=1
  local out; out=$(run_crew_state "$d" feat-gone)
  assert_contains "$out" "state: unknown" "gone window in a live session -> unknown"
  assert_contains "$out" "source: none" "gone window in a live session -> none source"
  assert_contains "$out" "backend target gone" "gone window in a live session reports the dead endpoint"
  assert_not_contains "$out" "source: status-log" "a gone window must not let the stale log read as current"
  pass "a gone window of a live session ignores the stale status log"
}

# Regression (2026-09 G7 stale-claim incident, tmux half): the default backend
# reached the same false-death path as herdr. A tmux that cannot answer at all
# - a trimmed PATH, or any non-definitive error - made every live crew report
# "backend target gone", the text the stale sweep matches as positive death.
# Absence must be proved by tmux's own answer: a window inventory that omits
# the recorded window, or one of its definitive no-session/no-server/no-socket
# responses. Anything else is a tmux that failed to answer: unknown, never
# death. (A socket-connection error is deliberately NOT in this test's scope -
# fm_backend_tmux_agent_state classifies it as `missing` so fm-bootstrap and
# fm-session-start can respawn after a genuine server death.)
test_no_run_tmux_unreadable_reads_unreachable_not_gone() {
  reset_fakes
  local d; d=$(new_case tmux-unreadable)
  make_repo_on_branch "$d/wt" fm/feat-tmux-unread
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-tmux-unread.meta" "window=fm:fm-feat-tmux-unread" \
    "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-tmux-unread.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_UNREADABLE=1
  local out; out=$(run_crew_state "$d" feat-tmux-unread)
  assert_contains "$out" "state: unknown" "an unreadable tmux must stay unknown"
  assert_contains "$out" "source: none" "an unreadable tmux has no state source"
  assert_contains "$out" "backend unreachable" "an unreadable tmux reads as unreachable, not gone"
  assert_not_contains "$out" "backend target gone" "an unreadable tmux is not positive death evidence"
  pass "a tmux that fails to answer reads unknown/unreachable, never gone"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished crew whose agent has
# exited and closed its window (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_window_still_reports_terminal_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-done)
  make_repo_on_branch "$d/wt" fm/feat-dead-done
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-done.meta" "window=fm:fm-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dead-done)"
  FM_FAKE_TMUX_MISSING=1   # the crew's window has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  assert_contains "$out" "state: done" "closed pane still reports terminal run-step done"
  assert_contains "$out" "source: run-step" "closed pane does not mask the run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with a run must never be unknown"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_window_still_reports_active_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-active)
  make_repo_on_branch "$d/wt" fm/feat-dead-act
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-act.meta" "window=fm:fm-feat-dead-act" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-dead-act)"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-timeout.meta" "window=fm:fm-feat-timeout" "worktree=$d/wt" "kind=ship" \
    "harness=claude"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-timeout)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-timeout busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  start=$SECONDS
  out=$(FM_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout" \
    "harness=claude"
  # Even if a run existed on this branch, a scout must not read it.
  FM_FAKE_AXI_STATUS="$(run_running fm/scout-j)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" scout-j)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" scout-j busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
  assert_contains "$out" "source: pane" "scout reads its semantic busy state"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

# --- remote secondmate arm ---------------------------------------------------
# A meta recording remote_host= must never be read through the local worktree
# probe or a local backend adapter: the recorded worktree and pane live on the
# remote host, and the old local reads misreported a healthy remote mate as
# "worktree gone". These cases drive the real helper over the real fm-on.sh
# route with a stubbed ssh transport (FM_SSH_BIN seam): the stub prints
# FM_FAKE_REMOTE_STATE_OUT as the remote endpoint's recovery-grade state and
# exits FM_FAKE_SSH_RC.

setup_remote_case() {  # <name> -> echoes case dir with remote meta + registry
  local d
  d=$(new_case "$1")
  mkdir -p "$d/data" "$d/fakebin"
  fm_write_meta "$d/state/rsm.meta" \
    "window=remote:rsm" \
    "endpoint_task_id=rsm" \
    "worktree=/remote/home/never-locally-present" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$d/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  cat > "$d/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
[ -z "${FM_FAKE_REMOTE_STATE_OUT:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_STATE_OUT"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$d/fakebin/fake-ssh"
  printf '%s\n' "$d"
}

run_remote_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_SSH_BIN="$1/fakebin/fake-ssh" "$CREW_STATE" "$2"
}

test_remote_alive_with_log_uses_status_log() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-log)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive exits 0"
  assert_contains "$out" "state: working" "alive remote mate with a working log reads working"
  assert_contains "$out" "source: status-log" "alive remote mate reads current activity from the routed log"
  assert_contains "$out" "remote endpoint alive on remote-mac" "the remote liveness read should be visible"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  pass "fm-crew-state remote: alive endpoint falls through to the routed status log"
}

test_remote_alive_idle_is_healthy_not_gone() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-idle)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive-idle exits 0"
  assert_contains "$out" "source: remote-endpoint" "the remote endpoint is the reported source"
  assert_contains "$out" "alive on remote-mac" "an idle remote mate reads alive"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  assert_not_contains "$out" "backend target gone" "a healthy remote mate must never read as a dead target"
  pass "fm-crew-state remote: an idle alive endpoint reads alive, never gone or dead"
}

test_remote_unreachable_is_unknown_remote_not_dead() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-unreachable)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_SSH_RC=255 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "unreachable remote exits 0"
  assert_contains "$out" "unknown-remote" "an unreachable remote must be labeled unknown-remote"
  assert_contains "$out" "not proof of death" "an unreachable remote must not read as dead"
  assert_not_contains "$out" "worktree gone" "an unreachable remote must never read as torn down"
  assert_not_contains "$out" "backend target gone" "an unreachable remote must never read as a dead target"
  pass "fm-crew-state remote: an unreachable host reads unknown-remote, never gone or dead"
}

test_remote_dead_reports_remote_verdict() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-dead)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=dead FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote dead exits 0"
  assert_contains "$out" "remote endpoint dead on remote-mac" \
    "a genuinely dead remote endpoint reports the remote host's own verdict"
  pass "fm-crew-state remote: the remote host's own dead verdict is reported truthfully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (m) override guard: FM_CREW_STATE_*_OVERRIDE is honoured only when its
# basename is the asked task's own file name. A mismatched override inherited
# from another task's environment must fall through to $STATE/$ID.*, while the
# snapshot's own matching-name override keeps steering the read at the captured
# generation.
test_mismatched_state_override_is_ignored() {
  reset_fakes
  local d out
  d=$(new_case override-mismatch)
  make_repo_on_branch "$d/wt" fm/feat-ovr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ovr.meta" "window=fm:fm-feat-ovr" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: real task log line\n' > "$d/state/feat-ovr.status"
  # Another task's snapshot capture, under snapshot-style names.
  fm_write_meta "$d/state/feat-other.meta" "window=fm:fm-feat-other" "worktree=$d/foreign-missing-wt" "kind=ship" "harness=claude"
  printf 'blocked: other task log line\n' > "$d/state/feat-other.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-ovr
  out=$(FM_CREW_STATE_META_OVERRIDE="$d/state/feat-other.meta" \
    FM_CREW_STATE_STATUS_OVERRIDE="$d/state/feat-other.status" \
    run_crew_state "$d" feat-ovr)
  assert_contains "$out" "state: working" "a mismatched override must be ignored: the task's own working log line wins"
  assert_contains "$out" "source: status-log" "a mismatched override must fall through to the task's own status log"
  assert_not_contains "$out" "worktree gone" "a mismatched metadata override must fall through to the task's live worktree"
  assert_not_contains "$out" "other task log line" "a mismatched override must never surface the other task's status"
  pass "override guard: a foreign-named override is ignored and the task's own state files are read"
}

test_matched_state_override_is_honoured() {
  reset_fakes
  local d out
  d=$(new_case override-match)
  make_repo_on_branch "$d/wt" fm/feat-ovr2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ovr2.meta" "window=fm:fm-feat-ovr2" "worktree=$d/live-missing-wt" "kind=ship" "harness=claude"
  printf 'working: live log line\n' > "$d/state/feat-ovr2.status"
  # The fleet snapshot's captured generation for THIS task: matching names.
  mkdir -p "$d/snapshot"
  fm_write_meta "$d/snapshot/feat-ovr2.meta" "window=fm:fm-feat-ovr2" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: snapshot captured status\n' > "$d/snapshot/feat-ovr2.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-ovr2
  out=$(FM_CREW_STATE_META_OVERRIDE="$d/snapshot/feat-ovr2.meta" \
    FM_CREW_STATE_STATUS_OVERRIDE="$d/snapshot/feat-ovr2.status" \
    run_crew_state "$d" feat-ovr2)
  assert_contains "$out" "state: paused" "a matched-name override must be honoured over the live status log"
  assert_contains "$out" "source: status-log" "a matched-name override reads the captured log through the normal source"
  assert_not_contains "$out" "worktree gone" "a matched-name metadata override must use the captured worktree"
  pass "override guard: a matching-name override still steers the read at the captured generation"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). This is the direct regression pair for the 2026-07-02 herdr
# incident: a validating crew whose bare `axi status` answer belongs to
# another branch must still be absorbed by the watcher via the runs-list
# fallback (working), while a crew with genuinely no run anywhere and an idle
# pane must still surface (the safety property the fix must never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d short; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-provable
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" "window=fm:fm-feat-provable" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-provable ${short}  2026-07-02 22:05
EOF
)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "cross-branch attribution via the runs list was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating crew found only via the runs-list fallback"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

# Head-binding: same branch name with a rewritten/diverged worktree tip must not
# attribute a historical no-mistakes run (multi-stage branch reuse incident).
test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" fm/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/todo-flag
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$old_head" != "$new_head" ] || fail "rewrite did not produce a new head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/wishlist.meta" "window=fm:fm-wishlist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # Historical run still reports the pre-rewrite head on the reused branch.
  FM_FAKE_RUN_HEAD="$old_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/todo-flag)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" wishlist
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_not_contains "$out" "parked at" "historical parked run must not mask current state"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" fm/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; run reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pipe.meta" "window=fm:fm-pipe" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$fix_head"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-pipeline)"
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active fixing run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Head-binding: local work that advanced past the run head invalidates the run.
test_local_advanced_past_run_head_invalidates() {
  reset_fakes
  local d run_head out
  d=$(new_case local-advanced)
  make_repo_on_branch "$d/wt" fm/feat-adv
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local stage-2 work after prior run'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/adv.meta" "window=fm:fm-adv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/adv.status"
  FM_FAKE_RUN_HEAD="$run_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-adv)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" adv
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use historical run"
  assert_contains "$out" "source: status-log" "falls back after local advanced past run"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past run head invalidates attribution"
}

# --- Run-attribution precedence for pipeline-owned lane heads ----------------
# A live run whose pipeline OWNS the branch (branch_sync.state=pipeline_owned)
# can report a lane head that is not a git object in the task worktree.
# Every fixture head is deliberately unresolvable so only the top-level
# branch_sync exemption - never an accidental nested-field match - attributes
# the run.
run_running_pipeline_owned() {  # <branch> <head> [<sync-state>]
  cat <<EOF
run:
  id: "01RUNLIVE"
  branch: $1
  status: running
  head: "$2"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
branch_sync:
  state: ${3:-pipeline_owned}
  changed: false
  local:
    branch: $1
    head: "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"
    clean: true
  next_action:
    code: continue_active_run
    command: no-mistakes axi status
EOF
}

# T1 direction 1: the daemon-attributed ACTIVE pipeline-owned run binds without
# head equality and wins over the older superseded failed row.
test_pipeline_owned_active_run_beats_superseded_failed_row() {
  reset_fakes
  local d short; d=$(new_case f10-pipeline-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10.meta" "window=fm:fm-feat-f10" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10 f0f0f0f0)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-f10 f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10 ${short}  2026-08-27 12:09
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f10)
  assert_contains "$out" "state: working" "pipeline-owned live run -> working"
  assert_contains "$out" "source: run-step" "pipeline-owned live run -> run-step source"
  assert_not_contains "$out" "state: failed" "superseded failed row must not surface over the live run"
  pass "pipeline-owned active run binds without head equality and beats the failed row"
}

# T1 direction 2: a genuinely-failed run with NO later run on the branch still
# surfaces as failed - hiding real failures is equally wrong.
test_failed_run_with_no_later_run_still_surfaces() {
  reset_fakes
  local d short; d=$(new_case f10-genuine-failure)
  make_repo_on_branch "$d/wt" fm/feat-f10b
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10b.meta" "window=fm:fm-feat-f10b" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-f10b)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-f10b ${short}  2026-08-27 12:09"
  local out; out=$(run_crew_state "$d" feat-f10b)
  assert_contains "$out" "state: failed" "a genuinely failed run with no later run still reports failed"
  assert_contains "$out" "source: run-step" "the genuine failure is run-step sourced"
  pass "a genuinely failed run with no later run is not hidden"
}

# --- A terminal FAILED run must be proven current before it is reported -----
# Regression family for the 2026-08-27 incident: bin/fm-crew-state.sh matched a
# run against the worktree's current code and so inherited whatever run last sat
# on that head. A stale FAILED run then
# outranked every newer record - a declared pause, a terminal done line, and even
# a live run in flight on the same branch - and that false failure was promoted
# into a captain-facing terminal outcome. The fixtures below drive each newer
# record apart from the failed run deliberately, and the two negative cases pin
# the opposite direction so a real failure is never hidden.

run_cancelled() {  # <branch> [pr]
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: cancelled
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "${2:-}"
  findings: none
outcome: cancelled
EOF
}

# The ledger's date column is validated as a real local-time stamp, so these
# fixtures are anchored to the same clock the reader uses rather than to a fixed
# calendar date.
ledger_stamp_minutes_ago() {  # <minutes>
  local epoch
  epoch=$(( $(date +%s) - $1 * 60 ))
  date -r "$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$epoch" '+%Y-%m-%d %H:%M'
}

# The reported live shape: `axi status` answers this branch's own FAILED run at
# exactly the worktree head, while the branch's ledger shows a newer run still in
# flight. The failed row is history; reporting it told the captain that healthy,
# progressing work had failed.
# Since f5d7f5f2 (#4476) this is rule 2b's case (c), not case (a): the ledger
# carries no run id, so a LIVE replacement cannot be proven current here and the
# honest answer is unknown. The safety properties this case exists to pin are
# unchanged - the stale failure must not surface, and neither must its PR.
test_later_active_run_supersedes_failed_reading() {
  reset_fakes
  local d short; d=$(new_case stale-failed-later-active)
  make_repo_on_branch "$d/wt" fm/feat-s1
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s1.meta" "window=fm:fm-feat-s1" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_with_pr fm/feat-s1 https://github.com/o/r/pull/1)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-s1 f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-s1 ${short}  2026-08-27 12:09
EOF
)"
  local out; out=$(run_crew_state "$d" feat-s1)
  assert_contains "$out" "state: unknown" "an unprovable live replacement outranks the failed reading as unknown"
  assert_not_contains "$out" "state: failed" "the superseded failed run must not surface"
  assert_not_contains "$out" "pull/1" "the stale failed run's pull request must not surface"
  assert_contains "$out" "replacement run identity unavailable" "the detail names the unprovable replacement"
  pass "a later active run supersedes a stale failed reading"
}

# The record's second requested case: failed run, then a LATER SUCCESSFUL run.
# The completed row's head is not an object in this copy, so the strict
# attribution bar refuses to bind it. It still proves the failed answer is
# history. Re-pointed from `done`: that verdict came from the crew's own
# terminal line, which the reader no longer orders against the run, so the
# answer it owes is unknown - the stale failure is still not published, and no
# unprovable success is published in its place.
test_later_completed_run_leaves_the_failure_unprovable() {
  reset_fakes
  local d short; d=$(new_case stale-failed-later-completed)
  make_repo_on_branch "$d/wt" fm/feat-s2
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2.meta" "window=fm:fm-feat-s2" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2890 merged\n' > "$d/state/feat-s2.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s2)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  completed  fm/feat-s2 f0f0f0f0  $(ledger_stamp_minutes_ago 30)  https://github.com/o/r/pull/2890
  failed     fm/feat-s2 ${short}  $(ledger_stamp_minutes_ago 60)
EOF
)"
  local out; out=$(run_crew_state "$d" feat-s2)
  assert_contains "$out" "state: unknown" "an unbindable completed row leaves the current state unproven"
  assert_not_contains "$out" "state: failed" "the superseded failed run must not surface"
  assert_not_contains "$out" "state: done" "an unbindable completed row is never published as a success"
  assert_not_contains "$out" "source: status-log" "the crew's own word is never published as the verdict"
  pass "a later unbindable completed run leaves the failure unprovable"
}

# Same ledger, no status log to explain the crew. An unbindable later run is not
# proof of any current state, but it IS proof the failed answer is history, so
# the reader says unknown - which keeps ordinary supervision on the crew and
# never becomes a captain-facing terminal outcome.
test_unbindable_later_run_reports_unknown_not_failed() {
  reset_fakes
  local d short; d=$(new_case stale-failed-unbindable-later)
  make_repo_on_branch "$d/wt" fm/feat-s2b
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2b.meta" "window=fm:fm-feat-s2b" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s2b)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  completed  fm/feat-s2b f0f0f0f0  2026-08-27 15:20
  failed     fm/feat-s2b ${short}  2026-08-27 12:09
EOF
)"
  local out; out=$(run_crew_state "$d" feat-s2b)
  assert_contains "$out" "state: unknown" "an unbindable later run leaves the current state unproven"
  assert_not_contains "$out" "state: failed" "the superseded failed run must not surface"
  assert_contains "$out" "cannot be bound" "the detail names the unbindable ledger row, not a proven newer run"
  pass "an unbindable later run reports unknown rather than a stale failure"
}

# A newer terminal row can be just as distinct as a newer active row. Its
# terminal status must not make the older attributed run look current, and an
# unbindable row supplies no replacement state or PR identity.
test_unbindable_later_terminal_run_reports_unknown() {
  reset_fakes
  local d short; d=$(new_case stale-failed-unbindable-terminal)
  make_repo_on_branch "$d/wt" fm/feat-s2c
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2c.meta" "window=fm:fm-feat-s2c" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_with_pr fm/feat-s2c https://github.com/o/r/pull/1)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-s2c f0f0f0f0  2026-08-27 15:20  https://github.com/o/r/pull/2
  failed     fm/feat-s2c ${short}  2026-08-27 12:09  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-s2c)
  assert_contains "$out" "state: unknown" "a distinct unbindable terminal row leaves the current state unproven"
  assert_not_contains "$out" "state: failed" "the older attributed failure must not surface"
  assert_not_contains "$out" "pr=" "an unknown state must not publish either run's pull request"
  pass "a distinct unbindable terminal row supersedes an older failure"
}

test_same_head_terminal_rerun_publishes_newest_pr() {
  reset_fakes
  local d short; d=$(new_case same-head-terminal-rerun)
  make_repo_on_branch "$d/wt" fm/feat-s2d
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2d.meta" "window=fm:fm-feat-s2d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_with_pr fm/feat-s2d https://github.com/o/r/pull/1)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-s2d ${short}  2026-08-27 15:20  https://github.com/o/r/pull/2
  failed     fm/feat-s2d ${short}  2026-08-27 12:09  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-s2d)
  assert_contains "$out" "state: failed" "the newest same-head terminal run remains failed"
  assert_contains "$out" "pr=https://github.com/o/r/pull/2" "the newest same-head run publishes its own pull request"
  assert_not_contains "$out" "pull/1" "the stale same-head run's pull request must not surface"
  pass "a same-head terminal rerun publishes the newest pull request"
}

# The ledger is a 200-row window, so a long-inactive crew - exactly what
# bin/fm-inactive-reconcile.sh scans - routinely has no row for its branch at
# all. An absent row is absence of contradicting evidence, not disproof, so the
# reading keeps the pull request from the same record that supplied its state:
# telling the captain the work is done while naming nothing to look at is its
# own false report.
test_terminal_reading_keeps_its_pr_when_the_ledger_has_no_row() {
  reset_fakes
  local d out; d=$(new_case terminal-pr-no-ledger-row)
  make_repo_on_branch "$d/wt" fm/feat-s2m
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2m.meta" "window=fm:fm-feat-s2m" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-s2m https://github.com/o/r/pull/4444)"
  FM_FAKE_RUNS_LIST=""
  out=$(run_crew_state "$d" feat-s2m)
  assert_contains "$out" "state: done" "the attributed terminal reading still stands"
  assert_contains "$out" "pr=https://github.com/o/r/pull/4444" \
    "an absent ledger row does not withhold the delivered pull request"
  assert_not_contains "$out" "state: unknown" "no ledger row means no contradiction"
  pass "a terminal reading keeps its pull request when the ledger has no row"
}

# The run id is a FIELD of the published line, not a word inside a clause. The
# precedence verdicts splice the reading's own detail into their sentences, so
# the id must be appended once at the end - otherwise the ' · ' field separator
# lands mid-clause and splits one sentence across two apparent fields. Only the
# inventory path assigns a run id, so this needs a real overview: a plain status
# TOON leaves the id empty and the defect invisible.
test_precedence_verdict_reads_as_one_sentence_with_the_run_id_last() {
  reset_fakes
  local d out; d=$(new_case precedence-run-id-field)
  make_repo_on_branch "$d/wt" fm/feat-s2n
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2n.meta" "window=fm:fm-feat-s2n" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  01RUN,fm/feat-s2n,failed,${FM_FAKE_RUN_HEAD},\"\""
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s2n)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s2n f0f0f0f0  $(ledger_stamp_minutes_ago 30)"
  out=$(run_crew_state "$d" feat-s2n)
  assert_contains "$out" "state: unknown" "an unbindable newest row still reads unknown"
  assert_contains "$out" "cannot be bound to the run failed; current state not provable here" \
    "the verdict's sentence is not split by the run-id field"
  assert_contains "$out" "not provable here · run: 01RUN" "the run id is the line's last field"
  pass "a precedence verdict reads as one sentence with the run id last"
}

# A verdict taken from the ledger row must not be labelled with the attributed
# run's identity. This arm fires only when the newest row is NOT provably the
# attributed run - here it carries a different pull request at the same head -
# so the verdict word and the pull request both come from that row, and the
# attributed reading is named only as the reading that row could not be bound
# to: an unbindable row does not prove a second, earlier run.
test_ledger_sourced_verdict_never_names_the_attributed_run_as_its_own() {
  reset_fakes
  local d short out; d=$(new_case ledger-verdict-attribution)
  make_repo_on_branch "$d/wt" fm/feat-s2k
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2k.meta" "window=fm:fm-feat-s2k" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_with_pr fm/feat-s2k https://github.com/o/r/pull/1111)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-s2k ${short}  $(ledger_stamp_minutes_ago 30)  https://github.com/o/r/pull/2222
  failed     fm/feat-s2k ${short}  $(ledger_stamp_minutes_ago 90)  https://github.com/o/r/pull/1111
EOF
)"
  out=$(run_crew_state "$d" feat-s2k)
  assert_contains "$out" "pr=https://github.com/o/r/pull/2222" "the pull request comes from the newest ledger row"
  assert_not_contains "$out" "pull/1111" "the attributed run's pull request must not surface"
  assert_contains "$out" "run failed from the ledger's row for this worktree" \
    "the verdict names the row it came from"
  assert_contains "$out" "the run failed reading could not be bound to it" \
    "the attributed reading is named only as the one that row could not be bound to"
  assert_not_contains "$out" "(earlier " \
    "an unbindable ledger row must not assert a second, earlier run"
  assert_not_contains "$out" "run failed · pr=" \
    "a ledger-sourced verdict never stands bare beside another record's pull request"
  pass "a ledger-sourced verdict never names the attributed run as its own"

  # A newer cancellation at this same head contradicts the old failure but
  # supplies no replacement failure verdict or terminal pull request.
  FM_FAKE_RUNS_LIST="$(printf '%s\n' "$FM_FAKE_RUNS_LIST" | sed '1s/failed/cancelled/')"
  out=$(run_crew_state "$d" feat-s2k)
  assert_contains "$out" "state: unknown" "a newer cancelled row is not a failed verdict"
  assert_not_contains "$out" "state: failed" "the earlier failure must not override cancellation"
  assert_not_contains "$out" "pr=" "cancellation publishes neither run's terminal pull request"
  pass "a newer cancelled ledger row leaves an earlier failure unprovable"
}

# A record cannot supersede itself. On the coarse path the emitted reading is
# already derived from the branch's newest ledger row - the same single row the
# supersession arm would compare it against - so the reader must publish the
# reading plainly, with no earlier clause claiming a supersession that never
# happened.
test_coarse_terminal_reading_claims_no_supersession() {
  reset_fakes
  local d short out; d=$(new_case coarse-no-self-supersession)
  make_repo_on_branch "$d/wt" fm/feat-s2l
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2l.meta" "window=fm:fm-feat-s2l" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  $(ledger_stamp_minutes_ago 10)
  cancelled  fm/feat-s2l ${short}  $(ledger_stamp_minutes_ago 30)  https://github.com/o/r/pull/3333
EOF
)"
  out=$(run_crew_state "$d" feat-s2l)
  assert_contains "$out" "state: unknown" "a coarse cancelled row has no verdict"
  assert_contains "$out" "run cancelled" "the coarse reading keeps its own detail"
  assert_not_contains "$out" "(earlier " "one ledger row must not be reported as superseding itself"
  assert_not_contains "$out" "pr=" "a coarse cancelled row publishes no terminal pull request"
  pass "a coarse terminal reading claims no supersession"
}

# Both readers of the `no-mistakes runs` listing must agree on when the ledger is
# unreadable: a row the strict reader rejects must not still supply newest-row
# evidence that unbinds the attributed run.
test_malformed_ledger_row_supplies_no_newest_evidence() {
  reset_fakes
  local d short; d=$(new_case malformed-ledger-row)
  make_repo_on_branch "$d/wt" fm/feat-s2i
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2i.meta" "window=fm:fm-feat-s2i" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s2i)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s2i ${short}  $(ledger_stamp_minutes_ago 60)  https://github.com/o/r/pull/3 stray"
  local out; out=$(run_crew_state "$d" feat-s2i)
  assert_contains "$out" "state: failed" "an unreadable ledger row never unbinds the attributed run"
  assert_contains "$out" "source: run-step" "the attributed failure stays run-step sourced"
  assert_not_contains "$out" "current state not provable here" "a rejected row supplies no supersession"
  assert_not_contains "$out" "pull/3" "a rejected row publishes no pull request"
  pass "a malformed ledger row supplies no newest-row evidence"
}

# Neither side's abbreviation length is fixed: the ledger may print a longer sha
# than the run record's own head, and the current run must still bind.
test_longer_ledger_sha_still_binds_the_current_run() {
  reset_fakes
  local d full url; d=$(new_case longer-ledger-sha)
  url=https://github.com/o/r/pull/7
  make_repo_on_branch "$d/wt" fm/feat-s2j
  full=$(git -C "$d/wt" rev-parse HEAD)
  FM_FAKE_RUN_HEAD=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  export FM_FAKE_RUN_HEAD
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2j.meta" "window=fm:fm-feat-s2j" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-s2j "$url")"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-s2j ${full}  $(ledger_stamp_minutes_ago 60)  $url"
  local out; out=$(FM_CREW_STATE_NO_FORGE=1 run_crew_state "$d" feat-s2j)
  assert_contains "$out" "state: done" "the current run still reads done"
  assert_contains "$out" "pr=$url" "a longer ledger sha still binds the run and keeps its pull request"
  pass "a ledger sha longer than the run head still binds the current run"
}

test_foreign_status_never_hides_coarse_terminal_pr() {
  reset_fakes
  local d short; d=$(new_case foreign-status-terminal-pr)
  make_repo_on_branch "$d/wt" fm/feat-s2e
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2e.meta" "window=fm:fm-feat-s2e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_with_pr fm/other-crew https://github.com/o/r/pull/1)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/other-crew ${short}  2026-08-27 15:25  https://github.com/o/r/pull/1
  failed     fm/feat-s2e ${short}  2026-08-27 15:20  https://github.com/o/r/pull/2
EOF
)"
  local out; out=$(run_crew_state "$d" feat-s2e)
  assert_contains "$out" "state: failed" "the current branch's coarse terminal run remains failed"
  assert_contains "$out" "pr=https://github.com/o/r/pull/2" "the coarse terminal row publishes its own pull request"
  assert_not_contains "$out" "pull/1" "the foreign branch's pull request must not surface"
  pass "a foreign status answer cannot hide the coarse terminal pull request"
}

test_stale_passed_run_publishes_no_pr_for_active_rerun() {
  reset_fakes
  local d short; d=$(new_case stale-passed-active-rerun)
  make_repo_on_branch "$d/wt" fm/feat-s2f
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2f.meta" "window=fm:fm-feat-s2f" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-s2f)"
  FM_FAKE_RUNS_LIST="  running    fm/feat-s2f ${short}  2026-08-27 15:20"
  local out; out=$(run_crew_state "$d" feat-s2f)
  # Since f5d7f5f2 (#4476) the unprovable live rerun reads unknown (case (c)).
  assert_contains "$out" "state: unknown" "an unprovable live rerun outranks the passed reading as unknown"
  assert_not_contains "$out" "pr=" "a stale passed reading publishes no pull request for an active rerun"
  assert_not_contains "$out" "pull/1" "the stale passed run's pull request must not surface"
  pass "a stale passed run publishes no pull request for an active rerun"
}

test_cancelled_run_publishes_no_pr_for_active_rerun() {
  reset_fakes
  local d short; d=$(new_case stale-cancelled-active-rerun)
  make_repo_on_branch "$d/wt" fm/feat-s2g
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2g.meta" "window=fm:fm-feat-s2g" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_cancelled fm/feat-s2g https://github.com/o/r/pull/1)"
  FM_FAKE_RUNS_LIST="  running    fm/feat-s2g ${short}  2026-08-27 15:20"
  local out; out=$(run_crew_state "$d" feat-s2g)
  # Since f5d7f5f2 (#4476) the unprovable live rerun reads unknown (case (c)).
  assert_contains "$out" "state: unknown" "an unprovable live rerun outranks the cancelled reading as unknown"
  assert_not_contains "$out" "pr=" "a stale cancelled reading publishes no pull request for an active rerun"
  assert_not_contains "$out" "pull/1" "the stale cancelled run's pull request must not surface"
  pass "a stale cancelled run publishes no pull request for an active rerun"
}

# A terminal DONE reading is exactly as stale-able as a terminal failed one:
# head identity binds whatever run last sat on this head, and
# bin/fm-inactive-reconcile.sh promotes either reading straight into a
# captain-facing terminal outcome. A false success is the worse of the two,
# because nobody goes looking, so a newer branch row the reader cannot bind to
# this run must leave the success unprovable rather than published.
test_contradicted_done_reading_is_never_published_as_success() {
  reset_fakes
  local d; d=$(new_case stale-done-newer-row)
  make_repo_on_branch "$d/wt" fm/feat-s2h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s2h.meta" "window=fm:fm-feat-s2h" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-s2h)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s2h f0f0f0f0  $(ledger_stamp_minutes_ago 60)"
  local out; out=$(run_crew_state "$d" feat-s2h)
  assert_contains "$out" "state: unknown" "an unbindable newer row leaves the done reading unprovable"
  assert_not_contains "$out" "state: done" "a contradicted terminal success is never published"
  assert_contains "$out" "current state not provable here" "the reader answers honestly instead of guessing"
  assert_not_contains "$out" "pull/1" "the stale success publishes no pull request"
  pass "a contradicted done reading is never published as a success"
}

# The original title case: the crew declared a bounded external wait after a
# failed reading the ledger cannot bind to this run, and that stale failure was
# reported as the crew's current state, so the pane kept producing wedge-suspect
# wakes for healthy work. The ledger row here sits at a head this worktree does
# not carry, so the failure is not provably current. Re-pointed from the crew's
# own word winning: the reader no longer orders the status log against the run
# at all, so the answer it owes here is an honest unknown - the false failure is
# still gone, and no crew word is minted as a verdict in its place.
test_later_declared_pause_leaves_the_failure_unprovable() {
  reset_fakes
  local d; d=$(new_case stale-failed-later-pause)
  make_repo_on_branch "$d/wt" fm/feat-s3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s3.meta" "window=fm:fm-feat-s3" "worktree=$d/wt" "kind=ship"
  printf 'paused: polling the CI run myself\n' > "$d/state/feat-s3.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s3)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s3 f0f0f0f0  $(ledger_stamp_minutes_ago 60)"
  local out; out=$(run_crew_state "$d" feat-s3)
  assert_contains "$out" "state: unknown" "an unbindable failed row is never reported as the current state"
  assert_not_contains "$out" "state: failed" "the stale failure must not be published as current"
  assert_not_contains "$out" "source: status-log" "the crew's own word is never published as the verdict"
  assert_contains "$out" "current state not provable here" "the reader answers honestly instead of guessing"
  pass "a stale failed reading behind a declared pause reads unknown"
}

# Cancellation has no verdict, and a later declared pause must not turn it into
# a terminal result through the failed-run precedence path.
test_later_declared_pause_leaves_the_cancelled_reading_unprovable() {
  reset_fakes
  local d; d=$(new_case stale-cancelled-later-pause)
  make_repo_on_branch "$d/wt" fm/feat-s4
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s4.meta" "window=fm:fm-feat-s4" "worktree=$d/wt" "kind=ship"
  printf 'paused: waiting on the upstream release\n' > "$d/state/feat-s4.status"
  FM_FAKE_AXI_STATUS="$(run_cancelled fm/feat-s4)"
  FM_FAKE_RUNS_LIST="  cancelled  fm/feat-s4 f0f0f0f0  $(ledger_stamp_minutes_ago 60)"
  local out; out=$(run_crew_state "$d" feat-s4)
  assert_contains "$out" "state: unknown" "an unbindable cancelled row is never reported as the current state"
  assert_not_contains "$out" "source: status-log" "the crew's own word is never published as the verdict"
  pass "a stale cancelled reading behind a declared pause reads unknown"
}

# The record's other masked case: an agent that was stopped after its PR merged
# left a terminal done line the failed run outranked. Re-pointed for the same
# reason as the pause case - and this direction matters most, because publishing
# the crew's `done:` over a failed run would be a captain-facing false success.
test_later_declared_done_leaves_the_failure_unprovable() {
  reset_fakes
  local d; d=$(new_case stale-failed-later-done)
  make_repo_on_branch "$d/wt" fm/feat-s5
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s5.meta" "window=fm:fm-feat-s5" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2890 merged\n' > "$d/state/feat-s5.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s5)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s5 f0f0f0f0  $(ledger_stamp_minutes_ago 60)"
  local out; out=$(run_crew_state "$d" feat-s5)
  assert_contains "$out" "state: unknown" "an unbindable failed row is never reported as the current state"
  assert_not_contains "$out" "state: done" "a crew's own word is never minted as a terminal success"
  assert_not_contains "$out" "pull/2890" "no pull request is published from a status-log claim"
  pass "a stale failed reading behind a declared done reads unknown"
}

# A crew's own word must never be minted as a terminal success over a
# replacement run that is still validating: the ledger carries no run id, so a
# live row can never be proven current. Retained after the status-log ordering
# rules were removed, because it pins the answer the reader owes for a live row
# it cannot bind - unknown, from neither record.
test_live_replacement_run_outranks_a_status_log_done() {
  reset_fakes
  local d; d=$(new_case live-replacement-done-log)
  make_repo_on_branch "$d/wt" fm/feat-s5d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s5d.meta" "window=fm:fm-feat-s5d" "worktree=$d/wt" "kind=ship"
  printf 'done: implementation complete\n' > "$d/state/feat-s5d.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s5d)"
  FM_FAKE_RUNS_LIST="  running    fm/feat-s5d f0f0f0f0  $(ledger_stamp_minutes_ago 60)"
  local out; out=$(run_crew_state "$d" feat-s5d)
  assert_not_contains "$out" "state: done" "a crew's word never outranks a live replacement run"
  assert_not_contains "$out" "source: status-log" "no status-log verdict is published against a live row"
  assert_contains "$out" "current state not provable here" "an unbindable live replacement reads unknown"
  pass "a live replacement run outranks a status-log done"
}

# When the ledger row IS the attributed run, no self-declared pause may outrank
# its failure, whenever the crew wrote it. The reader no longer orders the log
# against the run at all, so this holds for a declaration written before, during
# or after the run.
test_mid_run_pause_does_not_mask_current_run_failure() {
  reset_fakes
  local d short; d=$(new_case mid-run-pause-current-failure)
  make_repo_on_branch "$d/wt" fm/feat-s5b
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s5b.meta" "window=fm:fm-feat-s5b" "worktree=$d/wt" "kind=ship"
  printf 'paused: polling the CI run myself\n' > "$d/state/feat-s5b.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s5b)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s5b ${short}  $(ledger_stamp_minutes_ago 60)"
  local out; out=$(run_crew_state "$d" feat-s5b)
  assert_contains "$out" "state: failed" "a mid-run pause cannot mask the current run's failure"
  assert_contains "$out" "source: run-step" "the failure stays run-step sourced"
  assert_not_contains "$out" "state: paused" "the declaration never becomes the reported state"
  pass "a mid-run pause does not mask the current run's failure"
}

# The routine ship shape in the same AGREES=1 shape: the crew reports its
# implementation done while the run is still going, the run then fails, and the
# captain must still be told the run failed. Its sibling below fixes the same
# shape with the declaration written before the run; the reader no longer
# distinguishes the two, and must answer failed for both.
test_mid_run_done_log_does_not_mask_current_run_failure() {
  reset_fakes
  local d; d=$(new_case mid-run-done-current-failure)
  make_repo_on_branch "$d/wt" fm/feat-s5c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s5c.meta" "window=fm:fm-feat-s5c" "worktree=$d/wt" "kind=ship"
  printf 'done: implementation complete\n' > "$d/state/feat-s5c.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s5c)"
  local short; short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s5c ${short}  $(ledger_stamp_minutes_ago 60)"
  local out; out=$(run_crew_state "$d" feat-s5c)
  assert_contains "$out" "state: failed" "a mid-run done line cannot mask the current run's failure"
  assert_contains "$out" "source: run-step" "the failure stays run-step sourced"
  assert_not_contains "$out" "state: done" "the declaration never becomes the reported state"
  pass "a mid-run done line does not mask the current run's failure"
}

# Opposite direction 1: a done line the crew appended BEFORE its validation run
# even started must never convert a real failure into a false success. This is
# the routine ship shape - the crew reports its implementation done, firstmate
# starts the run, the run fails - and the ledger row is that very run.
test_pre_run_done_log_does_not_mask_failed_run() {
  reset_fakes
  local d short; d=$(new_case pre-run-done-log)
  make_repo_on_branch "$d/wt" fm/feat-s6
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s6.meta" "window=fm:fm-feat-s6" "worktree=$d/wt" "kind=ship"
  printf 'done: implementation complete\n' > "$d/state/feat-s6.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s6)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s6 ${short}  $(ledger_stamp_minutes_ago 60)"
  local out; out=$(run_crew_state "$d" feat-s6)
  assert_contains "$out" "state: failed" "a done line older than the run never masks the failure"
  assert_contains "$out" "source: run-step" "the failure stays run-step sourced"
  assert_not_contains "$out" "state: done" "an older declaration never becomes the reported state"
  pass "a pre-run done line does not mask a failed run"
}

# Opposite direction 2: with no ledger row to order the records against, there is
# no evidence the status line is newer, so the failed run stands.
test_failed_run_without_ordering_evidence_still_surfaces() {
  reset_fakes
  local d; d=$(new_case failed-no-ordering)
  make_repo_on_branch "$d/wt" fm/feat-s7
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s7.meta" "window=fm:fm-feat-s7" "worktree=$d/wt" "kind=ship"
  printf 'paused: waiting on something\n' > "$d/state/feat-s7.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s7)"
  local out; out=$(run_crew_state "$d" feat-s7)
  assert_contains "$out" "state: failed" "an unorderable pause never masks the failure"
  assert_contains "$out" "source: run-step" "the failure stays run-step sourced"
  pass "a failed run with no ordering evidence still surfaces"
}

# Opposite direction 3: a stale needs-decision line is exactly the log staleness
# this reader exists to correct, so it must never supersede a failed run.
test_needs_decision_log_never_supersedes_failed_run() {
  reset_fakes
  local d short; d=$(new_case needs-decision-vs-failed)
  make_repo_on_branch "$d/wt" fm/feat-s8
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s8.meta" "window=fm:fm-feat-s8" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: pick A or B\n' > "$d/state/feat-s8.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s8)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s8 ${short}  $(ledger_stamp_minutes_ago 60)"
  local out; out=$(run_crew_state "$d" feat-s8)
  assert_contains "$out" "state: failed" "a needs-decision line never supersedes a failed run"
  assert_contains "$out" "source: run-step" "the failure stays run-step sourced"
  pass "a needs-decision log never supersedes a failed run"
}

# The terminal outcome's PR identity must come from the run that produced the
# state. A failed run that never reached its pr step opened no pull request, so
# the reader must not lend it one.
test_failed_run_detail_carries_no_pr_it_never_opened() {
  reset_fakes
  local d short; d=$(new_case failed-no-pr)
  make_repo_on_branch "$d/wt" fm/feat-s9
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s9.meta" "window=fm:fm-feat-s9" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-s9)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-s9 ${short}  2026-08-27 12:09"
  local out; out=$(run_crew_state "$d" feat-s9)
  assert_contains "$out" "state: failed" "the genuine failure still reports failed"
  assert_not_contains "$out" "pr=" "a run that opened no pull request advertises none"
  pass "a failed run advertises no pull request it never opened"
}

# A terminal run that DID open a pull request publishes that identity, so the
# terminal-outcome record can take its PR from the same source as its state.
test_terminal_run_detail_carries_its_own_pr() {
  reset_fakes
  local d short; d=$(new_case terminal-run-pr)
  make_repo_on_branch "$d/wt" fm/feat-s10
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-s10.meta" "window=fm:fm-feat-s10" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-s10)"
  FM_FAKE_RUNS_LIST="  completed  fm/feat-s10 ${short}  2026-08-27 15:20  https://github.com/o/r/pull/1"
  local out; out=$(run_crew_state "$d" feat-s10)
  assert_contains "$out" "state: done" "a passed run reports done"
  assert_contains "$out" "pr=https://github.com/o/r/pull/1" "the run publishes the pull request it opened"
  pass "a terminal run publishes its own pull request identity"
}

# The coarse runs-list rows: the branch's newest row is ACTIVE at an
# unresolvable head and the row immediately before it ended at exactly this
# worktree's head - the ledger proves this is this crew's own pipeline-owned
# fix round (axi status answers another branch here, so attribution can only
# go through the coarse list). The anchored active run answers via the
# run-step, and the older failed row never surfaces.
test_coarse_unresolvable_active_row_never_falls_to_older_row() {
  reset_fakes
  local d short; d=$(new_case f10-coarse-guard)
  make_repo_on_branch "$d/wt" fm/feat-f10c
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10c.meta" "window=fm:fm-feat-f10c" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-27 14:00
  running    fm/feat-f10c f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10c ${short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-f10c)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-f10c busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-f10c)
  assert_not_contains "$out" "state: failed" "an unresolvable active row must not fall to the older failed row"
  assert_contains "$out" "source: run-step" "the ledger-anchored continuation binds via the runs list"
  assert_contains "$out" "state: working" "the anchored active fix round reads working"
  assert_contains "$out" "validating (background run)" "coarse resolution keeps coarse run detail"
  pass "coarse scan anchors the unresolvable active row instead of falling to an older one"
}

# Coarse negative control: the anchor must end at EXACTLY this worktree's
# head. The newest same-branch row is active at an unresolvable head, but the
# row immediately before it sits at an OLDER local commit, so the ledger
# proves nothing - unknown attribution stops the scan, never falls to the
# older failed row, and the busy pane answers instead.
test_coarse_mismatched_anchor_falls_to_pane_not_older_row() {
  reset_fakes
  local d old_short; d=$(new_case f10-coarse-no-anchor)
  make_repo_on_branch "$d/wt" fm/feat-f10g
  git -C "$d/wt" commit -q --allow-empty -m 'second local commit'
  old_short=$(git -C "$d/wt" rev-parse --short=8 HEAD~1)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10g.meta" "window=fm:fm-feat-f10g" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-27 14:00
  running    fm/feat-f10g f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10g ${old_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-f10g)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-f10g busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-f10g)
  assert_not_contains "$out" "state: failed" "a mismatched anchor must not fall to the older failed row"
  assert_not_contains "$out" "source: run-step" "unknown attribution must not bind a run"
  assert_contains "$out" "state: working" "the busy crew still reads working through the pane fallback"
  assert_contains "$out" "source: pane" "without an exact anchor the pane answers, not the runs rows"
  pass "coarse scan with a mismatched anchor stays unknown and lets the pane answer"
}

# The same ledger with the newest row TERMINAL keeps the strict rule: a finished
# run on a diverged head is history, not this worktree's current run.
test_coarse_terminal_row_at_foreign_head_not_attributed() {
  reset_fakes
  local d; d=$(new_case f10-coarse-terminal)
  make_repo_on_branch "$d/wt" fm/feat-f10h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10h.meta" "window=fm:fm-feat-f10h" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-f10h.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-27 14:00
  failed     fm/feat-f10h f0f0f0f0  2026-08-27 13:53
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10h
  local out; out=$(run_crew_state "$d" feat-f10h)
  assert_not_contains "$out" "source: run-step" "a terminal row at an unresolvable head must not bind"
  assert_not_contains "$out" "state: failed" "an unattributed terminal row must not read as failure"
  assert_contains "$out" "source: status-log" "the status log answers without an attributable run"
  pass "coarse terminal row at a foreign head is not attributed"
}

# An EXECUTING run on the task's branch binds whatever branch_sync says and
# whatever its head, so the pipeline_owned exemption is no longer the only way a
# live run with an unresolvable lane head is attributed.
test_executing_run_binds_without_pipeline_owned_sync() {
  reset_fakes
  local d; d=$(new_case f10-not-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10d.meta" "window=fm:fm-feat-f10d" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-f10d.status"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10d f0f0f0f0 synced)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10d
  local out; out=$(run_crew_state "$d" feat-f10d)
  assert_contains "$out" "source: run-step" "an executing run binds without the pipeline_owned label"
  assert_contains "$out" "state: working" "the executing run reads working"
  pass "an executing run binds regardless of branch_sync state"
}

# Negative control: a run PARKED at a gate keeps the strict head rule, so a
# non-pipeline_owned parked run at an unresolvable head is not attributed. The
# ledger carries a live same-branch row at that same unresolvable head - the
# coarse fallback must not revive the rejected run's gate detail through it,
# because a bare `running` row cannot tell working from waiting at a gate.
test_non_pipeline_owned_parked_unresolvable_head_not_attributed() {
  reset_fakes
  local d; d=$(new_case f10-parked-not-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10p
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10p.meta" "window=fm:fm-feat-f10p" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-f10p.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-f10p)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="  running    fm/feat-f10p f0f0f0f0  2026-08-27 13:53"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10p
  local out; out=$(run_crew_state "$d" feat-f10p)
  assert_not_contains "$out" "source: run-step" "a non-pipeline-owned parked run at an unresolvable head must not bind"
  assert_not_contains "$out" "parked at" "a live ledger row must not revive the rejected run's gate detail"
  assert_contains "$out" "source: status-log" "falls back to the status log for the unbound parked run"
  pass "a parked run keeps the strict head rule without pipeline_owned"
}

# The CLI leaves the top-level `status:` word at `running` while a run WAITS at
# a gate, so the word alone cannot decide "executing". A gate-parked run at an
# unresolvable head, on a branch the pipeline has released, must keep the strict
# head rule in both gate shapes - otherwise the crew reports a stale
# `parked at <gate>` from a run whose code identity was never verified.
test_gate_parked_run_with_live_status_word_not_attributed() {
  local fixture d out
  for fixture in run_parked_scalar_gate_running run_parked_in_gate_block; do
    reset_fakes
    d=$(new_case "f10-gate-parked-$fixture")
    make_repo_on_branch "$d/wt" fm/feat-f10q
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-f10q.meta" "window=fm:fm-feat-f10q" "worktree=$d/wt" "kind=ship" "harness=claude"
    printf 'working: implementing\n' > "$d/state/feat-f10q.status"
    FM_FAKE_RUN_HEAD=f0f0f0f0
    FM_FAKE_AXI_STATUS="$($fixture fm/feat-f10q)
branch_sync:
  state: synced"
    FM_FAKE_RUNS_LIST=""
    FM_FAKE_BUSY=0
    arm_idle_record "$d/state" feat-f10q
    out=$(run_crew_state "$d" feat-f10q)
    assert_not_contains "$out" "source: run-step" "$fixture: a gate-parked run at an unresolvable head must not bind"
    assert_not_contains "$out" "parked at" "$fixture: no gate detail may come from an unverified run"
    assert_contains "$out" "source: status-log" "$fixture: the status log answers for the unbound parked run"
    pass "$fixture keeps the strict head rule despite its live status word"
  done
}

# Negative control: the exemption also requires an ACTIVE run - a terminal run
# released the branch, so an inconsistent pipeline_owned label must not bind a
# terminal run by branch name alone.
test_pipeline_owned_terminal_run_not_exempt() {
  reset_fakes
  local d; d=$(new_case f10-terminal-not-exempt)
  make_repo_on_branch "$d/wt" fm/feat-f10e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10e.meta" "window=fm:fm-feat-f10e" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 in progress\n' > "$d/state/feat-f10e.status"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10e f0f0f0f0)
outcome: failed"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10e
  local out; out=$(run_crew_state "$d" feat-f10e)
  assert_not_contains "$out" "source: run-step" "a terminal run must not bind through the exemption"
  assert_contains "$out" "source: status-log" "falls back to the status log for a terminal unresolvable head"
  pass "the exemption never applies to a terminal run"
}

test_missing_run_head_falls_back_to_current_state() {
  reset_fakes
  local d out
  d=$(new_case missing-run-head)
  make_repo_on_branch "$d/wt" fm/feat-no-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/no-head.meta" "window=fm:fm-no-head" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: current stage still in progress\n' > "$d/state/no-head.status"
  FM_FAKE_AXI_STATUS=$(run_parked fm/feat-no-head | grep -v '^  head:')
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" no-head
  out=$(run_crew_state "$d" no-head)
  assert_not_contains "$out" "source: run-step" "missing run head must not permit branch-only attribution"
  assert_contains "$out" "source: status-log" "missing run head falls back to current state sources"
  assert_contains "$out" "state: working" "status-log remains current after missing run head"
  pass "missing run head falls back instead of matching by branch"
}

# Mint a descendant of <repo>'s HEAD in a separate clone, echoing its full sha.
# The task copy never receives the new object, which is exactly the incident
# shape: the pipeline committed its fix round in its own checkout, so the run
# head advanced beyond the submitted head while the task copy lacks the commit.
mint_unfetched_fix_head() {  # <worktree>
  local wt=$1 h2
  rm -rf "$wt.pipe"
  git clone -q "$wt" "$wt.pipe"
  git -C "$wt.pipe" commit -q --allow-empty -m 'pipeline fix round commit'
  h2=$(git -C "$wt.pipe" rev-parse HEAD)
  if git -C "$wt" cat-file -e "$h2" 2>/dev/null; then
    fail "fixture broken: fix head object leaked into the task copy"
  fi
  printf '%s' "$h2"
}
