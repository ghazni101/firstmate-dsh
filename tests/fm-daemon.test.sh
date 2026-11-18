#!/usr/bin/env bash
# tests/fm-daemon.test.sh - supervise-daemon classifiers, the captain-relevant
# status-phrase matrix (a product contract), escalation batching/dedupe,
# decision-owned queued-row suppression, afk presence-gating, and the
# injection-hardening units that an e2e cannot deterministically reach
# (persistent-Enter-swallow, max-defer wedge alarms, fm-send typed-plane swallow
# reporting, composer-pending ANSI parsing). The operator-visible inject flow
# lives in fm-afk-inject-e2e and fm-wake-daemon-lifecycle-e2e.
# shellcheck disable=SC2034 # suite setup is read by the -cases-* modules

set -u

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
AFK_START="$ROOT/bin/fm-afk-start.sh"
# Source the daemon's pure functions once. Its main loop is skipped under sourcing
# via a BASH_SOURCE guard, so only classify_*/housekeeping/escalate_*/afk_* and the
# pane/submit helpers become defined.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=/dev/null
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-daemon-tests)
FM_DAEMON_PRIMARY_HARNESS=claude
export FM_DAEMON_PRIMARY_HARNESS

# Ambient hc (herdr-core) terminal markers are scrubbed for the whole suite:
# discover_supervisor_target/discover_supervisor_backend read HC_TERMINAL_ID
# and HC_TERMINAL_SOCKET now, so running these tests inside a real hc
# terminal would leak an hc resolution into the tmux/herdr/fallback
# expectations below. Per-case fixtures set their own HC_* claims.
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SESSION HC_SOCKET

# Cases live in definition-only modules so each is its own lint root; this
# file owns the setup and the run order.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-daemon-cases-1.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-daemon-cases-2.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-daemon-cases-3.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-daemon-cases-4.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-daemon-cases-5.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-daemon-cases-6.sh"

test_dialog_name_survives_away_self_handle
test_seen_terminal_dialog_stale_clears_like_a_plain_stale
test_dialog_name_joins_unseen_status_escalation
test_dialog_name_after_demand_deep_inspection_still_escalates
