# Port status

Where the port stands right now: the last milestone reached, the milestones so far, and the open issues with
what probably causes each and what should fix it. Update it whenever an issue is found or closed or a milestone
is reached; the full history of how each one was found stays in [09-bringup-log.md](09-bringup-log.md).

When a big milestone is reached, copy this file into the guide
(`nx-port-guide/platforms/xbox/conker/`).

**Last milestone (2026-10-18):** the final overclocked hardware capture on diagnostic NRO `5924ba1f`
completed and is recorded in `run/net_logs/20261018-030841.log`. It passed Windmill frame 2,831, continued
through at least frame 6,903, returned to Frontend, then loaded `Mp_Frontend` and `MPBeach` through frame
14,282. The earlier presentation stall did not recur in this run. Across 32 Windmill performance windows,
FPS ranged 21.9–34.7 with vblank near 60 Hz; 95 frames took at least 50 ms, including repeated six-frame
bursts at 217–283 ms. Ninety of those 95 hitches had no shader compilation or texture upload. This supports
continued investigation of CPU/renderer work, but the run omitted `RECOMP_NX_PROFILE=2`, so it cannot name
the hot functions. The tree diagnostic emitted no records at its configured thresholds; this weakens but
does not disprove the suspected `sub_000139D0` fix-up loop. The run ended by nxlink connection reset with
exit code 0 and no crash/exception report. It was overclocked and is not a stock performance benchmark.
**Focus: use the capture as route and hitch evidence, pursue a narrowly measured optimization in the Linux
container, and keep the renderer hot path active alongside the guest CPU investigation.** Diagnostic NRO
`545de116` has now been sent to hardware; its 2026-10-19 profile-2 capture is in progress in
`run/net_logs/20261019-012749.log`. The log confirms profile-2 sampling, per-frame GPU timestamps, the
watchdog arguments, and a live `sys-clk` service. Conker left clock control to sys-clk; the log does not
report its active MHz or prove that its selected profile is overclocked. The title reached at least frame 595
without a logged crash at the latest check. Continue the same overclocked Windmill route and retain the
nxlink session through the user's run. The container's save route still cannot jump directly to Windmill.
The reconstructed first-success checkpoint `6d26ed5d` has now launched on the Switch; the user confirms its
intro video and audio both play correctly.

**Builds:** Linux bench `build/linux-vk/conker_recomp`. Latest diagnostic Switch candidate
`analysis/elf_archive/conker-vulkan_5924ba1f.{nro,elf}` (tree-insert logging enabled; not a benchmark).
Latest comparable candidate `analysis/elf_archive/conker-vulkan_e037bd66.{nro,elf}` has the constant cache
on by default; its cache A/B used culling diagnostics off. The earlier culling-instrumented candidate is
`analysis/elf_archive/conker-vulkan_b8ff2fc5.{nro,elf}`. The corrected baseline is
`analysis/elf_archive/conker-vulkan_630412bd.{nro,elf}`. The Linux build and live startup reached frame 534
without a crash. Profile-2 captures on `630412bd` and `e037bd66` loaded Windmill; the latter stopped
presenting at frame 2,831 with `sub_000139D0` as the dominant late game-main sample. Candidate `b8ff2fc5`
reached frame 4,301 after loading Windmill but enabled culling diagnostics, so its FPS is diagnostic only.
The cache-on and cache-off runs on `e037bd66` are both complete, one run each, and did not establish a
speedup. The diagnostic Linux target `build/linux-vk-tree-diag/conker_recomp` compiled and reached
TrainingLevel from a cloned save but did not provide a direct Windmill route. Diagnostic Switch NRO
`5924ba1f` completed the overclocked route in `run/net_logs/20261018-030841.log`; its build has tree-insert
diagnostics but no sampling profiler. Older captures
include an unprofiled multiplayer run that reached frame 1,906 and a
delayed `RECOMP_NX_PROFILE=1` run that stopped at frame 3,194 with a pending PGRAPH NOP and guest-lock
waiter. The user's reported FPS drop at the former freeze point remains without a clean, directly marked
single-player measurement. Earlier candidates:
`f976b53f` stalled at frame
3,533; `3260c845` crashed in the first guard attempt; `cfd4c805` (commit a4747ae, `RECOMP_DOF=0` by default)
was the build before the crash guard.

**Prepared next diagnostic build:** `analysis/elf_archive/conker-vulkan_545de116.{nro,elf}` (NRO MD5
`545de116f420fcd449a26f576a768d0b`), staged at `switch_sd/switch/conker/conker-vulkan.nro`. It includes
tree-insert counters and optional Vulkan GPU timestamps. Launch with
`RECOMP_NX_PROFILE=2 RECOMP_VK_GPU_TIMING=1 RECOMP_WATCHDOG_SECS=60 RECOMP_WATCHDOG_KEEP=1`; the CPU sampler
captures renderer callers and stack return addresses, and the GPU timer reports per-frame command-buffer
duration. Docker confirmed the timer emits values alongside the Linux CPU profile. No Switch data is available
for this NRO yet.

**Latest hardware capture (2026-10-18, profile-2 NRO `e037bd66`, `run/net_logs/20261018-022626.log`):**
loaded Windmill and reached frame 2,831. Frames 2,830–2,831 took 1,902 and 2,086 ms, with 1,254 and
1,175 draws; only frame 2,830 reported texture work (three textures, 0.1 MB, 5 ms), and neither frame
reported shader compilation. Later windows fell to 0.1 FPS and then 0.0 FPS / 0.0 Hz vblank while `game:0`
stayed at 98–100% of one core. In profile windows 12–20, 75.1% of the game-main sampled PCs mapped to
`sub_000139D0`. Source inspection suggests a tree insert/rebalance routine with an upward parent-link walk;
a cycle is possible but unproven. The NV2A thread also had renderer work samples, but this capture points to
guest CPU as the immediate stall lead. APU pacing and audio stayed stable. No exception, crash report, pending
NOP, or watchdog report was logged; the nxlink connection later reset. Treat this as a black-screen
presentation stall, not a confirmed process crash. The sampler is diagnostic, not a performance benchmark.

**Completed hardware capture (2026-10-18, diagnostic NRO `5924ba1f`, `run/net_logs/20261018-030841.log`):**
the NRO was sent with no `RECOMP_NX_PROFILE` argument and initialized under title takeover/full memory. The
overclocked route loaded Frontend, Windmill, Frontend again, `Mp_Frontend`, and `MPBeach`, reaching frame
14,282. Windmill ran past the prior frame-2,831 presentation stall through at least frame 6,903. Across 32
Windmill FPS windows, it ranged from 21.9 to 34.7 FPS with vblank near 60 Hz. The 95 Windmill hitch records
(frames of at least 50 ms) included 51 at or above 100 ms and 50 at or above 200 ms, with a maximum of
608 ms. Ninety of 95 had no shader compile or texture upload; there were no shader compilations in Windmill.
Repeated six-frame runs of 217–283 ms occurred around frames 2,476–2,481, 2,894–2,899, 3,051–3,056,
3,098–3,103, 4,478–4,483, 5,163–5,168, 5,501–5,506, and 6,898–6,903. This points toward guest CPU or
renderer work, but there are no function samples or GPU timers to distinguish them.

Across the full capture there were 444 hitch records, 77 at or above 100 ms, 67 at or above 200 ms, and a
3,570 ms maximum. In `MPBeach`, 315 hitch records included 19 at or above 100 ms and 13 at or above 200 ms.
Shader compilation explains several large frames: frame 11,968 took 3,570 ms, including 2,069 ms compiling
20 programs; frame 12,068 took 1,985 ms, including 1,073 ms compiling eight programs. Other large
`MPBeach` hitches had no shader compile or meaningful texture upload, so shader work is not the only source
of stalls. The final sample was 21.1 FPS at 60.0 Hz vblank. Audio stayed at 1,500 APU frames/s with no
output gaps, queue underruns, or dropped buffers; heap use peaked at 658 MB.

There were no `[profile]` or `[tree-insert-diag]` lines. The diagnostic thresholds were 128 iterations for
individual fix-up reports and 16,384 calls for aggregate reports; their absence means no threshold was
observed, not that `sub_000139D0` was never called. No crash/exception/watchdog or unresolved PGRAPH NOP
was logged. The run ended with `recv: Connection reset by peer`, `exiting ...`, and `EXIT_CODE=0`, consistent
with a normal host-side stop. Overclocked FPS is diagnostic context, not a stock-clock benchmark. Preserve
the guest routine semantics until source and profile evidence identify a specific safe change.

**Previous hardware capture (2026-10-18, cache-on NRO `e037bd66`, `run/net_logs/20261018-021534.log`):**
loaded Windmill and reached frame 2,016 before the nxlink connection reset. After loading Windmill, six FPS
windows ranged from 18.9 to 30.0, with vblank near 60 Hz. Cache stats reported 44–64% block reuse across six
300-frame windows. Long hitches of 383–468 ms occurred at frames 1,299–1,301, 1,470–1,473, and
2,013–2,016 without shader compiles or texture uploads. No crash or pending NOP was logged; APU pacing and
audio output remained stable. The cache-off control is complete below; one run per setting showed no
confirmed speedup.

**Previous hardware capture (2026-10-18, profile-2 NRO `630412bd`, `run/net_logs/20261018-015143.log`):**
loaded `Level\Windmill\default.rbm` and reached frame 1,248 before nxlink reset, with no logged crash or
pending NOP. Settled FPS windows ranged from 18.5 to 24.5; the final two vblank readings were about 59.9 Hz.
Late samples showed `game:0` at 90–93% of one core and the NV2A acknowledgement thread at 45–49%.
Executor caller samples included `nv2a_pb_scan` (18.8%), `vk_draw_raw` (13.1%), and
`nvk_sw_emitted_equal` (6.7%). These are profile sample shares, not CPU-time or GPU-time percentages; this
diagnostic run is not a benchmark and does not mark the exact reported slowdown event.

**Previous optimization candidate hardware run (2026-10-18, NRO `b8ff2fc5`, `run/net_logs/20261018-020128.log`):**
loaded Windmill and reached frame 4,301 without a logged crash or pending NOP. Cache counters showed about
50–61% reuse in later windows. `RECOMP_DRAW_STATS=1` also enabled culling diagnostics, so the FPS readings
are not suitable for comparison and no speedup is confirmed. The later clean cache-on and cache-off runs of
`e037bd66` are recorded above and below.

**Previous captured hardware log (2026-10-18, NRO `630412bd`, delayed low-overhead profile, `run/net_logs/20261018-014455.log`):**
launched with `RECOMP_NX_PROFILE=1 RECOMP_NX_PROFILE_AFTER=15`, loaded the multiplayer front end and
`MPBeach`, and reached frame 3,194. Settled windows were mostly 13.0–15.4 FPS with 60 Hz vblank; the last
window reported 10.2 FPS and 47.4 Hz. At frame 3,191 one shader compiled in 119 ms; frames 3,192–3,194
reported 467, 101, and 84 ms. A NOP trap with parameter `0x15200041` then remained pending with PGRAPH
interrupt status asserted (`PMC_INTR=0x00001000`, enabled). The log also found thread 1007 waiting on guest
lock `0x004E1674`, held by thread 0 at guest PC `0x004C38D8`, and reported an OHCI guest IRQL that never
dropped at depth 2. Before the stall, `game:0` used about 85–94% of one core, `nv2a_ack_thread` about
52–71%, and `nv2a_flag_thread` about 14–29%. The profile's caller samples in the executor included
`nv2a_pb_scan` (19.8%), `vk_draw_raw` (13.8%), and `nvk_sw_emitted_equal` (8.7%); these are sample shares,
not CPU-time or GPU-time percentages. The run used core mask `0x7` and serialized guest code under
`RECOMP_GIL`. No crash or exception was logged. This run also stopped before the known single-player
slowdown and does not establish physical-core placement or GPU execution time.

**Previous captured hardware log (2026-10-18, NRO `630412bd`, unprofiled, `run/net_logs/20261018-014209.log`):**
loaded the multiplayer front end and `MPBeach`, reached frame 1,906, and then ended with `recv: Connection
reset by peer`. No crash, exception, or pending NOP was logged before that disconnect. FPS windows ranged
from 4.4 to 28.4, with late windows at 12.8–21.7 FPS; late `game:0` samples reached 94% of one core and
`nv2a_ack_thread` reached 71%. This run passed the frame where the earlier profile-2 capture stalled, but
ended before frame 3,194, so it is not a full-duration control for the later hang.

**Earlier captured hardware log (2026-10-18, NRO `630412bd`, profiler enabled, `run/net_logs/20261018-013420.log`):**
launched with `RECOMP_NX_PROFILE=2`, loaded the `SoloSetup` text asset, reached frame 949, and then stopped
presenting. The last nonzero window was 18.0 FPS / 36.2 Hz vblank. A NOP software trap with parameter
`0x12C80041` remained pending; watchdog snapshots at 20 and 40 seconds showed the same guest stack and
PGRAPH interrupt still asserted. No crash or exception was logged. Before the stall, `game:0` peaked at
79% of one core and `nv2a_ack_thread` at 50%; the reported thread use did not show all three available cores
fully busy. Guest code was serialized under `RECOMP_GIL`. This profile does not establish physical-core
placement or the cause of the original slowdown. The capture is diagnostic and its FPS is not a benchmark.

**Earlier captured hardware log (2026-10-18, NRO `630412bd`, `run/net_logs/20261018-012629.log`):** ran with
default settings in title-override full-memory mode (3,189 MB reported), loaded multiplayer front-end assets
and the `MPBeach` package, and reached frame 1,939. Ten FPS windows ranged from 4.4 to 28.6; the final
three were 18.0, 20.9, and 19.6 FPS. Late samples showed `game:0` at 86–95% of one core and another tracked
thread at 54–60%. This suggests CPU pressure, but the log has no GPU timings and this route did not confirm
the former single-player slowdown. Shader programs increased from 321 to 370 during the pass, so its
performance windows include shader-cache warming. Audio reported no gaps, underruns, or dropped buffers.
The client closed the nxlink connection normally; no crash or exception was logged. All 145 kernel thunks
resolved; the log contains one existing `NtFsControlFile` file-operation stub. Player 1 was assigned the
handheld pad, but the runtime did not explicitly log docked/handheld power or clock mode.

**Earlier captured hardware log (2026-10-18, NRO `f976b53f`, `run/net_logs/20261018-005801.log`):** launched
with no arguments and default settings in title-override full-memory mode (3,189 MB reported). It opened
`BootIntro.xmv`, reached frame 3,533, then presented no more frames. Watchdog samples at 20 and 40 seconds
show the game thread at 99% CPU and an unchanged stack in `sub_00354610` called from `sub_00355B40`.
The user later reported that the latest candidate passed this location without a crash or stall, but with
an FPS drop; the multiplayer-content capture does not identify that location or verify its frame timing. The intro's 4:3
presentation and soundtrack still need hardware confirmation.

**Previous hardware run (2026-10-18, NRO `3260c845`, log `run/net_logs/20261018-005259.log`):** the first
sentinel guard crashed during startup at guest VA `0x434C9CF6` while dereferencing an invalid parent
pointer. The revised guard compares against the saved search base. Details for both that crash and the
earlier gameplay crash on NRO `cfd4c805` are in [09-bringup-log.md](09-bringup-log.md).

**Previous hardware run (2026-10-18, NRO `cfd4c805`, log `run/net_logs/20261018-001825.log`):** the user
played single-player until a guest access crash at frame 1,466. The last performance windows were 18.8,
25.0 and 22.8 FPS, with 571–572 MB of heap in use. There was no preceding `[ICALL]` or `[STUB]` report.

**Previous hardware run (2026-10-17, NRO `084306cc`, log `run/net_logs/20261017-163543.log`):** played by
the user through TrainingLevel, TrainingCave, ThroneRoom and Windmill; no crash or unresolved call. Gameplay
"better than ever"; the loads into the training areas no longer freeze (no multi-second frame); some
cutscenes now clear (talking with Birdy), others still blurred over the whole screen, so the cutscene depth
of field is now off by default (below). 25–30 FPS in the training level with some 20 FPS stretches, 24–25
in Windmill; first visits to ThroneRoom and Windmill stalled 4–6 s compiling shaders (cached afterwards).

**Previous hardware run (2026-10-17, NRO `0678347d`, log `run/net_logs/20261017-152423.log`):** played by the
user. 30.0 FPS in 34 of the run's 10-second windows and 29–30 in most others; menu transitions a lot
smoother; gameplay better and more stable. Still there: very very minor stutters (not a focus), blurry
cutscene shots, and no loading screen between sections (the game froze for a couple of seconds instead, for
example entering the area with the first weapon in the training level). The emulated vblank counter read
only 3–7 Hz in gameplay while the game held 30 FPS (see the performance issue below).

## Milestones

| Date | Milestone | Where |
|---|---|---|
| 2026-10-16 | Full regen builds for AArch64 (21,284 functions) and links | Linux, Switch |
| 2026-10-16 | Boots past D3D device creation, loads fonts and front-end assets | Linux |
| 2026-10-16 | Builds its `Z:` cache from scratch (directories, texture tips, audio banks) | Linux, Switch |
| 2026-10-16 | Intro movie `BootIntro.xmv` plays with picture | Linux |
| 2026-10-17 | Boots and plays the intro movie on a console (NRO `31500df5`) | Switch |
| 2026-10-17 | Profiles menu reached and driven by pad scripts (Start pressed early) | Linux |
| 2026-10-17 | Title-screen 3D flythrough partly draws (shadow maps cleared white, right surface presented) | Linux |
| 2026-10-17 | Front end runs on the console with its music and no memory errors (picture still black) | Switch |
| 2026-10-17 | **Front end renders and is playable**: title tavern, profile created and saved, Dumbots level/team/class select and lobby | Linux |
| 2026-10-17 | **Single-player campaign plays**: new game, the full opening, control in the training level | Linux |
| 2026-10-17 | **The game plays on the console**: boot to the training level by hand, steady 20 FPS | Switch |
| 2026-10-17 | Version 0.8 tagged (NRO `688d985e`): no audio static, tail and shadows right, caches work | Switch |
| 2026-10-17 | **Steady 30 FPS in gameplay** (NRO `0678347d`, vertex attributes unpacked on the GPU) | Switch |
| 2026-10-18 | Revised recursive-walk guard reaches frame 2,149 on Switch and frame 3,882 on Linux without a crash | Linux, Switch |
| 2026-10-18 | Candidate no-match search fix built; user reports passing the former freeze point, with an FPS drop | Linux, Switch report |
| 2026-10-18 | Constant-block cache A/B completed on one Windmill run per setting; copy reuse confirmed, speedup inconclusive | Switch |
| 2026-10-18 | Profile-2 Windmill run stopped presenting at frame 2,831; late main-thread samples concentrated in `sub_000139D0` | Switch |
| 2026-10-18 | Diagnostic Switch NRO `5924ba1f` continued through Windmill and reached MPBeach without the prior frame-2,831 stall; no crash logged | Switch |

**Priority (2026-10-17):** get to a visible, playable game scene as soon as possible. The Linux bench may use
a different resolution or aspect ratio from the Switch; exact aspect-ratio matching can wait. The current
640×480 back-buffer capture shows geometry projected far outside the view, so aspect ratio alone does not
explain the black screen.

Next milestones: investigate the capture's repeated no-resource Windmill hitches through Docker-side source
profiling and a narrowly measured optimization; do not claim Switch speedup from lavapipe results. Keep the
renderer hot path active because earlier Switch caller samples identify `nv2a_pb_scan` and `vk_draw_raw`,
while the newest run lacks function samples. The constant-block cache reduces copies but has no demonstrated
frame-rate benefit yet. Continue tracing the XMV/DirectSound refill issue, using the early sound-on/black-menu
history as a lead while distinguishing documented log evidence from the user's recollection. Revisit the
reported single-player slowdown when a repeatable route is available, and preserve visual quality.
## Known issues

Each issue: **culprit** = what probably causes it, **fix** = what should solve it. Tick it once it is solved
and say how.

- [x] **No-match recursive child search caused an invalid recursion or retry loop** (Switch, NROs `cfd4c805`, `3260c845`, `f976b53f`, and candidate `630412bd`, 2026-10-18).
  - Evidence: exception 257, guest fault address `0xFFFFFFF0`; the native PC maps to
    `sub_00355430 + 312` (`gen/recomp_0046.c:20736`), which reads the first argument's object at `+0x10`.
    The caller passed `EDI=0xFFFFFFE0`; the read at `+0x10` matches the reported fault address. No unresolved
    indirect-call or stub report preceded the exception.
  - Culprit (identified): `sub_00354610` searches a 32-byte-entry collection with index initialized to
    `-1`. If it finds no match, it returns `base - 32`; on this run `base` was null, yielding
    `0xFFFFFFE0`. `sub_00355B40` passed that sentinel to `sub_00355430` without checking it.
  - First guard attempt (NRO `3260c845`) stopped the original bad recursion but crashed in the guard
    itself: it dereferenced the saved parent at `[esp + 0x40]`, which was invalid in this recursive walk
    (second log, guest VA `0x434C9CF6`, `sub_00355B40`, `loc_00355C85`).
  - New hardware evidence (NRO `f976b53f`): it reached frame 3,533 without an exception, then stopped
    presenting frames. The 20-second and 40-second watchdog samples show 99% game-thread CPU and the same
    guest stack at `sub_00354610`, called from `sub_00355B40` at `loc_00355C85`. The no-match guard returned
    to `loc_00355C91`; if the parent still had unprocessed children, that code could retry the same search
    without changing its input. This is the likely infinite-retry path; the watchdog does not capture the
    guest instruction pointer, so the loop is inferred from the stable stack and control flow.
  - Resolution: the no-match branch now jumps to `loc_00355C9F`, which takes the existing exhausted-child
    path and continues parent processing. The regenerated-code patch is preserved in `tools/regen.sh`.
    Linux compile and live startup passed (frame 534, about 53 FPS); the user reports the latest hardware
    candidate passed the previous freeze point without a crash or stall. There is no host-captured runtime
    log for that replay, so the next issue tracks its reported FPS drop separately. See
    [09-bringup-log.md](09-bringup-log.md).

- [ ] **FPS drops at the former recursive-walk freeze point** (Switch, latest candidate `630412bd`, 2026-10-18).
  - Evidence: the user reports the game continued past the prior freeze location but slowed there. The
    preceding captured run on `f976b53f` logged a 433 ms frame at 3,533 before the infinite retry began.
    The new `630412bd` capture (`20261018-012629.log`) reached frame 1,939 through multiplayer content and
    did not reproduce or measure the reported single-player location. Its late windows were 18.0–20.9 FPS,
    with `game:0` at 86–95% of one core, but this is not evidence about the slowdown's cause.
  - Cause and next step: unresolved. The bounded child search and surrounding traversal may still be
    expensive, but that is only a hypothesis. The later profile-2 Windmill capture `022626.log` stopped
    presenting at frame 2,831 and identified a separate guest routine, `sub_000139D0`, as a dominant late
    sample; the log does not mark whether this was the user's exact former freeze point. After investigating
    that stall, capture the fixed build from a repeatable single-player save point and mark the reported
    location before changing the bounded traversal.

- [ ] **Intermittent Windmill presentation stall / severe CPU frame hitches** (Switch, NROs `e037bd66` and `5924ba1f`, 2026-10-18).
  - Evidence: profile-2 log `run/net_logs/20261018-022626.log` records 1,902 ms and 2,086 ms frames at
    2,830–2,831 followed by zero FPS/vblank. `game:0` remained at 98–100% of one core; 75.1% of its late
    sampled PCs were in `sub_000139D0`. In the later overclocked diagnostic capture `030841.log`, the game
    passed frame 2,831, reached at least frame 6,903 in Windmill, then continued through MPBeach to frame
    14,282. However, 95 Windmill frames still took at least 50 ms and 90 had no shader compile or texture
    upload. That capture omitted sampling profiling, so it cannot identify the hot function. Neither run
    logged an exception or process crash.
  - Cause (hypothesis): `sub_000139D0` resembles tree insertion/rebalancing; a cycle was suspected but no
    tree diagnostic met its report threshold on the later route. The recurring no-resource hitches remain
    consistent with guest CPU or renderer CPU pressure; GPU time and function samples are missing.
  - Next step: keep guest semantics unchanged. Use Docker to rebuild and compare one isolated renderer
    optimization at a time, while retaining the caveat that the save route does not reach Windmill. Preserve
    `tools/tree_insert_diag.py` and combine it with `RECOMP_NX_PROFILE=2` on a later hardware build when a
    Switch run becomes available. Do not add a loop cap or skip rebalancing without evidence.

- [ ] **PGRAPH NOP trap remained unacknowledged in the profile-enabled pass** (NRO `630412bd`, 2026-10-18).
  - Evidence: `run/net_logs/20261018-013420.log` reports that NOP parameter `0x12C80041` was still pending;
    FPS and vblank fell to zero, and the watchdog saw no frame after 20 and 40 seconds. Earlier NOP traps
    were handled in the same run. The pass reached frame 949 after loading `SoloSetup` text.
  - Follow-up evidence: the unprofiled pass `014209.log` reached frame 1,906 with no pending NOP before the
    connection reset. The delayed profile-1 pass `014455.log` later stopped at frame 3,194 on NOP
    `0x15200041`, with PGRAPH interrupt asserted and a guest-lock waiter. This makes the synchronization
    failure reproducible under more than one profile setting, though the unprofiled pass ended too early to
    rule out a later hang. No crash or exception was logged.
  - Cause and next step: unresolved. After the console is recovered, run the same multiplayer route without
    profiling through at least frame 3,200 or until it stalls. If the NOP wait recurs, trace the PGRAPH
    acknowledgement alongside guest-lock `0x004E1674` and IRQL delivery. Keep this separate from the former
    recursive-search slowdown until the single-player route is captured.

- [x] **R5G6B5 shadow-map clears were decoded as cyan** (Linux and Switch renderer path).
  - Culprit: Conker's projected shadows render into 128×128 and 64×64 R5G6B5 (16-bit) surfaces cleared with
    `0x0000FFFF`, which is white in R5G6B5. The renderer keeps every colour surface as ARGB8888 and used the
    raw value, so the shadow maps were cyan, and the three `DST_COLOR × ZERO` shadow passes over the whole
    scene multiplied it to black.
  - Fix (done 2026-10-17): `clear_color_argb()` in `xboxrecomp/src/kernel/nv2a_pb_exec.c` widens
    R5G6B5 / X1R5G5B5 clear values before handing them to the back end. Found by skipping draws by blend mode
    (`RECOMP_SKIP_BLEND=306/0`). This fixed one scene-darkening cause and exposed geometry in some Linux
    views; it did not solve the current black menu, which remains open below.
- [x] **Flythrough shows a small black square instead of the scene** (Linux, from about frame 4,300).
  - Culprit: the Vulkan back end presented the last surface *touched* (drawn or cleared). After compositing
    its glow onto the back buffer, the game clears its 256×256 glow target, so the flip showed that cleared
    target (dumps came out 341×256 instead of 853×480).
  - Fix (done 2026-10-17): `vk_flip()` presents the last surface *drawn* in the frame (`s_last_drawn` in
    `xboxrecomp/src/nv2a_vk/nv2a_vk.c`) and falls back to the last one touched if nothing was drawn.
- [x] **Most of the 3D scene missing, then a black title screen** (Linux and Switch).
  - Culprit (found 2026-10-17): the lifter emitted the x87 instruction `fincstp` as a comment. The game's
    rotation-matrix builder `sub_003E2E60` runs three `fsincos`, sets `cos·scale` aside with `fincstp` and
    reads it back as `st(6)`; as a no-op the stack ran one slot off and row 0 of every roll matrix came out
    zero. `sub_00046490` multiplies the camera's look-at (`sub_0029BCA0`, itself correct) by that roll
    matrix, so the camera view collapsed onto its y axis and the world projected tens of thousands of pixels
    off screen. All depth, clip and cull theories (including `SET_CONTROL0` bit 20 as a w-buffer flag) were
    wrong leads; the renderer was drawing what it was given.
  - Fix (done 2026-10-17, commit 1bc623e): `fincstp`/`fdecstp` move `g_fp_top` (`lifter.py`, test in
    `test_lifter_fpu.py`). The title tavern renders. How it was found, step by step: 2026-10-17 entries in
    [09-bringup-log.md](09-bringup-log.md) and [15-black-screen-investigation-summary.md](15-black-screen-investigation-summary.md).
- [x] **Static ("heavy rain", TV noise) on menu selections, in cutscenes and in gameplay** (Switch and Linux).
  Confirmed fixed on the console (NRO `688d985e`, 2026-10-17).
  - Culprit: DirectSound gives the APU `MmGetPhysicalAddress()` of its buffers; for memory above RAM (the
    extended-VMA range at `0x74000000`) that is the VA passed through, and `apu_phys()` masked it to 26
    bits. A stream segment at `0x7415D7A0` was read from `0x0015D7A0`, the game's code, played as
    full-scale noise.
  - Fix (commit c130f84): addresses in `[0x08000000, 0x80000000)` are VAs. Linux capture: no noise left.
- [ ] **Intro movie audio stops after under a second on some builds** (Switch and Linux; current build comparison open).
  - Evidence: `BootIntro.xmv` contains 227 packets and later audio data for all four mono tracks. The game
    initially queues only two ADPCM packets per track (about 0.9 seconds). APU notifications, IRQ 5, the
    deferred procedure call and DirectSound completion callbacks execute, but the stream queue lookup returns
    no next buffer and no later XMV packet is submitted. A Docker `RECOMP_AUDIO_DUMP` captured 10 seconds of
    device PCM: nonzero samples from 0.30–1.40 seconds, then exactly zero through 10 seconds. The log opened
    `BootIntro.xmv`, but has no shared timestamp tying its first frame to the audio sample clock.
  - First explicit failing hardware report reviewed: NRO `e807fd88`, `run/net_logs/20261017-064742.log`;
    the user reported the intro audio dropped out in under a second. The first `[perf] audio out` summary
    had peak `16810`; the next three had peak `0`, followed by nonzero peaks later in gameplay. These
    summaries corroborate brief output and silence, but do not locate the exact cutoff. This run predates
    `c130f84` and `0d9fb5c`; neither introduced the first observed failure. The early Switch logs only show
    APU startup and movie open. In a later hardware comparison, the user confirms both picture and sound play
    correctly on reconstructed first-success source-state NRO `6d26ed5d` (`52a4270`). The confirmed old
    state and the failed `e807fd88` run bound the behavior to different revisions, but do not identify the
    exact regression. No APU, DirectSound, or XMV implementation change appears in the source diff from
    `52a4270` to `66ef96c`. The initial renderer failure and guest XMV/DirectSound producer are separate
    paths. The Docker PCM A/B of the pre-`c130f84` and
    current APU address mapping produced similar nonzero samples for two seconds and exact zero for seconds
    2–10 in both captures. This says the VA mapping does not explain the cutoff
    duration in this headless route; it cannot verify soundtrack identity, audio quality, or Switch audibility.
    The selected hardware checkpoints are `31500df5` (first successful run), `a43804b` (pre-lifter-fix
    investigation), `1bc623e` (black-scene fix), `c130f84` (high-VA APU fix), and archived `688d985e` as a
    later known-good reference. The original first-success NRO `31500df5` is absent, but its source state
    (`52a4270`) has been rebuilt as NRO `6d26ed5d` with a matching unstripped ELF. Its MD5 differs from the
    historical binary, so treat it as a source-state reconstruction. Four nxlink attempts failed, then the
    fifth transferred the NRO and launched it. `run/net_logs/20261018-215038.log` shows the title starting
    the APU and opening `BootIntro.xmv`. The user confirms both intro video and audio play correctly on this
    first-success source reconstruction. This establishes sound on that source state, but not on later builds.
    Builds from revisions `a43804b`, `1bc623e`, and `c130f84` still need rebuilding;
    `688d985e` and its matching ELF are archived. Docker PCM confirms only a short signal burst, not audible
    or correct Switch music.
  - The earlier shader/pipeline-stall explanation is unconfirmed: Linux traces show long early frames with
    zero shader compilations and about 2 ms spent uploading three textures. The configured cache path did not
    resolve the audio cutoff.
  - Fix/next: unresolved for later/current builds; no safe audio change identified. Compare the current build
    with the confirmed-audio source checkpoint `6d26ed5d`, then trace the four voices' segment addresses and
    queue state through the first completion to find why no packet follows packet two. See the
    2026-10-18 review in [09-bringup-log.md](09-bringup-log.md).
- [ ] **Intro movie is widened to gameplay aspect** (4:3 source; NRO `3260c845`, Switch verification pending).
  - Cause: the present path expands 640×480 title content to 16:9 when widescreen is enabled.
  - Fix: both GL and Vulkan now detect the XMV's 640×480 YUY2/UYVY texture (`0x24`/`0x25`, pitch 1280)
    and retain its native 4:3 aspect for that frame. Build and check the intro on hardware.
- [x] **Conker's tail draws magenta** (Switch and Linux).
  - Culprit: the tail fur samples a 64×64 `SZ_A8Y8` and a 64×64 `SZ_G8B8` texture; neither had a decoder,
    so both were uploaded as the undecodable-texture magenta.
  - Fix (commit 9882f42): `AY8`, `A8Y8`, `G8B8`, `R8B8` decoders (xemu's channel placement). The tail is
    orange fur with a white tip.
- [x] **Two shadows following Conker / dark quads on the ground** (Switch and Linux).
  - Culprit: the projected shadow maps are sampled clamp-to-border with border `0x00FFFFFF` (white = no
    shadow); the Vulkan samplers always used transparent black, and the shadow passes multiply the scene
    by the sample.
  - Fix (commit d300139): the sampler takes the nearest fixed border colour, colour before alpha.
- [ ] **Some cutscene shots blurry, some sharp** (Switch, user report). Still there on NRO `688d985e` and
  `0678347d`. On NRO `084306cc` some cutscenes are clear (Birdy) but others still blur the whole screen
  (no cutscene is a movie: only `BootIntro.xmv` is ever opened). **Workaround (user's call): the cutscene
  depth of field is off by default** (`RECOMP_DOF=0` in `src/main.c`; the executor drops a draw that
  samples the depth buffer it is bound to; `RECOMP_DOF=1` brings it back). Open question for later: why
  some shots still blur everything (focus constants, the stencil byte, or the depth scale).
  - Culprit, in two parts. (1) The game reads its Z24S8 depth buffer as a colour texture; the depth lived
    only in a Vulkan image, so the texture came from stale guest bytes (fixed in 00f1cb4 by converting the
    depth on the GPU). (2) That conversion wrote the texels of one format, `LIN_R8G8B8A8` (0x41), which is
    how the glow pass reads the depth. The cutscene depth of field reads it as `LIN_A8B8G8R8` (0x3F), where
    alpha is the depth's high byte and blue its middle byte. Its six combiner stages compare those two
    bytes with a focus constant (`0xED…35`), scale the difference by 16 and square it as (2a − 1)², so
    pixels at the focus depth stay sharp and nearer and farther ones take the blurred image. With alpha 0
    from the wrong byte order the result was full blur on every pixel of every shot that used it (the
    near grass sharp and Conker blurred in the wake-up scene, for example).
  - Fix: the conversion writes the dword `(z24 << 8) | stencil` as its bytes in memory order and each
    guest format samples it through a view with that format's channel swizzle (`depth_texture_view()` in
    `nv2a_vk.c`: 0x41, 0x3F, 0x40, 0x12, 0x1E). The wake-up scene now opens blurred, then holds Conker in
    focus with the near flowers and the background soft. Stencil is still not converted (the depth of
    field does not use it).
- [x] **No loading screen between sections; the game looks frozen for a few seconds instead** (Switch,
  user report on NRO `0678347d`: entering the area with the first weapon in the training level; the same
  happens loading the training level from the profile menu on Linux). Fixed (commit a19d7b2); on NRO
  `084306cc` the training-area loads no longer freeze.
  - Culprit: Conker's loader never flips. Each loading step draws a progress-bar sliver into the back
    buffer (`80964000`) and then copies the whole back buffer into the front one (`80A90000`, the buffer
    the CRTC scans out) with a full-screen quad, a fence after each pair: 13,400 draws and one flip in 13.6
    s on Linux. The hardware shows it because the CRTC reads the front buffer every vblank; the renderer
    presented only on flips, so the last gameplay frame stayed up. Found with `RECOMP_SURF_STATS=1` (draws
    per surface, control methods and draw runs of any frame over 2,000 draws) and
    `RECOMP_FRAME_TRACE_DRAWS=3000-3011`.
  - Fix: a draw into the scanned-out buffer (`PCRTC_START`, read by `xbox_Nv2aScanout()`) at least 100 ms
    after the last flip presents that buffer, at most every 33 ms (`scanout_present()` in
    `xboxrecomp/src/kernel/nv2a_pb_exec.c`; `RECOMP_SCANOUT_PRESENT=0` turns it off). The Linux bench now
    shows the "Loading..." screen with its progress bar where it showed the menu frozen.
- [ ] **Minor stutters in the menu and the intro movie** (Switch, user report; low priority). Still some
  very minor stutters with the shader cache in place (NRO `688d985e`); "very very minor" on NRO
  `0678347d`. Main-menu transitions were a bit slow; a lot smoother on NRO `0678347d`.
  - Culprit: shader/pipeline compiles on first use (no cache until now) and `[hitch]` frames of 50–120 ms
    in the movie.
  - Fix: re-check with the cache in place.
- [ ] **Level loads and cutscenes stop on unresolved calls** (Linux, 2026-10-17): Beach Dead (`0x00359E00`,
  then `0x0019D3C0` in play, followed by a crash), the opening cutscene (`0x0014FE60` crashed it,
  `0x00153340`). All seeded, plus 32 more from a static scan (`tools/hidden_entries`, which now also sees
  entries after jump tables). The campaign ran from the opening to the training level clean; Beach Dead ran
  two minutes of bot play clean (commit a6f9ff2). Tick once more levels load without `[ICALL]`.
- [ ] **Intermittent freeze when changing class in the Dumbots class screen** (Linux, once in seven tries).
  - Culprit: the main thread sleeps in D3D's GPU wait (`sub_0053C190`, BlockOnTime, called from
    `sub_00218220` ← `sub_00208AA0` ← `sub_0028EAD0`) on the event the PGRAPH handler sets
    (`device+0x1DCC`), while the GPU executor is idle with no work: the wake-up was lost. Happened right
    after a class change started loading another model. Did not reproduce with `CONKER_D3D_TRACE=1` (six
    tries), so it is timing-dependent.
  - Fix: find the race between the "make space" NOP trap, its handling and the event (a set before the
    wait, or a trap the executor never sees). Catch it with `RECOMP_WATCHDOG_SECS` and the executor's
    pushbuffer pointers in the dump.
- [ ] **Beach Dead's bunker interior is strongly red** (Linux observation, not reported by the user).
  - Culprit: unknown; could be the level's own lighting, or a texture/combiner problem.
  - Fix: compare with footage of the original first.
- [ ] **Other x87 instructions the lifter leaves as comments** (`/* FPU: ... */` in `gen/`).
  - Done (commit 5fa8fb2): the `fcmov` family and `fxtract` (CRT math, `sub_00458494`, `sub_00459020`).
  - Left: `ficom`/`ficomp` (`sub_0018DEC2`, looks like data decoded as code), `fnsave`/`frstor`
    (`sub_004716D8`), `fbld`/`fisttp` (data decoded as code), `fnclex` (harmless).
  - Fix: check whether `sub_0018DEC2` and `sub_004716D8` are reached before implementing them.
- [ ] **A black band across the top of some frames** (Linux, title camera pan and the profile keyboard).
  - Culprit: unknown; possibly part of a transition. Seen twice, not investigated.
  - Fix: frame-trace a frame that shows it.
- [x] **Switch: extended-VMA commits refused (`0xCE01`)** when a title re-commits a growing range from the
  same base.
  - Culprit: the Switch `VirtualAlloc` only recognises a range inside one existing mapping, so the larger
    second commit tried to map pages already mapped.
  - Fix (done, verified on hardware 2026-10-17 with NRO `3f85b158`): 6ab1239 commits 2 MB granules once.
    The run logged no `0xCE01` and did not need the shared-memory fallback even once (the run with NRO
    `31500df5` used it 12 times).
- [ ] **Frame rate drops when the camera moves** (Switch, NRO `688d985e`, user report). Not reported on NRO
  `0678347d`; re-check when looking for 60 FPS.
- [x] **Switch runs at 20 FPS** (front end 540–860 draws; gameplay in the training level 526 draws, steady
  50 ms frames, NRO `e807fd88`). **30 FPS since NRO `0678347d`.**
  - Culprit: the GPU executor, about 80 % of a core, spent a fifth of its time converting vertex
    attributes on the CPU per vertex and draw: CMP (packed 11:11:10) normals through `fetch_attr` (~13 %)
    and formats NVK cannot fetch through `attr_to_float4` (~9.5 %), each then copied again as 16 bytes.
  - Fix (commit f67d461): the Vulkan back end fetches CMP normals as stored (one R32 lane, back-end flag
    `NV2A_BACKEND_RAW_CMP`) and unpacks them in the vertex shader; unfetchable formats get a fetchable
    neighbour plus a fix-up (three components fetched as four with w = 1, D3DCOLOR fetched as RGBA and
    swapped), three per-draw masks applied by `nv2a_inputs()`. Executor 43 % of a core, game thread 59 %.
- [ ] **60 FPS** (Switch). Headroom after the 30 FPS change: game thread ~59 % of a core, executor ~43 %.
  - Culprit to check first: the emulated vblank counter read 3–7 Hz in gameplay on NRO `0678347d` (11–50
    Hz in menus): the timer thread delivers vblanks late or the game paces itself another way. Then the
    game thread's own hot functions (`tools/prof_log_report.py`).
  - Fix: find what paces the frame (vblank, flip retire, the game's own timer) before optimising further;
    levers in [06-performance.md](06-performance.md), whose "Next candidates" table lists what the guide's
    newer ports found (fourth core, console PGO, LTO, code ordering, less copying in the executor).
- [ ] **Intro movie decodes slowly on Switch** (50–117 ms frames).
  - Culprit: CPU-side XMV decode and the YUV→RGB conversion in lifted code.
  - Fix: a native YUV converter as Burnout 3's port has; find Conker's converter first.
- [ ] **16-bit render targets are stored as ARGB8888.**
  - Culprit: `nv2a_vk` creates every colour surface as `B8G8R8A8`. Clears are now converted, but draws into a
    16-bit target keep 8-bit precision, X1R5G5B5's alpha is not forced to 1, and a CPU read of the surface's
    guest memory would see the wrong layout.
  - Fix: only if it shows up on screen: a real `R5G6B5` / `A1R5G5B5` attachment for those formats.
- [ ] **NV2A texture-shader bump and dot-product modes are not implemented** (they sample as plain 2D).
  - Culprit: toolkit gap ([05-renderer.md](05-renderer.md)); Conker uses normal mapping and fur.
  - Fix: implement the modes the game's frame traces show, starting with the ones gameplay uses.
