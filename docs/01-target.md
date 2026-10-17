# The target: Conker: Live & Reloaded (Xbox)

## The disc in this repo

`conker.7z` (3.85 GB) holds `Conker - Live & Reloaded (Europe) (En,Ja,Fr,De,Es,It).iso` (4.76 GB) and a
`readme.txt`. This is a **Redump full-disc image of the PAL release**:

- The game partition starts at `0x18300000` (after a ~387 MB DVD-video partition). xboxrecomp's
  `python3 -m tools.xiso unpack` probes that offset, and its source says the offset was confirmed on the
  Conker Redump image (`tools/xiso/xdvdfs.py`).
- macOS `tar -tf conker.7z` (bsdtar) lists the archive. Extracting it needs 7-Zip (`brew install sevenzip`)
  or bsdtar.
- **It is PAL; all four reference ports are NTSC-U.** See "PAL" below.
- Never commit the disc, the extracted files, `default.xbe` or generated C.

## The hardware the game was written for

| Part | Original Xbox | Consequence on the Switch |
|---|---|---|
| CPU | Intel Pentium III-class, 733 MHz, x87 + SSE (1), single core | Recompiled single-thread code on a 1020 MHz A57 is the usual limit. The game has no multi-core design to exploit, but its threads (audio mixer, streaming) still compete for the guest lock ([04](04-switch-platform.md)) |
| GPU | NV2A (NV20/NV25 class), 233 MHz: vertex programs, register combiners (8 general + final), 4 texture stages with *texture shader* modes | Everything goes through the pushbuffer executor and `nv2a_vk` ([05](05-renderer.md)) |
| Memory | 64 MB unified (retail); RAM mirrors at 0x0 and the 0x80000000 contiguous window; tiled framebuffer aperture at 0xF0000000 | Horizon cannot alias memory the way Windows/Linux can ([04](04-switch-platform.md), "Memory") |
| Audio | MCPX APU (voice processor, GP/EP DSPs) | xboxrecomp emulates the voice processor (from xemu, LGPL). There is no DSP56300: DirectSound's doorbell is acknowledged instead |
| Storage | DVD + 8 GB HDD (save partitions, cache partitions) | Partitions map to folders; never pass guest memory to Horizon file IPC |

## What we know about the game binary

From xboxrecomp's study of Microsoft's own Xbox→360/One back-compat recompiler (Fission), which processed Conker
(`docs/technical/ms-fusion-corpus.md` in the toolkit):

- **Rare's engine is more C++-abstracted** than the other titles studied: only 10 named `D3DDevice_` and 16
  `D3DX` symbols, but C++ STL in the symbol table. So the game probably calls few XDK graphics helpers and
  does more in its own classes. Expect heavier indirect-call dispatch (vtables): budget for missing-function
  seeds and `[ICALL] Failed` hunting.
- **Heavy networking**: 615 XNet/XOnline symbols (`CXnIp` etc.), the most in that corpus. Conker had Xbox
  Live multiplayer. Offline play must not wait on the network stack (Halo's XNet DHCP spin is the known
  failure). NFSU2 also hit an XNet bug: an unaligned `lock` atomic that faults on AArch64.
- **DirectSound linked in full** (387 functions): the audio bring-up will look like Burnout's and NFS's.
- The toolkit's conformance harness (running the game's own x86 functions as the oracle) was "verified clean
  on Burnout 3, Conker, Crimson Skies and Blood Wake". Someone has already lifted and exercised Conker's code
  with this toolkit.
- xboxrecomp's `candidate-games.md` puts Conker in **Tier 3 (challenging): "Rare, complex shaders"**.

## PAL: what to expect

The kernel layer reports a North American console: `ExQueryNonVolatileSetting` returns English, NTSC and
widescreen, and `AvSendTVEncoderOption(QUERY_AVPACK)` returns `AV_STANDARD_NTSC_M | 60Hz`
(`kernel_xbox.c`, `kernel_hal.c`). The vblank runs at 59.94 Hz (`kernel_bridge.c`). For a PAL XBE:

- XAPI checks the XBE certificate's game region against the console's region (EEPROM). A mismatch can send
  the title to the dashboard / `HalReturnToFirmware`, the same symptom Burnout 3 had with a missing
  `saves/` folder. Report the region the XBE asks for (read it with `xbe_parser`).
- PAL titles choose between 50 Hz and PAL-60 from `XC_VIDEO_FLAGS_PAL_60Hz` (0x00400000) and the AV
  standard. If the game paces anything on vblanks (movies, the main loop), 50 vs 59.94 Hz changes its speed.
  Report PAL-I + PAL-60 and check which display mode D3D picks (Burnout's display-mode table notes in
  `kernel_hal.c` show how a wrong standard fails `CreateDevice`).
- Language: the PAL disc carries six languages; `XC_LANGUAGE` = 1 (English) is fine.
- An NTSC-U disc would match the reference ports exactly. If PAL becomes a blocker, it is worth
  considering.

## Things to find out first (before any code)

Run on the XBE (toolkit pipeline steps 3-6, see [02-approach.md](02-approach.md)) and write the answers here:

- [ ] Title ID, XBE certificate region and media flags, entry point, section list (D3D, DSOUND, XPP, XNET,
      ... as separate sections?), `.text` size, kernel import count.
- [ ] **XDK version** and the D3D flavour (D3D8 or D3D8LTCG). NFSU2/Carbon/Burnout use 5849, NFSU1 uses 5558.
      D3D/DSOUND/XPP/CRT bodies matched the reference ports byte for byte apart from relocations
      (Carbon vs NFSU2: 100 % with the same XDK; NFSU1's 5558 D3D/DSOUND/CRT vs 5849 too, though game code
      differs). So the library hooks can be found by matching the first ~24 normalized instructions
      against every function start.
- [ ] Threads created at boot, XMV/other movie format, file formats on the disc.
- [ ] Self-modifying code / runtime code generation (would break static recompilation).
- [ ] Presentation interval (30 or 60 fps) and how the main loop steps simulation time (fixed steps per
      frame → slow motion below target, the Burnout/NFSU2 problem).
- [ ] Which NV2A features the frames use: texture shader modes per stage, cube maps, stencil, point sprites,
      fixed-function lighting vs vertex programs. Answer it with `RECOMP_FRAME_TRACE` once something
      draws ([07](07-debugging.md)).
