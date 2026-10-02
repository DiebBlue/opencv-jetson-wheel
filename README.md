# opencv-jetson-wheel

Reproducible native build of **OpenCV 5.0.0 as a headless Python wheel with CUDA and GStreamer**
for the NVIDIA Jetson Orin (JetPack 6 / L4T R36, aarch64, Python 3.10).

The PyPI `opencv-python-headless` wheels are built without CUDA and without GStreamer. This
repository contains the pinned inputs, the build driver and the safeguards to build such a wheel
on the board itself, unattended, without exhausting its 8 GB of shared RAM.

**Status:** this is a build recipe. No wheel is published (see [License](#license)). The numbers
below were measured on a Jetson Orin Nano 8 GB, L4T R36.5.2, CUDA 12.6, GCC 11.4, Python 3.10.

## What is built

- **Identity:** distribution `opencv-python-headless`, version `5.0.0.93+cu126.l4t36.1` (the PyPI
  public version plus a PEP 440 local label `cu<CUDA>.l4t<L4T major>.<build counter>`), file
  `opencv_python_headless-5.0.0.93+cu126.l4t36.1-cp37-abi3-linux_aarch64.whl` (stable ABI,
  `cp37-abi3`). It is a drop-in for the PyPI headless wheel: same import name `cv2`, same public
  version, and it is built against the **NumPy 2** headers (NumPy 2.0.2) like the PyPI wheel.
- **Source:** opencv-python tag `93` (= PyPI 5.0.0.93) with its submodules opencv `5.0.0` and
  opencv_contrib `5.0.0`, pinned by commit SHA in `pins.env`. Two small patches (see `patches/`)
  are applied; nothing else is changed in the sources.
- **Modules:** the PyPI headless set (`calib core dnn features flann geometry highgui imgcodecs
  imgproc objdetect photo ptcloud python3 stereo stitching video videoio`) plus six CUDA modules
  from opencv_contrib: `cudev cudaarithm cudafilters cudaimgproc cudawarping cudafeatures2d`.
- **Principle:** the CPU path stays equivalent to the PyPI wheel (same baseline, same codecs,
  pthreads parallel framework). `cmake-flags.txt` documents every flag. In short:

| Flag group | Setting | Reason |
|---|---|---|
| CUDA | on, compute capability 8.7 (Orin), SASS only (no PTX), no fast math, cuBLAS and cuFFT on | the point of the build; one GPU generation keeps the wheel small |
| cuDNN / DNN-CUDA, NVCUVID, NVENC | off | `cv2.dnn` is not targeted; the NVCUVID and NVENC libraries are absent on the board |
| GStreamer | on | the other point of the build |
| FFmpeg, V4L, LAPACK | on, linked dynamically from the board | system FFmpeg 4.4, OpenBLAS, libv4l |
| OpenCL | off | no OpenCL driver on Orin; `cv2.UMat` falls back to the CPU in both builds |
| TBB, OpenMP, Eigen, 1394, gPhoto2, OpenEXR, VTK, VA, AVIF | off | off in the PyPI build (it uses pthreads) or not used by it |
| KleidiCV, Carotene HAL | on | as in the PyPI build |
| JPEG, TIFF, WEBP, OpenJPEG | built from 3rdparty | as PyPI; decoding results must match |
| CPU baseline | `NEON,FP16`, dispatch `NEON_FP16,NEON_DOTPROD` | reproduces what PyPI's `DETECT` yields on AArch64; the Cortex-A78AE has no BF16, so PyPI's BF16 path is never selected here |
| Install RPATH | none (`CMAKE_SKIP_INSTALL_RPATH`) | CUDA, NPP, cuBLAS, GStreamer and FFmpeg resolve through the system loader cache |

Runtime requirements on the target: the shared libraries the extension links against must be
installed, i.e. the JetPack CUDA runtime libraries (NPP 12, cuBLAS 12, cuFFT 11), GStreamer 1.20,
FFmpeg 4.4 (`libavcodec.so.58` and friends), OpenBLAS and libpng. Only the CUDA runtime
(`cudart_static`) is linked statically.

## Files

| File | Content |
|---|---|
| `build.sh` | `--dry-run`, `fetch`, `pilot`, `full`, `record`, `night` |
| `watchdog.sh` | samples the build unit every 5 s and enforces the stop conditions S-a..S-f |
| `pins.env` | opencv-python tag, three commit SHAs, `LOCAL_LABEL`, CUDA architecture and module list |
| `cmake-flags.txt` | the CMake flags (placeholders are expanded by `build.sh`) |
| `build-requirements.txt` | hash-pinned build requirements for the build venv (`--require-hashes --no-deps`) |
| `patches/local-version.patch` | `find_version.py` appends `+$OCV_LOCAL_LABEL` on an exact tag |
| `patches/opencv-numpy-include-first.patch` | puts the NumPy headers of the build venv first on the include path (see [Known pitfalls](#known-pitfalls)) |
| `reference/pypi-5.0.0.93-buildinfo.txt` | `cv2.getBuildInformation()` of the PyPI 5.0.0.93 wheel, the comparison base of the pilot's configure check |
| `local.env.example` | template for the optional, gitignored host guards (see [Host guards](#host-guards-localenv)) |
| `tests/` | stub tests for the night chain and the watchdog |

Variables (all overridable from the environment, none hard-coded elsewhere):
`BUILD=~/build/ocv5` (sources, build tree, ccache, downloads, logs; outside every git work tree),
`BV=~/venvs/ocv-build` (build requirements only), `WH=~/wheelhouse` (the result goes to
`$WH/ocv`), `CUDA_HOME=/usr/local/cuda`. `build.sh` refuses a `$BUILD` that is empty, `/`, outside
`$HOME` or inside a git work tree.

## Prerequisites

Everything below is installed beforehand; the scripts need no `sudo`.

- JetPack 6 / L4T R36 with CUDA 12.6 (`nvcc`), GCC 11.4, cmake >= 3.13 (board: 3.22.1), git,
  `python3-venv`, ccache, and a systemd user manager (`systemd-run --user`).
- Development packages (`build.sh record` writes their installed versions to `build-env.txt`):
  `cuda-toolkit-12-6 libnpp-dev-12-6 libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
  libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libopenblas-dev liblapack-dev
  liblapacke-dev libv4l-dev libpng-dev zlib1g-dev python3.10-dev ccache`.
- Network access to GitHub (clone, configure-time archives such as KleidiCV) and PyPI (build
  requirements).
- Free disk space on the filesystem of `$BUILD`: the finished build tree measured about 3.5 GB;
  the guard stops below 50 GB free to leave a wide margin.
- Free RAM decides the job count (see [Memory sizing](#memory-sizing)). Close memory-hungry
  desktop applications before a build; 5 GiB or more of `MemAvailable` allows the fastest setting.

## Quick start

```bash
./build.sh --dry-run     # prints pins, environment and the full CMake arguments; no network, writes nothing
./build.sh fetch         # clones the sources at the pinned SHAs, applies the patches, creates the build venv
```

Then run the unattended chain below (recommended) or the steps in [Manual use](#manual-use). The
wheel ends up in `$WH/ocv/`; install it into the target venv with `pip install --no-deps <wheel>`
(it replaces the PyPI headless wheel of the same public version).

## Unattended night chain

One command, in any terminal. It returns immediately and the chain runs as a transient systemd
*user* unit, so closing the terminal does not stop it:

```bash
systemd-run --user --unit=ocv-night --collect -p Nice=19 -p IOSchedulingClass=idle \
  -p RuntimeMaxSec=11h -p TimeoutStopSec=300 \
  /path/to/opencv-jetson-wheel/build.sh night --window-end "tomorrow 07:00"
```

The chain is `fetch` -> `pilot` (only the CUDA module targets, `-j2`, 2304 MiB memory limit) ->
derive the job count J from the measured pilot peak -> `full` -> `record`, with every stop
condition active.

A wall-clock bound is mandatory: `night` refuses to start (`failed:arguments`) without
`--window-end "<date -d string>"` (must lie in the future; after midnight write the date, e.g.
`"2026-10-02 07:00"`) or an explicit `--no-window`. At the window end the watchdog stops the build
(S-d). `RuntimeMaxSec=11h` is a second, independent bound: systemd sends SIGTERM to `night`, which
stops the build unit and ends with `stopped:S-d`; `TimeoutStopSec=300` gives it time to do so.

**Lingering.** The unit lives in your systemd user manager. While you stay logged in it keeps
running; if you log out of *all* sessions (or reboot) the user manager stops and the build stops
with it. `sudo loginctl enable-linger $USER` keeps the user manager alive without a login. Nothing
in this repository runs it for you. Also keep the machine from suspending.

Look at the result at any time:

```bash
cat $BUILD/logs/night.status          # ok | stopped:S-x | failed:<step>
tail -n 40 $BUILD/logs/night.log
systemctl --user status ocv-night ocv-build
```

Stop it early (counts as S-d; the build unit is stopped, progress is kept):
`systemctl --user stop ocv-night`, or `touch $BUILD/STOP` (this also blocks a later start until the
file is removed).

**Rerun after any stop:** run the same start command again. `fetch` is idempotent, the pilot is
reused when `pins.env`, `cmake-flags.txt`, the patches and the requirements are unchanged and the
last pilot succeeded (`--repilot` forces it), and `full` resumes in the build tree and ccache.
Options of `night`: `--window-end "<date -d string>"` or `--no-window` (one is required),
`--max-jobs N`, `--repilot`, `--foreground` (tests only).

The build unit never outlives its guard: it is started with `BindsTo=`/`After=` the night unit
(stopping, killing or losing `ocv-night` stops `ocv-build`), `night` stops it whenever the watchdog
returns and again on every exit path, and the watchdog treats a failing `systemctl` as "state
unknown", never as "the build ended".

### Stop conditions

The build runs as `systemd-run --user --unit=ocv-build -p MemoryMax=.. -p MemorySwapMax=.. -p Nice=19
-p IOSchedulingClass=idle build.sh full --jobs J`, so the OOM killer stays inside the unit. A stop is
`systemctl --user stop ocv-build`; the build tree and ccache keep the progress.

| | Condition (5 s samples) | Reaction |
|---|---|---|
| S-a | OOM kill in the unit (cgroup `memory.events`, user-manager/kernel journal, compiler "Killed" in the log) | `night` resumes at J-1; an OOM kill at J=1 stops the chain |
| S-b | system `MemAvailable` < 512 MiB for 6 samples (30 s) | stop (protects the rest of the system) |
| S-c | zram swap used > 3 GiB (zram is RAM) | stop |
| S-d | window end (`--window-end`), `RuntimeMaxSec`, `$BUILD/STOP` exists, or a manual stop of `ocv-night` | stop |
| S-e | free disk on the filesystem of `$BUILD` < 50 GB | stop |
| S-f | the same first compile error in two attempts (`logs/<step>.errors.sig`) | the first error gets one resume, the second identical one stops; delete the `.errors.sig` file after fixing the cause |

`watchdog.sh` also runs standalone against any user unit (`watchdog.sh --help`). Its CSV
(`epoch,time,mem_available_mib,zram_used_mib,disk_free_gb,max_rss_mib,max_hwm_mib,max_rss_proc`)
and `events.jsonl` feed `build-summary.json`.

### `night.status`

`running:start` is written first thing, so an old result never survives a new start. It is
`running:<step>` while the chain works (if the unit is gone and it still says `running:*`, `night`
was killed with SIGKILL, or the user manager was stopped by logout or reboot; `ocv-build` is
stopped by `BindsTo` in that case), then exactly one of:

| Status | Meaning |
|---|---|
| `ok` | wheel, `SHA256SUMS`, `buildinfo.txt`, `build-env.txt`, `build-summary.json` are in `$WH/ocv` |
| `stopped:S-a` | OOM kill even at J=1: do not retry blindly; free more RAM first |
| `stopped:S-b` / `S-c` / `S-e` | system RAM low / zram swap high / disk low; rerun later |
| `stopped:S-d` | window end, `STOP` file or manual stop; rerun in the next window |
| `stopped:S-f` | the same compile error twice; read `logs/full.log` (or `pilot.log`), fix the cause |
| `failed:arguments` | missing or invalid option (no `--window-end`/`--no-window`, window in the past, bad `--max-jobs`, not started as a systemd unit); the reason is in `night.log` or on stderr |
| `failed:aborted` | `night` died unexpectedly (a guard such as the `BUILD`/`BV` checks refused to continue); the build unit was stopped |
| `failed:precheck` | a guard unit from `local.env` is active or a guarded process runs, `MemAvailable` < 2048 MiB, or < 50 GB disk |
| `failed:fetch` | clone, SHA assertion, patch, venv or the `setup.py` check failed (a SHA mismatch aborts) |
| `failed:pilot-w3` | the pilot's configure summary differs from the PyPI reference (`logs/w3.txt`); fix `cmake-flags.txt` first |
| `failed:pilot` / `failed:full` / `failed:record` / `failed:derive-jobs` | failure without a classified cause; see the step log |

## Memory sizing

`MemAvailable` at the start of the chain selects a row; the pilot runs at `-j2` in the 2304M row
(`-j1` if only the last row fits):

| MemAvailable at start | J (cap) | MemoryMax | MemorySwapMax |
|---|---|---|---|
| >= 5120 MiB | 4 | 4096M | 1536M |
| 2816-5119 MiB | 2 | 2304M | 1536M |
| 2048-2815 MiB | 1 | 1536M | 1024M |
| < 2048 MiB | does not start | - | - |

`night` then sets `J = min(table J, floor((MemoryMax - 256 MiB) / peak))`, where `peak` is the
largest `VmHWM` (peak resident set) of any `cc1plus|cicc|ptxas|nvcc|ld` process in
`logs/pilot_mem.csv`; it is kept in `logs/peak_hwm_mib` for later reruns. `MemoryMax` stays that of
the table row. The pilot compiles only the CUDA modules, so peaks of other translation units are
not measured; S-a covers that.

## Manual use

```bash
./build.sh --dry-run
./build.sh fetch
systemd-run --user --unit=ocv-build --collect -p MemoryMax=4096M -p MemorySwapMax=1536M \
  -p Nice=19 -p IOSchedulingClass=idle /path/to/opencv-jetson-wheel/build.sh pilot --jobs 2
./watchdog.sh --unit ocv-build --csv $BUILD/logs/pilot_mem.csv --status $BUILD/logs/pilot.watchdog
./build.sh record        # after a successful `full`
```

`pilot` configures `opencv/` into `$BUILD/pilot` with the arguments `setup.py` (tag 93) would pass
plus `cmake-flags.txt`, then **compares the configure summary with the PyPI reference before it
compiles anything** (`logs/w3.txt`; "W3" in file and status names). Must-equal lines: `Baseline`,
`Built as dynamic libs?`, `Parallel framework`, `Custom HAL`, `JPEG`, `TIFF`, `WEBP`,
`JPEG 2000`, `Limited API`, `Algorithm Hint`, NumPy headers 2.0.2. Intended differences: CUDA
12.6, GPU arch 87, no PTX, cuDNN NO, GStreamer 1.20.3, FFmpeg, LAPACK from OpenBLAS, GCC 11.4,
system libpng, AVIF NO, OpenCL NO, dispatch `NEON_DOTPROD NEON_FP16` (no `NEON_BF16`), modules =
reference plus the six CUDA modules. Every other differing line goes to `logs/w3_diff.txt` as
information. A mismatch exits with code 3. Then the pilot builds only `opencv_cudev
opencv_cudaarithm opencv_cudawarping opencv_cudaimgproc opencv_cudafilters opencv_cudafeatures2d`
and writes `logs/pilot.json` (wall time, targets built, peak RSS).

`full` runs `python setup.py bdist_wheel --py-limited-api=cp37 -v` in `$BUILD/src` with
`ENABLE_HEADLESS=1 ENABLE_CONTRIB=0 CI_BUILD=1 OPENCV_PYTHON_SKIP_GIT_COMMANDS=1
OCV_LOCAL_LABEL=<label> CCACHE_DIR/BASEDIR/MAXSIZE MAKEFLAGS=-jJ CMAKE_ARGS=<flags>` in a clean
`env -i` environment (`LC_ALL=C`). There is no `auditwheel repair`. The pilot's objects are not
reused by the full build (different build directory); ccache may or may not hit.

## Outputs

`$BUILD/logs/`: `night.log`, `night.status`, `events.jsonl`, `watchdog.log`, per step `<step>.log`,
`<step>.rc`, `<step>.watchdog`, `<step>_mem.csv`, `<step>.errors.sig`, `pilot.json`, `w3.txt`,
`w3_diff.txt`, `peak_hwm_mib`.

`$WH/ocv/` (mode 0755): the wheel, `SHA256SUMS`, `buildinfo.txt` (`cv2.getBuildInformation()` of
the built wheel, unpacked and imported, never installed), `build-env.txt` (L4T line,
`nvcc`/`gcc`/`cmake` versions, `dpkg-query` versions of the build dependencies, pins, CMake args,
environment; the home directory is written as `~`), and `build-summary.json` (wall time per job
count, peak RSS, stop events).

## Reference numbers

Measured on a Jetson Orin Nano 8 GB (7607 MiB visible RAM, shared with a desktop session), L4T
R36.5.2, CUDA 12.6.68, GCC 11.4.0, cmake 3.22.1. Sources: the `events.jsonl`,
`pilot_mem.csv`/`full_mem.csv` and `build-summary.json` written by the chain.

| Quantity | Value |
|---|---|
| `MemAvailable` at the start of the chain | 6301-6586 MiB (row J=4, MemoryMax 4096M) |
| Pilot (six CUDA module targets), `-j2`, 2304M | 3013 s (about 50 min) |
| Peak resident set of one compiler process in the pilot (`VmHWM`) | 1135 MiB (about 1.1 GiB) |
| J derived from it in the 4096M row | floor((4096 - 256) / 1135) = 3 |
| Full build, `-j3`, 4096M | 3356 s (about 56 min) |
| Peak resident set of one compiler process in the full build (`cc1plus`) | 1605 MiB |
| Lowest system `MemAvailable` / highest zram use over the sampled full-build runs | 3508 MiB / 202 MiB |
| Rerun of `full` on a warm build tree | 294 s (a later rerun with nothing to rebuild: 26 s) |
| Wheel size | 36,772,831 bytes (about 36.8 MB); `cv2.abi3.so` about 188 MB unpacked |
| Build tree after the full build (`$BUILD`) | about 3.5 GB (sources 2.7 GB, pilot tree 549 MB) |

Wall-clock times depend on the load of the board while it builds.

## Known pitfalls

- **NumPy header shadowing.** Debian/Ubuntu's `python3-numpy` installs NumPy 1.x headers in
  `/usr/include/python3.X/numpy`, and OpenCV's bindings put the Python include directory *before*
  the NumPy include directory. The extension then compiles against NumPy 1 and fails at import
  under NumPy 2 with `numpy.core.multiarray failed to import`.
  `patches/opencv-numpy-include-first.patch` reorders the include directories, and
  `build.sh record` imports the built wheel with NumPy 2 before it writes anything to the
  wheelhouse.
- **Install RPATH.** OpenCV forces `CMAKE_INSTALL_RPATH_USE_LINK_PATH` on
  (`cmake/OpenCVInstallLayout.cmake`) and `link_directories()` puts the CUDA library directory on
  the link line, so `cv2.abi3.so` was installed with `RUNPATH /usr/local/cuda/lib64`. Setting
  `CMAKE_INSTALL_RPATH=` or `..._USE_LINK_PATH=OFF` is not enough; `-DCMAKE_SKIP_INSTALL_RPATH=ON`
  makes the install step strip it while the link itself is unchanged.
- **Lapack label "Unknown" on a reconfigure.** When an existing build directory is configured
  again, `OpenCVFindLAPACK.cmake` skips detection because `LAPACK_LIBRARIES` is cached, and the
  summary reads `YES (Unknown <libs>)` instead of `YES (OpenBLAS ...)`. The library is the same, so
  the configure check accepts any `YES (...)` line that names `libopenblas`.
- **Absent AVIF line.** With `WITH_AVIF=OFF` the summary may have no AVIF line at all; the check
  accepts "NO or absent".
- **User lingering for systemd user units.** Without lingering, logging out of all sessions stops
  the user manager and with it the build (see [Unattended night chain](#unattended-night-chain)).
- **Comment edits change the pilot fingerprint.** The pilot is reused only if a hash of
  `pins.env`, `cmake-flags.txt`, `build-requirements.txt` and the patches matches; even a comment
  edit in these files makes `night` run the pilot again.
- **CMake's `DETECT` warning.** OpenCV warns that AArch64 is "designed to work with DETECT" when
  the baseline is pinned; this is expected and the configure check proves the result.

## Updating for a new release

| Trigger | Action |
|---|---|
| New opencv-python release (tag N) | `git ls-remote` the tag SHA; read the submodule SHAs (`git ls-tree`); check that the CUDA modules still exist in opencv_contrib; take a new reference build info from the PyPI wheel (unpack it, import it via `PYTHONPATH`, never install); update `pins.env` and set the build counter in the label back to `.1`; diff the tag's `setup.py` `cmake_args` against `setup_equivalent_args()` in `build.sh`; regenerate `build-requirements.txt` if the tag's `[build-system]` pins changed; run the chain (it repeats the pilot because `pins.env` changed); compare the result with the reference build info |
| New JetPack / L4T release (CUDA, NPP, GStreamer/FFmpeg sonames) | new label `cu<cuda>.l4t<major>.1`; rebuild in the new environment and check again |
| `apt upgrade` of GStreamer, FFmpeg, OpenBLAS, libpng with the same sonames | no rebuild needed; re-run an import and a capture/decode smoke test |
| Flag or module change at the same upstream version | label build counter + 1 (`.2`) |

Regenerating `build-requirements.txt`: in a fresh venv run
`python -m pip download --no-deps <name>==<version> -d <dir>` for numpy, scikit-build, setuptools
(59.2.0, as the tag's `pyproject.toml`), packaging, pip, wheel (the newest that still works with
setuptools 59.2.0: `setup.py bdist_wheel --help` plus a packaging smoke test), and scikit-build's
own runtime dependencies `distro` and `tomli` (`--no-deps` installs nothing implicitly); then
`python -m pip hash <file>` for every downloaded file.

Regenerating the reference build info from an installed PyPI wheel (executed, not modified):

```bash
env -i HOME=$HOME PATH=/usr/bin:/bin /path/to/venv-with-pypi-wheel/bin/python \
  -c "import cv2; print(cv2.getBuildInformation())" > reference/pypi-5.0.0.93-buildinfo.txt
```

## Host guards (`local.env`)

Guards that depend on the machine are not hard-coded. Copy `local.env.example` to `local.env`
(gitignored, sourced by `build.sh` if present). All values default to empty, which disables the
guard:

| Variable | Meaning |
|---|---|
| `PRECHECK_UNITS` | systemd units (system scope) that must be inactive when a build starts |
| `PRECHECK_PGREP` | `pgrep -af` pattern of processes that must not be running when a build starts |
| `FORBIDDEN_DIRS` | directories the build must not run in or below (current directory, repository, `$BUILD`) |
| `FORBIDDEN_BV_GLOB` | glob; a build venv whose directory name matches is refused |

`./build.sh --dry-run` prints the values in effect.

## Tests

```bash
tests/run_tests.sh                    # everything, about 2 minutes
tests/run_tests.sh oom night_killed   # only tests whose name contains one of the words
```

`tests/run_tests.sh` runs the real `night` chain and the real `watchdog.sh` in real transient user
units (`ocv-test-night`, `ocv-test-build`; a real `ocv-build` is never touched) with
`tests/stub_step.sh` in place of the compiler steps. It needs `OCV_TEST=1` hooks that `build.sh`
honours only in that mode (`OCV_STEP_BIN`, `OCV_TEST_UNIT`, `OCV_WD_ARGS`, `OCV_TEST_FULL_PROPS`,
`OCV_LOCAL_ENV`, `BUILD` outside `$HOME`). It covers: the watchdog killed with -9 and `night`
killed with -9 (the build unit stops), a failing `systemctl` once (no premature "ended"), S-a
without journal evidence and the resume at J-1, `RuntimeMaxSec` (`stopped:S-d`), missing
`--window-end`, invalid options with a pre-seeded `ok` status, `BUILD` validation, the host guards
from `local.env`, the J fallback of `full`, and the watchdog stop conditions S-a to S-f against
dummy units with lowered thresholds. The stub holds up to 300 MiB for a few seconds and one test
provokes an OOM kill in a 64 MiB test unit: run it when the board is idle. `bash -n` and
`shellcheck` are clean on all scripts.

## Known limitations

- The S-f signature is the first `error:` line of the log segment; a benign repeated line could
  make two unrelated failures look like the same error. Check `watchdog.log` after S-f.
- The pilot fingerprint covers pins, flags, requirements and patches, not `build.sh` itself; after
  changing `build.sh` run `night --repilot`.
- `ensure_build_venv`, the Python probe and the configure check inherit the unit environment
  instead of `env -i` (integrity is still protected by `--require-hashes`).
- `assert_sources` checks the HEAD SHAs, not that the source work trees are unmodified.
- A `night` refused by the precheck (`failed:precheck`, e.g. because `ocv-build` is already
  running) still stops the `ocv-build` unit on exit; do not start `night` while a manual pilot or
  full build runs.
- `night` has no persistent J cap: after an S-a stop a rerun derives J again from the pilot peak
  (`--max-jobs` overrides).
- The pilot peak covers only the CUDA module targets; other translation units are not measured.
- A SIGKILL of `night` or a logout leaves `night.status` at `running:*` (the build unit is still
  stopped through `BindsTo`).
- A native build embeds its build paths, including the local user name, in `cv2.abi3.so` and in
  `buildinfo.txt`. This does not matter for a wheel used on the build machine; a wheel meant for
  distribution should be built in a container with neutral paths. The reference file committed here
  contains only what the PyPI wheel itself prints (the upstream CI's container paths).
- Only the Jetson Orin family (compute capability 8.7) and L4T R36 are covered; other boards need
  a different `CUDA_ARCH_BIN` and label.

## License

The scripts, patches and documentation in this repository are released under the Unlicense (see
`LICENSE`).

A wheel built with this recipe is a different matter: it contains OpenCV (Apache-2.0), the
third-party code OpenCV bundles (see `LICENSE-3RD-PARTY.txt` inside the wheel), and parts of the
NVIDIA CUDA runtime that are linked statically (`cudart_static`) and are subject to NVIDIA's CUDA
Toolkit license. Check those terms before redistributing a built wheel. **No wheel is published
from this repository.**
