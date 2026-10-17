# The target: Conker: Live & Reloaded (Xbox)

## The disc in this repo

`conker.7z` (3.85 GB) holds `Conker - Live & Reloaded (Europe) (En,Ja,Fr,De,Es,It).iso` (4.76 GB) and a
`readme.txt`. It is an image of the **PAL release's game partition**:

- `tools.xiso ls` finds the XDVDFS volume at offset **0** (a bare game partition, no DVD-video partition in
  front, despite the Redump-style name). Extracted 2026-10-16 with `tar -xf conker.7z` (macOS bsdtar reads
  7z) and `python -m tools.xiso unpack <iso> -o game/` (4.4 GB).
- Contents: `default.xbe` (7.4 MB), `dashupdate.xbe`, `update.xbe`; `dvddata/Audio/` (77 XACT wave banks
  `.xwb` + one `.xsb` sound bank, 3.6 GB), `dvddata/fmv/` (59 XMV movies, 224 MB), `dvddata/aid/` (Rare's
  own formats: 473 `.bin`, 161 `.rbm`, 105 `.rba`, 548 MB), `media/` (24 MB, one `.xpr`, a `.ttf`).
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

- [x] **Answered 2026-10-16** (`xbe_parser`, full report in `analysis/`, git-ignored):
      - Title ID **0x4D530051**, retail, built 2005-04-28, region **Rest of World** (PAL), media DVD_X2,
        debug path `D:\work\Bfd\Game\BuildOutput\FinalRelease.exe` (Rare's "Bfd" = Bad Fur Day).
      - Base 0x00010000, image 8.51 MB (ends 0x00891D20), **entry 0x0042F0E9**, kernel thunks 0x00561000.
      - 27 sections: `.text` 4.48 MB (0x00011000), library sections D3DX, XNET, XONLINE, DSOUND, XMV,
        WMADEC, XGRPH, D3D, PAGELK, XACTENG, EFFECT_U/EFFECT_C/EFFECTS_ (x86 SSE code), XPP; data
        `.rdata`, `.data` (2.2 MB virtual), XON_RD, DOLBY, `.data1`; non-preloaded `$$XTIMAGE`,
        `$$XSIMAGE`, bitmaps, `.XTLID`.
      - **145 kernel imports, all handled** by the toolkit (`tools.kernel_audit.coverage`).
- [x] **XDK 5849 for every library, D3D8LTCG** (flags 0x400F), DSOUND flags 0x400B (Carbon's later
      build), plus XACTENLT (XACT audio engine), WMADEC, XVOICE/VOICMAIL, XONLINES. Same XDK as Burnout 3,
      NFSU2 and Carbon. The D3D code is laid out like Burnout's locally (ISR → vblank handler is 0x2D0
      in both), and the DSOUND bodies match Burnout's/Carbon's instruction for instruction. Hooks:
      [09-bringup-log.md](09-bringup-log.md).
- [ ] Threads created at boot, XMV/other movie format, file formats on the disc.
- [ ] Self-modifying code / runtime code generation (would break static recompilation).
- [ ] Presentation interval (30 or 60 fps) and how the main loop steps simulation time (fixed steps per
      frame → slow motion below target, the Burnout/NFSU2 problem).
- [ ] Which NV2A features the frames use: texture shader modes per stage, cube maps, stencil, point sprites,
      fixed-function lighting vs vertex programs. Answer it with `RECOMP_FRAME_TRACE` once something
      draws ([07](07-debugging.md)).
