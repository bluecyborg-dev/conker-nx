# Conker optimization plan

**Status (2026-10-18):** the cache-on/cache-off Windmill comparison on `e037bd66` reduced 3,072-byte
constant-block copies but did not confirm an FPS gain. A later profile-2 run stopped presenting at frame 2,831
with the game thread busy in `sub_000139D0`; the final overclocked diagnostic run `5924ba1f` passed that
frame and reached MPBeach, but lacked sampling profiling. It recorded repeated no-shader/no-texture Windmill
hitches. Keep the guest routine and renderer hot path as separate leads; the current Docker save route does
not reach Windmill.

This plan focuses on the reported gameplay slowdown near the former recursive-search freeze point, then uses measured results to improve frame pacing elsewhere. It follows the measurement and A/B methods in the port guide's `03-switch-performance.md` and Conker case study `platforms/xbox/conker/source-notes/06-performance.md`.

## Goal and quality guardrails

- First remove or reduce the repeatable slowdown at the former freeze location on Switch.
- Preserve the current image quality. Texture quality reductions are out of scope for this plan. Render resolution stays at its current default; a temporary render-scale change may be used only to isolate a proven or suspected GPU pixel/fill limit, and must be restored after diagnosis.
- Keep visual effects, audio, input response, and game behavior correct while improving frame-time consistency.
- Retain 30 FPS in sections that already approach it. Treat 60 FPS as a later headroom goal, after the localized slowdown and missed-frame pattern are understood.
- Do not change code based on average FPS or a profile from a different build. Keep correctness fixes separate from performance changes.

## What the current evidence says

| Evidence | What it supports | Limit |
|---|---|---|
| NRO `0678347d` held 29–30 FPS in most measured windows; the executor used about 43% of a core and the game thread about 59%. | The port has reached 30 FPS in gameplay, with room that varies by scene. | This is an earlier build and scene; it is not the baseline for the reported slowdown. |
| NRO `084306cc` reached 25–30 FPS with 20 FPS stretches in TrainingLevel; the executor was around 70% of a core in the cited stretch and the game thread around 40%. Windmill reached 24–25 FPS with the game thread at 65–91%. | The bottleneck changes with the scene; both guest CPU and renderer CPU need measuring. | Those percentages are from older runs and cannot classify the current dip. |
| NRO `f976b53f` reached a 433 ms frame near frame 3,533, then stopped presenting while the game thread spun in the child search. | It identifies where to repeat the test. | That build had the no-match retry bug. Its frame cost is not the cost of the fixed traversal. |
| The user reports that the latest candidate passed the former freeze point without crashing or stalling, but slowed down there. | The issue is now a performance report at a known gameplay location. | No runtime log from that pass was captured; the exact NRO, frame time, draw count, and CPU/GPU load are unverified. |
| NRO `630412bd` was captured in an alternate-mode hardware pass (`run/net_logs/20261018-012629.log`): multiplayer front-end assets and `MPBeach` loaded; final FPS windows were 18.0, 20.9, and 19.6. Late samples showed `game:0` at 86–95% of one core and another tracked thread at 54–60%. | The corrected build ran through this multiplayer-content route without crashing; it shows CPU-side pressure worth profiling in the workload that matters. | It reached only frame 1,939, did not confirm the reported single-player location, included shader-cache warming (321 to 370 programs), and has no GPU timing. This is not the targeted baseline. |
| Profile-enabled NRO `630412bd` (`run/net_logs/20261018-013420.log`) reported 4.1, 29.0, 21.5, 25.0, and 18.0 FPS before a PGRAPH NOP trap (`0x12C80041`) remained pending; the watchdog found no frames after 20 and 40 seconds. Before the stall, `game:0` peaked at 79% of a core, `nv2a_ack_thread` at 50%, and `nv2a_flag_thread` at 15%. | The capture exposes a synchronization stall and shows the game and renderer threads using meaningful CPU time before it; it gives us a concrete next reproduction target. | It stopped at frame 949 after loading `SoloSetup` text, did not reach the known slowdown, and `RECOMP_NX_PROFILE=2` may have affected timing. Thread ticks do not identify which physical core ran each thread; the sample-PC mix is not utilization. |
| Unprofiled NRO `630412bd` (`run/net_logs/20261018-014209.log`) loaded `Mp_Frontend` and `MPBeach`, reached frame 1,906, and logged 4.4–28.4 FPS windows; late `game:0` use reached 94% of a core and `nv2a_ack_thread` reached 71%. NOP traps continued to be handled. | The route passed frame 949 without the earlier pending NOP and showed substantial per-thread CPU use. | It ended on `Connection reset by peer` before frame 3,194, so it cannot rule out a later PGRAPH stall. It is multiplayer content and not the reported single-player slowdown. |
| Delayed `RECOMP_NX_PROFILE=1` NRO `630412bd` (`run/net_logs/20261018-014455.log`) reached frame 3,194. Settled windows were mostly 13.0–15.4 FPS; late `game:0` use was 85–92% of a core, `nv2a_ack_thread` 52–60%, and `nv2a_flag_thread` 22–29%. Executor caller samples included `nv2a_pb_scan`, `vk_draw_raw`, and `nvk_sw_emitted_equal`. | The lower-overhead capture passed the earlier frame-949 stall and identifies pushbuffer scan/draw-state handling as leads in the executor thread. | It later stopped on pending NOP `0x15200041`, with PGRAPH interrupt asserted and a guest-lock waiter. Caller sample shares are not CPU-time shares; the run has no physical-core placement or GPU timings and does not reach the single-player slowdown. |
| Profile-2 NRO `630412bd` (`run/net_logs/20261018-015143.log`) loaded `Level\Windmill\default.rbm` and reached frame 1,248 before nxlink reset. Settled FPS windows varied from 18.5 to 24.5 FPS; the last two vblank windows were about 59.9 Hz. In the final windows `game:0` was 90–93% of one core and the NV2A acknowledgement thread 45–49%. Executor caller samples included `nv2a_pb_scan` (18.8%), `vk_draw_raw` (13.1%), and `nvk_sw_emitted_equal` (6.7%); sampled executor PCs included `memmove`/`memcpy` (6.6%) and `nv2a_pb_scan` (4.4%). | A route reaching Windmill reproduces high game-thread and renderer-thread CPU use and makes command scanning, draw-state work, and copies reasonable optimization targets. | Profile sample shares are not CPU-time or GPU-time shares. `svcSleepThread` was a large sample category, no GPU timing or physical-core placement is available, and the log does not mark the exact previously reported slowdown event. The pass ended on connection reset without a logged crash, watchdog, or pending NOP. |
| First constant-block cache candidate `b8ff2fc5` (`run/net_logs/20261018-020128.log`) ran to frame 4,301 and loaded Windmill. In later 300-frame windows it reused about 50–61% of the vertex-program constant blocks. | Repeated 3,072-byte constant-block copies are avoidable when the guest constant generation and current command-buffer slot have not changed. The cache is now a concrete candidate to measure. | This run had `RECOMP_DRAW_STATS=1`, which enables culling diagnostics (about 13–21 µs/draw in this run); its 17.1–24.3 FPS windows cannot establish a speedup. The copy/reuse counters show opportunities, not elapsed time saved. |
| Clean cache-on NRO `e037bd66` (`run/net_logs/20261018-021534.log`) loaded Windmill and reached frame 2,016. After Windmill loaded, FPS windows were 22.3, 18.9, 22.6, 24.9, 24.8, and 30.0 with about 60 Hz vblank. The six cache windows ranged from 44% to 64% reuse. | The cache and its counters run without culling diagnostics; it completes the route without a logged crash or pending NOP. | This is one side of the completed A/B. Hitches of 383–468 ms recurred with no shader compiles or texture uploads. The FPS result is inconclusive without repeated runs; see the cache-off row below. |
| The cache-on and cache-off runs of the same `e037bd66` NRO are complete (`021534.log` and `021920.log`). Cache-on reused 44–64% of blocks; cache-off had zero reuse and more copies. | The cache prevents repeated 3,072-byte copies when its generation and command-buffer-slot conditions match. | One run per setting is not enough to distinguish a small gain from run-to-run variation. The FPS ranges overlap, and long hitches persisted in both modes; no frame-rate benefit is demonstrated. |
| Profile-2 `e037bd66` (`run/net_logs/20261018-022626.log`) loaded Windmill, then frames 2,830–2,831 took 1,902 and 2,086 ms. Presentation fell to 0 FPS/vblank; `game:0` stayed at 98–100% of one core. In late windows, 75.1% of main-thread sampled PCs mapped to `sub_000139D0`. | The immediate black-screen stall is associated with guest CPU work. Source inspection suggests a tree insert/rebalance routine; its parent-link fix-up loop is a concrete lead. | The profile does not prove a corrupt/cyclic tree or distinguish one long call from a high call volume. There is no exception, pending NOP, raw `prof.bin`, exact event marker, or GPU timing. |
| Overclocked diagnostic NRO `5924ba1f` (`run/net_logs/20261018-030841.log`) passed Windmill frame 2,831, reached at least frame 6,903 there, then loaded Frontend and MPBeach through frame 14,282. Windmill recorded 95 hitches of at least 50 ms; 90 had no shader compilation or texture upload. The whole run had 444 hitches; MPBeach frame 11,968 took 3,570 ms, including 2,069 ms compiling 20 programs. | The earlier presentation stop did not recur on this route; Windmill retains substantial no-resource frame hitches and MPBeach has both compile-bound and unexplained stalls. Audio remained paced. | No `RECOMP_NX_PROFILE=2` was passed and no tree diagnostic crossed its logging thresholds. Overclocked timing is not a stock baseline; no GPU timers or function samples identify the no-resource hitches. The run ended on nxlink reset with exit code 0. |
| A copy-on-write clone of `run/save` in `conker-dev` reached TrainingLevel; the chapter selector did not allow a direct Windmill jump. | The container can validate boot, save loading, and early gameplay. | It did not reproduce the Windmill stall. Lavapipe timing is not Switch performance evidence. |
| Two 60-second Docker cache A/B runs used independent `run/live/save` copies and the same profiled Linux Vulkan build. Both opened `BootIntro.xmv` and settled at 59.9–60.0 FPS; each 300-frame window copied 3,000 blocks and reused none. | This front-end route does not exercise the cache; the Switch Windmill reuse counters remain the relevant evidence for copy savings. | `RECOMP_LINUX_PROFILE=1` adds overhead, lavapipe reached its vblank limit, and the route does not reach Windmill; no optimization speedup can be inferred. |
| A 10-second `RECOMP_AUDIO_DUMP` from a separate Docker start recorded nonzero PCM only from 0.30–1.40 seconds after audio-device startup, followed by exact zero PCM to 10 seconds. The log opened `BootIntro.xmv`. | The current Linux route reproduces a short audio burst followed by silence and supplies raw PCM for analysis. | No timestamp ties movie frame zero to the sample clock; dummy SDL output cannot establish audibility or precise intro-relative cutoff. |
| The current Switch `[perf]` report includes FPS, APU pacing, per-thread CPU use and waits. `[hitch]` reports frames over 50 ms with shader compilation, texture uploads, and draw count. | We can begin with existing runtime diagnostics. | These logs do not report per-pass GPU execution time or a full per-frame histogram. The CPU sampler measures CPU PCs; it is not a GPU profiler. |

The former freeze fix around `sub_00354610` / `sub_00355B40` remains a correctness change, and its runtime cost is still unmeasured. The previous 433 ms frame must not be used as evidence that this path is still expensive. Renderer CPU work remains part of this plan: the measured leads include pushbuffer scan, method dispatch, state comparison, Vulkan recording, and avoidable constant-block copies. The cache has demonstrated fewer copies, but not a Switch frame-time improvement. The latest black-screen capture points first to guest work in `sub_000139D0`; diagnose that stall separately before changing renderer behavior.

The multiplayer captures show CPU pressure on `Mp_Frontend` / `MPBeach`, while the profile-2 and cache runs reach Windmill. In the sampled routes, `game:0` and the NV2A executor each use a large share of one core, and the process reports core mask `0x7`. The game still serializes guest code under `RECOMP_GIL`; logs do not say which physical core ran each thread. Executor caller samples point toward `nv2a_pb_scan` and draw-state calls, while sampled PCs also include wait/yield paths. The profile-2 stall capture concentrated game-main samples in `sub_000139D0`, while the later overclocked run passed the same frame without sampling. Neither result clears the renderer from the sustained no-resource hitch investigation. Do not change affinity or remove the guest lock based on these samples. GPU execution time remains unmeasured.

## Measurement rules

Use the Switch as the performance authority. Linux and container runs remain useful for correctness and reproducing guest logic, but their FPS cannot establish Switch performance.

For every benchmark, record:

- NRO short ID and the matching archived ELF; archive both together.
- Docked or handheld mode, stock clocks, render settings, and whether shader/pipeline caches were warm.
- Save point, level, camera, route, actions, and the time window containing the slowdown.
- Per-run frame-time/FPS data, draw count, game-thread and `nv2a_ack_thread` use, wait reasons, APU pacing, and shader/texture work.
- Any visible, audio, input, or stability regression.

Keep docked and handheld results separate. Do not use CPU boost or overclocking for gameplay benchmarks. Run a clean baseline without the sampling profiler first; run profiling separately because sampling and extra logging can change timing. Keep the route and warm-cache state the same across A/B runs. Repeat each baseline or candidate at least three times before treating a small difference as real.

Report distributions rather than only average FPS: median and p95/p99 frame time where available, worst frame, and the fraction of frames over 33, 50, and 100 ms. The present `[hitch]` log only catches frames above 50 ms, so the absence of a `[hitch]` line does not prove that all frames met a 30 FPS deadline. If the reported dip is below that threshold or the 10-second `[perf]` windows obscure it, add a low-overhead frame-time histogram or a narrow event capture before changing gameplay code.

## Phase 1: capture the corrected-build baseline

1. Confirm which NRO is actually on the console. Use archived NRO `630412bd` for a reproducible pass if that is the candidate the user tested; otherwise record the tested short ID and use its matching archived ELF.
2. Use one repeatable route through the gameplay location, with the same save, movement, camera, and scene state. Let the shader/pipeline cache warm before the measured pass. Include at least 10 seconds before the slowdown and 10 seconds after it.
3. Capture three passes at stock clocks in one device mode. Keep a recording or written event marker so the log's 10-second windows and frame numbers can be aligned with the observed slowdown. Do not run a frame trace or verbose graphics dump during this baseline.
4. Stream the normal runtime log over nxlink. Switch `[perf]` summaries and `[hitch]` lines are already enabled unless logging has been disabled. Example with the current archived candidate:

   ```sh
   NRO=analysis/elf_archive/conker-vulkan_630412bd.nro tools/nxlink_run.sh <switch-ip>
   ```

5. Save each timestamped file from `run/net_logs/` with the build ID and run number. Do not rely only on `latest.log`, since a later run replaces that link.

This gives the unprofiled reference and checks whether the slowdown repeats, how long it lasts, whether draw count changes, whether shader/texture work is active, and whether audio or input pacing changes with it.

## Phase 2: profile CPU work during the same route

Run a separate pass with the Switch sampling profiler. Start with `RECOMP_NX_PROFILE=2` to include threads above the 2% sampling threshold; it writes `prof.bin` to the SD card and also emits periodic `[profile]` summaries to the streamed log. This run diagnoses CPU hot spots; do not use it as the final FPS benchmark.

```sh
NRO=analysis/elf_archive/conker-vulkan_630412bd.nro \
ARGS="RECOMP_NX_PROFILE=2" \
tools/nxlink_run.sh <switch-ip>
```

Use the ELF from the same archived build to resolve function names:

```sh
python3 tools/prof_log_report.py run/net_logs/<profile-run>.log \
  analysis/elf_archive/conker-vulkan_630412bd.elf --top 25
```

Use the `[profile]` windows and, if needed, retrieve `prof.bin` for a time-scoped report. Ignore deep sampled stacks when frame pointers are absent; treat PCs and hot-function counts as the stronger evidence. If profiling changes or hides the slowdown, note that and use shorter/focused captures rather than interpreting the profiled FPS as representative.

### Interpret the first profile

| Observation around the slowdown | Likely critical path | Next investigation |
|---|---|---|
| Game main thread is busy while `nv2a_ack_thread` has clear idle time and little time waiting. | Guest CPU work. | Resolve hot PCs against the exact ELF. If samples land in `sub_00354610`, `sub_00355B40`, or adjacent generated code, count iterations and inspect inputs for the fixed route. Verify why the work repeats before considering caching or a semantics-preserving algorithm change. Do not add an arbitrary early exit. |
| `nv2a_ack_thread` is busy and the game thread often waits for command completion. | CPU-side pushbuffer decode, renderer state preparation, Vulkan recording, resource work, or driver calls. This thread's CPU use does not mean the GPU is busy. | Use caller-attributed samples and targeted CPU timers/counters for pushbuffer words, methods, draws, state changes, copies/hashes, upload bytes, allocations, barriers, submits, and fence waits. Compare work per frame at the slowdown with a nearby normal section. |
| Game and renderer CPU threads are not busy enough to explain the missed cadence. | GPU execution, presentation/vblank waits, scheduling, synchronization, asset work, or a frame cap may be limiting. | Inspect wait callers, `[hitch]` compile/upload counts, APU statistics, and presentation cadence. Add GPU timing instrumentation as described in Phase 3 before changing render workload. |
| APU frame pacing falls below 1500 frames/s, stale ring samples rise, or audio output gaps coincide with the dip. | Mixer or thread-scheduling pressure may be contributing. | Identify the busy/waiting thread and event sequence first. Keep gameplay clocks and priorities unchanged until the responsible wait or contention is measured. |
| Shader compilation or texture uploads recur during the same warm-cache route. | Cache misses, invalidation, or repeated resource preparation. | Confirm the cache path and cache hit state, then measure the repeated compile/upload source. Do not conflate this with the fixed recursive-search path. |

Historical executor samples named `memmove`, `memcmp`, `nv2a_pb_scan`, and `nv2a_pb_exec_method`; these are leads only if the corrected-build profile shows them again in the affected workload. Use `--callers` or the profiler's caller view before optimizing a generic library function.

## Phase 3: measure GPU work if the CPU profile does not explain the dip

The current Conker Vulkan path has no `vkCmdWriteTimestamp`, timestamp query-pool result, or per-pass GPU time in its runtime logs. The port guide describes GPU timestamps on a cited NVK build reading about 1.6 times low; that ratio is not a calibration for Conker's current driver.

If Phase 2 leaves GPU load unresolved, add an opt-in, low-overhead Vulkan timing mode in this repository before trying GPU reductions:

1. Check that the exact Horizon/NVK device exposes valid timestamp queries and record the device, Mesa/NVK build, timestamp valid bits, and period.
2. Add frame-boundary timestamps and coarse scopes for scene rendering, shadow/fur work, post-processing, resolve/present, and any explicit queue/fence wait. Start with these scopes rather than a query around every draw.
3. Read results from a ring of completed frames after their fence, without synchronously waiting on the frame being measured. Count dropped/unavailable query results and compare an instrumented run with the uninstrumented baseline.
4. Calibrate the query path on the exact driver/build and retain raw ticks plus converted time. Keep GPU execution, CPU recording, CPU wait, and presentation intervals separate; they overlap and must not be summed as if sequential.
5. If timestamps are unavailable or unreliable, triangulate with CPU busy/idle and wait data, queue/fence back-pressure, draw and pass counts, and only a temporary render-scale A/B. Restore the default immediately afterward.

Do not call the port GPU-bound solely because the executor thread is busy or draw count is high. Conversely, low CPU use does not prove GPU saturation without GPU timing or consistent queue/fence evidence.

## Phase 4: optimize only the measured limiting stage

Change one factor at a time, behind a runtime/build setting where practical, and keep the original path for A/B comparison.

### If guest CPU is limiting

- Attribute samples to exact guest routines in the matching ELF and compare affected versus unaffected frames.
- Count calls/iterations in the suspected work and validate the relevant guest data. For the child traversal, preserve the no-match completion behavior and parent/child processing semantics; optimize only repeated work proven by the profile.
- Consider native replacements only for a measured hot routine, with the existing native-check path comparing it against lifted output. Verify deterministic behavior and sampled edge cases before measuring performance.
- Consider code-generation, register-localization, LTO/PGO, direct-call, or function-ordering changes only after the profile shows the corresponding cost. These alter broad generated code and should follow smaller targeted changes.

### If renderer CPU is limiting

- Use counts and narrow timers to locate the work: command scanning, method dispatch, state comparisons, texture/program lookup, vertex preparation, copies/hashes, allocation, Vulkan recording, barriers, submissions, or fence waits.
- Prefer removing redundant work while preserving guest command order and resource contents: cache unchanged derived state, avoid repeated copies/hashes, reuse allocations, and reduce unnecessary host calls where their inputs and invalidation rules are understood.
- Validate command/draw counters and representative frame output. Fewer Vulkan calls alone do not prove less guest work or better frame time.

### If GPU execution is limiting

- First identify the costly pass or bandwidth path using calibrated timestamps and target dimensions/formats.
- Look for redundant resolves/copies, excessive barriers, unnecessary attachment work, or pass dependencies that can be preserved with less work. Keep guest-visible ordering, depth/stencil, blending, and shader inputs correct.
- Texture quality stays fixed. Do not make a permanent resolution change as the default fix. A temporary render-scale A/B is allowed only to confirm pixel/fill sensitivity; any sustained quality trade-off needs a separate decision based on evidence.

### If waits, scheduling, or presentation are limiting

- Identify the precise wait caller, producer, and queue state. Check whether game, renderer, APU, and presentation threads are runnable and which thread blocks progress.
- Test scheduling or frames-in-flight changes only after the wait is understood. Measure input-to-present latency, audio continuity, and frame-time spread along with throughput.
- Keep clocks at stock for results. A CPU boost mode that reduces GPU clock is not a gameplay optimization.

## Phase 5: validate each candidate

For each performance change:

1. Confirm correctness on Linux or in the container where useful, but make no performance claim from that run.
2. Build and archive the exact NRO/ELF pair. Keep the profiling setting off for the scored run.
3. Repeat the same Switch route, mode, clocks, cache state, save and settings at least three times for baseline and candidate.
4. Compare frame-time distributions, slowdown duration, draw/pass/resource work, CPU busy/wait time, calibrated GPU time if available, APU pacing, and input-to-present behavior.
5. Check the affected scene and nearby scenes for image, effect, audio, input, save, crash, or stability regressions.
6. Keep the change only when its improvement repeats beyond run-to-run variation and quality/behavior remain intact. Otherwise revert it and record the result.

Once the local dip is controlled, repeat profiling in the previously measured TrainingLevel and Windmill workloads. Use those results to prioritize broader headroom and evaluate the 60 FPS stretch target without sacrificing the current presentation quality.

## Immediate next action

The final overclocked capture `5924ba1f` (`run/net_logs/20261018-030841.log`) passed the earlier Windmill
presentation stall and reached `MPBeach`, but it was built without `RECOMP_NX_PROFILE=2`. It therefore
provides route, hitch, draw-count, and thread-load evidence, not function-level attribution. Windmill had
95 hitches of at least 50 ms; 90 had no shader compilation or texture upload. `MPBeach` included both
compile-related stalls and large hitches without resource work. Keep the renderer hot path active: earlier
Switch caller samples implicate `nv2a_pb_scan` and `vk_draw_raw`, while the newest capture cannot distinguish
renderer CPU, guest CPU, GPU time, or waits.

First, rebuild and run the current candidate in Docker with the preserved cloned save, confirm the build and
startup path, and inspect focused host-side timings around pushbuffer scanning and Vulkan draw submission.
The Docker chapter selector does not reach Windmill, so treat this as a correctness and directional
measurement only. Compare one isolated renderer change at a time and record the exact commands, build,
scene, and limitations. The existing vertex-constant cache saves block copies, but its one-run Switch A/B
has overlapping FPS and no demonstrated speedup; do not describe it as a proven performance fix. Keep the
cache opt-out available for further checks.

Do not change `sub_000139D0` semantics, scheduling, affinity, or the guest lock from the unprofiled overclocked
capture. The tree diagnostic emitted no lines at its 128-iteration and 16,384-call thresholds, which means
only that the thresholds were not reached in this route. The user cannot perform another Switch run for now;
continue with source inspection and Docker tests, then leave a ready-to-run combined profiler/diagnostic
configuration for a later hardware session without asking for one now.

In a separate follow-up, revisit the intro audio using early startup logs/builds where the user recalls that
the intro had sound while the front end was black. Verify what the logs actually captured, compare the XMV
producer and DirectSound callback/refill behavior across the relevant revisions, and trace why only the first
two audio packets are queued. Do not treat initialized APU output or a nonzero audio peak elsewhere in the
session as proof that the intro soundtrack was audible.

After the guest stall is understood, measure the previously reported slowdown from a repeatable single-player
save point with an event marker. Compare marked frame time, draw count, resource work, guest-thread CPU, and
renderer caller samples before changing the fixed traversal. The pending PGRAPH NOP issue remains separate;
if it recurs, capture the acknowledgement together with guest lock `0x004E1674` and OHCI guest IRQL delivery.
Do not change thread affinity or guest locking until the synchronization path is understood. Add calibrated
GPU timing if CPU evidence still does not isolate the critical path.
Record the resulting evidence and any resolved issue in [09-bringup-log.md](09-bringup-log.md), and keep [14-port-status.md](14-port-status.md) aligned with the current priority. This plan is specific to `conker-nx` and is not copied into the port guide.
