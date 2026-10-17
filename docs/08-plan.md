# Risks and plan for Conker

## Risks, most serious first

| Risk | Why | Mitigation |
|---|---|---|
| **NV2A texture-shader modes** (bump env map, dot-product chains) | Not implemented in the toolkit; Conker is a normal-mapped, per-pixel-lit, fur-shaded showcase | Census the modes from frame traces, implement in `gl_psh.c` with xemu as behavioural reference (no GPL code copied) ([05](05-renderer.md)) |
| **GPU / fill cost** | NFS titles were CPU-bound with an idle GPU; Conker's many passes (fur shells, post) may not be | Render scale 1× handheld, 460.8 MHz profile, ZCULL, fewer passes through game settings |
| **Rare's C++ engine** | Heavy virtual dispatch → missed functions, `[ICALL] Failed`, vtable garbage; xboxrecomp ranks custom engines harder than RenderWare | ICALL feedback (`recomp_icall_feedback.h`), stub tracing, ABI check from day one |
| **PAL disc** | Kernel reports NTSC-M/60 Hz/NA region; PAL XBE may refuse the region or run at 50 Hz | Report PAL region/standard + PAL-60; or use an NTSC-U disc ([01](01-target.md)) |
| **Xbox Live / XNet** (615 symbols) | Network init spins (Halo), unaligned atomics (NFSU2's XNet) | Stub the transport, make offline paths never wait; spinlock fallback for misaligned atomics already exists |
| **Direct framebuffer/tiled access from game code** | Horizon cannot alias; only device-aware library sections are folded | Watch for exception 257 at 0xF0xxxxxx; extend `XBOX_DEV_FOLD`/MMIO rewrite to the offending game functions |
| **Fixed-step main loop** | Slow motion below the Xbox's frame rate (Burnout, NFSU2) | Find the step logic, run it on real time ([03](03-reference-ports.md)) |
| Runtime data placed inside the image | Burnout's save signing keys were overwritten | Check the image end vs `xbox_RtDataPlace` |
| Toolkit copies diverged | Fixes live in four forks | Base on burnout3-sw's copy; port the others' features deliberately ([02](02-approach.md)) |

## Phases

**0. Setup**
- Extract the ISO (`tools.xiso unpack`; the game partition is at offset 0) to `game/` (git-ignored).
- `git init` this repo with a `.gitignore` for `*.7z`, `*.iso`, `game/`, `gen/`, `switch_sd/`, `build*/`.
- Vendor the toolkit from burnout3-sw, set up devkitPro + mesa-switch NVK + Switch glslang, and a Linux
  build host (VM/container) for regen and lavapipe.

**1. Analyse** (fill in the checklist in [01-target.md](01-target.md))
- `xbe_parser --json`, disasm (all code sections), func_id, abi_analysis, optional Ghidra names.
- Match XDK library functions against the reference ports to get the hook addresses ([03](03-reference-ports.md)).

**2. Boot on Linux**: entry point → title screen
- `main.c` from Burnout's (it has the most generic defaults); region/AV settings for PAL; D3D fence, vblank
  counter, vblank/PGRAPH wrappers; DSP doorbell; AC97.
- Seeds from `[ICALL] Failed` / `[STUB]` until the intros and title play.

**3. Menus, pad, saves on Linux**, then the first **Switch** run (GL in Eden, Vulkan on hardware): memory
aliasing, IPC bounce buffers, unaligned atomics, log devoptab, thread spreading, priorities.

**4. 3D world**: frame traces, texture-mode census, texture shader modes, then the other gaps (stencil, point
sprites, 3D textures) as the census demands. Correctness on lavapipe with validation, then hardware.

**5. Playable**: real-time simulation steps, audio (APU pacing, downmix), movies, saves, Switch wording,
options rows (scale/FXAA/aniso), widescreen if the game has it.

**6. Performance on the console** ([06](06-performance.md)): profile first, then frame lag / render thread,
lifter locals (registers, x87), native hot leaves with check modes, GIL tuning, caches + prewarm, LTO/PGO,
and the non-volatile guest memory A/B.
