#!/usr/bin/env bash
# Live guard for the two-session supervision coordinator (live-harness-optin
# family). Boot a disposable DSH web Host from a profile copy under a private
# DSH_HOME and loopback port, then drive session/create, session/prompt and
# session/events through the authenticated Host API the GUI uses - never the
# UI, the live web instance, the live DSH_HOME, or the live profile.
#
# This spends no model tokens: the disposable plugin copy registers a scripted
# provider that drives one real coordinator escalation turn for a captain-class
# traffic batch. It is still opt-in because it boots a real Host and takes
# several seconds. The driver refuses a pass with no Host, no completed turns,
# no real fork coordinators, or no tagged escalation in the owning parent.
#
# Run with FM_DSH_MULTISESSION_LIVE=1. Refresh
# docs/verification/dsh-multisession-coordinator.md after a DSH or plugin
# upgrade, using this guard's output.
set -u

SELF="$(readlink -f "$0")"
ROOT="$(dirname "$(dirname "$SELF")")"

# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
if ! declare -F fm_live_gate >/dev/null 2>&1; then
  printf 'not ok - tests/lib.sh did not define fm_live_gate\n' >&2
  exit 1
fi

fm_live_gate opt-in FM_DSH_MULTISESSION_LIVE dsh node

node "$ROOT/tests/fixtures/fm-dsh-multisession-live.mjs"
