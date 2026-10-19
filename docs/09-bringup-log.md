# Bring-up log

What was done to get Conker running, in order, with the evidence for each address. Newest at the bottom.
Addresses are Conker PAL (title 0x4D530051) guest VAs.

## 2026-10-16: setup and analysis

- Toolkit vendored from antoxa2584x/burnout3-sw `xboxrecomp/` at `80ed797` (`xboxrecomp/VENDORED_FROM.txt`).
  Python tools run from `.venv` (Homebrew Python 3.14 + capstone 5.0.7); `tools/regen.sh` picks it up.
- Toolkit tests: 542 of 554 pass. The 12 failures are stale tests: they compile lifted snippets with a
  harness that does not declare the fork's additions (`RECOMP_PREEMPT`, `recomp_leaf_ld_*`). Not
  translator bugs. Ignore them until the harness is updated.
- Pipeline on `game/default.xbe`: disasm 40 s (21,269 functions: `.text` 17,926, XONLINE 751, XGRPH 502,
  DSOUND 488, XNET 446, XACTENG 307, D3D 278, XPP 264, WMADEC 174, XMV 84), func_id, abi_analysis
  (1,545 thiscall), recomp 2 min 20 s → `gen/`: 86 files, 183 MB, 3.49 M lines, 310 unresolved stubs,
  94 spin loops marked, 1,531 MMIO functions.
- Six junk "functions" in data sections (XON_RD: Xbox Live host-name strings; DOLBY): nothing calls them.

### Unimplemented instructions

1,306 after the first lift, almost all in "functions" that nothing calls, i.e. data decoded as code (ASCII
bytes: `outsd` = 'o', `insb` = 'l', `arpl` = 'c', `aas` = '?', ...). In functions that do have callers:

| Mnemonic | Where | Status |
|---|---|---|
| `cmovp`, `cmovnp` | `sub_00143FF0`, `sub_00266DB0` (`ucomiss; lahf; test ah,0x44; cmov*p`, MSVC's NaN test) | **Fixed** in the vendored lifter (`tools/recomp/lifter.py`, test `test_cmov_parity.py`): same parity condition as `jp`/`jnp` |
| `ldmxcsr`, `stmxcsr` | `sub_002A6590`, `sub_0043B032`, `sub_0043B412` | open: the SSE rounding mode is ignored. Check what mode the title sets before trusting float→int SSE conversions |
| `cpuid`, `pushfd`, `popfd` | `sub_00446AC7` (CRT CPU detection), XNET | harmless (feature detection sees no change; flags push/pop balanced as no-ops) |
| `cli`, `sti`, `sgdt`, `ljmp` | `sub_00430742`, `sub_00433024`, XPP | harmless here (the guest lock replaces interrupt masking); check `sub_00433024` if it is ever reached |
| `wbinvd` | D3D `sub_0053E5D0` | harmless (cache flush) |
| `daa`, `aas`, `arpl`, `lcall` | inside a few called functions | probably data inside a function (jump tables); check if a run reaches them |

## Hooks (all in `src/recomp_manual.c`)

Found by code pattern, then checked against the reference ports' descriptions.

| Hook | Conker | Burnout 3 | Evidence |
|---|---|---|---|
| D3D device global | `0x005499E8` | 0x0035FB48 | most-used global in D3D (143 refs); `+0x2C` submit sequence, `+0x30` semaphore pointer used by the fence wait |
| BlockOnTime | `sub_0053C190` | 0x00351770 | reads `*(dev+0x30)` vs `dev+0x2C`, pushes a NOP(5) trap (`0x40100`/`5`), sleeps on the event at `dev+0x1DCC`. **Stack args (time, flags), `ret 8`**; Burnout's has the fence in eax and `ret 4` |
| ISR | `0x00540CA0` | 0x00356AD0 | `ret 8`, reads port 0x80C0, queues the DPC; same 0x2D0 distance to the vblank handler as in Burnout |
| DPC | `0x00540DC0` | | reads PMC_INTR, calls PGRAPH (`0x1000`), vblank (`0x1000000`) handlers |
| Vblank handler | `sub_00540F70` | 0x00356DA0 | block in eax; vblank count `+0x1C0`, retire index `+0x1BC`, field from port 0x80C0 to `+0x1D0`, KeSetEvent `+0x194` |
| PGRAPH handler | `sub_005411D0` | 0x00357000 | ecx = hardware block; reads PGRAPH_INTR `+0x400100`, NSOURCE `+0x400108`; vblank + 0x260 as in Burnout |
| Vblank block | `device + 0x1C28` | same | `lea ebp, [edi + 0x1c28]` (5 sites); vblank counter = device + 0x1DE8 |
| KickOff | `sub_0053C630` | | spins on the write-combine bit `[hw + 0x100410] & 0x10000` (runtime clears it) |
| CRT memmove/memcpy | `sub_0046E670` | 0x002442A0 | byte signature `55 8B EC 57 56 8B 75 0C 8B 4D 10 8B 7D 08`; negative-index jump tables (calls to "0xE8D6E8AC") |
| `_ftol2` | `sub_00471288` | 0x00244DF0 | byte signature `55 8B EC 83 EC 20 83 E4 F0 D9 C0 D9 54 24 18 DF 7C 24 10`. The native version has a check mode: `RECOMP_NATIVE_CHECK=1` |
| DSP command post | `sub_004C763D` | 0x002F7EC2 | thiscall `ret 4`; scratch = `***(this+8)+0x10`, writes 3 to scratch+0x810 and spins |
| AC'97 channel reset | `sub_004CE34C` | 0x002FE736 | instruction-for-instruction Burnout's body: lock `sub_004C36B0`, unlock `sub_004C36D2`, table `0x004E1608`, re-arm `sub_004CE156`, NABM byte `+0xFEC0010B` |
| DSOUND EP watchdog | skip `sub_004C7DBF` when called from `0x004C80A3` | Carbon 0x003947ED from 0x00394AD1 | `sub_004C7FFF` compares `*[0x004E1C60]` with 0xCCCCCC (Carbon's DSOUND build) |

Not yet located (not needed to boot, or found at run time): XMV YUV converter (Burnout made it native for
speed), presentation interval in the flip trap word (for uncapping), XGetVideoFlags, the game's main loop
and time step.

## 2026-10-16: first builds and boots (Linux bench)

The bench is an arm64 Ubuntu 24.04 container (`docker/Dockerfile`, image `conker-dev`): the lifted C is
built for AArch64 as on the Switch, Vulkan runs on lavapipe, headless. `tools/run_linux.sh` runs it for
`SECS` with frame dumps; `tools/snap_linux.sh` attaches gdb and prints every thread's stack (lifted
functions keep their `sub_XXXXXXXX` names, so the frames are the guest call chain).

Docker note: `docker pull` hung on this Mac because Docker Desktop's `desktop` credential helper was
waiting on Keychain. Public images pull fine with a throwaway config: `DOCKER_CONFIG=<dir with {} as
config.json and a symlink to ~/.docker/cli-plugins>`.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `gen/recomp_0048.c`: `'_cf' undeclared` | `lahf` after `inc`/`dec` reads CF through the same condition as `jb`, but `_function_needs_cf` did not count `lahf` as a CF reader (`sub_00389F5A`, data decoded as code) | toolkit `translator.py`, test `test_lahf_carry_decl.py` |
| 2 | Crash in `xbox_mmio_read` from D3D (`sub_00540345`, CreateDevice), guest 0xFD001804 | Every device aperture failed with ENOMEM: aarch64 Linux placed the RAM + mirror span at 0xFFFFxxxxxxxx, so base + 0xFD000000 was past the 48-bit user space. x86-64 gives lower addresses, so the NFS ports never hit it | toolkit `xbox_memory_layout.c`: on 64-bit POSIX hosts reserve the span at a fixed low host address first (64 GB, then 256 GB), the OS's choice as fallback |
| 3 | `[ICALL] Failed to resolve VA 0x00558C9D` | XPP USB host setup (pool tag 'USBH') starts right after the previous function's `ret 8` with no padding | seed in `config/seed_functions.json` |
| 4 | Game thread spins in `sub_001F04F0` forever | That is the game's **fatal error screen** (ends in `jmp $`). Reached from the asset loop in `sub_001F5440` (table at 0x006BAEC8: `ConkerFont`, `FrontendTitle`; Japanese variants at 0x006BAEF8 when `[0x007FA1DC] == 2`) because reading `dvddata\aid\font\ConkerFont\default.bin` failed: `NtReadFile: buffer 0x7402C8CC ... is not mapped guest memory` | The buffer is NtAllocateVirtualMemory memory above RAM (`guest_vmem.c`, first page past the mirrors = 0x74000000); the bridge's buffer check did not know that range. toolkit `kernel_bridge.c`: accept a range `guest_vmem` reports as committed |
| 5 | (found while chasing 4) guest stacks at 0x00780000-0x00F80000 overlap Conker's `.data`/BSS (image ends 0x00891D20), and the runtime data block (kernel data exports, PRCB, TLS) fell back to fixed addresses 0x00700000-0x00770000, also inside `.data` | The toolkit assumes the image ends below 0x00780000 (Burnout: 0x0076B93C) | `XBOX_STACK_BASE` is now overridable; Conker builds with `-DXBOX_STACK_BASE=0x00900000` (top-level CMakeLists.txt) |

Also added: `tools/stubtrace.py` (run by `regen.sh`): each of the 310 unresolved-call stubs logs
`[STUB] 0x........` on its first hit.

## 2026-10-16: cache creation and intro-screen follow-up

| Symptom | Cause / evidence | Resolution / status |
|---|---|---|
| Fresh-cache run entered the game's fatal error screen while creating `Z:\texture\frontend\tips` | The game's recursive mkdir helper (`sub_001F1E80`) calls `GetFileAttributes` and creates the parent chain only on `ERROR_PATH_NOT_FOUND`, the directory alone on `ERROR_FILE_NOT_FOUND`. `NtQueryFullAttributesFile` answered `OBJECT_NAME_NOT_FOUND` for every missing path, so the game created only the leaf (`FILE_CREATE` + `FILE_DIRECTORY_FILE`, `RECOMP_FILE_TRACE=1` shows `disp 2 opts 00004021`), which failed because `Z:\texture` did not exist; the fatal screen then deletes the `Z:\ConkerLiveAndReloaded` cache marker. Codex's first fix (`mkdir_tree()`, building every parent inside the bridge) worked and reached frame 902 on Switch, but creates parents NT would refuse | 2026-10-17: replaced by NT-faithful statuses. `missing_path_status()` in `kernel_file.c` reports `OBJECT_PATH_NOT_FOUND` when the parent is missing (`NtQueryFullAttributesFile` and `NtCreateFile`), and directory creates use plain `mkdir()` again. Fresh-cache Linux: the game creates `Z:\texture`, `Z:\texture\frontend`, `Z:\texture\frontend\tips` itself (78 creates in all), frame 3,001 in 60 s and 2,288 in 45 s at about 59 FPS, no unresolved calls. Switch NRO `31500df5` built; hardware run pending |
| Extended guest VMA commit failed at 72 KB after the shared-memory fallback rejected requests above 64 KB | The Xbox code makes standalone small commits above the ordinary guest RAM mapping; Horizon cannot always create a code-memory view at the requested VMA | Raised the narrow shared-memory fallback ceiling to 128 KB. Hardware log confirmed a failed 60 KB code-memory view was successfully mapped as a small shared-memory commit. The fallback does not cover large guest RAM. |
| `[ICALL] Failed to resolve VA 0x003FA4F0` after cache setup | Valid function following INT3 padding after `sub_003FA320`, referenced through a function pointer at `0x00480651` | Added verified seed `0x003FA4F0`; full translation and subsequent startup passed it. |
| `[ICALL]` at `0x00016620` (56,000+ hits) and `0x0002D710` followed by Linux crash | Both are real function entries after INT3 padding; `0x00016620` is referenced at `0x000162C0`; `0x0002D710` has a valid stack-frame prologue | Added both verified seeds. A clean-cache Linux run then rendered past the startup path, reaching 1,131 frames at about 60 FPS without an unresolved-call or guest-crash report. Frame captures are under `run/conker-dev-test/frames/`. |
| Switch run reached frame 902, then logged unresolved indirect targets `0x00123600` and `0x00248670`, followed by an invalid target `0x012020C0` and exception 257 | `0x00123600` begins a valid routine after the switch table at the end of `sub_00123290`; `0x00248670` begins a routine after eight INT3 bytes (`0x00248668-0x0024866F`) | Added both runtime-observed entries to `config/seed_functions.json` and regenerated 21,280 functions. Fresh-cache Linux run with these seeds reached 1,124 frames at 59.8 FPS without unresolved calls or a crash (`run/conker-dev-test/seeded3.log`). The subsequent Switch run passed frame 902 and continued to frame 1,801, where it exposed the next four targets below. |
| Switch run passed frame 1,801, then reported unresolved targets `0x00499849`, `0x001C1400`, `0x001C16A0`, and `0x001AF3C0`, followed by a guest access fault at `0x43F00014` | `0x00499849` starts valid XNET switch-dispatch code after a `ret`; `0x001C1400` and `0x001AF3C0` start code immediately after a preceding function's `ret`; `0x001C16A0` starts code after a five-entry jump table | Added all four runtime-observed targets as seeds; analysis now recovers 21,284 functions. A 45-second fresh-cache `conker-dev` run reached frame 2,211 at 59.1 FPS without unresolved calls or a crash, so the prior guest fault did not recur in that run (`run/conker-dev-test/seeded4.log`). The Switch rebuild completed and was archived as `analysis/elf_archive/conker-vulkan_d887d25b.{nro,elf}`. Hardware validation remains pending because nxlink could not connect to `192.168.1.248` on two attempts; no game log was received. |
| Upload of NRO `d887d25b` could not connect to `192.168.1.248` | Both nxlink sessions ended with `Connection to 192.168.1.248 failed` before any runtime output; current NetLoader/IP availability is unconfirmed | No transfer or hardware result is confirmed. Retry after opening Homebrew Menu's NetLoader and verifying the console is still at this IP. Logs: `run/net_logs/20261016-232929.log` and `run/net_logs/20261016-233056.log`. |

Logs and evidence:

- First Switch follow-up log: `run/net_logs/20261016-223841.log` (uploaded NRO reached frame 902).
- Switch run with the two intermediate seeds: `run/net_logs/20261016-230621.log` (reached frame 1,801 before the four newer seeds were added).
- Staged Switch build with Codex's seeds and `mkdir_tree()`: `analysis/elf_archive/conker-vulkan_d887d25b.{nro,elf}` (NRO MD5 `d887d25b28ac72a659ef358cec5f0e02`).
- Latest staged Switch build (NT-faithful directory statuses, 2026-10-17): `analysis/elf_archive/conker-vulkan_31500df5.{nro,elf}` (NRO MD5 `31500df543ad8c36edbae783793a383f`).
- Latest upload attempts: `run/net_logs/20261016-232929.log`, `run/net_logs/20261016-233056.log` (connection failed before runtime output).
- Linux runs: `run/conker-dev-test/seeded2.log`, `seeded3.log`, and `seeded4.log`; frame captures: `run/conker-dev-test/frames/`.

## 2026-10-17: first console run past the intro (NRO `31500df5`)

Build: NT-faithful directory statuses + Codex's seeds and small extended-VMA fallback
(`analysis/elf_archive/conker-vulkan_31500df5.{nro,elf}`). Log: `run/net_logs/20261017-002117.log` (third upload attempt; `20261017-001949.log` and `-002009.log` are the two failed ones).

| Observation | Evidence | Status |
|---|---|---|
| Upload failed twice before succeeding | 1st: `Connection to 192.168.1.248 failed` (NetLoader not open yet). 2nd: connected, then `recv: Connection reset by peer / Invalid response`, right after an `nc -z` probe of port 28280 (a probe connection seems to upset the NetLoader; don't probe it). 3rd upload worked | `tools/nxlink_run.sh` now runs nxlink under `script` so the log streams line by line (it arrived in 32 KB chunks through a pipe) |
| Boot, fresh `Z:` cache and audio-bank caching work on hardware | The game builds `Z:\texture...`, copies `sfx_*`/`cut_cash` wave banks to `Z:\audio`; 12 small extended-VMA commits fell back to shared memory (`[NX] small commit ... uses shared memory`, code-memory views refused with `0xCE01`) | working |
| Intro movie `dvddata\fmv\frontend\BootIntro.xmv` plays | 1.2 MB texture upload per frame, 10 draws; frames 50-117 ms early on (CPU-side XMV), `[fps] 28.5` at frame 366. The same movie renders correctly on the Linux bench (frame captures) | working; movie decode speed to look at later |
| **After skipping the intro: black screen with occasional brief flashes** (user report) | The game keeps running its 3D front end: 540-860 draws per frame at a steady 20 FPS (`[hitch]` 50 ms frames), frame 2,720 when the user quit; no `[ICALL]`, `[STUB]` or crash. 90 s watchdog: main thread in normal work (4.9 M indirect calls) | **open: renderer**. Game logic and pad input work; the draws do not reach the screen. Next: reproduce on the Linux bench (pad script to skip the intro), dump frames and intermediate surfaces, and take a `RECOMP_FRAME_TRACE` of a front-end frame to find the first wrong target (off-screen target + composite, as Burnout's world was, or unimplemented NV2A texture-shader modes) |

## 2026-10-17: black title screen on the Linux bench (renderer)

Reproduced the console's "black after the intro" on Linux by letting the game idle after `BootIntro.xmv`:
the in-engine title flythrough runs from about frame 3,700 to 6,500 (540–860 draws per frame), then
`attract.xmv` plays. Tools: `tools/live_linux.sh` (game in the background, pad presses appended to a file,
a frame dump every N flips) and the new draw-skip switches (see [07-debugging.md](07-debugging.md)).

| # | Symptom | Cause / evidence | Status |
|---|---|---|---|
| 1 | Whole flythrough black | Bisection by blend mode: `RECOMP_SKIP_BLEND=306/0` (skip `DST_COLOR × ZERO` draws) brought the picture back. Those are three projected-shadow passes multiplying the screen by 128×128 / 64×64 shadow maps. The maps are **R5G6B5** surfaces (`SET_SURFACE_FORMAT` 0x07070213: colour format 3, swizzled 128×128) cleared with `0x0000FFFF`, white in R5G6B5; the renderer keeps every colour surface as ARGB8888 and used the raw value, so the maps were cyan (surface dump) and the multiply turned the scene black | **fixed**: `clear_color_argb()` in `nv2a_pb_exec.c` widens R5G6B5 / X1R5G5B5 clear values before the back end sees them. First flythrough frames (rainy cobblestones) now draw |
| 2 | From frame ~4,300: a black 256×256 picture | Frame dumps were 341×256 instead of 853×480. `vk_flip()` presented `s_last`, the last surface drawn **or cleared**; after compositing its glow onto the back buffer the game clears its 256×256 glow target (`80CEC180`), so that was shown | **fixed**: `vk_flip()` presents the last surface drawn in the frame (`s_last_drawn`), falling back to the last one touched |
| 3 | Still black (now full size), and even "good" frames only show the ground next to the camera | Forcing the back-buffer clear to red (temporary hack) gave red frames with only a vignette and rain: the scene geometry is **not rasterised at all**, not drawn black. Skipping every draw after the opaque ones (`RECOMP_SKIP_DRAWS=263-999`) changes nothing. Combiner, fog (linear, enabled, colour `FF43628F`, params 1/1), blend and depth state of the opaque draws are identical in a good frame (4,050) and a black one (4,847). Every scene draw has `SET_CONTROL0` = `0x00100001`; `SET_ZMIN_MAX_CONTROL` = 1. Earlier CPU vertex traces show scene `oPos.z` values around 14–27 M against clip max 16,777,215, and mostly negative actual `oPos.w` for some groups. | **open; cause under review**. Earlier bit-20/W-buffer interpretation was incorrect: the vendored header defines `Z_PERSPECTIVE_ENABLE` at bit 16, which is clear in this value; bit 20 is not defined there. Clear bit 16 may imply W-depth, but confirm semantics before implementing. The clip trace is 0..16,777,215. See the reassessment below and [14-port-status.md](14-port-status.md) |

**Reassessment (2026-10-17):** the first diagnosis misidentified bit 20 of `SET_CONTROL0` as
`Z_PERSPECTIVE_ENABLE`. The vendored header places that named bit at bit 16 (`0x00010000`), so the
observed `0x00100001` has the named bit clear and bit 20 set but undocumented in that header. The trace
does confirm the clip range and shows vertex-program output values beyond it, but does not by itself
prove which depth representation the hardware is using or that depth clipping is the only cause. The
current investigation is to compare generated vertex output and clip conversion against xemu, and confirm
the NV2A state semantics before changing depth behavior.

**Full-draw position trace (2026-10-17, Linux frame after flip 4655):** the corresponding 640×480 frame
dump is black. The new `[FTRACE POS CPU]` diagnostic runs the CPU position interpreter for every submitted
index and reports positive-`oPos.w` bounds separately; it is an estimate, not GPU readback. Of 213 draws
to back buffer `80964000`, 181 had more than four indices (82,750 indices total). Their CPU-estimated
positive-`oPos.w` positions had no vertices inside the 640×480 bounds; only 6 draw bounds intersected the
screen, covering 4,722 indices. Of 53,043 positive-`oPos.w` positions, 45,640 were within the captured
depth interval. This makes VSH position/clip conversion the next comparison target, but does not establish
that Vulkan produced the same positions or that depth is the cause.

**Depth A/B probes (2026-10-17, Linux `conker-dev`):** added runtime-only Vulkan switches
`RECOMP_VK_NO_DEPTH=1` (disables tests and writes globally) and `RECOMP_VK_DEPTH_ALWAYS=1` (keeps enabled
tests and writes, but forces the compare op to ALWAYS). Both builds completed. The no-depth run remained
black at frame 4,800 (frame 3,840 showed only rain); the depth-always run was black at frames 3,780,
4,020 and 4,320. These broad overrides did not recover the scene, but they are not conclusive: they also
change shadow-pass visibility and/or scene draw ordering. Keep both off by default and do not mark the
depth issue resolved. The scoped follow-up below preserves shadow and post-process depth behavior.

**Scoped depth probes (2026-10-17, Linux `conker-dev`):**
`RECOMP_VK_DEPTH_ALWAYS_OPAQUE=1` forces the compare function to ALWAYS only when blending is disabled
and the target is a full-size surface; depth writes stay enabled, and shadow/glow targets keep their
original compare function. It exposed floor/room geometry in captured frames 3,780, 4,020 and 4,140;
frame 4,320 remained black. `RECOMP_VK_DEPTH_GREATER_OPAQUE=1` applies GREATER to the same draw class:
frame 3,780 showed the room, but frame 4,020 was black, as were frames 4,140, 4,320 and 4,530. The
normal depth comparison therefore rejects visible opaque geometry in at least some views, but changing
the compare op alone does not prevent the later blackout or establish the correct depth function. The
debug switches log the first target surface and are off by default. A later default-state trace found the
main depth clear and compare state unchanged across the late blackout; compare generated VSH positions
with the CPU estimate next.

**Depth-state trace (2026-10-17, Linux `conker-dev`, frames 4,120–4,340):** added
`RECOMP_VK_DEPTH_TRACE=<first>-<last>` to log depth clears and opaque full-size draw state in a selected
Vulkan frame window. The main scene alternates color surfaces `80964000` and `80A90000` against ZETA
`80BC0000`; each frame clears depth to `1.0` (`0xFFFFFF` of `0xFFFFFF`) with compare `0x203` (LEQUAL),
depth test and writes enabled, `SET_ZMIN_MAX_CONTROL=1`, and clip range 0..16,777,215. This state is
unchanged across the window, including the baseline black captures at frames 4,140 and 4,320. The late
blackout is not explained by a change in depth clear or compare state. This does not rule out invalid or
out-of-range generated vertex depth; the next comparison is generated Vulkan VSH output against the CPU
position estimate for the same draws. The scoped trace itself compiled and completed through frame 4,381.

**First black-frame position trace and attribute-path A/B (2026-10-17, Linux `conker-dev`, flip 4,321):**
the matching frame 4,320 capture is fully black. The per-draw CPU vertex-program estimate covered 497
back-buffer draws (`80A90000`, 139,085 indices): only three index positions were inside 640×480, one
from each of three full-screen composite quads; no world-geometry positions were inside the view. Of
50,028 estimated positive-`oPos.w` positions, 45,092 were within the recorded depth interval. This is
the CPU interpreter's estimate, not Vulkan shader output or GPU readback, so it does not prove the GPU
received the same positions. A second frame 4,320 run with `RECOMP_GL_DIRECT=0` (forcing Vulkan to use
the converted attribute path) was also black and showed the same pattern: 498 draws / 139,402 indices,
three in-view positions from full-screen quads, and no in-view world geometry. This makes the direct
vertex-format path an unlikely sole cause, but does not rule out a shared input or vertex-program
translation issue. Next compare CPU-interpreted `oPos` to generated Vulkan VSH output for matching
attributes and draws before changing depth behavior.

**Cross-backend reproduction (2026-10-17, Linux `conker-dev`):** rebuilt `build/linux-gl` from the current
source and ran the same title route. The OpenGL dump at frame 4,320 is also fully black; frames 4,313–4,326
continued submitting roughly 540–732 draws per frame. Together with the Vulkan capture, this shows the
late black scene is not Vulkan-specific. The renderers share CPU-side vertex-program state and GLSL
translation, so compare those shared inputs and generated positions before pursuing API-specific depth or
raster behavior. OpenGL GPU-position readback is now available; it does not directly verify Vulkan or
Switch output.

**VSH reference check (2026-10-17):** upstream xemu's programmable VSH tail converts screen-space x/y to
clip-space, scales z by the programmed clip maximum, and multiplies xyz by clip w
([`vsh-prog.c`](https://github.com/xemu-project/xemu/blob/master/hw/xbox/nv2a/pgraph/glsl/vsh-prog.c),
[`vsh.c`](https://github.com/xemu-project/xemu/blob/master/hw/xbox/nv2a/pgraph/glsl/vsh.c)). The port's
generated Vulkan path has the same broad conversion shape. This source comparison is not a per-draw output
match; the OpenGL result below supplies a per-draw comparison for the tested frame.

**OpenGL VSH output capture (2026-10-17, Linux `conker-dev`, frame after flip 2667):** added
`RECOMP_GL_VSH_TRACE=1` to capture the generated programmable vertex shader's `oPos` and
`gl_Position` through transform feedback on the next `RECOMP_FRAME_TRACE` frame. The first readback was
invalid because unbinding transform-feedback index 0 also cleared the generic buffer binding; rebinding
the buffer before `glGetBufferSubData` fixed it. On black frame 2668, the GPU readback covered 47 triangle
batches to the 640×480 back buffer. For the 2,382-index world batch, CPU and GPU both reported 1,537
positive-`oPos.w` vertices, zero inside the view, and nearly identical bounds (CPU
`-16366.1,-132156.5:-79.2,785.6`; GPU `-16366.2,-132157.4:-79.2,785.5`). The 1,830-index batch also
matched (CPU `-7750.0,-61827.4:-129.1,378.5`; GPU `-7750.0,-61827.6:-129.1,378.4`). Sampled `oPos`
and clip-space values agreed too. The in-view rectangle was a full-screen post-process quad, not world
geometry. This verifies that OpenGL VSH outputs match the CPU estimate for these draws and that the
missing world geometry is projected outside the viewport in this view. It does not identify whether the
shared guest attributes, VSH constants, program state, or camera state is wrong, and it does not directly
verify Vulkan or Switch GPU output. Next inspect those shared inputs and state and compare the same guest
frame with a reference implementation before changing depth or clip behavior.

**Corrected OpenGL VSH capture (2026-10-17, Linux `conker-dev`, black dump frame 2100):** the first
triangle-strip probe replayed the batch as triangle lists, which duplicated strip vertices in transform
feedback and still rasterized the diagnostic draw. Reworked it to replay the same index sequence as
`GL_POINTS` with `GL_RASTERIZER_DISCARD` enabled. This captures one generated vertex per input index and
does not write pixels during the probe. The 640×480 frame dump remains fully black. For the 747-index
world batch, `[FTRACE POS CPU]` reports 747 negative-`oPos.w` positions; the GPU point capture reports
zero positive-w positions. For the 1,082-index batch, CPU reports 1,002 negative-w and 80 positive-w
positions, zero inside the view, and positive-w bounds `-31283.3,-247017.6:-483.7,-2521.8`; GPU reports
the same 80 positive-w positions, zero in view, and bounds `-31283.1,-247015.9:-483.7,-2521.8`. The
frame trace is after flip 2104 and the GPU capture labels it frame 2105. These per-index results confirm
the CPU/GPU position match for these two OpenGL batches, with world vertices far outside the viewport.
They do not identify whether the shared attributes, constants, camera state or another guest-side input
is wrong, and they do not verify Vulkan or Switch output. The 747-index batch's attributes, VSH program
and constants were dumped for the next comparison. Decoding the 33-slot program shows no MAC ARL
instruction (opcode 13); upstream xemu maps opcode 13 to ARL and uses the same `floor(src + 0.001)` bias
as the port, so ARL rounding is not implicated for this batch ([reference](https://github.com/xemu-project/xemu/blob/master/hw/xbox/nv2a/pgraph/glsl/vsh-prog.c)).
Other instruction semantics and guest inputs remain to be checked. The issue remains open.

**Final scoped depth probe (2026-10-17, Linux `conker-dev`, Vulkan, black dump frame 2100):** rebuilt
`build/linux-vk` from current source and reran the scripted title route with
`RECOMP_VK_DEPTH_ALWAYS_OPAQUE=1`. The log confirms the override forced `ALWAYS` only for opaque draws
to full-size surfaces. The 640×480 frame 2,100 capture is still completely black; frame 2,101 submitted
700 draws. The run continued through at least frame 2,792 without a recorded exception or renderer crash,
then was stopped after the target capture. This rules out opaque depth rejection as a sufficient fix for
this menu view; it does not rule out clip rejection, guest-state errors, other depth behavior, or a
Switch-specific difference. No NRO was uploaded.

Draw structure of a flythrough frame (useful for later bisection): ~30 draws into the three shadow maps
(`8224F900`, `82257980`, `8225FA00`), ~230 opaque scene draws into the back buffer (`80964000` /
`80A90000`, alternating), ~270 alpha-blended ones, three `DST_COLOR × ZERO` shadow passes, then the glow
chain: back buffer → 256×256 `80CEC180` → 128×128 `80D4C280` → blur into 128×256 `80D2C200` → added back
with `ONE/ONE`, plus one `SRC_ALPHA/ONE` full-screen quad. The final combiner of the scene draws is
`13030C00` = `fog.a·fog.rgb + (1 − fog.a)·R0`, i.e. Conker's fog alpha is the fog *amount*, the reverse of
D3D's default final combiner (worth remembering if fog ever looks inverted).

Also on 2026-10-17 (commit 6ab1239, before the renderer work above): the console log showed extended-VMA
commits refused with `0xCE01` when the game re-commits a growing range from one base (12 KB, then 132, 144,
192 KB at the same address). The Switch `VirtualAlloc` only recognises a range inside one existing mapping,
so the second commit re-mapped pages already mapped. `extvma_commit()` in `guest_vmem.c` now commits whole
2 MB granules once and keeps them; the Horizon shared-memory fallback ceiling went from 128 KB to 2 MB. NRO
`analysis/elf_archive/conker-vulkan_dc06e7ee.nro` has it; not yet run on hardware.

## 2026-10-17: console run of NRO `3f85b158` (commit d386a80)

Log `run/net_logs/20261017-020541.log` (the first upload attempt, `-020451.log`, failed to connect: the
NetLoader was not open yet). Boot and intro as before; after skipping the intro the screen stays **black with
the menu music playing**. 20 FPS (50 ms frames, 605–669 draws), frame 1,553 reached (the user quit), no `[ICALL]`, `[STUB]` or
exception. No `0xCE01` and no shared-memory fallback at all: the 2 MB extended-VMA granules (6ab1239) are
verified on hardware. The black picture matches the unresolved Linux renderer problem; the depth/clip
cause has not been established, so a console-specific cause remains possible.

## 2026-10-17: corrected OpenGL VSH capture and final Vulkan depth probe

The OpenGL dump at frame 2,100 was fully black. The first triangle-strip transform-feedback diagnostic
replayed strips as triangle lists, duplicating vertices and rasterizing its probe. The corrected version
replays the same index sequence as `GL_POINTS` with `GL_RASTERIZER_DISCARD`, capturing one result per index
without changing the frame. On the 747-index world batch, the CPU estimate had 747 negative-`oPos.w`
positions and GPU capture had zero positive-w positions. On a 1,082-index world batch, CPU and GPU both had
80 positive-w positions, none inside 640×480, with bounds `-31283.3,-247017.6:-483.7,-2521.8` (CPU) and
`-31283.1,-247015.9:-483.7,-2521.8` (GPU). This confirms those sampled OpenGL outputs match the CPU
interpreter and lie outside the viewport. The 33-slot program has no MAC ARL instruction, so ARL rounding
does not explain this batch. Guest attributes, constants and camera state remain unverified against a
reference; OpenGL capture does not verify Vulkan or Switch output.

The final Linux Vulkan probe rebuilt `build/linux-vk` in `conker-dev` and ran the scripted title route with
`RECOMP_VK_DEPTH_ALWAYS_OPAQUE=1`. The 640×480 frame 2,100 dump remained black; frame 2,101 submitted 700
draws. The process reached at least frame 2,792 without a recorded renderer crash or guest exception. This
shows that forcing opaque depth comparisons to pass is not enough to recover this view. No NRO was uploaded.

## 2026-10-17: reference-port review for the missing scene

Reviewed the current engineering notes for [NFS Underground](https://github.com/antoxa2584x/nfsu1-sw),
[NFS Underground 2](https://github.com/antoxa2584x/nfsu2-sw),
[NFS Carbon](https://github.com/antoxa2584x/nfsc-sw), and
[Burnout 3](https://github.com/antoxa2584x/burnout3-sw), then checked the Xbox section of
[SwitchPorts](https://github.com/robzilla10001/SwitchPorts). SwitchPorts is a discovery and release-status
list, not a renderer-debugging source; it listed the four requested projects as Xbox-to-Switch ports. The
list also surfaced [FlatOut 2](https://github.com/antoxa2584x/flatout2-sw), another port from the same
maintainer/toolkit lineage, so its engineering notes were checked for renderer overlap.

| Reference-port finding | Relevance to Conker | Current-source comparison / result |
|---|---|---|
| **NFSU2 black loading screen:** methods from all pushbuffer subchannels were written into the 3D register shadow. An NV062 blit method at `0x0308` aliases NV097 `SET_CULL_FACE_ENABLE`; the loading-screen state then culled every quad. The fix was to update the 3D shadow only for subchannel 0. | Close symptom match and a straightforward state-path check, but not evidence Conker has the same active fault. | The current Conker executor already gates 3D shadow writes on `subch == 0` and returns for other subchannels. The current black-frame notes do not record cull enable/mode/front-face values or their originating subchannels. Capture/inspect those before ruling out a title-specific or runtime state issue. |
| **NFSU2 Vulkan front-face error:** a backend winding inversion discarded front-facing menu-car, wall and object draws. Pixel readback after each draw in matching GL/Vulkan frames found it. | Can remove surfaces while draws continue, though it does not explain measured world positions tens of thousands of pixels outside the view. | Current `nv2a_vk.c` already has the reference mapping (NV2A on-screen CW to Vulkan CW; GL's window orientation differs). Verify Conker's actual cull state and target pixels for a representative missing draw. |
| **NFSU2/Carbon clip-z error across the eye plane:** per-vertex clip-z clamp distorted interpolated depth for large triangles near or behind the eye. The Vulkan path was corrected to use depth clamp when available and avoid the invalid behind-eye clamp. | Relevant to Conker batches with negative `oPos.w` or triangles crossing the eye plane; not an explanation by itself for the sampled positive-w vertices far outside x/y bounds. | Current `gl_vsh.c` already has separate Vulkan clip paths based on depth-clamp support. Existing Conker GL capture does not validate matching Vulkan positions, and the final Vulkan report did not record feature availability; keep this as a scoped follow-up. |
| **Burnout 3 early black scene / missing composite:** incomplete combiners, texture stages, fog, alpha test and immediate attributes caused black-looking or absent outputs; one final composite lost its scene because immediate-mode `SET_VERTEX_DATA2F_M` slot 0 was ignored. | Important after confirming geometry reaches rasterization or a required composite is absent. Current Conker GL captures show an in-view full-screen quad but world vertices outside the view. | Conker's renderer supports register combiners, four texture stages and all 16 immediate attributes. Bump/dot-product texture modes remain missing; census those draws after positions are in view. |
| **NFSU1 aspect-ratio adaptation:** adjusts projection terms differently for race/front-end views and derives frustum culling from the adjusted projection. | Useful for later ratio tuning, not a current fix: the user accepts an aspect mismatch and that cannot account for extreme off-screen coordinates. | Keep aspect-ratio work deferred until geometry projects near the viewport. |

**Additional SwitchPorts lead: FlatOut 2.** Its notes independently report the R5G6B5 shadow target cleared
with `0xFFFF` (the same format-sensitive clear class already fixed in Conker) and a Vulkan bloom feedback
loop where a draw sampled the scene surface it was writing, producing wavy shimmer; the port snapshots the
target before that draw. The feedback-loop fix is only relevant to Conker if a traced draw reads from its own
color target. The current glow-chain summary names several separate surfaces but does not establish a
same-target read/write for a specific draw, so this is a trace check rather than a diagnosis.

The code already contains the strongest NFSU2 subchannel and front-face fixes, so duplicating them is premature.
The next targeted check is actual cull enable/mode/front-face state, with subchannel IDs retained. Then continue
the guest attribute, VSH-constant and camera comparison. For eye-plane cases, record whether Vulkan depth
clamp is active and compare the same draw across GL/Vulkan. Do not revive the disproved `SET_CONTROL0` bit-20
W-buffer interpretation. No source code was changed during this research review.

## 2026-10-17: black front end solved: `fincstp` was not translated

Starting point: Codex's captures showed world vertices tens of thousands of pixels off screen, identical in
the desktop GL vertex shader (transform feedback) and the CPU interpreter, so the shader back ends were fed
bad input. The `SET_CONTROL0` bit-20 w-buffer theory had already been withdrawn (`Z_PERSPECTIVE_ENABLE` is
bit 16). From there the cause was found in a few hours by following the transform constants back into the
game's CPU code:

| Step | What was done | Result |
|---|---|---|
| 1 | Disassembled the dumped 33-slot vertex program (a small NV2A VSH disassembler over the `[FTRACE VSH PROG]` tokens) | Positions are shorts × `c[109].x`, then model-view `c[96..98]`, projection `c[99..102]`, then the standard XDK screen epilogue (`c[58]`/`c[59]`). The projection was a sane right-handed perspective (near plane 10) |
| 2 | Logged `c[96..98]` for every programmable draw of one black frame and tested each 3×3 for equal row norms and orthogonal rows | 18 distinct matrices. The ~30 shadow-map draws (light views): orthonormal. All 458 world draws: one camera matrix with every row ≈ (0, 1, 0), cos(row 0, row 2) = 0.99, row 1 of length √2. Bit-identical at frames 4,173, 4,774 and 4,942 and across runs |
| 3 | Searched guest RAM for those floats with a tolerance, row- and column-major | 7 copies of the camera matrix in D3D layout, the first at `0x0076F8C0` |
| 4 | gdb hardware watchpoint on `0x0076F8C0` (stamp a different value first: watchpoints report changes only) | Copied there by `sub_000646A0` (`rep movsd`) from the per-viewport camera block `[0x762E44 + 4·viewport] + 64·n` (`0x742A58E0`). That block is written by `sub_0029BCA0`, called from `sub_00046490` |
| 5 | `sub_0029BCA0` is a look-at taking the eye in `xmm3`/`xmm4`/`xmm6` (register-passed) and target/up on the stack. Captured its inputs at entry with gdb (eye (−49.23, 165, −236.65), target (8, 180, 3), up (0, 1, 0)), emulated its x86 in Python and read the lifted function's output on return | Both correct and identical (x axis (0.973, −0.014, −0.232)…). The look-at was fine; something later overwrote its result (the watchpoint never fired for that write) |
| 6 | Matrix algebra: S = good⁻¹ · bad | bad = good · S with S degenerate (row 0 zero, row 1 = (0.995, 0.995, 0.995)): a post-multiply by a broken matrix. `sub_00046490`, when `[ebx+0xC0] == 0x40000`, builds a roll matrix with `sub_003E2E60(out, 1, 1, 0, angle, 0, 0, 0)` and multiplies it in with `sub_0042841D` |
| 7 | Captured `sub_003E2E60`'s inputs and output (another caller, angle 0.349 rad) | Output row 0 = 0; cos/sin of 20° scattered over the other rows |
| 8 | Read its x87: three `fsincos`, `fmul st(6)`, **`fincstp`** to set `cos·scale` aside, two pops, then `fmul st(6)` / `fmul st(5)` read it back | `gen/` had `/* FPU: fincstp */`: the lifter's fallback comment, i.e. a no-op, so the stack ran one slot off |

Fix (commit 1bc623e): `lifter.py` emits `g_fp_top = (g_fp_top + 1u) & 7u` for `fincstp` (and `+ 7u` for
`fdecstp`); `ffree` stays a tag-only comment; test in `test_lifter_fpu.py`. `LIFT_ONLY=1` regen: the XBE has
two `fincstp` sites, `sub_003E2E60` and `sub_00317F40`. **The title tavern renders** (Linux, NRO
`5c8b2369` built for the console).

Then on the Linux bench, with pad input through `tools/live_linux.sh press` (holds of 400 ms; 150 ms presses
were missed while the bench ran at ~5 FPS beside a Switch build): Start → Profiles → New Profile → typed
"a" → Create (saved to `UDATA\4d530051\000000000061\profile.bin`) → profile settings → the Xbox Live & Co
menu (Xbox Live, System Link, Dumbots, Profiles) → Dumbots → Solo → level select (Beach Dead) → team (Tediz)
→ class → lobby → Ready. Loading `Level\MPBeach` then stopped: `[ICALL] Failed to resolve VA 0x00359E00`,
a null function pointer, and the pushbuffer stopped moving. `0x00359E00` follows a jump table and `int3`
padding and tail-jumps to `0x00359FF0`, which starts right after `sub_00359F80`'s `ret`; both seeded, full
regen 21,284 of 21,286 functions.

Other x87 instructions still emitted as `/* FPU: ... */`: `fcmovnbe` ×2 (`sub_00458494`), `ficom`/`ficomp`
(`sub_0018DEC2`, probably data decoded as code), `fxtract` (`sub_00459020`), `fnsave`/`frstor`
(`sub_004716D8`), `fbld`/`fisttp` (data decoded as code), `fnclex` (harmless). The bring-up checklist's
"grep `gen/` for bare `/* mnemonic */` comments" missed `fincstp` because the x87 fallback prefixes
`FPU: `; grep for `/\* (FPU|SSE): ` as well.

Lesson: a black or empty 3D view with every back end agreeing is a CPU-side bug until proven otherwise.
Checking the model-view matrices for orthogonality would have pointed at the game's math a day earlier
than the depth/clip probes did.

## 2026-10-17: single-player campaign to the training level (Linux); hidden function entries

With the `fincstp` fix the title tavern is the menu: left/right pans between "Xbox Live & Co" and the save
slots ("Game 3" → New Game / Play, Erase). New game plays the opening in the engine: "A Rare Game / starring
Conker and Berri", King Conker on the throne, the Bad Fur Day logo, Berri's house and phone, the bar, the
castle at night, the Panther King; then `Level\TrainingLevel` loads and the stick moves Conker. The game
saved Game 3 on its own. Conker himself draws as a purple blob; the level and other characters look right.

Unresolved calls on the way, each a real function the static pass missed:

| Address | Where it bit | Why it was missed |
|---|---|---|
| `0x00359E00` → `0x00359FF0` | Dumbots level load (Beach Dead): `[ICALL]`, then a null function pointer, pushbuffer stopped | after a jump table and `int3` padding; its tail-jump target starts right after a `ret` |
| `0x0014FE60` | opening cutscene: crash in `sub_000D9950` reading `0xC3700014` | right after `sub_0014FE40`'s final `jmp [eax*4 + 0x597C58]`, so merged into it. Unresolved, its caller's stack slot kept a float (`0xC3700000` = −240.0) where a record pointer belonged |
| `0x00153340` | opening cutscene, later | right after a `ret`, referenced from a vtable in `.rdata` |

Rather than one regen per run, a static scan (`tools/hidden_entries`) lists every address referenced from
data or code that sits after a `ret`/`jmp` inside a known function or in a gap between functions, and vets
each one (referenced from outside its function, preceded by `ret`/`jmp`/`int3`/`nop`). 51 candidates, 32
accepted: 15 functions reached through vtables, tables or code immediates (including three D3DX
`this`-adjust thunks) and 17 SEH filter/handler blocks referenced from scope tables. Note for scanners: this
XBE sets the executable flag (`0x4`) on `.rdata` and `.data`, so section flags cannot separate code from
data; use the section names. Regen: 21,320 functions. After it the campaign ran from the opening to the
training level with no `[ICALL]`.

Console tooling for the performance work: the sampling profiler now also prints its 10 s window into the log
(`[profile]` lines, hottest 128-byte code granules per thread; `tools/prof_log_report.py LOG ELF` sums them
per function), and the 10 s `[perf]` report now runs under nxlink too (it only ran when logging to a file, so
no Wi-Fi run had it). NRO `e807fd88`.

## 2026-10-17: first hand-played console run; static, intro audio, tail and shadows fixed

The user played NRO `e807fd88` from boot to the training level (log `run/net_logs/20261017-064742.log`).
Gameplay was a steady 20.0 FPS (526 draws, game thread 28 % of a core, GPU executor 71 %, emulated vblank
26–33 Hz instead of 60) and felt smooth; the user asked to fix the visible and audible problems before
optimising. Each was reproduced and fixed on the Linux bench:

| User report | Cause | Fix |
|---|---|---|
| Brief "heavy rain / TV static" on menu selections, in the first cutscene, more often in gameplay | `apu_phys()` masked every APU address to 26 bits. DirectSound gives the APU `MmGetPhysicalAddress()` of its buffers, and for memory the game allocated above RAM (extended VMA, `0x74000000`) that is the VA passed through: a stream segment at `0x7415D7A0` was read from `0x0015D7A0`, the game's code | Addresses in `[0x08000000, 0x80000000)` are VAs (c130f84). Found by capturing the output (`RECOMP_AUDIO_DUMP`), measuring each 20 ms window's first-difference/signal energy ratio (white noise ≈ 2, music < 0.8), then a temporary per-voice detector in the voice processor that logged the noisy voice's format and stream-segment address: voice `v046`, 16-bit stereo stream, RMS 0.5 and ratio 1.8 (uniform random data) on segment `0x7415D7A0`, legitimate rain on segments in RAM |
| Intro movie audio lost within a second | The movie (four mono ADPCM stream voices) queues two 0.4 s segments per channel and refills only from completion callbacks. Its first frames stalled (frame 3: 4,270 ms on the console, 434 ms on Linux), so both segments drained, DirectSound paused the starved voices and the player never refilled. The stall is first-use shader and pipeline compilation (the Linux sampler shows lavapipe's LLVM busy while the main thread yields); the console run had prewarmed "0 programs, 0 pipelines" because the toolkit's cache folder was Burnout 3's `sdmc:/switch/b3x/`, hard-coded, which does not exist on this card | Cache folder from `XBOXRECOMP_SWITCH_DIR`, set to `sdmc:/switch/conker/` (0d9fb5c). To verify on the console: the first run fills the cache, the second should keep the intro audio |
| Tail is purple | The tail fur samples a 64×64 `SZ_A8Y8` (`0x1A`) and a 64×64 `SZ_G8B8` (`0x28`) texture; no decoder, so the magenta placeholder | Decoders for `AY8`, `A8Y8`, `G8B8`, `R8B8` with xemu's channel placement (9882f42); undecodable formats are now named once in the log |
| Two shadows following the character | The projected shadow maps (`PROJECT2D`, 128×128 R5G6B5) are sampled clamp-to-border with `SET_TEXTURE_BORDER_COLOR` `0x00FFFFFF`; Vulkan samplers always had a transparent black border, and the shadow passes multiply the scene (`DST_COLOR × ZERO`), so dark quads appeared wherever receivers reached past the map | Sampler takes the nearest fixed border colour, colour before alpha (d300139). A first attempt that chose by alpha first changed nothing; the frame trace's new stage-0 fields (`addr 00010404 border 00FFFFFF`) showed why |
| Some cutscene shots blurry | Probably the game's depth of field and the deliberately blurred hangover shot | Not changed; compare with footage of the original first |

Tooling added on the way: nxlink `KEY=VALUE` arguments are now applied inside `switch_boot()` (they came
after it had read the profiler, clock and log switches, so the profiled run had no profile); a Linux sampling
profiler (`RECOMP_LINUX_PROFILE=1`, `src/linux_prof.c`, 1 s windows, library code by symbol) printing the
console's `[profile]` format for `tools/prof_log_report.py --window-s 1`. A gdb-Python sampler with
`continue &`/`interrupt` does not work in batch mode (the thread is still running when the backtrace is
taken); the in-process `SIGPROF` sampler replaces it.

NRO with all of this: `analysis/elf_archive/conker-vulkan_ba31654d.{nro,elf}` (commit d300139).

## 2026-10-17: depth of field reads the real depth; fcmov and fxtract lifted

**Depth of field.** The post-process downsample (into the 256×256 target `80CEC180`) samples the back
buffer on stage 0 and the depth buffer `80BC0000` on stage 1, with stage 1's format `0x41`
(`LIN_R8G8B8A8`, a colour format) and an alpha test `≥ 8` deciding which pixels enter the blur. The game reads
its Z24S8 depth as raw bytes. Our depth is a Vulkan depth image that never reaches guest memory, so the
texture came from stale bytes and the blur mask was arbitrary: the likely cause of "some cutscene parts
blurry, some sharp". Fix (00f1cb4): depth images are samplable with a depth-only view; a texture whose address
is a depth buffer is a colour image refilled by a full-screen pass when the depth changed (a counter bumped by
depth writes and clears), holding the texels the guest's decode of the dword `(z24 << 8) | stencil` gives
(R G B = the depth's high, middle and low bytes; stencil not converted). The title tavern now blurs the
near foreground and keeps the bar sharp. Not compared with the original yet; to check on the console.

**x87.** `fcmovCC` (conditions from `g_fp_cmp`, as the jcc mapping) and `fxtract` are lifted (5fa8fb2); both
were comments in CRT math code (`sub_00458494`, `sub_00459020`).

**Incident.** A long bench run at `DUMPN=15` filled the disk with 9 GB of frame dumps; Docker Desktop hung
(every `docker` command blocked) and had to be force-restarted after freeing space. `live_linux.sh` now keeps
only the newest `KEEP_DUMPS` (300) dumps while running.

## 2026-10-17: Beach Dead plays; one more hidden entry; an intermittent class-screen freeze

- **Beach Dead.** With the first two seeds the level loaded, then logged `[ICALL] Failed to resolve VA
  0x0019D3C0` and crashed. That function starts right after the jump table that ends `sub_0019CE40` (last
  entry `0x0019CE92` at `0x0019D3BC`), referenced from `.rdata` `0x0058EE78`. The hidden-entry scan had
  missed it twice: its gap rule wanted the entry within 64 bytes of the previous function's end, and its
  vetting wanted a `ret`/`jmp`/`int3`/`nop` before it. Both now also accept an entry after a jump-table
  dword pointing back into the previous function; the rescan found exactly this one. Seeded, full regen
  (21,321 functions); Beach Dead then ran two minutes of bot play with no `[ICALL]` or crash (a6f9ff2).
  The bunker interior looks strongly red; not compared with the original yet.
- **Class-screen freeze (intermittent).** Once, after pressing up to change class, frames stopped: the main
  thread sat in D3D's GPU wait (`sub_0053C190` from `sub_00218220`) on the event the PGRAPH handler sets,
  while the GPU executor was idle. Six more class changes with `CONKER_D3D_TRACE=1` did not reproduce it.
  Recorded in the status as a lost wake-up to chase with the watchdog.

## 2026-10-17: console run of NRO `688d985e`; version 0.8

The user played the build with every fix so far (log `run/net_logs/20261017-145325.log`): the static is gone;
the cutscene blur is still there (the depth-of-field change did not fix it); main-menu transitions are a bit
slow; the frame rate drops a little when the camera moves; some very minor stutters remain. The launch
arguments now reach the profiler (`[prof] sampling ...` in the log). This state was tagged **v0.8** (NRO
version 0.8). Next: performance, using the hardware better rather than lowering quality.

## 2026-10-17: 30 FPS on the console: vertex attributes unpacked on the GPU

The console profile of the training level on NRO `688d985e` (`RECOMP_NX_PROFILE=1`, read with
`tools/prof_log_report.py`) had the GPU executor at about 80 % of a core and the game thread well below a
core, so the executor set the pace. A fifth of the executor's time was spent converting vertex attributes
on the CPU, per vertex and per draw: CMP (packed 11:11:10) normals through `fetch_attr` (~13 %) and formats
NVK cannot fetch as stored through `attr_to_float4` (~9.5 %), each result copied again as 16 bytes. A new
`[profile-lr]` table (samples by caller, `--callers`) charged the `memcpy`/`memcmp` leaves to their callers.

Commit f67d461 moves that work into the vertex shader. CMP normals are fetched as one R32 lane (back-end
flag `NV2A_BACKEND_RAW_CMP`) and unpacked by `nv2a_cmp()`; formats the device cannot fetch get a fetchable
neighbour and a fix-up (three components fetched as four with w forced to 1, D3DCOLOR fetched as RGBA and
swapped back). The three fix-up masks travel in the vertex uniform block and `nv2a_inputs()` in the Vulkan
prelude applies them. Startup logs which NV2A vertex formats the device cannot fetch as stored.

Console run of NRO `0678347d` (log `run/net_logs/20261017-152423.log`): 30.0 FPS in 34 of the 10-second
windows, 29–30 in most of the rest; executor about 43 % of a core, game thread about 59 %. The user: menu
transitions a lot smoother, gameplay better and more stable; left are very very minor stutters, the blurry
cutscene shots, and missing loading screens between sections. The emulated vblank counter read 3–7 Hz in
gameplay while the game held 30 FPS, to be understood before trying for 60.

## 2026-10-17: loading screens are drawn into the front buffer, never flipped

The user saw the game freeze for a couple of seconds where a loading screen belongs (entering the area with
the first weapon in the training level). Linux repro: loading the training level from the profile menu gave
one presented frame of 13.6 s with 13,400 draws. `RECOMP_SURF_STATS=1` (new: for any frame over 2,000
draws, draws per surface, scan-out address, control methods and draw runs) showed the draws split evenly
between the two framebuffers `80964000` and `80A90000`, alternating one at a time, with one flip in the
whole frame and the scan-out (`PCRTC_START`) parked on `80A90000`. `RECOMP_FRAME_TRACE_DRAWS=3000-3011`
(new: frame-trace a draw range of every frame, which reaches inside a long frame) showed each pair: a
progress-bar sliver alpha-blended into the back buffer, then a full-screen 640×480 copy (ONE/ZERO) of the
back buffer into the front one, then a fence.

So the loader updates the screen by drawing into the buffer the CRTC scans out; the hardware shows it at
every vblank, the renderer only presented on flips. Fix: `scanout_present()` in `nv2a_pb_exec.c`
presents the scanned-out buffer after a draw into it when the last flip is at least 100 ms old, at most
every 33 ms (`RECOMP_SCANOUT_PRESENT=0` turns it off; normal frames never draw into the scanned-out buffer,
and the 100 ms rule keeps a half-drawn frame from being shown). The Linux bench now shows the "Loading..."
screen with its progress bar; NRO `084306cc` carries it to the console.

## 2026-10-17: cutscene depth of field reads the depth in its own byte order

The cutscene blur was still there on the console after the depth-as-texture change. Frame traces armed every
2 s through the training level's wake-up scene (`RECOMP_FRAME_TRACE` re-armed in a loop; cutscene frames have
~272 draws and two draws that sample the depth, gameplay frames 753 and one) found a second reader of the
depth buffer: a full-screen pass into the back buffer, blend ONE / ONE_MINUS_SRC_ALPHA, alpha test `> 0`,
stage 0 = depth `80BC0000` as format **0x3F `LIN_A8B8G8R8`**, stage 1 = the blurred 128×128 `80D4C280`. The
glow pass reads the same buffer as 0x41 `LIN_R8G8B8A8`, the only order the conversion wrote.

`RECOMP_PSH_DUMP=1` gave its six combiner stages: `R0 = T0 − c0` with `c0 = 0xED000035` (alpha: depth high
byte − 0xED; blue: middle byte − 0x35), alpha × 4 × 4, plus a scaled `R0` and the blue term (a 16-bit depth
compare built from 8-bit combiners), then `(2a − 1)²`; the final combiner outputs `a × blurred` with alpha
`a`. So the focus depth gives `a = 0` (sharp) and both sides blur. In 0x3F the alpha channel is the depth's
high byte; the conversion had put the stencil (0) there, `R0.a` went to −1 and the square made `a = 1`:
every pixel took the blurred image whenever a shot used the effect.

Fix: `depth_as_texture()` writes the dword's four bytes in memory order and `depth_texture_view()` hands each
guest format a view with its decode as a component swizzle (0x41, 0x3F, 0x40, 0x12, 0x1E; the glow pass's
0x41 texels are unchanged). On the Linux bench the wake-up scene now opens blurred (waking up), then keeps
Conker sharp with the near flowers and the background soft; before, the near grass was sharp and Conker
blurred. NRO `084306cc` carries this and the loading-screen present to the console.

## 2026-10-17: console run of NRO `084306cc`; cutscene depth of field off by default

The user played further than before (log `run/net_logs/20261017-163543.log`): TrainingLevel, TrainingCave,
ThroneRoom, Windmill, with no crash or `[ICALL]`. Gameplay "better than ever"; the training-area loads no
longer freeze (the scan-out present ran; no multi-second frame on those loads). Some cutscenes are clear now
(talking with Birdy) but others still blur the whole screen. Only `BootIntro.xmv` is opened in the whole run,
so every cutscene is in-engine and the blur is the game's depth of field as we draw it. At the user's
request it is off by default: `RECOMP_DOF=0` (set in `src/main.c`) makes the executor drop any draw that
samples the depth buffer it is bound to, which in Conker is only the depth-of-field composite (the glow
pass reads the depth with no depth buffer bound). `RECOMP_DOF=1` brings it back for further work. Linux bench
check: the training level's wake-up scene is sharp from the first shot after waking, speech bubbles
readable; only the opening "eyes opening" shot stays soft (a separate, apparently deliberate effect).
Console build: NRO `cfd4c805`.

Frame rate: 25–30 FPS in the training level with 20 FPS stretches (executor ~70 % of a core), 24–25 FPS in
Windmill (game thread 65–91 %). First visits to ThroneRoom and Windmill stalled 4–6 s compiling 18–20
shaders. The guide's newer optimisation findings (fourth core, console PGO, LTO, code ordering, executor
copies) are recorded as candidates in [06-performance.md](06-performance.md).

## 2026-10-18: first single-player Switch crash captured (NRO `cfd4c805`)

The user played the newly sent NRO in single-player and reported a crash. `tools/nxlink_run.sh
192.168.1.248` captured the run at `run/net_logs/20261018-001825.log`. It was launched without `ARGS` and
without `conker_env.txt`; startup logged that default settings were used. The app reported title-override
full-memory mode with 3,189 MB available, so the crash was not caused by a missing launch argument or
applet-mode memory limit.

The game reached frame 1,466. Its last frame took 417 ms and drew 416 calls. The preceding performance
windows reported 18.8, 25.0 and 22.8 FPS; heap use was 571–572 MB. There was no `[ICALL]` or `[STUB]`
report before the crash.

Crash report:

```text
[CRASH] exception 257 at PC=0x1ca9dc5de8 far=0x68e2b1cff0 (guest VA 0xFFFFFFF0)
  guest: eax=00000000 ecx=00000000 edx=010FF7E8 ebx=00000000
         esi=7419D860 edi=FFFFFFE0 esp=010FF754
```

Using the logged `switch_boot` address and the archived ELF's symbol value to account for the PIE load
bias, the native PC resolves to `sub_00355430 + 312` at `gen/recomp_0046.c:20736`. That instruction reads
the first argument's object at `+0x10`. The crash registers show `EDI=0xFFFFFFE0`, and the reported guest
fault address is `0xFFFFFFF0`, matching that read. The stack's innermost recorded return address is
`0x00355C91`; the following entries include `0x003DC9EB`, `0x003DC2F7` and `0x003DC09A`.

Tracing the caller showed that `sub_00355B40` passes the result of `sub_00354610` directly to
`sub_00355430`. The helper scans 32-byte entries, starting its best index at `-1`; when no candidate
matches, it returns `base - 32`. In this run the collection base was null, so the result was
`0xFFFFFFE0`. That is the invalid object pointer observed in EDI. The earlier `g_seh_ebp` hypothesis was
incorrect: this read uses the function argument, not an inherited frame pointer.

An initial manual guard was added at generated label `loc_00355C85` in NRO `3260c845`: it compared the
returned pointer against `base - 32` and skipped recursion on that sentinel. It tried to obtain the base
by loading the parent pointer saved at `[esp + 0x40]` and dereferencing its `+0x10` field. That version
compiled, but the next hardware run exposed that this parent pointer can itself be invalid during the
recursive walk; the guard caused a second crash. The guard is revised below. Generated output is ignored
by Git, so the revised guard is also added to the tracked `tools/regen.sh` regeneration path. The
exception logger did not need an EBP change to diagnose either crash.

## 2026-10-18: second Switch crash in the sentinel guard (NRO `3260c845`)

After the first crash was diagnosed, NRO `3260c845` was sent to `192.168.1.248` with no launch arguments.
The Switch used its default settings and title-override full-memory mode (3,189 MB reported). It loaded
front-end assets and opened `BootIntro.xmv`, then crashed before this run could verify the intro aspect,
audio, or single-player gameplay. The log is `run/net_logs/20261018-005259.log`; no `[ICALL]` or `[STUB]`
report preceded it.

```text
[CRASH] exception 257 at PC=0x54f47dfdb4 far=0x6121b08cf6 (guest VA 0x434C9CF6)
  lr=0x54f47dfd5c sp=0x2b8bdc8780
  guest: eax=74258240 ecx=74258240 edx=010FFE0C ebx=00000002
         esi=7417D560 edi=01292600 esp=010FFE34
  guest stack return addresses: 0x00354017, 0x002A56FD, 0x002A4910, ...
```

The runtime `switch_boot` address was `0x54f277f750`; its ELF symbol is `0x9e750`. Applying that PIE
load bias resolves the faulting PC to ELF address `0x20FEDB4`, inside `sub_00355B40`, at the guard's
`MEM32(ecx + 0x10)` read in `loc_00355C85`. The reported guest address is the invalid value loaded from
the saved parent plus `0x10` (`0x434C9CE6 + 0x10`). This confirms the initial guard itself faulted while
trying to recover the collection base through an invalid parent pointer; it is a separate crash site from
the original `0xFFFFFFF0` access in `sub_00355430`.

The guard now saves the exact collection base already loaded into `eax` immediately before the helper
call, in the caller's unused stack local `[esp + 0x3C]`. After `sub_00354610` returns with `ret 8`, it
compares the returned candidate directly to the saved input base minus 32. If they match, it takes the
existing no-child path; it never dereferences the potentially invalid parent pointer. The tracked
`tools/regen.sh` now reapplies this guard after code generation. `bash -n tools/regen.sh` passes; a full
regeneration was not run. The original single-player crash is not yet considered resolved until the
revised guard reaches gameplay without another exception.

## 2026-10-18: revised recursive-walk guard built and sent (NRO `f976b53f`)

The `conker-dev` Linux build completed with `cmake --build build/linux-vk -j2`. Its live run
(`run/live/run.log`) advanced through frame 3,882; the last reported windows were about 59 FPS. The log
contained no `[CRASH]`, `[ICALL]`, or `[STUB]`. The test container was stopped after that run.

The Switch build completed with `VULKAN=1 STAGE_GAME=0 JOBS=2 ./switch/build.sh`. NRO MD5 is
`f976b53fd542cc4e82b0fbe5d76ad550` (short ID `f976b53f`); the archived pair is
`analysis/elf_archive/conker-vulkan_f976b53f.{nro,elf}`. `tools/nxlink_run.sh 192.168.1.248` sent and
started it with no launch arguments. The Switch used default settings and title-override full-memory mode
(3,189 MB reported). Its log, `run/net_logs/20261018-005801.log`, shows `BootIntro.xmv` opened and reached
frame 2,149 without a `[CRASH]`, `[ICALL]`, or `[STUB]`; the nxlink log stream was still connected at the
last check.

This confirms the revised guard gets past the startup crash seen on NRO `3260c845`, but it does not yet
close the single-player crash issue: the user has not replayed the route that crashed at frame 1,466 on
`cfd4c805`. The 4:3 intro presentation is included in `f976b53f` but still needs visual confirmation on
hardware. The intro audio investigation remains unresolved; no audio fix was included.

## 2026-10-18: intro video aspect and audio follow-up

The intro source `BootIntro.xmv` is 640×480 (4:3), WMV2 video with four mono 44.1 kHz Xbox ADPCM audio
tracks. The renderer trace identified the sampled XMV frame as a 640×480 YUY2 texture (NV2A format
`0x24`, pitch 1280; `0x25` is the alternate UYVY layout). A per-frame check now recognizes either layout
and suppresses the gameplay widescreen expansion for that frame in both GL and Vulkan. That presents the
frame at the source's 4:3 aspect without changing gameplay presentation. The Switch NRO `3260c845` was
built and archived as `analysis/elf_archive/conker-vulkan_3260c845.{nro,elf}`; hardware aspect verification
is pending.

The audio investigation narrowed the silence to stream refill. The XMV contains 227 packets and later audio
data for all four tracks; the game initially queues only the first two ADPCM packets per track (about 0.9
seconds). APU notifications, IRQ 5, the deferred procedure call, and the DirectSound completion callbacks
all execute. At the completion callback, the stream queue lookup returns no next buffer, and no later XMV
packet is submitted. The audio path therefore is not failing because the source soundtrack ends, nor is the
interrupt delivery path missing its completion event.

The prior shader/pipeline-stall explanation is not confirmed. Linux traces still show long early frames with
zero shader compilations and only about 2 ms spent uploading three textures; the configured cache path
alone did not make the intro audio continue. No safe audio fix has been identified. The remaining target is
the game's XMV/DirectSound packet producer and the conditions under which it stops queuing after packet two.

The first Switch build attempt in `conker-dev` stopped at the build script's toolchain check because that
container has no `/opt/devkitpro`. The same build succeeded on the host with its installed devkitPro
toolchain; no source or build configuration change was needed. The resulting NRO is `3260c845`.

## 2026-10-18: recursive-walk watchdog and no-match retry fix (candidate NRO `630412bd`)

The hardware log from NRO `f976b53f` continued after the earlier frame-2,149 check. It reached frame 3,533,
where one frame took 433 ms and the next performance window fell to 14.3 FPS. Rendering then stopped. The
watchdog captured the guest after 20 seconds without a presented frame and again at 40 seconds:

```text
[WATCHDOG] no frame presented for 20 s; guest esp=0x010FF754
  regs: eax=7428AC50 ecx=43540000 edx=010FF7E8 ebx=00000005 esi=74280280 edi=01293080
  recent ICALL targets: FE0001D0 0055EA00 0055EB46 FE0000F0 ...
    GS 010FF754 00355C85
    GS 010FF758 7428AC50
    GS 010FF75C 010FF7E8
    ...
[WATCHDOG] still no frame after 40 s; guest esp=0x010FF754
```

Both snapshots had the same guest stack pointer and return addresses. The first return address, `0x00355C85`,
is the call from `sub_00355B40` to `sub_00354610`, the 32-byte-entry child search. The search can return
`base - 32` when it has no match. The guard in `f976b53f` avoided recursing through that sentinel, but sent
execution to `loc_00355C91`. If the current parent still had children to inspect, the branch at that label
returned to `loc_00355C40` and repeated the same search with unchanged input. The watchdog does not record
the guest instruction pointer, so the precise loop instruction is inferred from the unchanged stack and
the generated control flow; it is consistent with the user-observed freeze.

The no-match branch now jumps to `loc_00355C9F`, which sets the exhausted-child state and continues through
the existing parent-processing path. This prevents the same child search from being retried indefinitely.
The tracked `tools/regen.sh` preserves both the saved-base sentinel check and this branch target after
regeneration.

The Linux Vulkan target rebuilt successfully in `conker-dev`. A live Linux startup reached frame 534 at
about 53 FPS before it was stopped; its captured startup log had no `[CRASH]`, `[ICALL]`, or `[STUB]` report.
The Switch target rebuilt with `VULKAN=1 STAGE_GAME=0 JOBS=2 ./switch/build.sh`; the NRO MD5 is
`630412bd7708c8c733a1625c05e1301c`, short ID `630412bd`, and the ELF MD5 is
`8c204512da3c88dc9066dc60c88a3b91`. The archived pair is
`analysis/elf_archive/conker-vulkan_630412bd.{nro,elf}`.

The host-side nxlink attempt did not yield a guest log. Its first transcript
(`run/net_logs/20261018-010453.log`) reported 32,065,659 bytes sent (41.53%), then failed to bind the local
stdio listener with `Address already in use`. The retry
(`run/net_logs/20261018-010536.log`) could not connect to the console. The console answered ping, but its
NetLoader was not accepting nxlink at that check. The user subsequently reported that the game did not
crash or stall at the previous location on the latest test, but its FPS dropped there. The report supports
the no-match retry fix, while the exact NRO and frame-time measurements are not verified in a captured
runtime log.

Keep the crash/freeze fix separate from the performance follow-up. The previous `f976b53f` run's 433 ms
frame identifies the area to profile, but it cannot establish the cost of the corrected traversal. Capture
a runtime log from the fixed build and compare frame time, draw count, and guest-thread CPU around that
slowdown before changing the traversal for speed.

## 2026-10-18: NRO `630412bd` alternate-mode hardware pass

The user completed another hardware pass using archived NRO `630412bd` (`analysis/elf_archive/conker-vulkan_630412bd.nro`). The streamed capture is `run/net_logs/20261018-012629.log` (2,953 lines). It launched with no `conker_env.txt`, in title-override full-memory mode (3,189 MB reported); the runtime assigned player 1 the handheld pad. The log does not explicitly report docked/handheld power or clock mode. It loaded multiplayer front-end character assets and the `MPBeach` level package, so this was an alternate multiplayer-content pass. It does not establish that the single-player location associated with the former freeze was exercised.

The game presented through frame 1,939 and the session ended when the nxlink connection was reset (`exiting ...`), with no crash, exception, watchdog, or unresolved indirect-call report. All 145 kernel thunks resolved. One existing file-control operation was logged as a stub (`NtFsControlFile(0x90020)`); no failure was attributed to it in this run. The log shows a high startup/loading frame (3,981 ms at frame 3), plus shader-compilation hitches including 1,034 ms at frame 482 (two programs, 747 ms compiling), 366 ms at frame 663 (three programs, 174 ms compiling), and 234 ms at frame 880 (two programs, 107 ms compiling). The live shader count rose from 321 to 370, so this was not a fully warm-cache pass. A later frame-1,103 loading interval reported one draw and a 1.2 MB texture upload.

The ten `[perf]` windows reported 4.4, 17.5, 26.1, 25.0, 28.6, 16.8, 8.2, 18.0, 20.9, and 19.6 FPS. The last three windows averaged 19.5 FPS; they are evidence for this alternate route only, not a measurement of the former single-player slowdown. In those late windows, `game:0` used 86–95% of one core and the largest other tracked thread used 54–60%; the GL thread reported 0% idle. This points to substantial CPU-side pressure, but there is no GPU timing and the test did not isolate the known slowdown. Late hitches were generally 50–67 ms with roughly 330–624 draws and no shader compilation or meaningful texture uploads. Audio pacing stayed at 1,500 frames/s with zero output gaps, underruns, or dropped buffers. Heap use reached 623 MB with 33 MB free in the arena.

This capture confirms the corrected build runs through a multiplayer-content route without crashing, but it does not close the FPS-drop issue at the former recursive-walk freeze point. Keep that issue open and capture the prescribed warm-cache, repeatable single-player route with an event marker; then collect the separate `RECOMP_NX_PROFILE=2` pass if the slowdown repeats.

## 2026-10-18: profiled Switch pass stalled on a PGRAPH NOP trap (NRO `630412bd`)

The next capture used the same archived NRO with `ARGS=RECOMP_NX_PROFILE=2`; no source or build changes were made. The log is `run/net_logs/20261018-013420.log`. It loaded the `SoloSetup` text asset, reached frame 949, and reported FPS windows of 4.1, 29.0, 21.5, 25.0, and 18.0 before presentation stopped. It had prewarmed 377 programs and logged no shader compiles in the later measured windows. This was a profiled run, so its FPS is diagnostic only.

Before the stall, `[perf] % of a core per thread` showed `game:0` at 43%, 79%, 74%, 27%, and 25% in successive windows. The `nv2a_ack_thread` was about 15%, 50%, 45%, 24%, and 34%; `nv2a_flag_thread` was about 15%, 10%, 6%, 5%, and 4%. The active threads therefore did not show all available CPU capacity saturated in these windows. These counters are per-thread CPU time, not physical-core placement. The process reported core mask `0x7`, while guest code was serialized under `RECOMP_GIL`; profile data alone does not justify changing affinity or removing that lock.

At the last rendered frame, the runtime reported 18.0 FPS and 36.2 Hz vblank, then 0 FPS and 0 Hz. The pushbuffer executor repeatedly reported `NOP(315097153)` still pending, which is method `0x0100` with parameter `0x12C80041`; earlier in this same run it had handled 5,120 NOP traps. The 20- and 40-second watchdog snapshots showed no frames, the same guest stack pointer (`0x010FFEC0`), and PGRAPH interrupt status still asserted (`PMC_INTR=0x00001000`, enabled). No crash or exception was logged. The host-side nxlink capture was stopped after the 40-second watchdog while the console remained frozen.

This is evidence of a missed PGRAPH software-interrupt acknowledgement during this profiled route, not evidence that the original single-player slowdown is caused by CPU saturation. It is not yet known whether sampling changed timing enough to expose the race or the same route hangs without profiling. Next, compare the same `SoloSetup` route without sampling, then use a lower-overhead profile (`RECOMP_NX_PROFILE=1`, optionally delayed until after startup) if the route is stable. Keep the CPU/core-allocation question separate from the PGRAPH wait until the latter is understood.

## 2026-10-18: follow-up profiling reaches a later PGRAPH NOP wait (NRO `630412bd`)

The unprofiled follow-up used the archived NRO with default settings; its log is `run/net_logs/20261018-014209.log`. It loaded `Mp_Frontend` and the `MPBeach` package, passed frame 949, and reached frame 1,906. FPS windows ranged from 4.4 to 28.4; late windows were 12.8–21.7 FPS. Late `[perf]` reports showed `game:0` as high as 94% of one core and the NV2A acknowledgement/executor thread as high as 71%. NOP traps continued to be handled. The host then received `Connection reset by peer`; no crash, exception, or pending NOP appears before that end. This is a partial negative control for the earlier frame-949 stall, not a full-duration control for the later hang.

The next capture used `RECOMP_NX_PROFILE=1 RECOMP_NX_PROFILE_AFTER=15`; no source or build changes were made. The log is `run/net_logs/20261018-014455.log`. It again loaded `Mp_Frontend` and `MPBeach`, and the lower-overhead profiler passed frame 949. It reached frame 3,194, with settled FPS windows mostly around 13.0–15.4 and 60 Hz vblank. In the late windows, `game:0` used 85–92% of one core, `nv2a_ack_thread` 52–60%, `nv2a_flag_thread` 22–29%, and the next tracked thread 5–7%. The process still reported core mask `0x7` and guest code serialized under `RECOMP_GIL`; these are per-thread counters and do not report physical-core placement.

The profile's later three-window caller report for `nv2a_ack_thread` attributed 19.8% of its sampled callers to `nv2a_pb_scan`, 13.8% to `vk_draw_raw`, and 8.7% to `nvk_sw_emitted_equal`. Its sampled PCs also included `svcSleepThread` (about 38%), `nv2a_pb_exec_method` (about 9%), `memmove` (about 6%), and `__swbuf_r` (about 8%). These percentages describe profile samples, not exclusive CPU time or GPU execution time; the sampled PCs include wait paths. The results make pushbuffer walking and draw-state submission concrete leads for the executor, but do not yet identify an optimization or prove that the thread is wasting CPU while yielding.

The run then stalled after frames 3,191–3,194 took 333, 467, 101, and 84 ms. The first frame compiled one shader in 119 ms; the next frames reported no shader compilation. The pushbuffer executor reported `NOP(354418753)` (`0x15200041`) still pending with `PMC_INTR=0x00001000` enabled. It had handled at least 66,560 earlier NOP traps. At the same time, the log found thread 1007 waiting on guest lock `0x004E1674` held by thread 0 at guest PC `0x004C38D8`, and reported `[OHCI0] guest IRQL never dropped (depth 2); delivering anyway`. The last captured perf window was 10.2 FPS / 47.4 Hz; no crash or exception was logged. The user reported the game frozen while the NOP remained pending; the host capture was interrupted afterward.

This later stall means the PGRAPH wait is not limited to the profile-2 capture or frame 949. The unprofiled run ended at frame 1,906, so it does not show whether the later wait also occurs without sampling. Do not change thread affinity or remove `RECOMP_GIL` based on these samples. After console recovery, repeat the same `MPBeach` route without profiling through frame 3,200 or until it stalls; if it does, trace NOP acknowledgement, the guest lock, and IRQL delivery together. This remains separate from the unmeasured single-player slowdown.

## 2026-10-18: profile-2 reaches Windmill and identifies renderer CPU leads

The user ran the corrected baseline NRO `630412bd` with `RECOMP_NX_PROFILE=2` and went directly to the area
associated with the earlier freeze. The streamed log is `run/net_logs/20261018-015143.log`. It loaded
`Level\Windmill\default.rbm`, logged the Windmill level text, and reached frame 1,248. The connection
then reset; the captured log contains no crash, watchdog, pending NOP, or exception. Its settled FPS windows
were 21.4, 18.5, 23.3, 24.5, and 18.7 after an initial 3.0 FPS window. The final two vblank readings were
59.9 and 59.8 Hz. This is a diagnostic profile, so these FPS values are not a benchmark. The log reaches
Windmill but contains no explicit marker for the exact formerly reported slowdown event.

In the last two profile windows, `game:0` used about 90–93% of one core and the NV2A acknowledgement thread
about 45–49%. On `game:0`, sampled PCs included `svcSleepThread` (12.1%), `svcSignalProcessWideKey` (7.5%),
and `sub_003DD570` (5.9%). On the NV2A acknowledgement thread, sampled PCs included `svcSleepThread`
(41.2%), `nv2a_pb_exec_method` (8.8%), `memmove` (6.6%; this address also resolves as `memcpy`),
`__swbuf_r` (6.4%), `nv2a_pb_scan` (4.4%), and `vk_draw_raw` (2.8%). Caller samples included
`nv2a_pb_scan` (18.8%), `vk_draw_raw` (13.1%), and `nvk_sw_emitted_equal` (6.7%). These are sample shares,
not CPU-time or GPU-time shares; the prominent sleep sample also means the PC distribution cannot be read
as exclusive active work. No physical-core placement or GPU execution time was captured.

The same Windmill pass reported recurring 400–566 ms hitches around frames 834–837, 950–953, 1,070–1,073,
and 1,221–1,224, with no shader compiles or texture uploads in those hitch records. The capture does not
attribute those intervals to a specific function or prove they are all the same event. It does show that
shader compilation and texture upload are not recorded causes for those particular hitches.

## 2026-10-18: first renderer CPU cache candidate

Based on the repeated copy samples and the renderer path, the first candidate caches the 3,072-byte
vertex-program constant block using the guest constant generation and the active command-buffer slot's
generation. Instanced/pending draws continue to receive a fresh block where required so pending draw data
remains contiguous. The cache can be disabled with `RECOMP_VK_CONST_CACHE=0`; it is enabled by default.
This removes a host copy only when the relevant constant generation is unchanged. It does not change guest
execution, command order, thread affinity, or lock behavior.

Candidate 1 was built with:

```sh
VULKAN=1 STAGE_GAME=0 JOBS=2 SD_ROOT=build/staging-cpu-cache ./switch/build.sh
```

The archived pair is `analysis/elf_archive/conker-vulkan_b8ff2fc5.nro` (MD5
`b8ff2fc56b8b04178a28cdab28299207`) and `analysis/elf_archive/conker-vulkan_b8ff2fc5.elf` (MD5
`7dcfbebd04613228787b92e585ce213e`). The hardware capture is
`run/net_logs/20261018-020128.log`, launched with `RECOMP_DRAW_STATS=1` and no sampling profiler. It loaded
Windmill, reached frame 4,301, and ended on connection reset without a crash or pending NOP. In later
300-frame windows the cache reported roughly 50–61% reuse (examples: 44,934 copied / 69,768 reused;
57,548 / 76,666; 59,389 / 58,416). Earlier transition work had a lower reuse ratio, around 36%.

This capture cannot establish a performance gain: `RECOMP_DRAW_STATS=1` also activates culling diagnostics,
which measured about 13–21 microseconds per draw in this run. Windmill FPS windows were 17.3, 17.9, 17.1,
21.4, and 24.3, but the added culling work contaminates the comparison. The counters establish that the
cache avoids copies; they do not quantify time saved. The log also recorded non-shader/non-upload hitches:
frame 4,144 took 150 ms while one shader compiled in 60 ms, then frame 4,145 took 534 ms with no compile or
upload; frames 4,248–4,251 took 401, 450, 468, and 367 ms with no compile or upload.

Candidate 2, `analysis/elf_archive/conker-vulkan_e037bd66.{nro,elf}`, was built to separate cache counters
from culling diagnostics. It adds opt-in `RECOMP_VK_CONST_CACHE_STATS=1` reporting while restoring
`RECOMP_DRAW_STATS` to its original draw-count-only behavior. The NRO MD5 is
`e037bd66b79dbb3a807f726f5d1866b1`; the ELF MD5 is `30dcef04dca6e716f8afb9fa8eb1422d`. The build
completed successfully with existing enum-conversion warnings in `depth_texture_view` and no errors.
At this point in the session Candidate 2 had not run on hardware. The first launch attempt is recorded in
`run/net_logs/20261018-020717.log`; the console answered ping, but nxlink failed because NetLoader was not
accepting the connection. Use the same NRO and route for the cache-on and cache-off runs, with the sampler
and culling diagnostics disabled. The two launch settings are:

```sh
ARGS='RECOMP_VK_CONST_CACHE_STATS=1'
ARGS='RECOMP_VK_CONST_CACHE=0 RECOMP_VK_CONST_CACHE_STATS=1'
```

Compare repeated warm-cache windows and retain the change only if the improvement exceeds run-to-run
variation without correctness or frame-pacing regressions. No speedup has yet been confirmed. Once this
controlled A/B is complete, measure the user's reported single-player slowdown with a marked save-point
route; do not infer its cause from this Windmill profile alone.

## 2026-10-18: clean cache-on Windmill run (NRO `e037bd66`)

The cache-on run used `analysis/elf_archive/conker-vulkan_e037bd66.nro` with
`RECOMP_VK_CONST_CACHE_STATS=1`. The streamed log is `run/net_logs/20261018-021534.log`. Sampling profiling
and `RECOMP_DRAW_STATS` were off, so the sampler and culling diagnostics did not contaminate this capture.
It loaded `Level\Windmill\default.rbm`, reached frame 2,016, and ended on `Connection reset by peer`.
The capture contains no logged crash, watchdog, exception, or pending PGRAPH NOP. It handled NOP traps
throughout; the APU stayed around 1,500 frames/s with no audio gaps, underruns, or dropped buffers.

The early FPS windows before Windmill were 4.4, 17.2, and 25.9 FPS while the route loaded. After the
Windmill content loaded, the six settled windows were 22.3, 18.9, 22.6, 24.9, 24.8, and 30.0 FPS, with
vblank near 60 Hz. Late `game:0` samples ranged from 77–94% of one core; the NV2A acknowledgement/executor
thread ranged from 48–73%. These are single-run measurements from the cache-on side only; they do not
establish a speedup.

The six 300-frame cache reports were: 47,063 copied / 36,790 reused; 55,430 / 51,209; 48,261 / 83,863;
66,595 / 103,963; 55,999 / 54,855; and 58,760 / 63,217. Reuse therefore varied from about 44% to 64% of
the reported total blocks, depending on the window. There is no culling-stat overhead in this run, but the
counter only measures reuse counts and not the CPU time saved by avoiding those copies.

Long hitches still occurred at frames 1,299–1,301 (450–468 ms), 1,470–1,473 (383–468 ms), and
2,013–2,016 (384–467 ms). Those hitch records show zero shader compiles and zero texture uploads. The
capture does not identify the cause of these long frames. For the A/B control, use the same NRO, route,
console mode, and warm-cache conditions with only `RECOMP_VK_CONST_CACHE=0` added; then compare the same
metrics and repeat both settings before drawing a performance conclusion.

## 2026-10-18: cache-off control sent, route capture pending

After the cache-on run, the same archived NRO `e037bd66` was sent with
`RECOMP_VK_CONST_CACHE=0 RECOMP_VK_CONST_CACHE_STATS=1`. The live nxlink log is
`run/net_logs/20261018-021920.log`. Startup confirmed both arguments and the application began loading the
intro. At that point in the session, the cache-off Windmill route had not yet been captured. Its completed
results are recorded in the following entry.

## 2026-10-18: cache-off Windmill control completed (NRO `e037bd66`)

The user completed the cache-off control using the same `e037bd66` NRO with
`RECOMP_VK_CONST_CACHE=0 RECOMP_VK_CONST_CACHE_STATS=1`. The capture is `run/net_logs/20261018-021920.log`.
It loaded `Level\\Windmill\\default.rbm`, reached frame 1,619, and ended on `Connection reset by peer`;
there is no logged crash, exception, or pending PGRAPH NOP. APU pacing stayed near 1,500 frames/s and audio
reported no gaps, underruns, or dropped buffers.

After Windmill loaded, the settled FPS windows were 20.3, 19.6, 22.1, 24.3, and 21.8, with vblank around
60 Hz. The four later cache-stat windows each reported zero reuse and 115,198, 171,624, 119,317, and
121,469 copies. Long non-shader/non-upload hitches persisted: frame 651 took 521 ms with eight draws;
frames 1,206–1,209 took 384–534 ms; frames 1,327–1,330 took 384–467 ms; frames 1,426–1,429 took
383–467 ms; and frames 1,617–1,619 took 450–467 ms. The 521 ms frame occurred during a low-draw transition;
the log does not identify the cause of the long hitches.

This is one cache-off run against one cache-on run, not a repeated benchmark. The FPS ranges overlap
substantially and are not consistently faster or slower in either mode. The cache-on run reduced block
copies by reusing blocks, while the cache-off run predictably reported no reuse; the measured logs do not
yet show that this reduced CPU time or improved Switch FPS. At this point, the planned follow-up was to
rebuild the Linux target and see whether the scripted pad input could reach Windmill in `conker-dev`; the
later Docker reachability check and its result are recorded below. Keep lavapipe timing separate from Switch
performance claims.

## 2026-10-18: profile-2 Windmill run stopped presenting in a guest tree routine (NRO `e037bd66`)

The same archived NRO/ELF pair was launched with `RECOMP_NX_PROFILE=2`; the streamed log is
`run/net_logs/20261018-022626.log`. It loaded `Level\Windmill\default.rbm` and ran through frame 2,831.
Frames 2,830 and 2,831 took 1,902 ms and 2,086 ms, with 1,254 and 1,175 draws. Frame 2,830 uploaded
three textures totaling 0.1 MB in 5 ms; frame 2,831 had no texture upload or shader compile. Later windows
reported 0.1 FPS and then 0.0 FPS / 0.0 Hz vblank while `game:0` stayed at 98–100% of one core. In those
later windows the guest indirect/kernel call counters dropped to zero even as the game thread stayed busy.
The NV2A executor and the APU did not show a matching stall; APU pacing stayed near 1,500 frames/s and
audio reported no gaps, underruns, or dropped buffers.

The last nine profile windows (indices 12–20) attributed 75.1% of the game-main thread's sampled PCs to
`sub_000139D0`. On `nv2a_ack_thread`, sampled PCs included `nv2a_pb_exec_method` (10.8%), `memmove`
(5.9%), `nv2a_pb_scan` (5.8%), and `vk_draw_raw` (3.2%); 32.1% of its samples were in `svcSleepThread`.
These are sampled-PC shares, not CPU-time percentages or GPU timings. The main-thread concentration points
to guest work as the immediate lead for this stall; renderer CPU work remains a separate optimization path.

Source inspection shows `sub_000139D0` attaches a node to a tree, updates its size and root/extreme links,
then checks parent/uncle color and performs rotations and recoloring. Its callers include
`sub_000136E0` and `sub_00013890`. This resembles a standard red-black-tree insert/rebalance routine. The
fix-up walks parent links upward, so a cycle or malformed parent chain could keep it busy; the profile does
not distinguish that from an unusually high volume of valid insertions. This is a strong lead, not a
confirmed root cause. The caller report is inconclusive without usable frame pointers, and the Switch
`prof.bin` was not retrieved.

The user described a black screen/crash. The streamed log shows a presentation stall but no exception,
crash report, pending PGRAPH NOP, or watchdog report. The profiler continued reporting after frames stopped;
the nxlink session later ended with `Connection reset by peer`, so this capture does not confirm that the
application process crashed.

For a local reachability check, a copy-on-write clone of `run/save` was mounted into the `conker-dev`
container. It reached the title and `Level\TrainingLevel`; the chapter selector showed “Hungover” as not
available and did not provide a direct Windmill route. This Docker run did not reproduce the Windmill stall.
Its lavapipe frame rate is not Switch performance evidence. Next, trace the tree insert/rebalance path and
add narrowly scoped diagnostics only if a comparable route can exercise it; do not add an arbitrary loop
exit or change tree semantics from this profile alone.

## 2026-10-18: tree-insert diagnostic build validated in Docker

Added `tools/tree_insert_diag.py` and an opt-in hook in `tools/regen.sh`. With `TREE_INSERT_DIAG=1`, the
regeneration path adds compile-time-guarded instrumentation to the generated `sub_000139D0`; the build must
also define `RECOMP_TREE_INSERT_DIAG=1`. It reports completed insert/fix-up totals every 16,384 calls and
prints the tree, inserted node, current node, parent, and grandparent when one fix-up reaches 128 steps and
again at later powers of two. The normal build has no instrumentation or guest behavior change. The
diagnostic build does extra logging and is not for performance scoring.

The generated source was cloned into `build/tree-diag-gen` and compiled in `conker-dev` as
`build/linux-vk-tree-diag/conker_recomp`; the build completed without errors (the existing compiler
warnings remain). Running it against the copy-on-write save reached `Level\TrainingLevel` without a crash.
No long-fix-up line appeared there. The 16,384-call aggregate threshold was not reached, and TrainingLevel
is not the Windmill stall route, so this does not establish whether the routine is called at all in that
scene or rule out a Windmill parent-link cycle.

The `conker-dev` image has the NVK SDK and glslang but lacks `/opt/devkitpro/cmake/Switch.cmake`, so this
session produced no Switch diagnostic NRO. The next useful capture needs the same Windmill route on the
diagnostic NRO; until then, leave the insert/rebalance semantics unchanged.

## 2026-10-18: Switch tree-insert diagnostic capture started (NRO `5924ba1f`)

Built and archived a Switch diagnostic pair as
`analysis/elf_archive/conker-vulkan_5924ba1f.{nro,elf}`. The NRO is 77,207,749 bytes and its MD5 is
`5924ba1fe33b426f0ab22ebc37065606`; the matching ELF MD5 is
`d05a4005d7016095af0414b87cc47956`. The isolated build defines
`RECOMP_TREE_INSERT_DIAG=1`; diagnostics are still opt-in and the guest tree algorithm is unchanged. This
build was compiled on the host with devkitPro after confirming that the Docker image itself lacks the Switch
toolchain.

The NRO was sent to the Switch at `192.168.1.248` with no `RECOMP_NX_PROFILE` argument, so periodic runtime
summaries remain enabled without the sampling profiler. It records per-thread busy percentages, frame
hitches/draw counts, and APU/audio status, but it has no function-level renderer samples. The live capture is
`run/net_logs/20261018-030841.log`. It booted under title takeover/full memory, loaded the game XBE, and
initialized the Vulkan/NVK renderer. The user is testing the Windmill route for 5–10 minutes with the
console overclocked. This run is diagnostic only and its FPS must not be used as a stock-clock benchmark.
At the latest interim check, it had loaded `Level\Windmill` and continued past frame 12,066, well beyond the
previous stall at frame 2,831. It logged 217–267 ms hitches at frames 6,898–6,903 and recurring 50–51 ms
hitches around frames 7,745–7,859, without shader compilation or substantial texture upload. Later hitches
at frames 12,039–12,040, 12,060–12,061, and 12,064–12,066 coincided with shader compilation: frame 12,064
took 517 ms with three programs compiled in 302 ms; frame 12,066 took 334 ms with two programs compiled in
172 ms. Texture uploads in those windows were at most 0.0 MB / 2 ms. No `[tree-insert-diag]` record had
appeared yet. The capture is still in progress; inspect it after the user finishes for fix-up records,
aggregate call counts, frame/presentation progress, thread activity, audio, and whether a stall or crash
occurred. This run did not enable `RECOMP_NX_PROFILE=2`, so it cannot identify renderer hot functions for
this build. Until the diagnostic evidence is available, the tree-cycle theory remains unconfirmed and no
guest semantics should change.


## 2026-10-18: completed overclocked Switch capture (NRO `5924ba1f`)

The user completed the diagnostic run from `analysis/elf_archive/conker-vulkan_5924ba1f.{nro,elf}`. The
NRO MD5 is `5924ba1fe33b426f0ab22ebc37065606`; the ELF MD5 is
`d05a4005d7016095af0414b87cc47956`. The streamed log is `run/net_logs/20261018-030841.log` (4,701 lines,
245,448 bytes). It was launched at `192.168.1.248` under title takeover/full memory, with tree-insert
instrumentation enabled and no `RECOMP_NX_PROFILE` argument. The user ran overclocked. The log ends with
`recv: Connection reset by peer`, `exiting ...`, and `EXIT_CODE=0`; it contains no `[CRASH]`, exception,
watchdog, unresolved PGRAPH NOP, or evidence of a process crash.

The load route was `Level\Frontend` → `Level\Windmill` → `Level\Frontend` → `Level\Mp_Frontend` →
`Level\MPBeach`. It passed the previous frame-2,831 Windmill presentation stop and continued through at least
frame 6,903 before leaving Windmill; the final reported frame was 14,282. The earlier stop did not recur in
this overclocked diagnostic run, which does not prove that the issue is fixed under normal clocks or other
routes.

There are 51 `[perf]` windows and 444 `[hitch]` records (frames at least 50 ms). Seventy-seven hitches were
at least 100 ms, 67 were at least 200 ms, and the maximum was 3,570 ms. Windmill contributed 32 performance
windows at 21.9–34.7 FPS with vblank near 60 Hz, and 95 hitch records: 51 at least 100 ms, 50 at least
200 ms, maximum 608 ms. No shader was compiled in Windmill. Ninety of its 95 hitch records had neither a
shader compile nor a texture upload. Repeated six-frame bursts included frames 2,476–2,481 (217–267 ms),
2,894–2,899 (217–267 ms), 3,051–3,056 (217–283 ms), 3,098–3,103 (234–284 ms), 4,478–4,483,
5,163–5,168, 5,501–5,506, and 6,898–6,903 (the latter groups were 217–267 ms). These frames had hundreds
of draws and no reported shader/texture work, making guest CPU or renderer CPU work a lead; no function
samples or GPU timers were captured, so the exact source remains unknown.

`MPBeach` contributed 14 performance windows at 11.0–29.8 FPS and 315 hitch records, including 19 at least
100 ms and 13 at least 200 ms. Shader compilation caused several identifiable long frames: frame 11,968
took 3,570 ms, including 2,069 ms compiling 20 programs; frame 12,068 took 1,985 ms, including 1,073 ms
compiling eight programs; frame 11,709 took 584 ms, including 465 ms compiling one program; frame 12,064
took 517 ms, including 302 ms compiling three programs. Other large MPBeach hitches did not compile
shaders or meaningfully upload textures, so compilation does not explain the whole route. The final summary
reported 21.1 FPS, 60.0 Hz vblank, 1,500 APU frames/s, zero audio gaps/underruns/dropped buffers, and
658 MB heap use with 49 MB arena space free. This is an overclocked diagnostic sample, not a stock-clock
benchmark.

Neither `[profile]` nor `[tree-insert-diag]` appeared. The tree diagnostic emits an individual record only
at 128 or more fix-up iterations and an aggregate every 16,384 calls. Their absence means those reporting
thresholds were not reached; it does not prove `sub_000139D0` was not called. The prior cyclic-parent-chain
theory is weakened for this route but remains unproven. The capture has useful route and resource-correlation
data, but no sample profile of the renderer. The next software-side work should keep the renderer hot path
active, test the existing constant-block cache carefully, and avoid changing guest tree semantics based on
this log alone.

## 2026-10-18: historical intro-audio evidence review

The earliest Switch logs reviewed (`run/net_logs/20261016-223841.log`,
`run/net_logs/20261017-002117.log`, and `run/net_logs/20261017-020541.log`) each show the game opening
`dvddata\fmv\frontend\BootIntro.xmv`; they also show `[APU] host audio output active` and later
`[APU] started by the title`. These logs have no intro-specific audio dump, voice cursor, packet count, or
per-window signal measurement. They corroborate that the video path and APU initialized, but do not by
themselves prove how long the intro soundtrack was audible. The user's recollection that early intro builds
had sound while the main menu was black is retained as a useful observation, distinct from the captured log
evidence.

The first explicit failing hardware report in the reviewed history is the 2026-10-17 play-through on NRO
`e807fd88`, logged in `run/net_logs/20261017-064742.log`: the user reported that intro audio disappeared in
under a second. The log confirms host audio output and title APU startup, and opens `BootIntro.xmv`. Its first
audio-output summary has a nonzero peak (`16810`); the next three summaries report `peak 0`, before later
gameplay summaries become nonzero again. These 10-second summaries corroborate a brief output followed by
silence, but do not timestamp the exact cutoff. This run predates commits `c130f84` and `0d9fb5c`, so neither
can have introduced the first observed failure. The source diff from the now-confirmed-audio checkpoint
`52a4270` to `66ef96c` contains no APU, DirectSound, or XMV implementation change, so the exact regression
is not identified by source history. `0d9fb5c` later redirected the shader cache to Conker's SD folder as a
proposed way to avoid startup stalls; later traces did not establish that as an audio fix.

The old black front end was independently traced to rendering: the title continued issuing hundreds of
3D draws while the menu stayed black, and renderer fixes later made the front end visible. That separates the
menu picture failure from the audio producer at the architectural level. The Switch `video_pump.c` host FMV
player is Windows-only and is not the Switch movie/audio path; the title's own XMV code feeds DirectSound/APU.

Source history from the first boot commit (`ac33bfb`) to the current tree shows no edits to the DirectSound
implementation or APU voice processor beyond commit `c130f84`, which changed
`apu_phys()` so addresses in `[0x08000000, 0x80000000)` are read as guest virtual addresses. This fixed
streamed game sounds whose VAs, such as `0x7415D7A0`, had previously been masked to unrelated low memory.
It is a specific build difference worth checking against the intro stream segment addresses, but current
traces place the cutoff later: four mono XMV voices queue two ADPCM packets each; completion callbacks and
IRQ/DPC run; the game's stream queue lookup then returns no next buffer and no later XMV packet is submitted.
The address fix might affect what the APU reads, but it does not yet explain why the guest producer stops
submitting packets. Do not revert `c130f84`; compare the early and current stream descriptor/segment VAs and
packet-completion state before deciding whether the address interpretation contributes.

The cache-folder correction in `0d9fb5c` changes shader/pipeline-cache placement, not XMV/DirectSound code.
The earlier theory that first-use shader compilation consumes the initial audio lead is still unconfirmed:
subsequent Linux traces show the intro audio cutoff with no shader compiles and only about 2 ms spent on
texture uploads. A useful follow-up is to capture an intro-only audio dump and the four voices' packet/segment
addresses and queue state through the first completion, then compare the values with the archived early
build's launch log and current build. Do not infer soundtrack output from APU initialization or the audio
peak later in a long session.


## 2026-10-18: Docker cache A/B and intro PCM capture

The current Linux Vulkan executable built in the available `conker-dev` image (`docker run ... conker-dev
cmake --build build/linux-vk -j2`); Ninja reported `no work to do`, so the executable already matched the
current source timestamps. Two 60-second headless runs used independent copies of `run/live/save`, the same
binary, `RECOMP_LINUX_PROFILE=1`, and the same startup route. The cache-on run used
`RECOMP_VK_CONST_CACHE=1`; the control used `RECOMP_VK_CONST_CACHE=0`. Both opened `BootIntro.xmv`, ran the
front-end path without a crash report, and settled near the lavapipe/vblank limit: cache-on recorded 59.9 FPS
at frames 1,132, 1,732, 2,332, and 2,932; cache-off recorded 59.9–60.0 FPS at frames 1,139, 1,739, 2,339,
and 2,939. Both began near 53–54 FPS during startup. On this front-end route the stats showed 3,000
constant blocks copied and zero reused in every 300-frame window, with the first partial window reporting
3,229 copies and zero reuse. This workload did not exercise the cache opportunity seen in Windmill. The
runs were profile-instrumented and hit the Linux display/vblank cap; they do not establish Switch speed.
The existing cache remains a copy-reduction optimization (44–64% reuse in the prior Windmill capture), but
there is still no measured FPS improvement, and this Docker route cannot decide its value in Windmill.

A separate 25-second Docker startup captured ten seconds of the exact PCM passed toward SDL using
`RECOMP_AUDIO_DUMP=/work/run/cache-ab/intro.raw,0,10`; the headless SDL driver was dummy. The raw file
contains 1,920,000 bytes (48 kHz, stereo, 16-bit). Its 100 ms RMS windows contain nonzero samples from
0.30 to about 1.40 seconds after the audio device opened, with a peak of 7,737; every window from 1.40 to
10.00 seconds is exactly zero. The same log opened `BootIntro.xmv` and reported that the title started the
APU. This reproduces a brief PCM burst followed by silence in the Linux route and gives a concrete artifact
for comparison. The log has no timestamp aligning the movie's first frame with the device-relative sample
clock, and a dummy output cannot verify audibility, so it does not prove the exact soundtrack cutoff time or
soundtrack identity. Files: `run/cache-ab/audio.log` and `run/cache-ab/intro.raw`.

This strengthens the stream-refill lead: there is a short nonzero output interval followed by sustained zero
PCM, while previous traces showed callbacks completing but no later XMV packet being submitted. The early
build logs and commit comparison above still do not prove that the complete intro soundtrack played in the
first iteration. The only concrete audio-path change after the initial commit is `c130f84`'s high-VA APU
address handling; compare the stream segment/descriptor addresses across the packet completion before
changing it or the game producer.

## 2026-10-18: Docker A/B of the early APU address mapping

To isolate the sound-path change in `c130f84`, the same current Linux Vulkan source and generated game code
were built twice in the `conker-dev` image, with separate fresh save directories. The control temporarily
used `apu_shim.h` from `c130f84^` (the mapping present around the first successful Switch build); the second
build restored the current high-VA mapping. Each run opened `BootIntro.xmv` and dumped ten seconds of the PCM
sent toward SDL to `run/audio-ab/pre-fix.raw` and `run/audio-ab/current.raw` respectively. Both dumps are
1,920,000 bytes (48 kHz, stereo, signed 16-bit), and both logs show the title starting the APU.

The pre-fix dump had RMS 1,813.9 and 71.0% nonzero samples in seconds 0–1, then RMS 923.4 and 25.3% nonzero
samples in seconds 1–2. The current dump measured RMS 1,780.6 / 66.2% and 986.0 / 30.1% in those same
windows. From seconds 2–10 both dumps contain exact zero PCM. Peaks were 7,737 in the first second and 5,000
in the second for both. Thus both builds produce a similar short signal burst; this A/B does not identify
whether the burst is correct music, noise, or otherwise audible. The dummy SDL output cannot be listened to
or validated as Switch output, and its device-relative clock is not aligned to the movie's first frame.

This rules out the `c130f84` address mapping as the cause of the *duration* of the Docker PCM burst: the
cutoff is effectively unchanged. It does not rule out a difference in sample correctness for a voice backed
by extended virtual memory. The source comparison is deliberately limited to that one APU mapping change;
it is not a full historical rebuild of every early NRO. Docker confirms PCM signal production but cannot
establish whether the intended soundtrack is audible or correct. For a hardware listening comparison,
prepare these five historical checkpoints: first-success NRO `31500df5` (the NT-faithful directory-status,
seed, and small-VMA-fallback source state at commit `52a4270`, before the APU mapping fix), source revision
`a43804b` (black-screen investigation before the lifter correction), source revision `1bc623e`
(black-screen fix), source revision `c130f84` (APU mapping fix as a sound-path control), and archived NRO
`688d985e` as a later known-good reference. The original `31500df5` binary was absent, so it has now been
rebuilt from source commit `52a4270`; the reconstructed NRO is `analysis/elf_archive/conker-vulkan_6d26ed5d.nro`
(MD5 `6d26ed5d4f7cadfb4cb5e5c4e87ffa32`) with its matching unstripped ELF. Its hash does not match the
historical NRO hash, so this is a source-state reconstruction, not the original binary. Revisions `a43804b`,
`1bc623e`, and `c130f84` still need NRO builds. The `688d985e` NRO and matching ELF are archived. No Switch
sound claim is made from the Docker captures.

## 2026-10-18: next overclock capture prepared with stack and renderer sampling

The overclocked NRO `5924ba1f` passed the earlier Windmill presentation stall but had no sampling profile.
The new diagnostic NRO `545de116` is built and archived at
`analysis/elf_archive/conker-vulkan_545de116.{nro,elf}`; it has the `sub_000139D0` tree instrumentation and
the opt-in Vulkan GPU timer compiled in. Its dedicated build directory is `build/switch-vk-profile`, and the
launch command is recorded in [10-building.md](10-building.md). The first full build compiled and linked but
did not stage through the wrapper; the incremental rerun succeeded and staged the NRO. The first staging
error did not recur, so its cause remains unknown.

The planned launch uses `RECOMP_NX_PROFILE=2` from startup. Its 1 kHz sampler covers every thread above its
2% busy threshold, including the renderer executor, and records PC, LR, and up to five return addresses per
sample. The log also contains per-thread PC/caller summaries every ten seconds; full stacks append to
`prof.bin` on the SD card. `RECOMP_VK_GPU_TIMING=1` adds the GPU command-buffer duration for each game frame,
reported after its frame fence signals; large ring-buffer flushes are timed as segments and summed.
`RECOMP_WATCHDOG_SECS=60 RECOMP_WATCHDOG_KEEP=1` preserves a guest stack snapshot if presentation stops.
Together these measurements can distinguish a guest CPU loop, renderer CPU work, and GPU execution pressure.

A 20-second Docker smoke run enabled `RECOMP_LINUX_PROFILE=1` and `RECOMP_VK_GPU_TIMING=1` together. It
opened `BootIntro.xmv`, emitted 1,031 `[vk-gpu]` frame samples, and logged no crash or exception. Lavapipe's
sample median was 9.745 ms, p95 13.064 ms, and maximum 879.896 ms, with the maximum during startup. This
confirms that the query path reports per-frame values and coexists with CPU profiling on Linux; these are
not Switch timing results. NRO `545de116` has not been sent to the console.

Use the same overclock setting and Windmill route as the previous capture, and note the scene, entry point,
and any point where frame progress or FPS changes. The profiler adds overhead, so this run is for diagnosis,
not an overclocked performance benchmark. Keep draw/surface diagnostic counters off to avoid adding per-draw
cost; the stack samples and existing hitch/thread reports provide the renderer and CPU leads needed for the
next optimization decision.

## 2026-10-18: first-success audio checkpoint reconstructed and launched

Rebuilt the first-success source state from commit `52a4270` in an isolated worktree, using that revision's
seed list and regeneration scripts. It regenerated 21,284 functions and produced NRO MD5
`6d26ed5d4f7cadfb4cb5e5c4e87ffa32` (archive prefix `6d26ed5d`), rather than the historical NRO MD5
`31500df5...`. The output is therefore a reconstruction from the recorded source state, not a bit-identical
copy of the original binary. `_start` is at address zero. The matching unstripped ELF and NRO are archived
as `analysis/elf_archive/conker-vulkan_6d26ed5d.{elf,nro}`.

Four initial attempts failed with `Connection to 192.168.1.248 failed`; their logs are
`run/net_logs/20261018-214748.log`, `run/net_logs/20261018-214754.log`,
`run/net_logs/20261018-214800.log`, and `run/net_logs/20261018-214853.log`. The Switch answered an ICMP
ping, and the fifth attempt succeeded, transferring all 77,088,965 bytes in
`run/net_logs/20261018-215038.log`. It started in title-takeover/full-memory mode. The current log confirms
the title started the APU and opened `BootIntro.xmv`. The user confirms that both the intro video and audio
play correctly on this checkpoint. This is direct hardware listening evidence for the reconstructed
first-success source state; the runtime log itself records APU startup and movie-file open, not an audio
measurement. This does not establish whether a later build has the same behavior. The same artifact can be
resent with
`NRO=analysis/elf_archive/conker-vulkan_6d26ed5d.nro tools/nxlink_run.sh 192.168.1.248`.

## 2026-10-19: profile-2 and GPU-timing diagnostic NRO sent to Switch

Sent archived NRO `analysis/elf_archive/conker-vulkan_545de116.nro` (MD5
`545de116f420fcd449a26f576a768d0b`) to `192.168.1.248`; its matching unstripped ELF remains archived. The
live session is `run/net_logs/20261019-012749.log`. Launch arguments enabled `RECOMP_NX_PROFILE=2`,
`RECOMP_VK_GPU_TIMING=1`, the 60-second watchdog, and a request for 1,785/921.6/1,600 MHz CPU/GPU/memory.
The log confirms title-takeover/full-memory mode, profile-2 sampling at 1 kHz, Vulkan frame timestamps, and
the game opened `BootIntro.xmv`. At the latest check the log had advanced through at least frame 595; no
crash was logged. Frame 3 took 3,203 ms with zero shader compiles and 1.7 MB of texture work reported as
16 ms; GPU timestamps were flowing for subsequent frames.

The runtime detected that `sys-clk` is running and explicitly ignored the `CONKER_*_MHZ` requests, leaving
clock control to its profile. This avoids competing with sys-clk. It verifies the service is active, but the
log does not report the selected profile or the actual CPU/GPU/memory frequencies; the user's statement that
the console is overclocked is not independently confirmed by MHz readback. At that interim check the run was
still active; its final outcome is recorded below.

## 2026-10-19: diagnostic run reached Windmill twice and froze in MPBeach

The completed run used the same `545de116` NRO and log. Its route was `Frontend` → `Windmill` → `Hell` →
`Windmill` → `Frontend` → `Mp_Frontend` → `MPBeach`. It recorded two Windmill visits before the user-reported
multiplayer freeze. The final GPU timestamp was frame 15,085 at 7.299 ms. After that, the log reported
0.0 FPS and 0.0 Hz vblank; the watchdog confirmed no frame presented for 20 seconds and still none after
40 seconds. The host nxlink stream ended with `recv: Connection reset by peer` and `exiting ...`; there is
no `[CRASH]`, exception, or explicit process-crash report.

The stall coincided with repeated `[PB] NOP(237) trap still pending after 2 s (PMC_INTR 00001000 EN 00000001)`
messages. Four `[PB] FLIP_STALL` reports preceded the stop. The watchdog also recorded a thread waiting on
guest lock `0x004E1674`, held by thread 0; its holder had entered at guest address `0x004C38D8`. The lock
diagnostic showed five outstanding enters. Around the same point OHCI0 reported `guest IRQL never dropped
(depth 2); delivering anyway`. These overlapping synchronization signals make a PGRAPH/guest-lock/interrupt
interaction the leading diagnostic area; they do not yet establish which event caused the freeze.

The watchdog snapshot's saved guest stack includes return site `0x004CB0D2` in `sub_004CB0BD`, a generated
function categorized as `game_audio`. That function contains an APU MMIO polling loop at `0x004CB0EC`, and
the last guest indirect-call targets repeatedly include `0x00554CD4`, `0x00554C9E`, and `0x00554C76`, also
in game-audio code. The watchdog does not report the guest instruction pointer, so the stack is a lead rather
than proof that the APU polling loop was the active instruction. Meanwhile the APU stayed at 1,500 frames/s,
with zero queue underruns, drops, or device gaps; audio output continued to be paced during the missing
video frames. The log reported repeated profile flushes to the intended `sdmc:/switch/conker/prof.bin`
path, but that binary has not been copied to or independently verified on the host; the streamed log is the
analyzed artifact so far.

The log also gives a useful comparison for the Windmill hitches. The first visit logged 54 frames of at least
50 ms (30 at least 100 ms); 51 had no shader compile or texture upload. The second logged 78 such frames
(17 at least 100 ms); 74 had no shader compile or texture upload. For those hitch frames, the closest
available per-frame GPU timestamps (same frame or an adjacent frame because query results are asynchronous)
had medians of 7.214 ms and 9.145 ms for the two visits, with maxima of 9.530 ms and 10.196 ms. Two of the
78 second-visit samples exceeded 10 ms, and none exceeded 16.67 ms. This points away from shader/texture
work or GPU command-buffer execution as the
primary cost in most Windmill hitches, and toward guest CPU, renderer CPU, synchronization, or waits. GPU
timestamps do not measure CPU recording, presentation delay, or all waits, so they do not by themselves
identify the cause.

The user identified the Windmill event as a worm emerging from the ground and retreating after the player
moves away. The user associates the same spot with the earlier crash, the later freeze, and the current FPS
drops. This is a useful reproduction marker for the next capture. Although this diagnostic run loaded
Windmill twice, its log has no worm-state or player-position marker, so its hitch records cannot yet be aligned
to emergence or retreat. The profile summary across both Windmill visits names `memcmp`, `memmove`,
`nv2a_pb_exec_method`, and `nv2a_pb_scan` in the executor, but those aggregate sample shares are not
per-hitch CPU times and do not tie those functions to the worm event.

The session confirms a real presentation freeze in multiplayer and narrows the Windmill hitches away from
measured GPU saturation. Keep the two issues separate, with MPBeach first: it has PGRAPH NOP, guest-lock and
OHCI IRQL evidence, while the Windmill hitch trigger still needs event-aligned CPU and renderer attribution.
The runtime confirmed `sys-clk` was active but did not read back its selected profile or actual frequencies,
so this diagnostic capture is not a verified overclock benchmark. See [14-port-status.md](14-port-status.md)
and [16-optimization-plan.md](16-optimization-plan.md) for current priorities.

## 2026-10-19: MPBeach freeze source-trace findings and priority

The next investigation is the MPBeach freeze, ahead of Windmill FPS work. Source review narrows the PGRAPH
handoff to a measurable sequence. In the hooked pushbuffer path, `trap_deliver_hooked()` publishes the NOP
register state, asserts the PGRAPH interrupt, and waits for `s_trap_taken`. The D3D wrapper
`sub_005411D0()` enters `d3d_isr_enter()` (which may acquire the dispatch lock while managing the guest lock),
acquires the PGRAPH trap lock, calls the generated handler, and marks the trap taken only when `NSOURCE` is
set. A continuously pending NOP therefore means this acknowledgement sequence did not complete; the existing
log does not show which stage stalled. This is a code-path narrowing, not a root-cause finding.

OHCI's warning reads the modeled global IRQL-raised count after its bounded interrupt holdoff and then forces
delivery. A depth of 2 shows that the modeled interrupt mask remained raised at that point, but does not name
the raising thread or prove that the OHCI and PGRAPH symptoms share one cause. The guest lock reported at
`0x004E1674` is separately held by thread 0 at `0x004C38D8`; keep its ownership and the PGRAPH/IRQL handoffs
in the same time-ordered trace, but do not assume it is the runtime's GIL.

Next diagnostic change should add gated, low-volume stage markers/counters for NOP publication, D3D handler
entry, dispatch-lock/IRQL acquisition, trap-lock acquisition, generated-handler return, `trap_taken`, and the
guest-lock waiter/holder. Capture which marker is last before presentation stops. Do not change guest-lock,
IRQL, or PGRAPH acknowledgement semantics until that stage is identified. Windmill worm hitches remain
priority 2 and require their own event-aligned CPU/renderer capture.
