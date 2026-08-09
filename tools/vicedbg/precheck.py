#!/usr/bin/env python3
"""Watch a colTop/colBot column across every doWall entry of one frame --
answers "was this column already wrong before wall N even started?" This
is what caught the renderFrame init-loop bug: colTop[61]/colBot[61] were
already (0,0) at wall 0's very first doWall call, before any wall had run.

Usage: python3 tools/vicedbg/precheck.py [column] [stop_at_wall]
"""
import struct
import sys
import time

sys.path.insert(0, "tools/vicedbg")
from vicemon import Mon

DOWALL = 0xcadb
COL = int(sys.argv[1]) if len(sys.argv) > 1 else 61
STOP_AT_WALL = int(sys.argv[2]) if len(sys.argv) > 2 else 3


def wait_for_stop(m, timeout=30):
    m.exit_mon()
    deadline = time.time() + timeout
    while time.time() < deadline:
        stx, api, blen, rtype, err, rid = struct.unpack("<BBIBBI", m._recvn(12))
        payload = m._recvn(blen)
        if rtype == 0x11:
            return payload
    raise TimeoutError("no stop event")


def main():
    m = Mon()
    names = m.register_names()

    def cpu_x():
        # doWall's own `stx zWIdx2` hasn't executed yet at its entry
        # checkpoint -- read the CPU register, not the zero page, or
        # you'll see the *previous* wall's index.
        r = m.regs()
        for k, v in r.items():
            if names.get(k) == "X":
                return v
        return None

    m.checkpoint(DOWALL, DOWALL, op=4, stop=True)
    for i in range(200):
        wait_for_stop(m)
        widx = cpu_x()
        top = m.mem_get(0x0200 + COL, 0x0200 + COL, bank=1)[0]
        bot = m.mem_get(0x0300 + COL, 0x0300 + COL, bank=1)[0]
        print(f"  doWall entry #{i+1}: X={widx:2d}  colTop[{COL}]={top:3d} colBot[{COL}]={bot:3d}")
        if widx == STOP_AT_WALL:
            break

    m.quit()


if __name__ == "__main__":
    main()
