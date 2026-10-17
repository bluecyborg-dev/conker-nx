# Port status

Where the port stands right now: the last milestone reached, the milestones so far, and the open issues with
what probably causes each and what should fix it. Update it whenever an issue is found or closed or a milestone
is reached; the full history of how each one was found stays in [09-bringup-log.md](09-bringup-log.md).

When a big milestone is reached, copy this file into the guide
(`nx-port-guide/platforms/xbox/conker/`).

**Last milestone (2026-10-17):** **steady 30 FPS in gameplay on the console** (NRO `0678347d`, commit
f67d461): vertex attributes the CPU used to convert per vertex are now fetched as stored and unpacked in the
vertex shader, which took the GPU executor from about 80 % of a core to 43 %. The user found menu transitions
much smoother and gameplay better and more stable. **Focus: the known issues (cutscene blur, loading
screens), then more headroom** (60 FPS if possible, low input lag) without lowering quality.

**Builds:** Linux bench `build/linux-vk/conker_recomp`. Newest Switch NRO
`analysis/elf_archive/conker-vulkan_0f38c4dc.{nro,elf}` (the 30 FPS build plus the loading-screen present),
not yet run on hardware.

**Last hardware run (2026-10-17, NRO `0678347d`, log `run/net_logs/20261017-152423.log`):** played by the
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

**Priority (2026-10-17):** get to a visible, playable game scene as soon as possible. The Linux bench may use
a different resolution or aspect ratio from the Switch; exact aspect-ratio matching can wait. The current
640×480 back-buffer capture shows geometry projected far outside the view, so aspect ratio alone does not
explain the black screen.

Next milestones: the known issues closed on the console; then 60 FPS and input latency.

## Known issues

Each issue: **culprit** = what probably causes it, **fix** = what should solve it. Tick it once it is solved
and say how.

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
- [ ] **Intro movie audio stops after under a second** (Switch and Linux). **Still silent on NRO
  `688d985e`** (user report, 2026-10-17) with the shader cache in place; lower priority than performance.
  - Culprit: the movie queues 0.8 s of audio (two ADPCM segments per channel) and only refills from
    packet-completion callbacks. Its first frames stalled 4.3 s on the console compiling shaders and NVK
    pipelines (0.5 s on Linux), the stream starved, and the player never refilled. The shader/pipeline
    cache that should prevent the compiles was written to Burnout 3's folder `sdmc:/switch/b3x/`
    (hard-coded in the toolkit), which does not exist: nothing was ever cached.
  - Fix (commit 0d9fb5c): the cache folder is `XBOXRECOMP_SWITCH_DIR`, set to `sdmc:/switch/conker/`. If the
    first frames still stall on a cold cache, prewarm or keep the APU fed during compiles.
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
- [ ] **Some cutscene shots blurry, some sharp** (Switch, user report). **Still there on NRO `688d985e`**:
  the depth fix below did not solve it.
  - Culprit: the depth of field reads the Z24S8 depth buffer as a `LIN_R8G8B8A8` texture to decide which
    pixels to blur; depth lives in a Vulkan image and never reached guest memory, so the mask came from
    stale bytes. (The hangover shot at the start of the training level is blurred on purpose.)
  - Fix (commit 00f1cb4): a texture at a depth buffer's address is a colour image converted from the depth
    on the GPU (R G B = the 24-bit depth's bytes). The title tavern now blurs its near foreground and keeps
    the bar sharp; not yet compared with the original game.
- [ ] **No loading screen between sections; the game looks frozen for a few seconds instead** (Switch,
  user report on NRO `0678347d`: entering the area with the first weapon in the training level; the same
  happens loading the training level from the profile menu on Linux). **Fixed on the Linux bench, verify
  on the console** (NRO `0f38c4dc`).
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
    levers in [06-performance.md](06-performance.md).
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
