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
| `RECOMP_FILE_TRACE=1` / `=2` | every `NtCreateFile` with path, access, disposition, options and result; `=2` adds the code addresses on the guest stack (callers) |
| `RECOMP_FRAME_TRACE_DRAWS=<lo>-<hi>` | frame-trace draws lo..hi of every frame (counted from 0 after each flip): reaches into a long frame without flips, such as a loading screen, which a flag file armed at a flip cannot time |
| `RECOMP_SURF_STATS=1` | for every frame over 2,000 draws: draws per target surface, the scan-out address (`PCRTC_START`) and how often it changed, the control methods (`0x0100`–`0x01FF`, semaphores, other subchannels) and the first 48 runs of consecutive draws to one surface. Says how a frame that never flips is shown |
| `RECOMP_DOF=0` / `=1` | drop / keep draws that sample the depth buffer they are bound to (Conker's cutscene depth of field); Conker defaults to 0 (`src/main.c`) |
| `RECOMP_SCANOUT_PRESENT=0` | turn off presenting the scanned-out buffer when a title draws into it without flipping (on by default: loading screens) |
| `RECOMP_SKIP_DRAWS=<lo>-<hi>` | drop draws lo..hi of every frame (counted from 0 after each flip) to bisect a wrong frame: skip a range, look at the dump, narrow it down |
| `RECOMP_SKIP_BLEND=<src>/<dst>` (hex, e.g. `306/0`) / `RECOMP_SKIP_INLINE=1` | drop every draw with that blend pair / every inline-vertex draw |
| `RECOMP_PSH_DUMP=1` | each new pixel-shader key (combiner stages, final combiner) and the GLSL generated for it |
| `RECOMP_FRAME_TRACE` fields | per draw also: raw blend regs, texture-shader program, combiner control and factors, alpha test, surface format, fog (enable, mode, colour, params), raw `SET_CONTROL0`, `ZMIN_MAX_CONTROL`, clip range |
| `[FTRACE POS CPU]` (during `RECOMP_FRAME_TRACE`) | runs the CPU position interpreter over every submitted index and reports screen-bounds/depth-range counts and bounds, including a separate positive-`oPos.w` summary; this is an estimate, not GPU readback |
| `RECOMP_GL_VSH_TRACE=1` with `RECOMP_FRAME_TRACE` (desktop OpenGL) | captures actual programmable VSH `oPos` and `gl_Position` through transform feedback for triangle draws to full-size surfaces; compare the same draw's `[VSH GPU]` summary with `[FTRACE POS CPU]` |
| `RECOMP_GL_DIRECT=0` | disable direct guest-vertex reads for raw batches and convert attributes through `fetch_attr`; use as an A/B for direct vertex-format handling, not as a performance setting |
| `RECOMP_VK_NO_DEPTH=1` / `RECOMP_VK_DEPTH_ALWAYS=1` | broad Vulkan depth probes: disable tests and writes, or force enabled tests to pass; affects all draws, including shadows, so not conclusive on its own |
| `RECOMP_VK_DEPTH_ALWAYS_OPAQUE=1` / `RECOMP_VK_DEPTH_GREATER_OPAQUE=1` | force ALWAYS / GREATER depth compare for opaque draws to full-size surfaces; leaves shadow and post-process draws at their original state; diagnostic only |
| `RECOMP_VK_DEPTH_TRACE=<first>-<last>` | log depth clears and opaque full-size draw depth state in the selected Vulkan frame range, including target, ZETA address, clear value, compare, and clip registers |
| `tools/live_linux.sh start\|press\|frame\|log\|stop` | Linux bench in the background: append pad presses, grab the newest dumped frame |
| `RECOMP_PB_EXEC=0` | no GPU: boot runs ~50× faster under the software path; follow it by file accesses |
| `RECOMP_APU_TRACE`, `RECOMP_APU_VOICES`, `RECOMP_AUDIO_DUMP`, `RECOMP_APU_VOICE_DUMP` | audio (never judge audio from a traced run: the trace itself injects gaps) |
| `RECOMP_NATIVE=0` / `RECOMP_NATIVE_CHECK=1` | disable / verify native replacements |
| `RECOMP_NX_PROFILE=1\|2` | sampling profiler ([06](06-performance.md)); also `[profile]` lines in the log every 10 s: `python3 tools/prof_log_report.py LOG ELF` |
| `RECOMP_LINUX_PROFILE=1` | Linux bench sampler (`src/linux_prof.c`): `[profile]` per 1 s window, library code as `[profile-lib]`; `prof_log_report.py LOG build/linux-vk/conker_recomp --window-s 1` |
| `RECOMP_AUDIO_DUMP=<path>,<start s>,<secs>` | the exact PCM sent to the device (s16 stereo 48 kHz); find noise with the first-difference/signal energy ratio per 20 ms (white noise ≈ 2) |
| `RECOMP_APU_VOICES=1` / `RECOMP_APU_TRACE=1` | every voice seen per 5 s with format and addresses / every APU front-end method (stream segments `0x320`, `0x35C`, `0x600+`, voice on/off/pause `0x124`/`0x128`/`0x140`) |
| `*_LOG_SYNC=1`, `*_NO_LOG=1`, `RECOMP_QUIET` | logging modes |
| `XBOX_LOG_LEVEL`, `RECOMP_USB_STATS`, `RECOMP_RUMBLE_TRACE`, `B3_D3D_TRACE`-style hook traces | subsystem logs |

Keep raw register values in graphics traces and decode each field against its exact mask in the matching
hardware header or emulator source. A mistaken bit label can turn a useful observation into a false cause.
Label transformed-position diagnostics by their source: a CPU interpreter estimate can point to a suspect
transform, but it does not prove what the generated GPU shader produced. On desktop OpenGL, the optional
`RECOMP_GL_VSH_TRACE=1` readback can verify the generated output for a traced frame. If both outputs agree
and the positions are outside the view, investigate shared vertex inputs, transform constants and guest
camera state before changing clip or depth rules. The readback is OpenGL-specific; it does not directly
verify Vulkan or Switch output.
Reproduce the same deterministic frame on each available graphics backend. A failure shared by back ends
that use the same shader translator narrows the search toward shared guest state, inputs, or translation;
it does not by itself prove the generated GPU positions match.

Treat global depth overrides as screening probes only. Disabling depth test and writes also removes draw
ordering, while forcing every depth test to pass changes depth-tested shadow passes; neither result isolates
depth rejection on the scene's opaque draws. Scope an A/B override to the target draws and leave shadow and
post-process passes unchanged before concluding that depth is or is not the cause.

## Bug classes to hunt for (grep the log and `gen/` on every bring-up step)

- **`[ICALL] Failed to resolve VA 0x...`**: a function the disassembler missed. It named Carbon's drift bug
  outright. Seed it, re-run the full regen, check the seed lands on a real function start.
- **`[STUB]` lines** (`stubtrace.py`): direct calls into undetected addresses that silently return.
- **`-DRECOMP_ABI_CHECK`**: `[ABI] sub_X: esi edi esp (epilogue never ran)`. Fast way to find split functions.
- **`_flags` fallbacks in `gen/`**: jcc conditions the translator could not resolve (each may be "never taken").
- **Bare `/* mnemonic */` comments in `gen/`**: instructions the lifter did not handle (it is how `lahf`,
  `pushad`, `bt*`, `cmpltss` were found). The x87 and SSE fallbacks carry a prefix, so grep those too:
  `grep -ohE '/\* (FPU|SSE): [a-z0-9]+' gen/*.c | sort | uniq -c`. `fincstp` hid there and blacked out the
  whole 3D scene (2026-10-17).
- **Degenerate transform constants**: when geometry is off screen on every back end, log the model-view
  constants per draw (`[FTRACE VSH CONST]`) and test the 3×3 rows for equal length and orthogonality.
  A broken camera matrix is CPU-side: find it in guest RAM (tolerance search), watch it with gdb
  (`watch -l *(int*)(0x1000000000 + va)` after stamping a different value), and compare each writer's
  lifted output with an emulation of its x86 on the same inputs.
- **`0xAAAAAAAA`** pointers: the allocator fill, i.e. a race between guest threads or an unlinked node.
- **NaNs**: a NaN trap (`BO3_TRAP_NAN=<flag file>` in Burnout's main.c unmasks SSE invalid once the file
  exists) named the `lahf` bug.
- Slow motion: game time vs wall time (`clockscan.py`: float clocks in guest RAM and their rate).
- Memory: `peek.py PID ADDR '*PTR+OFF'` reads guest memory of a running Linux build; `/proc/<pid>/mem`
  unbuffered; gdb hardware watchpoints only report value *changes* (stamp a non-zero value first).

## Audio and texture bug classes

- **Static or noise bursts**: a voice reading the wrong memory (RMS ≈ 0.5, first-difference ratio ≈ 2 in its
  own samples). Check the addresses the APU is given: memory above RAM comes through `MmGetPhysicalAddress`
  as a VA (fixed in `apu_phys`, 2026-10-17).
- **Sound that stops**: trace the stream segments; a stream drained during a long frame and paused for lack
  of data is a stall problem (first-use shader compiles), not an audio one.
- **Magenta objects**: an undecodable texture format, named once in the log
  (`[VK] texture ... not decodable (drawn magenta)`).
- **Dark hard-edged quads under projected shadows**: the sampler's border colour (now taken from
  `SET_TEXTURE_BORDER_COLOR`); the frame trace prints stage 0's format, address modes and border.
- **Blur or masks in the wrong places in a post-process pass**: check every format the frame trace shows
  sampling a depth buffer or render target, not just the first. Conker reads its depth as 0x41 (glow) and
  0x3F (cutscene depth of field); the depth texture must decode as each format would decode the guest
  bytes (`depth_texture_view`, 2026-10-17). `RECOMP_PSH_DUMP=1` shows which channels the combiners use.
- **A freeze of a few seconds where a loading screen belongs**: look for a `[hitch]` frame of thousands of
  draws. If the draws continue while no flip comes, the title is drawing into the buffer being scanned
  out (`RECOMP_SURF_STATS=1` shows it). Conker's loader does that; the executor presents the scanned-out
  buffer for such draws (2026-10-17).

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
