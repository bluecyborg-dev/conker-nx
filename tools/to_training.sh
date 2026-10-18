#!/usr/bin/env bash
# Live bench to the training level, no hands: boot, profile menu -> Game 3 ->
# Play, wait for the level, skip the wake-up dialogue. Needs a save in
# run/live/save with Game 3 past the opening (KEEP_SAVE=1 keeps it).
#
#   tools/to_training.sh                         # then: tools/live_linux.sh press ...
#   tools/to_training.sh "RECOMP_SURF_STATS=1"   # extra switches for this run
#   SKIP=0 tools/to_training.sh                  # stop before skipping the dialogue
#
# Waits on log markers, not on time: bench boot varies by a minute, and a build
# running at the same time slows the game further.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LOG=run/live/run.log

tools/live_linux.sh stop >/dev/null
rm -f run/live/ft.flag
KEEP_SAVE=1 DUMPN="${DUMPN:-15}" EXTRA="${1:-}" tools/live_linux.sh start >/dev/null
# The title menu is up once a frame has a few hundred draws.
for i in $(seq 1 120); do
    sleep 3
    c=$(grep -o '[0-9]* draws' "$LOG" | tail -1 | cut -d' ' -f1 || true)
    [ -n "$c" ] && [ "$c" -gt 300 ] && break
done
sleep 25
tools/live_linux.sh press left:400; sleep 8      # pan to the save slots
tools/live_linux.sh press a:400; sleep 8         # Game 3
tools/live_linux.sh press a:400                  # Play
# The level's text bank is read at the end of the load.
for i in $(seq 1 90); do
    sleep 2
    grep -q 'text\\English\\TrainingLevel' "$LOG" && break
done
echo "training level loaded"
if [ "${SKIP:-1}" = "1" ]; then
    sleep 30
    for i in 1 2 3 4 5 6 7 8; do tools/live_linux.sh press b:400; sleep 4; done
    echo "dialogue skipped"
fi
