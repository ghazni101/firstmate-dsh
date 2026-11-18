#!/usr/bin/env bash
# fm-native-lib.sh - native (DSH) task-lease enforcement for the mutating engine.
#
# This is phase 2's integration seam. The mutating entrypoints (fm-send,
# fm-control, fm-teardown, fm-approval-failover) already call
# `fm_lease_guard` for per-task overlap; fm-pr-merge, fm-merge-local, fm-spawn,
# and fm-teardown also call `fm_lease_forbid_branch`. bin/fm-lease-lib.sh routes
# those two calls here when the home is a native home, so the six entrypoints do
# not each grow a second ownership model.
#
# WHAT CHANGES IN A NATIVE HOME.
#   - Task ownership is the DSH per-task lease (state/leases/<task>.lease): TTL,
#     heartbeat, fencing token, no fleet-lock dependence.
#   - The two-actor `main`/`branch` partition does not exist: there is no branch
#     actor in the native design, so `fm_lease_forbid_branch` returns 0 here.
#     bin/fm-lease-lib.sh keeps the refusal for a home that has not opted in,
#     where the branch actor can still be marking its own processes.
#   - A mutation must present the live token and the holding session
#     (FM_LEASE_TOKEN, FM_LEASE_SESSION, and the matching FM_LEASE_TASK) that the
#     native channel or reconciliation loop exported when it took the lease. A
#     direct shell invocation without those variables is refused loudly rather
#     than mutating an unowned task.
#   - No home-wide session record is read or written by this path.
#
# OPT-IN. The home creates `config/dsh-native-lease` and records the plugin
# package root in `config/native-plugin-dir` (or exports FM_NATIVE_PLUGIN_DIR).
# Without the marker this file is inert, so a non-native home behaves byte for
# byte as before. With the marker but no usable lease identity, mutations refuse
# (fail closed) instead of proceeding unguarded.
#
# Source-safe: set -u / set -e compatible, no side effects beyond defaults.

FM_NATIVE_REFUSE_EXIT=6
: "${FM_NATIVE_PLUGIN_DIR:=}"
: "${FM_NATIVE_NODE:=${DSH_NODE_EXECUTABLE:-node}}"

# fm_native_config: the home config directory, resolved exactly as the engine
# resolves it for its other config markers.
fm_native_config() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$STATE/..}/config}"
}

# fm_native_lease_enabled: 0 iff this home opted in to native lease enforcement.
fm_native_lease_enabled() {
  [ -f "$(fm_native_config)/dsh-native-lease" ]
}

# fm_native_plugin_dir: the native plugin package root, from the environment
# first and then from the home's recorded config.
fm_native_plugin_dir() {
  local dir=${FM_NATIVE_PLUGIN_DIR:-} file line
  if [ -z "$dir" ]; then
    file="$(fm_native_config)/native-plugin-dir"
    if [ -r "$file" ]; then
      IFS= read -r line < "$file" || line=
      dir=${line%%#*}
      dir=${dir#"${dir%%[![:space:]]*}"}
      dir=${dir%"${dir##*[![:space:]]}"}
    fi
  fi
  printf '%s\n' "$dir"
}

# fm_native_lease_guard <task> <action-label>: refuse unless the caller holds a
# live native lease for <task>. Exits FM_NATIVE_REFUSE_EXIT on refusal, like the
# two-actor guard it replaces. Returns 0 on success.
fm_native_lease_guard() {
  local task=$1 action=$2 home=${FM_HOME:-} token=${FM_LEASE_TOKEN:-} session=${FM_LEASE_SESSION:-} dir cli out
  if [ -z "$home" ]; then
    printf 'error: %s refused - FM_HOME is unset, so the native task lease cannot be resolved\n' "$action" >&2
    exit "$FM_NATIVE_REFUSE_EXIT"
  fi
  dir=$(fm_native_plugin_dir)
  cli="$dir/bin/fm-lease.mjs"
  if [ -z "$dir" ] || [ ! -f "$cli" ]; then
    printf 'error: %s refused - this is a native home but the lease CLI is unavailable; record the plugin package root in %s or export FM_NATIVE_PLUGIN_DIR\n' \
      "$action" "$(fm_native_config)/native-plugin-dir" >&2
    exit "$FM_NATIVE_REFUSE_EXIT"
  fi
  if [ -z "$token" ] || [ -z "$session" ]; then
    printf 'error: %s refused - task %s has no live native lease in this call (FM_LEASE_TOKEN/FM_LEASE_SESSION are unset); run the mutation through the native plugin channel or the reconciliation loop, which take the task lease around it\n' \
      "$action" "$task" >&2
    exit "$FM_NATIVE_REFUSE_EXIT"
  fi
  if [ -n "${FM_LEASE_TASK:-}" ] && [ "$FM_LEASE_TASK" != "$task" ]; then
    printf 'error: %s refused - the held lease belongs to task %s, not %s\n' "$action" "$FM_LEASE_TASK" "$task" >&2
    exit "$FM_NATIVE_REFUSE_EXIT"
  fi
  if ! command -v "$FM_NATIVE_NODE" >/dev/null 2>&1; then
    printf 'error: %s refused - node (%s) is required to verify the native task lease\n' "$action" "$FM_NATIVE_NODE" >&2
    exit "$FM_NATIVE_REFUSE_EXIT"
  fi
  if ! out=$("$FM_NATIVE_NODE" "$cli" guard --home "$home" --task "$task" --token "$token" --session "$session" 2>&1); then
    printf 'error: %s refused - task %s lease token %s is not live (see below); re-acquire the task lease and retry\n%s\n' \
      "$action" "$task" "$token" "$out" >&2
    exit "$FM_NATIVE_REFUSE_EXIT"
  fi
  export FM_LEASE_TASK=$task
}

# fm_native_lease_release: native guards never own the lease they verify, so the
# release hook the two-actor guard uses is a no-op here. The actor that acquired
# the lease releases it.
fm_native_lease_release() {
  return 0
}
