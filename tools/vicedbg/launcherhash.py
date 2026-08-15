#!/usr/bin/env python3
"""Prove the merged launcher's warm-jumped game matches a cold doom.prg boot.

    make framehash-launcher

The real machine only ever reaches the game after a real space press, which
the VICE binary monitor has no clean way to fake -- src/intro/intro.asm
polls the CIA1 keyboard matrix directly ($DC00/$DC01), not the KERNAL
keyboard buffer, so there is no RAM location to poke. Instead this sets an
exec checkpoint on waitSpace (src/intro/build/intro.sym) and, once the
launcher is sitting in that loop, forces the CPU's PC to chainToGame -- the
same code a real space press would reach, just arrived at without one. From
there it is exactly framehash.py's own wait-for-frames-then-hash-MATRIX
check: the two scripts should print identical digests for the same map/
build, which is the acceptance bar IMPLEMENTATION_PLAN's launcher plan §3
set for "the game boots warm, not from reset".
"""
import hashlib
import re
import sys
import time

sys.path.insert(0, "tools/vicedbg")
from vicemon import Mon
from probe import connect

MATRIX = 0x1000
VIEWROWS = 144
MATRIX_LEN = VIEWROWS * 160
FRAMECNT = 0x0F40
MAPOK = 0x0F47
SYMFILE = "src/intro/build/intro.sym"


def read_label(name: str) -> int:
    text = open(SYMFILE).read()
    m = re.search(rf"\.label {re.escape(name)}\s*=\s*\$([0-9a-fA-F]+)", text)
    if not m:
        raise ValueError(f"{SYMFILE}: no label {name!r} -- rebuild the launcher")
    return int(m.group(1), 16)


def frames(m):
    b = m.mem_get(FRAMECNT, FRAMECNT + 1, bank=1)
    return b[0] | (b[1] << 8)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 6510
    want = int(sys.argv[2]) if len(sys.argv) > 2 else 6
    m = connect(port)

    wait_space = read_label("waitSpace")
    chain_to_game = read_label("chainToGame")
    names = m.register_names()
    pc_id = next(rid for rid, n in names.items() if n == "PC")

    cp = m.checkpoint(wait_space, wait_space, op=4, stop=True, temporary=True)
    m.exit_mon()
    m.wait_stopped(timeout=60)          # blocks until waitSpace is hit
    m.regs_set({pc_id: chain_to_game})  # the automated stand-in for space

    deadline = time.time() + 120
    while time.time() < deadline:
        m.exit_mon()
        time.sleep(0.5)
        if frames(m) >= want:
            break
    else:
        print("framehash-launcher: the game never reached "
              f"{want} frames after the chain-in", file=sys.stderr)
        return 1

    if m.mem_get(MAPOK, MAPOK, bank=1)[0] != 1:
        print("framehash-launcher: the map did not load", file=sys.stderr)
        return 1

    data = m.mem_get(MATRIX, MATRIX + MATRIX_LEN - 1, bank=1)
    nz = sum(1 for x in data if x)
    print(f"frames {frames(m)}  matrix {len(data)}B  "
          f"nonzero {nz} ({100*nz/len(data):.1f}%)  "
          f"sha256 {hashlib.sha256(data).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
