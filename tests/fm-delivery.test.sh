#!/usr/bin/env bash
# Per-PR delivery decisions: durable record, resolution order, supersede/clear,
# yolo inheritance, and the spawn enforcement gate.
#
# Self-contained: one throwaway home, no fleet, no network, no backend.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-delivery-test.XXXXXX") || exit 1
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() { rm -rf "$HOME_DIR"; }
trap cleanup EXIT

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/bin"
printf '# fixture home\n' > "$HOME_DIR/AGENTS.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/bin/fm-session-start.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/bin/fm-spawn.sh"
chmod +x "$HOME_DIR/bin/"*.sh
cat > "$HOME_DIR/data/projects.md" <<'EOF'
# Projects

- demo [direct-PR +yolo] - Demo project (added 2026-11-16)
- gated [no-mistakes +yolo] - Gated project (added 2026-11-16)
- plain [no-mistakes] - Plain project (added 2026-11-16)
EOF

export FM_HOME="$HOME_DIR"
export FM_DATA_OVERRIDE="$HOME_DIR/data"
export FM_STATE_OVERRIDE="$HOME_DIR/state"
DELIVERY="$ROOT/bin/fm-delivery.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

FAILED=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; FAILED=1; }
check() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected '$2', got '$3')"; fi
}

field() { # <key=value output> <field>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# --- resolution: registry default -------------------------------------------------
out=$("$DELIVERY" resolve --task fm-x --project demo)
check 'registry posture resolves direct-PR on' 'direct-PR' "$(field "$out" mode)"
check 'registry yolo is reported' 'on' "$(field "$out" yolo)"
check 'registry source is reported' 'registry' "$(field "$out" delivery_source)"

out=$("$DELIVERY" resolve --task fm-unknown --project missing)
check 'unregistered project defaults to no-mistakes' 'no-mistakes' "$(field "$out" mode)"
check 'unregistered project defaults to yolo off' 'off' "$(field "$out" yolo)"
check 'unregistered project resolves through fm-project-mode' 'registry' "$(field "$out" delivery_source)"

# --- a PR decision turns the pipeline off for one PR ------------------------------
PR=https://github.com/example/repo/pull/12
"$DELIVERY" set --pr "$PR" --pipeline off --reason 'one-off skip' >/dev/null || not_ok 'set --pr --pipeline off'
out=$("$DELIVERY" resolve --pr "$PR" --project gated)
check 'PR record overrides a no-mistakes project' 'direct-PR' "$(field "$out" mode)"
check 'PR source is reported' 'pr' "$(field "$out" delivery_source)"
check 'PR reason is reported' 'one-off skip' "$(field "$out" reason)"
check 'inherited yolo comes from the registry' 'on' "$(field "$out" yolo)"
check 'inherited yolo source is the registry' 'registry' "$(field "$out" yolo_source)"

# --- a PR decision turns the pipeline on for a direct-PR project ------------------
PR2=https://github.com/example/repo/pull/13
"$DELIVERY" set --pr "$PR2" --mode no-mistakes >/dev/null || not_ok 'set --pr --mode no-mistakes'
out=$("$DELIVERY" resolve --pr "$PR2" --project demo)
check 'PR record can require the pipeline on a direct-PR project' 'no-mistakes' "$(field "$out" mode)"

# --- task records, and the task PR record they create ----------------------------
printf 'pr=%s\nbranch=fm/fm-task\n' "$PR2" > "$HOME_DIR/state/fm-task.meta"
"$DELIVERY" set --task fm-task --mode no-mistakes --reason 'gate this one' >/dev/null || not_ok 'set --task'
if [ -e "$HOME_DIR/data/delivery/pr-github.com_example_repo_13.record" ]; then
  ok 'a task decision writes its PR record when the task has a PR'
else
  not_ok 'a task decision writes its PR record when the task has a PR'
fi
out=$("$DELIVERY" resolve --task fm-task --project demo)
check 'task decision resolves by task' 'no-mistakes' "$(field "$out" mode)"
check 'task decision resolves through its PR record' 'pr' "$(field "$out" delivery_source)"

# --- PR record shadows a task record, visibly ------------------------------------
printf 'delivery=no-mistakes\nyolo=inherit\nreason=task-level\n' > "$HOME_DIR/data/delivery/task-fm-shadow.record"
SHADOW_PR=https://github.com/example/repo/pull/14
"$DELIVERY" set --pr "$SHADOW_PR" --pipeline off >/dev/null
out=$("$DELIVERY" resolve --task fm-shadow --pr "$SHADOW_PR" --project gated)
check 'PR record wins over the task record' 'direct-PR' "$(field "$out" mode)"
case "$(field "$out" shadowed)" in
  task:*) ok 'the losing task record is reported as shadowed' ;;
  *) not_ok 'the losing task record is reported as shadowed' ;;
esac

# --- explicit yolo in a record overrides the registry ----------------------------
PR3=https://github.com/example/repo/pull/15
"$DELIVERY" set --pr "$PR3" --mode no-mistakes --yolo off >/dev/null
out=$("$DELIVERY" resolve --pr "$PR3" --project gated)
check 'record yolo overrides the registry' 'off' "$(field "$out" yolo)"
check 'record yolo source is reported' 'pr' "$(field "$out" yolo_source)"

# --- clearing falls back to the next source --------------------------------------
"$DELIVERY" clear --task fm-task >/dev/null || not_ok 'clear --task'
out=$("$DELIVERY" resolve --task fm-task --project demo)
check 'after clear the registry applies again' 'direct-PR' "$(field "$out" mode)"

# --- list -----------------------------------------------------------------------
LIST=$("$DELIVERY" list)
case "$LIST" in
  *'pr-github.com_example_repo_12 delivery='*) ok 'list prints stored records' ;;
  *) not_ok 'list prints stored records' ;;
esac

# --- refusal paths --------------------------------------------------------------
if "$DELIVERY" set --pr not-a-pr --pipeline off >/dev/null 2>&1; then
  not_ok 'unusable PR URL is refused'
else
  ok 'unusable PR URL is refused'
fi
if "$DELIVERY" set --task fm-x --mode bogus >/dev/null 2>&1; then
  not_ok 'invalid mode is refused'
else
  ok 'invalid mode is refused'
fi
if "$DELIVERY" set --task 'bad id' --mode no-mistakes >/dev/null 2>&1; then
  not_ok 'invalid task id is refused'
else
  ok 'invalid task id is refused'
fi

# --- spawn enforcement ----------------------------------------------------------
printf 'pr=%s\nbranch=fm/fm-gate\n' "$PR" > "$HOME_DIR/state/fm-gate.meta"
"$DELIVERY" set --task fm-gate --mode no-mistakes --yolo off >/dev/null
spawn_out=$(FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" timeout 30 "$SPAWN" fm-gate /tmp/fm-delivery-demo --mode direct-PR --yolo off 2>&1)
spawn_code=$?
check 'spawn refuses a mode contradicting the decision' '1' "$spawn_code"
case "$spawn_out" in
  *'contradicts a durable delivery decision'*) ok 'spawn refusal names the decision' ;;
  *) not_ok "spawn refusal names the decision (got: $spawn_out)" ;;
esac

if "$DELIVERY" enforce-task fm-gate no-mistakes off >/dev/null 2>&1; then
  ok 'matching spawn values pass enforcement'
else
  not_ok 'matching spawn values pass enforcement'
fi
if "$DELIVERY" enforce-task fm-free direct-PR off >/dev/null 2>&1; then
  ok 'a task with no record passes enforcement'
else
  not_ok 'a task with no record passes enforcement'
fi

if [ "$FAILED" -eq 0 ]; then
  printf '# all fm-delivery tests passed\n'
  exit 0
fi
printf '# fm-delivery tests failed\n' >&2
exit 1
