# Renderer: NV2A pushbuffer executor + `nv2a_vk`

## How a frame flows

1. Game code (recompiled) builds its draw lists and calls the XDK's D3D8 (also recompiled), which writes NV2A
   methods into a pushbuffer in guest memory and bumps `DMA_PUT`.
2. The executor (`kernel/nv2a_pb_scan.c` + `nv2a_pb_exec.c`) walks the pushbuffer **like the DMA engine**:
   it follows JUMP (old and new style), CALL/RETURN (one level; D3D sends state blocks as CALLs into
   pre-built pushbuffers) and stops at PUT. `DMA_GET` advances only after the walk. It keeps a register
   shadow and hands each draw to a back end through `nv2a_backend.h` (`Nv2aRawBatch`).
3. The back end is `nv2a_vk/nv2a_vk.c` on Switch (Vulkan 1.3: dynamic rendering, push descriptors, dynamic
   vertex input, nearly everything as dynamic state, images in GENERAL, 2 frames in flight with a 48 MB host
   ring each). `nv2a_gl` is kept building for Eden but gets no fixes.
4. Shaders: the vertex program (`gl_vsh.c`) and the texture shader + register combiners (`gl_psh.c`) become
   GLSL, compiled by glslang on a 4 MB-stack thread. Caches on the SD card: `progcache.bin` (program
   inputs), `vkspirv.bin` (SPIR-V by GLSL hash), `vkpipes.bin` (pipeline variants), `vkpipecache.bin`
   (`VkPipelineCache`, saved at most every 20 s). All are prewarmed at boot (`[VK] prewarm:`).
5. On a flip the frame is presented (FXAA 3.11 draw, letterbox/crop), and the vblank counter ticks.

## What is implemented (as of burnout3-sw, 2026-10-16)

- Vertex programs (interpreter on the CPU for culling/tracing; GLSL for drawing), viewport scale/offset in
  c[58]/c[59], NV2A's 1/16-pixel screen snap (`nv2a_snap`, corrected for render scale).
- **Fixed-function vertex lighting** (`SET_LIGHTING_ENABLE`, up to 8 lights, two-sided normal flip).
- Register combiners (general stages + final), four texture stages, alpha test, fog unit (linear/exp/exp2,
  for vertex-program draws), all 16 immediate-mode attributes, `SET_VERTEX_DATA*` tracked per attribute.
- Texture modes: 2D/projective, **cube map** (Vulkan only), pass-through, clip plane,
  **DEPENDENT_AR / DEPENDENT_GB**. P8 palettes, DXT1/3/5 uploaded compressed, swizzled formats via lookup
  tables, mip chains honoured, trilinear + anisotropic, LOD bias −0.25.
- Dynamic cube maps assembled from the six face surfaces the title renders (`cube_from_surfaces`).
- Render targets: surfaces keyed by clip origin + size that only grow, draws scissored to the clip, depth
  **per zeta address and stored size**, render-target-as-texture with scaled texcoords (`rt_scale`), sampling
  from inside a surface (`surf_find_inside`, Carbon only so far).
- Render scale 0.5-4× (`RECOMP_GL_SCALE`, in-game rows), square pixels for 16:9, FXAA, present crop.
- Instancing of repeated draws that differ only in transform constants (`RECOMP_VK_INSTANCE`, up to 16).
- Off-screen batch cull (`RECOMP_CULL`, with a CPU check mode). It culled only 1-5 % in the NFS titles and
  dropped Burnout's car-select thumbnails, so it is **off by default** in Burnout/NFSU1.

## Gaps that matter for Conker

`gl_psh.c` says it outright: *"the bump-map and dot-product texture modes (DOT_ST and friends) sample as plain
2D."* The NV2A texture shader modes (PS_TEXTUREMODES) and their status:

| Mode | # | Status |
|---|---|---|
| NONE, PROJECT2D, PROJECT3D, CUBEMAP, PASSTHRU, CLIPPLANE | 0-5 | done (cube: VK only; 3D: **check**) |
| BUMPENVMAP, BUMPENVMAP_LUM | 6, 7 | **missing** (EMBM: perturbed lookups, water, heat haze) |
| BRDF | 8 | **missing** |
| DOT_ST, DOT_ZW | 9, 10 | **missing** |
| DOT_RFLCT_DIFF, DOT_RFLCT_SPEC, DOT_RFLCT_SPEC_CONST | 11, 12, 18 | **missing** (per-pixel reflection with normal maps) |
| DOT_STR_3D, DOT_STR_CUBE | 13, 14 | **missing** (normal-map lookups into 3D/cube textures, e.g. normalisation cube) |
| DPNDNT_AR, DPNDNT_GB | 15, 16 | done |
| DOTPRODUCT | 17 | **missing** (first stage of every dot-product chain) |

Conker: Live & Reloaded is known for per-pixel lighting, normal maps and fur, which on NV2A are typically
dot-product texture-shader chains and many alpha-blended or alpha-tested passes. **Expect this to be the main
renderer work.** Plan:

1. As soon as the 3D world draws, take a `RECOMP_FRAME_TRACE` frame. Its draw lines show the shader stage
   program (5 bits per stage), combiner setup and textures. Make a census of the texture modes Conker uses
   (the NFS ports logged "texture modes not yet done" in `nv2a_gl.c` with the bump matrix; reuse that log).
2. Implement the modes in that census in `gl_psh.c`: DOTPRODUCT + DOT_ST/ZW/STR_3D/STR_CUBE/RFLCT_*, BUMPENVMAP
   with `SET_TEXTURE_SET_BUMP_ENV_MAT/SCALE/OFFSET`. Also the signed texture formats and the per-stage "dot
   mapping" (`SHADER_DOTMAPPING`: zero-to-one / minus-one-to-one / HILO). xemu's `psh.c` is the behavioural
   reference (GPL-2: read it, don't copy; see [02](02-approach.md), "Licences").
3. Also check what the reference titles never needed: **stencil** (shadow volumes?), **point sprites**,
   **PROJECT3D / 3D textures**, many-pass alpha (fur shells), occlusion queries / visibility reports,
   `SHADER_OTHER_STAGE_INPUT` routing, combiner `MUX`/`BLUE_TO_ALPHA` paths, user clip planes, W-buffering,
   and the fixed-function paths (texgen, texture matrices).

## Correctness traps already found (keep the fixes, watch for siblings)

| Symptom | Cause |
|---|---|
| Every culled draw lost its front faces (Vulkan) | NV2A winding is on-screen, top-first = Vulkan's framebuffer, so CW → CW. Only GL swaps |
| Depth wrong for triangles crossing the eye plane; a mirrored car beat the floor (Carbon) | The shader clamped clip z per vertex. With `depthClamp`, leave z unclamped; the rasteriser clamps per fragment as NV2A does |
| Loading screen black (all culled) | The executor wrote methods of **every subchannel** into the 3D shadow (an NV062 blit set "cull enable"). Only subchannel 0 goes into the 3D shadow |
| Car paint washed pink (Vulkan) | Clears with a partial colour mask (alpha only, `CLEAR_SURFACE 0x83`) were skipped → `clear_pipe` draws a masked triangle |
| Lights through walls | One depth buffer per colour surface; the flare pass switches colour target but keeps the scene Z |
| Split screen black / back buffer cleared each clip change | Surfaces keyed by (address, clip size): every clip change rebuilt the surface |
| Grey squares in rain | Absent attributes read as (0,0,0,1); D3D sets `SET_VERTEX_DATA4UB(4)=0` for them |
| Light line on top/left edge (also at render scale > 1) | D3D's viewport offset 0.53125 vs pixel centre 0.5 → NV2A's 1/16 px truncation snap, scaled per axis |
| Full-screen composite missing (Burnout's world) | Immediate-mode position in `SET_VERTEX_DATA2F_M` slot 0 was ignored; only VERTEX3F/4F completed a vertex |
| Particles drawn at x≈5000 | Immediate quads with **world** positions in fixed-function mode, taken as pre-transformed (`RECOMP_INLINE_FFP=1`) |
| Movie cycled 3 frames | Linear (pitch ≠ 0) textures hashed by sampling one byte per row; hash every byte for linear textures |
| Garage pure black (fog) | oFog read raw; the fog unit must run on vertex-program output |
| Race red / LUTs | DEPENDENT_AR/GB read the earlier stage's colour; final combiner C0/C1 are `SPECULAR_FOG_FACTOR0/1` |
| Reflections black | Cube maps: format bit 2, faces with their mips padded to 128 bytes; dynamic cubes from 6 surfaces |
| Neon through the car (square pixels) | Depth keyed by zeta *and* stored size; widening by AA mode gave the same Z two sizes |
| Surface bytes per pixel 5-12 | pitch/width guessing; read `SET_SURFACE_FORMAT` |

## Renderer debugging recipes that worked

- `RECOMP_FRAME_TRACE=<flag file>`: one line per draw/clear of the next frame (target, state, textures,
  combiner, first CPU-transformed vertices); touch the file again for another frame.
- `RECOMP_GL_DUMP=<prefix>[,N]` dumps presented frames; `RECOMP_VK_DUMP_SURF=<va>,...` also dumps chosen
  surfaces (`RECOMP_VK_DUMP_RAW=1` with alpha); `RECOMP_GL_WATCH=<va>` dumps draws into/sampling a VA.
- **Read one pixel back after every draw**, GL vs VK in the same frame (found the winding and depth-clamp
  bugs). Skip draw ranges and compare dumps. Project the logged constants by hand.
- Lavapipe + `RECOMP_VK_VALIDATION=1` on Linux for every renderer change; headless with
  `RECOMP_VK_HEADLESS=1`.
- From the BO1 port: a texture **format census** in the frame trace, image dumps of every intermediate target
  (scene vs final image located every black-screen cause), entropy checks of texture data (real DXT ≈ 6
  bits/byte).
