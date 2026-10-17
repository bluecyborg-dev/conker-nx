#!/usr/bin/env bash
# Run the Linux build headless in the conker-dev container for SECS seconds,
# with the log in run/run.log and frames dumped to run/d/ (BMP).
#
#   tools/run_linux.sh                     # 60 s, Vulkan build, a frame every 60 flips
#   SECS=120 DUMPN=30 tools/run_linux.sh
#   EXTRA="RECOMP_FRAME_TRACE=/work/run/trace.flag XBOX_LOG_LEVEL=3" tools/run_linux.sh
#   PAD="20000:start:300,30000:a:400" tools/run_linux.sh
#
# Environment: SECS, DUMPN, BIN (default build/linux-vk/conker_recomp), PAD
# (RECOMP_PAD_SCRIPT), EXTRA (more VAR=value pairs, space separated).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECS="${SECS:-60}"
DUMPN="${DUMPN:-60}"
BIN="${BIN:-build/linux-vk/conker_recomp}"

mkdir -p "$REPO/run/d"
rm -f "$REPO"/run/d/*.bmp
mkdir -p "$REPO/run/save"
envs=(-e CONKER_GAME_DIR=/work/game -e CONKER_SAVE_DIR=/work/run/save -e RECOMP_GL_DUMP="/work/run/d/f,$DUMPN" -e RECOMP_FPS_LOG=1)
[ -n "${PAD:-}" ] && envs+=(-e RECOMP_PAD_SCRIPT="$PAD")
for kv in ${EXTRA:-}; do envs+=(-e "$kv"); done

echo "running $BIN for ${SECS}s (log: run/run.log, frames: run/d/)"
# The binary ignores SIGTERM; timeout -s KILL ends it.
docker run --rm -v "$REPO":/work -w /work/run "${envs[@]}" conker-dev \
    timeout -s KILL "$SECS" "/work/$BIN" > "$REPO/run/run.log" 2>&1 || true
echo "exit; $(ls "$REPO"/run/d/*.bmp 2>/dev/null | wc -l | tr -d ' ') frames dumped"
tail -n 25 "$REPO/run/run.log"
