#!/usr/bin/env bash
# tests/fm-spawn-orca-worktree.test.sh - the backend=orca removal boundary.
#
# This suite used to drive the Orca worktree carve-outs with a fake `orca` CLI
# and asserted that fresh spawns entered the worktree Orca created, that source
# mode carried a controlled environment, and that an unrun launch file was
# reclaimed. Backend=orca was removed from the opinionated stack: herdr is the
# only spawn-supported runtime backend. Those cases no longer have a subject.
# They are retired here rather than left red; the removal is pinned on the
# public spawn interface instead, so a future change cannot silently reintroduce
# a backend the stack no longer supports.
set -u

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-worktree)

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_treehouse_lease "$fakebin"
  fm_test_spawn_home "$home" "$FM_TEST_FIXTURE_HARNESS"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

test_removed_orca_backend_is_refused_before_any_resources() {
  local rec id=orca-removed idout status
  rec=$(make_case orca-removed "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  idout=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$CASE_DIR/user-home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX=fake,1,0 PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a removed backend must be refused: $idout"
  assert_contains "$idout" "backend 'orca' was removed" \
    "the refusal did not name the removed backend"
  assert_contains "$idout" "herdr is the only supported runtime backend" \
    "the refusal did not name the supported backend"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn published a task record"
  pass "the removed orca backend is refused before any endpoint or worktree is created"
}

test_removed_orca_backend_is_refused_on_relaunch() {
  local rec id=orca-relaunch-removed idout status
  rec=$(make_case orca-relaunch "$id")
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$WT_DIR"
    echo "project=$PROJ_DIR"
    echo "harness=$FM_TEST_FIXTURE_HARNESS"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "backend=orca"
  } > "$HOME_DIR/state/$id.meta"
  mkdir -p "$CASE_DIR/user-home"
  idout=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$CASE_DIR/user-home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX=fake,1,0 PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch on a removed backend must be refused: $idout"
  assert_contains "$idout" "records backend 'orca', which was removed" \
    "the relaunch refusal did not name the removed backend"
  pass "a relaunch on the removed orca backend is refused too"
}

test_removed_orca_backend_is_refused_on_relaunch

echo "# all fm-spawn-orca-worktree tests passed"
