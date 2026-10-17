#!/usr/bin/env bash
# Build glslang for the Switch (devkitA64) and install it as a CMake package,
# for nv2a_vk, which compiles the NV2A shaders it generates at run time.
#
#   tools/build_glslang_switch.sh            -> deps/glslang-switch/
#
# The NFS ports used glslang 15.4. The optimizer (SPIRV-Tools) is left out:
# the Switch link in xboxrecomp/src/nv2a_vk/CMakeLists.txt does not use it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
VERSION="${GLSLANG_VERSION:-15.4.0}"
SRC="$REPO/deps/src/glslang-$VERSION"
BUILD="$REPO/deps/build/glslang-switch"
PREFIX="${GLSLANG_DIR:-$REPO/deps/glslang-switch}"

[ -f "$DEVKITPRO/cmake/Switch.cmake" ] || { echo "devkitPro not found at $DEVKITPRO" >&2; exit 1; }
if [ ! -d "$SRC" ]; then
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 -b "$VERSION" https://github.com/KhronosGroup/glslang.git "$SRC"
fi

cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$DEVKITPRO/cmake/Switch.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_OPT=OFF \
    -DGLSLANG_TESTS=OFF \
    -DGLSLANG_ENABLE_INSTALL=ON \
    -DENABLE_GLSLANG_BINARIES=OFF \
    -DENABLE_SPVREMAPPER=OFF \
    -DENABLE_HLSL=OFF
cmake --build "$BUILD"
cmake --install "$BUILD"
echo "glslang $VERSION for Switch installed in $PREFIX"
