# shellcheck shell=bash
# Test cases for fm-crew-state, split out of tests/fm-crew-state.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-crew-state.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
# Stamp origin/main at the current HEAD so a later ship done: is not refused
# solely for being a fixture with no remote-tracking refs; tests that need an
# unpreserved named head point those refs at a different commit.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse HEAD)"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi` (the identity overview), `axi status`,
# and `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    if [ "$#" = 0 ]; then
      printf '%s\n' "${FM_FAKE_AXI_HOME:-${FM_FAKE_AXI_STATUS:-}}"
      exit "${FM_FAKE_AXI_HOME_ERROR:-0}"
    fi
    case "${1:-}" in
      status)
        shift
        if [ -n "${FM_FAKE_STATUS_APPEND_FILE:-}" ] && [ ! -e "${FM_FAKE_STATUS_APPEND_MARKER:-}" ]; then
          : > "$FM_FAKE_STATUS_APPEND_MARKER"
          printf '%s\n' "$FM_FAKE_STATUS_APPEND_LINE" >> "$FM_FAKE_STATUS_APPEND_FILE"
        fi
        if [ "${1:-}" = --run ]; then
          run_id=${2:-}
          run_output="${FM_FAKE_AXI_STATUS_RUN:-}"
          if [ -n "$run_id" ]; then
            run_var="FM_FAKE_AXI_STATUS_RUN_$run_id"
            if [ -n "${!run_var+x}" ]; then
              run_output=${!run_var}
            fi
          fi
          printf '%s\n' "$run_output"
          exit "${FM_FAKE_AXI_STATUS_RUN_ERROR:-0}"
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
          exit "${FM_FAKE_AXI_STATUS_ERROR:-0}"
        fi ;;
      logs)
        shift
        # The real CLI prints only the last 40 log lines ("lines: 40 of N
        # total (tail)", verified against v1.79.0) unless --full asks for the
        # whole log, so a marker older than that is invisible to a plain read.
        full=0
        for arg in "$@"; do
          [ "$arg" = --full ] && full=1
        done
        if [ "$full" = 1 ]; then
          printf '%s\n' "${FM_FAKE_CI_LOGS:-}"
        else
          printf '%s\n' "${FM_FAKE_CI_LOGS:-}" | tail -40
        fi ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
  daemon)
    # FM_FAKE_DAEMON_DOWN: a missing/refused socket makes the probe fail.
    # A clean stop instead exits 0 and prints "○ daemon not running".
    # FM_FAKE_DAEMON_TIMEOUT: the probe does not answer at all, which is what
    # the bounded call reports as 124 when `timeout` kills a slow daemon status.
    [ -z "${FM_FAKE_DAEMON_PROBE_LOG:-}" ] || printf 'probe\n' >> "$FM_FAKE_DAEMON_PROBE_LOG"
    [ "${FM_FAKE_DAEMON_TIMEOUT:-0}" = 1 ] && exit 124
    if [ "${FM_FAKE_DAEMON_DOWN:-0}" = 1 ]; then
      printf '%s\n' "${FM_FAKE_DAEMON_OUTPUT-connection refused}" >&2
      exit 1
    fi
    printf '%s\n' "${FM_FAKE_DAEMON_OUTPUT-  ● daemon running (pid 4242)}"
    exit 0 ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "api graphql")
    [ -z "${FM_FAKE_PR_READ_LOG:-}" ] || printf 'gh\n' >> "$FM_FAKE_PR_READ_LOG"
    number=1
    for arg in "$@"; do
      case "$arg" in
        number=*) number=${arg#number=} ;;
      esac
    done
    case "$number" in *[!0-9]*|'') number=1 ;; esac
    state=${FM_FAKE_PR_STATE:-MERGED}
    merged=${FM_FAKE_PR_MERGED:-true}
    eval "state=\${FM_FAKE_PR_${number}_STATE:-\$state}"
    eval "merged=\${FM_FAKE_PR_${number}_MERGED:-\$merged}"
    [ "${FM_FAKE_PR_READ_FAIL:-0}" = 1 ] && exit 1
    printf 'state=%s\nmerged=%s\n' "$state" "$merged"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr view")
    [ -z "${FM_FAKE_PR_READ_LOG:-}" ] || printf 'gh-axi\n' >> "$FM_FAKE_PR_READ_LOG"
    [ "${FM_FAKE_PR_READ_FAIL:-0}" = 1 ] && exit 1
    printf 'pull_request:\n  number: %s\n  state: %s\n' "${3:-1}" "${FM_FAKE_PR_STATE_AXI:-merged}"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/glab" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "mr view")
    [ -z "${FM_FAKE_GLAB_READ_LOG:-}" ] || printf '%s|%s\n' "${GITLAB_HOST:-}" "$*" >> "$FM_FAKE_GLAB_READ_LOG"
    [ "${FM_FAKE_GLAB_READ_FAIL:-0}" = 1 ] && exit 1
    printf '{"state":"%s"}\n' "${FM_FAKE_GLAB_STATE:-merged}"
    exit 0 ;;
esac
exit 1
SH
  # tea answers its login list with one login for git.example.org and a pull
  # request read through "tea api" with the configured state; a read failure
  # prints the error body with exit 0, as the real tea api does.
  cat > "$fb/tea" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-} ${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "fj",\n    "url": "https://git.example.org"\n  }\n]\n'
  exit 0
fi
[ "${1:-}" = api ] || exit 1
[ -z "${FM_FAKE_TEA_READ_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TEA_READ_LOG"
if [ "${FM_FAKE_TEA_READ_FAIL:-0}" = 1 ]; then
  printf '{"message":"not found"}\n'
  exit 0
fi
printf '{"state":"%s","merged":%s,"head":{"sha":"abc"}}\n' \
  "${FM_FAKE_TEA_STATE:-closed}" "${FM_FAKE_TEA_MERGED:-true}"
SH
  cat > "$fb/gerrit-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  show)
    [ -z "${FM_FAKE_GERRIT_READ_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_GERRIT_READ_LOG"
    [ "${FM_FAKE_GERRIT_READ_FAIL:-0}" = 1 ] && exit 1
    # url defaults to null, the shape a server whose gerrit.canonicalWebUrl is
    # unset returns, so every case here reads a record that carries no URL.
    printf '{"ok":true,"op":"show","changes":[{"change":%s,"subject":"fixture change","status":"%s","url":%s}]}\n' \
      "${FM_FAKE_GERRIT_CHANGE:-${2:-0}}" "${FM_FAKE_GERRIT_STATUS:-MERGED}" \
      "${FM_FAKE_GERRIT_URL_JSON:-null}"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# FM_FAKE_TMUX_MISSING: the window is authoritatively gone - every addressed
# call fails, but the session inventory still answers successfully and simply
# omits the window, which is what proves absence.
# FM_FAKE_TMUX_UNREADABLE: tmux itself cannot answer - it fails to execute (a
# trimmed PATH) or errors non-definitively - so even the inventory fails, with
# a message that is NOT one of the definitive no-session/no-server/no-socket
# responses that fm_backend_tmux_agent_state owns as death.
[ "${FM_FAKE_TMUX_UNREADABLE:-0}" = 1 ] && { printf 'no current client\n' >&2; exit 1; }
case "${1:-}" in
  list-windows)
    if [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] || [ "${FM_FAKE_TMUX_WINDOW_GONE:-0}" = 1 ]; then
      printf 'other-window\n'
    else
      sed -n 's/^window=[^:]*://p' "${FM_STATE_OVERRIDE:?}"/*.meta 2>/dev/null
    fi ;;
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        [ "${FM_FAKE_HERDR_READ_FAIL:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
      get)
        if [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ]; then
          printf '{"error":{"code":"pane_not_found","message":"no such pane"}}\n'
          exit 1
        fi
        printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
        exit 0 ;;
      process-info)
        # The process-level view a registration is verified against (#4115):
        # `agent` puts a live claude in the foreground, `shell` a bare zsh whose
        # pid is the test script itself (a real, long-lived process with no
        # harness descendant, so the adapter's real process-table walk finds
        # it), and anything else answers nothing (unreadable).
        pane=""; args=("$@"); for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = --pane ] && pane=${args[$((i+1))]:-}; done
        case "${FM_FAKE_HERDR_PROCESS:-agent}" in
          agent) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":424242,"foreground_processes":[{"pid":424242,"name":"claude","argv0":"claude"}]}}}\n' "$pane" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" ;;
          shell) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}\n' "$pane" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" ;;
        esac
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        if [ "${FM_FAKE_HERDR_HUSK:-0}" = 1 ]; then
          printf '{"error":{"code":"agent_not_found","message":"no agent in pane"}}\n'
          exit 0
        fi
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/gh" "$fb/gh-axi" "$fb/glab" "$fb/tea" "$fb/gerrit-axi" "$fb/tmux" "$fb/herdr"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  NM_HOME="$TMP_ROOT/no-mistakes-unused"
  export NM_HOME
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_ERROR=0
  FM_FAKE_AXI_HOME=""
  FM_FAKE_AXI_HOME_ERROR=0
  FM_FAKE_AXI_STATUS_RUN_ERROR=0
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  FM_FAKE_BUSY_TEXT=
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_TMUX_WINDOW_GONE=0
  FM_FAKE_TMUX_UNREADABLE=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_READ_FAIL=0
  FM_FAKE_HERDR_HUSK=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_HERDR_PROCESS=agent
  FM_FAKE_HERDR_SHELL_PID=$$
  FM_FAKE_CI_LOGS=""
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_DAEMON_TIMEOUT=0
  FM_FAKE_DAEMON_OUTPUT='  ● daemon running (pid 4242)'
  FM_FAKE_DAEMON_PROBE_LOG=
  FM_FAKE_PR_STATE=MERGED
  FM_FAKE_PR_MERGED=true
  FM_FAKE_PR_READ_FAIL=0
  FM_FAKE_PR_READ_LOG=
  FM_FAKE_PR_STATE_AXI=merged
  FM_FAKE_GLAB_STATE=merged
  FM_FAKE_GLAB_READ_FAIL=0
  FM_FAKE_GLAB_READ_LOG=
  FM_FAKE_TEA_STATE=closed
  FM_FAKE_TEA_MERGED=true
  FM_FAKE_TEA_READ_FAIL=0
  FM_FAKE_TEA_READ_LOG=
  FM_FAKE_GERRIT_STATUS=MERGED
  FM_FAKE_GERRIT_CHANGE=
  FM_FAKE_GERRIT_URL_JSON=
  FM_FAKE_GERRIT_READ_FAIL=0
  FM_FAKE_GERRIT_READ_LOG=
  unset FM_FAKE_PR_47_STATE FM_FAKE_PR_47_MERGED FM_FAKE_PR_48_STATE FM_FAKE_PR_48_MERGED
  unset FM_FAKE_AXI_STATUS_RUN_01OLD FM_FAKE_AXI_STATUS_RUN_01NEW
  FM_FAKE_STATUS_APPEND_FILE=""
  FM_FAKE_STATUS_APPEND_MARKER=""
  FM_FAKE_STATUS_APPEND_LINE=""
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING FM_FAKE_TMUX_WINDOW_GONE FM_FAKE_TMUX_UNREADABLE
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_READ_FAIL FM_FAKE_HERDR_HUSK FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_HERDR_PROCESS FM_FAKE_HERDR_SHELL_PID FM_FAKE_CI_LOGS
  export FM_FAKE_DAEMON_DOWN FM_FAKE_DAEMON_TIMEOUT FM_FAKE_DAEMON_PROBE_LOG FM_FAKE_AXI_HOME
  export FM_FAKE_DAEMON_OUTPUT
  export FM_FAKE_AXI_HOME_ERROR FM_FAKE_AXI_STATUS_RUN_ERROR FM_FAKE_AXI_STATUS_ERROR
  export FM_FAKE_AXI_STATUS_RUN_01OLD FM_FAKE_AXI_STATUS_RUN_01NEW
  export FM_FAKE_PR_STATE FM_FAKE_PR_MERGED FM_FAKE_PR_READ_FAIL FM_FAKE_PR_READ_LOG FM_FAKE_PR_STATE_AXI
  export FM_FAKE_GLAB_STATE FM_FAKE_GLAB_READ_FAIL FM_FAKE_GLAB_READ_LOG
  export FM_FAKE_TEA_STATE FM_FAKE_TEA_MERGED FM_FAKE_TEA_READ_FAIL FM_FAKE_TEA_READ_LOG
  export FM_FAKE_GERRIT_STATUS FM_FAKE_GERRIT_CHANGE FM_FAKE_GERRIT_URL_JSON
  export FM_FAKE_GERRIT_READ_FAIL FM_FAKE_GERRIT_READ_LOG
  export FM_FAKE_PR_47_STATE FM_FAKE_PR_47_MERGED FM_FAKE_PR_48_STATE FM_FAKE_PR_48_MERGED
  export FM_FAKE_STATUS_APPEND_FILE FM_FAKE_STATUS_APPEND_MARKER FM_FAKE_STATUS_APPEND_LINE
}

seed_retired_pr_receipt() {  # <state> <id> <url>
  local state=$1 id=$2 url=$3 template provider host path number
  template="$ROOT/bin/fm-pr-poll.sh"
  fm_pr_url_parse "$url" || fail "retirement fixture URL was invalid"
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  fm_pr_poll_prepare "$state" "$id" "$provider" "$url" "$host" "$path" "$number" "$template" \
    || fail "could not prepare retirement fixture"
  fm_pr_poll_publish_prepared || fail "could not publish retirement fixture"
  fm_pr_poll_snapshot_capture "$state" "$id" "$template" || fail "could not snapshot retirement fixture"
  fm_pr_poll_retirement_publish "$state" "$id" "$template" merged \
    || fail "could not publish retirement receipt"
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

# A fixing run whose active step reports FRESH activity. `axi status` emits the
# active_steps table only while a step is running or fixing, and leaves
# last_activity unprefixed while step-log or agent lifecycle events keep
# arriving - that is the client's own recency verdict.
run_fixing_active_recent() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,12m3s,8s,44121,"auto-fix 1/3"
EOF
}

# The same run gone QUIET: the client prefixes last_activity with `quiet` once
# nothing has arrived for longer than its configured quiet warning. This is the
# shape a run record keeps when the daemon really did die under it.
run_fixing_active_quiet() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,42m8s,"quiet 31m2s",44121,"auto-fix 1/3"
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

# A gate owed the CREWMATE's own answer: every finding's `action` column is
# auto-fix. The free-text `description` column is where this repository's own
# review output routinely quotes finding actions, so one row spells the token out
# the way an enumeration does - surrounded by commas, in the exact shape a
# substring or unanchored-regex derivation would accept - and the branch name
# carries it too. Both are the counterexample: the ONLY thing that may mint the
# human-decision component is the `action` column read by position.
run_parked_crewmate_gate_with_ask_user_prose() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fix_review
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,the action field is one of no-op, auto-fix, ask-user, so pick one
    r2,warning,b.go,,auto-fix,ignored error
gate: review
EOF
}

# The same gate with the findings table's columns in a different order, so the
# derivation is proven to read the column INDEX out of the header rather than
# assuming action is the fifth field. Only the last row is owed a human.
run_parked_reordered_columns() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{severity,action,id,file,line,description}:
    warning,auto-fix,r1,a.go,,ignored error
    error,ask-user,r2,b.go,,changes product behavior
gate: review
EOF
}

# The same crewmate-owed gate with `description` placed BEFORE `action` in the
# header. Every row's real action column is auto-fix, but one description spells
# the token out surrounded by commas at exactly the comma offset the `action`
# index lands on, so a derivation that reads the index from the header and then
# walks raw commas to it accepts free text as the action. The table's shape is
# not provably safe here, so the only correct answer is to keep the ladder.
run_parked_free_text_before_action() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fix_review
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,description,action}:
    r1,warning,a.go,12,the action field is one of auto-fix, ask-user,auto-fix
gate: review
EOF
}

# The same crewmate-owed gate preceded by an UNBRACED `findings[N]:` block from
# an earlier, already-resolved round. The braced header that follows is the live
# gate's table and is the one the column index is read from, so the rows walked
# must be that table's rows too. An earlier block carrying `ask-user` at the very
# comma offset the braced header's `action` index resolves to is the counter-
# example: a row scan that anchors on the looser unbraced pattern reads the wrong
# block's rows at the right block's index, and mints the component for a gate
# whose every action is auto-fix.
run_parked_unbraced_findings_precursor() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fix_review
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]:
    prior-1,warning,a.go,ask-user,an earlier already-resolved block
    prior-2,info,b.go,ask-user,another earlier row
  findings[1]{id,severity,file,action,description}:
    r1,warning,a.go,auto-fix,the live gate is owed to the crewmate
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

run_passed_with_override() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed-with-override
ci_override_reason: "live checks not all passed: Lint (fail)"
EOF
}

run_passed_with_skips() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed-with-skips
automatic_skips: "publication skipped: no-mistakes.yaml pr.enabled=false"
EOF
}

run_passed_with_pr() {  # <branch> <pr-url>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "$2"
  findings: none
outcome: passed
EOF
}

run_passed_no_pr() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: passed
EOF
}

run_failed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: failed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
EOF
}

# The 2026-09-05 jr-voice orphaned-CI-monitor shape: every substantive step
# completed, only ci failed (after the shared daemon restarted under its
# merge poll), and GitHub read the PR green and mergeable.
run_failed_ci_orphan() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: failed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/203"
  findings: none
outcome: failed
steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,0
  rebase,completed,0,0
  review,completed,0,0
  test,completed,0,0
  document,completed,0,0
  lint,completed,0,0
  push,completed,0,0
  pr,completed,0,0
  ci,failed,0,76127890
EOF
}

# Same shape but with no outcome line: only top-level status reads failed.
run_failed_ci_orphan_status_only() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: failed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/203"
  findings: none
steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,0
  rebase,completed,0,0
  review,completed,0,0
  test,completed,0,0
  document,completed,0,0
  lint,completed,0,0
  push,completed,0,0
  pr,completed,0,0
  ci,failed,0,76127890
EOF
}

# A second failed step (lint) disqualifies the orphaned-monitor reclassification.
run_failed_ci_orphan_second_failure() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: failed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/203"
  findings: none
steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,0
  rebase,completed,0,0
  review,completed,0,0
  test,completed,0,0
  document,completed,0,0
  lint,failed,0,0
  push,completed,0,0
  pr,completed,0,0
  ci,failed,0,76127890
EOF
}

run_failed_with_pr() {  # <branch> <pr>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: failed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "$2"
  findings: none
outcome: failed
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-b)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-bb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bb.meta" "window=fm:fm-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bb)"
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# A crew whose drive call timed out or was killed by its harness command limit
# routinely blocks claiming the pipeline died. The daemon accepts `respond`
# immediately and runs the fix round in the background, so such a claim over a
# run that is fixing WITH fresh activity is contradicted by the run itself: the
# supervisor answer is to steer a reattach, not to escalate a dead pipeline.
test_daemon_claim_over_live_run_reads_run_alive() {
  reset_fakes
  local d; d=$(new_case daemon-claim-live)
  make_repo_on_branch "$d/wt" fm/feat-dl
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dl.meta" "window=fm:fm-feat-dl" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon unreachable, drive run: read response: i/o timeout\n' \
    > "$d/state/feat-dl.status"
  FM_FAKE_AXI_STATUS="$(run_fixing_active_recent fm/feat-dl)"
  local out; out=$(run_crew_state "$d" feat-dl)
  assert_contains "$out" "state: working" "live run beats the crew's death claim"
  assert_contains "$out" "source: run-step" "live run -> run-step source"
  assert_contains "$out" "run alive" "daemon claim over a live run is named as run alive"
  assert_contains "$out" "reattach" "the reading names the reattach steer"
  assert_not_contains "$out" "superseded by active run" \
    "the daemon claim gets the sharper reading, not the generic one"
  pass "daemon/timeout blocked claim over a live fixing run reads as run alive"
}

# A genuine refused socket outranks the persisted fixing record, which can
# survive after the daemon exits.
test_socket_refusal_over_stale_fixing_run_reports_blocked() {
  reset_fakes
  local d; d=$(new_case daemon-socket-refused)
  make_repo_on_branch "$d/wt" fm/feat-dq
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dq.meta" "window=fm:fm-feat-dq" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon socket refused connections\n' \
    > "$d/state/feat-dq.status"
  FM_FAKE_AXI_STATUS="$(run_fixing_active_quiet fm/feat-dq)"
  local out; out=$(run_crew_state "$d" feat-dq)
  assert_contains "$out" "state: blocked" "socket refusal outranks a stale fixing record"
  assert_contains "$out" "source: status-log" "socket refusal remains status-log evidence"
  assert_contains "$out" "socket refused connections" "socket failure is preserved"
  assert_not_contains "$out" "run alive" "stale fixing record is not reported alive"

  # Exercise the exact alternate wordings emitted by the generated crew rule.
  printf 'blocked: no-mistakes daemon socket refuses connections\n' \
    > "$d/state/feat-dq.status"
  out=$(run_crew_state "$d" feat-dq)
  assert_contains "$out" "state: blocked" "socket-refuses wording outranks a stale fixing record"
  assert_not_contains "$out" "state: working" "socket-refuses wording cannot be suppressed by a stale active record"

  printf 'blocked: no-mistakes daemon socket is missing\n' \
    > "$d/state/feat-dq.status"
  out=$(run_crew_state "$d" feat-dq)
  assert_contains "$out" "state: blocked" "missing socket outranks a stale fixing record"
  assert_contains "$out" "source: status-log" "missing socket remains status-log evidence"
  assert_not_contains "$out" "state: working" "missing socket cannot be suppressed by a stale active record"
  pass "socket refusal or missing socket over a stale fixing run reports blocked"
}

# A terminal run record can be the final persisted state after the daemon exits.
# Positive socket-failure evidence must not be discarded merely because that
# attributed record no longer has an active status.
test_socket_refusal_over_terminal_run_reports_blocked() {
  reset_fakes
  local d; d=$(new_case daemon-socket-refused-terminal)
  make_repo_on_branch "$d/wt" fm/feat-dqt
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dqt.meta" "window=fm:fm-feat-dqt" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon socket refused connections\n' \
    > "$d/state/feat-dqt.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-dqt)"
  local out; out=$(run_crew_state "$d" feat-dqt)
  assert_contains "$out" "state: blocked" "socket refusal outranks a terminal run record"
  assert_contains "$out" "source: status-log" "terminal run cannot suppress socket-failure evidence"
  assert_not_contains "$out" "state: failed" "terminal run state is not emitted over socket-failure evidence"
  pass "socket refusal over a terminal attributed run reports blocked"
}

# The same override against a POPULATED ledger, the shape rule 2b's precedence
# block reads. The daemon answers another crew's run, so this crew resolves
# coarsely from its own newest ledger row at the worktree head - a terminal
# failed row - while its socket-down blocker is still the log's latest event.
# An instrument failure must not read as work failure, so the blocker wins.
test_socket_refusal_outranks_a_ledger_resolved_terminal_run() {
  reset_fakes
  local d short out
  d=$(new_case daemon-socket-refused-ledger)
  make_repo_on_branch "$d/wt" fm/feat-dql
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dql.meta" "window=fm:fm-feat-dql" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon socket refused connections\n' \
    > "$d/state/feat-dql.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-dql ${short}  $(ledger_stamp_minutes_ago 60)"
  out=$(run_crew_state "$d" feat-dql)
  assert_contains "$out" "state: blocked" "socket refusal outranks a ledger-resolved terminal run"
  assert_contains "$out" "source: status-log" "the override remains status-log evidence"
  assert_contains "$out" "daemon socket down despite attributed run record" "the override names its reason"
  assert_not_contains "$out" "state: failed" "a dead instrument must not be published as a work failure"
  pass "socket refusal outranks a ledger-resolved terminal run"
}

# The socket-down override is evidence about the log's CURRENT tip, not a latch:
# once the crew appends any later event the attributed run is the better witness.
test_socket_refusal_override_expires_when_the_crew_moves_on() {
  reset_fakes
  local d out
  d=$(new_case daemon-socket-refused-superseded)
  make_repo_on_branch "$d/wt" fm/feat-ds
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ds.meta" "window=fm:fm-feat-ds" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon socket is missing\n' > "$d/state/feat-ds.status"
  FM_FAKE_AXI_STATUS="$(run_fixing_active_recent fm/feat-ds)"
  out=$(run_crew_state "$d" feat-ds)
  assert_contains "$out" "state: blocked" "socket-down as the latest event still outranks a live run"
  assert_contains "$out" "source: status-log" "the override remains status-log evidence"
  assert_contains "$out" "daemon socket down despite attributed run record" "the override names its reason"

  printf 'working: reattached and continuing\n' >> "$d/state/feat-ds.status"
  out=$(run_crew_state "$d" feat-ds)
  assert_contains "$out" "state: working" "a later working event hands the reading back to the live run"
  assert_contains "$out" "source: run-step" "the superseded override no longer emits status-log state"
  assert_not_contains "$out" "daemon socket down despite attributed run record" \
    "a stale socket-down blocker cannot override a live run forever"

  # The later event does not have to be one the decision fold accepts. A blocked
  # line on a reserved key whose note does not speak that namespace is folded as
  # ordinary status, so the socket-down blocker stays the reconciled declaration
  # while the tip of the log has moved on; the override reads the tip, not the
  # declaration, so the stale daemon evidence stays retired.
  printf 'blocked: no-mistakes daemon socket is missing\nblocked [key=pending-reply-t3]: still waiting on the answer\n' \
    > "$d/state/feat-ds.status"
  out=$(run_crew_state "$d" feat-ds)
  assert_contains "$out" "state: working" "a later unfolded blocked event also hands the reading back to the run"
  assert_contains "$out" "source: run-step" "the retired override emits no status-log state"
  assert_not_contains "$out" "daemon socket down despite attributed run record" \
    "an unrelated later blocker cannot republish stale socket-down evidence"
  pass "socket-down evidence outranks a live run only while it is the log's latest event"
}

# And the claim half: an ordinary blocked line over the same live run keeps the
# generic reading, so the sharper one cannot fire on every superseded block.
test_ordinary_blocked_over_live_run_keeps_plain_superseded() {
  reset_fakes
  local d; d=$(new_case ordinary-blocked-live)
  make_repo_on_branch "$d/wt" fm/feat-ob
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ob.meta" "window=fm:fm-feat-ob" "worktree=$d/wt" "kind=ship"
  printf 'blocked: database upload failed with broken pipe\n' > "$d/state/feat-ob.status"
  FM_FAKE_AXI_STATUS="$(run_fixing_active_recent fm/feat-ob)"
  local out; out=$(run_crew_state "$d" feat-ob)
  assert_contains "$out" "state: working" "ordinary blocked log over an active run -> working"
  assert_contains "$out" "superseded by active run" "ordinary blocked keeps the generic reading"
  assert_not_contains "$out" "run alive" "broken pipe is not a pipeline-unreachable alias"
  pass "broken-pipe blocker over a live run keeps the plain superseded reading"
}

# The genuine daemon-down case still reaches the supervisor as blocked: the
# socket refused connections and no run is executing anywhere.
test_genuine_daemon_down_reports_blocked() {
  reset_fakes
  local d; d=$(new_case daemon-down)
  make_repo_on_branch "$d/wt" fm/feat-dd
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dd.meta" "window=fm:fm-feat-dd" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: no-mistakes daemon socket refused connections\n' > "$d/state/feat-dd.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-dd
  local out; out=$(run_crew_state "$d" feat-dd)
  assert_contains "$out" "state: blocked" "a genuine daemon-down claim with no run stays blocked"
  assert_contains "$out" "source: status-log" "no run -> status-log source"
  assert_not_contains "$out" "run alive" "nothing is alive to report"
  pass "genuine daemon-down blocked line still reports blocked"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces ask-user finding"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

# Which HUMAN owes a parked gate its answer is the distinction the watcher's
# wedge deferral rests on, so the component that carries it must come from the
# findings table's `action` column and from nothing else. Both directions, plus
# the counterexample a text match would have accepted.
test_parked_human_decision_comes_from_the_action_column() {
  local d out
  reset_fakes
  d=$(new_case parked-ask-user-action-column)
  make_repo_on_branch "$d/wt" fm/feat-au
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-au.meta" "window=fm:fm-feat-au" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-au.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-au)"
  out=$(run_crew_state "$d" feat-au)
  assert_contains "$out" "state: parked" "an ask-user row still reports parked"
  assert_contains "$out" " · ask-user: authority decision" \
    "an action column of ask-user mints the human-decision component"

  # The counterexample. Nothing here is owed a human: every action column is
  # auto-fix. A description enumerating the action values, and a branch named
  # after the same token, must not mint the component - a crewmate that goes
  # quiet before answering its own gate has to keep the wedge ladder.
  reset_fakes
  d=$(new_case parked-ask-user-prose-only)
  make_repo_on_branch "$d/wt" fm/ask-user-authority-fix
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ap.meta" "window=fm:fm-feat-ap" "worktree=$d/wt" "kind=ship"
  printf 'working: validation under way\n' > "$d/state/feat-ap.status"
  FM_FAKE_AXI_STATUS="$(run_parked_crewmate_gate_with_ask_user_prose fm/ask-user-authority-fix)"
  # Guard the counterexample against going vacuous: the payload this gate is read
  # from must really contain the token in a position a substring or unanchored
  # regex would accept, or the case below proves nothing.
  assert_contains "$FM_FAKE_AXI_STATUS" ", ask-user," \
    "the counterexample payload must carry the token where a naive match accepts it"
  assert_contains "$FM_FAKE_AXI_STATUS" "branch: fm/ask-user-authority-fix" \
    "the counterexample payload must also carry the token in its branch name"
  out=$(run_crew_state "$d" feat-ap)
  assert_contains "$out" "state: parked" "a crewmate-owed gate still reports parked"
  assert_not_contains "$out" " · ask-user: authority decision" \
    "free text and a branch name must not mint the human-decision component"

  # Column order is read from the header, not assumed.
  reset_fakes
  d=$(new_case parked-ask-user-reordered)
  make_repo_on_branch "$d/wt" fm/feat-ar
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ar.meta" "window=fm:fm-feat-ar" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-ar.status"
  FM_FAKE_AXI_STATUS="$(run_parked_reordered_columns fm/feat-ar)"
  out=$(run_crew_state "$d" feat-ar)
  assert_contains "$out" " · ask-user: authority decision" \
    "the action column is located by header index, not by fixed position"

  # A header index alone is not enough, because the row is split on raw commas.
  # With `description` ahead of `action` the comma walk lands inside free text,
  # so a gate whose every action is auto-fix would mint the component. The table
  # is not provably safe to walk, so the derivation must refuse and the crewmate
  # must keep the wedge ladder.
  reset_fakes
  d=$(new_case parked-free-text-before-action)
  make_repo_on_branch "$d/wt" fm/feat-af
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-af.meta" "window=fm:fm-feat-af" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-af.status"
  FM_FAKE_AXI_STATUS="$(run_parked_free_text_before_action fm/feat-af)"
  # Non-vacuity: the payload must really carry the token at the comma offset the
  # `action` index resolves to, or the case below proves nothing.
  assert_contains "$FM_FAKE_AXI_STATUS" "findings[1]{id,severity,file,line,description,action}:" \
    "the fixture must really place free text before the action column"
  assert_contains "$FM_FAKE_AXI_STATUS" ", ask-user," \
    "the fixture description must carry the token where the comma walk would accept it"
  out=$(run_crew_state "$d" feat-af)
  assert_contains "$out" "state: parked" "an unsafe findings header still reports parked"
  assert_not_contains "$out" " · ask-user: authority decision" \
    "a findings header that puts free text before action must not mint the human-decision component"

  # The header and the rows must come from the SAME block. An earlier unbraced
  # `findings[N]:` block ahead of the live gate's braced table would otherwise
  # supply the rows while the braced header supplies the count and the `action`
  # index, so the walk reads the wrong rows at the right index. Here that earlier
  # block carries ask-user at exactly that offset while the live gate's only row
  # is auto-fix: the crewmate owes this gate its own answer and must keep the
  # wedge ladder.
  reset_fakes
  d=$(new_case parked-unbraced-findings-precursor)
  make_repo_on_branch "$d/wt" fm/feat-ub
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ub.meta" "window=fm:fm-feat-ub" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-ub.status"
  FM_FAKE_AXI_STATUS="$(run_parked_unbraced_findings_precursor fm/feat-ub)"
  # Non-vacuity: the payload must really carry an unbraced findings block ahead
  # of the braced one, with the token at the offset the walk would land on.
  assert_contains "$FM_FAKE_AXI_STATUS" "findings[2]:" \
    "the fixture must really place an unbraced findings block before the gate's table"
  assert_contains "$FM_FAKE_AXI_STATUS" ",ask-user," \
    "the earlier block must carry the token where the wrong-block walk would accept it"
  out=$(run_crew_state "$d" feat-ub)
  assert_contains "$out" "state: parked" "an unbraced findings precursor still reports parked"
  assert_not_contains "$out" " · ask-user: authority decision" \
    "rows from an earlier unbraced findings block must not mint the human-decision component"
  pass "the parked human-decision component is derived from the findings table's action column"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" fm/feat-cs
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cs.meta" "window=fm:fm-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" fm/feat-cb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cb.meta" "window=fm:fm-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crew never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

test_ci_monitoring_no_checks_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: working" "a PR with no CI checks -> working"
  assert_not_contains "$out" "checks green" "a PR with no CI checks is not checks green"
  assert_contains "$out" "no CI checks" "the detail names the real condition"
  pass "a PR with no CI checks reported is not read as checks green"
}

# The crew's own "done: ... checks green" report must not be promoted by the
# status-log override when the ci log says no check ever reported.
test_ci_no_checks_status_log_override_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-status-log)
  make_repo_on_branch "$d/wt" fm/feat-cinocheckssl
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinocheckssl.meta" "window=fm:fm-feat-cinocheckssl" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cinocheckssl.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinocheckssl)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cinocheckssl)
  assert_contains "$out" "state: working" "crew-reported green with no CI checks -> working"
  assert_not_contains "$out" "source: status-log" "no-checks must not reach the status-log override"
  pass "status-log override refuses a PR with no CI checks"
}

# The monitor logs a checks state only when it changes, and a base-branch
# advance re-arms only its idle timeout, so a green PR on a busy base ends its
# ci log with re-arm lines (the 2026-09-22 PR #5317 shape: green, then main
# advanced while it waited for merge). The green marker before them is current.
test_ci_monitoring_green_then_rearm_stays_green() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
base branch advanced (bbbbbbb..ccccccc), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: done" "a base-advance re-arm after green keeps the PR green"
  assert_contains "$out" "source: run-step" "re-armed green monitoring stays run-step sourced"
  assert_contains "$out" "checks green: PR ready for review" "re-armed green monitoring reads held for merge"
  assert_contains "$out" "https://github.com/o/r/pull/2" "the held-for-merge reading names the run's PR"
  assert_not_contains "$out" "state: working" "a re-arm line must not read as checks not ready"
  pass "base-advance re-arm after green stays checks green"
}

# The same green-then-re-arm shape, but monitored long enough that the base
# advanced past the CLI's 40-line log tail: `axi logs` without --full would
# answer with re-arm lines only, hiding the green marker entirely, and the
# green PR would read as still working for as long as main kept moving.
test_ci_monitoring_green_before_log_tail_stays_green() {
  reset_fakes
  local d; d=$(new_case ci-green-beyond-tail)
  make_repo_on_branch "$d/wt" fm/feat-citail
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-citail.meta" "window=fm:fm-feat-citail" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-citail)"
  FM_FAKE_CI_LOGS=$({
    printf 'monitoring CI for PR #2 (timeout: 4h0m0s)...\n'
    printf 'all CI checks passed - still monitoring until merged or closed\n'
    for i in $(seq 1 60); do
      printf 'base branch advanced (%07d..%07d), re-arming CI monitor timeout\n' "$i" "$((i + 1))"
    done
  })
  local out; out=$(run_crew_state "$d" feat-citail)
  assert_contains "$out" "state: done" "a green marker older than the log tail still reads green"
  assert_contains "$out" "source: run-step" "the full-log green reading stays run-step sourced"
  assert_contains "$out" "checks green: PR ready for review" "the full-log reading is held for merge"
  assert_contains "$out" "https://github.com/o/r/pull/2" "the full-log reading names the run's PR"
  assert_not_contains "$out" "state: working" "a truncated ci log must not hide a green PR"
  pass "a green marker before the ci log tail still surfaces done"
}

NO_CI_SENTENCE="repository declares no CI (no_ci: true) - treating as all checks passed - still monitoring until merged or closed"

test_ci_monitoring_no_ci_declared_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-noci)
  make_repo_on_branch "$d/wt" fm/feat-cinoci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinoci.meta" "window=fm:fm-feat-cinoci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinoci)"
  FM_FAKE_CI_LOGS="$NO_CI_SENTENCE"
  local out; out=$(run_crew_state "$d" feat-cinoci)
  assert_contains "$out" "state: working" "a no_ci repository -> working"
  assert_contains "$out" "repository declares no CI" "the detail names the no_ci condition"
  assert_not_contains "$out" "validating (running)" "a parked no_ci run is not validating"
  assert_not_contains "$out" "checks green" "a no_ci repository is not checks green"
  pass "a no_ci ci-monitor marker reads as unverified, not validating"
}

test_ci_no_ci_status_log_override_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-noci-status-log)
  make_repo_on_branch "$d/wt" fm/feat-cinocisl
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinocisl.meta" "window=fm:fm-feat-cinocisl" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cinocisl.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinocisl)"
  FM_FAKE_CI_LOGS="$NO_CI_SENTENCE"
  local out; out=$(run_crew_state "$d" feat-cinocisl)
  assert_contains "$out" "state: working" "crew-reported green on a no_ci repository -> working"
  assert_not_contains "$out" "source: status-log" "no_ci must not reach the status-log override"
  pass "status-log override refuses a no_ci repository"
}

test_ci_no_ci_then_red_marker_is_not_ready() {
  reset_fakes
  local d; d=$(new_case ci-noci-red)
  make_repo_on_branch "$d/wt" fm/feat-cinocired
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinocired.meta" "window=fm:fm-feat-cinocired" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cinocired.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinocired)"
  FM_FAKE_CI_LOGS=$(printf '%s\nCI checks failed: build\n' "$NO_CI_SENTENCE")
  local out; out=$(run_crew_state "$d" feat-cinocired)
  assert_contains "$out" "state: working" "a red marker after the no_ci sentence -> working"
  assert_not_contains "$out" "state: done" "a red marker after the no_ci sentence is not done"
  assert_not_contains "$out" "repository declares no CI" "the last marker wins over the no_ci sentence"
  pass "a red marker after the no_ci sentence reads not ready"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the ci log wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative
test_terminal_passed() {
  reset_fakes
  local d; d=$(new_case passed)
  make_repo_on_branch "$d/wt" fm/feat-d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-d)"
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  assert_contains "$out" "run passed: PR merged" "passed run reports merged only after the PR record says merged"
  assert_not_contains "$out" "merged/closed" "passed merged PR must not keep the old ambiguous label"
  pass "terminal passed run is authoritative"
}

test_terminal_passed_with_override() {
  reset_fakes
  local d; d=$(new_case passed-with-override)
  make_repo_on_branch "$d/wt" fm/feat-override
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-override.meta" "window=fm:fm-feat-override" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_with_override fm/feat-override)"
  local out; out=$(run_crew_state "$d" feat-override)
  assert_contains "$out" "state: done" "passed-with-override run -> done, not unknown"
  assert_contains "$out" "source: run-step" "passed-with-override -> run-step source"
  assert_contains "$out" "run passed: PR merged" "passed-with-override run reports merged only after the PR record says merged"
  assert_not_contains "$out" "state: unknown" "passed-with-override must not fall through to unknown"
  assert_not_contains "$out" "outcome: passed-with-override" "passed-with-override must not surface as a raw unmapped outcome detail"
  pass "terminal passed-with-override run reads done like a clean pass"
}

test_terminal_passed_with_skips() {
  reset_fakes
  local d; d=$(new_case passed-with-skips)
  make_repo_on_branch "$d/wt" fm/feat-skips
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-skips.meta" "window=fm:fm-feat-skips" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_with_skips fm/feat-skips)"
  local out; out=$(run_crew_state "$d" feat-skips)
  assert_contains "$out" "state: done" "passed-with-skips run -> done, not unknown"
  assert_contains "$out" "source: run-step" "passed-with-skips -> run-step source"
  assert_contains "$out" "run passed: PR merged" "passed-with-skips run reports merged only after the PR record says merged"
  assert_contains "$out" "publication/CI verification skipped" "passed-with-skips keeps the skip visible, unlike a clean pass"
  assert_not_contains "$out" "state: unknown" "passed-with-skips must not fall through to unknown"
  assert_not_contains "$out" "outcome: passed-with-skips" "passed-with-skips must not surface as a raw unmapped outcome detail"
  pass "terminal passed-with-skips run reads done with the skip kept visible"
}

test_terminal_passed_uses_matching_retirement_receipt_without_forge() {
  reset_fakes
  local d url read_log out
  d=$(new_case passed-receipt)
  url=https://github.com/o/r/pull/1
  make_repo_on_branch "$d/wt" fm/feat-dreceipt
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dreceipt.meta" "window=fm:fm-feat-dreceipt" \
    "worktree=$d/wt" "kind=ship" "pr=$url"
  seed_retired_pr_receipt "$d/state" feat-dreceipt "$url"
  read_log="$d/pr-read.log"
  : > "$read_log"
  FM_FAKE_PR_READ_LOG=$read_log
  FM_FAKE_PR_READ_FAIL=1
  FM_FAKE_AXI_STATUS="$(run_passed_no_pr fm/feat-dreceipt)"
  out=$(run_crew_state "$d" feat-dreceipt)
  assert_contains "$out" "state: done" "passed run with retired PR receipt -> done"
  assert_contains "$out" "run passed: PR merged" "matching retirement receipt is local merged evidence"
  [ ! -s "$read_log" ] || fail "matching retirement receipt still attempted a forge read"
  pass "terminal passed run uses matching retirement receipt without forge"
}

test_terminal_passed_no_forge_switch_skips_read_but_keeps_receipt() {
  reset_fakes
  local d url read_log out
  d=$(new_case passed-no-forge-switch)
  url=https://github.com/o/r/pull/1
  make_repo_on_branch "$d/wt" fm/feat-dnoforge
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dnoforge.meta" "window=fm:fm-feat-dnoforge" \
    "worktree=$d/wt" "kind=ship" "pr=$url"
  read_log="$d/pr-read.log"
  : > "$read_log"
  FM_FAKE_PR_READ_LOG=$read_log
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dnoforge "$url")"

  out=$(FM_CREW_STATE_NO_FORGE=1 run_crew_state "$d" feat-dnoforge)
  assert_contains "$out" "run passed: PR state unknown (forge read skipped)" "no-forge mode reports skipped read"
  assert_not_contains "$out" "PR merged" "no-forge mode without a receipt must not report merged"
  [ ! -s "$read_log" ] || fail "no-forge mode invoked a forge read"

  seed_retired_pr_receipt "$d/state" feat-dnoforge "$url"
  out=$(FM_CREW_STATE_NO_FORGE=1 run_crew_state "$d" feat-dnoforge)
  assert_contains "$out" "run passed: PR merged" "no-forge mode still trusts a matching retirement receipt"
  [ ! -s "$read_log" ] || fail "no-forge mode with a receipt invoked a forge read"
  pass "terminal passed no-forge mode preserves local receipt evidence"
}

test_terminal_passed_with_open_pr_does_not_claim_merged() {
  reset_fakes
  local d; d=$(new_case passed-open-pr)
  make_repo_on_branch "$d/wt" fm/feat-dopen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dopen.meta" "window=fm:fm-feat-dopen" \
    "worktree=$d/wt" "kind=ship" "pr=https://github.com/o/r/pull/1"
  FM_FAKE_PR_STATE=OPEN
  FM_FAKE_PR_MERGED=false
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dopen)"
  local out; out=$(run_crew_state "$d" feat-dopen)
  assert_contains "$out" "state: done" "passed run with open PR -> done"
  assert_contains "$out" "run passed: PR open" "open PR state is named"
  assert_not_contains "$out" "merged/closed" "open PR must not get the old merged/closed label"
  assert_not_contains "$out" "PR merged" "open PR must not be reported merged"
  pass "terminal passed run with open PR does not claim merged"
}

test_terminal_passed_run_pr_overrides_stale_metadata() {
  reset_fakes
  local d; d=$(new_case passed-stale-meta)
  make_repo_on_branch "$d/wt" fm/feat-dstale
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dstale.meta" "window=fm:fm-feat-dstale" \
    "worktree=$d/wt" "kind=ship" "pr=https://github.com/o/r/pull/47"
  FM_FAKE_PR_47_STATE=MERGED
  FM_FAKE_PR_47_MERGED=true
  FM_FAKE_PR_48_STATE=OPEN
  FM_FAKE_PR_48_MERGED=false
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dstale https://github.com/o/r/pull/48)"
  local out; out=$(run_crew_state "$d" feat-dstale)
  assert_contains "$out" "state: done" "passed run with stale task metadata -> done"
  assert_contains "$out" "run passed: PR open" "run PR identity outranks stale task metadata"
  assert_not_contains "$out" "PR merged" "stale merged metadata must not report merged"
  pass "terminal passed run PR overrides stale task metadata"
}

test_terminal_passed_without_readable_pr_identity_reports_unknown() {
  reset_fakes
  local d; d=$(new_case passed-no-pr)
  make_repo_on_branch "$d/wt" fm/feat-dnopr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dnopr.meta" "window=fm:fm-feat-dnopr" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_no_pr fm/feat-dnopr)"
  local out; out=$(run_crew_state "$d" feat-dnopr)
  assert_contains "$out" "state: done" "passed run without PR identity -> done"
  assert_contains "$out" "run passed: PR state unknown (no PR identity)" "missing PR identity is honest unknown"
  assert_not_contains "$out" "merged/closed" "unknown PR state must not get the old merged/closed label"
  assert_not_contains "$out" "PR merged" "unknown PR state must not be reported merged"
  pass "terminal passed run without readable PR identity reports unknown"
}

test_terminal_passed_with_open_gitlab_mr_does_not_claim_merged() {
  reset_fakes
  local d read_log out
  d=$(new_case passed-open-gitlab-mr)
  make_repo_on_branch "$d/wt" fm/feat-dgitlabopen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dgitlabopen.meta" "window=fm:fm-feat-dgitlabopen" \
    "worktree=$d/wt" "kind=ship" "pr=https://git.example.com/group/subgroup/repo/-/merge_requests/9"
  read_log="$d/glab-read.log"
  : > "$read_log"
  FM_FAKE_GLAB_READ_LOG=$read_log
  FM_FAKE_GLAB_STATE=opened
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgitlabopen https://git.example.com/group/subgroup/repo/-/merge_requests/9)"
  out=$(run_crew_state "$d" feat-dgitlabopen)
  assert_contains "$out" "run passed: PR open" "open GitLab MR state is named"
  assert_not_contains "$out" "PR merged" "open GitLab MR must not be reported merged"
  assert_grep 'git.example.com|mr view 9 -R https://git.example.com/group/subgroup/repo -F json' "$read_log" \
    "GitLab MR read uses the parsed host and project URL"
  pass "terminal passed run reads open GitLab MR state"
}

test_terminal_passed_with_merged_gitlab_mr_reports_merged() {
  reset_fakes
  local d out
  d=$(new_case passed-merged-gitlab-mr)
  make_repo_on_branch "$d/wt" fm/feat-dgitlabmerged
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dgitlabmerged.meta" "window=fm:fm-feat-dgitlabmerged" \
    "worktree=$d/wt" "kind=ship" "pr=https://gitlab.com/group/repo/-/merge_requests/10"
  FM_FAKE_GLAB_STATE=merged
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgitlabmerged https://gitlab.com/group/repo/-/merge_requests/10)"
  out=$(run_crew_state "$d" feat-dgitlabmerged)
  assert_contains "$out" "run passed: PR merged" "merged GitLab MR is reported merged"
  pass "terminal passed run reads merged GitLab MR state"
}

test_terminal_passed_with_failed_gitlab_read_reports_unknown() {
  reset_fakes
  local d out
  d=$(new_case passed-unreadable-gitlab-mr)
  make_repo_on_branch "$d/wt" fm/feat-dgitlabunknown
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dgitlabunknown.meta" "window=fm:fm-feat-dgitlabunknown" \
    "worktree=$d/wt" "kind=ship" "pr=https://gitlab.com/group/repo/-/merge_requests/11"
  FM_FAKE_GLAB_READ_FAIL=1
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgitlabunknown https://gitlab.com/group/repo/-/merge_requests/11)"
  out=$(run_crew_state "$d" feat-dgitlabunknown)
  assert_contains "$out" "run passed: PR state unknown (unreadable)" "failed GitLab read is honest unknown"
  assert_not_contains "$out" "PR merged" "failed GitLab read must not be reported merged"
  pass "terminal passed run handles failed GitLab read"
}

test_terminal_passed_with_forgejo_pull_reports_its_state() {
  reset_fakes
  local d read_log out spec state merged fail expected name
  for spec in "open|open|false|0|run passed: PR open" \
    "merged|closed|true|0|run passed: PR merged" \
    "closed|closed|false|0|run passed: PR closed" \
    "unreadable|open|false|1|run passed: PR state unknown (unreadable)"; do
    IFS='|' read -r name state merged fail expected <<<"$spec"
    d=$(new_case "passed-forgejo-$name")
    make_repo_on_branch "$d/wt" "fm/feat-dforgejo$name"
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-dforgejo$name.meta" "window=fm:fm-feat-dforgejo$name" \
      "worktree=$d/wt" "kind=ship" "pr=https://git.example.org/team/repo/pulls/12"
    read_log="$d/tea-read.log"
    : > "$read_log"
    FM_FAKE_TEA_READ_LOG=$read_log
    FM_FAKE_TEA_STATE=$state
    FM_FAKE_TEA_MERGED=$merged
    FM_FAKE_TEA_READ_FAIL=$fail
    FM_FAKE_AXI_STATUS="$(run_passed_with_pr "fm/feat-dforgejo$name" https://git.example.org/team/repo/pulls/12)"
    out=$(run_crew_state "$d" "feat-dforgejo$name")
    assert_contains "$out" "$expected" "Forgejo pull request reading $name is reported"
    [ "$name" = merged ] || assert_not_contains "$out" "PR merged" "Forgejo $name pull request must not be reported merged"
    assert_grep 'api --login fj --repo team/repo /repos/{owner}/{repo}/pulls/12' "$read_log" \
      "Forgejo read uses the host's tea login and the parsed project path"
  done
  pass "terminal passed run reads Forgejo pull request state through tea api"
}

test_terminal_passed_with_open_gerrit_change_does_not_claim_merged() {
  reset_fakes
  local d url read_log out
  d=$(new_case passed-open-gerrit-change)
  url=https://review.internal/c/group/apps/console/+/4201
  make_repo_on_branch "$d/wt" fm/feat-dgerritopen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dgerritopen.meta" "window=fm:fm-feat-dgerritopen" \
    "worktree=$d/wt" "kind=ship" "pr=$url"
  read_log="$d/gerrit-read.log"
  : > "$read_log"
  FM_FAKE_GERRIT_READ_LOG=$read_log
  FM_FAKE_GERRIT_STATUS=NEW
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgerritopen "$url")"
  out=$(run_crew_state "$d" feat-dgerritopen)
  assert_contains "$out" "run passed: PR open" "open Gerrit change state is named"
  assert_not_contains "$out" "PR merged" "open Gerrit change must not be reported merged"
  assert_grep 'show 4201 --host review.internal --json' "$read_log" \
    "Gerrit read addresses the change by number and explicit host"
  pass "terminal passed run reads open Gerrit change state"
}

test_terminal_passed_with_merged_gerrit_change_reports_merged() {
  reset_fakes
  local d url out
  d=$(new_case passed-merged-gerrit-change)
  url=https://review.internal/c/group/apps/console/+/4200
  make_repo_on_branch "$d/wt" fm/feat-dgerritmerged
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dgerritmerged.meta" "window=fm:fm-feat-dgerritmerged" \
    "worktree=$d/wt" "kind=ship" "pr=$url"
  FM_FAKE_GERRIT_STATUS=MERGED
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgerritmerged "$url")"
  out=$(run_crew_state "$d" feat-dgerritmerged)
  # The fixture record carries a null url, the shape a server with no
  # gerrit.canonicalWebUrl returns, so the merge is reported off the change
  # number the read was addressed by rather than off a URL the server may
  # never compose.
  assert_contains "$out" "run passed: PR merged" "merged Gerrit change is reported merged"

  # An abandoned change is this report's closed, and is never merged.
  FM_FAKE_GERRIT_STATUS=ABANDONED
  out=$(run_crew_state "$d" feat-dgerritmerged)
  assert_contains "$out" "run passed: PR closed" "abandoned Gerrit change is reported closed"
  assert_not_contains "$out" "PR merged" "abandoned Gerrit change must not be reported merged"
  pass "terminal passed run reads merged and abandoned Gerrit change state"
}

test_terminal_passed_with_unreadable_gerrit_change_reports_unknown() {
  reset_fakes
  local d url out
  d=$(new_case passed-unreadable-gerrit-change)
  url=https://review.internal/c/group/apps/console/+/4202
  make_repo_on_branch "$d/wt" fm/feat-dgerritunknown
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dgerritunknown.meta" "window=fm:fm-feat-dgerritunknown" \
    "worktree=$d/wt" "kind=ship" "pr=$url"
  FM_FAKE_GERRIT_READ_FAIL=1
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgerritunknown "$url")"
  out=$(run_crew_state "$d" feat-dgerritunknown)
  assert_contains "$out" "run passed: PR state unknown (unreadable)" "failed Gerrit read is honest unknown"
  assert_not_contains "$out" "PR merged" "failed Gerrit read must not be reported merged"

  # A record naming another change can never answer for this one, however the
  # server came to return it. The change number is the whole identity of the
  # match, so a wrong one is an unreadable record rather than a merge.
  reset_fakes
  FM_FAKE_GERRIT_STATUS=MERGED
  FM_FAKE_GERRIT_CHANGE=4203
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgerritunknown "$url")"
  out=$(run_crew_state "$d" feat-dgerritunknown)
  assert_contains "$out" "run passed: PR state unknown (unreadable)" "mismatched Gerrit record is honest unknown"
  assert_not_contains "$out" "PR merged" "another change's merged record must not report merged"
  pass "terminal passed run handles an unreadable or mismatched Gerrit read"
}

test_terminal_failed() {
  reset_fakes
  local d; d=$(new_case failed)
  make_repo_on_branch "$d/wt" fm/feat-e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-e)"
  FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS/status: completed/status: failed}
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# Recovered delivery cases, varying only the terminal route and the optional
# rebase step. The already-fixed passed-run case remains a control.
test_cancelled_delivery_and_skipped_rebase() {
  local scenario failures=0
  for scenario in cancelled-outcome cancelled-status skipped-rebase cancelled-skipped-rebase passed; do
    (
      reset_fakes
      local d out
      d=$(new_case "delivery-$scenario")
      make_repo_on_branch "$d/wt" fm/delivery
      make_fakebin "$d" >/dev/null
      fm_write_meta "$d/state/delivery.meta" "window=fm:fm-delivery" "worktree=$d/wt" "kind=ship"
      FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan fm/delivery)"
      case "$scenario" in
        cancelled*) FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS//failed/cancelled} ;;
      esac
      case "$scenario" in
        *skipped-rebase) FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS/rebase,completed/rebase,skipped} ;;
        cancelled-status) FM_FAKE_AXI_STATUS=$(printf '%s\n' "$FM_FAKE_AXI_STATUS" | sed '/^outcome:/d') ;;
        passed) FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/delivery https://github.com/o/r/pull/203)" ;;
      esac
      FM_FAKE_PR_STATE=OPEN
      FM_FAKE_PR_MERGED=false
      FM_FAKE_PR_STATE_AXI=open
      FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
      out=$(FM_HOME="$d" run_crew_state "$d" delivery)
      assert_contains "$out" "state: done" "$scenario: delivered work remains done: $out"
      assert_not_contains "$out" "PR merged" "$scenario: terminal record cannot prove a merge"
      if [ "$scenario" != passed ]; then
        assert_contains "$out" "https://github.com/o/r/pull/203" "$scenario: delivery identity retained"
        assert_contains "$out" "checks green" "$scenario: retain positive CI evidence"
        assert_contains "$out" "held for merge" "$scenario: delivery awaits merge"
      fi
      pass "$scenario: terminal delivery reports only observed evidence"
    ) || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || fail "$failures cancelled delivery regressions"
}

test_terminal_green_delivery_disposition() {
  local route provider disposition failures=0
  for route in failed-outcome failed-status cancelled-outcome cancelled-status; do
    for provider in github gitlab gerrit; do
      for disposition in open merged closed unreadable skipped no-identity; do
        (
          reset_fakes
          local d out url expected
          d=$(new_case "disposition-$route-$provider-$disposition")
          make_repo_on_branch "$d/wt" fm/disposition
          make_fakebin "$d" >/dev/null
          fm_write_meta "$d/state/delivery.meta" "window=fm:fm-delivery" "worktree=$d/wt" "kind=ship"
          FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan fm/disposition)"
          case "$route" in
            cancelled-*) FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS//failed/cancelled} ;;
          esac
          case "$route" in
            *-status) FM_FAKE_AXI_STATUS=$(printf '%s\n' "$FM_FAKE_AXI_STATUS" | sed '/^outcome:/d') ;;
          esac
          case "$provider" in
            github) url=https://github.com/o/r/pull/203 ;;
            gitlab) url=https://gitlab.com/o/r/-/merge_requests/203 ;;
            gerrit) url=https://review.example.com/c/r/+/203 ;;
          esac
          FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS//https:\/\/github.com\/o\/r\/pull\/203/$url}
          FM_FAKE_PR_STATE=OPEN
          FM_FAKE_PR_MERGED=false
          FM_FAKE_PR_STATE_AXI=open
          FM_FAKE_GLAB_STATE=opened
          FM_FAKE_GERRIT_STATUS=NEW
          case "$disposition" in
            no-identity) FM_FAKE_AXI_STATUS=$(printf '%s\n' "$FM_FAKE_AXI_STATUS" | sed '/^[[:space:]]*pr:/d') ;;
            merged)
              FM_FAKE_PR_STATE=MERGED
              FM_FAKE_PR_MERGED=true
              FM_FAKE_PR_STATE_AXI=merged
              FM_FAKE_GLAB_STATE=merged
              FM_FAKE_GERRIT_STATUS=MERGED ;;
            closed)
              FM_FAKE_PR_STATE=CLOSED
              FM_FAKE_PR_STATE_AXI=closed
              FM_FAKE_GLAB_STATE=closed
              FM_FAKE_GERRIT_STATUS=ABANDONED ;;
            unreadable)
              FM_FAKE_PR_READ_FAIL=1
              FM_FAKE_GLAB_READ_FAIL=1
              FM_FAKE_GERRIT_READ_FAIL=1 ;;
          esac
          FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
          if [ "$disposition" = skipped ]; then
            out=$(FM_CREW_STATE_NO_FORGE=1 FM_HOME="$d" run_crew_state "$d" delivery)
          else
            out=$(FM_HOME="$d" run_crew_state "$d" delivery)
          fi
          case "$disposition" in
            open|merged)
              assert_contains "$out" "state: done" "$route/$provider/$disposition: delivered work: $out"
              if [ "$disposition" = open ]; then
                assert_contains "$out" "held for merge" "open delivery awaits merge"
              else
                assert_contains "$out" "PR merged" "merged delivery has current evidence"
                assert_not_contains "$out" "held for merge" "merged delivery is no longer held"
              fi ;;
            *)
              expected=failed
              case "$route" in
                cancelled-*) expected=unknown
                  assert_contains "$out" "run cancelled: no verdict" "cancellation retains no verdict" ;;
              esac
              assert_contains "$out" "state: $expected" "$route/$provider/$disposition: no unsupported delivery: $out"
              assert_not_contains "$out" "held for merge" "unproven open delivery cannot await merge"
              assert_not_contains "$out" "PR merged" "unproven merge cannot be claimed" ;;
          esac
          pass "$route/$provider/$disposition: terminal delivery uses current disposition"
        ) || failures=$((failures + 1))
      done
    done
  done
  [ "$failures" -eq 0 ] || fail "$failures terminal delivery disposition regressions"
}

# Cancellation carries no verdict without the positive delivery safeguard.
# Exercise both detailed routes, selected-run attribution, and the coarse ledger.
test_cancelled_without_delivery_has_no_verdict() {
  local scenario failures=0
  for scenario in outcome status selected coarse no-ci-log red-ci cancelled-test skipped-test; do
    (
      reset_fakes
      local d out
      d=$(new_case "no-verdict-$scenario")
      make_repo_on_branch "$d/wt" fm/cancelled
      make_fakebin "$d" >/dev/null
      fm_write_meta "$d/state/cancelled.meta" "window=fm:fm-cancelled" "worktree=$d/wt" "kind=ship"
      FM_FAKE_AXI_STATUS="$(run_failed fm/cancelled)"
      FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS//failed/cancelled}
      FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS/status: completed/status: cancelled}
      case "$scenario" in
        status) FM_FAKE_AXI_STATUS=$(printf '%s\n' "$FM_FAKE_AXI_STATUS" | sed '/^outcome:/d') ;;
        selected)
          FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
          FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  01RUN,fm/cancelled,cancelled,$FM_FAKE_RUN_HEAD,\"\""
          ;;
        coarse)
          FM_FAKE_AXI_STATUS="$(run_running fm/another)"
          FM_FAKE_RUNS_LIST="  cancelled  fm/cancelled $FM_FAKE_RUN_HEAD  2026-09-26 17:00"
          ;;
        no-ci-log|red-ci|cancelled-test|skipped-test)
          FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan fm/cancelled)"
          FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS//failed/cancelled}
          FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
          case "$scenario" in
            no-ci-log) FM_FAKE_CI_LOGS= ;;
            red-ci) FM_FAKE_CI_LOGS="$FM_FAKE_CI_LOGS
checks failed: 1 of 2 checks red" ;;
            cancelled-test) FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS/test,completed/test,cancelled} ;;
            skipped-test) FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS/test,completed/test,skipped} ;;
          esac
          ;;
      esac
      out=$(FM_HOME="$d" run_crew_state "$d" cancelled)
      assert_contains "$out" "state: unknown" "$scenario: cancellation alone has no verdict: $out"
      assert_contains "$out" "run cancelled: no verdict" "$scenario: explicit reason"
      assert_contains "$out" "source: run-step" "$scenario: keep attribution"
      assert_not_contains "$out" "held for merge" "$scenario: no unsupported delivery claim"
      pass "$scenario: cancellation without delivery carries no verdict"
    ) || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || fail "$failures cancellation verdict regressions"
}

# The real inventory consumer must not confuse a cancellation with a failed
# child contradicting an In flight row. Unknown remains explicitly partial.
test_cancelled_fleet_inventory_is_unverified_not_contradictory() {
  reset_fakes
  local d out summary backlog_before status_before scenario=${1:-synthetic}
  d=$(new_case "cancelled-inventory-$scenario")
  make_repo_on_branch "$d/wt" fm/cancelled
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/data" "$d/config" "$d/projects"
  fm_write_meta "$d/state/cancelled.meta" "window=fm:fm-cancelled" "worktree=$d/wt" \
    "project=sample" "harness=claude" "kind=ship" "mode=no-mistakes"
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [ ] cancelled - Validation in progress (repo: sample) (kind: ship) (since 2026-09-26)

## Queued

## Done
EOF
  printf 'failed: historical cancellation projection\n' > "$d/state/cancelled.status"
  backlog_before=$(cat "$d/data/backlog.md")
  status_before=$(cat "$d/state/cancelled.status")
  FM_FAKE_AXI_STATUS="$(run_running fm/cancelled)"
  out=$(FM_HOME="$d" run_crew_state "$d" cancelled)
  assert_contains "$out" 'state: working' 'fixture begins with active validation'
  # Deliberately transition the external instrument fixture to cancelled.
  # This executes Firstmate end to end; it does not cancel a real daemon run.
  FM_FAKE_AXI_STATUS="$(run_failed fm/cancelled)"
  FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS//failed/cancelled}
  FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS/status: completed/status: cancelled}
  if [ "$scenario" = captured ]; then
    # Real record supplied read-only from axi status --run
    # 01M2SXM5NDEWK2KY5TG8DDYJMV; only branch/head are rebound for attribution.
    # Skipped rebase and cancelled CI monitoring remain synthetic cases above.
    FM_FAKE_AXI_STATUS="$(cat <<EOF
current_branch: fm/fm-abort-autorise-nest-pas-un-echec
other_branch_run:
id: "01M2SXM5NDEWK2KY5TG8DDYJMV"
branch: fm/cancelled
status: cancelled
head: ${FM_FAKE_RUN_HEAD:0:8}
head_sha: $FM_FAKE_RUN_HEAD
pr: "https://github.com/kunchenguid/firstmate/pull/4818"
findings: 2 awaiting
steps[9]{step,status,findings,duration_ms}:
intent,completed,0,32
rebase,completed,0,1137
review,failed,2,652115
test,pending,0,0
document,pending,0,0
lint,pending,0,0
push,pending,0,0
pr,pending,0,0
ci,pending,0,0
outcome: cancelled
error: "cancelled: aborted by user"
EOF
)"
  fi
  out=$(FM_HOME="$d" run_crew_state "$d" cancelled)
  assert_contains "$out" 'state: unknown' "$scenario cancellation has no verdict: $out"
  assert_contains "$out" 'source: run-step' "$scenario retains run attribution"
  assert_contains "$out" 'run cancelled: no verdict' "$scenario cancellation outweighs interrupted steps"
  assert_not_contains "$out" 'state: failed' "$scenario cancellation is not a failure"
  assert_not_contains "$out" 'held for merge' "$scenario has no positive delivery evidence"
  summary=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_ROOT_OVERRIDE="$d/fixture-root" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary)
  printf '%s' "$summary" | jq -e '
    .state == "unknown" and .valid == false
    and .invalidity == {kind:"child_current_unavailable",ids:["cancelled"]}
    and .reason == "child current state unavailable: cancelled"
  ' >/dev/null || fail "cancellation must not report a terminal/backlog contradiction: $summary"
  assert_equals "$backlog_before" "$(cat "$d/data/backlog.md")" 'correct backlog is unchanged'
  assert_equals "$status_before" "$(cat "$d/state/cancelled.status")" 'historical event is unchanged'
  pass "$scenario cancelled run leaves fleet inventory unverified without a failure contradiction"
}

# Replay the recorded producer output through both public consumers, without
# starting or aborting a daemon run or claiming live cancellation evidence.
test_captured_cancelled_review_has_no_verdict() {
  test_cancelled_fleet_inventory_is_unverified_not_contradictory captured
}

test_terminal_failed_ci_orphan_after_green_reads_done() {
  reset_fakes
  local d; d=$(new_case failed-ci-orphan)
  make_repo_on_branch "$d/wt" fm/feat-ci-orphan
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci-orphan.meta" "window=fm:fm-feat-ci-orphan" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan fm/feat-ci-orphan)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed
daemon shutting down"
  local out; out=$(run_crew_state "$d" feat-ci-orphan)
  assert_contains "$out" "state: done" "orphaned ci monitor after green must read done, not failed"
  assert_contains "$out" "source: run-step" "reclassified held run stays run-step sourced"
  assert_contains "$out" "https://github.com/o/r/pull/203" "PR URL surfaced from the run"
  assert_not_contains "$out" "state: failed" "monitor death must not read as a failed run"
  pass "orphaned ci monitor after green reads as held-for-merge done"
}

test_terminal_failed_ci_orphan_status_only_reads_done() {
  reset_fakes
  local d; d=$(new_case failed-ci-orphan-status-only)
  make_repo_on_branch "$d/wt" fm/feat-ci-orphan2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci-orphan2.meta" "window=fm:fm-feat-ci-orphan2" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan_status_only fm/feat-ci-orphan2)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed
daemon shutting down"
  local out; out=$(run_crew_state "$d" feat-ci-orphan2)
  assert_contains "$out" "state: done" "status-only failed orphaned monitor after green reads done"
  assert_contains "$out" "https://github.com/o/r/pull/203" "PR URL surfaced from the run"
  pass "status-only failed orphaned ci monitor after green reads done"
}

test_terminal_failed_ci_genuine_red_stays_failed() {
  reset_fakes
  local d; d=$(new_case failed-ci-genuine-red)
  make_repo_on_branch "$d/wt" fm/feat-ci-red
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci-red.meta" "window=fm:fm-feat-ci-red" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan fm/feat-ci-red)"
  FM_FAKE_CI_LOGS="CI checks running
checks failed: 1 of 2 checks red
daemon shutting down"
  local out; out=$(run_crew_state "$d" feat-ci-red)
  assert_contains "$out" "state: failed" "a genuinely red check keeps the run failed"
  assert_not_contains "$out" "state: done" "genuine CI failure must not reclassify to done"
  pass "genuinely failing CI keeps the failed verdict"
}

test_terminal_failed_ci_orphan_second_failed_step_stays_failed() {
  reset_fakes
  local d; d=$(new_case failed-ci-second-failure)
  make_repo_on_branch "$d/wt" fm/feat-ci-2fail
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci-2fail.meta" "window=fm:fm-feat-ci-2fail" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan_second_failure fm/feat-ci-2fail)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed
daemon shutting down"
  local out; out=$(run_crew_state "$d" feat-ci-2fail)
  assert_contains "$out" "state: failed" "a second failed step keeps the run failed"
  assert_not_contains "$out" "state: done" "a second failed step must not reclassify to done"
  pass "a second failed step disqualifies the orphaned-monitor reclassification"
}

# (e) cross-branch attribution: `axi status` returns ANOTHER branch's run (the
# routine case once more than one crew validates the same underlying repo
# concurrently - they share ONE no-mistakes repo registration), so the helper
# falls back to the real top-level `no-mistakes runs` listing to learn whether
# THIS branch has an active run of its own. Regression coverage for the
# 2026-07-02 herdr incident: the old fallback shelled out to `no-mistakes axi`
# (bare) expecting a `runs[N]{...}:` TOON table that the real CLI never emits
# (verified against the installed v1.32.2 - the `axi` surface has no
# runs-listing subcommand at all), so attribution silently failed every time
# the repo-wide answer was not this crew's own branch.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d short; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-f
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  # The repo-wide active/most-recent run belongs to a different crew's branch.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)
current_branch: fm/other-crew
runs_on_current_branch: 0"
  # Real `no-mistakes runs` shape: plain text, newest-first, no run id, no
  # quoting - "<status> <branch> <short-sha> <date> [<pr-url>]".
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-f ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the runs list"
  assert_contains "$out" "source: run-step" "runs-list-resolved run -> run-step source"
  pass "cross-branch run is attributed via the real runs list"
}

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.
test_coarse_socket_refusal_reports_blocked() {
  reset_fakes
  local d short; d=$(new_case coarse-socket-refused)
  make_repo_on_branch "$d/wt" fm/feat-coarse-down
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarse-down.meta" "window=fm:fm-feat-coarse-down" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon connection refused\n' > "$d/state/feat-coarse-down.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarse-down ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-coarse-down)
  assert_contains "$out" "state: blocked" "socket refusal outranks a coarse active record"
  assert_contains "$out" "source: status-log" "coarse socket refusal remains status-log evidence"
  assert_not_contains "$out" "state: working" "coarse active record cannot suppress socket refusal"
  pass "socket refusal over a coarse active run reports blocked"
}

# The coarse fallback has no steps table and no ci log, so the 2026-09-05
# orphaned-monitor shape (every substantive step completed, only the ci
# monitor failed after the daemon restarted under its merge poll) cannot be
# recognized there. With the daemon provably down, that terminal failed
# record is unverified evidence from a dead instrument and must read unknown,
# never failed - the fleet rule from #3785. The fallback is reached while the
# daemon is answering for another branch, so the probe proves the daemon
# went down after that answer (a flapping daemon under incident load) - the
# two calls are separate socket connections. With the daemon up, the same
# record keeps its failure verdict.
test_coarse_failed_ledger_with_daemon_down_reports_unknown() {
  reset_fakes
  local d short; d=$(new_case coarse-daemon-down-failed)
  make_repo_on_branch "$d/wt" fm/feat-coarsedown
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarsedown.meta" "window=fm:fm-feat-coarsedown" "worktree=$d/wt" "kind=ship"
  # The primary `axi status` call answers (another crew's run - the shared
  # daemon serves the whole repo), so attribution falls to the coarse runs
  # ledger, whose newest row for this branch is terminal failed at this
  # worktree's own head.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-coarsedown ${short}  2026-09-05 21:00"
  FM_FAKE_DAEMON_DOWN=1
  local out; out=$(run_crew_state "$d" feat-coarsedown)
  assert_contains "$out" "state: unknown" "daemon down + failed ledger record -> unknown"
  assert_contains "$out" "no-mistakes daemon unreachable; last ledger record failed - unverified" \
    "the unverified detail names the dead instrument"
  assert_not_contains "$out" "state: failed" "an instrument failure never reads as work failure"
  assert_contains "$out" "source: run-step" "the ledger row is still this branch's attributed run"

  # Daemon provably up again: the same row stays a failure.
  FM_FAKE_DAEMON_DOWN=0
  out=$(run_crew_state "$d" feat-coarsedown)
  assert_contains "$out" "state: failed" "daemon up keeps the failed verdict over the failed record"
  assert_not_contains "$out" "unverified" "no unverified qualifier while the daemon answers"
  pass "failed ledger record reads unknown only when the daemon is provably down"
}

test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d short; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" fm/feat-fq
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-fq.meta" "window=fm:fm-feat-fq" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-fq ${short}  2026-07-02 21:50
  completed  fm/feat-fq bbbbbbb  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older completed row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

# The plain ledger is ordered by creation time, not the time a status changed.
# A newer failure must not be hidden by an older live run, even when both heads
# bind to the worktree. These legacy CLI cases lack the AXI identity table.
test_terminal_run_keeps_newer_failure_over_live_sibling() {
  reset_fakes
  local d base_head live_head short_base short_live out
  d=$(new_case live-beats-corpse)
  make_repo_on_branch "$d/wt" fm/feat-corpse
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'live run advanced the tip'
  live_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree stays at the commit the dead run recorded; the live run is ahead.
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_live=$(git -C "$d/wt" rev-parse --short=7 "$live_head")
  [ "$short_base" != "$short_live" ] || fail "live run head did not advance past the worktree"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/corpse.meta" "window=fm:fm-corpse" "worktree=$d/wt" "kind=ship"
  # The newest run failed at this worktree's own commit.
  FM_FAKE_RUN_HEAD="$base_head"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-corpse)"
  # The older live run may have advanced its tip, but it did not replace this run.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-corpse ${short_base}  2026-08-05 11:20
  running    fm/feat-corpse ${short_live}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" corpse)
  assert_contains "$out" "state: failed" "the newer failure remains authoritative beside an older live run"
  assert_contains "$out" "source: run-step" "the newer failure keeps its run-step verdict"
  pass "a newer failure is not hidden by a live sibling"
}
