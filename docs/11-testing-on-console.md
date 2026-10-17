# Testing on the console without moving the SD card

The game data stays on the SD card. Only the NRO (77 MB) goes over Wi-Fi with each build, and the log comes
back to the Mac live. The card only comes out for a file that cannot be streamed back. This follows the BO1
port's workflow (asked of its session on 2026-10-16, `../bo1-nx/tools/nxlink_run.sh`), adapted to Conker,
whose Switch layer logs through the netloader's own server instead of BO1's custom TCP sink.

## SD card layout (permanent)

```
sdmc:/switch/conker/conker-vulkan.nro   replaced by every nxlink upload
sdmc:/switch/conker/conker_env.txt      optional settings, KEY=VALUE per line, '#' comments
sdmc:/switch/conker/conker_log.txt      the log, when no nxlink host is listening
sdmc:/switch/conker/game/               the extracted disc (4.5 GB), copied once
sdmc:/switch/conker/save/               saves, the X:/Y:/Z: cache partitions, partition images
```

Copied 2026-10-16 to the card (FAT32 named "NO NAME"): the NRO and `game/` (file list verified identical to
the repo's `game/`, minus `default_analysis.json`). macOS writes `._*` AppleDouble files on FAT. Copy with
`COPYFILE_DISABLE=1` and delete them afterwards:
`find "/Volumes/NO NAME/switch/conker" -name '._*' -delete`.

## A Wi-Fi run, end to end

On the Switch:

1. **Title takeover**: hold R while starting any installed game. The Homebrew Menu then runs with the game's
   full memory (about 3.2 GB) instead of the applet budget (about 400 MB), which a recompiled game needs.
2. Press **Y** in the Homebrew Menu to open the NetLoader.

On the Mac:

```sh
tools/nxlink_run.sh <switch-ip>                                       # newest build in switch_sd/
ARGS="RECOMP_FPS_LOG=1 RECOMP_WATCHDOG_SECS=60" tools/nxlink_run.sh <switch-ip>
NRO=analysis/elf_archive/conker-vulkan_<md5>.nro tools/nxlink_run.sh <switch-ip>   # an archived build
```

What `tools/nxlink_run.sh` does:

1. Stops any listener left on port 28771. BO1 lost a run to a stale `nc` that took the game's connection and
   stopped reading it: the game blocked on stdout at a black screen.
2. Runs `nxlink -a <ip> -r 30 -s -p switch/conker/conker-vulkan.nro [--args "$ARGS"] <nro>`. The netloader
   writes the NRO at that SD path, replacing the old one, and starts it. `-s` keeps nxlink running as the
   log server.
3. Conker's Switch layer (`src/switch_nx.c`, `nxlinkStdio()`) sends stdout and stderr to that server; the
   script prints them and saves them in `run/net_logs/<time>.log` (`latest.log` points at the newest).
   Without an nxlink host the log goes to `sdmc:/switch/conker/conker_log.txt`.
4. It ends when the game closes the connection (exit or crash).

## Changing settings between runs without touching the card

- **Launch arguments**: `ARGS="KEY=VALUE KEY2=VALUE2"`. `src/main.c` (Switch) turns every `KEY=VALUE` argument
  into a setting after `conker_env.txt` is read, so arguments override the file, and the log shows
  `[switch] arg KEY=VALUE` for each. Any runtime switch from [07-debugging.md](07-debugging.md) works this way.
- The netloader keeps only about **256 characters** of arguments and silently drops the rest. The script
  refuses more than 240. Spaces separate arguments, so values cannot contain spaces.
- `conker_env.txt` on the card holds stable defaults. Changing it means touching the card, so keep test
  switches off by default and turn them on per run with `ARGS`.
- An in-game toggle (BO1 uses MINUS + D-pad for live presets) avoids relaunching at all. Worth adding once the
  game draws.

## Getting files back without pulling the card

| What | How | Status for Conker |
|---|---|---|
| The log | live over nxlink (above) | ready |
| Crash state | the CPU exception handler (`switch_nx.c`) prints host and guest state to the log, so it reaches the Mac before the process dies | ready; resolve addresses against the archived ELF of that build |
| Profiler | `RECOMP_NX_PROFILE=1` writes `sdmc:/switch/conker/prof.bin`; `tools/prof_report.py prof.bin <elf> <log>` | file on the card. BO1 forwards its profiler report text into the log as `[profile]` lines; worth copying if pulling `prof.bin` becomes a chore |
| Frame and surface dumps | BO1 sends images over their own TCP connection (`tools/dump_receiver.py`, port 28772) | not in this toolkit yet; the dumps (`RECOMP_GL_DUMP`) write files on the card |
| Any file | FTP (ftpd) or MTP (the `haze` NRO on this card) | untested in both ports. The obvious way to fetch `prof.bin` or edit `conker_env.txt`. BO1's card dropped writes: a file the Mac reads fine is not proof the Switch reads it fine; never overwrite in place on a suspect card |

## Failure modes BO1 hit (and what Conker's setup does about them)

1. **Stale listener → black screen** (the game blocked writing stdout to a listener nobody read). The script
   kills listeners on 28771 first.
2. **1.7-4.4 s whole-game freezes from logging**: BO1's sink called `send()` on the logging thread inside a
   mutex; a Wi-Fi stall held every thread that logs. Fixed there with a queue and one sender thread. Conker's
   `nxlinkStdio()` writes stdout straight to the socket, so the same risk exists: **if Wi-Fi runs show
   freezes that SD-log runs do not, move the network writes to a sender thread**.
3. **`std::thread` at early init crashed BO1 at startup**. Use libnx `threadCreate` (priority 0x2C, core -2)
   for runtime threads; on Horizon only priority 0x3B is time-sliced.
4. **Arguments over 256 characters silently cut**. The script refuses; group options into presets.
5. **A connection that closes after a few seconds with an empty log** is a crash at or before the logger's
   start. Check the newest init code first.
6. Log volume: BO1's profiler forwarding is about 20 KB/s, fine over Wi-Fi only because of fix 2.
