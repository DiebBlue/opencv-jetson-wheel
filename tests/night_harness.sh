#!/usr/bin/env bash
# Runs build.sh's night chain inside a systemd user unit (as the real start command does) with the
# board-specific parts stubbed. Env (from run_tests.sh): OCV_TEST=1 BUILD BV WH OCV_STEP_BIN OCV_TEST_UNIT ...
export CMD=night
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=build.sh
. "$(dirname "${BASH_SOURCE[0]}")/../build.sh"
precheck() { log "precheck stubbed"; }
mem_available_mib() { echo 5300; }
row_for_mem() { echo "${TEST_ROW:-4 4096M 1536M}"; }
cmd_night "$@"
