# The title screen (`src/intro/`)

A separate program from the engine: its own source directory, its own PRG
(`build/intro.prg`), its own REU image (`build/intro.reu`), pushed to hardware
independently of `build/doom.prg`. Phase 1 shows `assets/doom-title.kla` and
loops "04 - Intermission From Doom" through the Ultimate's own PCM sampler.
The next phase — the id Software and Hondani logos, and space chain-loading
`doom.prg` and its REU image — is not built yet; `intro.asm` stops at making
space visible (border goes red) and halts.

## Why a separate program

The engine's `src/defs.asm` alone runs past 600 lines pinning down a memory
map with no free bytes left in it (`IMPLEMENTATION_PLAN.md` §14). The title
screen needs almost none of that — no MATRIX, no BSP, no map data — and
tying it to the engine's layout would be a coupling that serves nothing.
It gets its own `defs.asm`, duplicating the handful of constants (`BANK_IO`,
`TURBOREG`) it actually needs rather than importing the engine's.

## The picture

`doom-title.kla` is Koala Painter's own format: 2-byte load address ($6000),
then bitmap (8000 B), screen RAM (1000 B) and colour RAM (1000 B) back to
back *in the file*, plus a final background-colour byte — 10003 bytes total,
small enough to sit directly in the PRG image rather than going through the
REU. Only the bitmap lands at its native file address, though: Koala's own
screen-RAM position falls *inside* the bitmap's 8K VIC span (bitmap at
$6000 = bank offset $2000 takes the whole upper half of a 16K VIC bank), so
the screen segment is imported to $4000 (the bank's lower half) instead, and
colour RAM goes to scratch memory at $9000 and is copied to the VIC's fixed
$D800 at startup, 1000 bytes as four interleaved 250-byte strides (the same
shape `main.asm`'s `clearHudRows` uses).

## The music: the Ultimate's own PCM sampler, not a SID player

This is a different hardware path from `tools/sidstream.py`'s SID-register
capture (a separate, in-progress M2 feature — the engine plays a *chiptune*
by replaying register writes a `.sid` file's own player produced offline).
The title music is a real recording, and there is no `.sid` for it to
imitate. Instead it uses **Ultimate Audio**, a feature of the C64 Ultimate/
Ultimate-II hardware documented in "Ultimate Audio, Register API" v0.2
(Gideon Zweijtzer, 2012): seven independent 8/16-bit PCM channels that the
Ultimate's own FPGA DMAs straight out of REU/SDRAM, mapped into cartridge
I/O at $DF20-$DFFF. The 6502 programs four registers per channel (address,
length, sample rate divider, volume/pan) and sets the gate bit; from then on
no CPU cycles are spent on audio at all — see `src/intro/ultaudio.asm`.

**This block is real hardware only.** VICE does not emulate it: `$DF20`
upward reads back open bus, the same as any cartridge I/O the currently
selected emulation doesn't provide. So `make shot-intro` can and does verify
the picture, but the music can only be heard with `make run-intro-u64`. Two
machine settings have to be turned on first, off by default and not touched
by `tools/u64config.py` (that one is the engine's turbo profile): "Map
Ultimate Audio $DF20-DFFF" under C64 and Cartridge Settings, and "Vol Sampler
L"/"Vol Sampler R" under Audio Mixer, which must not be OFF.
`tools/introconfig.py` applies both. Those are the names a live machine
reports on firmware 1.1.0 / core 1.49; the register API PDF's §2.1 names an
older menu wording that does not exist here.

`tools/mp3topcm.py` does the offline half: ffmpeg decodes the mp3 to raw
8-bit signed **mono** PCM (default 22050 Hz — 3.6 MB for the 2:53 track),
and both title-music channels point at that one buffer at the same offset,
differing only in pan: hard left and hard right. Repeat points loop the whole
buffer for as long as the gate bit stays set, i.e. for as long as the title
screen is up.

Mono is a reliability decision, not an audio one. Getting the image into REU
RAM is a per-chunk gamble on this hardware (see "REU delivery" below), and
stereo at the same rate is 7.6 MB — 467 chunks against mono's 234. Halving the
number of rolls is worth more here than a stereo image of a title track. The
sampler's "interleave" control bit, which lets two channels share one stereo
buffer a byte apart, is consequently unused: there is one stream, played twice.

The image is padded to 4 MB, which must stay equal to the Makefile's
`-reusize 4096` for the intro because VICE rejects any `-reuimage` that is not
exactly `-reusize` (`docs/reu-format.md` §9.1). The Ultimate's own *REU Size*
is an unrelated setting and stays at 16 MB.

## REU delivery

Real hardware upload reuses `tools/u64push.py`'s existing generic REU
uploader (`src/reuload.asm` + the host-driven mailbox protocol) unchanged —
it already doesn't care what's playing the file, only that bytes land in REU
RAM. The one thing it assumed was the engine's own `D64U` block-header
format, to know how many of a padded image's bytes are worth uploading;
`image_regions` falls back to trimming trailing zero padding for
images with no such header — a heuristic that only ever worked while the PCM
was unsigned (silence at $80, so a run of zero bytes could only be pad).
`mp3topcm.py` moved to *signed* PCM (2026-08-15, matching the sampler's
actual two's-complement format), where silence legitimately reads $00 too;
this fallback path is unused by the merged launcher's `game.reu` (D64U-framed,
never falls through to it) and should not be relied on again for a raw image
without revisiting the trim.

**The intro does not use that uploader.** `intro.reu` is loaded once from the
Ultimate's own menu — `REU Preload Image` → `/Usb0/intro.reu`, then reset —
and stays in REU RAM across every reset after that, so `run-intro-u64` pushes
only the 2.4 KB PRG and starts playing immediately. Reload it by hand when the
mp3 changes; nothing else touches it.

That is worth stating plainly because this project spent a long time believing
the opposite. `docs/reu-format.md` §9.2 records the sequence: preload was
tested through the REST API, found inert, and `src/reuload.asm` was written to
work around it — then the same settings applied *from the menu* turned out to
work fine. The broken thing is arming preload over HTTP, not preload. The
uploader still earns its place for `assets.reu`, which is rebuilt on every map
or packer change and where a manual step per build would be worse than a
three-chunk upload. For 3.6 MB that changes when the soundtrack does, the menu
wins outright.

Mono survives that reversal on its own merits — half the image, half the load
time, and no audible difference on a title screen — though the original
argument for it (halving a 467-chunk network upload that no longer happens) is
now moot.
