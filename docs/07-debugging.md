# Debugging workflow

## Test loop

- **Linux first** (SDL2, GL or Vulkan on lavapipe, headless): boot, menus and gameplay logic, most render
  bugs, frame dumps, gdb. Use `RECOMP_NO_MIRRORS=1` so Horizon's no-alias behaviour shows up there too.
  Under gdb: `set disable-randomization off` (with ASLR off the Xbox kernel VA and tiled aperture cannot be
  mapped).
- **Eden** runs the GL NRO only (no NVK). Good for boot time and hitches, not for fps. Close it politely
  (a hard kill corrupted its exe/config once).
- **Hardware** for Vulkan and anything about speed, unaligned atomics, IPC, memory aliasing.
- The BO1 port's Wi-Fi loop is worth copying: nxlink from the Homebrew Menu with `--log_network=<host>:<port>`
  streaming the log to a listener on the Mac. Kill stale listeners first (a leftover listener blocked the
  game's stdout at a black screen).
- Process hygiene on Linux: one run at a time; the process renames itself and ignores SIGTERM. Kill by PID
  with `-9`, and never `pkill -f` a pattern that matches your own shell.

## Runtime switches (Switch: `KEY=VALUE` lines in `sdmc:/switch/conker/conker_env.txt`)

| Switch | Use |
|---|---|
| `RECOMP_FRAME_TRACE=<flag file>` | one frame of draws (state, textures, combiners, first vertices) |
| `RECOMP_GL_DUMP=<prefix>[,N]`, `RECOMP_VK_DUMP_SURF`, `RECOMP_FB_DUMP_FLIPS` | frame / surface dumps |
| `RECOMP_PAD_SCRIPT=<ms>:<btn>[:<hold>],...` / `RECOMP_PAD_LIVE=<file>` | drive menus without hands; with dumps on, "look at the latest frame, append a press" |
| `RECOMP_WATCHDOG_SECS=<s>` (+ `RECOMP_WATCHDOG_KEEP=1`) | guest call stack on a hang (`tools/stackwalk.py`) |
| `RECOMP_PB_EXEC=0` | no GPU: boot runs ~50× faster under the software path; follow it by file accesses |
| `RECOMP_APU_TRACE`, `RECOMP_APU_VOICES`, `RECOMP_AUDIO_DUMP`, `RECOMP_APU_VOICE_DUMP` | audio (never judge audio from a traced run: the trace itself injects gaps) |
| `RECOMP_NATIVE=0` / `RECOMP_NATIVE_CHECK=1` | disable / verify native replacements |
| `RECOMP_NX_PROFILE=1\|2` | sampling profiler ([06](06-performance.md)) |
| `*_LOG_SYNC=1`, `*_NO_LOG=1`, `RECOMP_QUIET` | logging modes |
| `XBOX_LOG_LEVEL`, `RECOMP_USB_STATS`, `RECOMP_RUMBLE_TRACE`, `B3_D3D_TRACE`-style hook traces | subsystem logs |

## Bug classes to hunt for (grep the log and `gen/` on every bring-up step)

- **`[ICALL] Failed to resolve VA 0x...`**: a function the disassembler missed. It named Carbon's drift bug
  outright. Seed it, re-run the full regen, check the seed lands on a real function start.
- **`[STUB]` lines** (`stubtrace.py`): direct calls into undetected addresses that silently return.
- **`-DRECOMP_ABI_CHECK`**: `[ABI] sub_X: esi edi esp (epilogue never ran)`. Fast way to find split functions.
- **`_flags` fallbacks in `gen/`**: jcc conditions the translator could not resolve (each may be "never taken").
- **Bare `/* mnemonic */` comments in `gen/`**: instructions the lifter did not handle (it is how `lahf`,
  `pushad`, `bt*`, `cmpltss` were found).
- **`0xAAAAAAAA`** pointers: the allocator fill, i.e. a race between guest threads or an unlinked node.
- **NaNs**: a NaN trap (`BO3_TRAP_NAN=<flag file>` in Burnout's main.c unmasks SSE invalid once the file
  exists) named the `lahf` bug.
- Slow motion: game time vs wall time (`clockscan.py`: float clocks in guest RAM and their rate).
- Memory: `peek.py PID ADDR '*PTR+OFF'` reads guest memory of a running Linux build; `/proc/<pid>/mem`
  unbuffered; gdb hardware watchpoints only report value *changes* (stamp a non-zero value first).

## Techniques from the external (BO1) docs that apply here too

- Automate the path to the test scene. BO1 queued a console command from a hook. Here, pad scripts or a save
  file that lands at the scene.
- Trigger frame traces on the first heavy frame after a delay, not on time alone, or they land on a loading
  screen.
- SD cards fail silently: hash files on the console against the extracted disc, never overwrite in place,
  replace failing cards. BO1 lost days to this.
- xemu's GDB stub (`xboxrecomp/docs/technical/xemu-debugging.md`) gives ground truth from the real game:
  memory diffs per page, float search, matrix detection. Halt before setting breakpoints, remove them before
  continuing.
