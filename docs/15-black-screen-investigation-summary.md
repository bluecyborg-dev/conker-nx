# Black-screen investigation summary

**Date:** 2026-10-17  
**Scope:** Conker PAL port bring-up through the final Linux Vulkan depth probe  
**Current outcome:** The port boots, plays the intro, and continues running the front end, but the menu/title scene is still black or mostly absent. The menu is not yet playable. The latest probe did not fix it. The extended-memory error is fixed and verified on Switch. No NRO was uploaded during the final Linux probe.

> **Resolved 2026-10-17.** The black scene was not a renderer fault. The lifter emitted the x87 instruction
> `fincstp` as a no-op; the game's rotation-matrix builder (`sub_003E2E60`) depends on it, so every camera
> roll matrix lost a row and the camera view collapsed. The world was projected off screen on every back
> end. After the lifter fix (conker-nx commit 1bc623e) the title tavern renders and the front end is
> playable on Linux. The steps that found it are in the 2026-10-17 entry "black front end solved" of
> [09-bringup-log.md](09-bringup-log.md). The depth, clip and cull probes below were wrong leads; they are kept as a record.

This report consolidates the build, startup, hardware, and graphics attempts recorded through this date. It separates direct hardware evidence from Linux-bench and CPU-estimated results. The full dated logs remain in [09-bringup-log.md](09-bringup-log.md), current issues in [14-port-status.md](14-port-status.md), and the diagnostic commands in [07-debugging.md](07-debugging.md).

## Current state at a glance

- **Switch boot and intro:** verified with NRO `31500df5`; input can skip the intro.
- **Switch front end:** continues running with menu music and hundreds of draws, but is black after the intro. Last run reported 20 FPS and 605–669 draws/frame through frame 1,553, when the user quit. It logged no unresolved indirect calls, stubs, guest exception, or `0xCE01` memory error.
- **Linux Vulkan:** menu/title capture remains black after the final probe. At frame 2,100 the image was fully black; frame 2,101 submitted 700 draws. The run reached at least frame 2,792 without a recorded renderer crash or guest exception.
- **Linux OpenGL:** reproduces the black view. Transform-feedback captures confirm generated OpenGL positions agree with the CPU interpreter for sampled world batches, and those vertices lie outside the 640×480 viewport. That points toward shared guest vertex inputs/program/camera state or shared translation, but does not identify which is wrong.
- **Depth:** changing opaque depth comparison can reveal room/floor geometry in some earlier views, so depth rejection contributes to missing geometry in those views. It is not a sufficient explanation or fix for the later black menu. The final scoped `ALWAYS` probe remained black.
- **Priority:** reach a visible, controllable game scene first. The Linux bench may use a different resolution or aspect ratio; exact Switch aspect ratio is not a prerequisite. Geometry projected tens of thousands of pixels outside the viewport cannot be explained by aspect-ratio mismatch alone.

## Attempts and results

### 1. Port setup, translation, and first builds

The `xboxrecomp/` toolkit was vendored from Burnout 3 Switch port commit `80ed797`. The initial Conker PAL pipeline disassembled 21,269 functions and emitted 86 generated files (183 MB, about 3.49 million lines), with 310 unresolved-call stubs and 94 spin loops marked. A first toolkit test run passed 542 of 554 tests; the 12 failures were stale generated-code harnesses that did not declare this fork's `RECOMP_PREEMPT` and `recomp_leaf_ld_*` additions. They were not treated as translator regressions.

The build and startup blockers found and fixed were:

| Attempt / symptom | Finding | Result |
|---|---|---|
| Generated `recomp_0048.c` failed with `_cf` undeclared after `lahf`. | The translator did not count `lahf` as reading carry, although the lifted code can observe CF afterward. | Updated the translator's CF-reader analysis and added `test_lahf_carry_decl.py`; build progressed. |
| AArch64 Linux crashed while creating the D3D device; MMIO aperture access at guest `0xFD001804` returned ENOMEM. | The reserved guest RAM/mirror span landed too high in the 64-bit host address space; adding the NV2A aperture exceeded the available user VA range. | Memory layout now first reserves the span at fixed low host addresses (64 GB, then 256 GB), with the OS-selected address as fallback. |
| Startup logged unresolved indirect call `0x00558C9D`. | XPP USB host setup begins directly after a preceding `ret 8`, without padding. | Added a verified function seed; it resolved. |
| Fresh asset load reached Conker's fatal error loop (`sub_001F04F0`) while reading `ConkerFont/default.bin`. | The file buffer was committed guest virtual memory above ordinary RAM (`guest_vmem` range starting at `0x74000000`); the bridge only accepted ordinary mapped RAM. | The file bridge now recognizes ranges reported committed by `guest_vmem`; font/front-end asset loading progressed. |
| Guest stacks and runtime data overlapped the Conker image's `.data`/BSS. | Toolkit defaults assumed an image ending below `0x00780000`; Conker's image ends at `0x00891D20`. | Made `XBOX_STACK_BASE` configurable and set Conker's base to `0x00900000`. |

The analysis also fixed lifter handling for `cmovp`/`cmovnp` used by MSVC NaN tests. Other unusual instructions were reviewed; remaining cases such as `ldmxcsr`/`stmxcsr` are still open for future correctness checks, while several others were assessed as harmless or likely data decoded as code. Runtime hooks were ported for D3D device globals, fence waits, ISR/DPC/vblank/PGRAPH handlers, KickOff, CRT memcpy/memmove, `_ftol2`, DSP posting, AC'97 reset, and the DSOUND watchdog.

### 2. Cache creation, missing functions, and Linux boot progress

On a fresh cache, the game stopped while creating `Z:\texture\frontend\tips`. The first bridge-side `mkdir_tree()` fix let the Linux run reach frame 902 and a Switch build reached the front end, but the bridge was creating parent directories in cases where NT would not. The implementation was replaced with NT-faithful status reporting: `OBJECT_PATH_NOT_FOUND` when a parent path is missing, and `OBJECT_NAME_NOT_FOUND` when only the final component is missing. The game then created its own parent chain. A clean-cache Linux run reached frame 3,001 in 60 seconds and 2,288 in 45 seconds, at about 59 FPS, with no unresolved calls.

Further indirect-call targets were confirmed as real function entries and added to `config/seed_functions.json`:

- `0x003FA4F0`, reached after `sub_003FA320`/INT3 padding.
- `0x00016620` and `0x0002D710`, both real entries after padding; their Linux run reached 1,131 frames without unresolved calls or a guest crash.
- `0x00123600` and `0x00248670`; the Switch run passed frame 902 and continued to 1,801 before exposing later targets.
- `0x00499849`, `0x001C1400`, `0x001C16A0`, and `0x001AF3C0`; after seeding these, analysis recovered 21,284 functions and a clean-cache Linux run reached frame 2,211 at 59.1 FPS without unresolved calls or a guest crash.

These runs established that the initial startup and asset path could work on Linux. They did not show the menu correctly. The Linux bench used AArch64 Ubuntu 24.04 in the `conker-dev` container, Vulkan on lavapipe, and headless frame dumps. An earlier NRO (`d887d25b`) was built, but its first two upload attempts failed to connect to `192.168.1.248`; there was no hardware result from those attempts.

### 3. First Switch runs and the memory fix

The first successful console run used NRO `31500df5` (build archive `analysis/elf_archive/conker-vulkan_31500df5.{nro,elf}`). Two upload attempts failed before the third worked: the first could not connect because NetLoader was not open; the second connected and then returned a reset/invalid response after a port probe. The successful run log is `run/net_logs/20261017-002117.log`.

On Switch, that build booted, built the fresh `Z:` texture cache, cached audio banks, and played `dvddata\fmv\frontend\BootIntro.xmv`. The intro rendered with picture; early frames took about 50–117 ms and a reported sample was 28.5 FPS at frame 366. After skipping the movie, the title/front end ran at about 20 FPS (50 ms frames), 540–860 draws/frame, and reached frame 2,720 before the user quit. The image was black apart from occasional flashes, but input/game logic continued. A 90-second watchdog showed the main thread doing normal work. There were no `[ICALL]`, `[STUB]`, or crash reports in that run.

That NRO's extended guest virtual-memory commits sometimes failed with `0xCE01`; 12 small allocations used a shared-memory fallback. The root issue was repeated commits of a growing range from the same address: Horizon attempted to remap pages already mapped. `extvma_commit()` was changed to commit and retain 2 MB granules once, and the shared-memory fallback ceiling was raised from 128 KB to 2 MB. The newer NRO `3f85b158` (commit `d386a80`) was tested on hardware. Its log, `run/net_logs/20261017-020541.log`, shows the game booting and playing the intro; after the user skipped it, the display remained black with menu music. It reached frame 1,553 at 20 FPS and 605–669 draws/frame, with no unresolved calls, stubs, exception, `0xCE01`, or shared-memory fallback. **The memory fix is verified on hardware; the renderer issue is not.**

### 4. Linux renderer reproduction and fixes that removed two false leads

An idle Linux run reproduced the post-intro black/title view. The title flythrough runs approximately frames 3,700–6,500, with roughly 540–860 draws/frame, before `attract.xmv`.

**16-bit shadow-map clear conversion.** Bisection with `RECOMP_SKIP_BLEND=306/0` (skip `DST_COLOR × ZERO`) restored part of the view. Those draws were three projected-shadow passes, multiplying the screen by 128×128 / 64×64 shadow maps. The maps used R5G6B5 surfaces (`SET_SURFACE_FORMAT` value `0x07070213`) cleared with `0x0000FFFF`, which is white in R5G6B5. The back end treated the value as ARGB8888, so the maps were cyan and the multiply darkened the scene. `clear_color_argb()` in `xboxrecomp/src/kernel/nv2a_pb_exec.c` now widens R5G6B5 and X1R5G5B5 clear values. This fixed a real darkening bug and exposed some geometry, but not the whole menu.

**Wrong surface presented.** From around frame 4,300, captures became a black 256×256 square (341×256 dump rather than 853×480). After compositing glow into the back buffer, the game cleared the 256×256 glow surface `80CEC180`. Vulkan tracked the last surface touched, so `vk_flip()` presented that cleared target. It now presents `s_last_drawn`, falling back to the last touched surface only if no draw occurred. This fixed the wrong-size output; the full-size view remained black/missing.

### 5. Scene visibility, clip/depth probes, and position traces

Several attempts were used to distinguish black shading from geometry not appearing:

1. **Red back-buffer clear diagnostic:** temporarily forcing the back-buffer clear to red produced a red field with vignette/rain but no world scene. This indicated that scene geometry was not reaching the view in that sample, rather than the whole frame simply being shaded black. This was a temporary diagnostic and is not committed.
2. **Draw skip:** `RECOMP_SKIP_DRAWS=263-999` (skip later draw indices) did not change the result. Opaque draw combiner, fog, blend, and depth state compared between a partly visible frame 4,050 and black frame 4,847 were the same. Scene draws used `SET_CONTROL0=0x00100001`; `SET_ZMIN_MAX_CONTROL=1`.
3. **Corrected register interpretation:** an early working theory called bit 20 of `SET_CONTROL0` a W-buffer control. Review against the vendored NV2A header showed `Z_PERSPECTIVE_ENABLE` is bit 16 (`0x00010000`), clear in `0x00100001`; bit 20 is undefined in that header. The earlier W-buffer diagnosis was wrong. The trace alone does not establish depth representation. Do not implement W-depth based on bit 20.
4. **Initial full-draw CPU position estimate, frame after flip 4,655:** for 181 large back-buffer draws, 82,750 indices were examined. No positive-`oPos.w` CPU-estimated vertex was inside 640×480; only six draw bounds intersected the screen, accounting for 4,722 indices. Of 53,043 positive-w positions, 45,640 fell inside the captured depth interval. This was an interpreter estimate, not GPU readback.
5. **Global Vulkan depth probes:** `RECOMP_VK_NO_DEPTH=1` disabled depth tests and writes; `RECOMP_VK_DEPTH_ALWAYS=1` forced enabled comparisons to ALWAYS. Both runs remained black (no-depth at frame 4,800; always-depth at frames 3,780, 4,020, and 4,320; frame 3,840 in the no-depth run showed only rain). These changes also affect shadows and draw ordering, so they are screening tests, not conclusive isolated depth tests.
6. **Scoped opaque depth probes:** `RECOMP_VK_DEPTH_ALWAYS_OPAQUE=1` applied ALWAYS only to opaque draws targeting full-size surfaces, retaining depth behavior for shadow/glow surfaces. It exposed floor/room geometry in frames 3,780, 4,020, and 4,140, but frame 4,320 was black. `RECOMP_VK_DEPTH_GREATER_OPAQUE=1` showed the room at 3,780, then was black at 4,020, 4,140, 4,320, and 4,530 (run reached 4,545). These results show the normal opaque comparison rejects some visible geometry in some views; neither override is the correct general fix or recovers the later black view.
7. **Depth-state trace, frames 4,120–4,340:** Vulkan logged color targets `80964000`/`80A90000` with ZETA `80BC0000`. The depth buffer was cleared to 1.0 (`0xFFFFFF` of `0xFFFFFF`) each frame; compare was `0x203` (LEQUAL), depth test and writes were enabled, `SET_ZMIN_MAX_CONTROL=1`, clip range 0–16,777,215. This did not change across black and partly visible frames. The late blackout was not caused by a change in those traced clear/compare registers; invalid or out-of-range vertex positions remained possible.
8. **Frame 4,320 CPU position trace and attribute A/B:** 497 back-buffer draws (`80A90000`) and 139,085 indices were covered. Only three positions were estimated inside 640×480, all full-screen composite quads; there were no in-view world vertices. Of 50,028 positive-w positions, 45,092 were within the recorded depth interval. A second run with `RECOMP_GL_DIRECT=0` forced the converted attribute path; it too was black, with 498 draws / 139,402 indices, three in-view composite positions, and no in-view world positions. This makes the direct vertex-format path unlikely to be the sole cause, but both figures were CPU estimates and did not prove GPU positions.

### 6. Cross-backend OpenGL and corrected GPU VSH capture

Rebuilding and running the same Linux title route on `build/linux-gl` also produced a fully black frame 4,320, while approximately 540–732 draws/frame continued. Vulkan and desktop OpenGL therefore reproduce the symptom. Both use shared guest state and vertex-shader translation, so this reduces the likelihood of a Vulkan-only bug; it does not prove that Switch/Vulkan GPU positions match OpenGL.

The source comparison against upstream xemu's programmable VSH (`vsh-prog.c` and `vsh.c`) found the same broad screen-space x/y-to-clip conversion, clip-range z scaling, and multiplication by clip w. This is a structural comparison, not a proof of identical behavior for the captured guest state.

The first OpenGL transform-feedback probe exposed a diagnostic bug: unbinding transform-feedback index 0 also cleared the generic buffer binding, making the readback invalid. Rebinding the buffer before `glGetBufferSubData` corrected that problem. A later triangle-strip probe had a second flaw: replaying strips as triangle lists duplicated vertices in the capture and allowed the diagnostic draw to rasterize. It was replaced with a replay of the same indexed inputs as `GL_POINTS` with `GL_RASTERIZER_DISCARD`, so each input index yields one captured vertex without changing the image.

Results from the GPU captures:

| Captured frame / batch | CPU vs GPU result | Meaning / limit |
|---|---|---|
| Black frame 2,668, 2,382-index world batch | Both reported 1,537 positive-w positions and none in view. Bounds were CPU `-16366.1,-132156.5:-79.2,785.6`; GPU `-16366.2,-132157.4:-79.2,785.5`. The 1,830-index batch also matched closely; none were in view. | Confirms the generated desktop GL positions matched CPU estimates for sampled draws and were outside the viewport. The visible rectangle was a full-screen post-process quad. Does not identify which guest input/state is wrong. |
| Black dump frame 2,100; trace after flip 2,104 / GPU label 2,105; 747-index batch | CPU reported all 747 positions with negative `oPos.w`; GPU found zero positive-w positions. | CPU and GPU agree that this batch has no positive-w vertices. |
| Same frame, 1,082-index batch | CPU: 1,002 negative-w, 80 positive-w, none in view; bounds `-31283.3,-247017.6:-483.7,-2521.8`. GPU: same 80 positive-w, none in view; bounds `-31283.1,-247015.9:-483.7,-2521.8`. | Confirms these sampled world vertices lie far outside the viewport. Attributes, constants, and the 33-slot VSH program were dumped for comparison. |

The captured 33-slot VSH program contains no MAC ARL instruction (opcode 13). Since xemu and the port both use `floor(src + 0.001)` for ARL, the known ARL rounding difference is not an explanation for that sample. Other instruction semantics, guest vertex attributes, constants, program state, and camera state are still candidates. The capture is desktop OpenGL only; it does not directly validate Vulkan or the Switch GPU.

### 7. Final attempt: scoped Vulkan depth override

The final attempt rebuilt the current Linux Vulkan target in `conker-dev`:

```sh
docker run --rm \
  -v /Users/cyborg/Desktop/proyectos/conker-nx:/work \
  -w /work conker-dev \
  cmake --build build/linux-vk -j4
```

The build linked successfully. It emitted an existing `-Wcomment` warning in `kernel.h:504` about `/*` appearing inside a comment; no build failure resulted. The current binary was run through the scripted title route with `RECOMP_VK_DEPTH_ALWAYS_OPAQUE=1`, with frame output under `/private/tmp/conker-vk-depthfinal/frames/`. The runtime log confirmed the override applied to opaque draws on full-size surfaces. The 640×480 capture at frame 2,100 was completely black; frame 2,101 still submitted 700 draws. The process continued through at least frame 2,792 without a recorded exception or renderer crash and was stopped after the target capture. **This last probe failed to recover the menu.** It shows that forcing opaque depth comparisons to pass is not sufficient for this view. It does not rule out clip rejection, incorrect shared guest inputs/state, other depth behavior, or a Switch-specific difference. No NRO was uploaded in this attempt.

## Other findings that remain relevant

- **Frame composition:** a typical flythrough frame has about 30 draws into three shadow maps (`8224F900`, `82257980`, `8225FA00`), about 230 opaque and 270 alpha-blended scene draws to alternating back buffers (`80964000`/`80A90000`), three `DST_COLOR × ZERO` shadow passes, then glow/post-process surfaces (`80CEC180`, `80D4C280`, `80D2C200`) and composite draws.
- **Combiner/fog:** scene final combiner `13030C00` evaluates `fog.a·fog.rgb + (1-fog.a)·R0`; Conker uses fog alpha as the fog amount. This is useful if later captures show an inverted fog result.
- **Performance:** the console front end is about 20 FPS with much of the 3D view missing; that is not a useful full-scene performance baseline. Profile on hardware with `RECOMP_NX_PROFILE=1` after rendering is correct. Intro playback had 50–117 ms frames; CPU-side XMV decode and YUV-to-RGB conversion are suspected, not yet optimized.
- **Unimplemented NV2A modes:** bump and dot-product texture shader modes are not implemented (they currently sample as plain 2D); Conker uses normal mapping and fur. Their involvement in this specific black screen has not been established.
- **Render-target formats:** colour surfaces are stored as ARGB8888. Clear conversion is fixed, but true 16-bit attachment precision/layout and X1R5G5B5 alpha remain open if visible evidence points there.

## Evidence files and code locations

- Hardware logs: `run/net_logs/20261017-002117.log` (NRO `31500df5`), `run/net_logs/20261017-020541.log` (NRO `3f85b158`). Earlier upload failures for `d887d25b`: `run/net_logs/20261016-232929.log` and `run/net_logs/20261016-233056.log`.
- NRO archives: `analysis/elf_archive/conker-vulkan_31500df5.{nro,elf}`, `analysis/elf_archive/conker-vulkan_d887d25b.{nro,elf}`; the memory-fix build is `analysis/elf_archive/conker-vulkan_dc06e7ee.nro`, followed by hardware-verified NRO `3f85b158`.
- Linux startup logs: `run/conker-dev-test/seeded2.log`, `seeded3.log`, `seeded4.log`; frame captures under `run/conker-dev-test/frames/`.
- Graphics changes/diagnostics: `xboxrecomp/src/kernel/nv2a_pb_exec.c` (16-bit clear conversion), `xboxrecomp/src/nv2a_vk/nv2a_vk.c` (present last drawn target and Vulkan probes), plus OpenGL/VSH diagnostic work in `xboxrecomp/src/nv2a_gl/` and `xboxrecomp/src/kernel/`.
- Runtime probe reference: [07-debugging.md](07-debugging.md). Diagnostic switches are off by default unless explicitly set in the run environment.

## What remains and recommended next steps

1. Compare the dumped guest vertex attributes, VSH constants/program, and camera state for a representative out-of-view world draw against a reference Xbox/NV2A implementation. Start with the 747-index and 1,082-index batches whose attributes/program/constants were captured.
2. Capture the same inputs from an earlier partly visible view and the first fully black view; identify which guest inputs or camera values change. Avoid attributing the change to depth based solely on the CPU position estimate.
3. For a matching draw, compare the desktop GL capture with generated Vulkan shader output and then, if feasible, Switch output. The current OpenGL readback is not Vulkan or hardware evidence.
4. Confirm the relevant NV2A `SET_CONTROL0` and `SET_ZMIN_MAX_CONTROL` semantics from an authoritative hardware/emulator source. Keep x/y clipping, z clipping, and depth comparison as separate tests; do not treat bit 20 as a W-buffer flag.
5. Re-run deterministic title frames with a frame dump and `RECOMP_FRAME_TRACE`; use the temporary red-clear diagnostic only to distinguish absent geometry from black shading. Keep global depth switches off for conclusions because they affect shadow and post-process ordering.
6. After a visible controllable scene appears, enter a new game and capture the first gameplay frame on Linux, then verify on Switch. Adjust scaling/aspect ratio later if needed; it is not a gate for reaching gameplay.
7. Once the scene is rendering correctly, profile the console's 20 FPS and investigate native XMV/YUV conversion if intro performance remains important.

**Final assessment:** the port has progressed through build, asset/cache setup, intro playback, and a healthy but visually broken Switch front end. Two real renderer issues (16-bit clear interpretation and presenting the wrong surface) were fixed, and the Switch memory error was fixed. The core black/missing-scene issue remains open. The strongest current graphics evidence is that sampled desktop OpenGL world vertices match the CPU interpreter and project far outside the 640×480 view, while opaque depth changes sometimes reveal earlier geometry but do not fix the later black frame. The next useful step is to identify why the guest vertex inputs/program/camera produce those coordinates and validate the answer across back ends.
