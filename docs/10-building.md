# Building the Switch NRO

Two ways to build: **natively** with devkitPro on the Mac (what Conker uses today), or **inside Docker**
with the official devkitPro image, which is how the BO1 port builds without installing anything on the Mac.
The Docker section comes from the BO1 port's own guide (asked of its session on 2026-10-16; paths there are
in `../bo1-nx`) and is adapted here. It has not been run for Conker yet.

## What a build needs

| Piece | Conker | Notes |
|---|---|---|
| devkitA64 + libnx + switch-tools (`nacptool`, `elf2nro`, `nxlink`) | native `/opt/devkitpro` | |
| `switch-sdl2` (+ `switch-mesa`, `switch-libdrm_nouveau`) | native, installed 2026-10-16 | SDL is the audio output and pad source; its EGL/GL is filtered out of the Vulkan link |
| `switch-libexpat`, `switch-zlib`, **`switch-libzstd`** | native, installed 2026-10-16 | Needed by the NVK driver. Mesa 26.2.3 needs **zstd**, the NFS ports' older Mesa did not. The package is `switch-libzstd`, not `switch-zstd` |
| NVK driver `libvulkan.a` + Vulkan headers | `deps/nvk-sdk/` (git-ignored) | `lib/libvulkan.a` copied from `../bo1-nx/out/mesa-sdk-direct` (mesa-switch d4a00ea0ab3, Mesa 26.2.3, masseffect + p8-direct-draws patches, `-O2`, `libnak_rs.a` merged in); `include/` from `../mesa-switch-src/include`. Provenance in `deps/nvk-sdk/SOURCE.txt` |
| glslang for Horizon (CMake package) | `deps/glslang-switch/`, built by `tools/build_glslang_switch.sh` | nv2a_vk compiles the NV2A shaders it generates at run time. BO1 compiles glslang inside its own build instead |
| libelf | stubs in `xboxrecomp/src/nv2a_vk/switch_elf_stubs.c` | devkitPro has no libelf; NVK's CUBIN parser that uses it never runs on Switch |

Link line for NVK (`xboxrecomp/src/nv2a_vk/CMakeLists.txt`, same as BO1's): `libvulkan.a expat zstd z nx`,
listed twice so the linker rescans the archives, then `stdc++ m`. No separate Rust runtime, libnak_rs or
libdrm. Do not use `find_package(Vulkan)` for Switch: the Mesa SDK's config pulls in libelf.

## Native build (current)

```sh
tools/regen.sh                                   # only when the lift changes: XBE -> gen/ (needs .venv)
VULKAN=1 STAGE_GAME=0 bash switch/build.sh       # build/switch-vk -> switch_sd/switch/conker/conker-vulkan.nro
```

- `switch/build.sh` sizes `JOBS` from memory (1.5 GB per job; `-O2` on the lifted code). It runs CMake +
  ninja in `build/switch-vk/`, which is persistent: after a change to `src/` or the runtime only those files
  compile and the NRO relinks (about a minute); a re-lift recompiles the 86 generated files.
- `STAGE_GAME=0` skips copying the 4.4 GB disc into `switch_sd/` (the card already has it).
- Check after every build: `_start` must be at address 0 or the NRO does not boot (BO1's rule):
  `aarch64-none-elf-nm build/switch-vk/conker_recomp.elf | grep ' T _start$'` must print `0000000000000000`.
- Archive the unstripped ELF (500 MB) with the NRO of every build that goes to the console, named by the
  NRO's md5: `analysis/elf_archive/conker-vulkan_<md5:8>.{elf,nro}`. Crash addresses and profiler samples are
  resolved against exactly that ELF (`nm -n`, `addr2line`).

## Docker build (BO1's way, not yet tried for Conker)

Nothing Switch-related on the Mac; the toolchain lives in images:

- `devkitpro/devkita64:latest`: the official image, with devkitA64, libnx and the switch portlibs, including
  expat, zlib and zstd, plus nacptool, elf2nro and nxlink. Already on this Mac.
- `devkitpro-mesa-rust`: built locally by mesa-switch's `build-switch.sh` for the NVK build (Rust nightly,
  meson, bindgen). Already on this Mac. Only needed to *rebuild* the driver.

Both are arm64 on Apple Silicon; check with
`docker image inspect devkitpro/devkita64:latest --format '{{.Architecture}}'`. An amd64 image runs under
emulation several times slower; pull with `--platform linux/arm64`.

**Mount the repository at the same absolute path inside the container** (`-v "$PWD:$PWD" -w "$PWD"`). Paths in
CMake caches and ninja files stay valid on both sides, so the build folder survives between runs and builds
stay incremental. BO1's `tools/build_nro.sh` does:

```sh
docker run --rm -v "$ROOT:$ROOT" -w "$ROOT" -e JOBS ... devkitpro/devkita64:latest bash -euo pipefail -c '
  cmake -S app -B "$NRO_OUT" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE=<toolchain> -D<NVK SDK path>=...
  cmake --build "$NRO_OUT" -j "$JOBS"
  aarch64-none-elf-nm "$NRO_OUT/<elf>" | grep "^0000000000000000 T _start$"'
```

For Conker that would be `switch/build.sh` run inside the image with the repo mounted at its own path,
`DEVKITPRO=/opt/devkitpro` (the image's), `NVK_SDK=$PWD/deps/nvk-sdk` and `GLSLANG_DIR` built in the same
image by `tools/build_glslang_switch.sh`. Use a separate build folder (`BUILD_DIR=build/switch-vk-docker`):
a CMake cache configured natively points at the Mac's `/opt/devkitpro`.

Docker notes from both ports:

- **Memory**: Docker Desktop here has about 8 GB (`docker info` → MemTotal). Each GCC job on a big generated
  file needs 1-2 GB; too many jobs and the container is OOM-killed with an unhelpful error. Use `JOBS=4`, or
  raise Docker's memory under Settings → Resources.
- **File sharing**: VirtioFS bind mounts were fast enough for both ports; no named volumes needed.
- **`docker pull` hanging** (hit here on 2026-10-16, never in BO1): Docker Desktop's `"credsStore": "desktop"`
  helper waits on Keychain. Unlocking the login Keychain usually fixes it. Without touching
  `~/.docker/config.json`, pull public images with a throwaway config: a directory with `{}` as
  `config.json` and a symlink to `~/.docker/cli-plugins`, passed as `DOCKER_CONFIG=<dir>`.
- **Disk**: images about 19 GB (`docker system df`), the Mesa source and build about 15 GB.
  `docker builder prune` reclaims the build cache. Keep `devkitpro-mesa-rust` if you want incremental Mesa
  rebuilds.
- Run long builds in the background; a foreground run once hung the user's terminal in BO1.

## A/B builds

- Separate build folders per variant (`BUILD_DIR=build/switch-vk-<name>`).
- To try another driver without recompiling, clone the build folder with APFS copy-on-write (instant, no
  extra disk until files change) and relink against it: `cp -c -R build/switch-vk build/switch-vk-mesaX`, then
  `BUILD_DIR=build/switch-vk-mesaX NVK_SDK=<other sdk> VULKAN=1 bash switch/build.sh`. Ninja does not notice
  an archive found through a link directory changing; BO1 adds `libvulkan.a` to `LINK_DEPENDS` for that.
  Ours links it by full path, which ninja does track.

## Rebuilding the NVK driver (only when the pin, a patch or the optimisation level changes)

BO1's `mesa/build_mesa_docker.sh` (details in `../bo1-nx/mesa/README.md`):

1. Clones danfromtico/mesa-switch at d4a00ea0ab3 into `../mesa-switch-src`.
2. Applies `mesa-switch-masseffect.patch` and `mesa-switch-p8-direct-draws.patch`. A stamp file holds the
   patches' hash and resets the tree when they change.
3. Sets `-Doptimization` to `MESA_OPT`, default 2 (+5 % draw throughput over upstream's `-O1` on BO1's console).
4. Runs upstream's `./build-switch.sh` in `devkitpro-mesa-rust`.
5. Merges `libnak_rs.a` into `libvulkan.a` with an `ar -M` script, and writes `SOURCE.txt`.

```sh
OUT=$PWD/out/mesa-sdk-direct mesa/build_mesa_docker.sh                 # full build, about an hour, ~15 GB
OUT=$PWD/out/mesa-sdk-direct mesa/build_mesa_docker.sh --incremental   # after editing the source: ninja + merge
```

The output folder is self-contained; copying it (as `deps/nvk-sdk/lib` did) is all Conker needs.
