#!/usr/bin/env bash
# shellcheck disable=SC2034 # Output parameters and mode tables are read by bin/fm-delivery.sh and bin/fm-spawn.sh.
# fm-delivery-lib.sh - per-PR (and per-task) delivery decisions.
#
# WHY. Firstmate resolves a task's delivery mode (no-mistakes | direct-PR |
# local-only) at intake and passes it explicitly to bin/fm-spawn.sh and
# bin/fm-brief.sh. That decision is per task, but the unit a captain actually
# reasons about is often one pull request: "gate THIS PR with no-mistakes", or
# "skip the pipeline for this one". This library is the one owner of a durable,
# PR-scoped decision record and of the resolution order that makes it
# authoritative.
#
# ORDER OF AUTHORITY (first match wins):
#   1. A PR record keyed by the canonical pull/merge-request identity.
#   2. A task record keyed by the task id.
#   3. The project's registered posture (bin/fm-project-mode.sh).
#   4. The unregistered default: no-mistakes, yolo off.
# A PR record wins over a task record because it names the artifact; the loser is
# reported as `shadowed` rather than hidden. A record only overrides the axes it
# states: `yolo=inherit` keeps the project registry's merge authority.
#
# RECORD. Flat key=value text (the engine's record idiom, no jq dependency):
#   <home>/data/delivery/task-<id>.record
#   <home>/data/delivery/pr-<host>_<owner>_<repo>_<number>.record
# Fields: version, kind, key, task, pr_url, branch, project, delivery, yolo,
# decided_at, reason, supersedes, previous.
#
# INVARIANTS.
#   - The record is durable intent; a forge label or a chat message is not. A
#     later label sync may propose a record, but resolution never reads a label.
#   - Writing is atomic (temp + rename) and never rewrites history: a changed
#     record keeps `supersedes` and the previous value for audit.
#   - Resolution never mutates. `enforce-task` refuses a spawn whose explicit
#     mode/yolo contradicts an explicit task or PR record, so the switch cannot
#     be silently bypassed at dispatch.
#   - Nothing here starts, stops, or inspects a no-mistakes run. A run's evidence
#     stays owned by bin/fm-nm-run-lib.sh; this layer only decides whether the
#     gate is the required delivery path for a PR.
#
# Sourced by bin/fm-delivery.sh and bin/fm-spawn.sh. set -u safe; requires
# FM_HOME (or FM_DATA_OVERRIDE) resolved before calling.

FM_DELIVERY_VERSION='fm-delivery-v1'
FM_DELIVERY_MODE_SET='no-mistakes direct-PR local-only'
FM_DELIVERY_REFUSE_EXIT=6

fm_delivery_home() {
  printf '%s\n' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
}

fm_delivery_data_dir() {
  printf '%s\n' "${FM_DATA_OVERRIDE:-$(fm_delivery_home)/data}"
}

fm_delivery_dir() {
  printf '%s\n' "$(fm_delivery_data_dir)/delivery"
}

fm_delivery_meta_path() {  # <task>
  printf '%s\n' "${FM_STATE_OVERRIDE:-$(fm_delivery_home)/state}/$1.meta"
}

# fm_delivery_trim <value>: strip leading/trailing whitespace.
fm_delivery_trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

# fm_delivery_valid_mode <mode>
fm_delivery_valid_mode() {
  case "$1" in
    no-mistakes | direct-PR | local-only) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_delivery_valid_yolo <on|off|inherit>
fm_delivery_valid_yolo() {
  case "$1" in
    on | off | inherit) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_delivery_valid_id <task>: a safe file-name component.
fm_delivery_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_delivery_pr_slug <url>: canonical <host>_<owner>_<repo>_<number> for a
# pull-request or merge-request URL, or empty when the URL is not one.
fm_delivery_pr_slug() {
  local url=${1%%#*} host path rest number owner repo
  url=${url%/}
  case "$url" in
    http://* | https://*) ;;
    *) return 1 ;;
  esac
  rest=${url#*://}
  host=${rest%%/*}
  path=/${rest#*/}
  path=${path%.git}
  case "$host" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$path" in
    */pull/* | */pulls/* | */merge_requests/* | */pull-requests/*) ;;
    *) return 1 ;;
  esac
  number=${path##*/}
  case "$number" in
    '' | *[!0-9]*) return 1 ;;
  esac
  path=${path%/*}
  path=${path#/}
  path=${path%/*}
  case "$path" in
    *[!A-Za-z0-9._/-]* | '') return 1 ;;
  esac
  owner=${path%%/*}
  repo=${path#*/}
  case "$repo" in
    */*) repo=${repo##*/} ;;
  esac
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  printf '%s_%s_%s_%s\n' "$host" "$owner" "$repo" "$number"
}

# fm_delivery_pr_key <url>: record key, or empty for an unusable URL.
fm_delivery_pr_key() {
  local slug
  slug=$(fm_delivery_pr_slug "$1") || return 1
  printf 'pr-%s\n' "$slug"
}

# fm_delivery_task_key <task>
fm_delivery_task_key() {
  fm_delivery_valid_id "$1" || return 1
  printf 'task-%s\n' "$1"
}

# fm_delivery_record_path <key>
fm_delivery_record_path() {
  printf '%s/%s.record\n' "$(fm_delivery_dir)" "$1"
}

# fm_delivery_field <file> <field>: print one stored value, or empty.
fm_delivery_field() {
  local file=$1 field=$2 value
  [ -r "$file" ] || return 0
  value=$(sed -n "s/^$field=//p" "$file" | head -n 1) || value=
  printf '%s\n' "$value"
}

# fm_delivery_read <key>: load a record into FM_DELIVERY_* variables.
# Returns 1 when no record exists.
fm_delivery_read() {
  local key=$1 file
  FM_DELIVERY_KEY=$key
  FM_DELIVERY_TASK=
  FM_DELIVERY_PR_URL=
  FM_DELIVERY_BRANCH=
  FM_DELIVERY_PROJECT=
  FM_DELIVERY_MODE=
  FM_DELIVERY_YOLO=
  FM_DELIVERY_DECIDED_AT=
  FM_DELIVERY_REASON=
  case "$key" in
    task-* | pr-*) ;;
    *) return 1 ;;
  esac
  file=$(fm_delivery_record_path "$key")
  [ -r "$file" ] || return 1
  FM_DELIVERY_TASK=$(fm_delivery_field "$file" task)
  FM_DELIVERY_PR_URL=$(fm_delivery_field "$file" pr_url)
  FM_DELIVERY_BRANCH=$(fm_delivery_field "$file" branch)
  FM_DELIVERY_PROJECT=$(fm_delivery_field "$file" project)
  FM_DELIVERY_MODE=$(fm_delivery_field "$file" delivery)
  FM_DELIVERY_YOLO=$(fm_delivery_field "$file" yolo)
  FM_DELIVERY_DECIDED_AT=$(fm_delivery_field "$file" decided_at)
  FM_DELIVERY_REASON=$(fm_delivery_field "$file" reason)
  [ -n "$FM_DELIVERY_MODE" ] || return 1
  [ -n "$FM_DELIVERY_YOLO" ] || FM_DELIVERY_YOLO=inherit
  return 0
}

# fm_delivery_task_pr_url <task>: the task's recorded PR URL, or empty.
fm_delivery_task_pr_url() {
  local meta
  meta=$(fm_delivery_meta_path "$1")
  [ -r "$meta" ] || return 0
  sed -n 's/^pr=//p' "$meta" | head -n 1
}

# fm_delivery_task_branch <task>: the recorded ship branch, or fm/<task>.
fm_delivery_task_branch() {
  local meta branch
  meta=$(fm_delivery_meta_path "$1")
  branch=$(sed -n 's/^branch=//p' "$meta" 2>/dev/null | head -n 1)
  [ -n "$branch" ] || branch="fm/$1"
  printf '%s\n' "$branch"
}

# fm_delivery_resolve <task|-> <pr|-> <project|->: resolve the decision.
# Sets:
#   FM_DELIVERY_RESOLVED_MODE       no-mistakes | direct-PR | local-only
#   FM_DELIVERY_RESOLVED_YOLO       on | off
#   FM_DELIVERY_RESOLVED_SOURCE     pr | task | registry | default
#   FM_DELIVERY_RESOLVED_TASK       the task id considered, or empty
#   FM_DELIVERY_RESOLVED_PR         the PR URL considered, or empty
#   FM_DELIVERY_RESOLVED_SHADOWED   "<source>:<mode> <yolo>" for a losing record
#   FM_DELIVERY_RESOLVED_REASON     the record's reason, or empty
fm_delivery_resolve() {
  local task=${1:--} pr=${2:--} project=${3:--} mode yolo source reason shadowed registry_line yolo_source=
  mode=
  yolo=inherit
  source=
  reason=
  shadowed=
  if [ "$task" = '-' ]; then task=; fi
  if [ "$pr" = '-' ]; then pr=; fi
  if [ "$project" = '-' ]; then project=; fi
  [ -n "$pr" ] || { [ -z "$task" ] || pr=$(fm_delivery_task_pr_url "$task"); }

  # 1. PR record.
  local pr_key=
  if [ -n "$pr" ]; then pr_key=$(fm_delivery_pr_key "$pr" 2>/dev/null || true); fi
  if [ -n "${pr_key:-}" ] && fm_delivery_read "$pr_key"; then
    mode=$FM_DELIVERY_MODE
    yolo=$FM_DELIVERY_YOLO
    source=pr
    reason=$FM_DELIVERY_REASON
    [ -n "$project" ] || project=$FM_DELIVERY_PROJECT
    if [ "$yolo" != inherit ]; then yolo_source=pr; fi
  fi

  # 2. Task record.
  local task_key=
  if [ -n "$task" ]; then task_key=$(fm_delivery_task_key "$task" 2>/dev/null || true); fi
  if [ -n "${task_key:-}" ] && fm_delivery_read "$task_key"; then
    if [ "$source" = pr ]; then
      shadowed="task:$FM_DELIVERY_MODE $FM_DELIVERY_YOLO"
      [ "$FM_DELIVERY_MODE" = "$mode" ] || shadowed="task:$FM_DELIVERY_MODE (delivery differs)"
    else
      mode=$FM_DELIVERY_MODE
      yolo=$FM_DELIVERY_YOLO
      source=task
      reason=$FM_DELIVERY_REASON
      [ -n "$project" ] || project=$FM_DELIVERY_PROJECT
      if [ "$FM_DELIVERY_YOLO" != inherit ]; then yolo_source=task; fi
    fi
  fi

  # 3. Project registry posture, and the yolo fallback for a record that
  # inherits it.
  local registry_mode= registry_yolo=
  if [ -n "$project" ]; then
    if registry_line=$(FM_HOME="$(fm_delivery_home)" FM_DATA_OVERRIDE="$(fm_delivery_data_dir)" \
      "$(dirname "${BASH_SOURCE[0]}")/fm-project-mode.sh" "$project" 2>/dev/null); then
      if [ -n "$registry_line" ]; then
        registry_mode=${registry_line%% *}
        registry_yolo=${registry_line##* }
      fi
    fi
  fi
  if [ -z "$mode" ]; then
    if [ -n "$registry_mode" ] && fm_delivery_valid_mode "$registry_mode"; then
      mode=$registry_mode
      source=registry
    else
      mode=no-mistakes
      source=default
    fi
  fi
  if [ "$yolo" = inherit ]; then
    case "$registry_yolo" in
      on | off) yolo=$registry_yolo ;;
      *) yolo=off ;;
    esac
  fi
  if [ -z "$yolo_source" ]; then
    # An inheriting record, or no record at all: merge authority came from the
    # registry (or the unregistered default).
    if [ -n "$registry_yolo" ]; then yolo_source=registry; else yolo_source=default; fi
  fi
  fm_delivery_valid_mode "$mode" || { mode=no-mistakes; source=default; yolo=off; }
  case "$yolo" in on | off) ;; *) yolo=off ;; esac

  FM_DELIVERY_RESOLVED_MODE=$mode
  FM_DELIVERY_RESOLVED_YOLO=$yolo
  FM_DELIVERY_RESOLVED_SOURCE=$source
  FM_DELIVERY_RESOLVED_TASK=${task:-}
  FM_DELIVERY_RESOLVED_PR=${pr:-}
  FM_DELIVERY_RESOLVED_REASON=$reason
  FM_DELIVERY_RESOLVED_SHADOWED=$shadowed
  FM_DELIVERY_RESOLVED_YOLO_SOURCE=$yolo_source
}

# fm_delivery_write <key> <kind> <task> <pr_url> <mode> <yolo> <reason> <branch> <project>
# Atomically write or supersede one record.
fm_delivery_write() {
  local key=$1 kind=$2 task=$3 pr_url=$4 mode=$5 yolo=$6 reason=$7 branch=$8 project=$9
  local dir file tmp previous='' decided
  fm_delivery_valid_mode "$mode" || return 2
  fm_delivery_valid_yolo "$yolo" || return 2
  dir=$(fm_delivery_dir)
  file=$(fm_delivery_record_path "$key")
  mkdir -p "$dir" || return 1
  if fm_delivery_read "$key"; then
    previous="$FM_DELIVERY_MODE $FM_DELIVERY_YOLO"
  fi
  decided=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(mktemp "$dir/.record.XXXXXX") || return 1
  {
    printf '%s\n' "$FM_DELIVERY_VERSION"
    printf 'version=%s\n' "$FM_DELIVERY_VERSION"
    printf 'key=%s\n' "$key"
    printf 'kind=%s\n' "$kind"
    printf 'task=%s\n' "$task"
    printf 'pr_url=%s\n' "$pr_url"
    printf 'branch=%s\n' "$branch"
    printf 'project=%s\n' "$project"
    printf 'delivery=%s\n' "$mode"
    printf 'yolo=%s\n' "$yolo"
    printf 'reason=%s\n' "$reason"
    printf 'decided_at=%s\n' "$decided"
    printf 'supersedes=%s\n' "${previous:+previous:$previous}"
    printf 'previous=%s\n' "$previous"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  FM_DELIVERY_WRITTEN_PATH=$file
  return 0
}

# fm_delivery_clear <key>
fm_delivery_clear() {
  local file
  file=$(fm_delivery_record_path "$1")
  [ -e "$file" ] || return 1
  rm -f "$file"
}

# fm_delivery_enforce <task> <mode> <yolo>: refuse a spawn that contradicts an
# explicit task/PR record. Registry and default postures are intake inputs, so
# they are not contradictions.
fm_delivery_enforce() {
  local task=$1 mode=$2 yolo=$3 detail
  fm_delivery_resolve "$task" - -
  case "$FM_DELIVERY_RESOLVED_SOURCE" in
    pr | task) ;;
    *) return 0 ;;
  esac
  if [ "$FM_DELIVERY_RESOLVED_MODE" != "$mode" ]; then
    detail="recorded delivery is $FM_DELIVERY_RESOLVED_MODE (source $FM_DELIVERY_RESOLVED_SOURCE) for task $task"
    [ -z "$FM_DELIVERY_RESOLVED_PR" ] || detail="$detail / $FM_DELIVERY_RESOLVED_PR"
    printf 'error: --mode %s contradicts a durable delivery decision: %s; clear it with bin/fm-delivery.sh or spawn with the recorded mode\n%s\n' \
      "$mode" "$detail" "${FM_DELIVERY_RESOLVED_SHADOWED:+shadowed: $FM_DELIVERY_RESOLVED_SHADOWED}" >&2
    return "$FM_DELIVERY_REFUSE_EXIT"
  fi
  if [ "$FM_DELIVERY_RESOLVED_YOLO" != "$yolo" ]; then
    printf 'error: --yolo %s contradicts the durable delivery decision for task %s (source %s); clear it or spawn with yolo %s\n' \
      "$yolo" "$task" "$FM_DELIVERY_RESOLVED_SOURCE" "$FM_DELIVERY_RESOLVED_YOLO" >&2
    return "$FM_DELIVERY_REFUSE_EXIT"
  fi
  return 0
}
