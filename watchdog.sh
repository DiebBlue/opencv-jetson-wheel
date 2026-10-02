#!/usr/bin/env bash
# watchdog.sh - samples a transient user unit and enforces the stop conditions S-a .. S-f.
# Runs next to the unit, not inside it.
#
#   S-a  OOM kill inside the unit (cgroup memory.events, journal, or compiler "Killed" in the log)
#   S-b  system MemAvailable < --min-avail-mib for --min-avail-samples consecutive samples
#   S-c  zram swap used > --zram-max-mib
#   S-d  window end (--window-end EPOCH) reached, or --stop-file exists
#   S-e  free disk on --disk-path < --min-disk-gb
#   S-f  the same first compile error twice (signature kept in --errors-file); no blind retry
#
# S-a/S-f are classified after the unit ended (post-run); S-b..S-e stop the unit with
# `systemctl --user stop`. Every sample goes to --csv. The outcome goes to --status (one line):
#   done | failed:error | failed:unknown | stopped:S-a .. stopped:S-f | stopped:manual
# Exit code: 0 done, 1 failed:*, 2 stopped:*.
set -uo pipefail

UNIT=ocv-build
INTERVAL=5
MIN_AVAIL_MIB=512
MIN_AVAIL_SAMPLES=6
ZRAM_MAX_MIB=3072
MIN_DISK_GB=50
DISK_PATH=/
WINDOW_END=""
STOP_FILE=""
CSV=""
STATUS=""
EVENTS=""
BUILD_LOG=""
LOG_OFFSET=0
ERRORS_FILE=""
RC_FILE=""
PROCS='cc1plus|cicc|ptxas|nvcc|ld'
START_TIMEOUT=60
ATTEMPT_START=$(date +%s)

usage() {
  cat <<'EOF'
usage: watchdog.sh [--unit NAME] [--csv FILE] [--status FILE] [--events FILE]
                   [--interval S] [--min-avail-mib N] [--min-avail-samples N]
                   [--zram-max-mib N] [--min-disk-gb N] [--disk-path DIR]
                   [--window-end EPOCH] [--stop-file FILE]
                   [--build-log FILE] [--log-offset BYTES] [--errors-file FILE]
                   [--rc-file FILE] [--attempt-start EPOCH] [--procs REGEX]
                   [--start-timeout S]
Defaults: unit ocv-build, interval 5 s, 512 MiB x 6 samples, zram 3072 MiB, disk 50 GB.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --unit) UNIT=$2; shift 2 ;;
    --csv) CSV=$2; shift 2 ;;
    --status) STATUS=$2; shift 2 ;;
    --events) EVENTS=$2; shift 2 ;;
    --interval) INTERVAL=$2; shift 2 ;;
    --min-avail-mib) MIN_AVAIL_MIB=$2; shift 2 ;;
    --min-avail-samples) MIN_AVAIL_SAMPLES=$2; shift 2 ;;
    --zram-max-mib) ZRAM_MAX_MIB=$2; shift 2 ;;
    --min-disk-gb) MIN_DISK_GB=$2; shift 2 ;;
    --disk-path) DISK_PATH=$2; shift 2 ;;
    --window-end) WINDOW_END=$2; shift 2 ;;
    --stop-file) STOP_FILE=$2; shift 2 ;;
    --build-log) BUILD_LOG=$2; shift 2 ;;
    --log-offset) LOG_OFFSET=$2; shift 2 ;;
    --errors-file) ERRORS_FILE=$2; shift 2 ;;
    --rc-file) RC_FILE=$2; shift 2 ;;
    --attempt-start) ATTEMPT_START=$2; shift 2 ;;
    --procs) PROCS=$2; shift 2 ;;
    --start-timeout) START_TIMEOUT=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "watchdog.sh: unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

for v in INTERVAL MIN_AVAIL_MIB MIN_AVAIL_SAMPLES ZRAM_MAX_MIB MIN_DISK_GB LOG_OFFSET \
  START_TIMEOUT ATTEMPT_START; do
  [[ ${!v} =~ ^[0-9]+$ ]] || { echo "watchdog.sh: $v must be a non-negative integer" >&2; exit 64; }
done
[ -z "$WINDOW_END" ] || [[ $WINDOW_END =~ ^[0-9]+$ ]] \
  || { echo "watchdog.sh: --window-end must be an epoch" >&2; exit 64; }
[[ $UNIT =~ ^[A-Za-z0-9_.@-]+$ ]] || { echo "watchdog.sh: bad unit name" >&2; exit 64; }
SERVICE="$UNIT.service"

log() { printf '%s watchdog[%s] %s\n' "$(date '+%F %T')" "$UNIT" "$*"; }

# JSON-lines event; detail must not contain double quotes or backslashes.
ev() {
  [ -n "$EVENTS" ] || return 0
  local detail=${2//[\"\\]/_}
  printf '{"ts":"%s","event":"%s","detail":"%s"}\n' "$(date -u '+%FT%TZ')" "$1" "$detail" >>"$EVENTS"
}

set_status() {
  [ -n "$STATUS" ] || return 0
  printf '%s\n' "$1" >"$STATUS"
}

# ActiveState of the unit; "unknown" when systemctl itself fails. A failing systemctl must never
# be read as "the unit ended": the build could still be running without a guard.
unit_state() {
  local s
  s=$(systemctl --user show -p ActiveState --value "$SERVICE" 2>/dev/null) || { echo unknown; return; }
  [ -n "$s" ] && echo "$s" || echo unknown
}

mem_available_mib() { awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo; }

# zram swap in use (uncompressed data held in zram, as `swapon --show` USED); zram is RAM.
zram_used_mib() { awk '$1 ~ /^\/dev\/zram/ {s += $4} END {print int(s / 1024)}' /proc/swaps; }

disk_free_gb() { df -P -B1G "$DISK_PATH" 2>/dev/null | awk 'NR == 2 {print $4 + 0}'; }

# prints: <max VmRSS MiB> <max VmHWM MiB> <process name> of the watched compiler/linker processes
sample_procs() {
  local pid rss hwm name best_rss=0 best_hwm=0 best_name=-
  for pid in $(pgrep -x "$PROCS" 2>/dev/null); do
    read -r rss hwm name < <(awk '/^Name:/ {n = $2} /^VmRSS:/ {r = $2} /^VmHWM:/ {h = $2}
      END {print int((r + 1023) / 1024), int((h + 1023) / 1024), n}' "/proc/$pid/status" 2>/dev/null)
    [ -n "${rss:-}" ] || continue
    if [ "$rss" -gt "$best_rss" ]; then best_rss=$rss; best_name=$name; fi
    if [ "$hwm" -gt "$best_hwm" ]; then best_hwm=$hwm; fi
  done
  echo "$best_rss $best_hwm $best_name"
}

oom_kill_count() {
  local cg
  cg=$(systemctl --user show -p ControlGroup --value "$SERVICE" 2>/dev/null)
  [ -n "$cg" ] || { echo 0; return; }
  awk '$1 == "oom_kill" {print $2; f = 1} END {if (!f) print 0}' \
    "/sys/fs/cgroup$cg/memory.events" 2>/dev/null || echo 0
}

log_segment() {
  [ -n "$BUILD_LOG" ] && [ -r "$BUILD_LOG" ] || return 0
  tail -c +"$((LOG_OFFSET + 1))" "$BUILD_LOG"
}

# S-a evidence after the unit ended: compiler "Killed" in the log, the user manager's OOM
# message in the journal, or the kernel's memcg OOM line naming the unit.
oom_evidence() {
  if log_segment | grep -Eq \
    'Killed signal terminated program|died due to signal 9|internal compiler error: Killed|Error 137'; then
    echo "build log"; return 0
  fi
  if journalctl --no-pager -o cat --since "@$ATTEMPT_START" "USER_UNIT=$SERVICE" 2>/dev/null |
    grep -Eq "killed by the OOM killer|Failed with result 'oom-kill'"; then
    echo "journal (user manager)"; return 0
  fi
  if journalctl -k --no-pager -o cat --since "@$ATTEMPT_START" 2>/dev/null |
    grep -Fq "/$SERVICE"; then
    echo "journal (kernel memcg)"; return 0
  fi
  return 1
}

# First compile error of this attempt's log segment, normalised (no directories, no line or
# column numbers) so the same error compares equal across attempts.
error_signature() {
  local pat line=""
  for pat in 'error:' 'undefined reference' 'CMake Error' 'Error [0-9]+$'; do
    line=$(log_segment | grep -Em1 -- "$pat" || true)
    [ -z "$line" ] || break
  done
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" |
    sed -E 's#[^ :"'"'"'(]*/##g; s#:[0-9]+(:[0-9]+)?#:#g; s/[[:space:]]+$//' | cut -c1-300
}

finish() { # status, detail
  set_status "$1"
  ev "watchdog_result" "$1 $2"
  log "result: $1 ${2:+($2)}"
  case "$1" in
    "done") exit 0 ;;
    failed:*) exit 1 ;;
    *) exit 2 ;;
  esac
}

post_run() {
  local rc="" evidence sig
  [ -z "$RC_FILE" ] || rc=$(cat "$RC_FILE" 2>/dev/null || true)
  if [ "$rc" = "0" ]; then
    [ -z "$ERRORS_FILE" ] || : >"$ERRORS_FILE"
    finish "done" "unit exited 0"
  fi
  if evidence=$(oom_evidence); then
    finish stopped:S-a "OOM kill: $evidence"
  fi
  sig=$(error_signature)
  if [ -n "$sig" ] && [ -n "$ERRORS_FILE" ]; then
    if grep -qxF -- "$sig" "$ERRORS_FILE" 2>/dev/null; then
      finish stopped:S-f "same compile error twice: $sig"
    fi
    printf '%s\n' "$sig" >>"$ERRORS_FILE"
    finish failed:error "first occurrence: $sig"
  fi
  [ -z "$sig" ] || finish failed:error "$sig"
  if [ "$rc" = "143" ] || [ "$rc" = "130" ]; then
    finish stopped:manual "unit was stopped from outside (rc $rc)"
  fi
  finish failed:unknown "rc ${rc:-absent}, no OOM evidence, no compile error found"
}

stop_unit() {
  log "stopping $SERVICE ($1)"
  ev "stop" "$1"
  systemctl --user stop "$SERVICE" 2>&1 | sed 's/^/  /'
}

if [ -n "$CSV" ] && [ ! -s "$CSV" ]; then
  echo "epoch,time,mem_available_mib,zram_used_mib,disk_free_gb,max_rss_mib,max_hwm_mib,max_rss_proc" >"$CSV"
fi
set_status running
log "watching $SERVICE every ${INTERVAL}s: S-b ${MIN_AVAIL_MIB} MiB x ${MIN_AVAIL_SAMPLES}," \
  "S-c ${ZRAM_MAX_MIB} MiB zram, S-e ${MIN_DISK_GB} GB on ${DISK_PATH}"

low_count=0
seen_active=0
waited=0
unknown_count=0
fired=""
while true; do
  state=$(unit_state)
  if [ "$state" = unknown ]; then
    unknown_count=$((unknown_count + 1))
    log "systemctl could not report the state of $SERVICE ($unknown_count in a row); not treating it as ended"
    if [ "$unknown_count" -ge 12 ]; then
      stop_unit "unit state unavailable"
      finish failed:unknown "systemctl failed $unknown_count times in a row"
    fi
    sleep "$INTERVAL"
    continue
  fi
  unknown_count=0
  if [ "$state" != inactive ] && [ "$state" != failed ]; then
    seen_active=1
  else
    # the unit may have run and ended before the first sample: a written rc file proves it
    if [ "$seen_active" = 1 ] || [ "$waited" -ge "$START_TIMEOUT" ] ||
      { [ -n "$RC_FILE" ] && [ -s "$RC_FILE" ]; }; then break; fi
    waited=$((waited + INTERVAL))
    sleep "$INTERVAL"
    continue
  fi

  avail=$(mem_available_mib)
  zram=$(zram_used_mib)
  disk=$(disk_free_gb)
  read -r max_rss max_hwm max_name < <(sample_procs)
  if [ -n "$CSV" ]; then
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$(date '+%F %T')" "$avail" "$zram" \
      "$disk" "$max_rss" "$max_hwm" "$max_name" >>"$CSV"
  fi

  if [ "$(oom_kill_count)" -gt 0 ]; then
    fired="S-a"; detail="memory.events oom_kill > 0"
  fi
  if [ "$avail" -lt "$MIN_AVAIL_MIB" ]; then low_count=$((low_count + 1)); else low_count=0; fi
  if [ -z "$fired" ] && [ "$low_count" -ge "$MIN_AVAIL_SAMPLES" ]; then
    fired="S-b"; detail="MemAvailable ${avail} MiB < ${MIN_AVAIL_MIB} MiB for ${low_count} samples"
  fi
  if [ -z "$fired" ] && [ "$zram" -gt "$ZRAM_MAX_MIB" ]; then
    fired="S-c"; detail="zram used ${zram} MiB > ${ZRAM_MAX_MIB} MiB"
  fi
  if [ -z "$fired" ] && [ -n "$WINDOW_END" ] && [ "$(date +%s)" -ge "$WINDOW_END" ]; then
    fired="S-d"; detail="window end reached"
  fi
  if [ -z "$fired" ] && [ -n "$STOP_FILE" ] && [ -e "$STOP_FILE" ]; then
    fired="S-d"; detail="stop file present"
  fi
  if [ -z "$fired" ] && [ "$disk" -lt "$MIN_DISK_GB" ]; then
    fired="S-e"; detail="free disk ${disk} GB < ${MIN_DISK_GB} GB on ${DISK_PATH}"
  fi
  if [ -n "$fired" ]; then
    stop_unit "$fired: $detail"
    finish "stopped:$fired" "$detail"
  fi
  sleep "$INTERVAL"
done

if [ "$seen_active" = 0 ] && { [ -z "$RC_FILE" ] || [ ! -s "$RC_FILE" ]; }; then
  finish failed:unknown "unit never became active within ${START_TIMEOUT}s"
fi
post_run
