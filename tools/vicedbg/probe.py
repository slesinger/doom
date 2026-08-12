#!/usr/bin/env python3
"""Probes for a running x64sc, over the VICE binary monitor.

    # terminal 1
    xvfb-run -a x64sc -warp +sound +confirmonexit -autostartprgmode 1 \
        -binarymonitor -binarymonitoraddress ip4://127.0.0.1:6510 \
        -autostart build/doom.prg

    # terminal 2
    python3 tools/vicedbg/probe.py dump build/doom.prg   # memory occupancy + PC
    python3 tools/vicedbg/probe.py diff build/doom.prg   # live RAM vs PRG image

`diff` is the regression test for the spanFill out-of-bounds bug: it reports any
byte that differs from the loaded image outside the regions the engine is allowed
to write at runtime. A clean run prints zero unexpected differences.
"""
import re
import struct
import sys
import time
from collections import Counter

from vicemon import Mon

# regions the engine legitimately writes while running
ALLOWED = [
    (0x0200, 0x02FF, "colTop"),
    (0x0300, 0x03FF, "colBot"),
    (0x0400, 0x07FF, "COLBUF"),
    # $0E20-$0E5F is nodeSphere's code now that MAPHDR stages inside MATRIX, so
    # these are two regions rather than one span: a stray write into the gap is
    # a write into code, and this is the only thing that would report it.
    # The nine REU transfer registers the music interrupt saves and puts back
    # around its own DMA, in UDIV8's tail (MUSREU in src/defs.asm).
    (0x0D33, 0x0D3B, "MUSREU"),
    (0x0E00, 0x0E1F, "MAPINFO"),
    (0x0E60, 0x0E67, "SSECHDR + bounding sphere"),
    (0x0F00, 0x0F3F, "BSP stack"),
    (0x0F40, 0x0F41, "frameCnt"),
    (0x0F42, 0x0F50, "reuScratch/reuOK/mapOK/mapErr/mapSum"),
    # musBuf (the per-tick DMA window), the three stream pointers and the
    # player's status bytes -- MUSDATA in src/defs.asm. The handler itself is
    # at $FF40, outside the PRG image, so this diff never sees it.
    (0x0FC4, 0x0FF7, "music player state"),
    (0x1000, 0x7DFF, "MATRIX"),
    (0x8000, 0x83FF, "SCREEN0"),
    (0xA000, 0xBF3F, "BITMAP0"),
    (0xC000, 0xC3FF, "SCREEN1"),
    (0x9740, 0x97BF, "SEGBUF"),
    (0x9900, 0x9AFF, "converter code (self-mod)"),
    (0x9B60, 0x9D5F, "math code (self-mod mul8)"),
]

# texCol's tile pointer (the operand of txColBase, src/render/tex.asm), added
# to ALLOWED at import from the symbol file rather than written here as an
# address. Written once per textured seg by texFetch, which is what replaced
# Stage A's per-seg tile DMA when the tiles went resident at 16x16.
#
# Two bytes and not the whole TX_COL block: they are the only bytes in it that
# may legitimately change, and anything else moving there is code being
# overwritten -- which is precisely what this diff exists to catch. Derived
# from the symbol because TX_COL's address moves whenever the bin-packing does,
# and a stale constant here would silently stop covering the block.
def _selfmod_from_syms():
    try:
        sym = open(SYMFILE).read()
    except OSError:
        return
    m = re.search(r"^\.label txColBase=\$([0-9a-fA-F]+)$", sym, re.M)
    if m:
        a = int(m.group(1), 16) + 1             # skip the opcode: the operand
        ALLOWED.append((a, a + 1, "texCol tile pointer (self-mod)"))


def region(addr):
    for lo, hi, name in ALLOWED:
        if lo <= addr <= hi:
            return name
    return "*** UNEXPECTED ***"


def load_prg(path):
    raw = open(path, "rb").read()
    return raw[0] | (raw[1] << 8), raw[2:]


def reg_names(m):
    _, _, b = m.cmd(0x83, b"\x00")
    n = struct.unpack("<H", b[:2])[0]
    off, names = 2, {}
    for _ in range(n):
        size = b[off]
        names[b[off + 1]] = b[off + 4:off + 4 + b[off + 3]].decode()
        off += size + 1
    return names


def cmd_dump(m, prg_path, settle):
    names = reg_names(m)
    m.exit_mon()
    time.sleep(settle)

    pcs = []
    for _ in range(8):
        pcs.append({names[k]: v for k, v in m.regs().items()}.get("PC"))
        m.exit_mon()
        time.sleep(0.2)
    print("PC samples:", " ".join(f"${p:04x}" for p in pcs))
    if len(set(pcs)) == 1:
        print("  !! PC is frozen -- the CPU is wedged or JAMmed")

    ranges = {
        "matrix":  (0x1000, 0x7DFF),
        "screen0": (0x8000, 0x83FF),
        "screen1": (0xC000, 0xC3FF),
        "bitmap0": (0xA000, 0xBF3F),
        "bitmap1": (0xE000, 0xFF3F),
        "colbuf":  (0x0400, 0x077F),
        "clip":    (0x0200, 0x03FF),
    }
    for name, (a, b) in ranges.items():
        # bank 1 = ram, so reads under BASIC/KERNAL ROM see the RAM beneath
        data = m.mem_get(a, b, bank=1)
        nz = sum(1 for x in data if x)
        print(f"{name:8s} ${a:04x}-${b:04x} {len(data):6d}B "
              f"nonzero={nz:6d} ({100.0 * nz / max(1, len(data)):5.1f}%)")

    zp = m.mem_get(0x0000, 0x00FF, bank=1)
    print(f"camX={zp[0x50] | zp[0x51] << 8} camY={zp[0x52] | zp[0x53] << 8} "
          f"camA={zp[0x56]} camSec={zp[0x57]} backBuf={zp[0x4A]} stackN={zp[0x5C]}")
    if zp[0x4A] == 0:
        print("  !! backBuf still 0 -- flip() has never completed a frame")


REU_OK = 0x0F46          # `.const reuOK` in src/defs.asm


def check_reu(m):
    """Assert that the emulator actually gave the engine an REU.

    reuProbe round-trips a signature through REU address 0 at boot and
    leaves the verdict here. This is checked rather than assumed because
    the failure is completely silent from inside the C64: with no REU
    attached the $DFxx stores go nowhere, reads return $00, and every
    transfer is a no-op that reports success.

    It is an easy thing to lose by accident -- it was lost for the whole
    life of the project by `-default` sitting after `-reu` on VICE's
    command line, which resets the REU enable back off.
    """
    ok = m.mem_get(REU_OK, REU_OK, bank=1)[0]
    m.exit_mon()
    if ok == 1:
        print("\nREU: present and round-tripping")
        return 0
    print("\nREU: *** ABSENT *** -- reuProbe found no REU.\n"
          "  The engine ran, but any DMA it issues is a silent no-op.\n"
          "  Check that -reu comes AFTER -default on VICE's command line.")
    return 1


MAP_OK = 0x0F47          # `.const mapOK`  in src/defs.asm
MAP_ERR = 0x0F48         # `.const mapErr` in src/defs.asm
MAP_SUM = 0x0F49         # `.const mapSum` in src/defs.asm, 4 x 16-bit
REU_IMAGE = "build/assets.reu"

# The three wall-texturing blocks that run below $0801 -- see check_texcode.
# The .pseudopc source addresses come out of the symbol file; only the run
# addresses are named here, and they are TX_SEED/TX_FETCH/TX_VSET in defs.asm.
SYMFILE = "src/build/main.sym"
_selfmod_from_syms()            # ALLOWED's one symbol-derived entry, above
TEXBLOCKS = [("Seed", 0x0770), ("Fetch", 0x03A0), ("VSet", 0x02B0)]
# `.const LINECODE/LINECODE2/LINECODE3`, and the labels lines.asm gives their
# .pseudopc images. All three are under the I/O space.
LINEBLOCKS = [("Think", 0xDBD0), ("Step", 0xDE40), ("Act", 0xDF00)]
# `.const JUMPCODE2` -- jumpStep, above the music IRQ handler and below the
# CPU vectors. Copied up by lineBoot; see the jump comment in src/input.asm.
JUMPBLOCKS = [("Step", 0xFFE4)]
LINESPEC = 0xDB40        # `.const LINESPEC` -- the special-line table
MAXLINES = 16            # `.const MAXLINES`
BLK_LINEDEFS = 7         # docs/reu-format.md §3
LK_NAME = {1: "door", 2: "lift", 3: "floor", 4: "exit"}

# mapErr values, from src/defs.asm.
MERR = {0: "none", 1: "no REU", 2: "bad magic", 3: "wrong version",
        4: "bad block count", 5: "unknown block id", 6: "load address mismatch",
        7: "block too long", 8: "MAPINFO counts out of range",
        9: "spawn descent disagrees with the image"}


def check_map(m):
    """Assert that the resident map blocks reached RAM, byte for byte.

    mapOK alone only says the loader liked the header. This goes further and
    compares live RAM against build/assets.reu's own resident blocks, which is
    the end-to-end proof of the whole delivery path: image -> REU -> DMA ->
    staging in MATRIX -> block copy under the I/O space. Until this passes,
    "the bytes are in REU RAM" is an assumption (IMPLEMENTATION_PLAN.md §9,
    Phase 1.2's caveat).

    The blocks under $d000 are read with bank=1 ("ram"), which sees the RAM
    beneath the I/O registers -- the same memory the engine sees with
    $01 = $34.
    """
    ok = m.mem_get(MAP_OK, MAP_OK, bank=1)[0]
    err = m.mem_get(MAP_ERR, MAP_ERR, bank=1)[0]
    m.exit_mon()
    if ok != 1:
        print(f"\nMAP: *** NOT LOADED *** -- mapErr={err} "
              f"({MERR.get(err, 'unknown')})")
        return 1
    try:
        img = open(REU_IMAGE, "rb").read()
    except OSError as e:
        print(f"\nMAP: mapOK=1, but {REU_IMAGE} is unreadable ({e}) -- "
              "cannot verify the contents")
        return 1
    if img[0:4] != b"D64U":
        print(f"\nMAP: {REU_IMAGE} has bad magic {img[0:4]!r}")
        return 1

    bad = 0
    for i in range(img[5]):
        bid, flags, o0, o1, o2, length, loadhi = struct.unpack_from(
            "<BBBBBHB", img, 8 + i * 8)
        if not flags & 1:
            continue
        want = img[(o0 | o1 << 8 | o2 << 16):][:length]
        addr = loadhi << 8
        got = bytes(m.mem_get(addr, addr + length - 1, bank=1))
        sm = m.mem_get(MAP_SUM + bid * 2, MAP_SUM + bid * 2 + 1, bank=1)
        m.exit_mon()
        engine_sum = sm[0] | sm[1] << 8
        want_sum = sum(want) & 0xFFFF
        if engine_sum != want_sum:
            print(f"MAP: *** block {bid} checksum ${engine_sum:04X}, "
                  f"image says ${want_sum:04X} ***")
            bad = 1
        if got == want:
            print(f"MAP: block {bid} ${addr:04X} +{length} verified "
                  f"(sum ${engine_sum:04X})")
        else:
            n = sum(1 for a, b in zip(got, want) if a != b)
            first = next(k for k, (a, b) in enumerate(zip(got, want)) if a != b)
            print(f"MAP: *** block {bid} ${addr:04X} +{length}: {n} bytes "
                  f"differ, first at +{first} "
                  f"(want ${want[first]:02X}, got ${got[first]:02X}) ***")
            bad = 1
    return bad


MUS_OK = 0x0FF6          # `.const musOK`  in src/defs.asm
MUS_ERR = 0x0FF7         # `.const musErr` in src/defs.asm
MUS_PTR = 0x0FEC         # `.const musPtr` -- 24-bit, advances every tick
MUS_HDRSZ = 16           # the stream header, docs/reu-format.md §4.6
SID_BASE = 0xD400
SID_REGS = 25            # $D400-$D418, what the stream carries

# musErr values, from src/defs.asm.
MUSERR = {0: "none", 1: "bad stream magic", 2: "wrong stream version",
          3: "records longer than MUSWINDOW"}


def check_music(m):
    """Assert that all 25 SID registers hold what the stream says they should.

    This is the whole audio path in one comparison, and it can be exact because
    the tune was replayed offline: tools/sidstream.py ran the player in Python
    and recorded the register writes, so walking the stream from its start up to
    wherever `musPtr` has reached reconstructs the chip state the C64 must be in
    at that instant. If they match, then the handler is firing, its DMA is
    landing, its pointer arithmetic is on record boundaries, and every register
    write reached the chip. If the pointer has drifted off a boundary the walk
    says so directly -- and that is the failure this is really for, because a
    replay head half a record out of step still writes plausible-looking bytes
    to the SID and just sounds wrong.

    musOK alone would say only that musInit liked the header, which it can do
    and still produce silence. musOK = 0 with musErr = 0 is not a failure: it
    means the image carries no music block, which is what build/testmap.reu is.

    musPtr and the registers are read without leaving the monitor in between,
    so the machine is stopped for both and an interrupt cannot land between
    them and tear the two apart.
    """
    ok = m.mem_get(MUS_OK, MUS_OK, bank=1)[0]
    err = m.mem_get(MUS_ERR, MUS_ERR, bank=1)[0]
    ptr = bytes(m.mem_get(MUS_PTR, MUS_PTR + 2, bank=1))
    sid = bytes(m.mem_get(SID_BASE, SID_BASE + SID_REGS - 1, bank=3))
    m.exit_mon()

    if err:
        print(f"\nMUSIC: *** stream rejected *** -- musErr={err} "
              f"({MUSERR.get(err, 'unknown')})")
        return 1
    if ok != 1:
        print("\nMUSIC: no music block in the image -- rendering in silence")
        return 0
    try:
        img = open(REU_IMAGE, "rb").read()
    except OSError as e:
        print(f"\nMUSIC: musOK=1, but {REU_IMAGE} is unreadable ({e})")
        return 1

    mi = img[0x100:0x120]                       # MAPINFO, block 0
    base = mi[25] | mi[26] << 8 | mi[27] << 16
    want_ofs = (ptr[0] | ptr[1] << 8 | ptr[2] << 16) - base
    if not 0 < want_ofs <= len(img) - base:
        print(f"\nMUSIC: *** musPtr ${ptr[2]:02X}{ptr[1]:02X}{ptr[0]:02X} is "
              f"not inside the music block at ${base:06X} ***")
        return 1

    state = bytearray(SID_REGS)                 # musInit clears the chip first
    p, ticks = MUS_HDRSZ, 0
    while p < want_ofs:
        n = img[base + p]
        for k in range(n):
            state[img[base + p + 1 + 2 * k]] = img[base + p + 2 + 2 * k]
        p += 1 + 2 * n
        ticks += 1
    if p != want_ofs:
        print(f"\nMUSIC: *** musPtr is {want_ofs - p} bytes off a record "
              f"boundary *** -- {ticks} records reach {p}, the engine says "
              f"{want_ofs}. The replay head has lost the stream.")
        return 1
    if bytes(state) != sid:
        n = sum(1 for a, b in zip(state, sid) if a != b)
        first = next(k for k, (a, b) in enumerate(zip(state, sid)) if a != b)
        print(f"\nMUSIC: *** {n} of {SID_REGS} SID registers differ at tick "
              f"{ticks} *** first at $D4{first:02X}: stream says "
              f"${state[first]:02X}, chip has ${sid[first]:02X}")
        return 1
    print(f"\nMUSIC: playing -- tick {ticks}, all {SID_REGS} SID registers "
          f"match the stream (volume ${sid[24] & 0x0F:X})")
    return 0


def check_reloc(m, prg_path, tag, prefix, wanted, what):
    """Assert that a set of relocated code blocks is still executable.

    Some of this engine's code cannot be in the PRG image where it runs. The
    texture blocks run below $0801, under the load address; the doors blocks
    run under the I/O space, where an image that reached them would write 4 KB
    across $d000-$dfff as it loaded. Both are therefore assembled into MATRIX
    with .pseudopc and copied into place at boot (BOOTCODE4/BOOTCODE5).

    `diff` cannot see any of it: those addresses are outside the image, so it
    has nothing to compare them against, and the source copies in MATRIX are
    painted over by the first frame. So compare live RAM against the .pseudopc
    images in the PRG *file* instead. A column index that ran past 159 -- the
    exact bug spanFill's bounds check exists for -- now corrupts code rather
    than a clip window, and this is what would say so.

    The block addresses come from build/main.sym rather than being repeated
    here, because they move whenever the bin-packing does.
    """
    try:
        sym = open(SYMFILE).read()
    except OSError as e:
        print(f"\n{tag}: cannot read {SYMFILE} ({e})")
        return 1
    labels = dict(re.findall(r"^\.label (\w+)=\$([0-9a-fA-F]+)$", sym, re.M))
    try:
        blocks = [(name, int(labels[f"{prefix}{name}Src"], 16),
                   int(labels[f"{prefix}{name}End"], 16), run)
                  for name, run in wanted]
    except KeyError:
        print(f"\n{tag}: build/main.sym has no {prefix}*Src/End labels -- stale?")
        return 1

    load, img = load_prg(prg_path)
    bad = []
    for name, src, end, run in blocks:
        want = img[src - load:end - load]
        live = bytes(m.mem_get(run, run + len(want) - 1, bank=1))
        m.exit_mon()
        if live != want:
            n = sum(1 for a, b in zip(want, live) if a != b)
            first = next(k for k, (a, b) in enumerate(zip(want, live)) if a != b)
            bad.append(f"{name} at ${run:04X}: {n} of {len(want)} bytes differ, "
                       f"first at +${first:02X}")
    if bad:
        print(f"\n{tag}: *** relocated {what} has been overwritten ***")
        for line in bad:
            print(f"  {line}")
        return 1
    total = sum(e - s for _, s, e, _ in blocks)
    print(f"\n{tag}: {len(blocks)} relocated blocks intact, {total} bytes "
          f"({', '.join(f'${r:04X}' for _, _, _, r in blocks)})")
    return 0


def check_lines(m):
    """Assert that the special-line table reached the RAM under I/O.

    check_map cannot: block 7 is streamed rather than resident, because a
    descriptor carries a load *page* and $DB40 is not one. So mapLoad stages it
    in MATRIX and lineLoad copies it down (src/mapload.asm), and only the image
    itself says what should be there.

    Eighty bytes deciding which sectors are doors. Zeros here render exactly
    like a map with no doors in it, which is why this is asserted rather than
    watched for.
    """
    try:
        img = open(REU_IMAGE, "rb").read()
    except OSError as e:
        print(f"\nLINES: {REU_IMAGE} is unreadable ({e})")
        return 1
    for i in range(img[5]):
        bid, flags, o0, o1, o2, length, _ = struct.unpack_from(
            "<BBBBBHB", img, 8 + i * 8)
        if bid != BLK_LINEDEFS:
            continue
        want = img[(o0 | o1 << 8 | o2 << 16):][:length]
        got = bytes(m.mem_get(LINESPEC, LINESPEC + length - 1, bank=1))
        m.exit_mon()
        if got != want:
            n = sum(1 for a, b in zip(got, want) if a != b)
            print(f"\nLINES: *** the table at ${LINESPEC:04X} does not match "
                  f"block 7: {n} of {length} bytes differ ***")
            return 1
        kinds = Counter(k & 0x0F for k in want[:MAXLINES] if k)
        print(f"\nLINES: {sum(kinds.values())} special lines at "
              f"${LINESPEC:04X}, +{length} verified (" +
              " ".join(f"{LK_NAME.get(k, k)}:{n}"
                       for k, n in sorted(kinds.items())) + ")")
        return 0
    print("\nLINES: the image carries no block 7 -- no doors in this map")
    return 0


def check_texcode(m, prg_path):
    return check_reloc(m, prg_path, "TEXCODE", "tx", TEXBLOCKS, "texture code")


def check_linecode(m, prg_path):
    return check_reloc(m, prg_path, "LINECODE", "ln", LINEBLOCKS, "doors code")


def check_jumpcode(m, prg_path):
    return check_reloc(m, prg_path, "JUMPCODE", "jmp", JUMPBLOCKS, "jump code")


def cmd_diff(m, prg_path, settle):
    load, img = load_prg(prg_path)
    m.exit_mon()
    time.sleep(settle)

    diffs = []
    for a in range(load, load + len(img), 0x1000):
        b = min(a + 0xFFF, load + len(img) - 1)
        live = m.mem_get(a, b, bank=1)
        for i, v in enumerate(live):
            addr = a + i
            if v != img[addr - load]:
                diffs.append((addr, img[addr - load], v))
        m.exit_mon()

    counts = Counter(region(a) for a, _, _ in diffs)
    print("live-vs-PRG differences by region:")
    for name, n in counts.most_common():
        print(f"  {n:7d}  {name}")

    rc = (check_reu(m) | check_map(m) | check_music(m) | check_lines(m)
          | check_texcode(m, prg_path) | check_linecode(m, prg_path)
          | check_jumpcode(m, prg_path))

    bad = [d for d in diffs if region(d[0]).startswith("***")]
    print(f"\nunexpected differences: {len(bad)}")
    if not bad:
        print("  clean -- no writes outside the engine's own buffers")
        return rc

    runs = []
    for addr, was, now in bad:
        if runs and addr - runs[-1][1] <= 8 and now == runs[-1][2]:
            runs[-1][1] = addr
        else:
            runs.append([addr, addr, now])
    for start, end, val in runs[:40]:
        print(f"  ${start:04x}-${end:04x}  value=${val:02x}  ({end - start + 1} bytes)")
    return 1


def connect(port, wait=30.0):
    """Wait for the monitor socket to come up, then connect.

    x64sc opens the binary-monitor port some way into its startup, and how long
    that takes varies with the machine, whether xvfb is in the way, and whether
    the ROMs load on the first try. A fixed `sleep` in the Makefile therefore
    either raced (ConnectionRefused) or wasted seconds on every run.
    """
    deadline = time.time() + wait
    while True:
        try:
            return Mon(port=port)
        except (ConnectionRefusedError, OSError):
            if time.time() >= deadline:
                raise
            time.sleep(0.25)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("dump", "diff"):
        print(__doc__)
        return 2
    action = sys.argv[1]
    prg = sys.argv[2] if len(sys.argv) > 2 else "build/doom.prg"
    port = int(sys.argv[3]) if len(sys.argv) > 3 else 6510
    settle = float(sys.argv[4]) if len(sys.argv) > 4 else 8.0

    try:
        m = connect(port)
    except OSError as e:
        print(f"probe: no VICE binary monitor on port {port} ({e})")
        return 2
    try:
        return cmd_dump(m, prg, settle) if action == "dump" else cmd_diff(m, prg, settle)
    finally:
        m.quit()


if __name__ == "__main__":
    sys.exit(main() or 0)
