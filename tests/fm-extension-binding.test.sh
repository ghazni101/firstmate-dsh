#!/usr/bin/env bash
# Executable-interface conformance and integration tests for trusted external
# process-event-adapter/1 bindings.
#
# The suite drives only public commands, package executables, and the durable
# records those commands publish. It never asserts implementation-source bytes.

# The suite is split into ordered parts so each is its own lint root; this
# file sources them in order and owns nothing else. The parts share one
# shell, so their setup, counters, and run order are unchanged.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-extension-binding-part-1.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-extension-binding-part-2.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/fm-extension-binding-part-3.sh"
