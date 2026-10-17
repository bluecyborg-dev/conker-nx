# Port status

Where the port stands right now: the last milestone reached, the milestones so far, and the open issues with
what probably causes each and what should fix it. Update it whenever an issue is found or closed or a milestone
is reached; the full history of how each one was found stays in [09-bringup-log.md](09-bringup-log.md).

When a big milestone is reached, copy this file into the guide
(`nx-port-guide/platforms/xbox/conker/`).

**Last milestone (2026-10-17):** **the front end renders and plays on the Linux bench.** The black title
scene was a translator bug, not a renderer one: `fincstp` was emitted as a no-op, which broke the game's
rotation-matrix builder and collapsed the camera (commit 1bc623e). The title tavern draws; Start, profile
creation (saved to `UDATA`), the Xbox Live & Co menu, Dumbots → Solo → Beach Dead → team, class and lobby
all work with pad input. Loading the level then stopped on an unresolved call, now seeded (see below).

**Builds:** Linux bench `build/linux-vk/conker_recomp`. Newest Switch NRO
`analysis/elf_archive/conker-vulkan_5c8b2369.{nro,elf}` (commit 1bc623e: the `fincstp` fix; built before the
two level-load seeds), not yet run on hardware (the upload found the NetLoader closed).

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
| 2026-10-17 | **Front end renders and is playable**: title tavern, profile created and saved, Dumbots level/team/class select and lobby | Linux |

**Priority (2026-10-17):** get to a visible, playable game scene as soon as possible. The Linux bench may use
a different resolution or aspect ratio from the Switch; exact aspect-ratio matching can wait. The current
640×480 back-buffer capture shows geometry projected far outside the view, so aspect ratio alone does not
explain the black screen.

Next milestones: first gameplay frame on Linux (Dumbots Beach Dead, then the single-player campaign); the
front end on the console with the `fincstp` fix; first gameplay frame on the console.

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
- [ ] **Level load stops on an unresolved call** (Linux, Dumbots → Beach Dead, 2026-10-17).
  - Culprit: `[ICALL] Failed to resolve VA 0x00359E00`, then a null function pointer; the pushbuffer stopped.
    `0x00359E00` follows a jump table and `int3` padding and tail-jumps to `0x00359FF0`, which starts right
    after `sub_00359F80`'s `ret`. Neither was found by the static pass.
  - Fix: both seeded in `config/seed_functions.json`; full regen done (21,284 of 21,286 functions). Rebuild,
    load Beach Dead again, tick when the level plays.
- [ ] **Other x87 instructions the lifter leaves as comments** (`/* FPU: ... */` in `gen/`).
  - Culprit: no translation for `fcmovnbe` (2 sites, `sub_00458494`), `ficom`/`ficomp` (`sub_0018DEC2`, looks
    like data decoded as code), `fxtract` (`sub_00459020`), `fnsave`/`frstor` (`sub_004716D8`); `fbld` and
    `fisttp` sit in data decoded as code. `fnclex` and `ffree` are harmless as no-ops.
  - Fix: implement `fcmov*` and `fxtract` (CRT-area code, so likely reachable from math functions); check
    whether `sub_0018DEC2` is real code before doing `ficom`.
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
