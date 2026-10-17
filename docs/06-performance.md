# Performance

## Where the time goes in an original-Xbox recompilation on the Switch

Two threads decide the frame rate (NFSU1/NFSU2 console profiles):

1. **The game's main thread** running lifted x86 code (plus GIL waits).
2. **The executor thread** (`nv2a_ack_thread`): pushbuffer decode + our Vulkan recording + NVK. In NFSU1 at
   95-100 % of a core before the fixes: `pb_scan` + `exec_method` self time 33 % (one call per pushbuffer
   word; VS constant uploads ~55 % of race words, `ARRAY_ELEMENT16` ~28 %), our VK glue ~20 %, NVK ~10 %.

The GPU was idle in those titles. NFSU2 on Eden with every GL draw skipped still reached only 17-23 fps, so any
graphics API change is worth at most ~2×. Measure before rewriting the back end (the BO1 notes reach the same
verdict on deko3d).

Rule of thumb from NFSU2: fps ≈ draws per second the executor sustains / draws per frame. 30 fps at ~2000
draws/frame needs ~16 µs per draw.

## The levers, in the order they paid off

### Executor / renderer
| Change | Measured |
|---|---|
| Hash-chain texture and program lookups, last-program fast path, cached binds | part of NFSU2 6-12 → 11-20 fps |
| Skip the VP hash and the 3 KB constant memcmp with executor generation counters (`vp_prog_gen`/`vp_const_gen`); executor dirty blocks instead of an 8 KB register compare (was 14 % of the executor) | |
| Upload vertices as stored (`NV2A_BACKEND_RAW_DIRECT`), only present attributes, 16-bit indices | |
| **Frame lag**: wait on the previous frame's fence, not the one just built (`RECOMP_FRAME_LAG=1`) | Eden race 9-18 → 21-24 fps (NFSU1's D3D already did it) |
| **Render thread** (`RECOMP_GL_THREAD=1`; the VK version came from a third-party NFSU1 build, `RECOMP_VK_THREAD`) | took the GL build from executor-bound to game-bound |
| `nv2a_pb_exec_run`: constant and index runs in one loop; vertex input re-sent only on change; textures decoded straight into the ring; vertex buffers bound 8+8 (Mesa malloc'd for > 8) | NFSU1 race 13-17 → 26-28 fps (with OC) |
| VK instancing of draws differing only in transforms | 2382 draws → 1408 calls (NFSU1 race) |
| DXT uploaded compressed; only changed constant rows; ring maps without `INVALIDATE_RANGE` (GL) | hitches 133 → 33 per 90 s |
| Shader + pipeline caches with boot prewarm | race-start compiles 46-54 → 1-3. Console compile = 90-150 ms each |
| Next ideas listed by NFSU2: hazard-tracked barriers instead of `barrier_all` per pass break; texture uploads before the pass; ZCULL; constant block reuse | not done there |

### Game code (the lifter)
| Change | Measured |
|---|---|
| **Registers in C locals** (`_localize_registers`; stored before every call/ICALL/ITAIL, reloaded after) | Eden menu 29-32 → 38-40 fps; NRO 4.6 % smaller |
| **x87 stack top in a local** (`_localize_x87_stack`) | −5 % on x86; more on ARM (TLS) |
| MMX leaf registers in locals | IDCT 7.8×, MC 2.5× |
| Native replacements of hot leaves, bit-exact, with `RECOMP_NATIVE_CHECK=1` comparing against the lifted body (0 mismatches over millions of calls): `_ftol2`, SSE 4×4 multiply (15-18 % of NFSU2's game thread), frustum/box culling, LUT builders | main thread 6.4 → 5.4 ms/frame (one function) |
| Calls to wrapped overrides emitted directly instead of `RECOMP_ICALL_SAFE` | removes a binary search + trace per call |
| Seeding a missed per-frame function (`[ICALL] Failed` 10 k/race) | one run had fallen to 4 fps |
| LTO (`LTO=1`) | inlines almost nothing by itself (functions exceed `-O2` limits); `_ftol2` inlined at 569/581 sites when declared inline. Console A/B pending |
| Non-volatile guest memory (`RECOMP_MEM_VOLATILE=`) | no gain measured on x86; **never measured on the console**. BO1 (360) found guest memory without volatile "more fluid" there and ME +15-20 %. A/B it on hardware, with loop barriers so polling loops are not compiled into `b .` |
| PGO | not done; nfsmw-nx's toolchain notes list the Horizon pitfalls (`-fno-profile-values`, `-fprofile-correction`) |

### Scheduling
GIL eager handover, clock calls keeping the GIL, APU thread priority, spin hints. See [04](04-switch-platform.md).
Together these took the NFSU2 console race from ~17 to 19.5-22.7 fps.

### Game settings and resolution
- Render scale is the GPU lever (1× = the title's 640×480). The ports default to 1.5×. If the GPU becomes the
  limit (Conker's many passes may make it so, unlike the NFS titles), drop to 1× handheld.
- Turn off what the player won't miss at the game level (NFSU2's reflections row cut the cube-face passes).
  BO1 lesson: **turning a system off can leave shaders reading stale data**. Shrink it instead, and check with
  a frame trace.
- Lower resolution does nothing while CPU-bound.

## Next candidates (from the guide, 2026-10-17)

Recorded for when performance work resumes; none tried yet. Where Conker stands (console, NRO `084306cc`,
log `run/net_logs/20261017-163543.log`): 25–30 FPS in the training level with 20 FPS stretches where the GPU
executor reaches ~70 % of a core (game thread ~40 %); Windmill 24–25 FPS with the game thread at 65–91 %.
Earlier executor profile: `memmove` 6.9 %, `memcmp` 6.1 %, `nv2a_pb_scan` 4.3 %, `nv2a_pb_exec_method`
7.7 % of its samples. Sources: the guide's `02-how-the-switch-works.md`, `03-switch-performance.md` and the
Black Ops / Prototype research (`platforms/xbox-360/black-ops/`).

| # | Candidate | Why it may help Conker | Notes |
|---|---|---|---|
| 1 | **Fourth CPU core** through an NSP forwarder: `highest_cpu_id` 3 in both NPDM tables (ACID and ACI0), then thread core masks | Game thread and executor each need most of a core; the APU frame thread (~11 %), the NV2A flag thread and the kernel timer thread could move to core 3 | Core 3 is shared with system services, not exclusive. The forwarder needs the user's own `prod.keys` (never committed or published). The Black Ops decision: forwarder, not a patched `atmosphere/hbl.nsp`. Prototype 2 keeps audio on core 3 |
| 2 | **PGO trained on the console** | Lifted code is branchy and the game thread is the limit in Windmill; SA2 gained ~15 % | Instrumented build dumps gcov counters to `sdmc:/pgo` every 3 minutes (`__gcov_dump` + `__gcov_reset` on a helper thread), because the game is closed with HOME and never flushes at exit. Arc counts only (`-fno-profile-values`), same GCC and build-directory layout for the generate and use builds. Training builds stall: never benchmark them |
| 3 | **LTO + `-fipa-pta`** | Cross-function inlining in `gen/` and the runtime | Needs ~16 GB RAM for the link; check the Docker VM's limit |
| 4 | **Hot functions first in `.text`** (linker order from console samples) | ~21,000 lifted functions against a 48 KB I-cache | `tools/prof_log_report.py` already names the hot functions; keep `.crt0` first |
| 5 | **Less copying and comparing in the executor** | `memmove` + `memcmp` were ~13 % of the executor | Find the callers with `prof_log_report.py --callers` (`[profile-lr]`); the Prototype ports hash less in the renderer, and SA2 fingerprints with the A57's CRC32 instructions instead of XXH3 |
| 6 | **Native NEON memcpy/memset for the guest CRT's versions** | Guest copies run as lifted byte loops | Guard each replacement by a hash of the guest bytes; verify the first calls against the lifted version (the Prototype pattern: first 256 calls both ways, a mismatch disables the native path) |
| 7 | **Native hot game routines with verification** | Only after a console profile names a game function worth it | Same verification pattern as 6 |
| 8 | **GPU: no compute/graphics alternation** | Every switch between compute and drawing idles this GPU | The renderer's post passes (depth conversion, FXAA) are graphics passes; keep it that way. Depth is already D24S8 on the console (`[VK] ready: ... depth D24S8`), so the "64-bit depth on NVIDIA" warning does not apply |

Clocks: benchmark at stock clocks and note docked/handheld. CPU boost mode raises the CPU but drops the GPU
to a very low clock: at most for loading, never for gameplay. Do not hold a temperature-sensor (`ts`) session
open for the whole game (it coincided with Horizon OC's clock service crashing under load in the Prototype
ports).

## How to measure

- **Console only, stock clocks, one change per run behind a setting, A/B back to back.** Check the env file
  before trusting a run (one NFSU2 run had every setting commented out). Archive the exact ELF of each tested
  build (the profiler needs it).
- `[perf]` lines every 10 s: fps, APU frames/s (1500 = real time), executor/render-thread busy and idle,
  "executor held back", main-thread waits by caller, % of a core per thread.
- `[hitch]` lines: every frame > 50 ms with the programs compiled and textures uploaded in it.
- **Profiler** `RECOMP_NX_PROFILE=1` (busy threads) / `=2` (every thread over 2 %): 1 kHz samples (pc, lr,
  5 return addresses, 10 ms timestamp) into `prof.bin`; `tools/prof_report.py prof.bin <elf> <log> [--top N]
  [--time A-B]`. Thread entries are absolute: subtract the NRO base (`&_start`). Timestamps wrap every 655 s
  (the script unwraps). Without frame pointers, trust `pc` more than deep stacks (BO1 found the same).
- Report the frame-time distribution, not just fps: share of frames > 33/50/100 ms, worst. Frames show in
  16.67 ms steps; a fixed swap interval removes cadence jitter once ~90 % of frames fit it.
- Displayed fps from a capture: `ffmpeg -i clip.mp4 -vf "mpdecimate=hi=200:lo=64:frac=0.1,showinfo" -f null -`
  and gaps from `pts_time`.
- What misleads: **Eden** (caps race fps ~22; useful for menus and hitches only), **x86** (TLS and atomics are
  cheap there), **Linux race runs** (not repeatable: same build 15.0 vs 10.9 ms/frame). A static scene
  (main-menu idle, a car parked on the start line) is the repeatable benchmark.
