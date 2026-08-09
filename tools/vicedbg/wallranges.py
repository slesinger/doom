#!/usr/bin/env python3
"""Dump every doWall-entry and colLoopHead event in strict chronological
order for the first N events of a frame -- ground truth for wall traversal
order and each wall's live [zC0,zC1]/zBack, without hand-derived geometry
or fragile "did it get skipped" inference. See debug-notes/A-front-body-clamp.md.
"""
import struct
import sys
import time

sys.path.insert(0, "tools/vicedbg")
from vicemon import Mon

DOWALL = 0xcadb
COLLOOPHEAD = 0xcd7c

ZP = dict(zC0=0x24, zC1=0x25, zBack=0x3b, zWIdx2=0x3f)

N = int(sys.argv[1]) if len(sys.argv) > 1 else 30


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
    m.checkpoint(COLLOOPHEAD, COLLOOPHEAD, op=4, stop=True)

    last = None
    for i in range(N):
        payload = wait_for_stop(m)
        start_addr = struct.unpack("<H", payload[5:7])[0]
        widx = zp(m, "zWIdx2")
        key = (start_addr, widx)
        if key == last:
            continue
        last = key
        if start_addr == DOWALL:
            print(f"{i:3d}  ENTRY      wall {widx:2d}")
        else:
            c0, c1, back = zp(m, "zC0"), zp(m, "zC1"), zp(m, "zBack")
            print(f"{i:3d}  colLoopHead wall {widx:2d}  zC0={c0:3d} zC1={c1:3d} "
                  f"zBack={back:3d}{'  (portal)' if back != 0xff else '  (solid)'}")

    m.quit()


if __name__ == "__main__":
    main()
