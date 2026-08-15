#!/usr/bin/env python3
"""Merge assets.reu + doom.prg + the intro's PCM into one game.reu.

    python3 tools/build_launcher_reu.py \
        --assets build/assets.reu --game build/doom.prg \
        --pcm build/intro.reu --pcm-asm build/intro-audio.asm \
        -o build/game.reu --asm build/game-layout.asm

This is deliberately a thin append step, not a rewrite of wad2reu.py's
D64U format. assets.reu's own header/block table (docs/reu-format.md §2-4)
is frozen -- mapload.asm's resident-block loader depends on it byte for
byte -- so this tool never touches those bytes. It just tacks two more
payloads onto the end of the fixed-size assets.reu image, page-aligned,
and writes their offsets out as .asm constants the launcher (src/intro/
intro.asm) imports directly. Nothing in mapload.asm or wad2reu.py's own
descriptor table ever learns these payloads exist; mapLoad stops reading
descriptors long before reaching this appended region.

GAMECODE is build/doom.prg with its 2-byte load address and BasicUpstart2
stub stripped, leaving exactly the bytes that would land at $0810 on a
normal LOAD -- the launcher DMAs them there itself and jumps in, so the
stub (whose only job is to make BASIC's RUN command SYS into the game) is
dead weight here. The skip length is computed from the PRG's own load-
address header, not hardcoded, so a future relocation of $0810 in
src/main.asm is caught (a mismatch raises rather than silently truncating
the wrong number of bytes) instead of miscompiling silently.

INTROMUSIC is the same mono PCM tools/mp3topcm.py already decodes for the
standalone build/intro.reu (whose first AUDIO_LEN bytes, from build/
intro-audio.asm, are the real samples -- the rest is that file's own
padding to VICE's -reusize). Slicing it out avoids re-running ffmpeg here.
"""
from __future__ import annotations

import argparse
import os
import re

BLOCK_ALIGN = 256

# The engine's own code always starts here (src/main.asm's "code" segment) --
# duplicated as a constant rather than parsed out of main.asm because it is
# the one number this tool actually needs to agree with, and a mismatch
# should fail loudly (see the load-address assertion below), not silently.
GAME_CODE_ADDR = 0x0810

# 8 MB: 512 KB assets.reu + ~50 KB of game code + ~3.6-4 MB of mono PCM,
# rounded up to the next size VICE's -reusize accepts (docs/reu-format.md
# §9.1: -reusize must exactly match -reuimage's byte length). Same
# reasoning as mp3topcm.py's own REU_SIZE, just bigger to make room for
# assets.reu and the code alongside the PCM in the same file.
REU_TOTAL_SIZE = 8 * 1024 * 1024


def align(n: int) -> int:
    return (n + BLOCK_ALIGN - 1) // BLOCK_ALIGN * BLOCK_ALIGN


def strip_prg_stub(prg: bytes) -> bytes:
    """doom.prg -> raw code image starting at GAME_CODE_ADDR.

    A PRG's first 2 bytes are its load address (little-endian); everything
    from there to GAME_CODE_ADDR is BasicUpstart2's stub (a fake BASIC line
    that SYSes into `main`), which the launcher has no use for -- it DMAs
    straight to $0810 and jumps there itself.
    """
    if len(prg) < 2:
        raise ValueError("doom.prg is too short to have a load address")
    load_addr = prg[0] | (prg[1] << 8)
    skip = (GAME_CODE_ADDR - load_addr) + 2
    if skip < 2 or skip > len(prg):
        raise ValueError(
            f"doom.prg loads at ${load_addr:04x}, so the code image would "
            f"start {skip - 2} bytes into a {len(prg)}-byte file -- that's "
            "not a BasicUpstart2 stub in front of $0810 any more. Update "
            "GAME_CODE_ADDR here if src/main.asm's code segment moved.")
    return prg[skip:]


def load_audio_len(asm_path: str) -> int:
    """Pull AUDIO_LEN out of the generated build/intro-audio.asm.

    Reading the generated file rather than re-decoding the mp3 keeps this
    tool from needing ffmpeg at all -- tools/mp3topcm.py already did that
    work; this just borrows its answer.
    """
    text = open(asm_path).read()
    m = re.search(r"AUDIO_LEN\s*=\s*(\d+)", text)
    if not m:
        raise ValueError(f"{asm_path}: no AUDIO_LEN constant found")
    return int(m.group(1))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--assets", required=True, help="build/assets.reu")
    ap.add_argument("--game", required=True, help="build/doom.prg")
    ap.add_argument("--pcm", required=True,
                     help="build/intro.reu -- only its first AUDIO_LEN bytes are used")
    ap.add_argument("--pcm-asm", required=True,
                     help="build/intro-audio.asm -- provides AUDIO_LEN")
    ap.add_argument("-o", "--out", required=True, help="write build/game.reu here")
    ap.add_argument("--asm", required=True,
                     help="write the generated layout constants here")
    args = ap.parse_args(argv)

    assets = open(args.assets, "rb").read()
    prg = open(args.game, "rb").read()
    pcm_file = open(args.pcm, "rb").read()
    audio_len = load_audio_len(args.pcm_asm)
    if audio_len > len(pcm_file):
        raise ValueError(
            f"{args.pcm_asm} claims AUDIO_LEN={audio_len} but {args.pcm} is "
            f"only {len(pcm_file)} B -- rebuild both together (make intro)")
    pcm = pcm_file[:audio_len]

    gamecode = strip_prg_stub(prg)

    # assets.reu is a fixed size (REU_IMAGE_SIZE in wad2reu.py); this is
    # just a sanity check, not a real fix-up.
    gamecode_ofs = len(assets)
    if gamecode_ofs % BLOCK_ALIGN != 0:
        raise ValueError(
            f"{args.assets} is {gamecode_ofs} B, not page-aligned -- "
            "wad2reu.py's REU_IMAGE_SIZE must be a multiple of "
            f"{BLOCK_ALIGN}")
    music_ofs = align(gamecode_ofs + len(gamecode))

    end = music_ofs + len(pcm)
    if end > REU_TOTAL_SIZE:
        raise ValueError(
            f"merged image needs {end} B, past REU_TOTAL_SIZE "
            f"({REU_TOTAL_SIZE} B) -- raise it here and the Makefile's "
            "-reusize together")

    img = bytearray(REU_TOTAL_SIZE)
    img[0:len(assets)] = assets
    img[gamecode_ofs:gamecode_ofs + len(gamecode)] = gamecode
    img[music_ofs:music_ofs + len(pcm)] = pcm

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "wb") as fh:
        fh.write(img)

    os.makedirs(os.path.dirname(args.asm) or ".", exist_ok=True)
    with open(args.asm, "w") as fh:
        fh.write(
            "// Generated by tools/build_launcher_reu.py -- do not edit.\n"
            "//\n"
            "// GAMECODE and INTROMUSIC are appended after assets.reu's own\n"
            "// (unmodified, fixed-size) D64U image inside build/game.reu --\n"
            "// see that script's docstring and docs/reu-format.md's \"outer\n"
            "// envelope\" appendix. Not part of the D64U block table.\n"
            "//\n"
            "// _REUOFS is the full 24-bit REU byte offset, for ultaudio.asm's\n"
            "// uaLoad (which splits it into 3 bytes itself). _REUADDR/_BANK\n"
            "// is the same offset pre-split, matching reu.asm's reuSet(ram,\n"
            "// reu, bank, len) -- reu.asm's REU_REUADDR register is only 16\n"
            "// bits wide, same convention as REU_PROBE_ADDR/BANK in defs.asm.\n"
            f".const GAMECODE_REUOFS   = {gamecode_ofs}\n"
            f".const GAMECODE_REUADDR  = {gamecode_ofs & 0xffff}\n"
            f".const GAMECODE_BANK     = {(gamecode_ofs >> 16) & 0xff}\n"
            f".const GAMECODE_LEN      = {len(gamecode)}\n"
            f".const INTROMUSIC_REUOFS = {music_ofs}\n"
            f".const INTROMUSIC_REUADDR = {music_ofs & 0xffff}\n"
            f".const INTROMUSIC_BANK   = {(music_ofs >> 16) & 0xff}\n"
            f".const INTROMUSIC_LEN    = {len(pcm)}\n"
        )

    print(f"{args.out}: {end} B used of {REU_TOTAL_SIZE} B")
    print(f"  GAMECODE   @ ${gamecode_ofs:06x}  {len(gamecode)} B "
          f"(from {args.game}, stub-stripped)")
    print(f"  INTROMUSIC @ ${music_ofs:06x}  {len(pcm)} B (from {args.pcm})")
    print(f"  -> {args.asm}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
