#!/usr/bin/env bash
# fm-lease2-lib.sh - bash adapter for the DSH-native per-task lease.
#
# The protocol lives in dsh-plugin/src/lease.js and one CLI
# (dsh-plugin/bin/fm-lease.mjs) owns it. This file is the thin bash wrapper that
# engine scripts source when they need a lease guard; it never reimplements the
# protocol, never caches a verdict, and never removes a lease file itself.
#
# WHY THIS EXISTS. Phase 2 wires this adapter into the mutating bin entrypoints
# (fm-send, fm-control, fm-teardown, fm-pr-merge, fm-merge-local, fm-spawn)
# behind the per-home config/dsh-native-lease marker, replacing the fleet-lock
# ownership gate with a task-scoped fencing token. Phase 1 ships the adapter and
# tests it; no bin script sources it yet.
#
# CONTRACT.
#   - Every function takes an explicit home and task; there is no ambient home.
#     The CLI refuses a home other than $FM_HOME (cross-home, exit 6), so a
#     caller with the wrong environment fails loudly instead of writing into
#     another home.
#   - acquire prints the fencing token on stdout and sets FM_LEASE2_TOKEN.
#     renew/release/inspect/reap print the CLI's JSON. guard runs a command with
#     FM_LEASE_HOME, FM_LEASE_TASK, FM_LEASE_TOKEN, FM_LEASE_OWNER exported and
#     returns the command's own exit status.
#   - Failure output goes to stderr and the function returns the CLI's exit
#     code: 2 usage, 3 not-held/expired/unreadable, 4 fenced, 5 contention,
#     6 cross-home, 7 busy.
#   - A lease is task authority only. Expiry never kills a worker, tears down
#     work, or marks a task done.
#
# ENVIRONMENT.
#   FM_NATIVE_PLUGIN_DIR  plugin package root; defaults to this file's parent
#                         directory's parent, and is set by the plugin for every
#                         script it runs, so a linked or workspace checkout both
#                         resolve.
#   FM_NATIVE_NODE        node executable; defaults to DSH_NODE_EXECUTABLE from
#                         the DSH process, else `node`.
#   FM_HOME               the caller's home; the CLI compares it with --home.
#   FM_LEASE2_SESSION     stable holder label for this shell; defaults to
#                         shell:$$. It is pinned at source time because a bash
#                         caller acquires inside `$(...)`, whose subshell would
#                         otherwise give the CLI a different parent pid - and
#                         therefore a different holder - than the later renew,
#                         guard, and release calls.
#
# Usage:
#   . path/to/fm-lease2-lib.sh
#   token=$(fm_lease2_acquire "$FM_HOME" "$task" "land PR") || exit
#   fm_lease2_guard "$FM_HOME" "$task" "$token" -- bin/fm-pr-merge.sh "$task" "$url"
#   fm_lease2_release "$FM_HOME" "$task" "$token"
#
# Source-safe: set -u compatible, no side effects beyond variable defaults.

FM_LEASE2_LIB_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
: "${FM_NATIVE_PLUGIN_DIR:=$(cd "$FM_LEASE2_LIB_DIR/.." && pwd)}"
: "${FM_NATIVE_NODE:=${DSH_NODE_EXECUTABLE:-node}}"
FM_LEASE2_CLI="$FM_NATIVE_PLUGIN_DIR/bin/fm-lease.mjs"
FM_LEASE2_TOKEN="${FM_LEASE2_TOKEN:-}"
# `$$` stays the same inside a command-substitution subshell, so one shell keeps
# one holder identity across acquire, renew, guard, and release.
FM_LEASE2_SESSION="${FM_LEASE2_SESSION:-shell:$$}"

# fm_lease2_cli <args...>: run the owning CLI.
fm_lease2_cli() {
  if [ ! -f "$FM_LEASE2_CLI" ]; then
    printf 'fm-lease2: lease CLI not found at %s (set FM_NATIVE_PLUGIN_DIR to the plugin package root)\n' "$FM_LEASE2_CLI" >&2
    return 2
  fi
  "$FM_NATIVE_NODE" "$FM_LEASE2_CLI" "$@"
}

# fm_lease2_token_field <json>: print the first "token":<n> integer, or nothing.
fm_lease2_token_field() {
  printf '%s' "$1" | sed -n 's/.*"token":\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# fm_lease2_require_home: require FM_HOME so the CLI's cross-home check has one
# unambiguous environment to compare against.
fm_lease2_require_home() {
  if [ -z "${FM_HOME:-}" ]; then
    printf 'fm-lease2: FM_HOME is required; refusing an ambient-home lease\n' >&2
    return 2
  fi
}

# fm_lease2_acquire <home> <task> [purpose] [ttl-ms]: print the fencing token.
# A same-session re-acquire keeps the token (idempotent refresh).
fm_lease2_acquire() {
  local home=$1 task=$2 purpose=${3:-} ttl=${4:-} out rc token
  fm_lease2_require_home || return $?
  local argv=(acquire --home "$home" --task "$task" --session "$FM_LEASE2_SESSION")
  [ -n "$purpose" ] && argv+=(--purpose "$purpose")
  [ -n "$ttl" ] && argv+=(--ttl-ms "$ttl")
  out=$(fm_lease2_cli "${argv[@]}") || {
    rc=$?
    printf '%s\n' "$out" >&2
    return "$rc"
  }
  token=$(fm_lease2_token_field "$out")
  if [ -z "$token" ]; then
    printf 'fm-lease2: acquire returned no fencing token: %s\n' "$out" >&2
    return 2
  fi
  FM_LEASE2_TOKEN=$token
  printf '%s\n' "$token"
}

# fm_lease2_renew <home> <task> <token>: refresh a held lease.
fm_lease2_renew() {
  fm_lease2_require_home || return $?
  fm_lease2_cli renew --home "$1" --task "$2" --token "$3" --session "$FM_LEASE2_SESSION"
}

# fm_lease2_release <home> <task> <token>: drop a held lease.
fm_lease2_release() {
  fm_lease2_require_home || return $?
  fm_lease2_cli release --home "$1" --task "$2" --token "$3" --session "$FM_LEASE2_SESSION"
}

# fm_lease2_inspect <home> <task>: print the current lease inspection JSON.
fm_lease2_inspect() {
  fm_lease2_cli inspect --home "$1" --task "$2"
}

# fm_lease2_reap <home>: free every expired held lease in the home.
fm_lease2_reap() {
  fm_lease2_require_home || return $?
  fm_lease2_cli reap --home "$1" --session "$FM_LEASE2_SESSION"
}

# fm_lease2_guard <home> <task> <token> [--] <command...>: run a command only
# while the token is live, with the lease identity exported.
fm_lease2_guard() {
  local home=$1 task=$2 token=$3
  shift 3
  [ "${1:-}" = "--" ] && shift
  if [ "$#" -eq 0 ]; then
    printf 'fm-lease2: guard requires a command after --\n' >&2
    return 2
  fi
  fm_lease2_require_home || return $?
  fm_lease2_cli guard --home "$home" --task "$task" --token "$token" --session "$FM_LEASE2_SESSION" -- "$@"
}

# fm_lease2_check <home> <task> <token>: verify a lease without running anything.
fm_lease2_check() {
  fm_lease2_require_home || return $?
  fm_lease2_cli guard --home "$1" --task "$2" --token "$3" --session "$FM_LEASE2_SESSION" >/dev/null
}

# fm_lease2_live_token <home> <task>: print the live token, or nothing.
# Returns 1 when no live holder exists.
fm_lease2_live_token() {
  local out token
  out=$(fm_lease2_inspect "$1" "$2" 2>/dev/null) || return 1
  case "$out" in
    *'"live":true'*) ;;
    *) return 1 ;;
  esac
  token=$(fm_lease2_token_field "$out")
  [ -n "$token" ] || return 1
  printf '%s\n' "$token"
}
