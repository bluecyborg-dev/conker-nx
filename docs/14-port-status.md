# Port status

Where the port stands right now: the last milestone reached, the milestones so far, and the open issues with
what probably causes each and what should fix it. Update it whenever an issue is found or closed or a milestone
is reached; the full history of how each one was found stays in [09-bringup-log.md](09-bringup-log.md).

When a big milestone is reached, copy this file into the guide
(`nx-port-guide/platforms/xbox/conker/`).

**Last milestone (2026-10-17):** the in-engine title-screen flythrough draws on the Linux bench (it was
black), after widening 16-bit clear colours. Only the ground near the camera shows so far: see the
**CURRENT** issue below (w-buffering).

**Builds:** Linux bench `build/linux-vk/conker_recomp`. Newest Switch NRO
`analysis/elf_archive/conker-vulkan_3f85b158.{nro,elf}` (commit d386a80: 16-bit clears, present the last
surface drawn, 2 MB extended-VMA granules).

**Last hardware run (2026-10-17, NRO `3f85b158`, log `run/net_logs/20261017-020541.log`):** boots, plays
the intro, intro skipped with a button press, then a **black screen with the menu music playing**. The front
end runs at 20 FPS (steady 50 ms frames, 605–669 draws), reached frame 982 with no `[ICALL]`, `[STUB]`,
exception or `0xCE01` in the log. This matches the Linux bench: the scene is clipped (w-buffering, the
CURRENT issue below), so the console needs no separate fix for the picture.

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
| 2026-10-17 | Front end runs on the console with its music and no memory errors (picture still black: w-buffering) | Switch |

Next milestones: the whole title scene draws (w-buffering); main menu → new game; first
gameplay frame; first gameplay frame on the console.

## Known issues

Each issue: **culprit** = what probably causes it, **fix** = what should solve it. Tick it once it is solved
and say how.

- [x] **Title screen black after the intro** (Linux and Switch).
  - Culprit: Conker's projected shadows render into 128×128 and 64×64 R5G6B5 (16-bit) surfaces cleared with
    `0x0000FFFF`, which is white in R5G6B5. The renderer keeps every colour surface as ARGB8888 and used the
    raw value, so the shadow maps were cyan, and the three `DST_COLOR × ZERO` shadow passes over the whole
    scene multiplied it to black.
  - Fix (done 2026-10-17): `clear_color_argb()` in `xboxrecomp/src/kernel/nv2a_pb_exec.c` widens
    R5G6B5 / X1R5G5B5 clear values before handing them to the back end. Found by skipping draws by blend mode
    (`RECOMP_SKIP_BLEND=306/0`).
- [x] **Flythrough shows a small black square instead of the scene** (Linux, from about frame 4,300).
  - Culprit: the Vulkan back end presented the last surface *touched* (drawn or cleared). After compositing
    its glow onto the back buffer, the game clears its 256×256 glow target, so the flip showed that cleared
    target (dumps came out 341×256 instead of 853×480).
  - Fix (done 2026-10-17): `vk_flip()` presents the last surface *drawn* in the frame (`s_last_drawn` in
    `xboxrecomp/src/nv2a_vk/nv2a_vk.c`) and falls back to the last one touched if nothing was drawn.
- [ ] **CURRENT: most of the 3D scene is clipped away** (Linux; most likely the same on Switch). Through the
  whole title flythrough only the ground next to the camera draws; the sky and distant scenery are always
  missing, and from about frame 4,300 nothing draws at all, so the screen is black. Proof: forcing the
  back-buffer clear to red gives a red screen with only a vignette and rain on it (see the 2026-10-17 entry
  in [09-bringup-log.md](09-bringup-log.md) for the traces).
  - Culprit (very likely): **Conker uses NV2A w-buffering**, which the renderer does not implement. Every
    scene draw has `SET_CONTROL0` (0x0290) = `0x00100001`: bit 20 is `Z_PERSPECTIVE_ENABLE`, i.e. the depth
    buffer holds eye-space **w**, not z/w. `SET_ZMIN_MAX_CONTROL` (0x1D78) = 1 (cull near/far on, no z
    clamp, w not ignored). Our vertex shader (`nv2a_clip()` in `xboxrecomp/src/nv2a_gl/gl_vsh.c`) takes
    the program's `oPos.z` as depth and divides it by zmax (`u_surf.z = 1/zmax`, `zmax_of()` in
    `nv2a_vk.c`). In w-buffer mode that value is not a 0..zmax depth: the frame traces show first vertices at
    z = 16.8–17.8 M with zmax = 16,777,215, so Vulkan clips them at the far plane. Second possibility, to
    check alongside: many first vertices have negative w, and the clip path culls w < 0.
  - Fix to try, in order:
    1. Trace `SET_CLIP_MIN/MAX` (0x0394/0x0398) for the scene draws. The trace line now prints them as
       `clip <min> <max>` but the run has not been made yet. In w-buffer mode they should be a range of
       w values (near..far).
    2. Implement w-buffering, as xemu does: when `SET_CONTROL0` bit 20 is set, do not clip or depth-test on
       the program's `oPos.z`. In the vertex shader output z = w · 0.5 (inside the clip volume, so nothing is
       clipped on z). In the fragment shader write
       `gl_FragDepth = clamp((1/gl_FragCoord.w - clip_min) / (clip_max - clip_min), 0, 1)`, and discard
       outside [clip_min, clip_max] when cull near/far (0x1D78 bit 0) is on. Pass bit 20 and the clip range
       in the pipeline key / uniforms (`Nv2aRenderState.depth_min/max` already holds the clip range).
       Depth clears stay as they are (the clear value is already a 0..zmax fraction).
    3. If geometry is still missing: compare with xemu's handling of w < 0 (it multiplies x, y, z by w only
       when w < 0 so the GPU clips the point correctly) and check `ZMIN_MAX_CONTROL` bit 8 (`CULL_IGNORE_W`).
    4. Verify with `RECOMP_FRAME_TRACE` + the red-clear test (force the back-buffer clear colour in
       `clear_color_argb()`, the hack is not committed) and with frames 3,700–6,500 of an idle run
       (`tools/live_linux.sh`, title flythrough), then on Switch.
- [x] **Switch: extended-VMA commits refused (`0xCE01`)** when a title re-commits a growing range from the
  same base.
  - Culprit: the Switch `VirtualAlloc` only recognises a range inside one existing mapping, so the larger
    second commit tried to map pages already mapped.
  - Fix (done, verified on hardware 2026-10-17 with NRO `3f85b158`): 6ab1239 commits 2 MB granules once.
    The run logged no `0xCE01` and did not need the shared-memory fallback even once (the run with NRO
    `31500df5` used it 12 times).
- [ ] **Switch front end runs at 20 FPS** (steady 50 ms frames, 540–860 draws; again 20 FPS with 605–669
  draws on NRO `3f85b158`, while most of the scene is still clipped, so expect worse once it draws).
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
