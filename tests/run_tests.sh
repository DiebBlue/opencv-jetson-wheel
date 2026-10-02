#!/usr/bin/env bash
# Stub tests for build.sh (night chain, guards) and watchdog.sh. One command, no compiler, no cmake:
#   tests/run_tests.sh              run everything (about 2 minutes)
#   tests/run_tests.sh oom night_killed   run only tests whose name matches one of the words
# Needs the systemd user manager (real transient units named ocv-test-night / ocv-test-build, so a
# real ocv-build / ocv-night is never touched). Scratch directories live under $TMPDIR and are
# removed at the end. The stub holds up to ~300 MiB for a few seconds and one test provokes a
# cgroup OOM in a 64 MiB unit; run it when the board is otherwise idle.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
BH=$(dirname "$HERE")
NU=ocv-test-night
BU=ocv-test-build
T=$(mktemp -d "${TMPDIR:-/tmp}/ocv-tests.XXXXXX")
PASS=0
FAIL=0
SELECT=("$@")

cleanup() {
  systemctl --user stop "$NU.service" "$BU.service" >/dev/null 2>&1
  [ -z "$T" ] || rm -rf -- "$T"
}
trap cleanup EXIT

state() { systemctl --user show -p ActiveState --value "$1.service" 2>/dev/null; }
is_gone() { case $(state "$1") in inactive | failed | "") return 0 ;; esac; return 1; }
wait_gone() { local i; for i in $(seq 1 "$2"); do is_gone "$1" && return 0; sleep 1; done; return 1; }
wait_for() { local t=$1 i; shift; for i in $(seq 1 "$t"); do "$@" && return 0; sleep 1; done; return 1; }
check() { # description command...
  local d=$1
  shift
  if "$@"; then echo "  PASS $d"; PASS=$((PASS + 1)); else echo "  FAIL $d"; FAIL=$((FAIL + 1)); fi
}
selected() {
  local s
  [ ${#SELECT[@]} -gt 0 ] || return 0
  for s in "${SELECT[@]}"; do [[ $1 == *"$s"* ]] && return 0; done
  return 1
}

# ---- per-case sandbox: BUILD / BV / WH in $T, stub scenario, fake compiler process name
new_case() { # name scenario
  W=$T/$1
  mkdir -p "$W/build/logs" "$W/wh"
  echo "$2" >"$W/build/scenario"
  : >"$W/local.env" # no host guards in the sandbox
  ln -s /usr/bin/python3 "$W/build/cicc"
  NU_PROPS=()
  NU_ENV=()
  TEST_PATH=$PATH
  BV_DIR=$W/bv
  echo "== $1 ($2)"
}
start_night() { # night options...
  systemd-run --user --unit="$NU" --collect --quiet -p Nice=19 -p TimeoutStopSec=300 "${NU_PROPS[@]}" \
    -E OCV_TEST=1 -E "OCV_TEST_UNIT=$BU" -E "BUILD=$W/build" -E "BV=$BV_DIR" -E "WH=$W/wh" \
    -E "OCV_LOCAL_ENV=$W/local.env" -E "OCV_STEP_BIN=$HERE/stub_step.sh" -E "OCV_WD_ARGS=--interval 2" -E "PATH=$TEST_PATH" \
    "${NU_ENV[@]}" bash "$HERE/night_harness.sh" "$@"
}
night_gone() { is_gone "$NU"; }
nstatus() { cat "$W/build/logs/night.status" 2>/dev/null; }
full_started() { grep -q '"event":"attempt_start","step":"full"' "$W/build/logs/events.jsonl" 2>/dev/null; }
status_is() { [ "$(nstatus)" = "$1" ]; }
log_has() { grep -q -- "$2" "$W/build/logs/$1"; }

# ---- baseline, guard processes -------------------------------------------------------------------------

t_baseline() {
  new_case baseline ok
  start_night --no-window
  wait_for 150 night_gone
  check "night.status is ok" status_is ok
  check "wheel recorded by the stub" test -f "$W/wh/ocv/stub.whl"
  check "build unit gone" is_gone "$BU"
}

t_watchdog_killed() {
  new_case watchdog_killed long
  start_night --no-window
  wait_for 90 full_started
  sleep 3
  pkill -9 -f "watchdog.sh --unit $BU"
  check "build unit stops although its watchdog was killed -9" wait_gone "$BU" 60
  wait_for 90 night_gone
  check "night.status is terminal (failed:full)" status_is failed:full
}

t_night_killed() {
  new_case night_killed long
  start_night --no-window
  wait_for 90 full_started
  sleep 3
  kill -9 "$(systemctl --user show -p MainPID --value "$NU.service")"
  check "build unit stops through BindsTo after kill -9 of the night process" wait_gone "$BU" 60
  check "night unit gone" wait_gone "$NU" 60
}

t_systemctl_failure() {
  new_case systemctl_failure ok
  local shim=$W/shim cnt=$W/count
  mkdir -p "$shim"
  cat >"$shim/systemctl" <<SH
#!/bin/sh
# fails the 3rd state query (show -p ActiveState / is-active) once; everything else is passed on
case "\$*" in
  *"show -p ActiveState"* | *is-active*)
    n=\$(cat "$cnt" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n >"$cnt"
    [ "\$n" = 3 ] && exit 1 ;;
esac
exec /usr/bin/systemctl "\$@"
SH
  chmod +x "$shim/systemctl"
  systemd-run --user --unit="$BU" --collect --quiet bash -c "sleep 8; echo 0 >$W/rc"
  PATH="$shim:$PATH" "$BH/watchdog.sh" --unit "$BU" --interval 1 --status "$W/st" --rc-file "$W/rc" \
    >"$W/wd.out" 2>&1
  check "status is done (not declared ended early)" test "$(cat "$W/st")" = "done"
  check "the failing call was logged as unknown" grep -q "could not report the state" "$W/wd.out"
  check "the unit had really ended (rc file written before the verdict)" test -s "$W/rc"
}

# ---- OOM evidence ------------------------------------------------------------------------------------

t_oom_journal_masked() {
  new_case oom_journal oom-real
  mkdir -p "$W/shim"
  printf '#!/bin/sh\nexit 0\n' >"$W/shim/journalctl"
  chmod +x "$W/shim/journalctl"
  TEST_PATH="$W/shim:$PATH"
  NU_ENV=(-E "OCV_TEST_FULL_PROPS=-p MemoryMax=64M -p MemorySwapMax=0 -p OOMPolicy=continue")
  start_night --no-window
  wait_for 200 night_gone
  check "S-a found through the cgroup without journal evidence" log_has watchdog.log "stopped:S-a (memory.events"
  check "chain resumed at J-1" log_has night.log "S-a: resuming full at J=3"
  check "chain finished ok after resuming" status_is ok
}

# ---- bounds and arguments ------------------------------------------------------------------------------------

t_runtime_max() {
  new_case runtime_max long
  NU_PROPS=(-p RuntimeMaxSec=20)
  start_night --no-window
  wait_for 150 night_gone
  check "RuntimeMaxSec SIGTERM ends in stopped:S-d" status_is stopped:S-d
  check "build unit gone" is_gone "$BU"
}

t_window_required() {
  new_case window_required ok
  start_night
  wait_for 60 night_gone
  check "night without --window-end / --no-window refuses with a terminal status" status_is failed:arguments
  check "no build unit was started" is_gone "$BU"
  new_case window_past ok
  start_night --window-end "now - 1 hour"
  wait_for 60 night_gone
  check "a window end in the past is refused" status_is failed:arguments
}

# ---- terminal status ------------------------------------------------------------------------------------

t_status_terminal() {
  new_case status_args ok
  echo ok >"$W/build/logs/night.status"
  start_night --no-window --max-jobs abc
  wait_for 60 night_gone
  check "invalid --max-jobs with a pre-seeded ok: status is not ok" test "$(nstatus)" != ok
  check "  and it is failed:arguments" status_is failed:arguments
  new_case status_guard ok
  echo ok >"$W/build/logs/night.status"
  echo "FORBIDDEN_BV_GLOB='forbidden-*'" >"$W/local.env"
  BV_DIR=$W/forbidden-bv # a BV matching FORBIDDEN_BV_GLOB makes guard() die after the status was reset
  start_night --no-window
  wait_for 60 night_gone
  check "an unexpected die ends in failed:aborted" status_is failed:aborted
}

# ---- guards and hooks (no systemd) -------------------------------------------------------------

t_build_path() {
  echo "== BUILD validation"
  local d=$T/build_path rc
  mkdir -p "$d"
  for b in / "$HOME" /tmp/ocv-not-home; do
    (cd "$d" && BUILD=$b "$BH/build.sh" --dry-run >/dev/null 2>&1)
    rc=$?
    check "BUILD=$b is refused (rc $rc)" test "$rc" -ne 0
  done
  (cd "$d" && BUILD=$HOME/ocv-test-never-created "$BH/build.sh" --dry-run >/dev/null 2>&1)
  check "BUILD below \$HOME is accepted by --dry-run" test $? -eq 0
  (cd "$d" && OCV_TEST=1 BUILD=/tmp/ocv-test-never-created "$BH/build.sh" --dry-run >/dev/null 2>&1)
  check "OCV_TEST=1 allows a BUILD outside \$HOME" test $? -eq 0
}

t_test_hooks() {
  echo "== test hooks need OCV_TEST=1"
  local a b
  a=$(OCV_STEP_BIN=/bin/false OCV_TEST_UNIT=x OCV_LOCAL_ENV=/dev/null bash -c ". '$BH/build.sh'; echo \$STEP_BIN \$UNIT")
  b=$(OCV_TEST=1 OCV_STEP_BIN=/bin/false OCV_TEST_UNIT=x OCV_LOCAL_ENV=/dev/null bash -c ". '$BH/build.sh'; echo \$STEP_BIN \$UNIT")
  check "without OCV_TEST the hooks are ignored" test "$a" = "$BH/build.sh ocv-build"
  check "with OCV_TEST=1 they apply" test "$b" = "/bin/false x"
  check "OCV_CHAIN is gone (replaced by the explicit --chain option)" test "$(grep -c OCV_CHAIN "$BH/build.sh")" = 0
}

t_full_jobs_fallback() {
  echo "== full: default J without a table row"
  local mem out
  for mem in 1000 5300; do
    out=$(bash -c ". '$BH/build.sh'; mem_available_mib() { echo $mem; }; precheck() { :; }; guard() { :; }
      load_pins() { :; }; step_begin() { :; }; assert_sources() { echo \"J=\$JOBS\"; exit 0; }; cmd_full")
    check "MemAvailable $mem -> $out" test "$out" = "J=$([ "$mem" = 1000 ] && echo 1 || echo 4)"
  done
}

t_disk_path() {
  echo "== disk checks look at BUILD"
  # shellcheck disable=SC2016 # the patterns are literal source text
  check "watchdog gets --disk-path \"\$BUILD\"" grep -qF -- '--disk-path "$BUILD"' "$BH/build.sh"
  # shellcheck disable=SC2016
  check "precheck measures the filesystem of BUILD" grep -qF 'df -P -B1G "$(existing_ancestor "$BUILD")"' "$BH/build.sh"
}

# ---- configurable host guards (local.env), no systemd ------------------------------------------

t_host_guards() {
  echo "== host guards come from local.env"
  local d=$T/host_guards le rc out
  le=$d/local.env
  mkdir -p "$d/forbidden/sub" "$d/free"
  printf 'FORBIDDEN_DIRS="%s %s"\nFORBIDDEN_BV_GLOB=%s\n' "$d/other" "$d/forbidden" "'forbidden-*'" >"$le"
  dry() { # cwd bv; runs --dry-run with the sandbox local.env
    (cd "$1" && OCV_TEST=1 OCV_LOCAL_ENV="$le" BUILD="$d/build" BV="$2" "$BH/build.sh" --dry-run >/dev/null 2>"$d/err")
  }
  dry "$d/free" "$d/ok-bv"
  check "a directory outside FORBIDDEN_DIRS is accepted" test $? -eq 0
  dry "$d/forbidden/sub" "$d/ok-bv"
  rc=$?
  check "running below a FORBIDDEN_DIRS entry is refused (rc $rc)" test "$rc" -ne 0
  check "  with the matching message" grep -q "refusing to run inside $d/forbidden" "$d/err"
  dry "$d/free" "$d/forbidden-bv"
  rc=$?
  check "a BV matching FORBIDDEN_BV_GLOB is refused (rc $rc)" test "$rc" -ne 0
  check "  with the matching message" grep -q "BV matches FORBIDDEN_BV_GLOB" "$d/err"
  : >"$le"
  dry "$d/forbidden/sub" "$d/forbidden-bv"
  check "empty defaults disable both guards" test $? -eq 0

  # precheck: a listed unit that is active, a listed process that is running
  mkdir -p "$d/shim"
  cat >"$d/shim/systemctl" <<'SH'
#!/bin/sh
case "$*" in *unit-a.service*) exit 0 ;; esac
exec /usr/bin/systemctl "$@"
SH
  chmod +x "$d/shim/systemctl"
  pre() { # local.env content; runs precheck, stderr to $d/pre.err
    printf '%s\n' "$1" >"$le"
    PATH="$d/shim:$PATH" OCV_TEST=1 OCV_LOCAL_ENV="$le" BUILD="$d/build" \
      bash -c ". '$BH/build.sh'; mem_available_mib() { echo 5300; }; precheck" >/dev/null 2>"$d/pre.err"
  }
  pre 'PRECHECK_UNITS="unit-b.service unit-a.service"'
  rc=$?
  check "an active PRECHECK_UNITS entry stops the precheck (rc $rc)" test "$rc" -ne 0
  check "  and is named" grep -q "unit-a.service is active" "$d/pre.err"
  sleep 4321 &
  local pid=$!
  pre "PRECHECK_PGREP='sleep 4321'"
  rc=$?
  check "a running PRECHECK_PGREP match stops the precheck (rc $rc)" test "$rc" -ne 0
  check "  and is reported" grep -q "matching PRECHECK_PGREP is running" "$d/pre.err"
  pre "PRECHECK_PGREP='sleep 4322'"
  out=$(cat "$d/pre.err")
  kill "$pid" 2>/dev/null
  check "a PRECHECK_PGREP without a match does not stop it" test "${out#*matching PRECHECK_PGREP}" = "$out"
  pre ""
  out=$(cat "$d/pre.err")
  check "empty defaults skip both checks" test "${out#*is active}" = "$out"
}

# ---- watchdog stop conditions (dummy units, lowered thresholds) --------------------------------

wd_case() { # name unit-command expected-status watchdog-args...
  local n=$1 cmd=$2 want=$3
  shift 3
  W=$T/wd_$n
  mkdir -p "$W"
  systemd-run --user --unit="$BU" --collect --quiet bash -c "$cmd"
  "$BH/watchdog.sh" --unit "$BU" --interval 1 --status "$W/st" --rc-file "$W/rc" \
    --attempt-start "$(date +%s)" "$@" >"$W/out" 2>&1
  check "watchdog $n -> $want" test "$(cat "$W/st")" = "$want"
}

t_watchdog_stop_conditions() {
  echo "== watchdog stop conditions"
  mkdir -p "$T/wd_dirs"
  local stopfile=$T/stopfile
  touch "$stopfile"
  wd_case Sb "sleep 120" stopped:S-b --min-avail-mib 999999 --min-avail-samples 3
  wd_case Sc "sleep 120" stopped:S-c --zram-max-mib 0
  wd_case Sd1 "sleep 120" stopped:S-d --window-end $(($(date +%s) + 3))
  wd_case Sd2 "sleep 120" stopped:S-d --stop-file "$stopfile"
  wd_case Se "sleep 120" stopped:S-e --min-disk-gb 99999
  W=$T/wd_Sa
  mkdir -p "$W"
  systemd-run --user --unit="$BU" --collect --quiet -p MemoryMax=64M -p MemorySwapMax=0 \
    bash -c "python3 -c 'b=bytearray(300*1024*1024)'; echo \$? >$W/rc2"
  "$BH/watchdog.sh" --unit "$BU" --interval 1 --status "$W/st2" --rc-file "$W/rc2" \
    --attempt-start "$(date +%s)" >/dev/null 2>&1
  check "watchdog Sa (real cgroup OOM) -> stopped:S-a" test "$(cat "$W/st2")" = stopped:S-a
  W=$T/wd_Sf
  mkdir -p "$W"
  printf 'x\n/a/b/foo.cpp:12:3: error: bar\n' >"$W/log"
  local i
  for i in 1 2; do
    systemd-run --user --unit="$BU" --collect --quiet bash -c "sleep 1; echo 1 >$W/rc"
    "$BH/watchdog.sh" --unit "$BU" --interval 1 --status "$W/st$i" --rc-file "$W/rc" --build-log "$W/log" \
      --errors-file "$W/sig" --attempt-start "$(date +%s)" >/dev/null 2>&1
  done
  check "watchdog Sf: first error failed:error" test "$(cat "$W/st1")" = failed:error
  check "watchdog Sf: same error again stopped:S-f" test "$(cat "$W/st2")" = stopped:S-f
}

# ---- run -------------------------------------------------------------------------------------

command -v systemd-run >/dev/null || { echo "systemd-run not found" >&2; exit 2; }
if ! is_gone "$NU" || ! is_gone "$BU"; then echo "$NU or $BU is active; refusing to run" >&2; exit 2; fi

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
  selected "$t" || continue
  "$t"
  systemctl --user stop "$NU.service" "$BU.service" >/dev/null 2>&1
done
echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
