#!/usr/bin/env python3
"""Turn a `.sid` file into a stream of SID register frames.

    python3 tools/sidstream.py assets/DooM_Medley.sid --seconds 240
    python3 tools/sidstream.py assets/DooM_Medley.sid -o build/music.bin

The engine cannot run a `.sid` file. A `.sid` is player code at fixed absolute
addresses -- DooM_Medley wants $0FF6-$3E6A, doom-e1m1 wants $1000-$1D60 -- and
both land inside MATRIX, the chunky framebuffer, with the engine's free RAM
totalling ~360 bytes in four holes (IMPLEMENTATION_PLAN.md §14, src/defs.asm).

But the SID chip only ever sees register writes. So the player runs *here*, in
`tools/cpu6502.py`, once per build: init is called, then play is called at the
tune's own rate, and the 25 registers $D400-$D418 are snapshotted after each
call. The C64 replays the snapshots out of the REU. Chip-identical output,
zero player code resident, and looping is exact -- it is a pointer rewind.

The stream is emitted with a 16-byte header; `docs/reu-format.md` §4.6 is the
contract and `src/music.asm` reads it.

Stdlib only.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

from cpu6502 import Cpu6502

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------
PAL_CLOCK = 985248              # C64 PAL system / CIA clock, Hz
PAL_REFRESH = 50.1245           # PAL vertical blank, Hz
SID_BASE = 0xD400
FRAME_SIZE = 25                 # $D400-$D418: three voices + filter + volume
SENTINEL = 0xFFF0               # where init/play "return" to; see run_until

STREAM_MAGIC = b"MU"
STREAM_VERSION = 1
HEADER_SIZE = 16
RECORD_SLACK = 4                # DMA window rounding, see build_stream

ROM_DIRS = ("/usr/share/vice/C64", "/usr/local/share/vice/C64",
            os.path.expanduser("~/.local/share/vice/C64"))


class SidError(Exception):
    pass


# ---------------------------------------------------------------------------
# the .sid container
# ---------------------------------------------------------------------------
class SidFile:
    """PSID/RSID header fields plus the tune image."""

    def __init__(self, path):
        with open(path, "rb") as fh:
            raw = fh.read()
        if len(raw) < 0x76 or raw[:4] not in (b"PSID", b"RSID"):
            raise SidError(f"{path}: not a PSID/RSID file")

        self.path = path
        self.kind = raw[:4].decode()
        (self.version, self.data_offset, load, self.init, self.play,
         self.songs, self.start_song) = struct.unpack(">HHHHHHH", raw[4:18])
        self.speed = struct.unpack(">I", raw[18:22])[0]
        self.name = raw[0x16:0x36].split(b"\0")[0].decode("latin-1")
        self.author = raw[0x36:0x56].split(b"\0")[0].decode("latin-1")
        self.released = raw[0x56:0x76].split(b"\0")[0].decode("latin-1")
        self.flags = struct.unpack(">H", raw[0x76:0x78])[0] if self.version >= 2 else 0

        body = raw[self.data_offset:]
        if load == 0:
            if len(body) < 2:
                raise SidError(f"{path}: truncated data")
            self.load = body[0] | (body[1] << 8)
            self.data = body[2:]
        else:
            self.load = load
            self.data = body
        self.end = self.load + len(self.data) - 1
        if self.init == 0:
            self.init = self.load

    @property
    def sid_model(self):
        return ("unknown", "6581", "8580", "6581+8580")[(self.flags >> 4) & 3]

    @property
    def clock(self):
        return ("unknown", "PAL", "NTSC", "PAL+NTSC")[(self.flags >> 2) & 3]


# ---------------------------------------------------------------------------
# just enough C64 for a player to run in
# ---------------------------------------------------------------------------
class C64Bus:
    """RAM + the three ROMs + the I/O registers a player touches.

    Banking follows $01's LORAM/HIRAM/CHAREN exactly, because a PSID runs with
    $01 = $37 and some players call into the KERNAL. The ROMs come from VICE's
    own data directory, which `tools/setup-dev-env.sh` already installs.

    Everything written to $D400-$D41C lands in `self.sid`, which is the entire
    point of this file. Reads from the I/O space return values chosen so a
    player cannot hang waiting on hardware that is not being emulated.
    """

    def __init__(self, roms=True):
        self.ram = bytearray(0x10000)
        self.sid = bytearray(0x20)
        self.cpu = None                  # set by the driver, for cycle-based reads
        self.kernal = self.basic = self.chargen = None
        if roms:
            self._load_roms()
        # $01 defaults to $37 as after reset: BASIC + KERNAL + I/O
        self.ram[0x0000] = 0x2F
        self.ram[0x0001] = 0x37
        self._rng = 0xACE1

    def _load_roms(self):
        want = {"kernal": ("kernal-901227-03.bin", 8192),
                "basic": ("basic-901226-01.bin", 8192),
                "chargen": ("chargen-901225-01.bin", 4096)}
        for attr, (fname, size) in want.items():
            for d in ROM_DIRS:
                p = os.path.join(d, fname)
                if os.path.isfile(p) and os.path.getsize(p) == size:
                    with open(p, "rb") as fh:
                        setattr(self, attr, fh.read())
                    break
        # Absent ROMs are not fatal: most players never leave their own code.
        # They become RAM, and a player that does call the KERNAL will fail
        # loudly (a JAM or a runaway) rather than silently producing silence.

    # -- banking ---------------------------------------------------------
    def _port(self):
        p = self.ram[0x0001] | (~self.ram[0x0000] & 0xFF)
        return p & 7

    def read(self, addr):
        if 0xA000 <= addr <= 0xBFFF:
            p = self._port()
            if (p & 3) == 3 and self.basic:
                return self.basic[addr - 0xA000]
        elif 0xE000 <= addr <= 0xFFFF:
            if (self._port() & 2) and self.kernal:
                return self.kernal[addr - 0xE000]
        elif 0xD000 <= addr <= 0xDFFF:
            p = self._port()
            if (p & 3) == 0:
                return self.ram[addr]
            if p & 4:
                return self._io_read(addr)
            if self.chargen:
                return self.chargen[addr - 0xD000]
        return self.ram[addr]

    def write(self, addr, val):
        if 0xD000 <= addr <= 0xDFFF:
            p = self._port()
            if (p & 3) != 0 and (p & 4):
                self._io_write(addr, val)
                return
        self.ram[addr] = val

    # -- I/O -------------------------------------------------------------
    def _io_write(self, addr, val):
        if 0xD400 <= addr <= 0xD7FF:
            self.sid[(addr - SID_BASE) & 0x1F] = val
        # VIC, CIAs and colour RAM: writes are recorded in RAM so a player can
        # read back what it wrote (CIA timer latches, mostly).
        self.ram[addr] = val

    def _io_read(self, addr):
        reg = addr & 0xFF
        if 0xD400 <= addr <= 0xD7FF:
            reg &= 0x1F
            if reg == 0x1B:              # OSC3 -- players use it as a random source
                self._rng = ((self._rng << 1) | (((self._rng >> 15) ^
                             (self._rng >> 13) ^ (self._rng >> 12) ^
                             (self._rng >> 10)) & 1)) & 0xFFFF
                return self._rng & 0xFF
            if reg == 0x1C:              # ENV3
                return 0
            return 0
        if 0xD000 <= addr <= 0xD3FF:
            cyc = self.cpu.cycles if self.cpu else 0
            if reg == 0x12:              # raster line
                return (cyc // 63) % 312 & 0xFF
            if reg == 0x11:
                return 0x1B | (0x80 if ((cyc // 63) % 312) > 255 else 0)
            if reg == 0x19:
                return 0x71              # no pending VIC interrupt
            return 0
        if 0xDC00 <= addr <= 0xDDFF:     # CIA1/CIA2
            cyc = self.cpu.cycles if self.cpu else 0
            if reg in (0x00, 0x01):
                return 0xFF              # no key, no joystick
            if reg in (0x04, 0x05, 0x06, 0x07):
                # A free-running countdown from the latch, so a player that
                # polls a timer sees it move instead of hanging.
                latch = (self.ram[(addr & 0xFF00) | 0x04] |
                         (self.ram[(addr & 0xFF00) | 0x05] << 8)) or 0xFFFF
                t = latch - (cyc % (latch + 1))
                return (t if reg in (0x04, 0x06) else t >> 8) & 0xFF
            if reg == 0x0D:
                return 0x81              # timer A underflow pending
            return self.ram[addr]
        return self.ram[addr]


# ---------------------------------------------------------------------------
# running the tune
# ---------------------------------------------------------------------------
def tick_rate(sid, bus, song_index=0):
    """The rate the tune wants `play` called at, in Hz.

    Two sources, in the order the PSID spec gives them: the speed bit for this
    song selects vertical blank (0) or CIA timer A (1), and in the CIA case the
    rate is whatever the tune's own init wrote into $DC04/$DC05. DooM_Medley
    writes $2663 -- 100.2 Hz, not 50, which is why this is read rather than
    assumed.
    """
    bit = (sid.speed >> min(song_index, 31)) & 1
    if bit == 0:
        return PAL_REFRESH, None
    latch = bus.ram[0xDC04] | (bus.ram[0xDC05] << 8)
    if latch < 100:                      # nothing plausible was written
        return PAL_REFRESH, None
    return PAL_CLOCK / (latch + 1), latch


def dump(sid, seconds, song=None, quiet=False):
    """Run the tune and return (frames, rate_hz, cia_latch, stats)."""
    bus = C64Bus()
    cpu = Cpu6502(bus)
    bus.cpu = cpu
    bus.ram[sid.load:sid.load + len(sid.data)] = sid.data

    song = sid.start_song if song is None else song
    song_index = max(0, min(sid.songs - 1, song - 1))

    def call(addr, acc=0):
        cpu.a, cpu.x, cpu.y = acc, 0, 0
        cpu.sp = 0xFD
        cpu.p = 0x24
        cpu.pc = addr
        cpu.push((SENTINEL - 1) >> 8)
        cpu.push((SENTINEL - 1) & 0xFF)
        return cpu.run_until(SENTINEL)

    init_cycles = call(sid.init, song_index)
    rate, latch = tick_rate(sid, bus, song_index)

    ticks = int(seconds * rate)
    frames = bytearray()
    worst = 0
    total = 0
    for _ in range(ticks):
        spent = call(sid.play)
        worst = max(worst, spent)
        total += spent
        frames += bus.sid[:FRAME_SIZE]

    stats = {
        "init_cycles": init_cycles,
        "play_worst": worst,
        "play_mean": total / ticks if ticks else 0,
        "ticks": ticks,
    }
    return frames, rate, latch, stats


# ---------------------------------------------------------------------------
# loop detection
# ---------------------------------------------------------------------------
def find_loop(frames, rate, min_seconds=5.0, probe=2000):
    """Find (loop_start, end) such that frame[i] == frame[i + period] forever.

    A tune that repeats does so because the player's state is periodic, and
    then the register stream is periodic too. Detecting it exactly is what
    lets the C64 loop by rewinding a pointer: the machine state before tick
    `loop_start` and before `loop_start + period` are the same by
    construction, so the seam is inaudible and no second init is needed.

    Method: take the last `probe` frames as a fingerprint and find where else
    that exact run occurs. Any true period maps the fingerprint onto itself,
    so this reduces an O(n²) search to one scan plus a verification. Then walk
    backwards for the earliest tick from which the period holds -- everything
    before it is the tune's intro and is played once.

    Returns tick indices; `loop_start == total` means nothing repeated inside
    the dump, and the stream should be restarted from the top instead.
    """
    n = len(frames) // FRAME_SIZE
    if n < 2 * probe:
        return n, n
    fr = [bytes(frames[i * FRAME_SIZE:(i + 1) * FRAME_SIZE]) for i in range(n)]
    tail = fr[n - probe:]
    min_period = max(1, int(min_seconds * rate))

    # Candidate periods are the places the *last* frame recurs -- one cheap
    # scan. Each candidate is then checked against the whole fingerprint, so a
    # coincidental single-frame match costs one comparison and not a walk.
    last = fr[-1]
    for period in sorted(n - 1 - i for i in range(n - probe) if fr[i] == last):
        if period < min_period:
            continue
        if fr[n - probe - period:n - period] == tail:
            break
    else:
        return n, n

    start = 0
    for i in range(n - period):
        if fr[i] != fr[i + period]:
            start = i + 1
    return start, start + period


# ---------------------------------------------------------------------------
# the stream file
# ---------------------------------------------------------------------------
def encode(frames, total_ticks):
    """Delta-encode the frames. Returns (blob, tick_offsets, max_record).

    One record per tick: a count byte, then that many (register, value) pairs
    for the registers that changed since the previous tick. The medley changes
    4.1 of 25 registers per tick, so this is 9.1 bytes where a raw snapshot is
    25 -- 405 KB against 1.11 MB for the whole 7:22. That ratio is not about
    REU space, which is 16 MB and free; it is about upload time, because
    `u64push.py` re-sends and verifies the used region on every hardware run.

    Only changed registers reach the SID, which is also what a real player
    does -- a register the tune never touches is never written.
    """
    out = bytearray()
    offsets = []
    prev = bytearray(FRAME_SIZE)
    longest = 0
    for t in range(total_ticks):
        cur = frames[t * FRAME_SIZE:(t + 1) * FRAME_SIZE]
        offsets.append(len(out))
        head = len(out)
        out.append(0)
        count = 0
        for reg in range(FRAME_SIZE):
            if cur[reg] != prev[reg]:
                out.append(reg)
                out.append(cur[reg])
                count += 1
        out[head] = count
        longest = max(longest, 1 + 2 * count)
        prev[:] = cur
    offsets.append(len(out))
    return bytes(out), offsets, longest


def build_stream(frames, rate, latch, loop_start, total_ticks):
    """Header + delta records, exactly as `src/music.asm` reads it.

    `docs/reu-format.md` §4.6 is the contract; change it there first.
    """
    blob, offsets, longest = encode(frames, total_ticks)
    if latch is None:
        latch = int(round(PAL_CLOCK / rate)) - 1

    # The player DMAs a fixed window per tick and only then learns how long
    # the record was, so the window must cover the longest record and the
    # stream must be padded by that much -- the last record's read runs off
    # the end by design.
    window = longest + RECORD_SLACK

    hdr = bytearray(HEADER_SIZE)
    hdr[0:2] = STREAM_MAGIC
    hdr[2] = STREAM_VERSION
    hdr[3] = window
    hdr[4:6] = struct.pack("<H", latch & 0xFFFF)
    hdr[6:9] = struct.pack("<I", HEADER_SIZE + offsets[loop_start])[:3]
    hdr[9:12] = struct.pack("<I", HEADER_SIZE + offsets[total_ticks])[:3]
    hdr[12:15] = struct.pack("<I", total_ticks)[:3]
    return bytes(hdr) + blob + bytes(window)


def stream_from_sid(path, seconds=480.0, song=None, quiet=False):
    """The one call `wad2reu.py` makes. Returns (stream_bytes, info dict)."""
    sid = SidFile(path)
    frames, rate, latch, stats = dump(sid, seconds, song, quiet)
    loop_start, total = find_loop(frames, rate)
    stream = build_stream(frames, rate, latch, loop_start, total)
    info = {
        "name": sid.name, "author": sid.author, "released": sid.released,
        "load": sid.load, "end": sid.end, "init": sid.init, "play": sid.play,
        "model": sid.sid_model, "clock": sid.clock,
        "rate": rate, "latch": latch,
        "ticks": total, "loop_start": loop_start,
        "seconds": total / rate, "looped": loop_start < total,
        "bytes": len(stream),
        **stats,
    }
    return stream, info


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sid")
    ap.add_argument("-o", "--out", help="write the stream here")
    ap.add_argument("--seconds", type=float, default=480.0,
                    help="how much of the tune to run before giving up on "
                         "finding its loop (default 480; DooM_Medley repeats "
                         "at 442 s)")
    ap.add_argument("--song", type=int, default=None)
    ap.add_argument("--no-loop", action="store_true",
                    help="keep the whole dump; do not trim to the loop point")
    args = ap.parse_args(argv)

    try:
        sid = SidFile(args.sid)
    except SidError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(f"{args.sid}")
    print(f"  {sid.name} -- {sid.author} ({sid.released})")
    print(f"  {sid.kind} v{sid.version}  ${sid.load:04X}-${sid.end:04X} "
          f"({len(sid.data)} B)  init ${sid.init:04X}  play ${sid.play:04X}")
    print(f"  {sid.clock}  {sid.sid_model}  songs {sid.songs} "
          f"(start {sid.start_song})")

    frames, rate, latch, stats = dump(sid, args.seconds, args.song)
    n = len(frames) // FRAME_SIZE
    print(f"  rate {rate:.2f} Hz" + (f" (CIA latch ${latch:04X})" if latch else
                                     " (vertical blank)"))
    print(f"  init {stats['init_cycles']} cycles; play mean "
          f"{stats['play_mean']:.0f}, worst {stats['play_worst']} cycles")

    if args.no_loop:
        loop_start, total = n, n
    else:
        loop_start, total = find_loop(frames, rate)
    if loop_start < total:
        print(f"  loop: ticks {loop_start}..{total} "
              f"({loop_start / rate:.1f} s intro, "
              f"{(total - loop_start) / rate:.1f} s loop)")
    else:
        print(f"  loop: none found in {args.seconds:.0f} s -- "
              f"the stream plays through and restarts")

    stream = build_stream(frames, rate, latch, loop_start, total)
    raw = total * FRAME_SIZE
    secs = total / rate
    print(f"  {total} ticks = {secs / 60:.0f}:{secs % 60:04.1f}, "
          f"{len(stream)} B ({len(stream) / secs / 1024:.2f} KB/s), "
          f"{raw / len(stream):.2f}x smaller than raw snapshots")
    print(f"  registers changing per tick: mean "
          f"{_delta_stats(frames, total):.1f} of {FRAME_SIZE}, "
          f"DMA window {stream[3]} B")

    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "wb") as fh:
            fh.write(stream)
        print(f"  -> {args.out}")
    return 0


def _delta_stats(frames, total):
    """Mean registers changed per tick -- the number that says whether a delta
    encoding would be worth its decoder. Reported, not acted on."""
    prev = bytes(FRAME_SIZE)
    changed = 0
    for i in range(total):
        cur = bytes(frames[i * FRAME_SIZE:(i + 1) * FRAME_SIZE])
        changed += sum(1 for a, b in zip(prev, cur) if a != b)
        prev = cur
    return changed / total if total else 0


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    raise SystemExit(main())
