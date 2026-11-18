#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI selects
# canonical partitions; no-mistakes invokes the context-selected default, so
# both use this owner without duplicating lint configuration.
# The explicit --fast mode is local-only and disables ShellCheck's extended
# dataflow analysis while preserving ordinary shell lint checks. No canonical
# pass follows sources: CI, main, merge-base-less runs, changed-file mode, and
# --fast all run --norc without --external-sources and exclude SC1091, the note
# that a source statement was not followed. Following is the measured cost
# driver, not line count: with it enabled a 75-line definition module allocated
# about 330 MiB because ShellCheck resolved a variable-path import, while the
# same module costs about 15 MiB without it. Changed-file mode excludes
# SC2034, SC2153, and SC2329 as well, the codes that need library context.
# Explicit paths keep --external-sources with the selected dataflow mode, so a
# developer linting one file still gets cross-file judgement.
# Every importer stops source analysis at the imported library: the import is
# marked `# shellcheck source=/dev/null`, and the library is a canonical root of
# its own, so a library is analyzed once rather than re-parsed inside every
# consumer. That is what keeps one small script from paying for the whole
# library graph, and it means cross-file codes are judged at the library's own
# root instead of at each consumer. A file that assigns a global another file
# reads says so with a targeted disable naming the reader.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed workflow under .github/workflows or .forgejo/workflows, including a
# self-broken ci.yml, fails locally before merge instead of only failing there.
# A checkout with neither directory is a pass, so a CI-less repository
# still lints.
#
# With no explicit paths, the file set and source-following posture depend
# on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh, with full
#     dataflow, no source following, and SC1091 excluded. Full-set coverage never
#     depends on a local diff.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). That local pass additionally excludes SC2034, SC2153, and SC2329.
#     A branch with zero matching changed files
#     skips ShellCheck and prints a "no changed lint targets" note, then
#     still runs the backend-purity check and validates workflows.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config, without the workflow YAML check.
# Explicit core bin/ and bin/backends/ scripts still receive the
# backend-purity check. The backend-purity check rejects direct Beads CLI
# invocations in the core bin/ and bin/backends/ scripts so every configured
# backlog backend follows the same tasks-axi lifecycle path.
#
# Lint schedules by measured cost, not a flat file count. A root's line count
# gives a scheduling estimate; a root at or above FM_LINT_HEAVY_LINES (default
# 2500) is heavy and runs strictly one at a time on its own lane, so a
# pathological file is never in flight beside another analysis, while lighter
# roots pack by estimate into two stable logical shards. The worker count is
# sized from the memory budget (FM_LINT_MEMORY_BUDGET_MIB, else the host's
# available memory) and never exceeds JOBS; --list-plan prints the classification,
# estimates, lane assignment, and worker counts without running any lint.
# Each worker runs ONE canonical root per ShellCheck process, so a run holds
# at most one heavy analysis plus the sized number of light ones, and
# diagnostics replay in stable lane/root order. FM_LINT_JOBS=1 changes
# concurrency, not diagnostics or exit selection.
# --partition 1of2/2of2 splits the entire canonical inventory across
# two hosted runners, each with that same cost-based scheduling.
# Partitions are complete, disjoint, and byte-weight balanced; --list-files
# exposes their actual roots.
# Partition mode starts with the full canonical analysis, never changed-only
# or --fast, and does not accept explicit paths. Each partition also runs
# workflow lint and backend-purity checks, keeping either invocation
# independently useful.
#
# Every per-root analysis, bounded mode or not, runs under a resident memory
# ceiling (FM_LINT_ROOT_MEMORY_MIB, default 1500 MiB): the worker samples the
# root's own process group while it runs and, on breach, terminates that group
# and records reason=memory-ceiling with the file named. The ceiling is a
# structural stop, not a retry condition: a root that reaches it is a file to
# split, so the memory-fallback retry below never applies to it.
#
# With FM_LINT_REQUIRE_BOUNDS=1, which a hosted runner can set, every per-root ShellCheck
# process additionally runs under an enforced envelope: a wall deadline
# (FM_LINT_ROOT_SECONDS, default 1200), a terminate-then-kill cleanup grace
# (FM_LINT_ROOT_GRACE, default 5), and a per-process address-space limit
# (FM_LINT_ROOT_MEMORY_KIB, default 12582912 = 12 GiB of virtual address
# space per analysis process). The address-space limit is the backstop for a
# host whose process sampling cannot see a runaway; the resident ceiling is
# the ordinary bound. The watchdog uses the shared bin/fm-timeout-lib.sh
# group-kill pattern, so a deadline or an interrupt removes the owned process
# group. Bounds mode proves the watchdog can actually bound a probe command and
# that the host accepts the memory limit BEFORE any root starts; when either
# check fails the run refuses with a named error, so a required-bounds run
# never lints uncapped. Without FM_LINT_REQUIRE_BOUNDS (a local developer lint,
# where hosts like macOS cannot apply the address-space limit at all) each root
# still runs in its own ShellCheck process with identical diagnostics and the
# same resident ceiling.
#
# The whole run executes inside one memory-capped scope when user scopes are
# available: systemd-run --user --scope with MemoryMax=FM_LINT_SCOPE_MEMORY_MIB
# (default ceiling times maximum concurrent analyses plus 1 GiB) and
# MemorySwapMax=FM_LINT_SCOPE_SWAP_MIB (default 0). A scheduling estimate that
# slips past the per-root ceiling therefore still cannot exhaust the host. The
# scope is probed once before any lint work; when it is unavailable the run
# continues plainly and says so. FM_LINT_MEMORY_SCOPE=0 opts out.
#
# If a source-following root exits with a memory failure, it is retried once
# without --external-sources under the same memory limit and only the time
# left in that root's original deadline; with under a second left, the
# memory failure stands without a retry. A clean retry passes
# with an explicit memory-fallback reason and warning; only the same
# cross-file-dependent codes omitted in local no-source lint are excluded.
# Other findings and failed retries still fail lint. The retry's diagnostics
# replace the failed attempt's output; peak RSS is the maximum of both attempts.
#
# Per-root evidence is incremental: workers append begin/end records (root,
# mode, shard, start, end, duration, final exit status, reason, peak RSS when
# measured, and whether the final attempt followed sources) to a roots log
# as each root completes, so a mid-run kill still leaves the completed record
# and names the root in flight as begun-but-unfinished. With --telemetry the
# log is retained at
# <telemetry-without-.tsv>.roots.tsv (or <telemetry>.roots.tsv if there is no
# .tsv suffix); otherwise it lives only in the
# run's scratch dir. Reason values are ok, findings, memory-fallback,
# memory-ceiling, timeout, memory, signal:<sig>, limit-unavailable, or
# error:<rc>.
# Memory requires process-level evidence (a GHC exhaustion status or runtime
# error on stderr), not an echoed source excerpt or an OOM phrase in a
# filename. In partition mode begin/end
# lines also stream to stderr, and an abnormal root end is always reported
# there.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
# source_followed_directives counts directives only for roots whose final
# attempt followed sources, not roots that passed or failed a no-source retry.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override concurrent worker count
#   fm-lint.sh --partition <1of2|2of2> lint one canonical CI partition (see fallback above)
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --list-plan             print the cost scheduling plan (no lint)
#   fm-lint.sh --help                  print this usage
set -u

# Preserved so the run-level memory scope can re-enter this exact invocation.
FM_LINT_ARGV=("$@")

REQUIRED_SHELLCHECK=0.11.0
# Codes that need library context. A run that does not follow imports cannot
# judge them: the canonical full pass excludes only SC1091, and changed-file
# mode and the memory fallback exclude the whole set.
LOCAL_NOX_EXCLUDE=SC1091,SC2034,SC2153,SC2329
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

# The sibling timeout library supplies the shared group-kill watchdog that
# bounds each root when FM_LINT_REQUIRE_BOUNDS=1 requires it; without the
# library a required-bounds run refuses in preflight rather than lint uncapped.
if [ -r "$SELF_DIR/fm-timeout-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$SELF_DIR/fm-timeout-lib.sh"
fi

FM_LINT_WORKER_RUN_PID=
FM_LINT_WORKER_ARGS=()
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  local pid=$FM_LINT_WORKER_RUN_PID i=0
  [ -n "$pid" ] || return 0
  # The run is its own group leader (setpgrp, above), because the ceiling
  # monitor must be able to stop one analysis without ending the worker that
  # owns it. Signalling only the leader would orphan the tool and the time
  # wrapper underneath it, so the whole group gets the terminate-then-kill
  # sweep the rest of this script uses. The poll is bounded so a tool that
  # ignores TERM cannot hold the worker's signal handling open.
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.01 2>/dev/null || { sleep 1; i=$((i + 100)); }
    i=$((i + 1))
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  FM_LINT_WORKER_RUN_PID=
}

fm_lint_now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local seconds=${EPOCHREALTIME%.*} micros=${EPOCHREALTIME#*.}
    printf '%s\n' "$((seconds * 1000 + 10#${micros:0:3}))"
  else
    printf '%s\n' "$(($(date +%s) * 1000))"
  fi
}

# Names are listed only for signal numbers that agree on Linux and macOS; any
# other number reports itself.
fm_lint_signal_name() {  # <signal-number>
  case "$1" in
    1) printf 'HUP\n' ;; 2) printf 'INT\n' ;; 3) printf 'QUIT\n' ;;
    6) printf 'ABRT\n' ;; 8) printf 'FPE\n' ;; 9) printf 'KILL\n' ;;
    11) printf 'SEGV\n' ;; 13) printf 'PIPE\n' ;; 14) printf 'ALRM\n' ;;
    15) printf 'TERM\n' ;; 24) printf 'XCPU\n' ;; 25) printf 'XFSZ\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Peak RSS of a finished root process: GNU time writes max_rss_kib=<KiB> while
# BSD time -l writes "maximum resident set size" in bytes.
fm_lint_root_rss() {  # <rss-file>
  local file=$1 kib
  kib=$(awk '
    /^max_rss_kib=/ { value = substr($0, 13) + 0; found = 1 }
    /maximum resident set size/ { value = int($1 / 1024); found = 1 }
    END { if (found) print value }
  ' "$file" 2>/dev/null)
  printf '%s\n' "${kib:-unavailable}"
}

fm_lint_max_root_rss() {  # <rss-kib> <rss-kib>
  local first=$1 second=$2
  case "$first" in ''|unavailable|*[!0-9]*) printf '%s\n' "$second"; return ;; esac
  case "$second" in ''|unavailable|*[!0-9]*) printf '%s\n' "$first"; return ;; esac
  if [ "$first" -gt "$second" ]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' "$second"
  fi
}

# Map a root's exit status onto the reported reason vocabulary without
# pretending every signal or nonzero exit is a memory kill: only process-level
# memory-failure evidence earns the memory reason - GHC's heap-exhaustion
# status 251, or a complete runtime memory-error line on the root's stderr -
# and that evidence is checked before a generic findings or signal reason.
# Diagnostics and their echoed source excerpts are on stdout and never count,
# and each stderr form is matched whole to its line end, so a root path that
# merely contains OOM words inside a file error never counts either.
fm_lint_classify_root() {  # <rc> <root-stderr-file>
  local rc=$1 err=$2
  case "$rc" in
    0) printf 'ok\n'; return 0 ;;
    97) printf 'limit-unavailable\n'; return 0 ;;
    251) printf 'memory\n'; return 0 ;;
  esac
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] && [ "$rc" = 124 ]; then
    printf 'timeout\n'; return 0
  fi
  if grep -qE '^[^[:space:]:]+: (out of memory \(requested [0-9]+ bytes\)|Heap exhausted;)$|: resource exhausted \((Cannot allocate memory|out of memory)\)$' "$err" 2>/dev/null; then
    printf 'memory\n'; return 0
  fi
  if [ "$rc" = 1 ]; then
    printf 'findings\n'; return 0
  fi
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ]; then
    case "$rc" in
      137)
        # The perl watchdog exits 124 on its own bound, so a bare 137 is a real
        # SIGKILL of the child; GNU/BSD timeout instead report 137 when their
        # configured kill had to fire at the bound.
        if [ "${FM_LINT_INTERNAL_BOUNDED:-}" = perl ]; then
          printf 'signal:KILL\n'; return 0
        fi
        printf 'timeout\n'; return 0
        ;;
    esac
  fi
  case "$rc" in
    ''|*[!0-9]*) printf 'error\n' ;;
    *)
      if [ "$rc" -gt 128 ]; then
        printf 'signal:%s\n' "$(fm_lint_signal_name "$((rc - 128))")"
      else
        printf 'error:%s\n' "$rc"
      fi
      ;;
  esac
}

# One process-tree snapshot of <root-pid>: prints "<pid> <rss-kib>" for the
# root and every descendant. Bounded mode wraps the analysis in a watchdog that
# puts the tool in a group of its own, so a process-group sum would miss the
# analysis entirely; the parent chain is the one relation both shapes share.
fm_lint_tree_snapshot() {  # <root-pid>
  ps -A -o pid=,ppid=,rss= 2>/dev/null | awk -v root="$1" '
    { pid[NR] = $1; ppid[NR] = $2; rss[NR] = $3; n = NR }
    END {
      want[root] = 1
      for (pass = 0; pass < 8; pass++) {
        changed = 0
        for (i = 1; i <= n; i++) {
          if (!(pid[i] in want) && (ppid[i] in want)) { want[pid[i]] = 1; changed = 1 }
        }
        if (!changed) break
      }
      for (i = 1; i <= n; i++) if (pid[i] in want) print pid[i], rss[i]
    }
  '
}

# Resident memory of one running analysis in KiB, or empty when this host cannot
# report it.
fm_lint_tree_rss_kib() {  # <root-pid>
  fm_lint_tree_snapshot "$1" | awk '
    NF { sum += $2; seen = 1 }
    END { if (seen) printf "%d\n", sum }
  '
}

# Terminate one analysis and every process under it, then escalate. The
# per-process term keeps the watchdog's forwarding path in play, and the group
# term reaches anything that left the tree.
fm_lint_stop_tree() {  # <root-pid>
  local root=$1 sig=$2 pid
  if [ "$sig" = TERM ]; then
    kill -TERM -- "-$root" 2>/dev/null || true
    kill -TERM "$root" 2>/dev/null || true
  else
    kill -KILL -- "-$root" 2>/dev/null || true
    kill -KILL "$root" 2>/dev/null || true
  fi
  for pid in $(fm_lint_tree_snapshot "$root" | awk -v skip="$root" '$1 != skip { print $1 }'); do
    kill -"$sig" "$pid" 2>/dev/null || true
  done
}

# Sample one running analysis and stop its process tree when it passes the
# per-root resident ceiling. The monitor is the ordinary memory bound: it needs
# no cgroup and works the same on a developer host and a runner. Three blind
# samples disable it rather than spin, leaving the address-space limit and the
# run-level cap as the backstops.
fm_lint_watch_root() {  # <path> <pid>
  local path=$1 pid=$2 ceiling_kib=$(( ${FM_LINT_INTERNAL_CEILING_MIB:-0} * 1024 ))
  local rss_kib blind=0
  [ "$ceiling_kib" -gt 0 ] || return 0
  while kill -0 "$pid" 2>/dev/null; do
    rss_kib=$(fm_lint_tree_rss_kib "$pid")
    case "$rss_kib" in
      ''|*[!0-9]*) rss_kib= ;;
    esac
    if [ -n "$rss_kib" ]; then
      blind=0
      if [ "$rss_kib" -gt "$ceiling_kib" ]; then
        FM_LINT_CEILING_TRIPPED=1
        printf 'fm-lint: %s exceeded the per-root memory ceiling (%s MiB used, %s MiB allowed); stopping that analysis\n' \
          "$path" "$((rss_kib / 1024))" "${FM_LINT_INTERNAL_CEILING_MIB:-0}" >&2
        fm_lint_stop_tree "$pid" TERM
        sleep 1
        fm_lint_stop_tree "$pid" KILL
        return 0
      fi
    else
      blind=$((blind + 1))
      [ "$blind" -lt 3 ] || return 0
    fi
    sleep 0.2 2>/dev/null || sleep 1
  done
}

# Run one ShellCheck invocation in its own process group under the per-root
# address-space limit (bounded mode only) and the resident ceiling, returning
# its exit status in FM_LINT_LAST_RC and any ceiling breach in
# FM_LINT_CEILING_TRIPPED.
fm_lint_exec_root() {  # <path> <stdout-file> <stderr-file> <rss-file> <seconds> <args...>
  local path=$1 root_out=$2 root_err=$3 rss_file=$4 seconds=$5 invocation_rc=0
  shift 5
  local -a payload
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ]; then
    # The watchdog runs in a process group of its own (the same setpgrp hop the
    # workers use), so the owner's TERM-then-KILL group sweep cannot kill it
    # before it has forwarded the signal to the root's own group. If the worker
    # dies before its trap can signal the watchdog, the watchdog's parent-death
    # check still starts the same terminate-then-kill escalation; the worker
    # names itself as that owner before the launch, so a worker that dies while
    # the watchdog is still starting is detected too.
    rm -f "$rss_file"
    payload=(
      "${BASH:-bash}" "$SELF" --internal-timed
      "$seconds" "$FM_LINT_INTERNAL_GRACE"
      "${BASH:-bash}" "$SELF" --internal-root "$rss_file" "$FM_LINT_INTERNAL_MEMORY_KIB"
      "$FM_LINT_SHELLCHECK" "$@" -- "$path"
    )
  else
    # Without the wall and address-space envelope the payload still goes
    # through this mode with no address-space limit, so the sidecar keeps the
    # per-root peak RSS record.
    rm -f "$rss_file"
    payload=(
      "${BASH:-bash}" "$SELF" --internal-root "$rss_file" none
      "$FM_LINT_SHELLCHECK" "$@" -- "$path"
    )
  fi
  FM_LINT_CEILING_TRIPPED=0
  ( FM_EXEC_TIMED_OWNER_PID=$$ exec "${FM_LINT_PERL_BIN:-perl}" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      "${payload[@]}" ) > "$root_out" 2> "$root_err" &
  FM_LINT_WORKER_RUN_PID=$!
  # The run owns a group of its own, so its owner (this worker) is the only
  # process that knows which group to stop. Publish it before waiting: a
  # run-level cleanup must still reach an analysis whose worker was killed
  # before it could forward the signal.
  printf '%s\n' "$FM_LINT_WORKER_RUN_PID" > "${root_out%.out}.pgid" 2>/dev/null || true
  fm_lint_watch_root "$path" "$FM_LINT_WORKER_RUN_PID"
  wait "$FM_LINT_WORKER_RUN_PID" || invocation_rc=$?
  rm -f "${root_out%.out}.pgid"
  FM_LINT_WORKER_RUN_PID=
  FM_LINT_LAST_RC=$invocation_rc
}

# Run one selected root, retry memory failures without source following, record
# its lifecycle in the roots log, and append the final diagnostics.
fm_lint_run_root() {  # <index> <path> <output-dir> <shard-index>
  local index=$1 path=$2 output_dir=$3 shard_index=$4
  local root_out="$output_dir/root.$shard_index.$index.out"
  local root_err="$output_dir/root.$shard_index.$index.err"
  local rss_file="$output_dir/root.$shard_index.$index.rss"
  local fallback_out="$output_dir/root.$shard_index.$index.fallback.out"
  local fallback_err="$output_dir/root.$shard_index.$index.fallback.err"
  local fallback_rss="$output_dir/root.$shard_index.$index.fallback.rss"
  local start_ms end_ms duration_ms invocation_rc=0 reason rss_kib initial_rc initial_reason
  local fallback_secs
  local final_follow_sources=${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}
  local -a fallback_args
  start_ms=$(fm_lint_now_ms)
  if [ -n "${FM_LINT_INTERNAL_ROOTS_LOG:-}" ]; then
    printf 'begin\t%s\t%s\t%s\t%s\t%s\n' \
      "$index" "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-}" "$start_ms" \
      >> "$FM_LINT_INTERNAL_ROOTS_LOG"
  fi
  if [ "${FM_LINT_INTERNAL_PROGRESS:-0}" = 1 ]; then
    printf 'fm-lint: begin %s (shard %s, %s mode)\n' \
      "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-unknown}" >&2
  fi
  fm_lint_exec_root "$path" "$root_out" "$root_err" "$rss_file" \
    "$FM_LINT_INTERNAL_ROOT_SECS" "${FM_LINT_WORKER_ARGS[@]}"
  invocation_rc=$FM_LINT_LAST_RC
  reason=$(fm_lint_classify_root "$invocation_rc" "$root_err")
  if [ "${FM_LINT_CEILING_TRIPPED:-0}" = 1 ]; then
    reason=memory-ceiling
    printf 'fm-lint: %s is over the per-root memory ceiling of %s MiB; the analysis was stopped. Split that file rather than raising the ceiling.\n' \
      "$path" "${FM_LINT_INTERNAL_CEILING_MIB:-0}" >> "$output_dir/shard.$shard_index.out"
  fi
  initial_rc=$invocation_rc
  initial_reason=$reason
  # The retry spends what is left of this root's one deadline rather than a
  # fresh one, so both attempts together still fit the budget a hosted lint job
  # sized its timeout around.
  fallback_secs=$(( (start_ms + FM_LINT_INTERNAL_ROOT_SECS * 1000 - $(fm_lint_now_ms)) / 1000 ))
  if [ "$reason" = memory ] \
    && [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ] \
    && [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] \
    && [ "$fallback_secs" -lt 1 ]; then
    printf 'fm-lint: %s hit the memory ceiling with --external-sources (reason=%s rc=%s); no time left in its %ss deadline to retry without it\n' \
      "$path" "$initial_reason" "$initial_rc" "$FM_LINT_INTERNAL_ROOT_SECS" >> "$output_dir/shard.$shard_index.out"
    rss_kib=$(fm_lint_root_rss "$rss_file")
    cat "$root_out" "$root_err" >> "$output_dir/shard.$shard_index.out"
  elif [ "$reason" = memory ] \
    && [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
    fallback_args=()
    for arg in "${FM_LINT_WORKER_ARGS[@]}"; do
      [ "$arg" = --external-sources ] || fallback_args+=("$arg")
    done
    [ -z "$LOCAL_NOX_EXCLUDE" ] || fallback_args+=("--exclude=$LOCAL_NOX_EXCLUDE")
    fm_lint_exec_root "$path" "$fallback_out" "$fallback_err" "$fallback_rss" \
      "$fallback_secs" "${fallback_args[@]}"
    final_follow_sources=0
    invocation_rc=$FM_LINT_LAST_RC
    reason=$(fm_lint_classify_root "$invocation_rc" "$fallback_err")
    rss_kib=$(fm_lint_max_root_rss \
      "$(fm_lint_root_rss "$rss_file")" "$(fm_lint_root_rss "$fallback_rss")")
    printf 'fm-lint: %s hit the memory ceiling with --external-sources (reason=%s rc=%s); retried without it' \
      "$path" "$initial_reason" "$initial_rc" >> "$output_dir/shard.$shard_index.out"
    if [ "$reason" = ok ]; then
      reason=memory-fallback
      invocation_rc=0
      printf '; fallback passed with cross-file codes excluded (%s)\n' "$LOCAL_NOX_EXCLUDE" \
        >> "$output_dir/shard.$shard_index.out"
    else
      printf '; fallback reason=%s rc=%s\n' "$reason" "$invocation_rc" \
        >> "$output_dir/shard.$shard_index.out"
    fi
    cat "$fallback_out" "$fallback_err" >> "$output_dir/shard.$shard_index.out"
  else
    rss_kib=$(fm_lint_root_rss "$rss_file")
    cat "$root_out" "$root_err" >> "$output_dir/shard.$shard_index.out"
  fi
  end_ms=$(fm_lint_now_ms)
  duration_ms=$((end_ms - start_ms))
  if [ -n "${FM_LINT_INTERNAL_ROOTS_LOG:-}" ]; then
    printf 'end\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$index" "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-}" \
      "$start_ms" "$end_ms" "$duration_ms" "$invocation_rc" "$reason" "$rss_kib" "$final_follow_sources" \
      >> "$FM_LINT_INTERNAL_ROOTS_LOG"
  fi
  if [ "${FM_LINT_INTERNAL_PROGRESS:-0}" = 1 ] || { [ "$reason" != ok ] && [ "$reason" != findings ] && [ "$reason" != memory-fallback ]; }; then
    printf 'fm-lint: end %s reason=%s rc=%s duration_ms=%s rss_kib=%s\n' \
      "$path" "$reason" "$invocation_rc" "$duration_ms" "$rss_kib" >&2
  fi
  return "$invocation_rc"
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab entry index path output invocation_rc rc=0
  local -a root_entries
  root_entries=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    root_entries+=("$index	$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#root_entries[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    FM_LINT_WORKER_ARGS=(--norc)
    if [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
      FM_LINT_WORKER_ARGS+=(--external-sources)
    fi
    if [ -n "${FM_LINT_INTERNAL_EXCLUDE:-}" ]; then
      FM_LINT_WORKER_ARGS+=(--exclude="$FM_LINT_INTERNAL_EXCLUDE")
    fi
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      FM_LINT_WORKER_ARGS+=(--extended-analysis=false)
    fi
    : > "$output.out"
    for entry in "${root_entries[@]}"; do
      index=${entry%%"$tab"*}
      path=${entry#*"$tab"}
      invocation_rc=0
      fm_lint_run_root "$index" "$path" "$output_dir" "$shard_index" || invocation_rc=$?
      if [ "$rc" -eq 0 ] && [ "$invocation_rc" -ne 0 ]; then
        rc=$invocation_rc
      fi
    done
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

# Private per-root payload mode used only by the bounded runner above: apply
# the per-process address-space limit (a positive KiB count), then exec
# /usr/bin/time for the per-root peak-RSS record when it is available, else the
# tool itself. A limit the host cannot apply exits 97 so the parent reports
# limit-unavailable instead of running uncapped.
if [ "${1:-}" = "--internal-root" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-root is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -ge 4 ] || exit 2
  internal_rss_file=$2
  internal_memory_kib=$3
  shift 3
  case "$internal_memory_kib" in
    none) internal_memory_kib= ;;
    ''|0*|*[!0-9]*)
      printf 'fm-lint.sh: --internal-root memory limit must be a positive KiB count or none, got %s\n' \
        "$internal_memory_kib" >&2
      exit 2
      ;;
  esac
  if [ -n "$internal_memory_kib" ]; then
    ulimit -v "$internal_memory_kib" 2>/dev/null || {
      printf 'fm-lint.sh: per-root memory limit %s KiB is not enforceable on this host\n' \
        "$internal_memory_kib" >&2
      exit 97
    }
  fi
  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec /usr/bin/time -l -o "$internal_rss_file" "$@"
    fi
    exec /usr/bin/time -f 'max_rss_kib=%M' -o "$internal_rss_file" "$@"
  fi
  exec "$@"
fi

# Private bounded-run mode used only by the per-root runner above: the caller
# has already moved this process into its own group, so re-enter through SELF
# keeps the watchdog out of the worker's killable group while resolving the
# shared fm_exec_timed implementation through the same source path.
if [ "${1:-}" = "--internal-timed" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-timed is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -ge 4 ] || exit 2
  declare -F fm_exec_timed >/dev/null 2>&1 || {
    printf 'fm-lint.sh: fm-timeout-lib.sh is required for bounded runs.\n' >&2
    exit 127
  }
  fm_exec_timed "$2" "$3" "${@:4}"
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates CI workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

# Backend adapters belong behind tasks-axi. Keep direct Beads CLI invocations
# out of firstmate's core scripts so every configured backend follows the same
# lifecycle path.
fm_lint_run_backend_purity() {
  local findings path canonical
  local -a purity_roots
  purity_roots=()
  if [ "$EXPLICIT_PATHS" -eq 0 ]; then
    purity_roots=(bin/*.sh bin/backends/*.sh)
  else
    for path in "${ROOTS[@]}"; do
      [ -f "$path" ] || continue
      # shellcheck disable=SC2016 # Perl, not the shell, expands $ARGV.
      canonical=$("$PERL_BIN" -MCwd=realpath -e '
        my $resolved = realpath($ARGV[0]);
        exit 1 unless defined $resolved;
        print $resolved;
      ' "$path" 2>/dev/null) || continue
      case "$canonical" in
        "$ROOT"/bin/*.sh|"$ROOT"/bin/backends/*.sh)
          purity_roots+=("$canonical")
          ;;
      esac
    done
  fi
  [ "${#purity_roots[@]}" -gt 0 ] || return 0
  findings=$(LC_ALL=C awk '
    function hex_value(character) {
      return index("0123456789abcdef", tolower(character)) - 1
    }
    function ansi_number(digits, base,    i, value) {
      value=0
      for (i=1; i <= length(digits); i++) value=value * base + hex_value(substr(digits, i, 1))
      return value
    }
    # Non-printable and non-ASCII bytes can never spell the bd command, so a
    # placeholder keeps them from colliding into it.
    function ansi_character(value) {
      if (value < 32 || value > 126) return "?"
      return sprintf("%c", value)
    }
    function invokes_bd(segment) {
      sub(/^[[:space:]]+/, "", segment)
      while (1) {
        previous=segment
        sub(/^(if|then|elif|else|while|until|do)[[:space:]]+/, "", segment)
        sub(/^![[:space:]]+/, "", segment)
        sub(/^(command|exec)[[:space:]]+/, "", segment)
        sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
        if (segment ~ /^env[[:space:]]+/) {
          sub(/^env[[:space:]]+/, "", segment)
          while (1) {
            if (segment ~ /^--[[:space:]]+/) {
              sub(/^--[[:space:]]+/, "", segment)
              break
            }
            if (segment ~ /^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/) {
              sub(/^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/) {
              sub(/^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/) {
              sub(/^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/) {
              sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            break
          }
        }
        if (segment == previous) break
      }
      command_word=""
      quote=""
      ansi=0
      for (position=1; position <= length(segment); position++) {
        character=substr(segment, position, 1)
        if (quote == "") {
          if (character ~ /[[:space:]]/) break
          if (character == "$" && position < length(segment)) {
            next_character=substr(segment, position + 1, 1)
            if (next_character == "\"" || next_character == sprintf("%c", 39)) {
              position++
              quote=next_character
              ansi=(next_character == sprintf("%c", 39)) ? 1 : 0
              continue
            }
          }
          if (character == "\"" || character == sprintf("%c", 39)) {
            quote=character
            ansi=0
            continue
          }
          if (character == "\\") {
            position++
            if (position > length(segment)) return 0
            character=substr(segment, position, 1)
          }
          command_word=command_word character
          continue
        }
        if (character == quote) {
          quote=""
          ansi=0
          continue
        }
        if (character == "\\" && (quote == "\"" || ansi)) {
          position++
          if (position > length(segment)) return 0
          escape=substr(segment, position, 1)
          if (ansi) {
            # ANSI-C quoting decodes escapes, so an encoded spelling of the
            # command still runs bd and must be decoded here to be caught.
            value=-1
            if (escape == "x" || escape == "u" || escape == "U") {
              max_digits=2
              if (escape == "u") max_digits=4
              if (escape == "U") max_digits=8
              digits=""
              while (length(digits) < max_digits && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-9A-Fa-f]/) break
                digits=digits digit
                position++
              }
              if (digits == "") {
                # An escape prefix with no digits yields the prefix character.
                command_word=command_word escape
                continue
              }
              value=ansi_number(digits, 16)
            } else if (escape ~ /[0-7]/) {
              digits=escape
              while (length(digits) < 3 && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-7]/) break
                digits=digits digit
                position++
              }
              value=ansi_number(digits, 8)
            }
            if (value >= 0) {
              if (value == 0) {
                # NUL truncates the bash word.
                quote=""
                break
              }
              command_word=command_word ansi_character(value)
              continue
            }
            if (escape == "c") {
              # Control characters can never spell the bd command.
              if (position < length(segment)) position++
              command_word=command_word "?"
              continue
            }
            if (escape ~ /^[abeEfnrtv]$/) {
              command_word=command_word "?"
              continue
            }
            # Remaining ANSI-C escapes keep their character, and bash drops
            # the backslash before any other character.
            command_word=command_word escape
            continue
          }
          character=escape
        }
        command_word=command_word character
      }
      if (quote != "") return 0
      return command_word ~ /(^|\/)bd$/
    }
    function split_commands(line, segments,   position, character, quote, current, count) {
      delete segments
      count=0
      current=""
      quote=""
      for (position=1; position <= length(line); position++) {
        character=substr(line, position, 1)
        if (quote != "") {
          current=current character
          if (character == quote) {
            quote=""
          } else if (quote == "\"" && character == "\\") {
            position++
            if (position <= length(line)) current=current substr(line, position, 1)
          }
          continue
        }
        if (character == "\\") {
          current=current character
          position++
          if (position <= length(line)) current=current substr(line, position, 1)
          continue
        }
        if (character == "\"" || character == sprintf("%c", 39)) {
          quote=character
          current=current character
          continue
        }
        if (character ~ /[();|&{}]/) {
          segments[++count]=current
          current=""
          continue
        }
        current=current character
      }
      if (quote != "") return split(line, segments, /[();|&{}]+/)
      segments[++count]=current
      return count
    }
    /^[[:space:]]*#/ { next }
    {
      count=split_commands($0, segments)
      for (i=1; i<=count; i++) {
        if (invokes_bd(segments[i])) {
          print FILENAME ":" FNR ": direct Beads CLI invocation bypasses tasks-axi"
          break
        }
      }
    }
  ' "${purity_roots[@]}")
  [ -z "$findings" ] || {
    printf '%s\n' "$findings" >&2
    return 1
  }
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
FAST=0
ANALYSIS_MODE=full
PARTITION=
PARTITION_REQUESTED=0
LIST_FILES=0
LIST_PLAN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --partition)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --partition requires 1of2 or 2of2.\n' >&2; exit 2; }
      PARTITION=$2
      PARTITION_REQUESTED=1
      shift 2
      ;;
    --partition=*)
      PARTITION=${1#*=}
      PARTITION_REQUESTED=1
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --list-plan)
      LIST_PLAN=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

case "$PARTITION" in
  '')
    if [ "$PARTITION_REQUESTED" -eq 1 ]; then
      printf 'fm-lint.sh: --partition requires 1of2 or 2of2.\n' >&2
      exit 2
    fi
    ;;
  1of2|2of2)
    if [ "$FAST" -eq 1 ] || [ "$#" -gt 0 ]; then
      printf 'fm-lint.sh: --partition requires full canonical lint; omit --fast and explicit paths.\n' >&2
      exit 2
    fi
    ;;
  *) printf 'fm-lint.sh: --partition must be 1of2 or 2of2, got %s.\n' "$PARTITION" >&2; exit 2 ;;
esac

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# Per-root bounded-execution envelope. Under FM_LINT_REQUIRE_BOUNDS=1 the
# watchdog is probed and the host's acceptance of ulimit -v is checked before
# any root starts; failed checks refuse with a named error. A required-bounds run
# never lints uncapped. Without it each root still runs alone in its own
# ShellCheck process, with the same resident ceiling and no wall or
# address-space envelope, for local developer lint.
ROOT_SECONDS=${FM_LINT_ROOT_SECONDS:-1200}
ROOT_GRACE=${FM_LINT_ROOT_GRACE:-5}
# Address-space backstop, not the ordinary bound: the resident ceiling below is
# what stops an ordinary runaway. ulimit -v caps virtual address space, and
# ShellCheck's GHC runtime reserves about a third of it, so 12 GiB leaves about
# 8 GiB usable heap - above every measured real demand. This limit therefore
# only fires on a host where process sampling cannot see the runaway, which is
# why it stays wider than the ceiling instead of tracking it.
ROOT_MEMORY_KIB=${FM_LINT_ROOT_MEMORY_KIB:-12582912}
# Resident memory ceiling for one analysis. Measured x86_64 demand is roughly
# 0.09-0.6 MiB per line with sharp content dependence, and every legitimately
# sized root measured below this ceiling; a root that reaches it is a file to
# split, so the run stops it by name instead of letting it allocate gigabytes.
ROOT_MEMORY_MIB=${FM_LINT_ROOT_MEMORY_MIB:-1500}
# Scheduling estimate knobs: a root at or above the heavy line count runs
# serially on its own lane, and each root's estimate sizes the worker count.
HEAVY_LINES=${FM_LINT_HEAVY_LINES:-2500}
MEMORY_BUDGET_MIB=${FM_LINT_MEMORY_BUDGET_MIB:-}
DEFAULT_MEMORY_BUDGET_MIB=4096
SCOPE_MODE=${FM_LINT_MEMORY_SCOPE:-auto}
SCOPE_MEMORY_MIB=${FM_LINT_SCOPE_MEMORY_MIB:-}
SCOPE_SWAP_MIB=${FM_LINT_SCOPE_SWAP_MIB:-0}

fm_lint_require_positive() {  # <env-name> <value>
  case "$2" in
    ''|0*|*[!0-9]*)
      printf 'fm-lint.sh: %s must be a positive integer, got %s.\n' "$1" "$2" >&2
      exit 2
      ;;
  esac
}

fm_lint_require_positive FM_LINT_ROOT_SECONDS "$ROOT_SECONDS"
fm_lint_require_positive FM_LINT_ROOT_GRACE "$ROOT_GRACE"
fm_lint_require_positive FM_LINT_ROOT_MEMORY_KIB "$ROOT_MEMORY_KIB"
fm_lint_require_positive FM_LINT_ROOT_MEMORY_MIB "$ROOT_MEMORY_MIB"
fm_lint_require_positive FM_LINT_HEAVY_LINES "$HEAVY_LINES"
[ -z "$MEMORY_BUDGET_MIB" ] || fm_lint_require_positive FM_LINT_MEMORY_BUDGET_MIB "$MEMORY_BUDGET_MIB"
[ -z "$SCOPE_MEMORY_MIB" ] || fm_lint_require_positive FM_LINT_SCOPE_MEMORY_MIB "$SCOPE_MEMORY_MIB"
case "$SCOPE_SWAP_MIB" in
  ''|*[!0-9]*) printf 'fm-lint.sh: FM_LINT_SCOPE_SWAP_MIB must be a non-negative integer, got %s.\n' "$SCOPE_SWAP_MIB" >&2; exit 2 ;;
esac
case "$SCOPE_MODE" in
  auto|0|1) ;;
  *) printf 'fm-lint.sh: FM_LINT_MEMORY_SCOPE must be auto, 0, or 1, got %s.\n' "$SCOPE_MODE" >&2; exit 2 ;;
esac


# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_MODE=0
EXPLICIT_PATHS=0
FOLLOW_SOURCES=1
EXCLUDE_CODES=
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ -z "$PARTITION" ] && [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
if [ "$EXPLICIT_PATHS" -eq 1 ]; then
  # One developer-facing file still gets cross-file judgement.
  FOLLOW_SOURCES=1
  EXCLUDE_CODES=
else
  # A canonical run never follows sources: each library is a canonical root of
  # its own, and letting ShellCheck resolve a variable-path import re-analyzes
  # that library inside the consumer at roughly twenty times the consumer's own
  # cost. SC1091 is the note that such a statement was not followed, so it is
  # the one code this posture must exclude rather than report on every root.
  FOLLOW_SOURCES=0
  EXCLUDE_CODES=SC1091
fi
if [ "$CHANGED_MODE" -eq 1 ]; then
  EXCLUDE_CODES=$LOCAL_NOX_EXCLUDE
  [ "$FAST" -eq 1 ] || ANALYSIS_MODE=local
fi
# Stable largest-first packing is shared by cross-runner partition selection
# and the two local workers. Weights are a scheduling proxy, never a skip rule.
TAB=$(printf '\t')
fm_lint_root_weights() {
  local index=1 path weight
  for path in "${ROOTS[@]}"; do
    case "$path" in
      *"$TAB"*|*$'\n'*)
        printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
        return 2
        ;;
    esac
    weight=1
    if [ -f "$path" ]; then
      weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
    printf '%s\t%s\t%s\n' "$weight" "$index" "$path"
    index=$((index + 1))
  done
}

if [ -n "$PARTITION" ]; then
  PARTITION_ROOTS=()
  partition_weights=$(fm_lint_root_weights) || exit $?
  while IFS="$TAB" read -r index path; do
    PARTITION_ROOTS+=("$path")
  done < <(printf '%s\n' "$partition_weights" | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n | awk -F '\t' -v want="${PARTITION%%of*}" '
    { shard=(load[2] < load[1]) ? 2 : 1; load[shard]+=$1; if (shard == want) print $2 "\t" $3 }
  ' | LC_ALL=C sort -t "$TAB" -k1,1n)
  ROOTS=("${PARTITION_ROOTS[@]}")
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

# Cost-based scheduling -------------------------------------------------------
# A root's line count is the portable cost proxy: it sizes the worker count and
# decides the heavy class. It is a proxy, never a skip rule: every root is
# analyzed, and the resident ceiling is the hard bound on a root whose content
# costs far more than its line count suggests.
fm_lint_root_lines() {  # <path>
  local lines=
  [ ! -f "$1" ] || lines=$(wc -l < "$1" 2>/dev/null | tr -d '[:space:]')
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  printf '%s\n' "$lines"
}

# Estimate one analysis's peak resident demand in MiB from its line count. The
# coefficient sits above the measured median so the scheduler over-reserves
# rather than under-reserves.
fm_lint_estimate_mib() {  # <lines>
  printf '%s\n' $((48 + ($1 * 200 + 999) / 1000))
}

# The budget the worker count is sized from: an explicit override, else the
# host's current available memory, else a conservative default.
fm_lint_memory_budget_mib() {
  local avail=
  if [ -n "$MEMORY_BUDGET_MIB" ]; then
    printf '%s\n' "$MEMORY_BUDGET_MIB"
    return 0
  fi
  if [ -r /proc/meminfo ]; then
    avail=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' /proc/meminfo 2>/dev/null)
  elif command -v sysctl >/dev/null 2>&1; then
    avail=$(sysctl -n hw.memsize 2>/dev/null)
    case "$avail" in
      ''|*[!0-9]*) avail= ;;
      *) avail=$((avail / 1048576)) ;;
    esac
  fi
  case "$avail" in
    ''|0*|*[!0-9]*) avail=$DEFAULT_MEMORY_BUDGET_MIB ;;
  esac
  printf '%s\n' "$avail"
}

# How many light analyses fit in <budget-mib>: one per <peak-mib> estimate,
# never below one, never above the requested jobs or the two light shards.
fm_lint_light_workers() {  # <budget-mib> <peak-mib> <jobs>
  local budget=$1 peak=$2 jobs=$3 workers
  [ "$peak" -gt 0 ] || { printf '0\n'; return 0; }
  workers=$((budget / peak))
  [ "$workers" -ge 1 ] || workers=1
  [ "$workers" -le "$jobs" ] || workers=$jobs
  [ "$workers" -le 2 ] || workers=2
  printf '%s\n' "$workers"
}

PLAN_LINES=()
PLAN_ESTIMATE=()
PLAN_CLASS=()
HEAVY_COUNT=0
LIGHT_COUNT=0
HEAVY_PEAK_MIB=0
LIGHT_PEAK_MIB=0
plan_index=0
while [ "$plan_index" -lt "$ROOT_COUNT" ]; do
  plan_path=${ROOTS[plan_index]}
  plan_lines=$(fm_lint_root_lines "$plan_path")
  plan_estimate=$(fm_lint_estimate_mib "$plan_lines")
  if [ "$plan_lines" -ge "$HEAVY_LINES" ]; then
    plan_class=heavy
    HEAVY_COUNT=$((HEAVY_COUNT + 1))
    [ "$plan_estimate" -le "$HEAVY_PEAK_MIB" ] || HEAVY_PEAK_MIB=$plan_estimate
  else
    plan_class=light
    LIGHT_COUNT=$((LIGHT_COUNT + 1))
    [ "$plan_estimate" -le "$LIGHT_PEAK_MIB" ] || LIGHT_PEAK_MIB=$plan_estimate
  fi
  PLAN_LINES[plan_index]=$plan_lines
  PLAN_ESTIMATE[plan_index]=$plan_estimate
  PLAN_CLASS[plan_index]=$plan_class
  plan_index=$((plan_index + 1))
done
MEMORY_BUDGET_USED=$(fm_lint_memory_budget_mib)
# A heavy root occupies one concurrency slot, so --jobs 1 has to run it alone
# instead of beside a light analysis.
heavy_slot=0
[ "$HEAVY_COUNT" -eq 0 ] || heavy_slot=1
if [ "$HEAVY_COUNT" -gt 0 ] && [ "$JOBS" -le 1 ]; then
  HEAVY_ALONE=1
  LIGHT_WORKERS=$(fm_lint_light_workers "$MEMORY_BUDGET_USED" "$LIGHT_PEAK_MIB" 1)
else
  HEAVY_ALONE=0
  light_jobs=$((JOBS - heavy_slot))
  [ "$light_jobs" -ge 1 ] || light_jobs=1
  LIGHT_WORKERS=$(fm_lint_light_workers "$MEMORY_BUDGET_USED" "$LIGHT_PEAK_MIB" "$light_jobs")
fi
SCOPE_CONCURRENCY=$((LIGHT_WORKERS + heavy_slot))
[ "$SCOPE_CONCURRENCY" -ge 1 ] || SCOPE_CONCURRENCY=1
# The run cap is the sum of the intended per-root ceilings plus one GiB of
# headroom: unbounded driver, worker, and sampler memory, plus the overshoot a
# root can add between two ceiling samples. Anything larger than that belongs in
# a higher ceiling, not in a bigger cap.
if [ -z "$SCOPE_MEMORY_MIB" ]; then
  SCOPE_MEMORY_MIB=$((ROOT_MEMORY_MIB * SCOPE_CONCURRENCY + 1024))
  [ "$SCOPE_MEMORY_MIB" -ge 2048 ] || SCOPE_MEMORY_MIB=2048
fi

if [ "$LIST_PLAN" -eq 1 ]; then
  printf 'jobs\t%s\n' "$JOBS"
  printf 'heavy_lines\t%s\n' "$HEAVY_LINES"
  printf 'root_memory_ceiling_mib\t%s\n' "$ROOT_MEMORY_MIB"
  printf 'memory_budget_mib\t%s\n' "$MEMORY_BUDGET_USED"
  printf 'light_peak_mib\t%s\n' "$LIGHT_PEAK_MIB"
  printf 'heavy_peak_mib\t%s\n' "$HEAVY_PEAK_MIB"
  printf 'light_workers\t%s\n' "$LIGHT_WORKERS"
  printf 'heavy_alone\t%s\n' "$HEAVY_ALONE"
  printf 'scope_memory_mib\t%s\n' "$SCOPE_MEMORY_MIB"
  plan_index=0
  while [ "$plan_index" -lt "$ROOT_COUNT" ]; do
    printf 'root\t%s\t%s\t%s\t%s\n' "${ROOTS[plan_index]}" "${PLAN_LINES[plan_index]}" \
      "${PLAN_ESTIMATE[plan_index]}" "${PLAN_CLASS[plan_index]}"
    plan_index=$((plan_index + 1))
  done
  exit 0
fi

# Whole-run memory scope ------------------------------------------------------
# The fingerprint keeps the re-exec from recursing. The probe proves this host
# can create a user scope before any lint work starts; FM_LINT_MEMORY_SCOPE=1
# refuses rather than run unbounded, auto falls back with a named warning.
fm_lint_enter_memory_scope() {
  [ "$SCOPE_MODE" != 0 ] || return 0
  [ "${FM_LINT_SCOPE_ACTIVE:-0}" != 1 ] || return 0
  if ! command -v systemd-run >/dev/null 2>&1 \
    || ! systemd-run --user --scope -q true >/dev/null 2>&1; then
    if [ "$SCOPE_MODE" = 1 ]; then
      printf 'fm-lint.sh: FM_LINT_MEMORY_SCOPE=1 but user scopes are unavailable on this host.\n' >&2
      exit 2
    fi
    printf 'fm-lint.sh: user scopes unavailable; running without the run-level memory cap\n' >&2
    return 0
  fi
  printf 'fm-lint.sh: run memory cap %s MiB (swap %s MiB)\n' "$SCOPE_MEMORY_MIB" "$SCOPE_SWAP_MIB" >&2
  FM_LINT_SCOPE_ACTIVE=1 exec systemd-run --user --scope -q \
    -p "MemoryMax=${SCOPE_MEMORY_MIB}M" \
    -p "MemorySwapMax=${SCOPE_SWAP_MIB}M" \
    -- "${BASH:-bash}" "$SELF" "${FM_LINT_ARGV[@]}"
}

fm_lint_enter_memory_scope

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required (pinned version), found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if [ "$FAST" -eq 1 ] && [ "$FOLLOW_SOURCES" -eq 0 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled; source following disabled; excluding %s\n' "$EXCLUDE_CODES" >&2
elif [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled; source following enabled\n' >&2
elif [ "$CHANGED_MODE" -eq 1 ]; then
  printf 'fm-lint.sh: changed-file mode; ShellCheck source following disabled; excluding %s\n' "$EXCLUDE_CODES" >&2
elif [ "$EXPLICIT_PATHS" -eq 1 ]; then
  printf 'fm-lint.sh: explicit paths; ShellCheck source following enabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled; source following disabled; excluding %s\n' "$EXCLUDE_CODES" >&2
fi

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_backend_purity || overall_rc=$?
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

BOUND_MECH=none
if [ "${FM_LINT_REQUIRE_BOUNDS:-0}" = 1 ]; then
  bounds_problems=()
  if declare -F fm_exec_timed >/dev/null 2>&1; then
    # perl is mandatory above, so fm_exec_timed always takes its perl watchdog.
    BOUND_MECH=perl
  else
    bounds_problems+=('bin/fm-timeout-lib.sh is missing beside fm-lint.sh, so no watchdog is available')
  fi
  if [ "$BOUND_MECH" != none ]; then
    # Exercise the real bound end to end before any root starts: a clean probe
    # must exit 0 and an over-deadline probe must come back as a timeout, so a
    # watchdog that cannot actually bound a command (a perl without
    # Time::HiRes, say) refuses the run here instead of failing every root at
    # run time.
    probe_rc=0
    ( fm_exec_timed 30 1 true ) >/dev/null 2>&1 || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
      bounds_problems+=("the timeout watchdog could not run a probe command (rc=$probe_rc)")
    else
      probe_rc=0
      ( fm_exec_timed 2 1 sleep 30 ) >/dev/null 2>&1 || probe_rc=$?
      case "$probe_rc" in
        124|137) : ;;
        *) bounds_problems+=("the timeout watchdog did not bound an over-deadline probe (rc=$probe_rc)") ;;
      esac
    fi
  fi
  ( ulimit -v "$ROOT_MEMORY_KIB" ) 2>/dev/null \
    || bounds_problems+=("per-root memory limit FM_LINT_ROOT_MEMORY_KIB=$ROOT_MEMORY_KIB KiB is not enforceable on this host (ulimit -v)")
  if [ "${#bounds_problems[@]}" -gt 0 ]; then
    for problem in "${bounds_problems[@]}"; do
      printf 'fm-lint.sh: bounds required but %s.\n' "$problem" >&2
    done
    printf 'fm-lint.sh: refusing to lint uncapped under FM_LINT_REQUIRE_BOUNDS=1.\n' >&2
    exit 2
  fi
fi

PROGRESS=0
if [ -n "$PARTITION" ]; then
  PROGRESS=1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# Signal every analysis group the workers published. A worker killed before its
# trap runs would otherwise leave its analysis behind, because that analysis
# deliberately runs in a group of its own so the ceiling monitor can stop it
# without ending the worker.
# shellcheck disable=SC2329 # Invoked from the EXIT and signal trap handler below.
fm_lint_signal_runs() {  # <signal>
  local pgid_file pgid
  [ -n "${OUTPUT_DIR:-}" ] || return 0
  for pgid_file in "$OUTPUT_DIR"/*.pgid; do
    [ -f "$pgid_file" ] || continue
    pgid=$(cat "$pgid_file" 2>/dev/null) || continue
    case "$pgid" in ''|*[!0-9]*) continue ;; esac
    kill -"$1" -- "-$pgid" 2>/dev/null || true
  done
}

# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid i=0 alive
  fm_lint_signal_runs TERM
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  # Give each worker time to run its own trap, which forwards the same
  # terminate-then-kill sweep. The wait is bounded so a wedged worker still gets
  # killed, and the recorded groups above cover a worker that never got there.
  while [ "$i" -lt 200 ]; do
    alive=0
    for pid in "${ACTIVE_PIDS[@]:-}"; do
      [ -n "$pid" ] || continue
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 1 ] || break
    sleep 0.01 2>/dev/null || { sleep 1; i=$((i + 100)); }
    i=$((i + 1))
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_lint_signal_runs KILL
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"

# The roots log is the retained per-root lifecycle sidecar; beside --telemetry
# it survives as ${TELEMETRY%.tsv}.roots.tsv even when a run is killed
# mid-flight.
if [ -n "$TELEMETRY" ]; then
  ROOTS_LOG=${TELEMETRY%.tsv}.roots.tsv
else
  ROOTS_LOG=$TMP_ROOT/roots.tsv
fi
: > "$ROOTS_LOG"
if [ "$BOUND_MECH" != none ]; then
  bounds_applied=1
  root_deadline_meta=$ROOT_SECONDS
  root_grace_meta=$ROOT_GRACE
  root_memory_meta=$ROOT_MEMORY_KIB
else
  bounds_applied=0
  root_deadline_meta=unbounded
  root_grace_meta=unbounded
  root_memory_meta=unbounded
fi
{
  printf 'format\t%s\n' 'fm-lint-roots-v1'
  printf 'meta\t%s\t%s\n' 'shellcheck_version' "$resolved"
  printf 'meta\t%s\t%s\n' 'platform' "$(uname -s) $(uname -m)"
  printf 'meta\t%s\t%s\n' 'image_os' "${ImageOS:-unknown}"
  printf 'meta\t%s\t%s\n' 'image_version' "${ImageVersion:-unknown}"
  printf 'meta\t%s\t%s\n' 'mode' "$ANALYSIS_MODE"
  printf 'meta\t%s\t%s\n' 'partition' "${PARTITION:-all}"
  printf 'meta\t%s\t%s\n' 'jobs' "$JOBS"
  printf 'meta\t%s\t%s\n' 'bounds_enforced' "$bounds_applied"
  printf 'meta\t%s\t%s\n' 'root_deadline_seconds' "$root_deadline_meta"
  printf 'meta\t%s\t%s\n' 'root_kill_grace_seconds' "$root_grace_meta"
  printf 'meta\t%s\t%s\n' 'root_memory_limit_kib' "$root_memory_meta"
  printf 'meta\t%s\t%s\n' 'root_memory_ceiling_mib' "$ROOT_MEMORY_MIB"
  printf 'meta\t%s\t%s\n' 'memory_budget_mib' "$MEMORY_BUDGET_USED"
  printf 'meta\t%s\t%s\n' 'light_workers' "$LIGHT_WORKERS"
  printf 'meta\t%s\t%s\n' 'heavy_roots' "$HEAVY_COUNT"
  printf 'meta\t%s\t%s\n' 'heavy_alone' "$HEAVY_ALONE"
  printf 'meta\t%s\t%s\n' 'run_memory_scope_mib' "${FM_LINT_SCOPE_ACTIVE:+$SCOPE_MEMORY_MIB}"
  printf 'meta\t%s\t%s\n' 'timing_mechanism' "$BOUND_MECH"
} >> "$ROOTS_LOG"

# Two light lanes pack by estimate; the heavy lane is a third manifest that
# runs one root at a time, so a pathological analysis is never in flight beside
# another one.
SHARD_COUNT=2
HEAVY_LANE=$SHARD_COUNT
worker=0
while [ "$worker" -le "$HEAVY_LANE" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done
LIGHT_LANE_LOADS=(0 0)
LIGHT_LANE_BYTES=(0 0)
HEAVY_LANE_BYTES=0

fm_lint_root_weights > "$WEIGHTS" || exit $?

# Split the plan into heavy and light rows, then pack the light rows
# largest-estimate-first onto whichever lane holds less work. Lane membership
# never changes the diagnostics, only when each root runs; each manifest is
# finally ordered by canonical index so the replay is stable.
: > "$TMP_ROOT/light.rows"
: > "$TMP_ROOT/heavy.rows"
plan_index=0
while [ "$plan_index" -lt "$ROOT_COUNT" ]; do
  row_path=${ROOTS[plan_index]}
  row_index=$((plan_index + 1))
  row_bytes=0
  if [ -f "$row_path" ]; then
    row_bytes=$(wc -c < "$row_path" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$row_bytes" in ''|*[!0-9]*) row_bytes=0 ;; esac
  if [ "${PLAN_CLASS[plan_index]}" = heavy ]; then
    printf '%s\t%s\t%s\t%s\n' "$row_index" "$row_path" \
      "${PLAN_ESTIMATE[plan_index]}" "$row_bytes" >> "$TMP_ROOT/heavy.rows"
  else
    printf '%s\t%s\t%s\t%s\n' "$row_index" "$row_path" \
      "${PLAN_ESTIMATE[plan_index]}" "$row_bytes" >> "$TMP_ROOT/light.rows"
  fi
  plan_index=$((plan_index + 1))
done
while IFS="$TAB" read -r index path estimate bytes; do
  [ -n "$index" ] || continue
  worker=0
  if [ "${LIGHT_LANE_LOADS[1]}" -lt "${LIGHT_LANE_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  LIGHT_LANE_LOADS[worker]=$((LIGHT_LANE_LOADS[worker] + estimate))
  LIGHT_LANE_BYTES[worker]=$((LIGHT_LANE_BYTES[worker] + bytes))
done < <(LC_ALL=C sort -t "$TAB" -k3,3nr -k1,1n "$TMP_ROOT/light.rows")
while IFS="$TAB" read -r index path estimate bytes; do
  [ -n "$index" ] || continue
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$HEAVY_LANE"
  HEAVY_LANE_BYTES=$((HEAVY_LANE_BYTES + bytes))
done < <(LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/heavy.rows")
worker=0
while [ "$worker" -le "$HEAVY_LANE" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  local -a worker_env
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  worker_env=(
    FM_LINT_INTERNAL=1
    FM_LINT_INTERNAL_FAST="$FAST"
    FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES"
    FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES"
    FM_LINT_INTERNAL_BOUNDED="$BOUND_MECH"
    FM_LINT_INTERNAL_MEMORY_KIB="$ROOT_MEMORY_KIB"
    FM_LINT_INTERNAL_CEILING_MIB="$ROOT_MEMORY_MIB"
    FM_LINT_INTERNAL_ROOT_SECS="$ROOT_SECONDS"
    FM_LINT_INTERNAL_GRACE="$ROOT_GRACE"
    FM_LINT_INTERNAL_ROOTS_LOG="$ROOTS_LOG"
    FM_LINT_INTERNAL_MODE="$ANALYSIS_MODE"
    FM_LINT_INTERNAL_PROGRESS="$PROGRESS"
    FM_LINT_SHELLCHECK="$SHELLCHECK_BIN"
    FM_LINT_PERL_BIN="$PERL_BIN"
  )
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env "${worker_env[@]}" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

# The heavy lane holds at most one analysis at a time by construction: one
# worker drains it. It is started beside the light lanes when the job count and
# the memory budget leave room, and alone first otherwise, so a --jobs 1 run
# never puts a heavy root in flight next to another analysis.
if [ "$HEAVY_COUNT" -gt 0 ]; then
  if [ "$HEAVY_ALONE" -eq 1 ]; then
    fm_lint_start_worker "$HEAVY_LANE"
    fm_lint_wait_workers
  else
    fm_lint_start_worker "$HEAVY_LANE"
  fi
fi
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  fm_lint_start_worker "$worker"
  worker=$((worker + 1))
  [ "$worker" -lt "$SHARD_COUNT" ] || break
  if [ "$LIGHT_WORKERS" -le 1 ]; then
    fm_lint_wait_workers
  fi
done
fm_lint_wait_workers

# Replay every lane in deterministic order and select the first nonzero lane
# status. ShellCheck processes every root in a lane after earlier findings.
overall_rc=0
worker=0
LAST_LANE=$((SHARD_COUNT - 1))
[ "$HEAVY_COUNT" -eq 0 ] || LAST_LANE=$HEAVY_LANE
while [ "$worker" -le "$LAST_LANE" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

# Close the roots log with completion counts so a mid-run kill leaves
# begun-but-unfinished roots attributable by name. result_exit is appended
# after the purity and workflow checks so it records the run's final status.
if [ -s "$ROOTS_LOG" ]; then
  read -r roots_completed roots_unfinished roots_begun <<EOF
$(awk -F '\t' '
  $1 == "begin" { begun[$2 FS $3] = 1; total++ }
  $1 == "end" { ended[$2 FS $3] = 1; done_count++ }
  END { unfinished = 0; for (key in begun) if (!(key in ended)) unfinished++
        printf "%d %d %d\n", done_count + 0, unfinished, total + 0 }
' "$ROOTS_LOG")
EOF
  {
    printf 'meta\t%s\t%s\n' 'roots_begun' "$roots_begun"
    printf 'meta\t%s\t%s\n' 'roots_completed' "$roots_completed"
    printf 'meta\t%s\t%s\n' 'roots_unfinished' "$roots_unfinished"
  } >> "$ROOTS_LOG"
fi

purity_rc=0
fm_lint_run_backend_purity || purity_rc=$?
if [ "$overall_rc" -eq 0 ] && [ "$purity_rc" -ne 0 ]; then
  overall_rc=$purity_rc
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  source_followed=0
  awk -F '\t' '$1 == "end" && $12 == 0 { print $2 }' "$ROOTS_LOG" > "$TMP_ROOT/no-source-indices"
  root_index=0
  for path in "${ROOTS[@]}"; do
    root_index=$((root_index + 1))
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" > "$TMP_ROOT/root-source-targets"
      cat "$TMP_ROOT/root-source-targets" >> "$TMP_ROOT/source-targets"
      if [ "$FOLLOW_SOURCES" -eq 1 ] \
        && ! grep -qx "$root_index" "$TMP_ROOT/no-source-indices"; then
        followed_here=$(grep -cv '^/dev/null$' "$TMP_ROOT/root-source-targets" || true)
        source_followed=$((source_followed + followed_here))
      fi
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  if [ "${FM_LINT_SCOPE_ACTIVE:-0}" = 1 ]; then
    scope_meta=$SCOPE_MEMORY_MIB
  else
    scope_meta=none
  fi
  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'partition\t%s\n' "${PARTITION:-all}"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_bounds_enforced\t%s\n' "$bounds_applied"
    printf 'root_deadline_seconds\t%s\n' "$root_deadline_meta"
    printf 'root_kill_grace_seconds\t%s\n' "$root_grace_meta"
    printf 'root_memory_limit_kib\t%s\n' "$root_memory_meta"
    printf 'root_timing_mechanism\t%s\n' "$BOUND_MECH"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${LIGHT_LANE_BYTES[0]:-0}"
    printf 'shard_2_weight_bytes\t%s\n' "${LIGHT_LANE_BYTES[1]:-0}"
    printf 'heavy_lane_weight_bytes\t%s\n' "$HEAVY_LANE_BYTES"
    printf 'heavy_root_count\t%s\n' "$HEAVY_COUNT"
    printf 'light_root_count\t%s\n' "$LIGHT_COUNT"
    printf 'light_workers\t%s\n' "$LIGHT_WORKERS"
    printf 'heavy_alone\t%s\n' "$HEAVY_ALONE"
    printf 'root_memory_ceiling_mib\t%s\n' "$ROOT_MEMORY_MIB"
    printf 'memory_budget_mib\t%s\n' "$MEMORY_BUDGET_USED"
    printf 'run_memory_scope_mib\t%s\n' "$scope_meta"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

if [ -s "$ROOTS_LOG" ]; then
  printf 'meta\t%s\t%s\n' 'result_exit' "$overall_rc" >> "$ROOTS_LOG"
fi

exit "$overall_rc"
