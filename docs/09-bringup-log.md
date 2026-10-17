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
| 3 | Still black (now full size), and even "good" frames only show the ground next to the camera | Forcing the back-buffer clear to red (temporary hack) gave red frames with only a vignette and rain: the scene geometry is **not rasterised at all**, not drawn black. Skipping every draw after the opaque ones (`RECOMP_SKIP_DRAWS=263-999`) changes nothing. Combiner, fog (linear, enabled, colour `FF43628F`, params 1/1), blend and depth state of the opaque draws are identical in a good frame (4,050) and a black one (4,847). Every scene draw has `SET_CONTROL0` = `0x00100001`: bit 20 `Z_PERSPECTIVE_ENABLE` = **w-buffering**; `SET_ZMIN_MAX_CONTROL` = 1. The CPU interpreter's first vertices sit at z = 16.8–17.8 M (zmax 16,777,215) and mostly with w < 0 in the black frame | **open**. The renderer treats `oPos.z` as a 0..zmax depth and clips it; in w-buffer mode the depth is eye-space w scaled by the clip range. Plan in [14-port-status.md](14-port-status.md) |

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
verified on hardware. The black picture is the w-buffering problem found on the Linux bench (most of the
scene clipped), not a console-only fault.
