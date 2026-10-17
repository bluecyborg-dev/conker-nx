#!/usr/bin/env bash
# Interactive Linux bench: the game runs in the background (container
# conker-live), reads pad presses appended to run/live/pad.cmd and dumps a
# frame every DUMPN flips to run/live/d/.
#
#   tools/live_linux.sh start            # fresh save dir unless KEEP_SAVE=1
#   tools/live_linux.sh press a:400      # append a press (names as RECOMP_PAD_SCRIPT;
#                                        # "&x:ms" holds together, "clear" drops queued)
#   tools/live_linux.sh frame [out.png]  # newest dumped frame as PNG
#   tools/live_linux.sh log [N]          # last N log lines
#   tools/live_linux.sh stop
#
# Environment: DUMPN (default 30), EXTRA ("VAR=1 VAR2=2"), BIN, KEEP_DUMPS (newest frame dumps
# kept, default 300: a long run at DUMPN=15 once filled the disk with 9 GB of BMPs and hung Docker).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE="$REPO/run/live"
NAME=conker-live
BIN="${BIN:-build/linux-vk/conker_recomp}"
DUMPN="${DUMPN:-30}"

case "${1:-}" in
start)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    mkdir -p "$LIVE/d"
    rm -f "$LIVE"/d/*.bmp
    : > "$LIVE/pad.cmd"
    [ "${KEEP_SAVE:-0}" = "1" ] || rm -rf "$LIVE/save"
    mkdir -p "$LIVE/save"
    envs=(-e CONKER_GAME_DIR=/work/game -e CONKER_SAVE_DIR=/work/run/live/save
          -e RECOMP_GL_DUMP="/work/run/live/d/f,$DUMPN" -e RECOMP_FPS_LOG=1
          -e RECOMP_PAD_LIVE=/work/run/live/pad.cmd)
    for kv in ${EXTRA:-}; do envs+=(-e "$kv"); done
    docker run -d --name "$NAME" --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
        -v "$REPO":/work -w /work/run/live "${envs[@]}" conker-dev \
        bash -c "while sleep 20; do ls -t /work/run/live/d/*.bmp 2>/dev/null | tail -n +${KEEP_DUMPS:-300} | xargs -r rm -f; done &
                 exec /work/$BIN > /work/run/live/run.log 2>&1" >/dev/null
    echo "started $NAME (log run/live/run.log, frames run/live/d/)"
    ;;
press)
    shift
    for p in "$@"; do echo "$p" >> "$LIVE/pad.cmd"; done
    ;;
frame)
    # sed reads to the end: head would close the pipe early and, with many
    # dumps, ls dies of SIGPIPE (exit 141 under pipefail).
    f=$(ls -t "$LIVE"/d/f*.bmp 2>/dev/null | grep -v fxaa | sed -n 1p)
    [ -n "$f" ] || { echo "no frame yet" >&2; exit 1; }
    out="${2:-$LIVE/latest.png}"
    sips -s format png "$f" --out "$out" >/dev/null
    echo "$(basename "$f") -> $out"
    ;;
log)
    tail -n "${2:-30}" "$LIVE/run.log"
    ;;
stop)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "stopped"
    ;;
*)
    sed -n '2,15p' "$0"; exit 1 ;;
esac
