# Conker build and validation process

This is the repeatable path used to go from source changes to a test build on the Switch. It complements
[10-building.md](10-building.md), which documents the Switch toolchain and NVK dependencies, and
[11-testing-on-console.md](11-testing-on-console.md), which documents the NetLoader workflow.

## 1. Start from the intended branch and inspect changes

Run builds from the repository root. Check the active branch and working tree before regenerating or
building so that generated output and test logs can be associated with the source that produced them:

```sh
git branch --show-current
git status --short
```

Keep the extracted game under `game/`, generated translation under `gen/`, persistent build directories
under `build/`, and runtime evidence under `run/`. These large/generated paths are generally ignored by
Git. Do not discard pre-existing local edits when switching branches or cleaning build output.

## 2. Regenerate the lifted game code when required

The Xbox executable is `game/default.xbe`. `tools/regen.sh` runs the disassembler, function identification,
ABI analysis, and C code generator; the generated C is in `gen/` and is compiled for both Linux and Switch.
The project virtual environment is selected automatically when present.

```sh
tools/regen.sh
```

Regenerate after adding or changing entries in `config/seed_functions.json`, changing the lifter or ABI
analysis, or changing the XBE. Seeds expose real indirect-call targets the static pass missed; inspect the
bytes and neighboring function boundaries before accepting one, since a seed inside an existing function
would split it. A normal runtime or renderer edit does not need a re-lift. `LIFT_ONLY=1 tools/regen.sh` skips
the analysis passes and is intended for changes to manual recompilation code only; it does not apply new
seeds. Review the generated summary and any unresolved-call stubs before proceeding.

## 3. Build and validate in `conker-dev`

The `conker-dev` image is the fast correctness bench. It compiles the AArch64 Linux target and runs the
Vulkan renderer on lavapipe. The repository is mounted at `/work`; the game and build artifacts are read
through that mount. This checks startup, guest progress, file/cache behavior, and host crashes. It does not
validate Horizon memory mapping, the Switch NVK driver, or console performance.

Build incrementally in the container:

```sh
docker run --rm -v "$PWD":/work -w /work conker-dev \
  cmake --build build/linux-vk -j4
```

For a fresh-cache run, give each run a separate save directory. This avoids a previous run's generated
textures, audio, or cache files masking first-boot problems. The following example captures a 45-second
run and enables the watchdog's thread report:

```sh
RUN_ID="buildcheck-$(date +%Y%m%d-%H%M%S)"
mkdir -p "run/conker-dev-test/save-$RUN_ID"
docker run --rm -v "$PWD":/work -w /work/run \
  -e CONKER_GAME_DIR=/work/game \
  -e CONKER_SAVE_DIR="/work/run/conker-dev-test/save-$RUN_ID" \
  -e RECOMP_FPS_LOG=1 \
  -e RECOMP_WATCHDOG_SECS=40 \
  -e RECOMP_WATCHDOG_KEEP=1 \
  conker-dev timeout -s KILL 45 /work/build/linux-vk/conker_recomp \
  >"run/conker-dev-test/$RUN_ID.log" 2>&1 || true
```

Review the log for frame/FPS progress, `[STUB]` or `[ICALL]` unresolved targets, watchdog output, and
exceptions. If graphics evidence is useful, enable the runtime frame dump as in `tools/run_linux.sh`; keep
captures with the matching run log. For a hang, `tools/snap_linux.sh` can capture host backtraces while the
Linux process is live. Record the symptom, cause, fix, and evidence in [09-bringup-log.md](09-bringup-log.md).

## 4. Build and stage the Switch NRO

After the Linux correctness pass, build the Vulkan NRO using the native devkitPro installation:

```sh
VULKAN=1 STAGE_GAME=0 bash switch/build.sh
```

The script configures `build/switch-vk/`, runs Ninja, and stages
`switch_sd/switch/conker/conker-vulkan.nro`. `STAGE_GAME=0` leaves the large extracted disc copy on the
SD card untouched. The default job count is capped using available memory; set `JOBS` explicitly if a
different limit is needed. Check that the NRO timestamp and size changed, and check `_start` in the ELF:

```sh
aarch64-none-elf-nm build/switch-vk/conker_recomp.elf | grep ' T _start$'
```

The expected symbol address is zero. Keep the NRO and its exact unstripped ELF together for each console
build so exception and profiler addresses can be resolved against the right binary. The archive convention
is `analysis/elf_archive/conker-vulkan_<md5:8>.{elf,nro}`; see [10-building.md](10-building.md).

## 5. Upload and observe the console run

On the Switch, start Homebrew Menu with title takeover by holding **R** while launching a game, then press
**Y** to open the NetLoader. On the host, upload the staged NRO and enable a 60-second watchdog:

```sh
ARGS='RECOMP_WATCHDOG_SECS=60 RECOMP_WATCHDOG_KEEP=1' \
  tools/nxlink_run.sh 192.168.1.248
```

`tools/nxlink_run.sh` replaces the NRO at `sdmc:/switch/conker/conker-vulkan.nro`, starts it, and records
stdout/stderr in `run/net_logs/<timestamp>.log`; `latest.log` points to the newest run. The command stays
attached while the console process keeps its NetLoader connection open. After it closes, inspect the log for
the final frame count, watchdog report, unresolved calls, and exception. Runtime arguments are limited to
roughly 240 characters by the wrapper.

If a new `[ICALL]` target appears, inspect it in the XBE and confirm it is a function entry before adding a
seed, then repeat the full regeneration, container pass, NRO build, and upload. If the failure is a runtime
or platform issue rather than a missing function, fix the relevant kernel/platform path and repeat the same
validation sequence. Update the bring-up log with the exact build/run evidence after each fix.

## Evidence and reference documents

- [Building and toolchain details](10-building.md)
- [Console upload and diagnostic details](11-testing-on-console.md)
- [Bring-up issues and resolutions](09-bringup-log.md)
- [Technical architecture for future ports](12-porting-guide.md)
