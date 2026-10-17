cmake_minimum_required(VERSION 3.20)

# ============================================================================
# Conker: Live & Reloaded (Xbox, PAL) - Static Recompilation
#
# Hosts: Windows (MSVC, D3D11), Linux (GCC, SDL2 + OpenGL) and Nintendo
# Switch homebrew (devkitA64 + libnx, built with switch/build.sh).
# ============================================================================

project(conker_recomp C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_compile_definitions(
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)

set(XBOXRECOMP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/xboxrecomp" CACHE PATH
    "Path to the xboxrecomp toolkit root directory")

# The lifted code is ~100 MB of C generated from the retail XBE. It is never
# committed; point this at wherever tools.recomp --gen-dir wrote it.
set(CONKER_GEN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/recomp/gen" CACHE PATH
    "Directory holding the tools.recomp output (recomp_*.c, recomp_funcs.h)")

if(NOT EXISTS "${CONKER_GEN_DIR}/recomp_funcs.h")
    message(FATAL_ERROR "No generated code in ${CONKER_GEN_DIR}. Run tools.recomp "
                        "with --gen-dir, or pass -DCONKER_GEN_DIR=<dir>.")
endif()

# The Vulkan renderer (xboxrecomp nv2a_vk) instead of OpenGL. On the Switch it
# links mesa-switch's static NVK (NVK_SDK) and builds conker-vulkan.nro.
option(CONKER_VULKAN "Render with Vulkan instead of OpenGL" OFF)
set(XBOXRECOMP_VULKAN ${CONKER_VULKAN} CACHE BOOL "" FORCE)

# Conker's XBE image ends at 0x00891D20, past the toolkit's default stack base
# (0x00780000): the guest stacks and the runtime data block would overlap the
# game's .data. Everything (runtime, lifted code, main.c) must agree on it.
add_compile_definitions(XBOX_STACK_BASE=0x00900000)
# The title's SD-card folder for the toolkit's shader/pipeline caches. Without
# it they went to Burnout 3's folder (sdmc:/switch/b3x/), which does not exist
# here: nothing was ever cached and every console run compiled each shader and
# pipeline the first time it was drawn (a 4 s stall at the intro movie).
add_compile_definitions(XBOXRECOMP_SWITCH_DIR="sdmc:/switch/conker/")

add_subdirectory(${XBOXRECOMP_DIR} ${CMAKE_BINARY_DIR}/xboxrecomp)

file(GLOB RECOMP_GEN_SOURCES CONFIGURE_DEPENDS "${CONKER_GEN_DIR}/*.c")

set(GAME_SOURCES
    src/main.c
    src/recomp_manual.c
    src/switch_nx.c
    src/linux_prof.c
    src/switch_saltynx.c
)

if(WIN32)
    add_executable(${PROJECT_NAME} WIN32 ${GAME_SOURCES} ${RECOMP_GEN_SOURCES})
else()
    add_executable(${PROJECT_NAME} ${GAME_SOURCES} ${RECOMP_GEN_SOURCES})
endif()

target_link_libraries(${PROJECT_NAME} PRIVATE xboxrecomp)

# Movies: VP6 decoded by FFmpeg instead of the lifted On2 decoder
# (src/movie_vp6.c). CONKER_FFMPEG_DIR is an install of the minimal LGPL
# build from tools/build_ffmpeg_vp6.sh (libavcodec with only the vp6
# decoder); without it the lifted decoder plays the movies.
set(CONKER_FFMPEG_DIR "" CACHE PATH "FFmpeg (vp6 decoder) install prefix")
if(CONKER_FFMPEG_DIR)
    if(NOT EXISTS "${CONKER_FFMPEG_DIR}/lib/libavcodec.a")
        message(FATAL_ERROR "no libavcodec.a in ${CONKER_FFMPEG_DIR}/lib (tools/build_ffmpeg_vp6.sh)")
    endif()
    target_sources(${PROJECT_NAME} PRIVATE src/movie_vp6.c)
    target_compile_definitions(${PROJECT_NAME} PRIVATE CONKER_NATIVE_VP6=1)
    # BEFORE: the Switch portlibs include dir has devkitPro's (GPL) FFmpeg headers.
    target_include_directories(${PROJECT_NAME} BEFORE PRIVATE "${CONKER_FFMPEG_DIR}/include")
    target_link_libraries(${PROJECT_NAME} PRIVATE
        "${CONKER_FFMPEG_DIR}/lib/libavcodec.a" "${CONKER_FFMPEG_DIR}/lib/libavutil.a")
endif()

if(CONKER_VULKAN)
    target_compile_definitions(${PROJECT_NAME} PRIVATE CONKER_VULKAN=1)
endif()

target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CONKER_GEN_DIR}
    ${XBOXRECOMP_DIR}/include
)

if(WIN32)
    target_link_libraries(${PROJECT_NAME} PRIVATE
        d3d11 dxgi dxguid xinput winmm dbghelp)
    if(MSVC)
        target_link_options(${PROJECT_NAME} PRIVATE /LARGEADDRESSAWARE)
        target_compile_options(${PROJECT_NAME} PRIVATE /bigobj)
    endif()
else()
    # The generated chunks are huge straight-line functions; -O1 keeps GCC's
    # memory and time per chunk sane while still allocating registers. The
    # Switch's CPU is the bottleneck there, so it gets -O2.
    if(NINTENDO_SWITCH)
        set(CONKER_GEN_OPT "-O2" CACHE STRING "Optimisation for the lifted code")
    else()
        set(CONKER_GEN_OPT "-O1" CACHE STRING "Optimisation for the lifted code")
    endif()
    # CONKER_LTO: link-time optimisation of the lifted code and its manual
    # overrides, so lifted callers inline each other and the native leaves
    # (_ftol2, ...). The runtime and renderers are compiled as usual.
    # CONKER_LTO_JOBS parallel LTRANS jobs (memory: ~1-2 GB each).
    option(CONKER_LTO "Link-time optimisation of the lifted code" OFF)
    set(CONKER_LTO_JOBS "4" CACHE STRING "Parallel LTO link jobs")
    set(CONKER_GEN_FLAGS "${CONKER_GEN_OPT};-w;-fno-strict-aliasing;-fwrapv")
    if(CONKER_LTO)
        list(APPEND CONKER_GEN_FLAGS "-flto=auto")
        set_property(SOURCE src/recomp_manual.c APPEND PROPERTY
            COMPILE_OPTIONS "-flto=auto;-fno-strict-aliasing;-fwrapv")
        target_link_options(${PROJECT_NAME} PRIVATE
            "-flto=${CONKER_LTO_JOBS}" "-flto-partition=balanced" ${CONKER_GEN_OPT})
    endif()
    set_source_files_properties(${RECOMP_GEN_SOURCES} PROPERTIES
        COMPILE_OPTIONS "${CONKER_GEN_FLAGS}")
    target_link_libraries(${PROJECT_NAME} PRIVATE m)
endif()

# ── Nintendo Switch homebrew (devkitA64 + libnx) ────────────────
#
# Build with switch/build.sh. The NRO reads the extracted disc from
# sdmc:/switch/conker/game/ (never an ISO); logs and conker_env.txt live in
# sdmc:/switch/conker/.
if(NINTENDO_SWITCH)
    set(CONKER_SWITCH_APP_NAME "Conker (Xbox recomp)" CACHE STRING
        "Title shown in the homebrew menu")
    set(CONKER_SWITCH_AUTHOR "conker-nx" CACHE STRING "Author shown in the homebrew menu")
    # The release lives here, not in the cache: a cached default stays at
    # whatever the build directory was first configured with.
    # -DCONKER_SWITCH_VERSION_OVERRIDE=x sets another one.
    set(CONKER_SWITCH_VERSION "0.0.1")
    if(CONKER_SWITCH_VERSION_OVERRIDE)
        set(CONKER_SWITCH_VERSION "${CONKER_SWITCH_VERSION_OVERRIDE}")
    endif()
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/assets/icon.jpg")
        set(CONKER_ICON_DEFAULT "${CMAKE_CURRENT_SOURCE_DIR}/assets/icon.jpg")
    else()
        set(CONKER_ICON_DEFAULT "")
    endif()
    set(CONKER_SWITCH_ICON "${CONKER_ICON_DEFAULT}" CACHE FILEPATH
        "256x256 JPEG icon (libnx default when empty)")

    if(CONKER_VULKAN)
        # No GL: SDL is only the audio output; NVK comes with nv2a_vk.
        target_link_libraries(${PROJECT_NAME} PRIVATE nx m)
    else()
        # switch-sdl2's GL path is EGL on switch-mesa.
        target_link_libraries(${PROJECT_NAME} PRIVATE EGL glapi drm_nouveau nx m)
    endif()
    # SDL's audio thread gets a real-time priority and audren gaps are
    # counted (switch_nx.c, "SDL's audio thread").
    target_link_options(${PROJECT_NAME} PRIVATE
        "LINKER:--wrap=SDL_SYS_SetThreadPriority"
        "LINKER:--wrap=audrvVoiceAddWaveBuf")
    set_property(SOURCE src/switch_nx.c APPEND PROPERTY
        INCLUDE_DIRECTORIES "${XBOXRECOMP_DIR}/src/apu")
    # switch_nx.c's loading screen asks EGL for the on-screen size.
    target_include_directories(${PROJECT_NAME} PRIVATE "$ENV{DEVKITPRO}/portlibs/switch/include")

    set(CONKER_NACP "${CMAKE_CURRENT_BINARY_DIR}/conker.nacp")
    nx_generate_nacp(OUTPUT "${CONKER_NACP}"
        NAME "${CONKER_SWITCH_APP_NAME}"
        AUTHOR "${CONKER_SWITCH_AUTHOR}"
        VERSION "${CONKER_SWITCH_VERSION}")
    if(CONKER_SWITCH_ICON)
        nx_create_nro(${PROJECT_NAME} NACP "${CONKER_NACP}" ICON "${CONKER_SWITCH_ICON}")
    else()
        nx_create_nro(${PROJECT_NAME} NACP "${CONKER_NACP}")
    endif()
endif()
