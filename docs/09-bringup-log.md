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
