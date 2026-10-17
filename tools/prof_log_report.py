#!/usr/bin/env python3
"""prof_log_report.py LOG ELF [--top N] [--from S] [--to S]

Per-thread function tables from the "[profile]" lines a RECOMP_NX_PROFILE run
writes into its log every 10 s (src/switch_nx.c prof_summary): no prof.bin
needed. Each line carries one thread slot's sample count and its hottest
128-byte code granules as NRO offsets; this resolves each granule to the ELF
function that contains its start and sums them. A granule that straddles two
functions is charged to the first, so small functions can be slightly off.

--from/--to select windows by their index (window 0 is the first 10 s of
sampling), e.g. only the windows recorded in gameplay. Slots are named by the
"[prof] slots:" line (thread entry offsets).
"""
import argparse
import bisect
import collections
import re
import subprocess

NM = "/opt/devkitpro/devkitA64/bin/aarch64-none-elf-nm"


def symbols(elf):
    out = subprocess.run([NM, "-n", "--defined-only", elf], capture_output=True, text=True,
                         check=True).stdout
    addrs, names = [], []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1] in "tTwW":
            addrs.append(int(parts[0], 16))
            names.append(parts[2])
    return addrs, names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("elf")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--from", dest="first", type=int, default=0)
    ap.add_argument("--to", dest="last", type=int, default=1 << 30)
    ap.add_argument("--callers", action="store_true",
                    help="read the [profile-lr] lines: samples by caller (lr) instead of pc")
    ap.add_argument("--window-s", type=float, default=10.0,
                    help="window length: 10 on the console, 1 for RECOMP_LINUX_PROFILE")
    a = ap.parse_args()

    addrs, names = symbols(a.elf)

    def name_of(off):
        i = bisect.bisect_right(addrs, off) - 1
        return names[i] if i >= 0 else "?"

    slots = {}
    per_slot = collections.defaultdict(collections.Counter)
    totals = collections.Counter()
    shown = collections.Counter()
    windows = collections.Counter()
    window = -1
    seen_in_window = set()
    for line in open(a.log, errors="replace"):
        if line.startswith("[prof] slots:"):
            for s, off in re.findall(r" (\d+)=([0-9a-f]+)", line):
                slots[int(s)] = name_of(int(off, 16)) if int(off, 16) else "?"
            continue
        m = re.match(r"\[profile%s\] slot (\d+) n (\d+):(.*)" % ("-lr" if a.callers else ""), line)
        if not m:
            continue
        slot = int(m.group(1))
        if slot in seen_in_window or window < 0:
            window += 1
            seen_in_window = set()
        seen_in_window.add(slot)
        if not a.first <= window <= a.last:
            continue
        windows[slot] += 1
        totals[slot] += int(m.group(2))
        for g, c in re.findall(r" ([0-9a-f]+):(\d+)", m.group(3)):
            per_slot[slot][name_of(int(g, 16))] += int(c)
            shown[slot] += int(c)

    for slot in sorted(totals, key=lambda s: -totals[s]):
        n = totals[slot]
        print("slot %d (%s): %d samples in %d windows (%.0f%% of a core), top granules cover %.0f%%"
              % (slot, slots.get(slot, "?"), n, windows[slot], n / (windows[slot] * a.window_s * 10.0),
                 100.0 * shown[slot] / n))
        for fn, c in per_slot[slot].most_common(a.top):
            print("  %5.1f%%  %s" % (100.0 * c / n, fn))
        print()


if __name__ == "__main__":
    main()
