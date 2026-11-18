#!/usr/bin/env bash
# Behavior tests for the generic process-to-event runner and its Lavish adapter.
#
# The source under test is a fake blocking process that returns only when its
# trigger file appears, so completion is a real process event and no test here
# depends on a discovery timer. The Lavish adapter is exercised through its own
# public commands against the currently published poll shape; no live Lavish
# server is started.
#
# Delivery is deliberately NOT asserted as at-least-once or lossless: the
# published Lavish poll clears feedback destructively before returning it, so
# the only durability under test is the runner's own - output that reached the
# runner is stored before it is announced.

# The suite is split into ordered parts so each is its own lint root; this
# file sources them in order and owns nothing else. The parts share one
# shell, so their setup, counters, and run order are unchanged.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-procevent-part-1.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-procevent-part-2.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-procevent-part-3.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-procevent-part-4.sh"
