# conker-nx docs

Nintendo Switch homebrew port of **Conker: Live & Reloaded** (original Xbox, Rare, 2005) by static
recompilation: the game's x86 code is lifted to C, built for AArch64 (devkitA64/libnx), and its own Direct3D
output (NV2A pushbuffers) is executed by a native Vulkan renderer on NVK.

Written 2026-10-16 from two sources:

- `external-docs/`: notes from a **Call of Duty: Black Ops (Xbox 360)** Switch port. Its toolchain is the
  360 one (PowerPC, ReXGlue, Xenos PM4), which does not apply to an original Xbox game. What carries over is
  the Switch platform knowledge, the renderer cost model on NVK and the measuring method. Those parts are
  merged into the docs below. Everything specific to the 360 or to BO1 was left out.
- The four original-Xbox ports by antoxa2584x: [nfsu1-sw](https://github.com/antoxa2584x/nfsu1-sw),
  [nfsu2-sw](https://github.com/antoxa2584x/nfsu2-sw), [nfsc-sw](https://github.com/antoxa2584x/nfsc-sw),
  [burnout3-sw](https://github.com/antoxa2584x/burnout3-sw). Read 2026-10-16 (shallow clones, nothing copied
  into this repo). **These are the model for this project.**

| Doc | Read it for |
|---|---|
| [01-target.md](01-target.md) | What Conker is technically, the disc we have, what to find out first |
| [02-approach.md](02-approach.md) | The chosen pipeline (xboxrecomp → C → NRO), toolchain, repo layout, licences |
| [03-reference-ports.md](03-reference-ports.md) | What each of the four Xbox→Switch ports needed, in order, with results |
| [04-switch-platform.md](04-switch-platform.md) | Horizon / libnx / NVK rules that will bite (memory, threads, IPC, clocks) |
| [05-renderer.md](05-renderer.md) | The NV2A executor + `nv2a_vk`: what works, its traps, **its gaps for Conker** |
| [06-performance.md](06-performance.md) | Measured levers, in the order they paid off, and how to measure |
| [07-debugging.md](07-debugging.md) | Switches, traces, dumps, pad scripts and the bug classes to grep for |
| [08-plan.md](08-plan.md) | Risks for Conker and a phased plan |
| [09-bringup-log.md](09-bringup-log.md) | What was done, in order: analysis results, every hook address and its evidence |
| [10-building.md](10-building.md) | Building the NRO: native devkitPro (current) or BO1's Docker way, the NVK driver, A/B builds |
| [11-testing-on-console.md](11-testing-on-console.md) | Wi-Fi test loop with nxlink: SD layout, launch arguments, getting logs back, failure modes |
| [12-porting-guide.md](12-porting-guide.md) | Technical architecture and reusable workflow for future original-Xbox-to-Switch ports |
| [13-build-process.md](13-build-process.md) | Reproducible regeneration, container validation, Switch build, staging, and upload process |

## The five things to remember

1. **Original Xbox ≠ Xbox 360.** Pentium III-class x86 + NV2A (a GeForce 3/4-class GPU) + 64 MB unified RAM.
   The tool is [xboxrecomp](https://github.com/sp00nznet/xboxrecomp) (x86 → C), not ReXGlue/XenonRecomp.
2. **Start from a fork that already runs on the Switch.** Upstream xboxrecomp targets Windows with a software
   GPU (Burnout 3 ran at 2-4 fps that way). antoxa2584x's vendored copy adds the Horizon platform layer, the
   GL and Vulkan NV2A back ends and many lifter/kernel fixes. Burnout 3's copy is the newest. The copies have
   diverged, so a few features have to be merged in from the others (see [02-approach.md](02-approach.md)).
3. **Fix the recompiler or the runtime, not the game.** Per-title work is addresses: D3D's device pointer,
   fence, vblank and PGRAPH handlers, DSP doorbell, seeds for functions the static pass misses. The mechanisms
   are the same in every title.
4. **Conker's renderer needs more than the NFS/Burnout titles did.** The NV2A *texture shader* bump-map and
   dot-product modes are not implemented in the toolkit (they sample as plain 2D). Conker is known for normal
   mapping and fur, so expect this to be the main renderer job. Verify it with a frame trace first.
5. **Only the console measures performance.** Eden cannot run NVK at all, lavapipe says nothing about speed,
   and x86 hides TLS and atomics costs. Measure at stock clocks with one change per run.
