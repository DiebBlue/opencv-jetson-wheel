#!/usr/bin/env bash
# build.sh - reproducible native build of the OpenCV 5.0.0 headless wheel with CUDA + GStreamer
# for the Jetson Orin Nano (JetPack 6 / L4T R36).
#
#   build.sh --dry-run [--jobs N]   print resolved pins, env and the full CMake args; no network
#   build.sh fetch                  clone sources at the pinned SHAs, patch, create $BV, check setup.py
#   build.sh pilot [--jobs N]       configure + build only the CUDA module targets (default -j2)
#   build.sh full  [--jobs N]       setup.py bdist_wheel, resumable (rerun resumes)
#   build.sh record                 copy the wheel + SHA256SUMS + build info into $WH/ocv
#   build.sh night --window-end T   unattended chain: fetch -> pilot -> J -> full -> record
#                                   (--no-window, --max-jobs N, --repilot; run as a systemd user unit)
#
# Nothing host-specific is hard-coded: BUILD, BV, WH, CUDA_HOME are variables with defaults;
# host guards come from the optional local.env (see local.env.example). $BUILD must not lie in a git work tree.
set -euo pipefail

BH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CMD=${CMD:-build}

# shellcheck source=pins.env
. "$BH/pins.env"

# Optional host-specific guards, set in local.env (gitignored, see local.env.example); all empty by
# default. A value already in the environment is the default, local.env overrides it.
#   PRECHECK_UNITS     systemd (system scope) units that must not be active when a build starts
#   PRECHECK_PGREP     pgrep -f pattern of processes that must not be running when a build starts
#   FORBIDDEN_DIRS     directories (whitespace-separated) the build must not run in or under
#   FORBIDDEN_BV_GLOB  glob; a build venv ($BV) whose directory name matches it is refused
PRECHECK_UNITS=${PRECHECK_UNITS:-}
PRECHECK_PGREP=${PRECHECK_PGREP:-}
FORBIDDEN_DIRS=${FORBIDDEN_DIRS:-}
FORBIDDEN_BV_GLOB=${FORBIDDEN_BV_GLOB:-}
LOCAL_ENV=$BH/local.env
# Test hook (tests/): honoured only with OCV_TEST=1, never in a real run.
if [ "${OCV_TEST:-}" = 1 ]; then LOCAL_ENV=${OCV_LOCAL_ENV:-$LOCAL_ENV}; fi
# shellcheck source=local.env.example
[ ! -e "$LOCAL_ENV" ] || . "$LOCAL_ENV"

BUILD=${BUILD:-$HOME/build/ocv5}
BV=${BV:-$HOME/venvs/ocv-build}
WH=${WH:-$HOME/wheelhouse}
CUDA_HOME=${CUDA_HOME:-/usr/local/cuda}
SRC=$BUILD/src
LOGS=$BUILD/logs
PILOT=$BUILD/pilot
UNIT=ocv-build
STEP_BIN=$BH/build.sh
CHAIN=0
# Test hooks (tests/): honoured only with OCV_TEST=1, never in a real run.
if [ "${OCV_TEST:-}" = 1 ]; then
  STEP_BIN=${OCV_STEP_BIN:-$STEP_BIN} # executable the night chain starts inside the unit
  UNIT=${OCV_TEST_UNIT:-$UNIT}        # unit name, so tests never touch a real ocv-build
fi

# ---------------------------------------------------------------- helpers

log() { printf '%s %s: %s\n' "$(date '+%F %T')" "$CMD" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# JSON-lines event in $LOGS/events.jsonl: ev <event> key=value ... (no quotes in values)
ev() {
  [ -d "$LOGS" ] || return 0
  local name=$1 kv k v out
  shift
  out="{\"ts\":\"$(date -u '+%FT%TZ')\",\"event\":\"$name\""
  for kv in "$@"; do
    k=${kv%%=*}
    v=${kv#*=}
    v=${v//[\"\\]/_}
    v=${v//"$HOME"/\~}
    if [[ $v =~ ^[0-9]+$ ]]; then out+=",\"$k\":$v"; else out+=",\"$k\":\"$v\""; fi
  done
  printf '%s}\n' "$out" >>"$LOGS/events.jsonl"
}

mem_available_mib() { awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo; }

# RAM table: MemAvailable at chain start -> "J MemoryMax MemorySwapMax"; rc 1 = do not start
row_for_mem() {
  local a=$1
  if [ "$a" -ge 5120 ]; then echo "4 4096M 1536M"
  elif [ "$a" -ge 2816 ]; then echo "2 2304M 1536M"
  elif [ "$a" -ge 2048 ]; then echo "1 1536M 1024M"
  else return 1; fi
}

# limits of the table row for J (pilot runs at "-j2", capped by the row of the free memory)
row_for_j() {
  case $1 in
    4) echo "4096M 1536M" ;;
    2) echo "2304M 1536M" ;;
    1) echo "1536M 1024M" ;;
    *) return 1 ;;
  esac
}

realpath_m() { realpath -m -- "$1"; }

under() { # path is root or below it
  [ "$1" = "$2" ] || [[ $1 == "$2"/* ]]
}

# nearest existing ancestor directory of a path (for git and df checks before it is created)
existing_ancestor() {
  local d=$1
  while [ ! -d "$d" ]; do d=$(dirname "$d"); done
  printf '%s\n' "$d"
}

# BUILD is deleted and rewritten wholesale: never empty, never "/", always below $HOME
check_build_path() {
  local b h
  [ -n "$BUILD" ] || die "BUILD is empty"
  b=$(realpath_m "$BUILD")
  h=$(realpath_m "$HOME")
  [ "$b" != / ] || die "BUILD must not be /"
  if [ "${OCV_TEST:-}" != 1 ]; then
    if [ "$b" = "$h" ] || ! under "$b" "$h"; then die "BUILD must be a directory below $HOME: $BUILD"; fi
  fi
}

guard() {
  local p f d
  check_build_path
  for p in "$(realpath_m "$PWD")" "$(realpath_m "$BH")" "$(realpath_m "$BUILD")"; do
    for f in $FORBIDDEN_DIRS; do
      ! under "$p" "$f" || die "refusing to run inside $f ($p)"
    done
  done
  [[ $BUILD != *[[:space:]]* ]] || die "BUILD must not contain whitespace"
  if [ -n "$FORBIDDEN_BV_GLOB" ]; then
    # shellcheck disable=SC2053 # the glob is meant to match
    [[ $(basename "$BV") != $FORBIDDEN_BV_GLOB ]] || die "BV matches FORBIDDEN_BV_GLOB ($FORBIDDEN_BV_GLOB): $BV"
  fi
  d=$(existing_ancestor "$BUILD")
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "BUILD ($BUILD) lies inside a git work tree"
  fi
}

load_pins() {
  [[ $OPENCV_PYTHON_SHA =~ ^[0-9a-f]{40}$ ]] || die "OPENCV_PYTHON_SHA is not a 40-hex SHA"
  [[ $OPENCV_SHA =~ ^[0-9a-f]{40}$ ]] || die "OPENCV_SHA is not a 40-hex SHA"
  [[ $OPENCV_CONTRIB_SHA =~ ^[0-9a-f]{40}$ ]] || die "OPENCV_CONTRIB_SHA is not a 40-hex SHA"
  [[ $OPENCV_PYTHON_TAG =~ ^[0-9]+$ ]] || die "OPENCV_PYTHON_TAG must be numeric"
  [[ $LOCAL_LABEL =~ ^cu[0-9]+\.l4t[0-9]+\.[0-9]+$ ]] || die "LOCAL_LABEL has the wrong form"
  [[ $CUDA_ARCH_BIN =~ ^[0-9]+\.[0-9]+$ ]] || die "CUDA_ARCH_BIN has the wrong form"
  [ -n "$CUDA_MODULES" ] || die "CUDA_MODULES is empty"
}

# one CMake flag per line, placeholders expanded
cmake_flags() {
  local mods="" m line tok
  local -a toks
  for m in $CUDA_MODULES; do mods+="${mods:+;}$SRC/opencv_contrib/modules/$m"; done
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    read -ra toks <<<"$line"
    for tok in "${toks[@]}"; do
      tok=${tok//@BUILD@/$BUILD}
      tok=${tok//@CUDA_ARCH_BIN@/$CUDA_ARCH_BIN}
      tok=${tok//@EXTRA_MODULES_PATH@/$mods}
      printf '%s\n' "$tok"
    done
  done <"$BH/cmake-flags.txt"
}

# python facts as setup.py (tag 93) derives them via scikit-build; placeholders if $BV is not ready
py_probe() {
  if [ -x "$BV/bin/python" ] && "$BV/bin/python" - 2>/dev/null <<'PY'
import sys
from skbuild import cmaker
v = cmaker.CMaker.get_python_version()
lib = cmaker.CMaker.get_python_library(v) or ""
if lib == "":
    lib = "libpython%sm.a" % v
print(sys.executable)
print(cmaker.CMaker.get_python_include_dir(v).replace("\\", "/"))
print(lib.replace("\\", "/"))
PY
  then return 0; fi
  printf '%s\n' "<PYTHON3_EXECUTABLE: $BV/bin/python not ready>" "<PYTHON3_INCLUDE_DIR>" "<PYTHON3_LIBRARY>"
  return 1
}

# setup.py (tag 93) cmake_args for a headless, non-contrib CI_BUILD on Linux, plus skbuild's
# build type, one per line. The pilot configures with these so it matches the setup.py configure.
# On a new opencv-python tag diff them against setup.py (README "Updating for a new release").
setup_equivalent_args() {
  local py inc lib
  { read -r py; read -r inc; read -r lib; } < <(py_probe || true)
  printf '%s\n' \
    -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    "-DPYTHON3_EXECUTABLE=$py" "-DPYTHON_DEFAULT_EXECUTABLE=$py" \
    "-DPYTHON3_INCLUDE_DIR=$inc" "-DPYTHON3_LIBRARY=$lib" \
    -DBUILD_opencv_python3=ON -DBUILD_opencv_python2=OFF -DBUILD_opencv_java=OFF \
    -DOPENCV_PYTHON3_INSTALL_PATH=python -DINSTALL_CREATE_DISTRIB=ON \
    -DBUILD_opencv_apps=OFF -DBUILD_opencv_freetype=OFF -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_DOCS=OFF \
    -DPYTHON3_LIMITED_API=ON -DBUILD_OPENEXR=ON \
    -DWITH_WIN32UI=OFF -DWITH_QT=OFF -DWITH_GTK=OFF -DWITH_MSMF=OFF -DWITH_OBSENSOR=OFF \
    -DOPENCV_FFMPEG_ENABLE_LIBAVDEVICE=OFF \
    -DWITH_V4L=ON -DWITH_LAPACK=ON -DENABLE_PRECOMPILED_HEADERS=OFF
}

# KEY=VALUE lines of the build environment (jobs may be a placeholder in --dry-run)
build_env() {
  local jobs=$1 flags
  flags=$(cmake_flags | tr '\n' ' ')
  printf '%s\n' \
    "ENABLE_HEADLESS=1" "ENABLE_CONTRIB=0" "CI_BUILD=1" "OPENCV_PYTHON_SKIP_GIT_COMMANDS=1" \
    "OCV_LOCAL_LABEL=$LOCAL_LABEL" \
    "CCACHE_DIR=$BUILD/ccache" "CCACHE_BASEDIR=$SRC" "CCACHE_MAXSIZE=8G" \
    "MAKEFLAGS=-j$jobs" \
    "CMAKE_ARGS=${flags% }" \
    "PATH=$CUDA_HOME/bin:/usr/local/bin:/usr/bin:/bin" "LC_ALL=C" "HOME=$HOME"
}

# run a command in the clean build environment (env -i; nothing leaks from the caller)
in_build_env() {
  local jobs=$1
  shift
  local -a envv
  mapfile -t envv < <(build_env "$jobs")
  env -i "${envv[@]}" "$@"
}

# source patches as "<file in patches/>:<git work tree relative to $SRC>"
PATCHES=(
  "local-version.patch:."
  "opencv-numpy-include-first.patch:opencv"
)

fingerprint() {
  (cd "$BH" && sha256sum pins.env cmake-flags.txt build-requirements.txt \
    "${PATCHES[@]/#/patches/}" 2>/dev/null | sha256sum | cut -c1-16)
}

# ---------------------------------------------------------------- dry run

cmd_dry_run() {
  local jobs='<J>' row
  while [ $# -gt 0 ]; do
    case "$1" in
      --jobs) jobs=$2; shift 2 ;;
      *) die "dry-run: unknown option $1" ;;
    esac
  done
  load_pins
  guard
  echo "== pins ($BH/pins.env)"
  printf '%s=%s\n' OPENCV_PYTHON_TAG "$OPENCV_PYTHON_TAG" OPENCV_PYTHON_SHA "$OPENCV_PYTHON_SHA" \
    OPENCV_SHA "$OPENCV_SHA" OPENCV_CONTRIB_SHA "$OPENCV_CONTRIB_SHA" LOCAL_LABEL "$LOCAL_LABEL" \
    CUDA_ARCH_BIN "$CUDA_ARCH_BIN" CUDA_MODULES "$CUDA_MODULES" PILOT_TARGETS "$PILOT_TARGETS"
  echo "== layout"
  printf '%s=%s\n' BH "$BH" BUILD "$BUILD" SRC "$SRC" PILOT "$PILOT" BV "$BV" WH "$WH" \
    CUDA_HOME "$CUDA_HOME" "wheel" "opencv_python_headless-<version>+${LOCAL_LABEL}-cp37-abi3-linux_aarch64.whl"
  echo "== environment for setup.py (env -i; MAKEFLAGS jobs = $jobs)"
  build_env "$jobs" | grep -v '^CMAKE_ARGS=' | sed 's/^/  /'
  echo "== CMAKE_ARGS (cmake-flags.txt expanded; one per line)"
  cmake_flags | sed 's/^/  /'
  echo "== full build command"
  echo "  (cd $SRC && env -i <environment above> $BV/bin/python setup.py bdist_wheel --py-limited-api=cp37 -v)"
  echo "== pilot configure command (setup.py-equivalent args + CMAKE_ARGS)"
  echo "  cmake -S $SRC/opencv -B $PILOT   (one argument per line below)"
  { setup_equivalent_args; cmake_flags; } | sed 's/^/    /'
  echo "== pilot build command"
  echo "  make -C $PILOT -j<J> $PILOT_TARGETS"
  echo "== host guards (${LOCAL_ENV##*/}$([ -e "$LOCAL_ENV" ] || echo ' not present'))"
  printf '  %s=%s\n' PRECHECK_UNITS "$PRECHECK_UNITS" PRECHECK_PGREP "$PRECHECK_PGREP" \
    FORBIDDEN_DIRS "$FORBIDDEN_DIRS" FORBIDDEN_BV_GLOB "$FORBIDDEN_BV_GLOB"
  echo "== RAM table row for MemAvailable now"
  if row=$(row_for_mem "$(mem_available_mib)"); then
    echo "  MemAvailable $(mem_available_mib) MiB -> J MemoryMax MemorySwapMax = $row"
  else
    echo "  MemAvailable $(mem_available_mib) MiB < 2048 MiB: a build would not start"
  fi
  echo "== dry run ok (no network, nothing written)"
}

# ---------------------------------------------------------------- fetch

assert_sha() { # dir expected label
  local got
  got=$(git -C "$1" rev-parse HEAD 2>/dev/null) || die "$3: $1 is not a git checkout"
  [ "$got" = "$2" ] || die "$3 SHA mismatch: expected $2, found $got"
}

assert_sources() {
  [ -d "$SRC/.git" ] || die "sources missing under $SRC: run 'build.sh fetch'"
  assert_sha "$SRC" "$OPENCV_PYTHON_SHA" opencv-python
  assert_sha "$SRC/opencv" "$OPENCV_SHA" opencv
  assert_sha "$SRC/opencv_contrib" "$OPENCV_CONTRIB_SHA" opencv_contrib
  local e
  for e in "${PATCHES[@]}"; do
    git -C "$SRC/${e#*:}" apply --reverse --check "$BH/patches/${e%%:*}" 2>/dev/null \
      || die "${e%%:*} is not applied in $SRC/${e#*:}: run 'build.sh fetch'"
  done
}

apply_patch() {
  local e p d
  for e in "${PATCHES[@]}"; do
    p=$BH/patches/${e%%:*} d=$SRC/${e#*:}
    if git -C "$d" apply --reverse --check "$p" 2>/dev/null; then
      log "${e%%:*} already applied"
    elif git -C "$d" apply --check "$p" 2>/dev/null; then
      git -C "$d" apply "$p"
      log "applied ${e%%:*}"
    else
      die "${e%%:*} applies neither forward nor in reverse in $d"
    fi
  done
}

ensure_build_venv() {
  if [ ! -x "$BV/bin/python" ]; then
    log "creating $BV"
    /usr/bin/python3 -m venv "$BV"
  fi
  "$BV/bin/python" -m pip install --disable-pip-version-check --require-hashes --no-deps \
    -r "$BH/build-requirements.txt" >&2
}

# version string as setup.py's find_version.py yields it, with and without OCV_LOCAL_LABEL
version_via_find_version() { # label-or-empty
  (cd "$SRC" && env -i HOME="$HOME" PATH=/usr/bin:/bin ${1:+OCV_LOCAL_LABEL="$1"} \
    "$BV/bin/python" -c '
import runpy, sys
sys.argv = ["", "False", "True", "False", "True"]  # contrib headless rolling ci_build, as setup.py
runpy.run_path("find_version.py", run_name="__main__")
ns = {}
exec(open("cv2/version.py").read(), ns)
print(ns["opencv_version"])')
}

check_version() {
  local with without
  without=$(version_via_find_version "")
  with=$(version_via_find_version "$LOCAL_LABEL")
  log "find_version: without label '$without', with label '$with'"
  [ "$without" = "5.0.0.$OPENCV_PYTHON_TAG" ] || die "unlabelled version is '$without'"
  [ "$with" = "5.0.0.$OPENCV_PYTHON_TAG+$LOCAL_LABEL" ] || die "labelled version is '$with'"
}

cmd_fetch() {
  load_pins
  guard
  command -v git >/dev/null || die "git not found"
  mkdir -p "$BUILD" "$LOGS"
  if [ ! -d "$SRC/.git" ]; then
    if [ -e "$SRC" ] && [ -n "$(ls -A "$SRC")" ]; then die "$SRC exists but is not a git checkout"; fi
    log "cloning opencv-python tag $OPENCV_PYTHON_TAG"
    git clone --quiet --branch "$OPENCV_PYTHON_TAG" --depth 1 -c advice.detachedHead=false \
      "$OPENCV_PYTHON_REPO" "$SRC"
  fi
  assert_sha "$SRC" "$OPENCV_PYTHON_SHA" opencv-python
  # only these two submodules (not multibuild, not opencv_extra)
  (cd "$SRC" && git submodule update --init opencv opencv_contrib) >&2
  assert_sha "$SRC/opencv" "$OPENCV_SHA" opencv
  assert_sha "$SRC/opencv_contrib" "$OPENCV_CONTRIB_SHA" opencv_contrib
  apply_patch
  ensure_build_venv
  check_version
  log "check: setup.py bdist_wheel --help"
  (cd "$SRC" && env -i HOME="$HOME" PATH=/usr/bin:/bin OCV_LOCAL_LABEL="$LOCAL_LABEL" \
    "$BV/bin/python" setup.py bdist_wheel --help >/dev/null 2>"$LOGS/setup_help.err") \
    || die "setup.py check failed: '$BV/bin/python setup.py bdist_wheel --help' (see $LOGS/setup_help.err)"
  ev fetch_ok opencv_python="$OPENCV_PYTHON_SHA" opencv="$OPENCV_SHA" contrib="$OPENCV_CONTRIB_SHA"
  log "fetch ok: sources at the pinned SHAs, patch applied, $BV ready, setup.py check passed"
}

# ---------------------------------------------------------------- board preconditions

precheck() {
  local avail free u
  for u in $PRECHECK_UNITS; do
    if systemctl is-active --quiet "$u"; then log "PRECHECK: $u is active"; return 1; fi
  done
  if [ -n "$PRECHECK_PGREP" ] && pgrep -af "$PRECHECK_PGREP" >&2; then
    log "PRECHECK: a process matching PRECHECK_PGREP is running (listed above)"; return 1
  fi
  if systemctl --user is-active --quiet "$UNIT.service"; then
    log "PRECHECK: unit $UNIT is already running"; return 1
  fi
  avail=$(mem_available_mib)
  row_for_mem "$avail" >/dev/null || { log "PRECHECK: MemAvailable $avail MiB < 2048 MiB"; return 1; }
  free=$(df -P -B1G "$(existing_ancestor "$BUILD")" | awk 'NR == 2 {print $4 + 0}')
  [ "$free" -ge 50 ] || { log "PRECHECK: free disk for $BUILD is $free GB < 50 GB"; return 1; }
  log "precheck ok: no listed unit active, no listed process running, MemAvailable $avail MiB, disk $free GB"
}

# ---------------------------------------------------------------- inner steps (run in the unit)

step_begin() { # step: log file, rc file, TERM handling
  local step=$1
  mkdir -p "$LOGS" "$BUILD/downloads" "$BUILD/ccache"
  STEP_RC_FILE=$LOGS/$step.rc
  trap 'echo $? >"$STEP_RC_FILE"' EXIT
  trap 'exit 143' TERM INT
  log "$step: logging to $LOGS/$step.log" # still on the caller's stderr
  exec >>"$LOGS/$step.log" 2>&1
  CMD=$step
  log "---- $step start (pid $$, jobs ${JOBS:-?}, fingerprint $(fingerprint))"
}

parse_jobs() { # default; remaining args. --chain: started by night, which ran the precheck
  JOBS=$1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --jobs) JOBS=${2:-}; shift 2 ;;
      --chain) CHAIN=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
}

# csv column maximum: 6 = max_rss_mib, 7 = max_hwm_mib
csv_peak() { # file column
  [ -s "$1" ] || { echo 0; return; }
  awk -F, -v c="$2" 'NR > 1 && $c + 0 > m {m = $c + 0} END {print m + 0}' "$1"
}

# Compare the pilot's configure summary with the PyPI reference (before compiling anything; "W3").
# Writes $LOGS/w3.txt (verdict per line) and $LOGS/w3_diff.txt (every differing line, informational).
w3_check() {
  "$BV/bin/python" - "$PILOT/version_string.tmp" "$BH/reference/pypi-5.0.0.93-buildinfo.txt" \
    "$LOGS/w3.txt" "$LOGS/w3_diff.txt" "$CUDA_MODULES" <<'PY'
import difflib
import re
import sys

summary_path, ref_path, out_path, diff_path, cuda_modules = sys.argv[1:6]


def load_summary(path):
    lines = []
    for raw in open(path, encoding="utf-8"):
        raw = raw.rstrip("\n")
        m = re.fullmatch(r'"(.*)\\n"', raw)
        s = m.group(1) if m else raw
        lines.append(s.replace('\\"', '"').replace("\\\\", "\\"))
    return lines


def load_plain(path):
    return open(path, encoding="utf-8").read().splitlines()


def table(lines):
    t = {}
    for line in lines:
        m = re.match(r"^\s*([^:]+?):\s*(.*?)\s*$", line)
        if m:
            t.setdefault(m.group(1), []).append(m.group(2))
    return t


new_lines = load_summary(summary_path)
ref_lines = load_plain(ref_path)
new, ref = table(new_lines), table(ref_lines)


def first(t, key):
    v = t.get(key)
    return v[0] if v else None


results = []


def check(name, ok, detail):
    results.append((ok, "%-34s %s" % (name, detail)))


for key in ("Baseline", "Built as dynamic libs?",
            "Parallel framework", "Custom HAL", "JPEG", "TIFF", "WEBP", "JPEG 2000",
            "Limited API", "Algorithm Hint"):
    a, b = first(ref, key), first(new, key)
    check("equal: " + key, a is not None and a == b, "reference=%r build=%r" % (a, b))

np_line = first(new, "numpy") or ""
check("equal: numpy headers", "(ver 2.0.2)" in np_line, repr(np_line))


def intended(key, pred, what):
    v = first(new, key)
    check("intended: " + key, pred(v), "%s (build=%r)" % (what, v))


intended("NVIDIA CUDA", lambda v: bool(v and re.match(r"YES \(ver 12\.6", v)), "YES (ver 12.6...)")
intended("NVIDIA GPU arch", lambda v: v == "87", "87")
intended("NVIDIA PTX archs", lambda v: v in (None, ""), "empty")
intended("cuDNN", lambda v: v is None or v.startswith("NO"), "NO or absent")
intended("GStreamer", lambda v: bool(v and re.match(r"YES \(1\.20\.3\)", v)), "YES (1.20.3)")
intended("FFMPEG", lambda v: bool(v and v.startswith("YES")), "YES")
# A reconfigure of an existing build dir reports "YES (Unknown <libs>)": OpenCVFindLAPACK.cmake
# skips detection when LAPACK_LIBRARIES is cached, so the implementation id is lost, not the library.
intended("Lapack", lambda v: bool(v and v.startswith("YES (") and "libopenblas" in v),
         "YES (... libopenblas ...)")
intended("C++ Compiler", lambda v: bool(v and "(ver 11.4" in v), "GCC 11.4")
intended("PNG", lambda v: bool(v) and not v.startswith("build"), "system libpng, not built")
intended("AVIF", lambda v: v is None or v.startswith("NO"), "NO or absent")
intended("Dispatched code generation",
         lambda v: bool(v) and sorted(v.split()) == ["NEON_DOTPROD", "NEON_FP16"],
         "NEON_DOTPROD NEON_FP16 (no NEON_BF16)")
intended("OpenCL", lambda v: v is None or v.startswith("NO"), "NO or absent")

ref_mods = set((first(ref, "To be built") or "").split())
new_mods = set((first(new, "To be built") or "").split())
want = ref_mods | set(m for m in cuda_modules.split())
check("intended: modules", new_mods == want,
      "missing=%s extra=%s" % (sorted(want - new_mods), sorted(new_mods - want)))

with open(out_path, "w", encoding="utf-8") as f:
    for ok, line in results:
        f.write(("OK       " if ok else "MISMATCH ") + line + "\n")
with open(diff_path, "w", encoding="utf-8") as f:
    norm = lambda ls: [re.sub(r"\s+", " ", l).strip() for l in ls if l.strip()]
    f.write("\n".join(difflib.unified_diff(norm(ref_lines), norm(new_lines), "pypi-5.0.0.93",
                                           "pilot-configure", lineterm="", n=0)) + "\n")
bad = [line for ok, line in results if not ok]
for ok, line in results:
    print(("OK       " if ok else "MISMATCH ") + line)
sys.exit(1 if bad else 0)
PY
}

write_pilot_json() { # reads $LOGS/pilot.state (+ csv peaks)
  local st=$LOGS/pilot.state wall=0 jobs=0 built=0 rc=1 total hwm rss
  # shellcheck disable=SC1090
  [ ! -r "$st" ] || . "$st"
  total=$(wc -w <<<"$PILOT_TARGETS")
  hwm=$(csv_peak "$LOGS/pilot_mem.csv" 7)
  rss=$(csv_peak "$LOGS/pilot_mem.csv" 6)
  printf '{"ok":%s,"jobs":%s,"wall_s":%s,"targets_built":%s,"targets_total":%s,"peak_hwm_mib":%s,"peak_rss_mib":%s,"fingerprint":"%s"}\n' \
    "$([ "$rc" = 0 ] && echo true || echo false)" "$jobs" "$wall" "$built" "$total" "$hwm" "$rss" \
    "$(fingerprint)" >"$LOGS/pilot.json"
}

cmd_pilot() {
  parse_jobs 2 "$@"
  load_pins
  guard
  step_begin pilot
  [ "$CHAIN" = 1 ] || precheck || exit 4
  assert_sources
  py_probe >/dev/null || die "$BV is not ready (run 'build.sh fetch')"
  local t0 rc=0 pat built
  t0=$(date +%s)
  rm -f "$LOGS/pilot.state"
  mkdir -p "$PILOT"
  local -a args
  mapfile -t args < <(setup_equivalent_args; cmake_flags)
  log "configure: cmake -S $SRC/opencv -B $PILOT (${#args[@]} args)"
  in_build_env "$JOBS" cmake -S "$SRC/opencv" -B "$PILOT" "${args[@]}" || exit 5
  log "W3: comparing the configure summary with the PyPI reference"
  if ! w3_check; then
    log "W3 MISMATCH: fix cmake-flags.txt before compiling (details in $LOGS/w3.txt, $LOGS/w3_diff.txt)"
    exit 3
  fi
  log "W3 ok"
  # shellcheck disable=SC2086
  in_build_env "$JOBS" make -C "$PILOT" "-j$JOBS" $PILOT_TARGETS || rc=$?
  pat=$(tr ' ' '|' <<<"$PILOT_TARGETS")
  built=$(grep -ohE "Built target ($pat)\$" "$LOGS/pilot.log" | sort -u | wc -l)
  printf 'wall=%s\njobs=%s\nbuilt=%s\nrc=%s\n' "$(($(date +%s) - t0))" "$JOBS" "$built" "$rc" \
    >"$LOGS/pilot.state"
  write_pilot_json
  log "pilot finished: rc=$rc, $built/$(wc -w <<<"$PILOT_TARGETS") targets, $(($(date +%s) - t0)) s"
  exit "$rc"
}

expected_wheel_name() {
  echo "opencv_python_headless-5.0.0.${OPENCV_PYTHON_TAG}+${LOCAL_LABEL}-cp37-abi3-linux_aarch64.whl"
}

cmd_full() {
  local default_jobs row
  if row=$(row_for_mem "$(mem_available_mib)"); then
    default_jobs=${row%% *}
  else
    default_jobs=1 # below the table's 2048 MiB floor: smallest job count (precheck refuses anyway)
  fi
  parse_jobs "$default_jobs" "$@"
  load_pins
  guard
  step_begin full
  [ "$CHAIN" = 1 ] || precheck || exit 4
  assert_sources
  local t0 rc=0 whl
  t0=$(date +%s)
  log "setup.py bdist_wheel --py-limited-api=cp37 -v (MAKEFLAGS=-j$JOBS)"
  (cd "$SRC" && in_build_env "$JOBS" "$BV/bin/python" setup.py bdist_wheel \
    --py-limited-api=cp37 -v) || rc=$?
  whl="$SRC/dist/$(expected_wheel_name)"
  if [ "$rc" = 0 ] && [ ! -f "$whl" ]; then
    log "build returned 0 but $(expected_wheel_name) is missing in $SRC/dist"
    rc=6
  fi
  log "full finished: rc=$rc, $(($(date +%s) - t0)) s"
  exit "$rc"
}

# ---------------------------------------------------------------- record

cmd_record() {
  load_pins
  guard
  mkdir -p "$LOGS"
  CMD=record
  local whl out=$WH/ocv tmp=$BUILD/tmp/record meta pkg
  whl="$SRC/dist/$(expected_wheel_name)"
  [ -f "$whl" ] || die "wheel not found: $whl"
  # build info of the built wheel: unpack, import via PYTHONPATH with NumPy 2, never install.
  # The import must succeed before anything is written to $out (a wheel compiled against the
  # system NumPy 1.x headers fails here with "numpy.core.multiarray failed to import").
  mkdir -p "$tmp"
  find "$tmp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  "$BV/bin/python" -m zipfile -e "$whl" "$tmp"
  env -i HOME="$HOME" PATH=/usr/bin:/bin PYTHONPATH="$tmp" "$BV/bin/python" -c \
    'import numpy, cv2; assert numpy.__version__.startswith("2."); print(cv2.getBuildInformation())' \
    >"$tmp.buildinfo" || die "the built wheel does not import with NumPy 2 ($BV)"
  install -d -m 0755 "$out"
  find "$out" -mindepth 1 -maxdepth 1 -type f -delete
  cp -f -- "$whl" "$out/"
  (cd "$out" && sha256sum -- ./*.whl | sed 's# \./# #' >SHA256SUMS)
  mv -f -- "$tmp.buildinfo" "$out/buildinfo.txt"
  meta=$(find "$tmp" -maxdepth 2 -name METADATA | head -n1)
  pkg=$(sed -n 's/^Name: //p;s/^Version: /version=/p' "$meta" | tr '\n' ' ')
  log "wheel metadata: $pkg"
  grep -q "^Version: 5.0.0.${OPENCV_PYTHON_TAG}+${LOCAL_LABEL}\$" "$meta" || die "wheel version is not 5.0.0.$OPENCV_PYTHON_TAG+$LOCAL_LABEL"
  write_build_env "$out/build-env.txt"
  write_build_summary "$out/build-summary.json"
  chmod 0644 "$out"/*.whl "$out"/SHA256SUMS "$out"/buildinfo.txt "$out"/build-env.txt \
    "$out"/build-summary.json
  ev record_ok wheel="$(basename "$whl")" sha256="$(cut -d' ' -f1 "$out/SHA256SUMS" | head -n1)"
  log "recorded in $out: $(basename "$whl"), SHA256SUMS, buildinfo.txt, build-env.txt, build-summary.json"
}

write_build_env() { # file; the home directory is written as '~'
  local f=$1 p pkgs="cuda-toolkit-12-6 libnpp-dev-12-6 libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libopenblas-dev liblapack-dev liblapacke-dev libv4l-dev libpng-dev zlib1g-dev python3.10-dev ccache"
  {
    echo "# build-env.txt - environment of this wheel build (generated by build.sh record)"
    echo "## L4T"
    head -n1 /etc/nv_tegra_release 2>/dev/null || echo "(no /etc/nv_tegra_release)"
    echo "## toolchain"
    "$CUDA_HOME/bin/nvcc" --version | tail -n 2
    gcc --version | head -n1
    cmake --version | head -n1
    echo "## apt packages (dpkg-query)"
    for p in $pkgs; do
      dpkg-query -W -f='${Package} ${Version}\n' "$p" 2>/dev/null || echo "$p not installed"
    done
    echo "## pins (pins.env)"
    grep -vE '^\s*(#|$)' "$BH/pins.env"
    echo "## build.sh commit"
    git -C "$BH" rev-parse --verify -q HEAD || echo "(no commit)"
    git -C "$BH" diff --quiet HEAD 2>/dev/null || echo "(working tree has uncommitted changes)"
    echo "## CMake args (CMAKE_ARGS)"
    cmake_flags
    echo "## environment of setup.py (MAKEFLAGS shows the last resume's J)"
    build_env "${LAST_JOBS:-$(grep -o '"jobs":[0-9]*' "$LOGS/events.jsonl" 2>/dev/null | tail -n1 | cut -d: -f2)}" |
      grep -v '^CMAKE_ARGS='
    echo "## command"
    echo "python setup.py bdist_wheel --py-limited-api=cp37 -v"
  } | sed "s#$HOME#~#g" >"$f"
}

write_build_summary() { # file
  "$BV/bin/python" - "$LOGS" "$1" "$LOCAL_LABEL" <<'PY'
import csv
import glob
import json
import os
import sys

logs, out, label = sys.argv[1:4]
events = []
path = os.path.join(logs, "events.jsonl")
if os.path.exists(path):
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line:
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
attempts = [e for e in events if e.get("event") == "attempt_end"]
stops = [e for e in events if e.get("event") in ("watchdog_result", "stop") and
         str(e.get("detail", "")).split(" ")[0] not in ("done", "running")]
peaks = {}
for p in sorted(glob.glob(os.path.join(logs, "*_mem.csv"))):
    step = os.path.basename(p)[: -len("_mem.csv")]
    hwm = rss = 0
    with open(p, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            try:
                hwm = max(hwm, int(row["max_hwm_mib"]))
                rss = max(rss, int(row["max_rss_mib"]))
            except (KeyError, ValueError):
                pass
    peaks[step] = {"peak_hwm_mib": hwm, "peak_rss_mib": rss}
wall = {}
for a in attempts:
    if a.get("step") == "full":
        wall[str(a.get("jobs"))] = wall.get(str(a.get("jobs")), 0) + int(a.get("wall_s", 0))
summary = {
    "local_label": label,
    "attempts": [{k: a.get(k) for k in ("ts", "step", "jobs", "wall_s", "status")} for a in attempts],
    "full_wall_s_by_jobs": wall,
    "peak_rss_by_step": peaks,
    "stop_events": [{k: s.get(k) for k in ("ts", "event", "detail")} for s in stops],
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
PY
}

# ---------------------------------------------------------------- night chain

NIGHT_STATUS=""
NIGHT_WD_PID=""
NIGHT_FOREGROUND=0

# Stop the build unit and wait (bounded) until it is gone. Idempotent; always safe to call.
stop_build_unit() {
  local state=unknown
  systemctl --user stop --no-block "$UNIT.service" >/dev/null 2>&1 || true
  for _ in $(seq 1 120); do
    state=$(systemctl --user show -p ActiveState --value "$UNIT.service" 2>/dev/null || echo unknown)
    case "$state" in inactive | failed) return 0 ;; esac
    sleep 1
  done
  log "WARNING: $UNIT.service is still '$state' after the stop request"
  return 1
}

night_finish() { # status; the status file is terminal after this, the build unit is gone
  trap - TERM INT EXIT
  [ -z "$NIGHT_WD_PID" ] || kill "$NIGHT_WD_PID" 2>/dev/null || true
  stop_build_unit || true
  printf '%s\n' "$1" >"$NIGHT_STATUS"
  ev night_end status="$1"
  log "night finished: $1"
  case "$1" in ok) exit 0 ;; stopped:*) exit 2 ;; *) exit 1 ;; esac
}

# any exit that did not go through night_finish (die, unexpected failure) is still terminal
night_on_exit() {
  local rc=$?
  if grep -q '^running:' "$NIGHT_STATUS" 2>/dev/null; then
    trap - TERM INT EXIT
    [ -z "$NIGHT_WD_PID" ] || kill "$NIGHT_WD_PID" 2>/dev/null || true
    stop_build_unit || true
    printf 'failed:aborted\n' >"$NIGHT_STATUS"
    ev night_end status=failed:aborted
    log "night aborted unexpectedly (exit $rc)"
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}

night_args_fail() { log "ERROR: $*"; night_finish failed:arguments; }

# fetch / record run as their own process so that set -e is fully active inside them
night_child() {
  env BUILD="$BUILD" BV="$BV" WH="$WH" CUDA_HOME="$CUDA_HOME" "$STEP_BIN" "$1"
}

night_progress() { printf 'running:%s\n' "$1" >"$NIGHT_STATUS"; log "== $1"; }

night_on_term() {
  log "termination requested (counts as S-d)"
  night_finish stopped:S-d
}

# name of the service unit this process runs in (empty if none)
own_unit() { awk -F/ '$NF ~ /\.service$/ {u = $NF} END {print u}' /proc/self/cgroup; }

# window end / stop file between steps; returns 1 (and sets STEP_STATUS) when the window is over
window_open() {
  if [ -e "$BUILD/STOP" ]; then STEP_STATUS=stopped:S-d; ev stop condition=S-d detail="stop file"; return 1; fi
  if [ -n "$WINDOW_END_EPOCH" ] && [ "$(date +%s)" -ge "$WINDOW_END_EPOCH" ]; then
    STEP_STATUS=stopped:S-d; ev stop condition=S-d detail="window end"; return 1
  fi
}

# Run one unit attempt loop for a step with S-a recovery (resume at J-1) and one retry after a
# first compile error (S-f stops the second identical one). Sets STEP_STATUS; rc 0 only on success.
# The build unit never outlives its guard: it is bound to the night unit (BindsTo) and stopped
# explicitly whenever the watchdog returns, whatever the reason.
run_step() { # step jobs maxmem maxswap
  local step=$1 jobs=$2 maxmem=$3 maxswap=$4 attempt=0 offset t0 ws rc own
  local -a extra props wdopt
  local errors=$LOGS/$step.errors.sig
  while :; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 6 ]; then STEP_STATUS="failed:$step"; return 1; fi
    window_open || return 1
    rm -f "$LOGS/$step.rc" "$LOGS/$step.watchdog"
    offset=$(stat -c %s "$LOGS/$step.log" 2>/dev/null || echo 0)
    t0=$(date +%s)
    props=()
    if [ "$NIGHT_FOREGROUND" = 0 ]; then
      own=$(own_unit)
      if [ -n "$own" ]; then
        props+=(-p "BindsTo=$own" -p "After=$own")
      else
        log "WARNING: own unit not found in /proc/self/cgroup; $UNIT is not bound to it"
      fi
    fi
    if [ "${OCV_TEST:-}" = 1 ] && [ "$step" = full ] && [ -n "${OCV_TEST_FULL_PROPS:-}" ]; then
      read -ra extra <<<"$OCV_TEST_FULL_PROPS" # test hook: unit properties for the full step
      props+=("${extra[@]}")
    fi
    ev attempt_start step="$step" jobs="$jobs" attempt="$attempt" maxmem="$maxmem"
    log "$step attempt $attempt: J=$jobs MemoryMax=$maxmem MemorySwapMax=$maxswap"
    if ! systemd-run --user --unit="$UNIT" --collect --quiet \
      -p "MemoryMax=$maxmem" -p "MemorySwapMax=$maxswap" -p Nice=19 -p IOSchedulingClass=idle \
      "${props[@]}" \
      "--setenv=BUILD=$BUILD" "--setenv=BV=$BV" "--setenv=WH=$WH" "--setenv=CUDA_HOME=$CUDA_HOME" \
      "$STEP_BIN" "$step" --jobs "$jobs" --chain; then
      STEP_STATUS="failed:$step"
      return 1
    fi
    wdopt=(--unit "$UNIT" --csv "$LOGS/${step}_mem.csv" --status "$LOGS/$step.watchdog"
      --events "$LOGS/events.jsonl" --build-log "$LOGS/$step.log" --log-offset "$offset"
      --errors-file "$errors" --rc-file "$LOGS/$step.rc" --attempt-start "$t0"
      --stop-file "$BUILD/STOP" --disk-path "$BUILD")
    [ -z "$WINDOW_END_EPOCH" ] || wdopt+=(--window-end "$WINDOW_END_EPOCH")
    if [ "${OCV_TEST:-}" = 1 ] && [ -n "${OCV_WD_ARGS:-}" ]; then
      read -ra extra <<<"$OCV_WD_ARGS" # test hook: extra watchdog options (lowered thresholds)
      wdopt+=("${extra[@]}")
    fi
    "$BH/watchdog.sh" "${wdopt[@]}" >>"$LOGS/watchdog.log" 2>&1 &
    NIGHT_WD_PID=$!
    wait "$NIGHT_WD_PID" || true
    NIGHT_WD_PID=""
    stop_build_unit || true # the watchdog is gone: the build must not outlive it
    ws=$(cat "$LOGS/$step.watchdog" 2>/dev/null || echo "failed:unknown")
    rc=$(cat "$LOGS/$step.rc" 2>/dev/null || echo absent)
    ev attempt_end step="$step" jobs="$jobs" wall_s=$(($(date +%s) - t0)) status="$ws" rc="$rc"
    log "$step attempt $attempt ended: watchdog=$ws rc=$rc after $(($(date +%s) - t0)) s"
    case "$ws" in
      "done") STEP_STATUS="done"; return 0 ;;
      stopped:S-a)
        if [ "$jobs" -le 1 ]; then STEP_STATUS=stopped:S-a; return 1; fi
        jobs=$((jobs - 1))
        log "S-a: resuming $step at J=$jobs"
        ;;
      failed:error)
        if [ "$rc" = 3 ]; then STEP_STATUS="failed:$step-w3"; return 1; fi
        log "first occurrence of a compile error: one resume, a second identical error stops (S-f)"
        ;;
      stopped:manual) STEP_STATUS=stopped:S-d; return 1 ;;
      stopped:*) STEP_STATUS=$ws; return 1 ;;
      *)
        # includes a watchdog that died without a verdict ("running")
        if [ "$rc" = 3 ]; then STEP_STATUS="failed:$step-w3"; else STEP_STATUS="failed:$step"; fi
        return 1
        ;;
    esac
  done
}

cmd_night() {
  local foreground=0 max_jobs="" repilot=0 window="" no_window=0
  check_build_path # nothing safe to write if BUILD is unusable
  NIGHT_STATUS=$LOGS/night.status
  mkdir -p "$LOGS"
  printf 'running:start\n' >"$NIGHT_STATUS" # first thing: an old "ok" must never survive a new start
  trap night_on_term TERM INT
  trap night_on_exit EXIT
  while [ $# -gt 0 ]; do
    case "$1" in
      --foreground) foreground=1; shift ;;
      --repilot) repilot=1; shift ;;
      --no-window) no_window=1; shift ;;
      --max-jobs | --window-end)
        [ $# -ge 2 ] || night_args_fail "$1 needs a value"
        if [ "$1" = --max-jobs ]; then max_jobs=$2; else window=$2; fi
        shift 2
        ;;
      *) night_args_fail "night: unknown option $1" ;;
    esac
  done
  NIGHT_FOREGROUND=$foreground
  [ -z "$max_jobs" ] || [[ $max_jobs =~ ^[1-9][0-9]*$ ]] || night_args_fail "--max-jobs must be a positive integer"
  if [ -z "$window" ] && [ "$no_window" = 0 ]; then
    night_args_fail "--window-end is required (or --no-window for an unbounded run)"
  fi
  if [ -n "$window" ] && [ "$no_window" = 1 ]; then night_args_fail "--window-end and --no-window exclude each other"; fi
  WINDOW_END_EPOCH=""
  if [ -n "$window" ]; then
    WINDOW_END_EPOCH=$(date -d "$window" +%s) || night_args_fail "cannot parse --window-end '$window'"
    [ "$WINDOW_END_EPOCH" -gt "$(date +%s)" ] || night_args_fail "--window-end '$window' is in the past"
  fi
  if [ "$foreground" = 0 ] && [ -z "${INVOCATION_ID:-}" ]; then
    night_args_fail "night must run as a systemd user unit so it survives closing the terminal; use the start command in README.md (or --foreground for tests)"
  fi
  load_pins
  guard
  exec >>"$LOGS/night.log" 2>&1
  log "==== night chain start (fingerprint $(fingerprint), window end ${WINDOW_END_EPOCH:-none})"
  set +e # every step below is checked explicitly; an unexpected failure must not skip night_finish

  local avail row j0 maxmem maxswap pj pmem pswap peak jderived jfull
  night_progress precheck
  ev night_start window_end="${WINDOW_END_EPOCH:-none}"
  precheck || night_finish failed:precheck
  avail=$(mem_available_mib)
  row=$(row_for_mem "$avail") || night_finish failed:precheck
  read -r j0 maxmem maxswap <<<"$row"
  ev chain_start mem_available_mib="$avail" row_jobs="$j0" maxmem="$maxmem"

  night_progress fetch
  night_child fetch || night_finish failed:fetch

  # ---- pilot (row "-j2", or -j1 when only the 1-job row fits), capped by the free-memory row
  pj=2
  [ "$j0" -ge 2 ] || pj=1
  read -r pmem pswap <<<"$(row_for_j "$pj")"
  if [ "$repilot" = 0 ] && grep -q '"ok":true' "$LOGS/pilot.json" 2>/dev/null &&
    grep -q "\"fingerprint\":\"$(fingerprint)\"" "$LOGS/pilot.json"; then
    log "pilot already done for this fingerprint ($LOGS/pilot.json); reusing its peak (--repilot to redo)"
    ev pilot_reused
  else
    night_progress pilot
    rm -f "$LOGS/pilot_mem.csv"
    if ! run_step pilot "$pj" "$pmem" "$pswap"; then
      write_pilot_json
      night_finish "$STEP_STATUS"
    fi
    write_pilot_json
  fi

  # ---- J from the measured pilot peak, capped by the RAM table row
  night_progress derive-jobs
  peak=$(grep -o '"peak_hwm_mib":[0-9]*' "$LOGS/pilot.json" | cut -d: -f2 || true)
  peak=${peak:-0}
  if [ "$peak" -gt 0 ]; then
    printf '%s\n' "$peak" >"$LOGS/peak_hwm_mib"
  elif [ -s "$LOGS/peak_hwm_mib" ]; then
    peak=$(cat "$LOGS/peak_hwm_mib")
    log "pilot sampled no compiler process (cache hits?); using the last measured peak $peak MiB"
  fi
  jfull=$j0
  if [ "$peak" -gt 0 ]; then
    jderived=$(((${maxmem%M} - 256) / peak))
    [ "$jderived" -ge 1 ] || { log "peak $peak MiB does not fit MemoryMax $maxmem even at J=1"; night_finish failed:derive-jobs; }
    [ "$jderived" -ge "$jfull" ] || jfull=$jderived
  else
    log "no measured peak available; using the table row J=$jfull"
  fi
  if [ -n "$max_jobs" ] && [ "$jfull" -gt "$max_jobs" ]; then jfull=$max_jobs; fi
  ev jobs_derived peak_hwm_mib="$peak" row_jobs="$j0" jobs="$jfull" maxmem="$maxmem"
  log "J for the full build: $jfull (peak $peak MiB, MemoryMax $maxmem, table row J=$j0)"

  # ---- full build
  night_progress full
  run_step full "$jfull" "$maxmem" "$maxswap" || night_finish "$STEP_STATUS"

  # ---- record
  night_progress record
  night_child record || night_finish failed:record
  night_finish ok
}

# ---------------------------------------------------------------- main

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local sub=${1:-}
  [ $# -eq 0 ] || shift
  case "$sub" in
    --dry-run | dry-run) CMD=dry-run; cmd_dry_run "$@" ;;
    fetch) CMD=fetch; cmd_fetch "$@" ;;
    pilot) cmd_pilot "$@" ;;
    full) cmd_full "$@" ;;
    record) CMD=record; cmd_record "$@" ;;
    night) CMD=night; cmd_night "$@" ;;
    -h | --help | help | "") usage ;;
    *) usage >&2; exit 64 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
