# shellcheck shell=bash
# Test cases for fm-teardown, split out of tests/fm-teardown.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-teardown.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


# Cleanup keeps the task's no-mistakes pipeline spend in this home's records
# (bin/fm-pipeline-spend.sh) while the task branch that attributes its runs and
# the task record still exist, then removes both as before.
test_teardown_records_the_task_pipeline_spend() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend)
  write_meta "$case_dir" no-mistakes ship
  : > "$case_dir/config/pipeline-spend"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/nm"
  python3 - "$case_dir/nm/state.sqlite" "$case_dir/project" "$(date +%s)" <<'PY'
import sqlite3
import sys

database, project, created = sys.argv[1], sys.argv[2], int(sys.argv[3])
db = sqlite3.connect(database)
db.executescript("""
    CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
    CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                       status TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE agent_invocations (id TEXT, run_id TEXT, purpose TEXT, session_mode TEXT,
        started_at INTEGER, exit_status TEXT, duration_ms INTEGER, input_tokens INTEGER,
        output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
        delta_input_tokens INTEGER, delta_output_tokens INTEGER, delta_cache_read_tokens INTEGER);
""")
db.execute("INSERT INTO repos VALUES ('r1', ?)", (project,))
db.execute("INSERT INTO runs VALUES ('01RUN', 'r1', 'fm/task-x1', 'completed', ?)", (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i1', '01RUN', 'review', 'cold', ?, 'ok', 100, 7, 8, 9, 10, 7, 8, 9)",
           (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i2', '01RUN', 'review', 'cold', ?, 'cancelled', 50, "
           "NULL, NULL, NULL, NULL, NULL, NULL, NULL)", (created + 1,))
db.commit()
PY
  (
    export NM_HOME="$case_dir/nm" FM_FAKE_AXI_OVERVIEW="repo: $case_dir/project"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  ) || rc=$?

  expect_code 0 "$rc" "pipeline-spend: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend: teardown left no pipeline spend record"
  jq -e '
    .task == "task-x1" and .spawn_gen == "teardown-test-task-x1"
    and .source == "no-mistakes-state" and .branch == "fm/task-x1"
    and [.runs[].id] == ["01RUN"]
    and .total.invocations == 2 and .total.exit == {"ok": 1, "cancelled": 1}
    and .total.input_tokens == {"total": 7, "unknown": 1}
  ' "$ledger" >/dev/null || fail "pipeline-spend: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend: teardown kept the task record"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "pipeline-spend: teardown kept the task branch"
  pass "teardown records the task's pipeline spend before removing its branch and record"
}

test_teardown_skips_pipeline_spend_when_disabled() {
  local case_dir rc=0
  case_dir=$(make_case pipeline-spend-disabled)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-disabled: teardown should succeed"
  assert_absent "$case_dir/data/pipeline-spend.jsonl" \
    "pipeline-spend-disabled: teardown created a spend ledger without opt-in"
  assert_absent "$case_dir/state/task-x1.meta" \
    "pipeline-spend-disabled: teardown kept the task record"
  pass 'teardown skips all pipeline-spend recording when the home has not opted in'
}

# An owned ship task whose local copy is already gone still leaves a durable
# account: the recorder writes an unavailable-source line before the record goes.
test_teardown_records_unavailable_spend_for_a_gone_worktree() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  : > "$case_dir/config/pipeline-spend"
  seed_backlog_in_flight "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-gone: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend-gone: teardown left no pipeline spend record"
  jq -e '.task == "task-x1" and .source == "unavailable" and .total == null
    and (.reason | contains("is gone"))' "$ledger" >/dev/null \
    || fail "pipeline-spend-gone: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend-gone: teardown kept the task record"
  pass "teardown records unavailable pipeline spend for an owned ship task whose copy is gone"
}

test_parked_own_run_is_aborted_before_teardown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort: teardown should still succeed"
  assert_present "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort was never invoked for the task's own parked run"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort did not target the verified run id"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-abort: teardown did not report aborting the parked run before removing the worker"
  pass "a task's own parked no-mistakes run is aborted, not orphaned, before the worker is removed"
}

# A parked run that lives in a per-workspace no-mistakes home is found and
# aborted through the home's configured resolver when NM_HOME is unset.
test_parked_run_in_a_resolved_workspace_home_is_aborted() {
  local case_dir head rc=0
  case_dir=$(make_case parked-run-resolved-home)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  mkdir -p "$case_dir/workspace-nm"
  cat > "$case_dir/resolver" <<SH
#!/usr/bin/env bash
[ "\$1" = '$case_dir/wt' ] && printf '%s\\n' '$case_dir/workspace-nm'
SH
  chmod +x "$case_dir/resolver"
  printf '%s\n' "$case_dir/resolver" > "$case_dir/config/nm-home-resolver"

  (
    unset NM_HOME
    FM_FAKE_NM_EXPECT_HOME="$case_dir/workspace-nm" \
    FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
    FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
      run_teardown "$case_dir"
  ) > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "parked-run-resolved-home: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-resolved-home: the parked run in the resolved workspace home was not aborted"
  pass "a parked run in a resolved workspace no-mistakes home is aborted before the worker is removed"
}

# An abort can race a concurrent gate response: the run finishes with a
# passing-but-not-clean outcome (an explicitly approved Test/CI exception)
# instead of landing on `cancelled`. That is still a terminal, finished run,
# so teardown must conclude cleanly rather than refuse as still-parked.
test_parked_own_run_concludes_on_passed_with_override_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-override)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-override
ci_override_reason: "live checks not all passed: Lint (fail)"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-override: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-override: a passing override outcome must not be reported as still parked"
  pass "a run that lands on passed-with-override after abort is still recognized as terminal"
}

# The same race, landing on the other automatic passing-but-not-clean outcome:
# publication or CI verification was skipped instead of an explicit override.
# That is still a terminal, finished run.
test_parked_own_run_concludes_on_passed_with_skips_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-skips)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-skips
automatic_skips: "publication skipped: no-mistakes.yaml pr.enabled=false"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-skips: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-skips: a passing skips outcome must not be reported as still parked"
  pass "a run that lands on passed-with-skips after abort is still recognized as terminal"
}

# The pipeline advanced the parked run past the submitted head in its own
# repo, so the run head object does not exist in the task copy at all and the
# strict object-local identity rule cannot bind the run. The daemon's own
# runs ledger is what still proves the run is this task's continuation: its
# newest fm/task-x1 row is active at the unfetched head, anchored by the
# immediately older fm/task-x1 row ending exactly at this worktree's HEAD.
# Teardown must conclude the run instead of orphaning a parked gate wait that
# would otherwise hold a fleet slot forever (observed 2026-09-03). Foreign
# branches' rows interleaved in the ledger must not matter.
test_parked_run_advanced_past_unfetched_head_is_still_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-pipeline-advanced-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-pipeline-advanced-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-pipeline-advanced-unfetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-pipeline-advanced-unfetched: teardown did not abort the parked run the ledger proves is this task's continuation"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-pipeline-advanced-unfetched: teardown did not report aborting the parked run"
  pass "a parked run the pipeline advanced past the task copy is still concluded from the runs ledger, not orphaned"
}

test_parked_run_with_mismatched_ledger_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-mismatched-ledger-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-mismatched-ledger-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 deadbee 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-mismatched-ledger-head: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-mismatched-ledger-head: teardown aborted a ledger run with a different head"
  pass "a ledger row for a different head never authorizes a parked-run abort"
}

test_parked_run_with_malformed_ledger_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-malformed-ledger-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-malformed-ledger-row"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
running fm/task-x1 $advanced_short
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-malformed-ledger-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-malformed-ledger-row: teardown aborted from a malformed ledger row"
  pass "a malformed ledger row never authorizes a parked-run abort"
}

test_parked_run_with_impossible_ledger_date_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-impossible-ledger-date)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-impossible-ledger-date"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-02-31 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-02-28 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-impossible-ledger-date: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-impossible-ledger-date: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-impossible-ledger-date: teardown aborted from an impossible ledger date"
  pass "an impossible ledger date never authorizes a parked-run abort"
}

test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback() {
  local case_dir rc advanced_short anchor_short terminal_status
  case_dir=$(make_case parked-run-terminal-status-gate)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-status-gate"
  terminal_status=$(parked_axi_status_toon fm/task-x1 "$advanced_short")
  terminal_status=${terminal_status/status: awaiting_approval/status: completed}

  rc=0
  FM_FAKE_AXI_STATUS="$terminal_status" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-status-gate: teardown should still succeed"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-terminal-status-gate: terminal status queried the ledger fallback"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-status-gate: terminal status with a stale gate aborted"
  pass "a terminal status with a stale gate never reaches ledger cleanup"
}

# Counterfactual twin of the unfetched defect above: the SAME parked-run shape
# with the pipeline's advanced fix head FETCHED into the task copy (objects
# only - no ref moves) resolves through the strict object-local rule alone,
# because a fix round's commits descend from this worktree's submitted HEAD.
# With an EMPTY ledger, teardown must still abort - and must never query the
# ledger at all - proving the fallback stays dormant whenever the run head's
# object is present locally (no ledger dependency on the strict-rule path).
test_parked_run_advanced_head_locally_fetched_is_still_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-fetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  # The one changed condition vs the defect case: fetch the fix commits into
  # the project clone's object store (shared with the task worktree) without
  # moving any ref, so fm_nm_resolve_commit sees the head again.
  git -C "$case_dir/project" fetch -q "$case_dir/pipeline-clone" fm/task-x1
  [ -n "$(git -C "$case_dir/wt" rev-parse --verify --quiet "${advanced_short}^{commit}" 2>/dev/null)" ] \
    || fail "parked-run-advanced-fetched: fixture broke - the pipeline head never reached the task copy"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-fetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-advanced-fetched: teardown did not abort the parked run the strict object-local rule binds"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-advanced-fetched: the ledger fallback fired even though the advanced head resolves locally"
  pass "an advanced head present locally aborts through the strict rule alone - the ledger fallback stays dormant"
}

# No anchor: the unresolvable active row is the branch's ONLY row, so nothing
# proves the run ever touched this worktree's head - a branch-name coincidence
# or an arbitrary daemon-side run must not be concluded.
test_parked_advanced_run_without_anchor_is_never_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-no-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-no-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-no-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-no-anchor: teardown aborted an unanchored run it cannot prove is its own"
  pass "an unresolvable active row with no same-branch anchor is never concluded (conservative refusal)"
}

# The anchor row resolves but to an OLDER commit: the worktree advanced past
# it since the run was submitted, so exact-equality fails and the run is not
# provably this worktree's submission. Ancestor-only anchors must never bind.
test_parked_advanced_run_ancestor_anchor_is_never_aborted() {
  local case_dir rc advanced_short parent_short
  case_dir=$(make_case parked-run-advanced-ancestor-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  parent_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD~1)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ancestor-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$parent_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ancestor-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ancestor-anchor: teardown aborted on an ancestor-only anchor"
  pass "an ancestor-only anchor never binds an advanced parked run to this task"
}

# The branch's newest same-branch row is TERMINAL at an unfetched head: a
# finished run is history, never the branch's current run, and the anchored
# older row never answers for it. Teardown must not conclude a run from a
# stale terminal row.
test_parked_terminal_unfetched_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 08:20)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-unfetched: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-unfetched: teardown concluded a run from a terminal unfetched row"
  pass "a terminal unfetched-head row is stale history and never concludes a run"
}

# The crafted d15 boundary, tightened deliberately: the axi-reported head is
# unresolvable and the branch's newest ledger row is TERMINAL at exactly this
# worktree's head - a perfectly anchored, already-finished run. A finished run
# is history, so the ledger fallback authorizes cleanup only when its proved
# answer is the explicitly active word (`running`): a terminal newest row,
# even anchored at this head, never authorizes an abort. The runs log proves
# the fallback actually engaged, so the refusal is this tightened boundary
# and not an earlier guard.
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-newest-at-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-newest-at-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-03 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-newest-at-head: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-terminal-newest-at-head: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-newest-at-head: teardown aborted a run whose newest anchored ledger row is terminal"
  pass "a terminal newest row anchored at this worktree's head never authorizes an abort"
}

# The branch's newest row resolves in this copy to a head that DIVERGED from
# this worktree's HEAD (the branch was rewritten or moved on by a newer run
# from another worktree of the same project): not equal, not a descendant,
# so the shared rule answers nothing and every older row - including this
# task's parked run - stays stale history. Neither this task's run nor the
# unrelated newer run may be concluded here.
test_parked_run_behind_diverged_newer_row_is_never_aborted() {
  local case_dir rc advanced_short diverged_short
  case_dir=$(make_case parked-run-behind-newer-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-behind-newer-row"
  # A newer fm/task-x1 head that THIS copy resolves but that diverged from
  # the worktree's HEAD: rewritten from origin/main and pushed over the
  # branch (the fixture origin allows the non-fast-forward rewrite), then
  # fetched into the project clone (shared object store).
  git -C "$case_dir/origin.git" config receive.denyNonFastForwards false
  git clone -q "$case_dir/origin.git" "$case_dir/newer-clone"
  git -C "$case_dir/newer-clone" checkout -q origin/main
  git -C "$case_dir/newer-clone" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "newer run's diverged work"
  git -C "$case_dir/newer-clone" push -q --force origin HEAD:fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  diverged_short=$(git -C "$case_dir/wt" rev-parse --short=7 origin/fm/task-x1)
  git -C "$case_dir/wt" merge-base --is-ancestor HEAD "$diverged_short" \
    && fail "parked-run-behind-newer-row: fixture broke - the newer row is a descendant, not diverged"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$diverged_short" 2026-09-03 09:00)
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 07:55)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-behind-newer-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-behind-newer-row: teardown concluded this task from another run's ledger row"
  pass "a resolvable diverged newer same-branch row makes every older row stale history; no run is concluded"
}

# Two consecutive unresolvable running rows for the branch: the ledger cannot
# prove which row is current or where the submission boundary is. Ambiguity
# must refuse, never guess.
test_parked_advanced_run_ambiguous_rows_are_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-advanced-ambiguous)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir" 2)
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ambiguous"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 08:30)
$(ledger_row failed fm/other-task ccccccc 2026-09-03 08:10)
$(ledger_row running fm/task-x1 ddddddd 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ambiguous: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ambiguous: teardown guessed through ambiguous ledger rows"
  pass "consecutive unresolvable rows are ambiguous and never conclude a run"
}

# The ledger proves the continuation, but the run is NOT parked at a gate -
# it is autonomously running/fixing against the daemon's own clone. Teardown
# must leave that work alone even when the attribution proof would bind it.
test_ledger_proven_continuation_never_aborts_active_run() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-ledger-active)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-ledger-active"

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-ledger-active: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-ledger-active: teardown aborted an actively running run the ledger happened to bind"
  pass "a ledger-proven continuation is still left alone while the run is autonomously active"
}

test_mismatched_run_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-replaced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head" 01RUN)" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT="$(parked_axi_status_toon fm/task-x1 "$head" 02RUN)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-replaced: a different run does not confirm the targeted abort"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-replaced: teardown did not abort only the verified run"
  assert_present "$case_dir/wt" "parked-run-replaced: teardown removed the worktree without confirmation"
  pass "a different run cannot confirm the targeted abort"
}

test_empty_status_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-empty-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_EMPTY_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-empty-confirmation: empty status should refuse"
  assert_present "$case_dir/wt" "parked-run-empty-confirmation: teardown removed the worktree"
  pass "empty post-abort status is not accepted as confirmation"
}

test_not_found_status_after_abort_confirms_completion() {
  local case_dir rc head
  case_dir=$(make_case parked-run-not-found-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_NOT_FOUND_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-found-confirmation: explicit not-found should confirm completion"
  pass "the CLI's exact run-not-found signal confirms completion"
}

test_parked_own_run_refuses_when_abort_is_unconfirmed() {
  local case_dir rc head pid
  case_dir=$(make_case parked-run-abort-unconfirmed)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown

  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_ABORT_NOOP=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-abort-unconfirmed: teardown should refuse"
  assert_grep "REFUSED: no-mistakes run for task-x1 is still parked after axi abort" "$case_dir/stderr" \
    "parked-run-abort-unconfirmed: teardown did not explain the parked-run refusal"
  assert_present "$case_dir/wt" \
    "parked-run-abort-unconfirmed: teardown removed the worktree after refusing"
  assert_present "$case_dir/state/task-x1.meta" \
    "parked-run-abort-unconfirmed: teardown removed task metadata after refusing"
  assert_absent "$case_dir/treehouse.log" \
    "parked-run-abort-unconfirmed: teardown returned the worktree after refusing"
  kill -0 "$pid" 2>/dev/null || fail "parked-run-abort-unconfirmed: process reap ran before refusal"
  kill -KILL "$pid" 2>/dev/null || true
  pass "teardown refuses before reap or removal when a task-owned run remains parked"
}

test_another_branchs_parked_run_is_never_touched() {
  local case_dir rc
  case_dir=$(make_case parked-run-not-ours)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  local rc=0
  # A parked run reported for a DIFFERENT branch - e.g. another crew's task
  # still validating on the shared gate - must never be aborted by this task's
  # teardown.
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/some-other-task deadbeef)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-ours: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-not-ours: teardown called axi abort for a run on another branch"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "parked-run-not-ours: teardown reported aborting a run it does not own"
  pass "a parked run on another branch is never aborted by this task's teardown (ownership is precise)"
}

test_own_autonomous_run_is_left_alone() {
  local case_dir rc head
  case_dir=$(make_case autonomous-run-left-alone)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "autonomous-run-left-alone: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "autonomous-run-left-alone: teardown aborted a task-owned autonomous run"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "autonomous-run-left-alone: teardown reported aborting an autonomous run"
  pass "a task-owned autonomous running step is left alone rather than aborted"
}

test_leaked_worktree_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-process-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # A backgrounded, disowned process rooted (by cwd) under the task's own
  # worktree - the same shape the observed incident's leaked `go test`
  # binaries took (reparented to init, no live task meta to attribute them
  # to once an unpatched teardown had already run).
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-process-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-process-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-process-reap: leaked worktree process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-process-reap: teardown did not report reaping the leaked process"
  pass "a leaked descendant process rooted under the task's worktree is reaped by teardown, not left surviving"
}

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  ( cd "$case_dir/tasktmp" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

test_lsof_absent_reaps_tmux_process_group() {
  local case_dir rc pid path_without_lsof
  case_dir=$(make_case lsof-absent-process-group-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-process-group-reap: fixture path unexpectedly exposes lsof"

  perl -e 'setpgrp(0, 0); chdir shift or die; exec "sleep", "300"' "$case_dir/wt" &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-process-group-reap: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "lsof-absent-process-group-reap: teardown should succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "lsof-absent-process-group-reap: tmux process group survived teardown"
  fi
  assert_grep "reaping leaked worktree process group" "$case_dir/stderr" \
    "lsof-absent-process-group-reap: teardown did not use the process-group fallback"
  pass "missing lsof falls back to reaping the tmux pane process group"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep "REFUSED: cannot determine leaked processes under $case_dir/wt for task-x1 (lsof failed)" "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() {
  local case_dir rc pid
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  perl -e '$SIG{TERM} = "IGNORE"; sleep 300' &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$case_dir/lsof-count' ] || count=\$(cat '$case_dir/lsof-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$case_dir/lsof-count'
if [ "\$count" -le 3 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  if [ "$count" -le 2 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_REUSED_PID="$pid" FM_FAKE_PS_COUNT="$case_dir/ps-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  kill -KILL "$pid" 2>/dev/null || true
  pass "a reused pid with a different start time is never force-killed"
}

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  ( cd "$case_dir/wt" && exec perl -e '
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      open my $fh, ">", $done or die "open";
      close $fh;
      exec "perl", "-e", '\''$SIG{TERM} = "IGNORE"; sleep 300'\'';
    ' "$marker" "$done_flag" ) &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$FM_FAKE_EXEC_MARKER" ] || : > "$FM_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_FAKE_LSOF_COUNT" ] || count=$(cat "$FM_FAKE_LSOF_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_LSOF_COUNT"
if [ "$count" -eq 2 ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$FM_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_EXEC_PID="$pid" FM_FAKE_EXEC_MARKER="$marker" \
  FM_FAKE_EXEC_DONE="$done_flag" FM_FAKE_LSOF_COUNT="$case_dir/lsof-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  ( cd "$case_dir/wt" && exec perl -e '
      my $file = shift;
      $SIG{TERM} = sub {
        my $child = fork();
        die "fork" unless defined $child;
        if (!$child) { exec "sleep", "300"; }
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh;
        exit 0;
      };
      sleep 300;
    ' "$child_file" ) &
  pid=$!
  disown
  sleep 0.2

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc wt_path fake_pid=99999999
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_PERSISTENT_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  printf 'Tue Aug  4 10:00:00 2026\n'
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_PERSISTENT_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f "$case_dir/lsof-count" ] || count=\$(cat "$case_dir/lsof-count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/lsof-count"
if [ "\$count" -eq 1 ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXITED_PID:-}" ]; then
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'returned\n' > "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_EXITED_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_run_abort_precedes_process_reap_precedes_worktree_removal() {
  local case_dir rc head pid abort_log
  case_dir=$(make_case abort-then-reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  abort_log="$case_dir/nm-abort.log"

  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "abort-then-reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs, whether the run was already aborted and whether the
  # leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ -s "$abort_log" ]; then echo "abort-already-happened" >> "$case_dir/order.log"; fi
if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$abort_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "abort-then-reap-then-remove-order: teardown should still succeed"
  kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid" 2>/dev/null || true; }

  assert_present "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "abort-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the run was not yet aborted when the worktree return ran"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the run abort and the leaked-process reap both complete before the destructive worktree return"
}

# Copy the public teardown script tree, then drop or blank one required file.
# Symlinks keep the copy cheap; an unreadable case replaces one link with a
# real mode-000 file so the probe is of the file itself.
prepare_teardown_source_copy() {  # <case-dir>
  local case_dir=$1 f base dest="$1/test-root/bin" s
  mkdir -p "$dest/backends"
  for f in "$ROOT"/bin/*; do
    base=$(basename "$f")
    if [ -d "$f" ]; then
      mkdir -p "$dest/$base"
      for s in "$f"/*; do
        ln -s "$s" "$dest/$base/$(basename "$s")"
      done
    else
      ln -s "$f" "$dest/$base"
    fi
  done
  printf 'manual\n' > "$case_dir/config/backlog-backend"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/state/task-x1.status"
}

run_copied_teardown() {  # <case-dir> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" task-x1 "$@"
}

assert_source_refusal_preserved_state() {  # <case-dir> <label> <stderr-needle>
  local case_dir=$1 label=$2 needle=$3
  [ "$rc" -ne 0 ] || fail "$label: teardown reported success after a required source disappeared"
  assert_grep "$needle" "$case_dir/stderr" "$label: the refusal did not name the missing source"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: the refusal erased task metadata"
  [ -e "$case_dir/state/task-x1.status" ] || fail "$label: the refusal erased the task status record"
  [ ! -s "$case_dir/treehouse.log" ] || fail "$label: the refusal returned the local copy: $(cat "$case_dir/treehouse.log")"
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    fail "$label: the refusal still reported cleanup complete"
  fi
}

test_missing_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-startup-source" "required source fm-nm-run-lib.sh"
  pass "a missing teardown startup source refuses before cleanup"
}

test_unreadable_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case unreadable-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  cp "$ROOT/bin/fm-nm-run-lib.sh" "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  chmod 000 "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  if [ -r "$case_dir/test-root/bin/fm-nm-run-lib.sh" ]; then
    pass "unreadable startup source skipped: this user can read mode-000 files"
    return 0
  fi
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "unreadable-startup-source" "required source fm-nm-run-lib.sh"
  pass "an unreadable teardown startup source refuses before cleanup"
}

test_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-adapter-sibling)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-proc-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-adapter-sibling" "required tmux source"
  pass "a missing adapter sibling refuses before cleanup"
}

test_forced_child_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-child-adapter-sibling)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-transition-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-child-source" "required herdr source"
  [ -e "$home/state/child-herdr.meta" ] || fail "missing-child-source: the refusal erased the child record"
  [ -d "$home" ] || fail "missing-child-source: the refusal removed the secondmate home"
  pass "a forced descendant with a missing adapter sibling refuses before cleanup"
}

test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-own-adapter-sibling)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=zs:3" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "backend=zellij" \
    "zellij_session=zs" \
    "zellij_tab_id=1" \
    "zellij_pane_id=3" \
    "spawn_gen=teardown-test-task-x1"
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-tmux.meta" \
    "window=childsession:fm-child-tmux" \
    "endpoint_task_id=child-tmux" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  : > "$home/state/child-tmux.status"
  prepare_teardown_source_copy "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tmux.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$case_dir/tmux.log"
  rm -f "$case_dir/test-root/bin/fm-backend-hometag-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-own-source" "required zellij source"
  [ -e "$home/state/child-tmux.meta" ] || fail "missing-own-source: the refusal erased the child record"
  [ -e "$home/state/child-tmux.status" ] || fail "missing-own-source: the refusal erased the child status"
  [ -d "$home" ] || fail "missing-own-source: the refusal removed the secondmate home"
  if grep -q "kill" "$case_dir/tmux.log"; then
    fail "missing-own-source: the refusal killed the child endpoint: $(cat "$case_dir/tmux.log")"
  fi
  pass "a forced secondmate with a missing own adapter sibling refuses before child cleanup"
}

test_retained_sources_still_reach_the_ordinary_refusal() {
  local case_dir rc
  case_dir=$(make_case retained-sources)
  prepare_teardown_source_copy "$case_dir"
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "retained-sources: a present source tree should still reject a request with no task id (rc=$rc)"
  assert_grep "invalid teardown request" "$case_dir/stderr" \
    "retained-sources: the ordinary refusal was replaced"
  pass "present required sources still reach the ordinary teardown refusal"
}

test_teardown_preserves_opencode_busy_plugin_on_pool_return

# An orphan status log archived by record hygiene must survive status-archive
# retention: the prune counts 30 days from archive time, not the log's last write.
test_record_hygiene_archive_survives_status_archive_prune() {
  local case_dir rc=0
  case_dir=$(make_case record-hygiene-archive-retention)
  write_meta "$case_dir" local-only ship
  touch "$case_dir/config/status-archive"
  printf 'done: complete\n' > "$case_dir/state/task-x1.status"
  printf 'failed [at=1]: orphan from a lost task\n' > "$case_dir/state/orphan-x2.status"
  touch -t 200001010000 "$case_dir/state/orphan-x2.status"
  FM_TEST_LIB_SOURCED=1 bash -c '
    SCRIPT_DIR="$1/bin"; STATE="$2/state"; DATA="$2/data"
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    # shellcheck source=bin/fm-record-hygiene-lib.sh
    . "$SCRIPT_DIR/fm-record-hygiene-lib.sh"
    record_hygiene_report
  ' _ "$ROOT" "$case_dir" > "$case_dir/hygiene.out" 2>&1 || fail "record hygiene archive pass failed: $(cat "$case_dir/hygiene.out")"
  assert_present "$case_dir/data/orphan-x2/status.log" "record hygiene did not archive the orphan status log"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "status-archive teardown after record hygiene: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/data/task-x1/status.log" "status-archive teardown did not archive its own task"
  assert_present "$case_dir/data/orphan-x2/status.log" "teardown pruned a status log record hygiene just archived"
  pass "a status log archived by record hygiene survives the next status-archive teardown"
}

# Archive coverage uses the real teardown entry point over isolated homes.
test_status_archive_opt_in() {
  local case_dir rc mode
  for mode in off on; do
    case_dir=$(make_case "status-archive-$mode")
    write_meta "$case_dir" local-only ship
    printf 'working: started\nneeds-decision [key=choice]: choose\nresolved [key=choice]: chosen\ndone: complete\n' > "$case_dir/state/task-x1.status"
    printf 'marker\n' > "$case_dir/state/.paused-overdue-task-x1"
    cp "$case_dir/state/task-x1.status" "$case_dir/expected"
    mkdir -p "$case_dir/data/old"
    printf 'old archive\n' > "$case_dir/data/old/status.log"
    touch -t 200001010000 "$case_dir/data/old/status.log"
    [ "$mode" = off ] || touch "$case_dir/config/status-archive"
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "status archive $mode teardown"
    assert_absent "$case_dir/state/task-x1.status" "live status survived teardown"
    assert_absent "$case_dir/state/.paused-overdue-task-x1" "overdue marker survived task teardown"
    if [ "$mode" = on ]; then
      cmp -s "$case_dir/expected" "$case_dir/data/task-x1/status.log" || fail "opt-in archive lost history"
    else
      assert_absent "$case_dir/data/task-x1/status.log" "default-off teardown created an archive"
      assert_present "$case_dir/data/old/status.log" "default-off teardown pruned an archive"
    fi
  done
  pass "status archival is opt-in and preserves the complete log"
}

test_record_export_config_absent_never_reads_the_exporter() {
  local case_dir rc=0
  case_dir=$(make_case record-export-off)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-record-export.sh"
  mkdir -p "$case_dir/state/task-x1.inbox/handled"
  printf 'pending\n' > "$case_dir/state/task-x1.inbox/001.msg"
  run_copied_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "config-absent teardown without exporter: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "config-absent teardown retained metadata"
  assert_absent "$case_dir/state/task-x1.status" "config-absent teardown retained status"
  assert_absent "$case_dir/state/task-x1.inbox" "config-absent teardown retained inbox"
  pass "config-absent teardown does not read or invoke record export"
}

test_record_export_unopted_symlinked_config_does_not_block_teardown() {
  local case_dir rc=0
  case_dir=$(make_case record-export-symlink-config-off)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-record-export.sh"
  mv "$case_dir/config" "$case_dir/config-target"
  ln -s "$case_dir/config-target" "$case_dir/config"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "unopted symlinked config teardown: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "unopted symlinked config retained metadata"
  assert_absent "$case_dir/state/task-x1.status" "unopted symlinked config retained status"
  pass "unopted teardown ignores symlinked config when record export is absent"
}

test_record_export_archives_before_teardown_or_preserves_sources_on_failure() {
  local case_dir export_root archive rc mode
  for mode in success failure inaccessible-config; do
    case_dir=$(make_case "record-export-$mode")
    write_meta "$case_dir" local-only ship
    export_root="$case_dir/export"
    printf '%s\n' "$export_root" > "$case_dir/config/record-export-root"
    mkdir -p "$case_dir/state/task-x1.inbox/handled"
    printf 'working: export me\ndone: complete\n' > "$case_dir/state/task-x1.status"
    printf 'pending captain text\n' > "$case_dir/state/task-x1.inbox/001.msg"
    printf 'handled captain text\n' > "$case_dir/state/task-x1.inbox/handled/002.msg"
    cp "$case_dir/state/task-x1.meta" "$case_dir/expected.meta"
    cp "$case_dir/state/task-x1.status" "$case_dir/expected.status"
    if [ "$mode" = failure ]; then
      printf 'not an export directory\n' > "$export_root"
    elif [ "$mode" = inaccessible-config ]; then
      mv "$case_dir/config" "$case_dir/config-target"
      ln -s "$case_dir/config-target" "$case_dir/config"
    fi
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$mode" = success ]; then
      expect_code 0 "$rc" "record export teardown: $(cat "$case_dir/stderr")"
      archive="$export_root/archive/task-x1/teardown-test-task-x1"
      cmp -s "$case_dir/expected.meta" "$archive/meta" || fail "teardown archive lost metadata"
      cmp -s "$case_dir/expected.status" "$archive/status" || fail "teardown archive lost status"
      assert_grep 'pending captain text' "$archive/inbox/001.msg" "teardown archive lost a pending steer"
      assert_grep 'handled captain text' "$archive/inbox/handled/002.msg" "teardown archive lost a handled steer"
      assert_present "$archive/manifest.v1.json" "teardown archive did not commit its manifest"
      assert_absent "$case_dir/state/task-x1.meta" "successful export retained metadata"
      assert_absent "$case_dir/state/task-x1.status" "successful export retained status"
      assert_absent "$case_dir/state/task-x1.inbox" "successful export retained inbox"
    else
      [ "$rc" -ne 0 ] || fail "teardown ignored a record export failure in $mode mode: $(cat "$case_dir/stderr")"
      assert_grep 'record export' "$case_dir/stderr" \
        "teardown did not report the export failure reason"
      assert_grep 'retaining task records for retry' "$case_dir/stderr" \
        "teardown did not explain its record-preservation refusal"
      assert_present "$case_dir/state/task-x1.meta" "failed export removed metadata"
      assert_present "$case_dir/state/task-x1.status" "failed export removed status"
      assert_present "$case_dir/state/task-x1.inbox/001.msg" "failed export removed a pending steer"
      assert_present "$case_dir/state/task-x1.inbox/handled/002.msg" "failed export removed a handled steer"
    fi
  done
  pass "teardown commits the record archive before deleting sources and fails closed when export cannot commit"
}

test_record_export_captures_forced_secondmate_sub_state() {
  local case_dir home export_root archive rc=0
  case_dir=$(make_case record-export-secondmate-child)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  export_root="$case_dir/export"
  mkdir -p "$home/state/child.inbox/handled" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  printf 'home=%s\n' "$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child.meta" \
    "window=firstmate:fm-child" \
    "kind=scout" \
    "mode=local-only" \
    "project=$case_dir/project" \
    "worktree=$case_dir/wt" \
    "spawn_gen=child-generation"
  printf 'done: child complete\n' > "$home/state/child.status"
  printf 'pending child steer\n' > "$home/state/child.inbox/001.msg"
  printf 'handled child steer\n' > "$home/state/child.inbox/handled/002.msg"
  printf '%s\n' "$export_root" > "$case_dir/config/record-export-root"
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "forced secondmate record export: $(cat "$case_dir/stderr")"
  archive="$export_root/archive/child/child-generation"
  assert_present "$archive/meta" "secondmate child archive lost metadata"
  assert_grep 'done: child complete' "$archive/status" "secondmate child archive lost status"
  assert_grep 'pending child steer' "$archive/inbox/001.msg" "secondmate child archive lost pending inbox"
  assert_grep 'handled child steer' "$archive/inbox/handled/002.msg" "secondmate child archive lost handled inbox"
  assert_present "$archive/manifest.v1.json" "secondmate child archive did not commit"
  assert_absent "$home" "forced secondmate teardown retained the child home"
  pass "forced secondmate teardown exports task records from the child sub-state"
}

test_record_export_waits_for_endpoint_quiescence_before_archiving() {
  local case_dir export_root archive rc=0
  case_dir=$(make_case record-export-close-retry)
  write_meta "$case_dir" local-only ship
  export_root="$case_dir/export"
  printf '%s\n' "$export_root" > "$case_dir/config/record-export-root"
  mkdir -p "$case_dir/state/task-x1.inbox/handled"
  printf 'done: before refusal\n' > "$case_dir/state/task-x1.status"
  printf 'before refusal\n' > "$case_dir/state/task-x1.inbox/001.msg"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window) exit 1 ;;
  list-windows) printf '%s\n' fm-task-x1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  run_teardown "$case_dir" > "$case_dir/first.stdout" 2> "$case_dir/first.stderr" || rc=$?
  expect_code 1 "$rc" "record-export-close-retry: endpoint close should refuse"
  assert_grep "could not be closed" "$case_dir/first.stderr" \
    "record-export-close-retry: first attempt did not reach endpoint refusal"
  assert_absent "$export_root/archive/task-x1/teardown-test-task-x1" \
    "record-export-close-retry: archive published while the endpoint remained live"
  assert_present "$case_dir/state/task-x1.meta" \
    "record-export-close-retry: endpoint refusal removed metadata"

  printf 'done: after refusal\n' > "$case_dir/state/task-x1.status"
  printf 'after refusal\n' > "$case_dir/state/task-x1.inbox/001.msg"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  rc=0
  run_teardown "$case_dir" > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "record-export-close-retry: retry should complete"
  archive="$export_root/archive/task-x1/teardown-test-task-x1"
  assert_grep "done: after refusal" "$archive/status" \
    "record-export-close-retry: retry archive contains status from before endpoint quiescence"
  assert_grep "after refusal" "$archive/inbox/001.msg" \
    "record-export-close-retry: retry archive contains inbox from before endpoint quiescence"
  assert_absent "$case_dir/state/task-x1.meta" \
    "record-export-close-retry: successful retry retained task metadata"
  pass "record export waits for endpoint quiescence and retry captures records changed after refusal"
}

test_status_archive_reuse_and_retention() {
  local case_dir rc archive
  case_dir=$(make_case status-archive-reuse)
  write_meta "$case_dir" local-only ship
  touch "$case_dir/config/status-archive"
  mkdir -p "$case_dir/data/task-x1" "$case_dir/data/old" "$case_dir/outside"
  printf 'first generation\n' > "$case_dir/data/task-x1/status.log"
  printf 'outside sentinel\n' > "$case_dir/outside/status.log"
  ln -s "$case_dir/outside/status.log" "$case_dir/data/task-x1/status.1.log"
  ln -s "$case_dir/outside" "$case_dir/data/symlink-task"
  printf 'expired\n' > "$case_dir/data/old/status.log"
  printf 'report survives\n' > "$case_dir/data/old/report.md"
  printf 'unowned file survives\n' > "$case_dir/data/old/status.notes.log"
  touch -t 200001010000 "$case_dir/data/old/"* "$case_dir/outside/status.log"
  printf 'done: second generation\n' > "$case_dir/state/task-x1.status"
  touch -t 200001010000 "$case_dir/state/task-x1.status"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "status archive reuse"
  assert_grep 'first generation' "$case_dir/data/task-x1/status.log" "first archive overwritten"
  archive="$case_dir/data/task-x1/status.2.log"
  assert_grep 'second generation' "$archive" "reused ID did not select a fresh archive"
  assert_grep 'outside sentinel' "$case_dir/outside/status.log" "archive or pruning followed a symlink"
  [ -L "$case_dir/data/task-x1/status.1.log" ] || fail "archive replaced an existing symlink"
  assert_absent "$case_dir/data/old/status.log" "expired status archive survived pruning"
  assert_present "$case_dir/data/old/report.md" "pruning removed other task data"
  assert_present "$case_dir/data/old/status.notes.log" "pruning removed an unowned filename"
  pass "reused task IDs never overwrite archives and retention removes only old owned logs"
}

test_status_archive_unsafe_paths_refuse() {
  local case_dir rc unsafe
  for unsafe in source data task children; do
    case_dir=$(make_case "status-archive-unsafe-$unsafe")
    write_meta "$case_dir" local-only ship
    touch "$case_dir/config/status-archive"
    mkdir -p "$case_dir/outside"
    printf 'untouched\n' > "$case_dir/outside/sentinel"
    printf 'done: complete\n' > "$case_dir/state/task-x1.status"
    case "$unsafe" in
      source) rm "$case_dir/state/task-x1.status"; ln -s "$case_dir/outside/sentinel" "$case_dir/state/task-x1.status" ;;
      data) rmdir "$case_dir/data"; ln -s "$case_dir/outside" "$case_dir/data" ;;
      task) ln -s "$case_dir/outside" "$case_dir/data/task-x1" ;;
      children) mkdir -p "$case_dir/data/task-x1"; ln -s "$case_dir/outside" "$case_dir/data/task-x1/children" ;;
    esac
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$unsafe" = data ]; then
      expect_code 0 "$rc" "configured symlinked data root"
      assert_grep 'done: complete' "$case_dir/outside/task-x1/status.log" "archive did not use physical data root"
    elif [ "$unsafe" = children ]; then
      expect_code 0 "$rc" "pruning ignores symlinked children: $(cat "$case_dir/stderr")"
    else
      [ "$rc" -ne 0 ] || fail "unsafe $unsafe archive path accepted"
      assert_present "$case_dir/state/task-x1.status" "refusal lost status"
    fi
    assert_grep 'untouched' "$case_dir/outside/sentinel" "unsafe path changed outside data"
    assert_absent "$case_dir/outside/status.log" "archive escaped through symlink"
  done
  pass "archive sources and directories reject symlinks; pruning never follows children links"
}

# Intercept both the old move and atomic publication so the regressions also
# exercise the failure and watcher window on the pre-fix implementation.
prepare_status_archive_presentation() {
  local case_dir=$1
  write_meta "$case_dir" local-only ship
  touch "$case_dir/config/status-archive" "$case_dir/config/supervision-host-off"
  printf 'note: archived note\ndone: archived outcome\n' > "$case_dir/state/task-x1.status"
  FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" FM_DATA_OVERRIDE="$case_dir/data" \
    bash "$ROOT/bin/fm-wake-drain.sh" > "$case_dir/before" 2> "$case_dir/drain.err" || fail "initial presentation failed"
  assert_grep 'archived note' "$case_dir/before" "fixture never presented the live note"
  FM_STATE_OVERRIDE="$case_dir/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_status_mark_current "$2" "$2/task-x1.status"
  ' _ "$ROOT" "$case_dir/state" || fail "could not mark fixture status seen"
  printf 'ledger\n' > "$case_dir/state/.task-x1.home-appends"
  touch "$case_dir/state/.hb-surfaced-task-x1"
}

install_status_archive_publish_probe() {
  local case_dir=$1 command
  for command in ln mv; do
    cat > "$case_dir/fakebin/$command" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in
  */status.log)
    touch "$FM_ARCHIVE_TEST_CASE/publish-entered"
    if [ "$FM_ARCHIVE_TEST_MODE" = fail ]; then
      echo 'simulated archive publication failure' >&2
      exit 1
    fi
    bash -c '
      . "$1/bin/fm-watch.sh"
      scan_signals
    ' _ "$FM_ROOT_OVERRIDE" > "$FM_ARCHIVE_TEST_CASE/publish-signals" || exit 1
    ;;
esac
exec "/bin/${0##*/}" "$@"
SH
    chmod +x "$case_dir/fakebin/$command"
  done
}

test_status_archive_failed_publish_preserves_presentation() {
  local case_dir rc
  case_dir=$(make_case status-archive-failed-publish)
  prepare_status_archive_presentation "$case_dir"
  cp "$case_dir/state/.status-presentation-cursor" "$case_dir/cursor.before"
  cp "$case_dir/state/.seen-task-x1_status" "$case_dir/seen.before"
  install_status_archive_publish_probe "$case_dir"
  rc=0
  FM_ARCHIVE_TEST_CASE="$case_dir" FM_ARCHIVE_TEST_MODE=fail \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "failed archive publication"
  assert_present "$case_dir/publish-entered" "fixture never attempted publication"
  cmp -s "$case_dir/cursor.before" "$case_dir/state/.status-presentation-cursor" || fail "failed archive retired presentation cursor"
  cmp -s "$case_dir/seen.before" "$case_dir/state/.seen-task-x1_status" || fail "failed archive cleared seen marker"
  assert_present "$case_dir/state/.task-x1.home-appends" "failed archive cleared home append ledger"
  assert_present "$case_dir/state/task-x1.status" "failed archive lost live history"
  assert_present "$case_dir/state/task-x1.meta" "failed archive removed task metadata"
  FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" FM_DATA_OVERRIDE="$case_dir/data" \
    bash "$ROOT/bin/fm-wake-drain.sh" > "$case_dir/after" 2>> "$case_dir/drain.err" || fail "retry presentation failed"
  assert_no_grep 'archived note' "$case_dir/after" "failed archive re-presented note"
  assert_no_grep 'archived outcome' "$case_dir/after" "failed archive re-presented outcome"
  pass "failed archive publication preserves presentation and watcher bookkeeping"
}

test_status_archive_cursor_failure_retries_without_duplicate() {
  local case_dir rc
  case_dir=$(make_case status-archive-cursor-retry)
  prepare_status_archive_presentation "$case_dir"
  cp "$case_dir/state/task-x1.status" "$case_dir/expected"
  cp "$case_dir/state/.status-presentation-cursor" "$case_dir/cursor.before"
  printf 'broken\tidentity\tnot-an-offset\t0\n' >> "$case_dir/state/.status-presentation-cursor"
  cp "$case_dir/state/.status-presentation-cursor" "$case_dir/cursor.malformed"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "malformed presentation cursor"
  assert_present "$case_dir/state/task-x1.status" "cursor failure lost live history"
  cmp -s "$case_dir/cursor.malformed" "$case_dir/state/.status-presentation-cursor" \
    || fail "cursor failure changed presentation rows"
  assert_absent "$case_dir/data/task-x1/status.log" "failed retirement left a duplicate archive"
  assert_present "$case_dir/state/task-x1.meta" "cursor failure removed task metadata"
  cp "$case_dir/cursor.before" "$case_dir/state/.status-presentation-cursor"
  rc=0
  run_teardown "$case_dir" > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "retry after cursor repair"
  cmp -s "$case_dir/expected" "$case_dir/data/task-x1/status.log" || fail "retry archive lost history"
  assert_absent "$case_dir/state/task-x1.status" "successful retry retained live status"
  assert_absent "$case_dir/data/task-x1/status.1.log" "retry wrote a duplicate archive"
  pass "cursor retirement failure removes its archive so retry publishes one history"
}

test_status_archive_publish_and_cold_log_stay_inert() {
  local case_dir rc text
  case_dir=$(make_case status-archive-inert)
  prepare_status_archive_presentation "$case_dir"
  install_status_archive_publish_probe "$case_dir"
  rc=0
  FM_ARCHIVE_TEST_CASE="$case_dir" FM_ARCHIVE_TEST_MODE=scan \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "archive publication: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/publish-entered" "fixture never attempted publication"
  [ ! -s "$case_dir/publish-signals" ] || fail "archival caused a spurious watcher wake"
  assert_present "$case_dir/data/task-x1/status.log" "archive absent"
  for text in task-x1.status .task-x1.home-appends .seen-task-x1_status .hb-surfaced-task-x1 .task-x1.open-decisions-cursor; do
    assert_absent "$case_dir/state/$text" "retirement left live bookkeeping"
  done
  assert_no_grep 'task-x1' "$case_dir/state/.status-presentation-cursor" "retirement left presentation cursor"
  printf 'blocked: archive must stay cold\n' >> "$case_dir/data/task-x1/status.log"
  FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" FM_DATA_OVERRIDE="$case_dir/data" \
    bash "$ROOT/bin/fm-wake-drain.sh" > "$case_dir/after" 2>> "$case_dir/drain.err" || fail "post-retirement presentation failed"
  for text in task-x1 'archive must stay cold' 'archived note'; do
    assert_no_grep "$text" "$case_dir/after" "archive re-presented"
  done
  FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" bash -c '
    . "$1/bin/fm-watch.sh"
    scan_signals
    status_presentation_snapshot "$STATE"
  ' _ "$ROOT" > "$case_dir/snapshot" || fail "cold archive snapshot failed"
  [ ! -s "$case_dir/snapshot" ] || fail "watcher or snapshot consumed archive"
  pass "archive publication and cold logs never re-wake or re-present"
}

test_status_archive_pruning_failure_warns_and_completes() {
  local case_dir rc operation
  for operation in rm find; do
    case_dir=$(make_case "status-archive-prune-failure-$operation")
    write_meta "$case_dir" local-only ship
    touch "$case_dir/config/status-archive"
    printf 'done: current history\n' > "$case_dir/state/task-x1.status"
    mkdir -p "$case_dir/data/unrelated-old"
    printf 'expired\n' > "$case_dir/data/unrelated-old/status.log"
    touch -t 200001010000 "$case_dir/data/unrelated-old/status.log"
    cat > "$case_dir/fakebin/$operation" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */unrelated-old|*/unrelated-old/status.log) exit 1 ;; esac
done
exec "${FM_ARCHIVE_TEST_COMMAND:?}" "$@"
SH
    chmod +x "$case_dir/fakebin/$operation"
    rc=0
    FM_ARCHIVE_TEST_COMMAND="$(command -v "$operation")" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "unrelated archive $operation failure aborted teardown"
    grep -E 'warning:.*unrelated-old' "$case_dir/stderr" >/dev/null || fail "pruning failure did not name its path"
    assert_grep 'current history' "$case_dir/data/task-x1/status.log" "pruning failure lost current archive"
    assert_absent "$case_dir/state/task-x1.meta" "pruning failure retained current metadata"
    assert_present "$case_dir/data/unrelated-old/status.log" "failure fixture did not preserve expired archive"
  done
  pass "retention failures warn without aborting unrelated teardown"
}

test_status_archive_missing_status_noop() {
  local case_dir rc
  case_dir=$(make_case status-archive-missing-status)
  write_meta "$case_dir" local-only ship
  touch "$case_dir/config/status-archive"
  mkdir -p "$case_dir/state/.status-presentation-lock"
  printf '%s\n' "$$" > "$case_dir/state/.status-presentation-lock/pid"
  printf 'neighbor\tidentity\t0\t0\n' > "$case_dir/state/.status-presentation-cursor"
  cp "$case_dir/state/.status-presentation-cursor" "$case_dir/cursor.before"
  # A regression must fail within a bound, not wait forever on our live lock.
  . "$ROOT/bin/fm-timeout-lib.sh"
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    fm_run_timed 20 "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "local missing-status retirement"
  cmp -s "$case_dir/cursor.before" "$case_dir/state/.status-presentation-cursor" || fail "missing-status no-op rewrote neighboring cursor"
  assert_present "$case_dir/state/.status-presentation-lock" "missing-status no-op contended with presentation lock"
  assert_absent "$case_dir/data/task-x1" "missing-status no-op created empty archive"
  pass "local missing-status retirement stays lock-free without creating an archive"
}

test_status_archive_nested_secondmate_children() {
  local case_dir home nested_home rc unsafe
  for unsafe in none children; do
    case_dir=$(make_case "status-archive-nested-$unsafe")
    write_meta "$case_dir" local-only secondmate
    home="$case_dir/secondmate-home"
    nested_home="$home/nested-home"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
      "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
    printf 'task-x1\n' > "$home/.fm-secondmate-home"
    printf 'nested-sm\n' > "$nested_home/.fm-secondmate-home"
    printf 'home=%s\n' "$home" >> "$case_dir/state/task-x1.meta"
    fm_write_meta "$home/state/nested-sm.meta" "window=firstmate:fm-nested-sm" \
      "kind=secondmate" "mode=local-only" "home=$nested_home" "project=$case_dir/project" "worktree=$case_dir/wt"
    fm_write_meta "$nested_home/state/grandchild.meta" "window=firstmate:fm-grandchild" \
      "kind=scout" "mode=local-only" "project=$case_dir/project" "worktree=$case_dir/wt"
    touch "$case_dir/config/status-archive"
    printf 'done: parent history\n' > "$case_dir/state/task-x1.status"
    printf 'done: child history\n' > "$home/state/nested-sm.status"
    printf 'done: grandchild history\n' > "$nested_home/state/grandchild.status"
    printf 'marker\n' > "$case_dir/state/.paused-overdue-task-x1"
    printf 'marker\n' > "$home/state/.paused-overdue-nested-sm"
    printf 'marker\n' > "$nested_home/state/.paused-overdue-grandchild"
    if [ "$unsafe" = children ]; then
      mkdir -p "$case_dir/data/task-x1" "$case_dir/outside"
      ln -s "$case_dir/outside" "$case_dir/data/task-x1/children"
    fi
    rc=0
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$unsafe" = children ]; then
      expect_code 1 "$rc" "symlinked child archive directory"
      assert_present "$nested_home/state/grandchild.status" "unsafe child archive lost history"
      assert_absent "$case_dir/outside/nested-sm" "child archive escaped through symlink"
    else
      expect_code 0 "$rc" "nested secondmate status archive: $(cat "$case_dir/stderr")"
      assert_grep 'parent history' "$case_dir/data/task-x1/status.log" "parent history missing"
      assert_grep 'child history' "$case_dir/data/task-x1/children/nested-sm/status.log" "child history missing"
      assert_grep 'grandchild history' "$case_dir/data/task-x1/children/nested-sm/children/grandchild/status.log" "grandchild history missing"
      assert_absent "$case_dir/state/.paused-overdue-task-x1" "parent overdue marker survived teardown"
      assert_absent "$home/state/.paused-overdue-nested-sm" "child overdue marker survived teardown"
      assert_absent "$nested_home/state/.paused-overdue-grandchild" "grandchild overdue marker survived teardown"
      assert_absent "$home" "forced retirement retained secondmate home"
    fi
  done
  pass "forced secondmate retirement preserves two descendant levels and refuses linked child directories"
}

# A fake lsof marks the first reaper scan and writes the worker's last change
# after the initial landed-work proof. No real endpoint or pool is touched.
test_work_written_at_reap_boundary_is_preserved() {
  local backend change case_dir rc before kind replay_rc failed=0
  for backend in orca tmux; do
    for change in reap-refusal tracked untracked commit clean force scout; do
      (
      case_dir=$(make_case "post-reap-$backend-$change")
      kind=ship
      [ "$change" != scout ] || kind=scout
      write_meta "$case_dir" no-mistakes "$kind"
      wt_commit_file "$case_dir" worker.txt baseline
      add_fork_with_pushed_branch "$case_dir"
      before=$(git -C "$case_dir/wt" rev-parse HEAD)
      seed_backlog_in_flight "$case_dir" "$kind"
      mkdir -p "$case_dir/data/task-x1" "$case_dir/state/task-x1.inbox"
      printf 'report\n' > "$case_dir/data/task-x1/report.md"
      printf 'working: retained history\n' > "$case_dir/state/task-x1.status"
      printf 'retained steer\n' > "$case_dir/state/task-x1.inbox/001.msg"
      printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$case_dir/state/task-x1.meta"
      if [ "$backend" = orca ]; then
        sed 's/^window=.*/window=fm-task-x1/' "$case_dir/state/task-x1.meta" > "$case_dir/meta-new"
        mv "$case_dir/meta-new" "$case_dir/state/task-x1.meta"
        printf 'backend=orca\nterminal=term-test\norca_worktree_id=wt-test::/orca/wt-test\n' >> "$case_dir/state/task-x1.meta"
      fi
      cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$FM_REAP_CASE/reap-boundary" ]; then
  : > "$FM_REAP_CASE/reap-boundary"
  case "$FM_REAP_CHANGE" in
    reap-refusal|tracked|force|scout) printf 'late edit\n' > "$FM_REAP_CASE/wt/worker.txt" ;;
    untracked) printf 'late file\n' > "$FM_REAP_CASE/wt/late.txt" ;;
    commit)
      printf 'late commit\n' > "$FM_REAP_CASE/wt/worker.txt"
      "$REAL_GIT_FOR_TEST" -C "$FM_REAP_CASE/wt" add worker.txt
      "$REAL_GIT_FOR_TEST" -C "$FM_REAP_CASE/wt" commit -qm 'late worker commit' || exit 2
      ;;
  esac
fi
[ "$FM_REAP_CHANGE" != reap-refusal ] || exit 1
exit 0
SH
      cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'return\n' >> "$FM_REAP_CASE/removal.log"
exit 0
SH
      cat > "$case_dir/fakebin/orca" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'worktree show')
    printf '{"ok":true,"result":{"worktree":{"id":"wt-test::/orca/wt-test","path":"%s"}}}\n' "$FM_REAP_CASE/wt" ;;
  'worktree rm')
    printf 'remove\n' >> "$FM_REAP_CASE/removal.log"
    printf '{"ok":true,"result":{}}\n' ;;
  'terminal close') printf '{"ok":true,"result":{}}\n' ;;
  *) printf '{"ok":true,"result":{}}\n' ;;
esac
SH
      chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse" "$case_dir/fakebin/orca"
      rc=0
      if [ "$change" = force ]; then
        FM_HOME="$case_dir" FM_REAP_CASE="$case_dir" FM_REAP_CHANGE="$change" \
          run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      else
        FM_HOME="$case_dir" FM_REAP_CASE="$case_dir" FM_REAP_CHANGE="$change" \
          run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      fi
      assert_present "$case_dir/reap-boundary" "$backend/$change: did not reach the reaper: $(cat "$case_dir/stderr")"
      case "$change" in
        reap-refusal|tracked|untracked|commit)
          expect_code 1 "$rc" "$backend/$change: late work must refuse teardown"
          assert_grep REFUSED "$case_dir/stderr" "$backend/$change: refusal missing"
          if [ "$change" = reap-refusal ]; then
            assert_grep 'lsof failed' "$case_dir/stderr" "$backend/$change: reaper refusal missing"
          fi
          assert_absent "$case_dir/removal.log" "$backend/$change: returned or removed late work"
          [ "$(git -C "$case_dir/wt" symbolic-ref --short HEAD)" = fm/task-x1 ] \
            || fail "$backend/$change: task branch was detached or deleted"
          if [ "$change" = commit ]; then
            [ "$(git -C "$case_dir/wt" rev-parse HEAD)" != "$before" ] \
              || fail "$backend/$change: late commit missing"
            assert_grep 'late commit' "$case_dir/wt/worker.txt" "$backend/$change: late bytes missing"
          elif [ "$change" = tracked ] || [ "$change" = reap-refusal ]; then
            assert_grep 'late edit' "$case_dir/wt/worker.txt" "$backend/$change: late edit missing"
          else
            assert_grep 'late file' "$case_dir/wt/late.txt" "$backend/$change: late file missing"
          fi
          # Startup replay must not consume the retained task through a close
          # marker prepared before the second proof refused.
          replay_rc=0
          FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" bash -c '
            . "$1/bin/fm-tasks-axi-lib.sh"
            . "$1/bin/fm-backlog-transition-lib.sh"
            fm_backlog_close_marker_replay "$2/state" "$2/state/task-x1.backlog-close" "$2/data" || {
              printf "replay failed: %s\n" "$FM_BACKLOG_TRANSITION_ERROR" >&2
              exit 1
            }
          ' _ "$ROOT" "$case_dir" || replay_rc=$?
          if [ "$change" = reap-refusal ]; then
            printf '%s: teardown_exit=%s replay_exit=%s metadata_after_replay=%s backlog_after_replay=%s\n' \
              "$backend/$change" "$rc" "$replay_rc" \
              "$(if [ -f "$case_dir/state/task-x1.meta" ]; then printf retained; else printf missing; fi)" \
              "$(backlog_row_state "$case_dir")"
          fi
          expect_code 0 "$replay_rc" "$backend/$change: replay failed"
          assert_present "$case_dir/state/task-x1.meta" "$backend/$change: metadata lost"
          assert_present "$case_dir/state/task-x1.status" "$backend/$change: status lost"
          assert_present "$case_dir/state/task-x1.inbox/001.msg" "$backend/$change: inbox lost"
          [ "$(backlog_row_state "$case_dir")" = in_flight ] \
            || fail "$backend/$change: backlog closed despite retained work"
          ;;
        *)
          expect_code 0 "$rc" "$backend/$change: authorized teardown should complete: $(cat "$case_dir/stderr")"
          assert_present "$case_dir/removal.log" "$backend/$change: removal missing"
          assert_absent "$case_dir/state/task-x1.meta" "$backend/$change: cleanup incomplete"
          ;;
      esac
      ) || failed=$((failed + 1))
    done
  done
  [ "$failed" -eq 0 ] || fail "$failed post-reap boundary cases failed"
  pass "post-reap proof retains late work and retry records on ordinary and Orca paths, preserving clean/force/scout behavior"
}
