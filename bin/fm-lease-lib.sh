#!/usr/bin/env bash
# fm-lease-lib.sh - the native per-task lease seam every guarded entrypoint calls.
#
# WHAT THIS IS. One session is one peer owner of its home, so task ownership is
# the DSH per-task lease and nothing else: a fencing token, a TTL, a heartbeat,
# and reaping, all owned by bin/fm-native-lib.sh and dsh-plugin/src/lease.js
# ([docs/dsh-native-architecture.md](../docs/dsh-native-architecture.md)
# section 4). This file is the seam that lets the mutating entrypoints ask that
# owner without each of them growing a second ownership model.
#
# WHERE THE RECORD LIVES. state/leases/<task>.lease, a JSON record carrying the
# holder's session, purpose, TTL and fencing token. The retired two-actor
# contract kept a one-line state/.lease-<task> naming "main" or "branch"; that
# partition is gone with the fleet session lock, because there is no second
# actor to partition against.
#
# THE TWO CALLS.
#   fm_lease_guard <task> <action-label>
#     In a native-lease home, refuse the guarded mutation unless the caller
#     presents the live lease token for that task (bin/fm-native-lib.sh).
#     bin/fm-send.sh, bin/fm-control.sh, bin/fm-teardown.sh,
#     bin/fm-approval-failover.sh, bin/fm-pr-merge.sh and
#     bin/fm-merge-local.sh call it. bin/fm-spawn.sh deliberately does not: a
#     fresh spawn creates the task it would need a lease for, so it stays
#     fenced by its spawn lock and backlog transition instead
#     (docs/dsh-native-architecture.md section 4.11).
#   fm_lease_forbid_branch <action-label>
#     The surviving half of the retired role partition. A home that records
#     config/dsh-native-lease has no branch actor, so every action is the calling
#     session's own and this returns 0; a home that has not opted in refuses the
#     process that still marks itself as the supervision-branch actor
#     (FM_SUPERVISION_ACTOR=branch). dsh-plugin/test/native-guard.test.mjs pins
#     both halves of that seam, so this shim outlives the lease it was named for
#     until the branch actor itself goes.
#
# OPT-IN. bin/fm-native-lib.sh enforces only in a home that records
# config/dsh-native-lease. Without that marker the guard is inert, exactly as
# the native seam has been since phase 2, so a home that has not migrated keeps
# its previous behavior instead of losing an enforcement it never had.
#
# Sourced by the entrypoints above. Callers must have $STATE resolved. No side
# effects on source. set -u / set -e safe.

# Distinct from usage errors (2) and the gate refusal (3): the other session
# holds this task right now, so retry after it releases.
# shellcheck disable=SC2034 # Read by the guarded entrypoints that exit with it.
FM_LEASE_REFUSE_EXIT=6
FM_LEASE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# A torn checkout (the library updated before its sibling landed) must not break
# every lease consumer, so a missing seam refuses rather than mutating unowned.
if [ -r "$FM_LEASE_LIB_DIR/fm-native-lib.sh" ]; then
  # shellcheck source=bin/fm-native-lib.sh
  . "$FM_LEASE_LIB_DIR/fm-native-lib.sh"
else
  fm_native_lease_enabled() { return 1; }
  fm_native_lease_guard() { printf 'error: native lease seam is missing beside %s\n' "$FM_LEASE_LIB_DIR" >&2; exit 6; }
  fm_native_lease_release() { return 0; }
fi

# fm_lease_valid_id <id>: 0 iff the task id is safe to embed in a state filename.
fm_lease_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_lease_guard <task> <action-label>: the per-task ownership gate. Inert in a
# home that has not recorded config/dsh-native-lease, exactly as the native seam
# has been since phase 2. In a native home a task id that cannot name a lease
# record refuses, because no lease can be shown to cover it.
fm_lease_guard() {
  local task=$1 action=$2
  fm_native_lease_enabled || return 0
  if ! fm_lease_valid_id "$task"; then
    printf 'error: %s refused - task id %s cannot name a native task lease\n' "$action" "'$task'" >&2
    exit "$FM_LEASE_REFUSE_EXIT"
  fi
  fm_native_lease_guard "$task" "$action"
}

# fm_lease_guard_release: release the claim serialization fm_lease_guard holds.
# Idempotent, so callers can use it unconditionally from EXIT cleanup.
fm_lease_guard_release() {
  fm_native_lease_enabled || return 0
  fm_native_lease_release
}

# fm_lease_forbid_branch <action-label>: refuse (exit FM_LEASE_REFUSE_EXIT) a
# non-native home's supervision-branch actor; pass everywhere else.
fm_lease_forbid_branch() {
  local action=${1:-action}
  fm_native_lease_enabled && return 0
  [ "${FM_SUPERVISION_ACTOR:-main}" = branch ] || return 0
  printf 'error: %s refused - the supervision branch never performs this action; report the outcome and leave it to main (docs/pi-supervision-branch.md)\n' "$action" >&2
  return "$FM_LEASE_REFUSE_EXIT"
}
