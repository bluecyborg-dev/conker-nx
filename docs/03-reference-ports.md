# The four original-Xbox → Switch ports (antoxa2584x)

All four are lifted with xboxrecomp and built as libnx NROs with GL and Vulkan (NVK) back ends. They were
started one from another: NFSU2 (2026-09-28) → NFSU1 (10-02) → Carbon (10-03) → Burnout 3 (10-08). Each
`CLAUDE.md` is a dense log of findings, and most of what follows comes from them. Addresses below are
**those titles'** addresses. For Conker, carry over the mechanism and find our own address.

| Port | Title / XDK | Engine | Result on hardware |
|---|---|---|---|
| nfsu2-sw | NFSU2 NTSC-U, XDK 5849 | EA | Races 6-12 → ~20 fps (GL, stock), Vulkan about the same at first; v0.5.9 uncapped to 60 |
| nfsu1-sw | NFSU1 NTSC-U 0x45410047, XDK 5558 | EA | Races 13-17 → **steady 30 fps** (the game's cap). Vulkan at **1785/768/1600 MHz, scale 1.5** |
| nfsc-sw | Carbon NTSC-U 0x4541009E, XDK 5849 | Most Wanted engine | Boots and plays; fixed a 3.7 fps flip-counting bug |
| burnout3-sw | Burnout 3 NTSC-U 0x4541005B, XDK 5849, D3D8LTCG | Criterion RenderWare | **40-55 fps in races** (Vulkan), "being tuned" |

## The per-title hook list (what every port had to find)

These are always the same mechanisms. Find them in Conker's XBE by matching the library function bodies
against the reference ports (same XDK → same bytes apart from relocations).

| Hook | What it does | Burnout 3 / NFSU2 |
|---|---|---|
| D3D device pointer + **GPU fence** | D3D waits on `[device]+0x2C` submitted vs `*(+0x30)` consumed: `xbox_Nv2aMirrorFence(dev_ptr, 0x2C, 0x30)` | 0x35FB48 / 0x2F7798 |
| **BlockOnTime** / BlockOnFence | GPU waits. Wrapped so the game waits on events, not spins. NFSU2's "frame lag" fix waits on the *previous* frame's fence | 0x351770 / 0x2E8F20, 0x2E9530 |
| **vblank handler** and **PGRAPH (trap) handler** | Run at DISPATCH under a lock handshake with the executor; report retired flips. Read the retire counter *at DISPATCH* (Carbon's 3.7 fps bug counted a retire twice) | 0x356DA0, 0x357000 / 0x2F1D80, 0x2F22F0 |
| **vblank counter** | XMV/movie players pace on `[device]+0x1DE8`: `xbox_Nv2aFrameCounter(dev_ptr, 0x1DE8)` | |
| Presentation interval in the flip trap word | `(bits << 5) \| 1`; rewriting 2 → 1 in the PGRAPH wrapper uncaps 30 → 60 fps (`NFSU2_FPS_CAP=30` keeps the original) | |
| KickOff | D3D spins on the PFB write-combine bit (`+0x100410` bit 16); the polling thread clears it itself (`recomp_spin_wake`) | 0x2E8D40 |
| **DSP doorbell ack** | DirectSound writes 3 to a DSP command word and waits for it to clear; there is no DSP: `RECOMP_APU_DSP_ACK=<addr>` | 0x825F8810 (`ebx+0x810`) |
| **AC97 ready / reset** | DirectSound refuses to start until the codec is ready (`RECOMP_AC97_READY=1`); RenderWare would not start without audio | |
| memmove, `_ftol2`, D3D SSE 4x4 multiply | Native replacements (hot) | |
| XGetVideoFlags | Widescreen (and PAL-60 for us) | 0x21AEA8 (NFSU2) |
| Carbon only: DSOUND EP watchdog | Checks EP DSP memory for a 0xCCCCCC heartbeat, otherwise resets the APU ~60×/s; wrapper skips the reset | 0x394A2D |

Without the D3D wrappers NFSU1 stalled in the vblank handler's `in al,dx` before `SetDisplayMode`. Burnout's
intro movie never advanced until `in al,dx` was lifted at all and the runtime flipped port 0x80C0 bit 5 every
vblank (interlaced mode: only video field 2 starts the XMV clock).

## Bring-up: what stood between entry point and gameplay

Burnout 3's `docs/boot.md` (upstream Windows bring-up) and the CLAUDE.md files list these, in the order hit.
Expect most of them in Conker.

**Boot to title screen**
1. RAM mirror span leaked at reservation (Windows), memory layout bugs. On Horizon, see [04](04-switch-platform.md).
2. XAPI quick-reboots (`HalReturnToFirmware(2)`): the `saves/` folder did not exist, so the partition image
   could not be created.
3. Spin in D3D waiting on the GPU fence → fence mirror.
4. NULL audio device crashes the engine (DirectSoundCreate failed) → AC97 ready + APU MMIO routing.
5. Spin on the DSP command word → doorbell ack.
6. Host `memcpy` fault on APU GP/EP DSP memory → that memory is plain RAM on hardware, don't trap it.
7. XAPI takes the dashboard-update path → bad seeds had split `memcpy`; jump tables are lifted as switches now.
8. Movie stuck on first frame → vblank counter / port I/O.

**Title to menus and pad**
- P8 (palettised) textures white → `SET_TEXTURE_PALETTE`.
- USB/OHCI: physical descriptor addresses read as low RAM; XPP owns physical page 0 (contiguous allocator
  must skip it); class-driver AddDevice only reachable through a table (seeds); rumble `SET_REPORT`
  overwriting the input completion (one done queue per pass); the title starts USB late on hardware
  (25-130 s), so the OHCI thread must never give up.
- Freeze waiting for a sound to finish → APU must raise its interrupt and read voice memory correctly.
- Host-run ISRs/DPCs must restore IRQL and publish `KPCR.Irql` (fs:[0x24]).

**Menus to 3D**
- **x87 precision control** (Xbox runs at PC=24, float): a double compared with its own float copy looped
  forever in RenderWare's draw-list insert.
- Vertex program interpreter bugs (paired ILU result, `SET_VIEWPORT_SCALE/OFFSET` → c[58]/c[59]).
- **`lahf` lifted to a comment** → MSVC's `ucomiss; lahf; test ah,0x44` answered at random → NaN camera.
- **`cmpltss` unimplemented** → all frustum side planes zero → nothing visible but the sky.
- Register combiners, four texture stages, fog, alpha test, all 16 immediate-mode attributes.
- `pushad`/`popad` missing (NFSU2's music resampler lost its position → hiss).
- `cvtss2si` lifted as truncation (x86 rounds).
- Flag joins: a `jcc` reached from two predecessors with different flag producers lifted as `if (_flags)`,
  never taken. Fixed by materialising the condition per predecessor. NFSU2 still had ~1400 fallback sites
  unaudited: **grep `gen/` for `_flags` fallbacks**.

**Gameplay and saves**
- **Unaligned atomics** fault on AArch64 (x86 `lock cmpxchg` on odd addresses is legal) → spinlock fallback
  for misaligned addresses (NFSU2's XNet). Eden does not model the fault, only hardware does.
- **Guest threads racing** (data handed to a worker before filling it, allocator fill 0xAA read as a
  pointer) → the **guest lock (GIL)**: one guest thread runs lifted code at a time ([04](04-switch-platform.md)).
- Directory handles leaked per `NtQueryDirectoryFile` → Atmosphère's ams.mitm aborts the whole console.
- Saves "Unusable": kernel key exports placed at a fixed VA inside the game's `.data` got overwritten.
  Burnout moved kernel data/PRCB/TLS above the image (`xbox_RtDataPlace`). **Check Conker's image end
  against wherever the runtime puts its data.**
- Low heap VAs colliding with contiguous-arena physical addresses (APU read zeros) → tag
  (`XBOX_PHYS_LOWVA_TAG`).
- `NtSetTimerEx` was a no-op (Carbon's movie froze); `KeSetTimer` lost one-shots (NFSU1 autosave/music).
- **Unresolved stubs are silent**: a call to an address not detected as a function becomes
  `sub_X(){ g_esp += 4; }`. Carbon: a queue's get-next returned garbage, XPP never started. Use
  `stubtrace.py` / `[STUB]` lines.
- Disassembler false function starts: D3D's pushbuffer words as `mov [edi], imm` immediates looked like
  addresses; a data byte in a driver table decoded as a call into the middle of an instruction; jcc targets
  treated as gap prologues. All three are fixed in the fork's `tools/disasm/functions.py` with tests.

## Game-side fixes worth copying

- **Real-time simulation below the target frame rate.** Burnout ran N fixed 1/60 s steps per frame, but its
  race mode always answered N=1 (the Xbox held 60 fps), so 48 fps played at 0.80× speed. The override runs
  the race in the real-time mode (`B3_FRAME_LOCK=1` restores the original). NFSU2 raised a cap of game time
  per frame (3 × 1/60 s) that dropped the rest. Conker may have either pattern: `clockscan.py` (float clocks
  in guest RAM vs wall time) finds it.
- **Uncapped presentation** (flip interval rewrite, above).
- **In-game picture options**: Resolution Scale 1×-2.5×, FXAA, anisotropic 2-16×, square pixels, reflections
  on/off, added as rows in the game's own options screen and saved in `*_options.txt`. Strings come from
  unused PC/other-platform entries renamed in the string table on load.
- **Switch wording**: string table rewritten as `NtReadFile` delivers it (START → +, Xbox Live → neutral).
- **Widescreen**: NFSU2 has a real 16:9 mode (needs the EEPROM `XC_VIDEO` widescreen bit and the same bit in
  `AvSendTVEncoderOption`, or CreateDevice fails). NFSU1 did not, so it got Hor+ by scaling the projection's
  m00 by 3/4 in a wrapper. Conker: check whether it offers 16:9 in its options.
- **Present crop**: Burnout draws 448 of its 480 lines (overscan); `RECOMP_PRESENT_CROP_Y=16`.
- **Rumble**: XID output report → libnx HD rumble (low band 160 Hz, high 320 Hz); strength option.
- **Pads**: buttons by label (Switch A = Xbox A), `RECOMP_PAD_LAYOUT=position`; two USB pads on one HC; Joy-Con
  single mode. Conker's multiplayer is online/split-screen, so check the split-screen paths
  (surfaces with clip origins, `surf_find_inside`).

## What did not work in those ports

| Idea | Result |
|---|---|
| Fixed sleep instead of a wake for the flag/ack threads | every kickoff waited; game slower |
| Pinning all guest threads to one core (`RECOMP_GUEST_ONE_CORE=1`) | fixes races but Horizon's 10 ms slices cost ~90 % speed |
| Letting all higher-priority guest threads pre-empt the GIL holder | stream workers starved the main thread (GIL wait 31 %) |
| Letting only the main thread pre-empt | uneven audio (the time-critical mixer must pre-empt too) |
| Registers as plain globals (instead of TLS) | impossible: kernel dispatch releases the GIL before bridges read `g_esp` |
| Copying all 8 x87 slots at each call | slower than globals; store only the top index |
| Draw merging of identical consecutive draws | 0 % identical in a race; ~45 % differ only in constants → instancing instead |
| Eden for Vulkan or for race fps | NVK submissions never complete; Eden caps race fps ~22 |
| `switch-ffmpeg` from devkitPro | GPL; built an LGPL VP6-only FFmpeg instead |
| `svcCreateSharedMemory` for guest RAM | 0x4201 in Eden, may kill the process on hardware |
| A libnx framebuffer for a loading screen | `SDL_CreateWindow` hangs forever after one was open |
