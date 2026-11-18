# shellcheck shell=bash
# Test cases for fm-crew-state, split out of tests/fm-crew-state.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-crew-state.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner



# Head-binding regression (model-routing-benchmark-hardening incident): the
# active run's head advanced beyond the submitted head through a pipeline fix
# round whose commit object never reached the task copy. The reader must
# attribute the active run through the pipeline's own ledger - its newest row
# for the branch is active with a locally unverifiable head, and the row
# immediately before it ended at exactly this worktree's head - instead of
# rejecting the active row and letting the older failed row answer.
test_active_fix_round_unfetched_pipeline_head_reports_current() {
  reset_fakes
  local d h1 h2 out
  d=$(new_case unfetched-fix-head)
  make_repo_on_branch "$d/wt" fm/feat-unfetched
  h1=$(git -C "$d/wt" rev-parse HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  [ "$h1" != "$h2" ] || fail "fix head did not advance past the submitted head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unfetched.meta" "window=fm:fm-unfetched" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-unfetched)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other aaaaaaa  2026-07-30 22:10
  running    fm/feat-unfetched $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-unfetched $(git -C "$d/wt" rev-parse --short=7 HEAD)  2026-07-29 20:00
EOF
)"
  out=$(run_crew_state "$d" unfetched)
  assert_contains "$out" "source: run-step" "active run with an unfetched pipeline head still attributes"
  assert_contains "$out" "state: working" "active fix round reads working, not the older failed row"
  assert_contains "$out" "validating (fixing)" "full run detail survives the unfetched pipeline head"
  assert_not_contains "$out" "state: failed" "the older failed row must never answer for the active run"
  pass "active fix round with an unfetched pipeline head reads working"
}

# A live run on the task's branch is authoritative regardless of head, so an
# active row with an unverifiable head binds even when the ledger cannot anchor
# it to this worktree's head: the older row and the historical status-log
# `failed:` event never answer for the live run.
test_unanchored_unfetched_active_row_still_binds() {
  reset_fakes
  local d h2 out
  d=$(new_case unfetched-no-anchor)
  make_repo_on_branch "$d/wt" fm/feat-noanchor
  # A second commit gives the ledger a resolvable anchor row (HEAD~1) that is
  # NOT this worktree's head - the exact-equality anchor must fail on it.
  git -C "$d/wt" commit -q --allow-empty -m 'second local commit'
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/noanchor.meta" "window=fm:fm-noanchor" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'failed: earlier stage run\n' > "$d/state/noanchor.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-noanchor)"
  # The row before the active one is an OLDER commit, not this worktree's
  # head: the ledger anchor proves nothing, and the live run binds anyway.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other aaaaaaa  2026-07-30 22:10
  running    fm/feat-noanchor $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-noanchor $(git -C "$d/wt" rev-parse --short=7 HEAD~1)  2026-07-29 20:00
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" noanchor
  out=$(run_crew_state "$d" noanchor)
  assert_contains "$out" "source: run-step" "an unanchored active row on the branch still binds"
  assert_contains "$out" "state: working" "the live run reads working"
  assert_not_contains "$out" "state: failed" "neither the older failed row nor the stale status-log event answers"
  pass "unanchored unverifiable active row is attributed because it is live"
}

# Negative control: a TERMINAL row whose commit object is gone from the task
# copy is history even when it is the branch's newest row - an ancient or
# rewritten run whose commit was pruned must never read as current state.
test_unresolved_terminal_row_is_history_not_current() {
  reset_fakes
  local d h_old out
  d=$(new_case unresolved-terminal)
  make_repo_on_branch "$d/wt" fm/feat-hist
  # Mint the historical run head outside the task copy, then orphan-rewrite
  # the worktree tip, so the run head can never resolve locally.
  h_old=$(mint_unfetched_fix_head "$d/wt")
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/feat-hist
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/hist.meta" "window=fm:fm-hist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 in progress\n' > "$d/state/hist.status"
  FM_FAKE_RUN_HEAD="$h_old"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-hist)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-hist $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-01 20:00
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" hist
  out=$(run_crew_state "$d" hist)
  assert_not_contains "$out" "source: run-step" "an unresolvable terminal row is history, not current state"
  assert_contains "$out" "source: status-log" "historical fallback answers after an unresolvable terminal row"
  assert_contains "$out" "state: working" "the rewritten worktree's own log stays current"
  pass "unresolvable terminal row never reads as current"
}

# The same continuation recognition must work when bare `axi status` answers
# with ANOTHER branch's run: this branch's own active run is then visible only
# in the ledger, with coarse (status-word) detail.
test_runs_list_continuation_found_when_axi_answers_other_branch() {
  reset_fakes
  local d h1 h2 out
  d=$(new_case unfetched-coarse)
  make_repo_on_branch "$d/wt" fm/feat-coarsefix
  h1=$(git -C "$d/wt" rev-parse HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarsefix.meta" "window=fm:fm-coarsefix" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-30 22:10
  running    fm/feat-coarsefix $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-coarsefix $(git -C "$d/wt" rev-parse --short=7 HEAD)  2026-07-29 20:00
EOF
)"
  out=$(run_crew_state "$d" coarsefix)
  assert_contains "$out" "source: run-step" "ledger continuation attributes via the runs list too"
  assert_contains "$out" "state: working" "coarse continuation reads working"
  assert_contains "$out" "validating (background run)" "coarse resolution keeps coarse detail, not the other branch's run"
  pass "runs-list continuation attribution works when axi answers another branch"
}

# The AXI overview supplies run ids in creation order; the plain runs listing
# cannot identify a replacement or carry its review gate.
make_competing_runs_case() {  # <name> <new-status> <old-status>
  local d=$TMP_ROOT/$1 short
  reset_fakes
  mkdir -p "$d/state"
  make_repo_on_branch "$d/wt" fm/competing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/competing.meta" "window=fm:fm-competing" "worktree=$d/wt" "kind=ship"
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  \"01NEW\",fm/competing,$2,$short,\"\"
  \"01OLD\",fm/competing,$3,$short,\"\""
  FM_FAKE_RUNS_LIST="  $2 fm/competing $short 2026-09-14 12:01
  $3 fm/competing $short 2026-09-14 12:00"
}

make_capped_runs_case() {
  make_competing_runs_case "$1" "$2" "$3"
  local d=$TMP_ROOT/$1
  NM_HOME="$d/nm"
  mkdir -p "$NM_HOME"
  FM_FAKE_AXI_HOME=$(python3 - "$NM_HOME/state.sqlite" "$d/wt" "$2" "$3" "$FM_FAKE_RUN_HEAD" "${4:-visible}" <<'PY'
import csv
import json
import sqlite3
import sys

database, worktree, newest, oldest, head, placement = sys.argv[1:]
with sqlite3.connect(database) as db:
    db.executescript("""
        CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
        CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                           status TEXT NOT NULL, head_sha TEXT NOT NULL, created_at INTEGER NOT NULL);
    """)
    db.executemany("INSERT INTO repos VALUES (?, ?)", [("repo", worktree), ("other-repo", worktree + "-other")])
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)", [
        ("01NEW", "repo", "fm/competing", newest, head, 12 if placement == "visible" else 1),
        ("01OLD", "repo", "fm/competing", oldest, head, 0),
        ("01FOREIGN", "other-repo", "fm/competing", "running", head, 20),
    ] + [("01OTHER%02d" % i, "repo", "fm/other-%d" % i, "running", head, i + 2)
         for i in range(9 if placement == "visible" else 10)])
    rows = db.execute("SELECT id, branch, status, head_sha FROM runs WHERE repo_id = 'repo' "
                      "ORDER BY created_at DESC, id DESC").fetchall()
print("repo: " + json.dumps(worktree))
print("count: 10 of %d total" % len(rows))
print("runs[10]{id,branch,status,head,pr}:")
for row in rows[:10]:
    sys.stdout.write("  ")
    csv.writer(sys.stdout, lineterminator="\n").writerow([*row, ""])
PY
  ) || fail 'could not create the persisted run inventory fixture'
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
}

test_capped_competing_live_runs_report_both_ids() {
  make_capped_runs_case capped-competing running running
  local d=$TMP_ROOT/capped-competing out
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'a capped overview must not hide the competing live run'
  assert_contains "$out" '01NEW' 'capped ambiguity names the visible run'
  assert_contains "$out" '01OLD' 'capped ambiguity names the run beyond nine other branches'
  assert_not_contains "$out" '01FOREIGN' 'another repository cannot claim this branch'
  pass 'capped overview retains both competing same-branch run ids'
}

test_capped_overview_without_branch_rows_reports_both_ids() {
  make_capped_runs_case capped-absent running pending hidden
  local d=$TMP_ROOT/capped-absent out
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'no visible branch rows cannot establish absence'
  assert_contains "$out" '01NEW' 'the newer hidden run is identified'
  assert_contains "$out" '01OLD' 'the older hidden pending run is identified'
  pass 'same-branch identity survives both runs falling outside the overview'
}

# A branch with zero rows anywhere in a capped overview must read as
# truthfully absent, not as an unreadable table: the rebuilt zero-row
# inventory re-parses as `runs[0]`.
test_capped_overview_with_no_branch_runs_reports_absent() {
  reset_fakes
  local d; d=$TMP_ROOT/capped-no-branch-runs
  mkdir -p "$d/state"
  make_repo_on_branch "$d/wt" fm/orphan-branch
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/orphan.meta" "window=fm:fm-orphan" "worktree=$d/wt" "kind=ship" "harness=claude"
  NM_HOME="$d/nm"
  mkdir -p "$NM_HOME"
  local head; head=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  FM_FAKE_AXI_HOME=$(python3 - "$NM_HOME/state.sqlite" "$d/wt" "$head" <<'PY'
import json
import sqlite3
import sys

database, worktree, head = sys.argv[1:]
with sqlite3.connect(database) as db:
    db.executescript("""
        CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
        CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                           status TEXT NOT NULL, head_sha TEXT NOT NULL, created_at INTEGER NOT NULL);
    """)
    db.execute("INSERT INTO repos VALUES ('repo', ?)", (worktree,))
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)",
                    [("01OTHER%02d" % i, "repo", "fm/other-%d" % i, "running", head, i)
                     for i in range(11)])
print("repo: " + json.dumps(worktree))
print("count: 10 of 11 total")
print("runs[10]{id,branch,status,head,pr}:")
for i in range(10):
    print('  "01OTHER%02d",fm/other-%d,running,%s,""' % (i, i, head))
PY
)
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" orphan)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" orphan busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" orphan)
  assert_not_contains "$out" "state: unknown" 'a zero-row branch in a capped overview is absent, not unreadable'
  assert_not_contains "$out" "unreadable" 'a zero-row branch must not read as an unreadable table'
  assert_contains "$out" "state: working" 'absence of a run falls through to the pane/busy verdict'
  assert_contains "$out" "source: pane" 'the working verdict still comes from the pane source'
  pass 'a capped overview with zero same-branch rows reports absent, not unreadable'
}

# The same capped shape, but reached through the code path that actually
# consumes the same-branch selection: fm-crew-state only consults the overview
# once `axi status` answers with a run, so a branch of its own with no run at
# all is only reported while SOME run exists elsewhere. Pre-fix this read
# `unknown - complete same-branch run inventory unreadable`, which is the
# healthy-home-reports-itself-untrustworthy symptom.
test_no_branch_run_beside_a_live_run_elsewhere_reads_absent() {
  reset_fakes
  local d; d=$TMP_ROOT/capped-live-elsewhere
  mkdir -p "$d/state"
  make_repo_on_branch "$d/wt" fm/orphan-branch
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/orphan.meta" "window=fm:fm-orphan" "worktree=$d/wt" "kind=ship" "harness=claude"
  NM_HOME="$d/nm"
  mkdir -p "$NM_HOME"
  local head; head=$(git -C "$d/wt" rev-parse HEAD)
  FM_FAKE_AXI_HOME=$(python3 - "$NM_HOME/state.sqlite" "$d/wt" "$head" <<'PY'
import json
import sqlite3
import sys

database, worktree, head = sys.argv[1:]
with sqlite3.connect(database) as db:
    db.executescript("""
        CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
        CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                           status TEXT NOT NULL, head_sha TEXT NOT NULL, created_at INTEGER NOT NULL);
    """)
    db.execute("INSERT INTO repos VALUES ('repo', ?)", (worktree,))
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)",
                   [("01OTHER%02d" % i, "repo", "fm/other-%d" % i, "running", head, i)
                    for i in range(11)])
print("repo: " + json.dumps(worktree))
print("count: 10 of 11 total")
print("runs[10]{id,branch,status,head,pr}:")
for i in range(10):
    print('  "01OTHER%02d",fm/other-%d,running,%s,""' % (i, i, head))
PY
)
  FM_FAKE_AXI_STATUS=$(run_running fm/other-0)
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" orphan)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" orphan busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" orphan)
  assert_not_contains "$out" "unreadable" 'a branch with no run of its own is not an unreadable runs table'
  assert_not_contains "$out" "state: unknown" 'a healthy home does not report itself untrustworthy'
  assert_contains "$out" "state: working" 'absence of a same-branch run falls through to the pane verdict'
  assert_contains "$out" "source: pane" 'the working verdict still comes from the pane source'
  pass 'no run for this branch beside a live run elsewhere reads absent, not unreadable'
}

# The capped-overview sqlite reader runs inside the same per-read budget as
# every other no-mistakes state read, so a contended database cannot stall a
# crew poll: a reader that never returns must be killed and fall through to the
# reader-unavailable verdict.
test_capped_inventory_reader_is_time_bounded() {
  make_capped_runs_case capped-slow-reader running pending hidden
  local d=$TMP_ROOT/capped-slow-reader out started elapsed
  cat > "$d/fakebin/python3" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$d/fakebin/python3"
  FM_CREW_STATE_NM_TIMEOUT=1
  export FM_CREW_STATE_NM_TIMEOUT
  started=$SECONDS
  out=$(run_crew_state "$d" competing)
  elapsed=$((SECONDS - started))
  unset FM_CREW_STATE_NM_TIMEOUT
  [ "$elapsed" -lt 10 ] || fail "the capped inventory reader ran unbounded for ${elapsed}s"
  assert_contains "$out" 'state: unknown' 'an unreachable inventory reader cannot establish a verdict'
  assert_contains "$out" 'reader unavailable' 'a killed reader reports the same unavailable reader path'
  pass 'the capped inventory reader is bounded by the crew read budget'
}

# Repo identity is the overview's own `repo:` line matched exactly against the
# recorded `working_path`; a spelling the inventory does not record is not
# guessed at, and reads as an unreadable inventory that still names every
# candidate run id.
test_capped_inventory_requires_exact_repo_path() {
  make_capped_runs_case capped-noncanonical running pending hidden
  local d=$TMP_ROOT/capped-noncanonical out
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed "s|^repo: .*|repo: \"$d/wt/./\"|")
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'an unmatched repo spelling cannot establish a verdict'
  assert_contains "$out" 'unreadable' 'an unmatched repo lookup reports the inventory unreadable'
  assert_contains "$out" '01NEW' 'an unmatched repo lookup still names the candidate run'
  assert_not_contains "$out" 'absent' 'an unmatched repo lookup never reads as a branch without runs'
  pass 'a repo spelling the inventory does not record reads unreadable'
}

# The 2026-09-22 PR #5317 shape on no-mistakes v1.79.0. A task copy is a linked
# git worktree of its home clone, and the CLI registers the repository once, by
# the clone's path, which the overview reports as `repo:`. Past ten runs the
# overview is capped, so selection goes through the inventory reader, which must
# key on that `repo:` line: keyed on the task worktree path it matched no row and
# every read reported the inventory unreadable. The run is in ci merge
# monitoring with every check green, and main advanced while it waited for the
# merge, so its ci log ends in re-arm lines. It must read as a green PR held for
# the merge decision, naming the PR, rather than unknown or still validating.
test_linked_worktree_green_merge_monitoring_reads_held_for_merge() {
  reset_fakes
  local d out overview
  d=$(new_case linked-worktree-green)
  mkdir -p "$d/clone"
  git -C "$d/clone" init -q
  git -C "$d/clone" commit -q --allow-empty -m init
  git -C "$d/clone" worktree add -q -b fm/feat-green "$d/wt"
  FM_FAKE_RUN_HEAD=$(git -C "$d/wt" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-green.meta" "window=fm:fm-feat-green" "worktree=$d/wt" "kind=ship"
  NM_HOME="$d/nm"
  mkdir -p "$NM_HOME"
  overview=$(python3 - "$NM_HOME/state.sqlite" "$d/clone" "$FM_FAKE_RUN_HEAD" <<'PY'
import json
import sqlite3
import sys

database, clone, head = sys.argv[1:]
pr = "https://github.com/o/r/pull/2"
with sqlite3.connect(database) as db:
    db.executescript("""
        CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
        CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                           status TEXT NOT NULL, head_sha TEXT NOT NULL, created_at INTEGER NOT NULL);
    """)
    db.execute("INSERT INTO repos VALUES ('repo', ?)", (clone,))
    db.execute("INSERT INTO runs VALUES ('01GREEN', 'repo', 'fm/feat-green', 'running', ?, 100)", (head,))
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)",
                   [("01DONE%02d" % i, "repo", "fm/done-%d" % i, "completed", head, i)
                    for i in range(11)])
print("repo: " + json.dumps(clone))
print("current_branch: fm/feat-green")
print("daemon: running")
print("count: 10 of 12 total")
print("runs[10]{id,branch,status,head,pr}:")
print('  "01GREEN",fm/feat-green,running,%s,"%s"' % (head[:8], pr))
for i in reversed(range(2, 11)):
    print('  "01DONE%02d",fm/done-%d,completed,%s,""' % (i, i, head[:8]))
PY
) || fail 'could not create the linked-worktree run inventory fixture'
  # Guard the divergence this case exists for, so it cannot go vacuous.
  [ "$(git -C "$d/wt" rev-parse --show-toplevel)" != "$(git -C "$d/clone" rev-parse --show-toplevel)" ] \
    || fail 'the fixture task copy must not be the registered clone'
  assert_contains "$overview" 'count: 10 of 12 total' 'the fixture overview must be capped'
  FM_FAKE_AXI_HOME=$overview
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-green | sed 's/01RUN/01GREEN/')"
  FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
monitoring CI for PR #2 (timeout: 4h0m0s)...
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
base branch advanced (f9f74a1d91cc..6f0f139962ea), re-arming CI monitor timeout
base branch advanced (6f0f139962ea..c5131a33a1b2), re-arming CI monitor timeout
EOF
)
  out=$(run_crew_state "$d" feat-green)
  assert_not_contains "$out" 'unreadable' 'a linked worktree reads its run through the repo line'
  assert_not_contains "$out" 'state: unknown' 'a green PR in merge monitoring is never unknown'
  assert_contains "$out" 'state: done' 'a green PR in merge monitoring reads done'
  assert_contains "$out" 'source: run-step' 'the green reading comes from the selected run'
  assert_contains "$out" 'checks green: PR ready for review' 'the reading is held for the merge decision'
  assert_contains "$out" 'https://github.com/o/r/pull/2' 'the reading names the PR to ask about'
  pass 'a linked worktree green PR in merge monitoring reads held for merge'
}

test_capped_replacement_keeps_gate_and_inventory_unchanged() {
  make_capped_runs_case "capped reviewer's replacement" running cancelled
  local d="$TMP_ROOT/capped reviewer's replacement" out before after
  before=$(git hash-object "$NM_HOME/state.sqlite")
  FM_FAKE_AXI_STATUS="$(run_failed fm/competing | sed 's/01RUN/01OLD/; s/failed/cancelled/')"
  out=$(run_crew_state "$d" competing)
  after=$(git hash-object "$NM_HOME/state.sqlite")
  assert_contains "$out" 'state: parked' 'the live replacement keeps its review gate beyond the history cap'
  assert_contains "$out" 'parked at review: 2 finding(s)' 'full replacement gate details survive inventory selection'
  assert_contains "$out" '01NEW' 'the replacement run is identified'
  assert_not_contains "$out" '01FOREIGN' 'same-branch runs in another repository do not make authority ambiguous'
  [ "$after" = "$before" ] || fail 'current-state reporting modified the persisted inventory'
  NM_HOME=../nm
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: parked' 'relative NM_HOME resolves from the queried worktree'
  pass 'complete inventory preserves the replacement gate without writes'
}

test_capped_inventory_failures_report_unknown() {
  local mode rc=0 overview
  for mode in missing corrupt schema repo count norepo; do
    (
      make_capped_runs_case "capped-unreadable-$mode" running running
      d=$TMP_ROOT/capped-unreadable-$mode
      overview=$FM_FAKE_AXI_HOME
      case "$mode" in
        missing) rm "$NM_HOME/state.sqlite" ;;
        corrupt) printf 'invalid database\n' > "$NM_HOME/state.sqlite" ;;
        schema|repo)
          python3 - "$NM_HOME/state.sqlite" "$mode" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    if sys.argv[2] == "schema":
        db.execute("DROP TABLE runs")
    else:
        db.execute("DELETE FROM repos WHERE id = 'repo'")
PY
          ;;
        count) overview=$(printf '%s\n' "$overview" | sed '/^count:/d') ;;
        norepo) overview=$(printf '%s\n' "$overview" | sed '/^repo:/d') ;;
      esac
      out=$(FM_FAKE_AXI_HOME="$overview" run_crew_state "$d" competing)
      assert_contains "$out" 'state: unknown' "$mode cannot fall back to a confident verdict from capped rows"
      assert_contains "$out" '01NEW' "$mode preserves the available run identity"
      if [ "$mode" = missing ]; then
        [ ! -e "$NM_HOME/state.sqlite" ] || fail 'the read-only lookup created a missing inventory'
      fi
      pass "$mode complete-inventory failure reports unknown"
    ) || rc=1
  done
  [ "$rc" = 0 ] || fail 'capped inventory failures'
}

make_no_python_toolbin() {
  local tb=$1/no-python tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl awk tr date stat ps uname readlink sleep; do
    real=$(command -v "$tool") || fail "missing fixture tool: $tool"
    ln -s "$real" "$tb/$tool"
  done
  PATH="$tb" bash -c '! command -v python3 && ! command -v sqlite3' || fail 'fixture exposes optional inventory readers'
  printf '%s\n' "$tb"
}

test_complete_inventory_ignores_unrelated_semantics() {
  local branch encoded d toolbin out i=0
  for branch in 'fix/c++' 'fix/a,b' 'fix/a"b'; do
    i=$((i + 1))
    make_competing_runs_case "unrelated-semantics-$i" running cancelled
    d=$TMP_ROOT/unrelated-semantics-$i
    git -C "$d/wt" check-ref-format --branch "$branch" >/dev/null || fail 'fixture branch must be valid Git syntax'
    encoded=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$branch")
    FM_FAKE_AXI_HOME="$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/2 of 2/3 of 3/; s/runs\[2\]/runs[3]/')
  01OTHER,$encoded,running,$FM_FAKE_RUN_HEAD,\"\""
    FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
    FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
    toolbin=$(make_no_python_toolbin "$d")
    out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
    assert_contains "$out" 'state: parked' 'R6 unrelated branch syntax must not suppress the requested gate'
    assert_contains "$out" '01NEW' 'selection retains the requested run identity'
    FM_FAKE_AXI_HOME="$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed '/^  01OTHER,/d')
  foreign.id,$encoded,FUTURE,unresolved,\"\""
    out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
    assert_contains "$out" 'state: parked' 'unrelated id status and head semantics cannot suppress the requested gate'
    assert_not_contains "$out" 'foreign.id' 'unrelated identities are not candidates'
  done
  pass 'R6 complete selection ignores unrelated branch semantics'
}

test_requested_branch_has_no_character_whitelist() {
  local branch encoded d out i=0
  for branch in 'fix/c++' 'fix/a,b'; do
    i=$((i + 1))
    make_competing_runs_case "requested-branch-syntax-$i" running cancelled
    d=$TMP_ROOT/requested-branch-syntax-$i
    git -C "$d/wt" branch -m "$branch"
    encoded=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$branch")
    FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  01NEW,$encoded,running,$FM_FAKE_RUN_HEAD,\"\"
  01OLD,$encoded,cancelled,$FM_FAKE_RUN_HEAD,\"\""
    FM_FAKE_AXI_STATUS="$(run_running "$branch" | sed 's/01RUN/01NEW/')"
    FM_FAKE_AXI_STATUS_RUN="$(run_parked "$branch" | sed 's/01RUN/01NEW/')"
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" 'state: parked' 'R6 requested branch identity must not depend on a character whitelist'
    assert_contains "$out" '01NEW' 'the requested branch keeps its selected run'
  done
  pass 'R6 requested branches use exact identity without a whitelist'
}

test_capped_inventory_ignores_unrelated_semantics() {
  make_capped_runs_case capped-unrelated-semantics running running
  local d=$TMP_ROOT/capped-unrelated-semantics out
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's@01OTHER00,fm/other-0,running,[^,]*,@foreign.id,"fix/a,b",FUTURE,unresolved,@')
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'competing runs remain ambiguous beside unrelated metadata'
  assert_contains "$out" '01NEW' 'capped ambiguity retains the visible id'
  assert_contains "$out" '01OLD' 'R6 unrelated semantics cannot hide an id beyond the history window'
  assert_not_contains "$out" 'foreign.id' 'unrelated runs do not claim this branch'
  pass 'R6 capped inventory ignores unrelated semantics and names both ids'
}

test_capped_requested_semantics_do_not_hide_ids() {
  make_capped_runs_case capped-requested-semantics running running
  local d=$TMP_ROOT/capped-requested-semantics out
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's@01NEW,fm/competing,running,[^,]*,@01NEW,fm/competing,FUTURE,unresolved,@')
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'readable competing identities remain ambiguous'
  assert_contains "$out" '01NEW' 'the visible requested run remains identified'
  assert_contains "$out" '01OLD' 'R6 partial requested-row semantics cannot preempt complete identity lookup'
  pass 'R6 complete identity lookup precedes partial-row semantic rejection'
}

test_capped_requested_branch_with_comma_names_both_ids() {
  make_capped_runs_case capped-comma-branch running running
  local d=$TMP_ROOT/capped-comma-branch out branch=fix/a,b
  git -C "$d/wt" branch -m "$branch"
  python3 - "$NM_HOME/state.sqlite" "$branch" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE runs SET branch = ? WHERE repo_id = 'repo' AND branch = 'fm/competing'", (sys.argv[2],))
PY
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's@fm/competing@"fix/a,b"@g')
  FM_FAKE_AXI_STATUS="$(run_running "$branch" | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_parked "$branch" | sed 's/01RUN/01NEW/')"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'quoted branch fields retain ambiguous authority'
  assert_contains "$out" '01NEW' 'the quoted requested branch retains its visible run'
  assert_contains "$out" '01OLD' 'R6 complete inventory preserves quoted branch identity and both ids'
  pass 'R6 capped inventory preserves quoted requested-branch identity'
}

test_inventory_structure_and_requested_semantics_remain_checked() {
  local mode d out
  for mode in columns count status head; do
    make_competing_runs_case "requested-validation-$mode" running cancelled
    d=$TMP_ROOT/requested-validation-$mode
    FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
    FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
    case "$mode" in
      columns) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed '/01NEW/s/,""$//') ;;
      count) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/2 of 2/1 of 2/') ;;
      status) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/,running,/,FUTURE,/') ;;
      head) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed '/01NEW/s/,[a-f0-9]*,""$/,unresolved,""/') ;;
    esac
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" 'state: unknown' "$mode still prevents a confident selection"
    assert_contains "$out" '01NEW' "$mode preserves the available newer identity"
    assert_contains "$out" '01OLD' "$mode preserves the available older identity"
  done
  pass 'R6 structural completeness and requested-run validation remain enforced'
}

test_complete_inventory_without_python_keeps_gate() {
  make_competing_runs_case no-python-complete running cancelled
  local d=$TMP_ROOT/no-python-complete toolbin out
  toolbin=$(make_no_python_toolbin "$d")
  FM_FAKE_AXI_STATUS="$(run_failed fm/competing | sed 's/01RUN/01OLD/; s/failed/cancelled/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
  out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
  assert_contains "$out" 'state: parked' 'R5 complete inventory keeps its gate without Python'
  assert_contains "$out" 'parked at review: 2 finding(s)' 'optional dependencies do not remove gate detail'
  assert_contains "$out" '01NEW' 'complete inventory retains the selected id without Python'
  pass 'R5 complete inventory without Python keeps the replacement gate'
}

test_complete_ambiguity_without_python_names_both_ids() {
  make_competing_runs_case no-python-ambiguous running pending
  local d=$TMP_ROOT/no-python-ambiguous toolbin out
  toolbin=$(make_no_python_toolbin "$d")
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
  out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
  assert_contains "$out" 'state: unknown' 'complete competing runs remain ambiguous without Python'
  assert_contains "$out" '01NEW' 'R5 complete ambiguity retains the newer id without Python'
  assert_contains "$out" '01OLD' 'complete ambiguity retains the older id without Python'
  pass 'R5 complete ambiguity without Python names both ids'
}

test_capped_without_python_preserves_available_ids() {
  local placement d toolbin out
  for placement in visible hidden; do
    make_capped_runs_case "no-python-capped-$placement" running pending "$placement"
    d=$TMP_ROOT/no-python-capped-$placement
    toolbin=$(make_no_python_toolbin "$d")
    out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
    assert_contains "$out" 'state: unknown' 'unreadable complete inventory must fail closed'
    assert_contains "$out" '01NEW' 'R5 capped lookup retains available ids without Python'
    assert_contains "$out" 'inventory' 'unknown explains that complete inventory could not be read'
    assert_not_contains "$out" '01FOREIGN' 'unreadable inventory does not invent foreign authority'
  done
  pass 'R5 capped lookup without Python preserves available ids'
}

test_capped_without_sqlite_preserves_available_ids() {
  make_capped_runs_case no-sqlite-capped running running
  local d=$TMP_ROOT/no-sqlite-capped out
  mkdir -p "$d/no-sqlite"
  printf 'raise ImportError("sqlite support unavailable")\n' > "$d/no-sqlite/sqlite3.py"
  out=$(PYTHONPATH="$d/no-sqlite" run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'missing SQLite support must fail closed'
  assert_contains "$out" '01NEW' 'R5 capped lookup retains available ids without SQLite support'
  assert_contains "$out" 'inventory' 'missing SQLite support leaves an explicit inventory diagnostic'
  pass 'R5 capped lookup without SQLite support preserves available ids'
}

test_live_to_terminal_inventory_disagreement_is_unknown() {
  make_competing_runs_case live-to-terminal running cancelled
  local d=$TMP_ROOT/live-to-terminal out
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_failed fm/competing | sed 's/01RUN/01NEW/; s/failed/cancelled/')"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'R1 live selection becoming terminal cannot publish a stale failure'
  assert_contains "$out" 'status disagrees with inventory' 'the selection race is identified'
  assert_contains "$out" '01NEW' 'the changing run remains identifiable'
  assert_not_contains "$out" 'state: failed' 'a cancelled stale selection is not a work failure'
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/,running,/,cancelled,/')
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'terminal-to-live disagreement remains rejected'
  pass 'R1 both directions of inventory liveness disagreement read unknown'
}

make_uninitialized_worker_case() {
  local d=$TMP_ROOT/$1 gen
  reset_fakes
  mkdir -p "$d/state"
  make_repo_on_branch "$d/wt" fm/no-gate
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/worker.meta" "window=fm:fm-worker" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=$(cat "$ROOT/tests/captures/no-mistakes-v1.70.1/uninitialized.toon")
  FM_FAKE_AXI_STATUS_ERROR=1
  FM_FAKE_AXI_HOME_ERROR=1
  printf 'working: implementation continues\n' > "$d/state/worker.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" worker)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" worker "$2" --gen "$gen" \
    --source claude-hook --event "${3:-stop}"
}

test_uninitialized_busy_worker_uses_pane() {
  make_uninitialized_worker_case uninitialized-busy busy user-prompt-submit
  local d=$TMP_ROOT/uninitialized-busy out
  out=$(run_crew_state "$d" worker)
  assert_contains "$out" 'state: working' 'R2 an uninitialized gate must preserve a busy worker'
  assert_contains "$out" 'source: pane' 'a busy worker without a gate uses current pane evidence'
  assert_not_contains "$out" 'source: run-step' 'an initialization error is not a run'
  FM_FAKE_AXI_STATUS='error: "database locked"'
  out=$(run_crew_state "$d" worker)
  assert_contains "$out" 'state: unknown' 'other inventory errors must not be mistaken for no gate'
  pass 'R2 uninitialized busy workers retain pane reporting'
}

test_uninitialized_idle_worker_uses_status() {
  make_uninitialized_worker_case uninitialized-idle idle
  local d=$TMP_ROOT/uninitialized-idle out
  out=$(run_crew_state "$d" worker)
  assert_contains "$out" 'state: working' 'R2 an uninitialized gate must preserve current worker status'
  assert_contains "$out" 'source: status-log' 'an idle worker without a gate uses its current status'
  assert_contains "$out" 'implementation continues' 'current worker detail remains available'
  pass 'R2 uninitialized idle workers retain status reporting'
}

make_historical_inventory_case() {
  make_competing_runs_case "$1" completed cancelled
  local d=$TMP_ROOT/$1 gen
  FM_FAKE_AXI_STATUS="$(run_passed fm/competing | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
  git -C "$d/wt" commit -q --allow-empty -m 'current work after completed validation'
  fm_write_meta "$d/state/competing.meta" "window=fm:fm-competing" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementation after validation\n' > "$d/state/competing.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" competing)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" competing "$2" --gen "$gen" \
    --source claude-hook --event "${3:-stop}"
}

test_historical_inventory_uses_current_pane() {
  make_historical_inventory_case historical-inventory-busy busy user-prompt-submit
  local d=$TMP_ROOT/historical-inventory-busy out
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: working' 'R3 a proven historical run must preserve a busy worker'
  assert_contains "$out" 'source: pane' 'a historical inventory row yields to current pane evidence'
  assert_not_contains "$out" 'source: run-step' 'historical rows cannot be reattributed through the ledger'
  pass 'R3 historical inventory yields to the current busy pane'
}

test_historical_inventory_uses_current_status() {
  make_historical_inventory_case historical-inventory-idle idle
  local d=$TMP_ROOT/historical-inventory-idle out
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: working' 'R3 a proven historical run must preserve current worker status'
  assert_contains "$out" 'source: status-log' 'historical inventory yields to the current status log'
  assert_contains "$out" 'implementation after validation' 'the current work detail is preserved'
  pass 'R3 historical inventory yields to current worker status'
}

test_superseded_cancelled_run_preserves_replacement_gate() {
  make_competing_runs_case superseded-gate running cancelled
  local d=$TMP_ROOT/superseded-gate out
  FM_FAKE_AXI_STATUS="$(run_failed fm/competing | sed 's/01RUN/01OLD/; s/failed/cancelled/')
error: \"cancelled: superseded by new push\""
  # The rerun's rebased head is not in the submitted worktree's object store.
  FM_FAKE_RUN_HEAD=0123abcd
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')
branch_sync:
  state: pipeline_owned"
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed '/01NEW/s/,[a-f0-9]*,""$/,0123abcd,""/')
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: parked' 'superseded cancelled run must expose the live review gate'
  assert_contains "$out" 'parked at review: 2 finding(s)' 'replacement gate detail survives selection'
  assert_contains "$out" '01NEW' 'the selected replacement run is identified'
  pass 'superseded cancelled run preserves the replacement review gate'
}

# A commit the task copy HAS but that is neither the local head, an ancestor,
# nor a descendant of it: exactly what a pipeline rebase leaves as the run head.
make_rebased_head() {  # <worktree> -> echoes the diverged commit's short sha
  local wt=$1 tree commit
  tree=$(git -C "$wt" hash-object -t tree -w /dev/null)
  commit=$(git -C "$wt" commit-tree "$tree" -m 'pipeline rebased head')
  git -C "$wt" merge-base --is-ancestor HEAD "$commit" && fail "rebased head must not descend from local head"
  git -C "$wt" merge-base --is-ancestor "$commit" HEAD && fail "rebased head must not be an ancestor of local head"
  git -C "$wt" rev-parse --short=8 "$commit"
}

# A live run whose head diverged from the local head because the pipeline
# rebased the branch is this task's current run. The newest overview row is the
# live run, and an older FAILED run still matches the local head; the failed run
# must not be read as the task's state (2026-08-23 billing-cycle-crash-safety).
test_live_rebased_run_beats_older_failed_run_at_local_head() {
  make_competing_runs_case live-rebased running failed
  local d=$TMP_ROOT/live-rebased out rebased
  rebased=$(make_rebased_head "$d/wt")
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed "/01NEW/s/,[a-f0-9]*,\"\"\$/,$rebased,\"\"/")
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')
branch_sync:
  state: synced"
  FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
  printf 'working: validating\n' > "$d/state/competing.status"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: working' 'a live run on the branch reads working despite its rebased head'
  assert_contains "$out" 'source: run-step' 'the live run is the authoritative source'
  assert_not_contains "$out" 'state: failed' 'the older failed run must not be read as current'
  pass 'a live rebased run beats an older failed run at the local head'
}

# The same live run reads working for every EXECUTING status word the CLI can
# actually deliver here. `fm_nm_select_run` validates the overview status column
# against pending|running|completed|failed|cancelled, so those are the only live
# words that reach the predicate; the overview and the id-addressed detail read
# the same runs.status column, so the fixture carries one word in BOTH surfaces.
test_live_rebased_run_reads_working_for_every_executing_status() {
  local status d rebased out
  for status in pending running; do
    make_competing_runs_case "live-rebased-$status" "$status" failed
    d=$TMP_ROOT/live-rebased-$status
    rebased=$(make_rebased_head "$d/wt")
    FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed "/01NEW/s/,[a-f0-9]*,\"\"\$/,$rebased,\"\"/")
    FM_FAKE_RUN_HEAD=$rebased
    FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed "s/01RUN/01NEW/; s/status: running/status: $status/")"
    FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" 'state: working' "$status run with a rebased head reads working"
    assert_contains "$out" 'source: run-step' "$status run with a rebased head is run-step sourced"
    assert_not_contains "$out" 'state: failed' "$status run with a rebased head is never failed"
    pass "$status run with a rebased head reads working"
  done
}

# The LEGACY bare-status surface carries run-level `fixing` and `ci`, which the
# overview table's vocabulary does not include. The selector never validates a
# word there (it answers `unavailable` with no table), so those runs are the
# crew's own live run and must bind at a rebased head like any other.
test_legacy_surface_binds_fixing_and_ci_at_a_rebased_head() {
  local status d rebased out
  for status in fixing ci; do
    reset_fakes
    d=$(new_case "legacy-live-$status")
    make_repo_on_branch "$d/wt" fm/feat-legacylive
    rebased=$(make_rebased_head "$d/wt")
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-legacylive.meta" "window=fm:fm-feat-legacylive" "worktree=$d/wt" "kind=ship" "harness=claude"
    printf 'failed: earlier stage run\n' > "$d/state/feat-legacylive.status"
    FM_FAKE_RUN_HEAD=$rebased
    FM_FAKE_AXI_STATUS="$(run_running fm/feat-legacylive | sed "s/status: running/status: $status/")
branch_sync:
  state: synced"
    FM_FAKE_RUNS_LIST=""
    FM_FAKE_BUSY=0
    arm_idle_record "$d/state" feat-legacylive
    out=$(run_crew_state "$d" feat-legacylive)
    assert_contains "$out" "source: run-step" "a legacy $status run at a rebased head binds"
    assert_contains "$out" "state: working" "a legacy $status run reads working"
    assert_not_contains "$out" "state: failed" "the stale failed event must not answer for a live $status run"
    pass "legacy surface binds a $status run at a rebased head"
  done
}

# Legacy CLI surface (no overview table): the bare `axi status` run is live on
# this branch with a rebased head, while the runs ledger still holds an older
# failed row at the local head.
test_legacy_live_rebased_run_is_authoritative() {
  reset_fakes
  local d rebased short out; d=$(new_case legacy-live-rebased)
  make_repo_on_branch "$d/wt" fm/feat-rebased
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-rebased.meta" "window=fm:fm-feat-rebased" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/feat-rebased.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-rebased)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-rebased ${rebased}  2026-08-23 13:53
  failed     fm/feat-rebased ${short}  2026-08-23 12:09
EOF
)"
  out=$(run_crew_state "$d" feat-rebased)
  assert_contains "$out" 'state: working' 'legacy live rebased run reads working'
  assert_contains "$out" 'source: run-step' 'legacy live rebased run is run-step sourced'
  assert_not_contains "$out" 'state: failed' 'the older failed row must not read as current'
  pass 'legacy live rebased run is authoritative over an older failed row'
}

# The head-free route is licensed by the daemon being reachable. Once the daemon
# answers down AND no ledger row anchors the run, nothing ties the record to this
# worktree at all, so it stops answering and the status log takes over.
test_live_record_at_diverged_head_does_not_bind_an_unproven_record() {
  reset_fakes
  local d rebased out; d=$(new_case zombie-daemon-down)
  make_repo_on_branch "$d/wt" fm/feat-zombie
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-zombie.meta" "window=fm:fm-feat-zombie" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/feat-zombie.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-zombie)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-zombie
  out=$(run_crew_state "$d" feat-zombie)
  assert_not_contains "$out" "source: run-step" "a record with neither head nor anchor identity must not bind"
  assert_contains "$out" "source: status-log" "the crew's own evidence answers instead"
  pass "an unproven record at a diverged head does not answer for the crew"
}

# A run PARKED at a gate keeps its gate and findings when the daemon dies. The
# ledger word stays `running` while a run waits (parked.toon), so classifying
# off the ledger would relabel an open decision as a dead live record and the
# findings would never reach the supervisor.
test_parked_gate_survives_a_dead_daemon() {
  reset_fakes
  local d local_short out; d=$(new_case parked-dead-daemon)
  make_repo_on_branch "$d/wt" fm/feat-parkdd
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-parkdd.meta" "window=fm:fm-feat-parkdd" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-parkdd.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-parkdd)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-parkdd f0f0f0f0  2026-08-27 13:53
  completed  fm/feat-parkdd ${local_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-parkdd
  out=$(run_crew_state "$d" feat-parkdd)
  assert_contains "$out" "state: parked" "an open gate stays parked when the instrument dies"
  assert_contains "$out" "parked at review" "the gate itself still reaches the supervisor"
  assert_contains "$out" "finding(s)" "the gate findings still reach the supervisor"
  assert_not_contains "$out" "state: unknown" "a parked run is not a dead live record"
  pass "a parked gate survives a dead daemon with its findings intact"
}

# The modern selected-run route reaches the same diverged-head shape: the run
# head RESOLVES but diverged after the pipeline rebased, and no ledger row
# anchors it, so identity is unproven and the record must not answer at all.
test_selected_run_diverged_head_does_not_bind_an_unproven_record() {
  reset_fakes
  local d rebased out; d=$(new_case selected-diverged-down)
  make_repo_on_branch "$d/wt" fm/feat-seldiv
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/seldiv.meta" "window=fm:fm-seldiv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/seldiv.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-seldiv,running,$rebased,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-seldiv)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" seldiv
  out=$(run_crew_state "$d" seldiv)
  assert_not_contains "$out" "source: run-step" "an unproven record must not bind on the selected route either"
  assert_contains "$out" "source: status-log" "the crew's own evidence answers instead"
  pass "an unproven record at a diverged head does not answer on the selected route"
}

# The crew observed the refused socket itself. The ledger anchor BINDS a record
# here and the dead daemon makes it unverified, so this drives the dead-daemon
# verdict directly - and the blocker must still outrank it.
test_socket_refused_log_survives_the_dead_daemon_verdict() {
  reset_fakes
  local d local_short out; d=$(new_case socket-refused-anchored)
  make_repo_on_branch "$d/wt" fm/feat-sockdiv
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-sockdiv.meta" "window=fm:fm-feat-sockdiv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: no-mistakes daemon socket refused connections\n' > "$d/state/feat-sockdiv.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-sockdiv)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-sockdiv f0f0f0f0  2026-08-27 13:53
  completed  fm/feat-sockdiv ${local_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-sockdiv
  out=$(run_crew_state "$d" feat-sockdiv)
  assert_contains "$out" "state: blocked" "a first-hand socket refusal is not demoted to a generic unknown"
  assert_contains "$out" "socket refused" "the crew's own blocker reaches the supervisor"
  assert_not_contains "$out" "state: unknown" "the unverified record must not replace the blocker"
  pass "a socket-refused blocker survives the dead-daemon verdict"
}

# The selected route's anchored shape with an ORDINARY blocker: the header rule
# says a blocked tip stays blocked with the unverified record named, and nothing
# else reaches that path with a `blocked:` tip.
test_ordinary_blocked_tip_survives_the_dead_daemon_verdict() {
  reset_fakes
  local d h2 short out; d=$(new_case ordinary-blocked-anchored)
  make_repo_on_branch "$d/wt" fm/feat-obanch
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-obanch.meta" "window=fm:fm-feat-obanch" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: database upload failed with broken pipe\n' > "$d/state/feat-obanch.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-obanch,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-obanch)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-obanch $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-obanch ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-obanch
  out=$(run_crew_state "$d" feat-obanch)
  assert_contains "$out" "state: blocked" "an ordinary blocker stays blocked when the record is unverified"
  assert_contains "$out" "broken pipe" "the crew's own blocker reaches the supervisor"
  assert_contains "$out" "daemon unreachable" "the unverified record is named as the reason"
  assert_not_contains "$out" "superseded" "an unverified record never supersedes an open blocker"
  pass "an ordinary blocked tip survives the dead-daemon verdict"
}


# A visibly working crew must never be overridden by a stale record that merely
# names its branch. Identity is proven by neither head nor ledger anchor here,
# so the busy pane answers - the base behaviour before the daemon guard existed.
test_unproven_record_with_dead_daemon_does_not_override_a_busy_pane() {
  reset_fakes
  local d rebased out gen; d=$(new_case unproven-busy-pane)
  make_repo_on_branch "$d/wt" fm/feat-unproven
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-unproven.meta" "window=fm:fm-feat-unproven" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-unproven.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-unproven)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=1
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-unproven)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-unproven busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  out=$(run_crew_state "$d" feat-unproven)
  assert_contains "$out" "state: working" "a busy crew keeps reading working"
  assert_contains "$out" "source: pane" "the live pane answers, not the stale record"
  assert_not_contains "$out" "state: unknown" "an unproven record must not blank out a working crew"
  pass "an unproven record with a dead daemon never overrides a busy pane"
}

# Only a gate is ambiguous under a coarse live row. An ordinary blocker keeps the
# pre-existing reading, exactly as it does on the full route.
test_coarse_live_row_over_ordinary_blocked_keeps_superseded_reading() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-ordinary-blocked)
  make_repo_on_branch "$d/wt" fm/feat-cob
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cob.meta" "window=fm:fm-feat-cob" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: database upload failed with broken pipe\n' > "$d/state/feat-cob.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-cob ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cob
  out=$(run_crew_state "$d" feat-cob)
  assert_contains "$out" "state: working" "an ordinary blocker over a live coarse row keeps working"
  assert_contains "$out" "superseded by active run" "the generic superseded reading is kept"
  assert_not_contains "$out" "state: blocked" "a validating crew must not read blocked"
  pass "an ordinary blocked tip over a coarse live row keeps the superseded reading"
}

# The head-free route still binds while the daemon answers: the daemon probe
# narrows the zombie case only, it does not undo the rebase fix.
test_live_record_at_diverged_head_binds_while_daemon_answers() {
  reset_fakes
  local d rebased out; d=$(new_case live-daemon-up)
  make_repo_on_branch "$d/wt" fm/feat-livedaemon
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-livedaemon.meta" "window=fm:fm-feat-livedaemon" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/feat-livedaemon.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-livedaemon)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-livedaemon
  out=$(run_crew_state "$d" feat-livedaemon)
  assert_contains "$out" "source: run-step" "a reachable daemon keeps the rebased live run authoritative"
  assert_contains "$out" "state: working" "the live rebased run still reads working"
  pass "a live record at a diverged head binds while the daemon answers"
}


# Same anchored shape with the daemon answering: the guard narrows the dead
# instrument only, the unfetched-head fix round still binds.
test_anchored_continuation_binds_while_daemon_answers() {
  reset_fakes
  local d local_short out; d=$(new_case anchored-daemon-up)
  make_repo_on_branch "$d/wt" fm/feat-anchorup
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-anchorup.meta" "window=fm:fm-feat-anchorup" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/feat-anchorup.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-anchorup)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-anchorup f0f0f0f0  2026-08-27 13:53
  completed  fm/feat-anchorup ${local_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-anchorup
  out=$(run_crew_state "$d" feat-anchorup)
  assert_contains "$out" "source: run-step" "the anchored continuation still binds with the daemon answering"
  assert_contains "$out" "state: working" "the anchored live run reads working"
  pass "the anchored continuation binds while the daemon answers"
}

# A record that just declared itself unverified cannot also declare an open
# decision superseded.
test_unverified_coarse_record_makes_no_supersede_claim() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-unknown-supersede)
  make_repo_on_branch "$d/wt" fm/feat-cus
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cus.meta" "window=fm:fm-feat-cus" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-cus.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-cus ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cus
  out=$(run_crew_state "$d" feat-cus)
  assert_contains "$out" "state: working" "a head-tied coarse row keeps its working reading whatever the daemon answers"
  assert_contains "$out" "superseded by active run" "the coarse route keeps its original supersede note"
  pass "a head-tied coarse record keeps its working reading and its original note"
}

# The modern selected-run route reaches the anchored-continuation rule through
# its own `elif` (the run head is not an object in this copy). That route binds
# on ledger evidence which proves IDENTITY, not liveness, so the daemon rule
# has to hold there too.
test_selected_run_anchored_continuation_needs_a_live_daemon() {
  reset_fakes
  local d h2 short out
  d=$(new_case selected-anchored-down)
  make_repo_on_branch "$d/wt" fm/feat-selanchor
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/selanchor.meta" "window=fm:fm-selanchor" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/selanchor.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-selanchor,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-selanchor)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-selanchor $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-selanchor ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" selanchor
  out=$(run_crew_state "$d" selanchor)
  assert_not_contains "$out" "state: working" "the selected anchored route must not read working with the daemon answering down"
  assert_contains "$out" "daemon unreachable" "the ledger anchor proved identity, so liveness is what is reported"
  assert_not_contains "$out" "code identity unverified" "an anchored run's identity is proven, not unverified"
  assert_contains "$out" "run: 01RUN" "the verdict still names the run for a later --run read"
  pass "the selected-run anchored continuation reports the dead daemon, not an identity failure"
}

# The selected route honours the parked exemption too: an anchored PARKED run
# with a dead daemon keeps its gate and findings, exactly as the legacy route
# does on the same evidence.
test_selected_run_anchored_parked_keeps_its_gate_with_a_dead_daemon() {
  reset_fakes
  local d local_short out; d=$(new_case selected-anchored-parked)
  make_repo_on_branch "$d/wt" fm/feat-selpark
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/selpark.meta" "window=fm:fm-selpark" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/selpark.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-selpark,running,f0f0f0f0,\"\""
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-selpark)
branch_sync:
  state: synced"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-selpark f0f0f0f0  2026-08-27 13:53
  completed  fm/feat-selpark ${local_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" selpark
  out=$(run_crew_state "$d" selpark)
  assert_contains "$out" "state: parked" "an anchored parked run stays parked when the instrument dies"
  assert_contains "$out" "parked at review" "the gate reaches the supervisor on the selected route too"
  assert_contains "$out" "finding(s)" "the gate findings reach the supervisor"
  assert_not_contains "$out" "state: unknown" "a parked run is not a dead live record"
  pass "the selected route keeps an anchored parked run's gate with a dead daemon"
}

# An open decision outranks the unverified record on the selected route as well.
# The ledger anchor binds the run here, so the dead-daemon verdict is genuinely
# produced and the reconciliation is what keeps the decision visible.
test_selected_run_dead_daemon_leaves_the_open_decision_open() {
  reset_fakes
  local d h2 short out; d=$(new_case selected-dead-decision)
  make_repo_on_branch "$d/wt" fm/feat-seldec
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/seldec.meta" "window=fm:fm-seldec" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/seldec.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-seldec,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-seldec)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-seldec $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-seldec ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" seldec
  out=$(run_crew_state "$d" seldec)
  assert_contains "$out" "state: parked" "the open decision is not hidden behind the unverified record"
  assert_contains "$out" "approve the schema change" "the crew's own decision note reaches the supervisor"
  assert_contains "$out" "daemon unreachable" "the unverified record is named as the reason"
  assert_contains "$out" "run: 01RUN" "the verdict names the run so a human can go look at it"
  assert_not_contains "$out" "superseded" "an unverified record never supersedes an open decision"
  pass "an open decision survives the dead-daemon verdict on the selected route"
}

# A probe that did not ANSWER proves nothing, so it must not hand the verdict to
# a stale open decision: a genuinely failed run would be reported as awaiting a
# human on probe latency alone. The record still degrades to unknown, which is
# ambiguous but not falsely actionable.
test_unanswered_probe_does_not_turn_a_failed_coarse_record_into_a_gate() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-failed-probe-timeout)
  make_repo_on_branch "$d/wt" fm/feat-cfpt
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cfpt.meta" "window=fm:fm-feat-cfpt" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-cfpt.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  failed     fm/feat-cfpt ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_TIMEOUT=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cfpt
  out=$(run_crew_state "$d" feat-cfpt)
  assert_contains "$out" "state: unknown" "an unanswered probe still degrades the terminal record"
  assert_not_contains "$out" "state: parked" "probe latency must not assert an open gate over a failed run"
  pass "an unanswered probe never turns a failed coarse record into a gate"
}



# The selected route already appends `run: <id>` to every ordinary verdict, so
# the dead-daemon detail must not carry its own copy.
test_selected_route_dead_daemon_names_the_run_once() {
  reset_fakes
  local d h2 short out ids; d=$(new_case selected-id-once)
  make_repo_on_branch "$d/wt" fm/feat-selonce
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/selonce.meta" "window=fm:fm-selonce" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/selonce.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-selonce,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-selonce)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-selonce $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-selonce ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" selonce
  out=$(run_crew_state "$d" selonce)
  ids=$(printf '%s\n' "$out" | grep -o '01RUN' | wc -l | tr -d ' ')
  assert_contains "$out" "daemon unreachable" "the dead instrument is still named"
  assert_contains "$out" "01RUN" "the verdict still names the run"
  assert_equals "1" "$ids" "the run id appears exactly once"
  pass "the selected-route dead-daemon verdict names the run once"
}

# The same run, the same head, the same dead daemon must read the same way
# whichever run the shared daemon's bare `axi status` happens to name - that is
# routine once several crews validate one repo. The ledger row sits at this
# worktree's own head, so the head rule exempts it either way.
test_head_tied_row_reads_the_same_whichever_run_axi_names() {
  local who d local_short out
  for who in self other; do
    reset_fakes
    d=$(new_case "head-tied-$who")
    make_repo_on_branch "$d/wt" fm/feat-htied
    local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-htied.meta" "window=fm:fm-feat-htied" "worktree=$d/wt" "kind=ship" "harness=claude"
    printf 'working: implementing\n' > "$d/state/feat-htied.status"
    if [ "$who" = self ]; then
      FM_FAKE_AXI_STATUS="$(run_running fm/feat-htied)
branch_sync:
  state: synced"
    else
      FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
    fi
    FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-htied ${local_short}  2026-08-23 13:53
EOF
)"
    FM_FAKE_DAEMON_DOWN=1
    FM_FAKE_BUSY=0
    arm_idle_record "$d/state" feat-htied
    out=$(run_crew_state "$d" feat-htied)
    assert_contains "$out" "state: working" "$who: a head-tied run reads working with the daemon down"
    assert_not_contains "$out" "state: unknown" "$who: the head rule exempts a head-tied record"
    pass "a head-tied row reads working when axi names the $who run"
  done
}

# The record's head and the ledger row's head are INDEPENDENT. A same-branch
# record whose own head diverged still reaches the coarse fallback, where the
# newest ledger row can sit at this worktree's own head - a head-tied row the
# head rule exempts. The coarse route carries no dead-daemon verdict, so that
# row keeps its working reading.
test_coarse_head_tied_row_is_exempt_even_when_the_record_head_diverged() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-head-tied-diverged-record)
  make_repo_on_branch "$d/wt" fm/feat-chtd
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-chtd.meta" "window=fm:fm-feat-chtd" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-chtd.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-chtd)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="  running    fm/feat-chtd ${local_short}  2026-08-23 13:53"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-chtd
  out=$(run_crew_state "$d" feat-chtd)
  assert_contains "$out" "state: working" "a head-tied ledger row keeps its working reading"
  assert_not_contains "$out" "state: unknown" "the head rule exempts a head-tied row whatever the record head says"
  assert_not_contains "$out" "daemon unreachable" "the coarse route carries no dead-instrument verdict"
  pass "a head-tied coarse row is exempt even when the record head diverged"
}

# An unrecognised ledger word yields an unknown verdict from a LIVE daemon, so it
# is not an unverified record: the ordinary supersede note applies, as it did
# before the coarse-unknown special case existed.
test_unrecognised_ledger_word_keeps_the_ordinary_supersede_note() {
  reset_fakes
  local d local_short out; d=$(new_case unrecognised-word-supersede)
  make_repo_on_branch "$d/wt" fm/feat-uws
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-uws.meta" "window=fm:fm-feat-uws" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-uws.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  pending    fm/feat-uws ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-uws
  out=$(run_crew_state "$d" feat-uws)
  assert_contains "$out" "state: unknown" "an unrecognised word still reads unknown"
  assert_contains "$out" "runs list status: pending" "the unrecognised word is reported as itself"
  assert_contains "$out" "superseded (run unknown)" "a live daemon's unknown keeps the ordinary supersede note"
  pass "an unrecognised ledger word keeps the ordinary supersede note"
}

# The coarse ledger word `pending` is not an acceptance: it keeps its unknown
# reading rather than claiming the crew is validating.
test_coarse_pending_ledger_word_reads_unknown() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-pending)
  make_repo_on_branch "$d/wt" fm/feat-cpend
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cpend.meta" "window=fm:fm-feat-cpend" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-cpend.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  pending    fm/feat-cpend ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cpend
  out=$(run_crew_state "$d" feat-cpend)
  assert_contains "$out" "state: unknown" "a pending ledger word is not a working claim"
  assert_contains "$out" "runs list status: pending" "the unrecognised word is reported as itself"
  pass "a coarse pending ledger word reads unknown"
}

# The same anchored selected-run shape with the daemon answering still binds.
test_selected_run_anchored_continuation_binds_while_daemon_answers() {
  reset_fakes
  local d h2 short out
  d=$(new_case selected-anchored-up)
  make_repo_on_branch "$d/wt" fm/feat-selanchorup
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/selanchorup.meta" "window=fm:fm-selanchorup" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/selanchorup.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-selanchorup,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-selanchorup)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-selanchorup $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-selanchorup ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" selanchorup
  out=$(run_crew_state "$d" selanchorup)
  assert_contains "$out" "source: run-step" "the selected anchored route binds with the daemon answering"
  assert_contains "$out" "state: working" "the anchored fix round still reads working"
  pass "the selected-run anchored continuation binds while the daemon answers"
}

# A coarse TERMINAL record whose daemon is down is degraded to unknown, and that
# is where it stops: the ledger row is head-tied, so its identity is PROVEN and
# it records a run that reached a terminal failure at this worktree's own head.
# A daemon dying afterwards does not unmake that outcome, so the reading must
# not become a claim that a human decision is pending.
test_coarse_failed_record_with_dead_daemon_reads_unknown() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-failed-supersede)
  make_repo_on_branch "$d/wt" fm/feat-cfs
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cfs.meta" "window=fm:fm-feat-cfs" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-cfs.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  failed     fm/feat-cfs ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cfs
  out=$(run_crew_state "$d" feat-cfs)
  assert_contains "$out" "state: unknown" "a dead daemon degrades the terminal record to unknown"
  assert_contains "$out" "unverified" "the unverified record is named"
  assert_not_contains "$out" "state: parked" "a recorded terminal failure is never relabelled an open decision"
  pass "a coarse failed record with a dead daemon reads unknown"
}

# Exit 0 alone does not prove a live daemon: only a positive running answer
# licenses head-free attribution. A timeout remains unanswered rather than down.
test_daemon_probe_requires_positive_running_answer() {
  local probe d rebased out expected
  for probe in running stopped empty unexpected absent refused timeout; do
    reset_fakes
    d=$(new_case "probe-answer-$probe")
    make_repo_on_branch "$d/wt" fm/feat-probeanswer
    rebased=$(make_rebased_head "$d/wt")
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-probeanswer.meta" "window=fm:fm-feat-probeanswer" "worktree=$d/wt" "kind=ship" "harness=claude"
    printf 'failed: earlier run failed\n' > "$d/state/feat-probeanswer.status"
    FM_FAKE_RUN_HEAD=$rebased
    FM_FAKE_AXI_STATUS="$(run_running fm/feat-probeanswer)
branch_sync:
  state: synced"
    expected=failed
    case "$probe" in
      running) expected=working ;;
      stopped) FM_FAKE_DAEMON_OUTPUT='  ○ daemon not running' ;;
      empty) FM_FAKE_DAEMON_OUTPUT='' ;;
      unexpected) FM_FAKE_DAEMON_OUTPUT='unknown daemon status' ;;
      absent|refused)
        FM_FAKE_DAEMON_DOWN=1
        FM_FAKE_DAEMON_OUTPUT="socket $probe"
        ;;
      timeout) FM_FAKE_DAEMON_TIMEOUT=1; expected=working ;;
    esac
    arm_idle_record "$d/state" feat-probeanswer
    out=$(run_crew_state "$d" feat-probeanswer)
    assert_contains "$out" "state: $expected" "$probe: daemon answer controls live-run attribution"
    if [ "$expected" = working ]; then
      assert_contains "$out" 'source: run-step' "$probe: live run stays bound"
    else
      assert_contains "$out" 'source: status-log' "$probe: stale run cannot override the crew log"
    fi
    pass "daemon probe classifies $probe"
  done
}

# A probe that does not ANSWER proves nothing about the daemon, so it must not
# suppress a live rebased run: otherwise a slow `daemon status` on a busy fleet
# drops the crew back to a stale `failed:` log line, and the crew flaps between
# working and failed on probe latency alone.
test_unanswered_daemon_probe_does_not_suppress_live_run() {
  reset_fakes
  local d rebased out; d=$(new_case probe-timeout)
  make_repo_on_branch "$d/wt" fm/feat-probeto
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-probeto.meta" "window=fm:fm-feat-probeto" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'failed: earlier run failed\n' > "$d/state/feat-probeto.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-probeto)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_TIMEOUT=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-probeto
  out=$(run_crew_state "$d" feat-probeto)
  assert_contains "$out" "source: run-step" "an unanswered probe must not unbind the live run"
  assert_contains "$out" "state: working" "the live rebased run still reads working"
  assert_not_contains "$out" "state: failed" "the stale failed event must not answer on probe latency"
  pass "an unanswered daemon probe leaves a live rebased run bound"
}

# The coarse ledger row sits at this worktree's own head, so the head rule has
# already proven its identity and exempts it from the dead-instrument verdict:
# a dead daemon does not change what a head-tied row says about this crew.
test_coarse_live_row_is_exempt_from_the_dead_daemon_verdict() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-live-daemon-down)
  make_repo_on_branch "$d/wt" fm/feat-cldd
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cldd.meta" "window=fm:fm-feat-cldd" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-cldd.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-cldd ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cldd
  out=$(run_crew_state "$d" feat-cldd)
  assert_contains "$out" "state: working" "a head-tied coarse row keeps its working reading"
  assert_not_contains "$out" "daemon unreachable" "the head rule exempts a head-tied record from the dead-instrument verdict"
  assert_not_contains "$out" "01RUN" "the foreign crew's run id is never offered as this crew's"
  pass "a head-tied coarse live row is exempt from the dead-daemon verdict"
}

# The coarse route carries no special reading for an open decision: a live row
# over a needs-decision tip keeps the pre-existing supersede note, and the crew
# reads working rather than awaiting a human.
test_coarse_live_row_keeps_the_original_supersede_note() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-gate-signal)
  make_repo_on_branch "$d/wt" fm/feat-cg
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cg.meta" "window=fm:fm-feat-cg" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: review gate has an ask-user finding\n' > "$d/state/feat-cg.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-cg ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cg
  out=$(run_crew_state "$d" feat-cg)
  assert_contains "$out" "state: working" "a genuinely validating crew is not reported as awaiting a human"
  assert_contains "$out" "superseded by active run" "the coarse route keeps its original supersede note"
  pass "a coarse live row over an open decision keeps the original supersede note"
}

# Coarse negative control (axi answers another branch): a live row on the task's
# branch at a rebased head is not tied to this worktree by anything but the
# branch name, so the ledger must not answer for it and the older failed row
# must not answer either.
test_coarse_live_rebased_row_is_not_attributed() {
  reset_fakes
  local d rebased short out; d=$(new_case coarse-live-rebased)
  make_repo_on_branch "$d/wt" fm/feat-rebased2
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-rebased2.meta" "window=fm:fm-feat-rebased2" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-rebased2.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-rebased2 ${rebased}  2026-08-23 13:53
  failed     fm/feat-rebased2 ${short}  2026-08-23 12:09
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-rebased2
  out=$(run_crew_state "$d" feat-rebased2)
  assert_not_contains "$out" 'source: run-step' 'a branch-name-only live row must not bind'
  assert_not_contains "$out" 'state: failed' 'the older failed row must not answer either'
  assert_contains "$out" 'source: status-log' 'the status log answers without an attributable run'
  pass 'a coarse live row at a rebased head is not attributed'
}

# Negative control: once the rebased run has FAILED it is finished history on a
# head this worktree does not match, so it is not attributed and never reads as
# the task's failure.
test_terminal_rebased_run_is_not_attributed() {
  make_competing_runs_case terminal-rebased failed completed
  local d=$TMP_ROOT/terminal-rebased out rebased
  rebased=$(make_rebased_head "$d/wt")
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed "/01NEW/s/,[a-f0-9]*,\"\"\$/,$rebased,\"\"/")
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_failed fm/competing | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
  fm_write_meta "$d/state/competing.meta" "window=fm:fm-competing" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/competing.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" competing
  out=$(run_crew_state "$d" competing)
  assert_not_contains "$out" 'source: run-step' 'a terminal run on a diverged head is not attributed'
  assert_contains "$out" 'source: status-log' 'the status log answers when only a foreign terminal run exists'
  pass 'a terminal run at a diverged head keeps the strict head rule'
}

test_competing_live_runs_report_unknown_with_both_ids() {
  make_competing_runs_case ambiguous-runs running running
  local d=$TMP_ROOT/ambiguous-runs out
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
  printf 'done: old completion event\n' > "$d/state/competing.status"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'two live runs cannot establish exclusive authority'
  assert_contains "$out" '01NEW' 'ambiguity names the newer candidate'
  assert_contains "$out" '01OLD' 'ambiguity names the older candidate'
  pass 'competing live runs report unknown with both run ids'
}

# Overview order A (historical-first / reversed): AXI can surface a historical
# row before the active current run when an old run was updated by its stale PR
# being closed. The current branch status identifies the active run, so
# crew-state must not trust the overview's row order and report the stale PR
# state, even when both ledger rows share a minute-level timestamp.
test_current_active_run_beats_stale_overview_row() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case stale-overview-row)
  make_repo_on_branch "$d/wt" fm/reused-branch
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  new_head=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/reused.meta" "window=fm:fm-reused" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating the current run\n' > "$d/state/reused.status"
  FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  \"01OLD\",fm/reused-branch,completed,$old_head,\"https://github.com/o/r/pull/1\"
  \"01NEW\",fm/reused-branch,running,$new_head,\"\""
  FM_FAKE_RUN_HEAD=$new_head
  FM_FAKE_AXI_STATUS="$(run_running fm/reused-branch | sed 's/01RUN/01NEW/')
branch_sync:
  state: pipeline_owned"
  FM_FAKE_AXI_STATUS_RUN_01OLD="$(FM_FAKE_RUN_HEAD=$old_head run_passed fm/reused-branch | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_STATUS_RUN_01NEW="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="  running fm/reused-branch ${new_head:0:7} 2026-09-28 12:00
  completed fm/reused-branch ${old_head:0:7} 2026-09-28 12:00"
  out=$(run_crew_state "$d" reused)
  assert_contains "$out" 'state: working' 'the active current run remains authoritative'
  assert_contains "$out" '01NEW' 'the active run identity is reported'
  assert_not_contains "$out" 'PR closed' 'a stale closed PR is not reported for the active run'
  unset FM_FAKE_AXI_STATUS_RUN_01OLD FM_FAKE_AXI_STATUS_RUN_01NEW
  pass 'active current run beats a stale overview row'
}

# Same historical-first overview shape as above, but the stale row is failed
# rather than completed. failed is a terminal overview status and must yield to
# a newer live bare status the same way completed does.
test_current_active_run_beats_stale_failed_overview_row() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case stale-failed-overview-row)
  make_repo_on_branch "$d/wt" fm/reused-branch
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  new_head=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/reused.meta" "window=fm:fm-reused" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating the current run\n' > "$d/state/reused.status"
  FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  \"01OLD\",fm/reused-branch,failed,$old_head,\"\"
  \"01NEW\",fm/reused-branch,running,$new_head,\"\""
  FM_FAKE_RUN_HEAD=$new_head
  FM_FAKE_AXI_STATUS="$(run_running fm/reused-branch | sed 's/01RUN/01NEW/')
branch_sync:
  state: pipeline_owned"
  FM_FAKE_AXI_STATUS_RUN_01OLD="$(FM_FAKE_RUN_HEAD=$old_head run_failed fm/reused-branch | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_STATUS_RUN_01NEW="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="  running fm/reused-branch ${new_head:0:7} 2026-09-28 12:00
  failed fm/reused-branch ${old_head:0:7} 2026-09-28 12:00"
  out=$(run_crew_state "$d" reused)
  assert_contains "$out" 'state: working' 'the active current run remains authoritative'
  assert_contains "$out" '01NEW' 'the active run identity is reported'
  assert_not_contains "$out" 'state: failed' 'a stale failed overview row is not attributed'
  unset FM_FAKE_AXI_STATUS_RUN_01OLD FM_FAKE_AXI_STATUS_RUN_01NEW
  pass 'active current run beats a stale failed overview row'
}

test_current_active_run_beats_same_head_stale_failed_overview_row() {
  reset_fakes
  local d head out old_id new_id old_var new_var
  old_id=01M00000000000000000000000
  new_id=01M10000000000000000000000
  old_var=FM_FAKE_AXI_STATUS_RUN_$old_id
  new_var=FM_FAKE_AXI_STATUS_RUN_$new_id
  d=$(new_case stale-same-head-failed-overview-row)
  make_repo_on_branch "$d/wt" fm/reused-branch
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/reused.meta" "window=fm:fm-reused" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating the current run\n' > "$d/state/reused.status"
  FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  \"$old_id\",fm/reused-branch,failed,$head,\"\"
  \"$new_id\",fm/reused-branch,running,$head,\"\""
  FM_FAKE_RUN_HEAD=$head
  FM_FAKE_AXI_STATUS="$(run_running fm/reused-branch | sed "s/01RUN/$new_id/")
branch_sync:
  state: pipeline_owned"
  printf -v "$old_var" '%s' "$(FM_FAKE_RUN_HEAD=$head run_failed fm/reused-branch | sed "s/01RUN/$old_id/")"
  printf -v "$new_var" '%s' "$FM_FAKE_AXI_STATUS"
  export "${old_var?}" "${new_var?}"
  FM_FAKE_RUNS_LIST="  running fm/reused-branch ${head:0:7} 2026-09-28 12:00
  failed fm/reused-branch ${head:0:7} 2026-09-28 12:00"
  out=$(run_crew_state "$d" reused)
  assert_contains "$out" 'state: working' 'same-head active run remains authoritative'
  assert_contains "$out" "$new_id" 'same-head active run identity is reported'
  assert_not_contains "$out" 'state: failed' 'same-head stale failed row is not attributed'
  unset "$old_var" "$new_var"
  pass 'same-head active run beats a stale failed overview row'
}

test_same_head_run_with_unverifiable_timestamp_reports_unknown() {
  reset_fakes
  local d head out old_id new_id old_var new_var
  old_id=01M00000000000000000000001
  new_id=01M00000000000000000000000
  old_var=FM_FAKE_AXI_STATUS_RUN_$old_id
  new_var=FM_FAKE_AXI_STATUS_RUN_$new_id
  d=$(new_case stale-same-head-unverifiable-overview-row)
  make_repo_on_branch "$d/wt" fm/reused-branch
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/reused.meta" "window=fm:fm-reused" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating the current run\n' > "$d/state/reused.status"
  FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  \"$old_id\",fm/reused-branch,failed,$head,\"\"
  \"$new_id\",fm/reused-branch,running,$head,\"\""
  FM_FAKE_RUN_HEAD=$head
  FM_FAKE_AXI_STATUS="$(run_running fm/reused-branch | sed "s/01RUN/$new_id/")
branch_sync:
  state: pipeline_owned"
  printf -v "$old_var" '%s' "$(FM_FAKE_RUN_HEAD=$head run_failed fm/reused-branch | sed "s/01RUN/$old_id/")"
  printf -v "$new_var" '%s' "$FM_FAKE_AXI_STATUS"
  export "${old_var?}" "${new_var?}"
  FM_FAKE_RUNS_LIST="  running fm/reused-branch ${head:0:7} 2026-09-28 12:00
  failed fm/reused-branch ${head:0:7} 2026-09-28 12:00"
  out=$(run_crew_state "$d" reused)
  assert_contains "$out" 'state: unknown' 'same-head ordering within one ULID millisecond is unverified'
  assert_contains "$out" "$old_id" 'unverified same-head ordering names the selected run'
  assert_contains "$out" "$new_id" 'unverified same-head ordering names the reported run'
  assert_not_contains "$out" 'state: failed' 'unverified same-head ordering never attributes stale failure'
  unset "$old_var" "$new_var"
  pass 'same-head run with an unverified ULID timestamp reports unknown'
}

# Overview order B (recorded newer-first): a bare AXI status can lag the
# creation-ordered overview and name an older live run. That historical
# identity must not hide the overview's newer completed result, including when
# both ledger rows share a minute-level timestamp (row order is the tie-break).
test_older_live_status_does_not_hide_newer_completed_run() {
  reset_fakes
  local d new_head old_head out
  d=$(new_case older-live-status)
  make_repo_on_branch "$d/wt" fm/reused-branch
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  old_head=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/reused.meta" "window=fm:fm-reused" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating the current run\\n' > "$d/state/reused.status"
  FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  \"01NEW\",fm/reused-branch,completed,$new_head,\"https://github.com/o/r/pull/2\"
  \"01OLD\",fm/reused-branch,running,$old_head,\"\""
  FM_FAKE_RUN_HEAD=$old_head
  FM_FAKE_AXI_STATUS="$(run_running fm/reused-branch | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_STATUS_RUN_01OLD="$FM_FAKE_AXI_STATUS"
  FM_FAKE_AXI_STATUS_RUN_01NEW="$(FM_FAKE_RUN_HEAD=$new_head run_passed_with_pr fm/reused-branch https://github.com/o/r/pull/2 | sed 's/01RUN/01NEW/')"
  # Same-minute timestamps: ledger row order (newest-first) is the tie-break,
  # matching recorded AXI overviews. The bare status naming the older live run
  # must not hide the newer completed result.
  FM_FAKE_RUNS_LIST="  completed fm/reused-branch ${new_head:0:7} 2026-09-28 12:00 https://github.com/o/r/pull/2
  running fm/reused-branch ${old_head:0:7} 2026-09-28 12:00"
  out=$(run_crew_state "$d" reused)
  assert_contains "$out" 'state: done' 'the newer completed run remains authoritative'
  assert_contains "$out" '01NEW' 'the newer run identity is reported'
  assert_not_contains "$out" 'state: working' 'an older live status does not hide the completed result'
  pass 'older live status does not hide a newer completed run'
}

test_failed_selected_detail_read_is_not_attributed() {
  reset_fakes
  local d new_head old_head out
  d=$(new_case failed-selected-detail)
  make_repo_on_branch "$d/wt" fm/reused-branch
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  old_head=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/reused.meta" "window=fm:fm-reused" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating the current run\\n' > "$d/state/reused.status"
  FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  \"01NEW\",fm/reused-branch,completed,$new_head,\"https://github.com/o/r/pull/2\"
  \"01OLD\",fm/reused-branch,running,$old_head,\"\""
  FM_FAKE_RUN_HEAD=$old_head
  FM_FAKE_AXI_STATUS="$(run_running fm/reused-branch | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_STATUS_RUN_01OLD="$FM_FAKE_AXI_STATUS"
  FM_FAKE_AXI_STATUS_RUN_01NEW="$(FM_FAKE_RUN_HEAD=$new_head run_passed fm/reused-branch | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN_ERROR=1
  FM_FAKE_RUNS_LIST="  completed fm/reused-branch ${new_head:0:7} 2026-09-28 12:00
  running fm/reused-branch ${old_head:0:7} 2026-09-28 12:00"
  out=$(run_crew_state "$d" reused)
  assert_contains "$out" 'selected run unreadable' 'a failed selected-run read reports unknown'
  assert_not_contains "$out" 'state: done' 'output from a failed selected-run read is not attributed'
  pass 'failed selected-run detail read is not attributed'
}

# Overview lists a stale completed run A first, then a newer failed run C and
# a live run B created between them. B is newer than A but not than C, so B
# must not replace A and hide C's newer failure.
test_live_run_newer_than_selection_does_not_hide_newer_failed_run() {
  reset_fakes
  local d head out a_id b_id c_id a_var b_var c_var
  a_id=01M00000000000000000000000
  b_id=01M10000000000000000000000
  c_id=01M20000000000000000000000
  a_var=FM_FAKE_AXI_STATUS_RUN_$a_id
  b_var=FM_FAKE_AXI_STATUS_RUN_$b_id
  c_var=FM_FAKE_AXI_STATUS_RUN_$c_id
  d=$(new_case live-between-stale-and-newer-failed)
  make_repo_on_branch "$d/wt" fm/reused-branch
  head=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/reused.meta" "window=fm:fm-reused" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating the current run\n' > "$d/state/reused.status"
  FM_FAKE_AXI_HOME="count: 3 of 3 total
runs[3]{id,branch,status,head,pr}:
  \"$a_id\",fm/reused-branch,completed,$head,\"\"
  \"$c_id\",fm/reused-branch,failed,$head,\"\"
  \"$b_id\",fm/reused-branch,running,$head,\"\""
  FM_FAKE_RUN_HEAD=$head
  FM_FAKE_AXI_STATUS="$(run_running fm/reused-branch | sed "s/01RUN/$b_id/")"
  printf -v "$a_var" '%s' "$(FM_FAKE_RUN_HEAD=$head run_passed fm/reused-branch | sed "s/01RUN/$a_id/")"
  printf -v "$b_var" '%s' "$FM_FAKE_AXI_STATUS"
  printf -v "$c_var" '%s' "$(FM_FAKE_RUN_HEAD=$head run_failed fm/reused-branch | sed "s/01RUN/$c_id/")"
  export "${a_var?}" "${b_var?}" "${c_var?}"
  out=$(run_crew_state "$d" reused)
  assert_contains "$out" 'state: unknown' 'a live run older than another candidate is not promoted'
  assert_contains "$out" "$c_id" 'the newer failed run is named'
  assert_not_contains "$out" 'state: working' 'the live run does not hide the newer failed run'
  unset "$a_var" "$b_var" "$c_var"
  pass 'live run newer than the selection does not hide a newer failed run'
}

test_newer_failed_run_is_not_hidden_by_older_live_run() {
  make_competing_runs_case newest-failed failed running
  local d=$TMP_ROOT/newest-failed out
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_failed fm/competing | sed 's/01RUN/01NEW/')"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: failed' 'the newer failed run must not be hidden by an older live run'
  assert_contains "$out" '01NEW' 'the genuine failure identifies its run'
  pass 'newer failed run remains failed beside an older live run'
}

# A rerun that starts between the inventory read and the ledger read leaves a
# live head-matching row the reader has never read and cannot bind to a run id,
# so the honest answer is unknown, never a working verdict for that run.
test_live_ledger_row_after_selection_reports_unknown() {
  make_competing_runs_case rerun-window failed running
  local d=$TMP_ROOT/rerun-window out short
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_failed fm/competing | sed 's/01RUN/01NEW/')"
  FM_FAKE_RUNS_LIST="  running    fm/competing $short 2026-09-14 12:02
  failed     fm/competing $short 2026-09-14 12:01"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'an unbindable live replacement is never answered as working'
  assert_contains "$out" 'current state not provable here' 'the unbindable replacement is named as unprovable'
  assert_not_contains "$out" 'state: working' 'a run the reader never read cannot report working'
  pass 'a live ledger row appearing after selection reports unknown'
}

test_unverifiable_run_selection_reports_unknown() {
  local mode rc=0
  for mode in missing wrong-id wrong-branch wrong-head missing-status malformed-table inventory-error selected-error; do
    (
      make_competing_runs_case "unverified-$mode" running cancelled
      d=$TMP_ROOT/unverified-$mode
      FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01OLD/')"
      FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
      case "$mode" in
        missing) FM_FAKE_AXI_STATUS_RUN='' ;;
        wrong-id) FM_FAKE_AXI_STATUS_RUN=$(printf '%s\n' "$FM_FAKE_AXI_STATUS_RUN" | sed 's/01NEW/01OLD/') ;;
        wrong-branch) FM_FAKE_AXI_STATUS_RUN=$(printf '%s\n' "$FM_FAKE_AXI_STATUS_RUN" | sed 's@fm/competing@fm/another-task@') ;;
        wrong-head)
          FM_FAKE_AXI_STATUS_RUN="$(FM_FAKE_RUN_HEAD=0123abcd run_parked fm/competing | sed 's/01RUN/01NEW/')"
          ;;
        missing-status) FM_FAKE_AXI_STATUS_RUN=$(printf '%s\n' "$FM_FAKE_AXI_STATUS_RUN" | sed '/status:/d') ;;
        malformed-table) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/runs\[2\]/runs[3]/') ;;
        inventory-error) FM_FAKE_AXI_HOME_ERROR=1 ;;
        selected-error) FM_FAKE_AXI_STATUS_RUN_ERROR=1 ;;
      esac
      out=$(run_crew_state "$d" competing)
      assert_contains "$out" 'state: unknown' "$mode selection must not assert a run state"
      assert_contains "$out" '01NEW' "$mode selection preserves the replacement id"
      assert_contains "$out" '01OLD' "$mode selection preserves the original id"
      pass "$mode run selection reports unknown with candidate ids"
    ) || rc=1
  done
  [ "$rc" = 0 ] || fail 'unverifiable run selections'
}

test_legacy_conflicting_run_records_report_unknown() {
  make_competing_runs_case legacy-conflict failed running
  local d=$TMP_ROOT/legacy-conflict out
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_HOME=$FM_FAKE_AXI_STATUS
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'conflicting records without identities cannot prove authority'
  assert_contains "$out" '01OLD' 'legacy ambiguity preserves the available run id'
  assert_contains "$out" 'unavailable' 'legacy ambiguity states that the competing id is unavailable'
  pass 'legacy conflicting run records report unknown'
}

# Captured AXI stdout is a serialized input contract, not implementation source.
# Only the run identity is rebound to each disposable git repository; status,
# outcome, steps, findings, and gate bytes stay as emitted. The capture README
# distinguishes genuine histories from deliberately composed scenarios.
captured_axi_status() {  # <capture> [branch] [run-id]
  awk -v branch="${2:-fm/competing}" -v id="${3:-01NEW}" -v head="$FM_FAKE_RUN_HEAD" '
    /^  id:/ { print "  id: \"" id "\""; next }
    /^  branch:/ { print "  branch: " branch; next }
    /^  head:/ { print "  head: " head; next }
    /^  head_sha:/ { print "  head_sha: " head; next }
    { print }
  ' "$ROOT/tests/captures/no-mistakes-v1.70.1/$1.toon"
}

test_captured_axi_status_shapes() {
  local shape status expected d out toolbin
  for shape in replacement parked failed; do
    status=running; expected=working
    case "$shape" in parked) expected=parked ;; failed) status=failed; expected=failed ;; esac
    make_competing_runs_case "captured-$shape" "$status" cancelled
    d=$TMP_ROOT/captured-$shape
    FM_FAKE_AXI_STATUS=$(captured_axi_status superseded fm/competing 01OLD)
    FM_FAKE_AXI_STATUS_RUN=$(captured_axi_status "$shape")
    # A newer failure must remain visible even with an older live record.
    if [ "$shape" = failed ]; then
      FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/,cancelled,/,running,/')
      FM_FAKE_AXI_STATUS=$(captured_axi_status replacement fm/competing 01OLD)
    fi
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" "state: $expected" "captured $shape status is understood"
    assert_contains "$out" '01NEW' "captured $shape preserves the selected identity"
    if [ "$shape" = parked ]; then
      assert_contains "$out" 'parked at test: 1 finding(s)' 'the captured gate retains its actual step and finding count'
      assert_contains "$out" ' · ask-user: authority decision' \
        'the captured gate mints the human-decision component from the real column layout'
      toolbin=$(make_no_python_toolbin "$d")
      out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
      assert_contains "$out" 'parked at test: 1 finding(s)' 'a complete captured gate remains readable without Python'
      assert_contains "$out" ' · ask-user: authority decision' \
        'the captured gate mints the human-decision component without Python'
      assert_contains "$out" '01NEW' 'the captured gate retains its id without Python'
    fi
    pass "captured AXI $shape status replays through crew-state"
  done
}

test_captured_inventory_replay() {
  make_capped_runs_case captured-inventory running cancelled
  local d=$TMP_ROOT/captured-inventory out before after branch newer older toolbin
  branch=fm/fm-bearings-board-loses-owner-state-and-links
  newer=01M2GAWMSDQK4B5EA9GZW35RXE
  older=01M20MQ02N69VJKXW9N8321SQW
  git -C "$d/wt" checkout -q -b "$branch"
  python3 - "$NM_HOME/state.sqlite" "$ROOT/tests/captures/no-mistakes-v1.70.1/same-branch-inventory.json" <<'PY'
import json
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("DELETE FROM runs")
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)", [
        (r["id"], "repo", r["branch"], r["status"], r["head_sha"], r["created_at"])
        for r in json.load(open(sys.argv[2]))
    ])
PY
  FM_FAKE_AXI_HOME="repo: $d/wt
$(cat "$ROOT/tests/captures/no-mistakes-v1.70.1/overview.toon")"
  FM_FAKE_AXI_STATUS=$(captured_axi_status superseded "$branch" 01M2FNFPK984YP0EHFTD1XEF8P)
  FM_FAKE_AXI_STATUS_RUN=$(captured_axi_status replacement "$branch" "$newer")
  before=$(git hash-object "$NM_HOME/state.sqlite")
  out=$(run_crew_state "$d" competing)
  after=$(git hash-object "$NM_HOME/state.sqlite")
  assert_contains "$out" 'state: working' 'the recorded live successor outranks its superseded cancellation'
  assert_contains "$out" "$newer" 'the recorded successor keeps its real run id'
  [ "$before" = "$after" ] || fail 'captured inventory replay wrote to the database'
  assert_not_contains "$FM_FAKE_AXI_HOME" "$older" 'the competing candidate is outside the real overview window'
  # Counterfactual, not a recorded competing-live history: revive one hidden
  # cancelled row, keeping its captured id, branch, head, and creation order.
  python3 - "$NM_HOME/state.sqlite" "$older" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE runs SET status = 'running' WHERE id = ?", (sys.argv[2],))
PY
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'a hidden counterfactual live competitor prevents selection'
  assert_contains "$out" "$newer" 'captured ambiguity retains the visible id'
  assert_contains "$out" "$older" 'captured ambiguity retains the hidden id'
  toolbin=$(make_no_python_toolbin "$d")
  out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
  assert_contains "$out" 'state: unknown' 'missing optional lookup cannot imply exclusive authority'
  assert_contains "$out" "$newer" 'unavailable lookup retains the captured visible id'
  assert_contains "$out" 'inventory' 'unavailable lookup reports its evidence gap'
  pass 'captured capped inventory replays selection, ambiguity, and unavailable lookup'
}

test_captured_authority_transition() {
  make_competing_runs_case captured-transition running cancelled
  local d=$TMP_ROOT/captured-transition out
  FM_FAKE_AXI_STATUS=$(captured_axi_status replacement)
  FM_FAKE_AXI_STATUS_RUN=$(captured_axi_status superseded)
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'captured terminal output cannot validate a live selection'
  assert_contains "$out" '01NEW' 'the changing selected id is preserved'
  assert_contains "$out" '01OLD' 'the other available id is preserved'
  pass 'captured status formats reject a synthetic authority transition'
}

test_captured_completed_history() {
  local activity d out source
  for activity in busy idle; do
    make_historical_inventory_case "captured-history-$activity" "$activity"
    d=$TMP_ROOT/captured-history-$activity
    FM_FAKE_AXI_STATUS=$(captured_axi_status completed)
    FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
    source=pane; [ "$activity" = busy ] || source='status-log'
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" 'state: working' 'captured completion does not hide subsequent development'
    assert_contains "$out" "source: $source" 'captured historical validation yields to current worker evidence'
  done
  pass 'captured completed status yields to synthetic subsequent development'
}
