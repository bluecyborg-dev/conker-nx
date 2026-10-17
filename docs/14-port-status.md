# Port status

Where the port stands right now: the last milestone reached, the milestones so far, and the open issues with
what probably causes each and what should fix it. Update it whenever an issue is found or closed or a milestone
is reached; the full history of how each one was found stays in [09-bringup-log.md](09-bringup-log.md).

When a big milestone is reached, copy this file into the guide
(`nx-port-guide/platforms/xbox/conker/`).

**Last milestone (2026-10-17):** the in-engine title-screen flythrough draws on the Linux bench (it was
black), after widening 16-bit clear colours. Only the ground near the camera shows so far: see the
**CURRENT** renderer issue below. Its depth/clip cause is still under investigation.

**Builds:** Linux bench `build/linux-vk/conker_recomp`. Newest Switch NRO
`analysis/elf_archive/conker-vulkan_3f85b158.{nro,elf}` (commit d386a80: 16-bit clears, present the last
surface drawn, 2 MB extended-VMA granules).

**Last hardware run (2026-10-17, NRO `3f85b158`, log `run/net_logs/20261017-020541.log`):** boots, plays
the intro, intro skipped with a button press, then a **black screen with the menu music playing**. The front
end runs at 20 FPS (steady 50 ms frames, 605–669 draws), reached frame 1,553 (the user quit) with no `[ICALL]`, `[STUB]`,
exception or `0xCE01` in the log. The Switch and Linux both show the unresolved renderer issue; the
current evidence does not establish that they share the same specific depth/clip cause.

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

**Priority (2026-10-17):** get to a visible, playable game scene as soon as possible. The Linux bench may use
a different resolution or aspect ratio from the Switch; exact aspect-ratio matching can wait. The current
640×480 back-buffer capture shows geometry projected far outside the view, so aspect ratio alone does not
explain the black screen.

Next milestones: front end visible and controllable; enter new game; first gameplay frame on Linux (any
usable aspect ratio); first gameplay frame on the console.

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
- [ ] **CURRENT: most of the 3D scene is missing** (Linux and Switch). With the default depth state, through
  the whole title flythrough only the ground next to the camera draws; the sky and distant scenery are
  missing, and from about frame 4,300 nothing draws at all, so the screen is black. Proof: forcing the
  back-buffer clear to red gives a red screen with only a vignette and rain on it (see the 2026-10-17 entry
  in [09-bringup-log.md](09-bringup-log.md) for the traces).
  - Culprit: **depth rejection is a confirmed contributor; the later blackout is still unresolved**.
    The frame trace records `SET_CONTROL0` (0x0290) = `0x00100001` and
    `SET_ZMIN_MAX_CONTROL` (0x1D78) = 1, with clip range 0..16,777,215. A review found the earlier
    bit-20 interpretation was wrong: the vendored NV2A header defines `Z_PERSPECTIVE_ENABLE` at bit 16
    (`0x00010000`), which is clear in `0x00100001`; bit 20 is not defined there. The effect of this bit
    setting on Conker's raster depth remains unconfirmed. A full-draw
    `[FTRACE POS CPU]` estimate on Linux (frame after flip 4655, black dump) found 181 large back-buffer
    draws with 82,750 indices. None of their positive-`oPos.w` positions fell inside 640×480; 6 draw bounds
    intersected the screen, covering 4,722 indices. Of 53,043 positive-`oPos.w` positions, 45,640 were
    within the captured depth interval. This diagnostic runs the CPU position interpreter, not the Vulkan
    shader, so compare its output with generated VSH output before attributing the missing scene to either
    x/y clipping or depth. Scoped Linux probes force depth compare only for opaque draws to full-size
    surfaces, preserving shadow and post-process behavior. `RECOMP_VK_DEPTH_ALWAYS_OPAQUE=1` revealed
    scene geometry in frames 3,780, 4,020 and 4,140; frame 4,320 was black. The follow-up
    `RECOMP_VK_DEPTH_GREATER_OPAQUE=1` showed the room at frame 3,780, then black at 4,020, 4,140,
    4,320 and 4,530 (the run reached frame 4,545). These probes show that changing the opaque depth
    comparison can expose geometry in some views, but neither setting fixes the later blackout or
    establishes the correct depth function. A default-state trace across frames 4,120–4,340 found the same
    main ZETA (`80BC0000`) cleared to 1.0 each frame and the same LEQUAL compare (`0x203`) with depth
    test/write enabled, including black baseline frames 4,140 and 4,320. The late blackout is not
    explained by a change in depth clear or compare state. A follow-up CPU position trace at flip 4,321
    (black frame dump 4,320) covered 497 back-buffer draws / 139,085 indices: only three index positions
    were estimated inside 640×480, all from three full-screen composite quads; no world-geometry positions
    were inside. Of 50,028 estimated positive-`oPos.w` positions, 45,092 were in the depth interval. A
    second frame 4,320 run with `RECOMP_GL_DIRECT=0` was also black and showed the same pattern (498 draws
    / 139,402 indices, three in-view composite positions, no in-view world positions). Those were CPU
    interpreter estimates, not GPU output. A later desktop OpenGL transform-feedback capture on black
    frame 2,668 read the generated `oPos` and `gl_Position` for 47 programmable-VSH batches to the
    640×480 back buffer. On the 2,382-index world batch, GPU and CPU results agreed: 1,537 positive-w
    vertices, none inside the view, and nearly identical bounds (`-16366,-132157:-79,786`). The
    1,830-index world batch also matched, with no vertices inside. The only in-view rectangle was the
    full-screen post-process quad. This verifies the OpenGL shader output against the CPU estimate for
    these draws and confirms that world geometry is projected outside the viewport in this captured view;
    the guest input/state that produced those coordinates is still unknown. The direct-format attribute
    path is unlikely to be the sole cause. The current-source Linux OpenGL build also reproduced the black
    screen, so the failure is not Vulkan-specific. Global depth probes also stayed black, but changed
    shadow visibility and draw ordering and were inconclusive. Upstream xemu's VSH template has the same
    broad screen-to-clip x/y and clip-range z conversion shape as the port
    ([reference](https://github.com/xemu-project/xemu/blob/master/hw/xbox/nv2a/pgraph/glsl/vsh-prog.c));
    compare the shared vertex inputs and constants before changing that conversion.
    A corrected OpenGL capture on black frame dump 2,100 replayed indexed batches as points with
    rasterization discarded, so each index produced one captured vertex without changing the frame.
    On the 747-index world batch, all 747 CPU vertices had negative `oPos.w` and the GPU reported no
    positive-w vertices. On the 1,082-index batch, CPU and GPU both reported 80 positive-w vertices, none
    inside 640×480, with matching projected bounds (CPU `-31283.3,-247017.6:-483.7,-2521.8`; GPU
    `-31283.1,-247015.9:-483.7,-2521.8`). This confirms the out-of-view result for those OpenGL draws;
    it does not identify the bad guest state or validate Vulkan/Switch output. The captured menu frame is
    still black; the black-screen issue remains open. The captured 33-slot VSH program contains no MAC
    ARL instruction (opcode 13), so ARL rounding is not a cause for this sample; compare its other
    instructions and guest inputs against xemu.
    Final Linux Vulkan probe: with `RECOMP_VK_DEPTH_ALWAYS_OPAQUE=1` confirmed active, the 640×480 dump
    at frame 2,100 remained fully black; frame 2,101 still issued 700 draws. Forcing opaque depth tests to
    pass is not sufficient to recover this menu view. The run reached at least frame 2,792 without a
    recorded exception or renderer crash. A detailed attempt-by-attempt report is in
    [15-black-screen-investigation-summary.md](15-black-screen-investigation-summary.md).
    Do not treat bit 20 as a W-buffer flag or implement a W-depth path from that assumption.
  - Fix to try, in order:
    1. Inspect the vertex attributes, VSH constants/program and guest camera state for representative
       world draws whose GPU output is outside the viewport; compare those values and outputs with xemu.
    2. Check the same guest state across an earlier partially visible frame and the first fully black frame
       to see which inputs or camera values move geometry out of view.
    3. Verify Vulkan and Switch output against the validated OpenGL/CPU positions for matching draws.
    4. Confirm the meaning of `Z_PERSPECTIVE_ENABLE` and `SET_ZMIN_MAX_CONTROL` from authoritative NV2A
       behavior, then test depth and clip handling independently using the stable clear/compare state.
    5. Verify with `RECOMP_FRAME_TRACE` + the red-clear test (force the back-buffer clear colour in
       `clear_color_argb()`, the hack is not committed) and with frames 3,700–6,500 of an idle run
       (`tools/live_linux.sh`, title flythrough), then on Switch.
    6. Once the game reaches a playable scene, tune output scaling and aspect ratio separately; matching
       the Switch display is not a prerequisite for the first Linux gameplay milestone.
- [x] **Switch: extended-VMA commits refused (`0xCE01`)** when a title re-commits a growing range from the
  same base.
  - Culprit: the Switch `VirtualAlloc` only recognises a range inside one existing mapping, so the larger
    second commit tried to map pages already mapped.
  - Fix (done, verified on hardware 2026-10-17 with NRO `3f85b158`): 6ab1239 commits 2 MB granules once.
    The run logged no `0xCE01` and did not need the shared-memory fallback even once (the run with NRO
    `31500df5` used it 12 times).
- [ ] **Switch front end runs at 20 FPS** (steady 50 ms frames, 540–860 draws; again 20 FPS with 605–669
  draws on NRO `3f85b158`, while most of the scene is missing).
  - Culprit: unknown until profiled; draw submission cost on NVK or the guest's own CPU time.
  - Fix: `RECOMP_NX_PROFILE=1` on hardware once the picture is right; levers in [06-performance.md](06-performance.md).
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
