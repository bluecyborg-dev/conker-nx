# Switch platform rules (Horizon, libnx, NVK)

Merged from the BO1 360 port's field guide (`external-docs/SWITCH_OPTIMIZATION_GUIDE.md`) and the four Xbox
ports. Where both measured the same thing, both are cited.

## Hardware

| Part | Fact | Consequence |
|---|---|---|
| CPU | 4× Cortex-A57 at **1020 MHz** docked and handheld; a game gets cores 0-2, core 3 is the system's | ~100 core-ms per frame at 30 fps; single-thread speed is the limit for lifted code |
| Caches | L1D 32 KB, L1I 48 KB, **L2 2 MB shared**, DRAM ~250 cycles | big working sets thrash; code locality matters (LTO, function ordering) |
| TLB | 32-entry L1 DTLB, 1024-entry L2 (4 MB reach with 4 KB pages) | prefer 2 MB-aligned mappings for guest RAM |
| Memory | 4 GB LPDDR4 shared; ~8 GB/s from one core; 1331 MHz handheld, 1600 docked | every CPU copy (vertex uploads, texture decode, untiling) competes with the GPU |
| GPU | Maxwell GM20B, 256 lanes; **307.2 MHz handheld default, 460.8 with the official profile, 768 docked** | request apm config `0x92220008` (GPU 460.8 + mem 1331.2) handheld |
| GPU caches | L2 256 KB | full-screen passes and big targets are bandwidth-bound |
| Storage | microSD UHS-I 60-95 MB/s sequential; A2 cards 15-25 % faster on streaming | random small reads hurt; bad cards fail silently (keep old block contents) |
| Process memory | ~3.2 GB with title takeover, ~400 MB in applet mode | always launch with full memory (hold R) |

The original Xbox needs only 64 MB of guest RAM plus mirrors. Memory size is not the problem. Aliasing is.

## Memory: aliasing is the Xbox-specific trap

- The Xbox reaches the same RAM at 0x0 and through the 0x80000000 contiguous window, and the tiled
  framebuffer aperture at 0xF0000000 is another view. Windows uses file-mapping views and Linux uses shared
  mappings. **Horizon:** `svcCreateSharedMemory` → 0x4201 (and may kill the process on hardware),
  `svcMapPhysicalMemory` → 0xFA01. The NFSU2 runtime uses **code memory** (`svcCreateCodeMemory` +
  `svcControlCodeMemory(MapOwner)`), which cannot alias, then tries `svcMapProcessMemory` on its own process
  for second views (log `[NX] aliasing views with svcMapProcessMemory` or `... refused`). The fallback folds
  0x80000000-0x83FFFFFF onto low RAM in `XBOX_PTR` and the runtime's translations, and folds
  0xF0000000-0xF7FFFFFF onto 0x80000000 in device-aware (lifted with `--mmio-sections`) code
  (`XBOX_DEV_FOLD`). **Game `.text` that writes through a tiled pointer would still fault.** Watch for it in
  Conker (Rare's own engine may touch the framebuffer directly).
- `RECOMP_NO_MIRRORS=1` reproduces the Switch's no-mirror situation on a desktop. Use it on Linux so the bugs
  show up there first.
- **Never pass guest memory to a Horizon IPC buffer.** `read()`/`write()` of guest RAM into the fs service
  froze the whole console on small unaligned save-file reads. NtReadFile/NtWriteFile go through a `.bss`
  bounce buffer on `__SWITCH__`. Same lesson from BO1: Horizon's socket service could not read GPU-mapped
  memory.
- No `open()` on directories; FAT cannot hold sparse files (create partition images empty, report the size).
- Close directory handles on `NtClose` (leaks abort Atmosphère's ams.mitm and freeze the console).
- From the 360 port (applies to any recompiled code): GCC can merge two 64-bit context copies into one q-register
  access; avoid relying on vector registers across faults. Horizon loses vector registers when a thread is
  pre-empted inside an exception handler. That is why page-watching/emulated memory access is avoided.

## Threads and scheduling

- **Only priority 59 (0x3B) is time-sliced; every other priority is cooperative.** libnx creates pthreads at 59
  with preferred core 0. Spread guest threads over cores 0-2 (`xbox_nx_spread_thread`). **Never put threads on
  core 3**: Eden reports mask 0xF, but core 3 does not time-slice 59, and busy threads there starved each other.
- Host service threads go above the guest (lower number): audio 0x2B/0x2C, clock keeper 0x2C, ring/executor
  ~0x2C-0x2D. When a thread starves, **lower the hog, don't raise the starving one**. A thread at 0x3F starved
  behind busy 0x3B guests (NFSU2's clock keeper).
- `SetThreadPriority` from the guest only reached `win32_compat` bookkeeping, not Horizon. The APU frame thread's
  HIGHEST request had to be applied by hand (`xbox_nx_raise_host_thread`).
- switch-sdl2's audio thread asks TIME_CRITICAL, which maps to 59 → late refills, crackle; wrapped to 0x2B.
- **The guest lock (GIL)** serialises lifted code (fixes real races in game code written for one CPU). It is
  released in every kernel call, every 64 poll-loop turns (`recomp_spin_yield`), and at function entry when
  someone waited > 1 ms (`RECOMP_PREEMPT`). Tuning that paid off in NFSU2:
  - `RECOMP_GIL_EAGER=1`: the main thread and time-critical threads (the audio mixer) pre-empt at once,
    everyone else keeps the 1 ms rule (race 17 → 19.5 fps; GIL wait 24 % → 10 %).
  - Clock calls (`KeQuery*Time`, performance counter; ordinals 125-128) **keep the GIL**. The mixer polled them
    ~400 k/s, each a handover → 0.5-1.5 s frames. Worst frame 1540 → 77 ms.
  - IRQL raise/lower calls keep the GIL unless the dispatch lock is contended. Pre-emption checks the
    *per-thread* dispatch state, not the global IRQL.
  - APU lock handed over after every APU frame (Horizon mutexes are unfair); voice-lock bits set atomically.
- **Busy-waits → real waits.** On the Xbox a spinning thread costs only itself. Here it steals one of three
  cores. `tools/recomp/spin_hint.py` marks the title's poll loops (single block, back-edge to itself, no
  stores/calls, fixed addresses) with `RECOMP_SPIN_HINT()` (pause, wake hardware threads every 16, yield every
  64). NFSU2 had 45 (D3D fence, PGRAPH polls, DirectSound APU-clock polls). The flag/ack threads sleep when
  idle and are woken by `recomp_spin_wake()`. A fixed sleep instead of a wake slowed every kickoff. BO1 found
  the same pattern (job queue requeue spin, PulseEvent as signal+yield+sleep). The BO1 lesson for the throttle
  is to **never throttle the main thread**.
- A yield on Horizon only gives way to threads of the same priority. Zero-timeout waits in a loop are a spin
  in disguise.
- Kernel calls cost microseconds (signalling with no waiter, fence queries, mapping, IPC). Avoid them per draw.
- `thread_local` is a function call: libnx builds with `-mtp=soft`, and every TLS access calls
  `__aarch64_read_tp`. Guest registers are TLS in xboxrecomp. GCC calls it once per function, so the cost is
  per call, which is why "registers in C locals" won 25-30 % in NFSU2 menus.
- Never read `cntvct_el0` (faults): use `armGetSystemTick`. `std::thread::detach()` can throw: use persistent
  workers. Decide sleep/wake under the lock (lost wake-ups hang).
- Clock overflow: `count * 1e6 / freq` on a QPC that counts ns since host boot wrapped after 2.6 h uptime.
  Use a proper scale.

## Logging

- The SD log was the **boot bottleneck** (each `fflush` = an SD write: ~33 s to display mode). Use a `log:`
  devoptab that appends to RAM with a timestamp per line and a thread that writes every 0.5 s (the crash
  handler drains it). `*_LOG_SYNC=1` only for hangs.
- Never block a hot thread on the log. BO1's network log sink called `send()` inside the sink mutex; a Wi-Fi
  stall froze the whole game for 1.7-4.4 s. Queue lines and send from their own thread.
- Floats printed inside the log device's `%f` timestamp shared newlib's dtoa buffer, so every fps figure was a
  copy of its timestamp. Integer-format the timestamp.
- `open_memstream` (newlib) froze the game on Horizon (BO1): write to a plain file instead.
- `RECOMP_QUIET=1` on Switch (periodic kernel/GPU summaries each flushed stderr).

## Clocks and power

- Stock clocks are the target (overclocked numbers hid the real limit for days in NFS:MW). NFSU1's "30 fps"
  was measured at 1785/768/1600 MHz: report clocks with every result.
- Opt-in overrides (`*_CPU_MHZ`, `*_GPU_MHZ`, `*_MEM_MHZ`) via clkrst/pcv, restored on exit, re-applied by a
  keeper thread at 0x2C plus an applet hook (dock/sleep/HOME reset them). If sys-clk / Horizon OC
  (`hoc:clk`, `sys:clk`) is running, don't fight it (a clock fight froze a console after 11 min).
- CPU boost (`appletSetCpuBoostMode`, 1785 MHz) throttles the GPU to 76.8 MHz: unusable in play, but fine for
  **loading screens** (Nintendo's own games do it).

## NVK on Horizon

- **Eden cannot run NVK** (no submission ever completes). Test Vulkan builds on hardware. Eden runs the GL build.
- Every GPU allocation is several kernel round trips (nvMapCreate, VA, map, memset + cache clean). NFS:MW measured
  ~1.9 ms per dedicated texture allocation. The number of NvMap handles is limited (`0x235C`, `nvMapCreate failed`
  after minutes). **Sub-allocate textures from 32 MB slabs**, free on a background thread, release only after
  the GPU's fence.
- Every barrier is a full GPU idle. Each `vkQueueSubmit` is an IPC; aim for one per frame.
- **ZCULL** needs depth images without `TRANSFER_DST` usage. Our depth images ask for it only for the
  initial `vkCmdClearDepthStencilImage`, so clear with `loadOp CLEAR` instead (NFS:MW: ~2 ms GPU per frame).
  BO1 caveat: enabling ZCULL there gave no clear gain and coincided with an input oddity. A/B it.
- GPU timestamps on NVK read ~1.6× low (× 1.627).
- Present: one queue, three swapchain images, FIFO and IMMEDIATE only (IMMEDIATE does not tear; the compositor
  composes at 60 Hz). Present from the thread that renders. Swapchain 1280×720 handheld, 1920×1080 docked.
- Switch Mesa's scaled, flipped `glBlitFramebuffer` writes outside the destination rect (GL build): scissor it.
