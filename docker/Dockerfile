# Linux test bench for the Conker recompilation (arm64 on Apple Silicon: the
# lifted C is built for AArch64, as on the Switch). GL and Vulkan builds;
# Vulkan runs headless on Mesa's lavapipe.
#
#   docker build -t conker-dev docker/
#   docker run --rm -it -v "$PWD":/work -w /work conker-dev
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake ninja-build build-essential pkg-config gdb file \
        libsdl2-dev libgl1-mesa-dev libepoxy-dev libssl-dev \
        libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
        libvulkan-dev mesa-vulkan-drivers vulkan-tools vulkan-validationlayers \
        glslang-dev glslang-tools spirv-tools \
        python3 python3-capstone python3-pefile \
    && rm -rf /var/lib/apt/lists/*

# Headless by default: no window, Vulkan on lavapipe.
ENV SDL_VIDEODRIVER=offscreen \
    SDL_AUDIODRIVER=dummy \
    VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
    RECOMP_VK_HEADLESS=1
