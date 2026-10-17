# Approach: static recompilation with xboxrecomp

## Why this route

- **Emulating on the Switch is too slow.** An x86 interpreter or JIT plus a software or emulated NV2A would
  not hold frame rate on a 1020 MHz A57.
- **Static recompilation is proven for original-Xbox → Switch.** Four ports on the same toolkit fork run on
  hardware: NFSU1 30 fps in races (the game's cap, with overclock, see [03](03-reference-ports.md)), NFSU2
  ~20 fps, Burnout 3 40-55 fps in races, Carbon playable.
- **The game's own D3D runs unchanged.** The recompiled XDK D3D writes NV2A pushbuffers into guest memory. A
  runtime executor reads them and a host back end (Vulkan on NVK) draws them. So the renderer is
  title-independent: Conker inherits everything the four ports fixed and only adds what its own frames use.

## The pipeline (xboxrecomp)

```
disc ISO --tools.xiso unpack--> game/ (default.xbe + data)
default.xbe --xbe_parser --json--> *_analysis.json   (sections, imports, entry, XDK)
            --disasm-->           functions.json, xrefs.json, strings.json
            --func_id-->          CRT / XDK / vtables classified
            --abi_analysis-->     calling conventions, parameter counts
            --(Ghidra FidDb, optional) real names--
            --recomp--> gen/recomp_*.c, recomp_dispatch.c, recomp_funcs.h, recomp_types.h
gen/ + src/main.c + src/recomp_manual.c + xboxrecomp runtime --CMake/devkitA64--> conker.nro
```

- Each port drives this with `tools/regen.sh`. `LIFT_ONLY=1` re-lifts only (enough after translator or
  `recomp_manual.c` changes). Changes to seeds need the full run. `TRACE_FUNCS=<json>` logs function entries.
- `--mmio-sections D3D,D3DX,XGRPH,DSOUND,XPP...` lifts the device-aware sections so their accesses to device
  memory (tiled aperture, APU, NV2A registers) get rewritten. Carbon needed this for D3DX writing into the
  tiled framebuffer.
- `config/seed_functions.json`: function entries the static pass cannot find (thread start routines,
  callbacks registered by `push`, class-driver tables, functions after `int3` padding). **Seeds are
  measurements and can be wrong**: Burnout seeded two jump-table arms of `memcpy` as functions, which split
  it and sent XAPI down the dashboard-update path. Check every seed against the function it lands in.

## Repo layout (the same one the four ports use)

| Path | What |
|---|---|
| `src/main.c` | Boot: load the XBE, map Xbox memory, runtime defaults (env), register the D3D addresses, jump to the entry point. Decides no game state |
| `src/recomp_manual.c` | Hand-written overrides/wrappers of lifted functions: library hooks (D3D fence/vblank/PGRAPH, DSOUND, memmove, `_ftol2`), native hot leaves, menu rows for options |
| `src/switch_nx.c` | Switch log devoptab, `*_env.txt` reader, exception handler, profiler, clocks, loading screen |
| `config/seed_functions.json` | Entries the static pass misses, each with a note on how it was found |
| `xboxrecomp/` | Vendored toolkit (MIT) with this port's changes |
| `tools/regen.sh` | XBE → `gen/` (never committed) |
| `switch/build.sh` | NRO build + SD-card staging (`switch_sd/`, never committed) |
| `docs/` | These notes |

SD layout on the console (by analogy with the ports): `sdmc:/switch/conker/{conker.nro, conker_env.txt,
conker_log.txt, conker_options.txt, game/}`. The game reads the **unpacked** disc, never the ISO. Launch
with **title takeover** (hold R on a game). Applet mode leaves ~400 MB, too little.

## Which toolkit copy to start from

Each port vendors its own `xboxrecomp/`, and the copies have diverged (checked 2026-10-16 by grepping
feature names):

| Feature | nfsu1 | nfsu2 | nfsc | burnout3 |
|---|---|---|---|---|
| Fixed-function vertex lighting, cube maps, render scale, mips/aniso/FXAA | ✓ | ✓ | ✓ | ✓ |
| `in`/`out` port I/O lifted (`xbox_PortIn`, video field bit for interlaced modes) | | | | ✓ |
| Immediate-mode vertices with all attributes, `RECOMP_INLINE_FFP` (world-space immediate quads) | | | | ✓ |
| Fog unit for vertex-program draws (`nv2a_fog_params`) | | | | ✓ |
| Partial-colour-mask clears on Vulkan (`clear_pipe`) | | | | ✓ |
| Kernel data / PRCB / TLS placed above the image (`xbox_RtDataPlace`) | | | | ✓ |
| Present crop (`RECOMP_PRESENT_CROP_Y`) | | | | ✓ |
| Sampling a surface from an address inside it (`surf_find_inside`, split screen) | | | ✓ | |
| Vulkan submission thread (`RECOMP_VK_THREAD`), texture pool, pacing (reconstructed from a third-party build) | ✓ | | | |

**Start from burnout3-sw's copy** (newest, 2026-10-16, most generic fixes), then port Carbon's
`surf_find_inside` and, after measuring, NFSU1's Vulkan thread work. Keep a list of what was merged from
where.

## Toolchain

- devkitPro: devkitA64, libnx, `switch-sdl2` (window, audio, pads). switch-sdl2's EGL/glapi/drm_nouveau are
  filtered out of `SDL2::SDL2` for the Vulkan build (a second Mesa). SDL's unused EGL calls and libelf are
  stubbed (`switch_egl_stubs.c`, `switch_elf_stubs.c`).
- **Mesa NVK for Horizon** (mesa-switch, danfromtico): the NFS ports built commit `1a8c1a66d6f` plus
  StevensND/nfsmw-nx's `mesa-switch-nfsmw.patch`, static `libvulkan.a`. The BO1 notes used Mesa 26.2.3 for
  Horizon (ZCULL support, less shader-cache lock contention, fewer redundant UBO updates), plus a hand-merged
  project8-sw "direct draws" patch that halved renderer CPU per draw there. Pick the newer Mesa and measure.
- **glslang built for the Switch** (15.4): the NV2A shaders are generated as GLSL at run time
  (`gl_vsh.c`/`gl_psh.c`, `nv2a_shader_vk = 1`) and compiled on the console, so deko3d's offline `uam`
  compiler is not an option without a different shader path.
- Optional: an **LGPL-only FFmpeg** build if the game's movies are a format FFmpeg decodes faster than the
  lifted decoder (NFSU2: VP6). devkitPro's `switch-ffmpeg` is `--enable-gpl`, don't link it.
- Build host: the ports used Linux/WSL with `-O2` for the lifted code (`JOBS=6` fits in RAM, ~1.5 GB per job).
  On this Mac: the devkitPro pacman packages exist for macOS, but the lifted C is millions of lines. A Linux
  VM/container may be easier for `regen.sh` and for the lavapipe test build.
- Linux builds (SDL2 + GL or Vulkan on lavapipe, headless with `SDL_VIDEODRIVER=offscreen` /
  `RECOMP_VK_HEADLESS=1`) are the fast test bench for logic and most render bugs.

## Licences

- xboxrecomp: **MIT**, except the APU files and `nv2a_regs.h` extracted from xemu (**LGPL-2.1+**, listed in its
  `NOTICE`). The four ports are MIT-style on top.
- **xemu** (GPL-2) is the reference for NV2A behaviour (texture shader modes, `psh.c`). Burnout removed its
  xemu-derived NV2A code. Read xemu to understand the hardware, then write our own implementation, unless we
  accept GPL for the whole port.
- **nfsmw-nx** (StevensND) is **GPL-3**: take ideas, not files (the NFSU2 notes say the same).
- No game data, no generated C, no disc-derived captures in git.
