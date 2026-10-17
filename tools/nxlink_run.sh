#!/usr/bin/env bash
# Send the NRO to the Switch over Wi-Fi, start it, and keep its log on the Mac.
#
#   tools/nxlink_run.sh <switch-ip>                       # newest Vulkan build
#   ARGS="RECOMP_FPS_LOG=1 RECOMP_WATCHDOG_SECS=60" tools/nxlink_run.sh <switch-ip>
#   NRO=analysis/elf_archive/<name>.nro tools/nxlink_run.sh <switch-ip>
#
# On the Switch first: hold R while starting any game (title takeover: full
# memory), then press Y in the Homebrew Menu to open the NetLoader.
#
# The NRO is written to sdmc:/switch/conker/conker-vulkan.nro (replacing the
# one there) and started; the game data on the card stays where it is. With
# nxlink -s the netloader's own server receives the game's stdout/stderr
# (switch_nx.c: nxlinkStdio), printed here and saved in run/net_logs/.
# ARGS are KEY=VALUE pairs; main.c turns them into settings that override
# conker_env.txt. The netloader cuts arguments at about 256 characters.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IP="${1:-}"
NRO="${NRO:-$REPO/switch_sd/switch/conker/conker-vulkan.nro}"
NXLINK="${NXLINK:-/opt/devkitpro/tools/bin/nxlink}"
ARGS="${ARGS:-}"

[ -f "$NRO" ] || { echo "no NRO at $NRO (run VULKAN=1 switch/build.sh)" >&2; exit 1; }
[ -x "$NXLINK" ] || { echo "nxlink not found at $NXLINK (devkitPro switch-tools)" >&2; exit 1; }
if [ "${#ARGS}" -gt 240 ]; then
    echo "ARGS is ${#ARGS} characters; the netloader keeps about 256 -- shorten it" >&2
    exit 1
fi

# A listener left over from an earlier run (nxlink -s serves on 28771) would
# take the game's connection and stop reading it: the game then blocks on
# stdout (BO1 hit exactly that). Stop it first.
for pid in $(lsof -t -iTCP:28771 -sTCP:LISTEN 2>/dev/null || true); do
    echo "stopping old listener $pid on port 28771"
    kill "$pid" 2>/dev/null || true
done

mkdir -p "$REPO/run/net_logs"
LOG="$REPO/run/net_logs/$(date +%Y%m%d-%H%M%S).log"
ln -sf "$(basename "$LOG")" "$REPO/run/net_logs/latest.log"

addr=()
[ -n "$IP" ] && addr=(-a "$IP")
extra=()
[ -n "$ARGS" ] && extra=(--args "$ARGS")
echo "sending $(basename "$NRO") ($(($(wc -c < "$NRO") / 1048576)) MB)${IP:+ to $IP}; log: $LOG"
"$NXLINK" ${addr[@]+"${addr[@]}"} -r 30 -s -p switch/conker/conker-vulkan.nro ${extra[@]+"${extra[@]}"} "$NRO" 2>&1 | tee "$LOG"
echo "connection closed; $(wc -l < "$LOG" | tr -d ' ') lines in $LOG"
