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
