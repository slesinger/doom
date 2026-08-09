#!/usr/bin/env python3
"""Single-step wall 3 (the A->B portal, sector A) from its doWall entry
through its first column's full processing, dumping the front-wall clamp
(zTW/zBW) and the portal-opening clamp (zBT/zBB) plus raw accumulators at
every step. This directly answers hypothesis A vs D for the *actual* bug
(wall 3's own clampAcc collapsing to (0,0) across its whole [61,98] range --
see debug-notes/A-front-body-clamp.md for how wall 8 was misattributed).
"""
import struct
import sys
import time

sys.path.insert(0, "tools/vicedbg")
from vicemon import Mon

DOWALL = 0xcadb

ZP = dict(zWT=0x88, zWB=0x89, zTW=0x8a, zBW=0x8b, zBT=0x8c, zBB=0x8d,
          accTop=0x68, accBot=0x6b, accBT=0x6e, accBB=0x71,
          zSX=0x60, zWIdx2=0x3f, zBack=0x3b, zC0=0x24, zC1=0x25)

TARGET_WALL = int(sys.argv[1]) if len(sys.argv) > 1 else 3
STEPS = int(sys.argv[2]) if len(sys.argv) > 2 else 120


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


def zp16(m, name):
    a = ZP[name]
    b = m.mem_get(a, a + 2, bank=1)
    return b[0], b[1], b[2]


def main():
    m = Mon()
    names = m.register_names()

    def cpu_x():
        r = m.regs()
        for k, v in r.items():
            if names.get(k) == "X":
                return v
        return None

    m.checkpoint(DOWALL, DOWALL, op=4, stop=True)
    for i in range(200):
        wait_for_stop(m)
        widx = cpu_x()
        if widx == TARGET_WALL:
            print(f"hit doWall entry for wall {widx} after {i+1} tries")
            break
    else:
        print("never saw target wall")
        m.quit()
        return 1

    print("\n-- single-step trace from doWall entry --")
    for step in range(STEPS):
        r = m.advance_instructions(1, step_over=True)
        pc = None
        for k, v in r.items():
            if names.get(k) == "PC":
                pc = v
        interesting = step % 50 == 0 or 0xcdd0 <= pc <= 0xce28
        if interesting:
            tw, bw = zp(m, "zTW"), zp(m, "zBW")
            bt, bb = zp(m, "zBT"), zp(m, "zBB")
            back = zp(m, "zBack")
            print(f"  step {step:3d}  PC=${pc:04x}  zTW={tw:3d} zBW={bw:3d} "
                  f"zBT={bt:3d} zBB={bb:3d}  zBack={back}")
        if pc == 0xce28:  # colAdvance -- first column done
            print("  (reached colAdvance -- first column complete)")
            break

    print("\n-- raw accumulators (frac, int-lo, int-hi) --")
    for name in ("accTop", "accBot", "accBT", "accBB"):
        frac, lo, hi = zp16(m, name)
        signed_hi = hi - 256 if hi >= 128 else hi
        print(f"  {name:8s} frac={frac:3d} lo={lo:3d} hi={hi:3d} (signed {signed_hi})")

    m.quit()


if __name__ == "__main__":
    main()
