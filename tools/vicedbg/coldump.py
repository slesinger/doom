#!/usr/bin/env python3
"""Per-column colTop/colBot dump for one wall's doWall call, sampled at
colAdvance ($ce28) -- i.e. right after that column's write, so there's no
stale-zero-page ambiguity (unlike sampling at colLoopHead, where zSX still
holds the *previous* column's index until STX executes).
"""
import struct
import sys
import time

sys.path.insert(0, "tools/vicedbg")
from vicemon import Mon

DOWALL = 0xcadb
COLADVANCE = 0xce28

ZP = dict(zSX=0x60, zWIdx2=0x3f, zBack=0x3b)

TARGET_WALL = int(sys.argv[1]) if len(sys.argv) > 1 else 3
MAX_COLS = int(sys.argv[2]) if len(sys.argv) > 2 else 40


def wait_for_stop(m, timeout=30):
    m.exit_mon()
    deadline = time.time() + timeout
    while time.time() < deadline:
        stx, api, blen, rtype, err, rid = struct.unpack("<BBIBBI", m._recvn(12))
        payload = m._recvn(blen)
        if rtype == 0x11:
            return payload
    raise TimeoutError("no stop event")


def zp(m, name):
    a = ZP[name]
    return m.mem_get(a, a, bank=1)[0]


def main():
    m = Mon()
    m.checkpoint(DOWALL, DOWALL, op=4, stop=True)

    names = m.register_names()

    def cpu_x(m):
        r = m.regs()
        for k, v in r.items():
            if names.get(k) == "X":
                return v
        return None

    for i in range(200):
        wait_for_stop(m)
        widx = cpu_x(m)  # doWall's own `stx zWIdx2` hasn't executed yet at
                          # the entry checkpoint -- zero page zWIdx2 is
                          # still the *previous* wall's index there; the
                          # CPU register X already holds the new one.
        if widx == TARGET_WALL:
            print(f"hit doWall entry for wall {widx} after {i+1} tries")
            break
    else:
        print("never saw target wall")
        m.quit()
        return 1

    m.checkpoint(COLADVANCE, COLADVANCE, op=4, stop=True)
    for i in range(MAX_COLS):
        wait_for_stop(m)
        sx = zp(m, "zSX")
        top = m.mem_get(0x0200 + sx, 0x0200 + sx, bank=1)[0]
        bot = m.mem_get(0x0300 + sx, 0x0300 + sx, bank=1)[0]
        print(f"  col {sx:3d}: colTop={top:3d} colBot={bot:3d}"
              f"{'  <-- BOTH ZERO' if top == 0 and bot == 0 else ''}")

    m.quit()


if __name__ == "__main__":
    main()
