#!/usr/bin/env bash
# Build the Conker (Xbox) recompilation as a Switch homebrew NRO and stage an
# SD-card layout:
#
#   <SD>/switch/conker/conker.nro
#   <SD>/switch/conker/game/        the extracted disc: default.xbe, dvddata/, media/
#   <SD>/switch/conker/save/        created on first run
#   <SD>/switch/conker/conker_env.txt   optional KEY=VALUE runtime switches
#   <SD>/switch/conker/conker_log.txt   written when no nxlink host is listening
#
# The game reads the unpacked disc files directly -- never the ISO.
#
# Environment:
#   DEVKITPRO        default /opt/devkitpro (switch-dev, switch-sdl2, switch-mesa)
#   XBOXRECOMP_DIR   toolkit (default: the vendored xboxrecomp/)
#   CONKER_GEN_DIR    lifted C from tools/regen.sh (default $REPO/gen)
#   CONKER_GAME_SRC   extracted disc to stage (default $REPO/game)
#   SD_ROOT          staging SD root (default <repo>/switch_sd)
#   BUILD_DIR        default $REPO/build/switch
#   JOBS             parallel compile jobs (default: nproc, capped by memory)
#   VULKAN=1         the Vulkan renderer: stages conker-vulkan.nro, built in
#                    BUILD_DIR (default $REPO/build/switch-vk) against
#                    NVK_SDK (mesa-switch install, default deps/nvk-sdk)
#                    and GLSLANG_DIR (glslang for the Switch, default $REPO/deps/glslang-switch)
#   LTO=1            link-time optimisation of the lifted code (CONKER_LTO):
#                    BUILD_DIR gets a -lto suffix and the NRO is staged as
#                    conker[-vulkan]-lto.nro next to the normal one, for A/B.
#                    LTO_JOBS parallel link jobs (default 4, ~2 GB each)
#   FFMPEG_DIR       VP6-only LGPL FFmpeg for the movies (tools/build_ffmpeg_vp6.sh
#                    switch; default $REPO/deps/ffmpeg-vp6-switch). Without
#                    it the lifted (slow) decoder plays them.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
TK="${XBOXRECOMP_DIR:-$REPO/xboxrecomp}"
GEN="${CONKER_GEN_DIR:-$REPO/gen}"
GAME="${CONKER_GAME_SRC:-$REPO/game}"
SD="${SD_ROOT:-$REPO/switch_sd}"
VK="${VULKAN:-0}"
if [ "$VK" = "1" ]; then
    BUILD="${BUILD_DIR:-$REPO/build/switch-vk}"
    NRO_NAME=conker-vulkan.nro
    NVK_SDK="${NVK_SDK:-$REPO/deps/nvk-sdk}"
    GLSLANG_DIR="${GLSLANG_DIR:-$REPO/deps/glslang-switch}"
    VK_ARGS=(-DCONKER_VULKAN=ON -DNVK_SDK="$NVK_SDK"
             -Dglslang_DIR="$GLSLANG_DIR/lib/cmake/glslang")
else
    BUILD="${BUILD_DIR:-$REPO/build/switch}"
    NRO_NAME=conker.nro
    VK_ARGS=(-DCONKER_VULKAN=OFF)
fi

LTO_ARGS=(-DCONKER_LTO=OFF)
if [ "${LTO:-0}" = "1" ]; then
    [ -z "${BUILD_DIR:-}" ] && BUILD="$BUILD-lto"
    NRO_NAME="${NRO_NAME%.nro}-lto.nro"
    LTO_ARGS=(-DCONKER_LTO=ON -DCONKER_LTO_JOBS="${LTO_JOBS:-4}")
fi

FFMPEG_DIR="${FFMPEG_DIR:-$REPO/deps/ffmpeg-vp6-switch}"
if [ -f "$FFMPEG_DIR/lib/libavcodec.a" ]; then
    FF_ARGS=(-DCONKER_FFMPEG_DIR="$FFMPEG_DIR")
else
    FF_ARGS=(-DCONKER_FFMPEG_DIR=)
fi

fail() { echo "error: $*" >&2; exit 1; }
[ -f "$DEVKITPRO/cmake/Switch.cmake" ] || fail "devkitPro not found at $DEVKITPRO"
[ -f "$DEVKITPRO/portlibs/switch/include/SDL2/SDL.h" ] || fail "switch-sdl2 missing"
[ -f "$GEN/recomp_funcs.h" ] || fail "no generated code in $GEN (run tools/regen.sh)"
[ -f "$GAME/default.xbe" ] || fail "no extracted disc in $GAME"

if [ -z "${JOBS:-}" ]; then
    if [ "$(uname)" = Darwin ]; then
        mem_mb=$(( $(sysctl -n hw.memsize) / 1048576 * 3 / 4 )); cpus=$(sysctl -n hw.ncpu)
    else
        mem_mb=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 )); cpus=$(nproc)
    fi
    JOBS=$(( mem_mb / 1500 )); [ "$JOBS" -lt 1 ] && JOBS=1
    [ "$JOBS" -gt "$cpus" ] && JOBS=$cpus
fi

cmake -S "$REPO" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$DEVKITPRO/cmake/Switch.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DXBOXRECOMP_DIR="$TK" -DCONKER_GEN_DIR="$GEN" \
    "${VK_ARGS[@]}" "${FF_ARGS[@]}" \
    "${LTO_ARGS[@]}" >/dev/null
ninja -C "$BUILD" -j"$JOBS"

DEST="$SD/switch/conker"
mkdir -p "$DEST/game"
cp "$BUILD/conker_recomp.nro" "$DEST/$NRO_NAME"
# The extracted disc is 4.4 GB: copy only what changed (STAGE_GAME=0 skips it).
[ "${STAGE_GAME:-1}" = "1" ] && rsync -a --size-only "$GAME/" "$DEST/game/" --exclude '*_analysis.json'
echo
echo "staged $DEST"
echo "  $NRO_NAME $(wc -c < "$DEST/$NRO_NAME" | tr -d ' ') bytes, game/ $(du -sh "$DEST/game" | cut -f1)"
echo "  copy <SD>/switch/conker/ to the card (or point Eden's sdmc at $SD),"
echo "  and start it from hbmenu with title takeover (hold R on a game) for full RAM."
