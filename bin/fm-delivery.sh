#!/usr/bin/env bash
# fm-delivery.sh - per-PR (and per-task) delivery decisions.
#
# The decision layer answers one question: for this pull request (or this ship
# task), is no-mistakes the required delivery path, or is direct delivery
# allowed? It never runs, drives, or inspects a no-mistakes run itself; the
# pipeline evidence and run attribution stay with bin/fm-nm-run-lib.sh.
#
# Usage:
#   fm-delivery.sh resolve [--task <id>] [--pr <url>] [--project <name>] [--words]
#       Print the effective decision as key=value lines (mode=, yolo=,
#       delivery_source=, yolo_source=, task=, pr=, shadowed=, reason=), or
#       "<mode> <yolo>" with --words.
#   fm-delivery.sh get (--task <id> | --pr <url>)
#       Print one stored record as key=value lines; exit 1 when absent.
#   fm-delivery.sh set (--task <id> | --pr <url>) --mode <mode> [--yolo on|off|inherit]
#                     [--pipeline on|off] [--reason <text>] [--project <name>]
#       Write or supersede the durable decision. --pipeline on is no-mistakes;
#       --pipeline off is direct-PR. --task may accompany --pr so a task's
#       decision is visible alongside the PR record.
#   fm-delivery.sh clear (--task <id> | --pr <url>)
#       Remove one record; resolution falls back to the next source.
#   fm-delivery.sh list
#       Print every record: key, delivery, yolo, source task/pr.
#   fm-delivery.sh enforce-task <id> <mode> <yolo>
#       Refuse (exit 6) when an explicit task/PR record contradicts the values a
#       spawn is about to use. bin/fm-spawn.sh calls this so a per-PR switch
#       cannot be silently bypassed at dispatch.
#   fm-delivery.sh key --pr <url>
#       Print the canonical record key (diagnostics).
#
# Exit codes: 0 ok, 1 no record, 2 usage/invalid, 6 decision conflict.
#
# Environment: FM_HOME (or FM_DATA_OVERRIDE) selects the home whose
# data/delivery records are read and written; the home is never inferred from
# the current directory.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_ROOT FM_HOME FM_DATA_OVERRIDE
# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"

usage() {
  sed -n '3,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# fm_delivery_require_data_dir: refuse an unusable data root rather than
# creating records in an unexpected place.
fm_delivery_require_data_dir() {
  mkdir -p "$(fm_delivery_data_dir)" 2>/dev/null || {
    printf 'fm-delivery: cannot create data directory %s\n' "$(fm_delivery_data_dir)" >&2
    exit 1
  }
}

# fm_delivery_print_record <key>
fm_delivery_print_record() {
  fm_delivery_read "$1" || return 1
  printf 'key=%s\n' "$FM_DELIVERY_KEY"
  printf 'task=%s\n' "$FM_DELIVERY_TASK"
  printf 'pr_url=%s\n' "$FM_DELIVERY_PR_URL"
  printf 'branch=%s\n' "$FM_DELIVERY_BRANCH"
  printf 'project=%s\n' "$FM_DELIVERY_PROJECT"
  printf 'delivery=%s\n' "$FM_DELIVERY_MODE"
  printf 'yolo=%s\n' "$FM_DELIVERY_YOLO"
  printf 'reason=%s\n' "$FM_DELIVERY_REASON"
  printf 'decided_at=%s\n' "$FM_DELIVERY_DECIDED_AT"
}

COMMAND=${1:-}
shift 2>/dev/null || true
[ -n "$COMMAND" ] || usage

TASK=
PR=
PROJECT=
POS=()
MODE=
YOLO=inherit
PIPELINE=
REASON=
WORDS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:-}; shift 2 ;;
    --pr) PR=${2:-}; shift 2 ;;
    --project) PROJECT=${2:-}; shift 2 ;;
    --mode) MODE=${2:-}; shift 2 ;;
    --yolo) YOLO=${2:-}; shift 2 ;;
    --pipeline) PIPELINE=${2:-}; shift 2 ;;
    --reason) REASON=${2:-}; shift 2 ;;
    --words) WORDS=1; shift ;;
    -h | --help) usage ;;
    --) shift; break ;;
    -*)
      printf 'fm-delivery: unexpected option %s\n' "$1" >&2
      exit 2
      ;;
    *)
      POS+=("$1")
      shift
      ;;
  esac
done

case "$PIPELINE" in
  '' ) ;;
  on )
    [ -z "$MODE" ] || { printf 'fm-delivery: pass --mode or --pipeline, not both\n' >&2; exit 2; }
    MODE=no-mistakes
    ;;
  off )
    [ -z "$MODE" ] || { printf 'fm-delivery: pass --mode or --pipeline, not both\n' >&2; exit 2; }
    MODE=direct-PR
    ;;
  * )
    printf 'fm-delivery: --pipeline must be on or off (got %s)\n' "$PIPELINE" >&2
    exit 2
    ;;
esac

case "$COMMAND" in
  resolve)
    fm_delivery_resolve "${TASK:--}" "${PR:--}" "${PROJECT:--}"
    if [ "$WORDS" = 1 ]; then
      printf '%s %s\n' "$FM_DELIVERY_RESOLVED_MODE" "$FM_DELIVERY_RESOLVED_YOLO"
    else
      printf 'mode=%s\n' "$FM_DELIVERY_RESOLVED_MODE"
      printf 'yolo=%s\n' "$FM_DELIVERY_RESOLVED_YOLO"
      printf 'delivery_source=%s\n' "$FM_DELIVERY_RESOLVED_SOURCE"
      printf 'yolo_source=%s\n' "$FM_DELIVERY_RESOLVED_YOLO_SOURCE"
      printf 'task=%s\n' "$FM_DELIVERY_RESOLVED_TASK"
      printf 'pr=%s\n' "$FM_DELIVERY_RESOLVED_PR"
      printf 'shadowed=%s\n' "$FM_DELIVERY_RESOLVED_SHADOWED"
      printf 'reason=%s\n' "$FM_DELIVERY_RESOLVED_REASON"
    fi
    ;;
  get)
    if [ -n "$PR" ]; then
      KEY=$(fm_delivery_pr_key "$PR") || { printf 'fm-delivery: not a pull-request URL: %s\n' "$PR" >&2; exit 2; }
    elif [ -n "$TASK" ]; then
      KEY=$(fm_delivery_task_key "$TASK") || { printf 'fm-delivery: invalid task id\n' >&2; exit 2; }
    else
      usage
    fi
    fm_delivery_print_record "$KEY" || exit 1
    ;;
  set)
    [ -n "$MODE" ] || usage
    fm_delivery_valid_mode "$MODE" || {
      printf 'fm-delivery: --mode must be one of %s (got %s)\n' "$FM_DELIVERY_MODE_SET" "$MODE" >&2
      exit 2
    }
    fm_delivery_valid_yolo "$YOLO" || {
      printf 'fm-delivery: --yolo must be on, off, or inherit (got %s)\n' "$YOLO" >&2
      exit 2
    }
    fm_delivery_require_data_dir
    if [ -n "$PR" ]; then
      KEY=$(fm_delivery_pr_key "$PR") || { printf 'fm-delivery: not a pull-request URL: %s\n' "$PR" >&2; exit 2; }
      BRANCH=
      [ -z "$TASK" ] || BRANCH=$(fm_delivery_task_branch "$TASK")
      fm_delivery_write "$KEY" pr "$TASK" "$PR" "$MODE" "$YOLO" "$REASON" "$BRANCH" "$PROJECT" || {
        printf 'fm-delivery: could not write the PR decision record\n' >&2
        exit 1
      }
      printf 'recorded %s: delivery=%s yolo=%s\n' "$FM_DELIVERY_WRITTEN_PATH" "$MODE" "$YOLO"
      exit 0
    fi
    [ -n "$TASK" ] || usage
    fm_delivery_valid_id "$TASK" || { printf 'fm-delivery: invalid task id\n' >&2; exit 2; }
    BRANCH=$(fm_delivery_task_branch "$TASK")
    # A task decision records its already-known PR too, so a later PR lookup
    # resolves the same decision instead of falling back to the registry.
    if [ -z "$PR" ]; then PR=$(fm_delivery_task_pr_url "$TASK"); fi
    if [ -n "$PR" ]; then
      KEY=$(fm_delivery_pr_key "$PR") || KEY=
    fi
    if [ -n "${KEY:-}" ]; then
      fm_delivery_write "$KEY" pr "$TASK" "$PR" "$MODE" "$YOLO" "$REASON" "$BRANCH" "$PROJECT" || {
        printf 'fm-delivery: could not write the PR decision record\n' >&2
        exit 1
      }
      printf 'recorded %s: delivery=%s yolo=%s\n' "$FM_DELIVERY_WRITTEN_PATH" "$MODE" "$YOLO"
      exit 0
    fi
    KEY=$(fm_delivery_task_key "$TASK")
    fm_delivery_write "$KEY" task "$TASK" "$PR" "$MODE" "$YOLO" "$REASON" "$BRANCH" "$PROJECT" || {
      printf 'fm-delivery: could not write the task decision record\n' >&2
      exit 1
    }
    printf 'recorded %s: delivery=%s yolo=%s\n' "$FM_DELIVERY_WRITTEN_PATH" "$MODE" "$YOLO"
    ;;
  clear)
    if [ -n "$PR" ]; then
      KEY=$(fm_delivery_pr_key "$PR") || { printf 'fm-delivery: not a pull-request URL: %s\n' "$PR" >&2; exit 2; }
    elif [ -n "$TASK" ]; then
      KEY=$(fm_delivery_task_key "$TASK") || { printf 'fm-delivery: invalid task id\n' >&2; exit 2; }
    else
      usage
    fi
    CLEARED=0
    if fm_delivery_clear "$KEY"; then
      printf 'cleared %s\n' "$KEY"
      CLEARED=1
    fi
    if [ -n "$TASK" ] && [ -z "$PR" ]; then
      TASK_PR=$(fm_delivery_task_pr_url "$TASK")
      if [ -n "$TASK_PR" ]; then
        TASK_PR_KEY=$(fm_delivery_pr_key "$TASK_PR" 2>/dev/null || true)
        if [ -n "$TASK_PR_KEY" ] && fm_delivery_clear "$TASK_PR_KEY"; then
          printf 'cleared %s\n' "$TASK_PR_KEY"
          CLEARED=1
        fi
      fi
    fi
    if [ "$CLEARED" = 0 ]; then
      printf 'fm-delivery: no record for %s\n' "$KEY" >&2
      exit 1
    fi
    ;;
  list)
    DIR=$(fm_delivery_dir)
    [ -d "$DIR" ] || exit 0
    for FILE in "$DIR"/*.record; do
      [ -e "$FILE" ] || continue
      KEY=${FILE##*/}
      KEY=${KEY%.record}
      fm_delivery_read "$KEY" || continue
      printf '%s delivery=%s yolo=%s task=%s pr=%s\n' \
        "$KEY" "$FM_DELIVERY_MODE" "$FM_DELIVERY_YOLO" "$FM_DELIVERY_TASK" "$FM_DELIVERY_PR_URL"
    done
    ;;
  enforce-task)
    [ "${#POS[@]}" -ge 3 ] || usage
    fm_delivery_enforce "${POS[0]}" "${POS[1]}" "${POS[2]}"
    ;;
  key)
    [ -n "$PR" ] || usage
    fm_delivery_pr_key "$PR" || { printf 'fm-delivery: not a pull-request URL: %s\n' "$PR" >&2; exit 2; }
    ;;
  *)
    usage
    ;;
esac
