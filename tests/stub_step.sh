#!/usr/bin/env bash
# Stand-in for build.sh inside the build unit (tests only; never compiles anything).
# usage: stub_step.sh <fetch|record|pilot|full> [--jobs N] [--chain]
# Behaviour comes from $BUILD/scenario (default "ok"); see run_tests.sh.
step=$1
jobs=${3:-0}
LOGS=$BUILD/logs
mkdir -p "$LOGS"
trap 'echo $? >"$LOGS/$step.rc"' EXIT
trap 'exit 143' TERM
exec >>"$LOGS/$step.log" 2>&1
scn=$(cat "$BUILD/scenario" 2>/dev/null || echo ok)
echo "stub $step jobs=$jobs scenario=$scn"
case $step in
  fetch) exit 0 ;;
  record) mkdir -p "$WH/ocv"; echo wheel >"$WH/ocv/stub.whl"; exit 0 ;;
  pilot)
    [ "$scn" != w3 ] || { echo "W3 MISMATCH: stub"; exit 3; }
    # a process named cicc (symlink created by the test) holds memory like a compiler would
    "$BUILD/cicc" -c "b = bytearray($(cat "$BUILD/pilot_alloc" 2>/dev/null || echo 300)*1024*1024); import time; time.sleep(6)"
    printf 'wall=7\njobs=%s\nbuilt=6\nrc=0\n' "$jobs" >"$LOGS/pilot.state"
    exit 0
    ;;
  full)
    case $scn in
      ok) sleep 3; exit 0 ;;
      long) sleep 120; exit 0 ;;
      # real cgroup OOM without any marker in the build log; the unit stays alive (OOMPolicy=continue)
      oom-real)
        if [ "$jobs" -gt 2 ]; then
          python3 -c 'b = bytearray(300*1024*1024)'
          sleep 60
        fi
        sleep 3
        exit 0
        ;;
      oom-marker)
        if [ "$jobs" -gt 2 ]; then echo "c++: fatal error: Killed signal terminated program cc1plus"; sleep 1; exit 1; fi
        sleep 3; exit 0
        ;;
      err-twice) echo "/x/y/foo.cpp:$RANDOM:7: error: 'bar' was not declared"; sleep 1; exit 1 ;;
    esac
    ;;
esac
