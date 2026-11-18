#!/usr/bin/env bash
# tests/fm-proc-lib.test.sh - harness process identity (bin/fm-proc-lib.sh).
#
# The cases drive the library's own query functions behind a deterministic fake
# ps, so both platforms' reporting semantics are covered from either host: macOS
# reports argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
# name and ignores argv[0] entirely.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-proc-lib)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-proc-lib.sh"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone (FM_TEST_KILL_RC=1
# makes every pid dead). The suite itself may run inside a Claude session whose
# CLAUDE_CODE_SESSION_ID and CLAUDE_PID would leak into the expression, so both
# are scrubbed and only FM_TEST_SESSION_ID and FM_TEST_CLAUDE_PID reach it.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a session_env=()
  [ -z "${FM_TEST_SESSION_ID:-}" ] || session_env+=("CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION_ID")
  [ -z "${FM_TEST_CLAUDE_PID:-}" ] || session_env+=("CLAUDE_PID=$FM_TEST_CLAUDE_PID")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${session_env[@]+"${session_env[@]}"} \
    PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
  done
  pass "a version-named Claude Code session is identified from its install path and argv[0]"
}

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  pass "a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_bun_run_omp_is_identified_on_both_platforms() {
  local comm fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/bun-omp")
  # macOS reports the executable path in comm, procps on Linux the exec name.
  for comm in bun /Users/u/.bun/bin/bun /opt/homebrew/bin/bun; do
    lib_eval "$fakebin" "fm_harness_process_matches '$comm' 'bun /Users/u/.bun/bin/omp'" \
      || fail "$comm running the omp launcher must be identified"
    if lib_eval "$fakebin" "fm_harness_process_matches '$comm' 'bun /Users/u/.bun/bin/ompd'"; then
      fail "$comm running ompd was identified as a harness"
    fi
  done
  pass "a bun-run omp script is identified under both platforms' comm reporting"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
  done
  pass "ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_is_never_the_session() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  # The out-of-run harness is live, but it is not this session's ancestry.
  lib_eval "$fakebin" 'fm_harness_pid_alive 920' \
    || fail "the unrelated harness beyond the gap was not recognized as a live harness"
  pass "ancestry stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin got
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session; this process descends from 650
  # instead. The walk must not adopt the other session, and liveness must
  # still report it alive.
  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the walk found no harness in this process's own ancestry"
  [ "$got" = 650 ] || fail "the walk resolved '$got', expected this session's own pid 650"
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as dead"
  pass "a live version-named session outside this ancestry is not adopted as this session"
}

cygwin_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'MINGW64_NT-10.0-26200'
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  # Cygwin's ps has no -o option at all; it fails the whole invocation.
  [ "$a" = "-o" ] && { echo "ps: unknown option -- o" >&2; exit 1; }
done
mode=p full=0 pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -W) mode=W; shift ;;
    -f) full=1; shift ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$mode" = W ]; then
  [ -z "${FM_TEST_WIN_PS_FAIL:-}" ] || { echo "ps: cannot read the Windows process table" >&2; exit 1; }
  printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
  [ -n "${FM_TEST_WIN_TABLE:-}" ] && printf '%s\n' "$FM_TEST_WIN_TABLE"
  exit 0
fi
# The Cygwin-side table. 700 is an MSYS-native harness; everything else is an
# ordinary shell whose parent link is severed exactly as the real ps reports it.
case "$pid" in
  700) comm='/opt/claude/versions/2.1.220'; ppid=1 ;;
  *)   comm='/usr/bin/bash'; ppid=${FM_TEST_CYG_PPID:-1} ;;
esac
if [ "$full" = 1 ]; then
  printf '%s\n' '     UID     PID    PPID  TTY        STIME COMMAND'
  printf 'u %s %s ? 00:00:00 %s\n' "$pid" "$ppid" "$comm"
else
  printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
  printf '%s %s %s 9999 ? 0 00:00:00 %s\n' "$pid" "$ppid" "$pid" "$comm"
fi
SH
  chmod +x "$fakebin/uname" "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# WINPID 7204 is the session harness. 4321 is an ordinary desktop process, and
# 5150 is the path-shaped lookalike that must never read as a harness.
WIN_TABLE='  4201508       0       0       7204  ?              0 22:24:48 C:\Users\u\.local\bin\claude.exe
  4198625       0       0       4321  ?              0 22:24:48 C:\Windows\explorer.exe
  4199454       0       0       5150  ?              0 22:24:48 C:\tools\claude-notes\helper.exe'

test_cygwin_ps_without_o_still_resolves_a_local_harness() {
  local dir fakebin got
  dir="$TMP_ROOT/cygwin-local"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # An MSYS-native harness lives in the same process table as this shell, so it
  # must resolve through the ordinary walk and stay an untagged pid. This is
  # what proves the walk survives a ps with no -o option at all.
  got=$(FM_TEST_CYG_PPID=700 FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_CLAUDE_PID=7204 \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "a harness in the local process table was not resolved when ps rejected -o"
  [ "$got" = 700 ] || fail "expected the untagged local harness pid 700, got '$got'"
  pass "a harness in the local process table resolves untagged when ps has no -o option"
}


test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_bun_run_omp_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_is_never_the_session
test_competing_version_named_session_is_seen_as_live
test_cygwin_ps_without_o_still_resolves_a_local_harness

echo "ALL PASS"
