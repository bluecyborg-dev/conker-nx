#!/usr/bin/env bash
# Run the Linux build headless for AT seconds, then print every thread's host
# backtrace with gdb (lifted functions keep their sub_XXXXXXXX names, so the
# frames are the guest call chain), take SNAPS snapshots 2 s apart, and stop.
#
#   AT=40 tools/snap_linux.sh            -> run/snap.txt, log in run/run.log
#   AT=40 SNAPS=3 EXTRA="VAR=1" tools/snap_linux.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AT="${AT:-40}"
SNAPS="${SNAPS:-2}"
BIN="${BIN:-build/linux-vk/conker_recomp}"
DEPTH="${DEPTH:-14}"

mkdir -p "$REPO/run/d"
mkdir -p "$REPO/run/save"
envs=(-e CONKER_GAME_DIR=/work/game -e CONKER_SAVE_DIR=/work/run/save -e RECOMP_FPS_LOG=1)
[ -n "${PAD:-}" ] && envs+=(-e RECOMP_PAD_SCRIPT="$PAD")
for kv in ${EXTRA:-}; do envs+=(-e "$kv"); done

docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    -v "$REPO":/work -w /work/run "${envs[@]}" conker-dev bash -c "
    /work/$BIN > /work/run/run.log 2>&1 &
    pid=\$!
    sleep $AT
    : > /work/run/snap.txt
    for i in \$(seq 1 $SNAPS); do
        echo \"=== snapshot \$i at \$(( $AT + (\$i - 1) * 2 ))s\" >> /work/run/snap.txt
        gdb -p \$pid -batch -ex 'set pagination off' \
            -ex 'thread apply all bt $DEPTH' >> /work/run/snap.txt 2>/dev/null
        sleep 2
    done
    kill -9 \$pid"
echo "snapshots in run/snap.txt ($(grep -c '^Thread' "$REPO/run/snap.txt") thread stacks)"
