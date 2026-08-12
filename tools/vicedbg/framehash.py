#!/usr/bin/env python3
"""Hash the rendered frame buffer, for the pixel-exact acceptance test.

    make framehash                 # -> one sha256 over MATRIX

`make shot`'s PNG is not an oracle for "did this change a pixel": the
screenshot lands wherever -limitcycles stops, which is mid-flip often enough
that two runs of the *same* build differ by a few dozen pixels. What is exact
is the renderer's own output buffer, read at a frame boundary: the camera does
not move without input, so every frame writes the identical 25600 bytes
(176 -> 160 rows, IMPLEMENTATION_PLAN.md §14a.1).

Waits for the engine's frame counter to pass a few frames, reads MATRIX, and
prints its sha256 plus the coverage the shot check would see. Two builds that
print the same digest differ by zero pixels; that is the standard every frame
optimization since IMPLEMENTATION_PLAN.md §13 has been held to.
"""
import hashlib
import sys
import time

sys.path.insert(0, "tools/vicedbg")
from vicemon import Mon
from probe import connect

MATRIX = 0x1000
MATRIX_LEN = 160 * 160          # what the renderer actually writes
FRAMECNT = 0x0F40               # `.const frameCnt` in src/defs.asm
MAPOK = 0x0F47


def frames(m):
    b = m.mem_get(FRAMECNT, FRAMECNT + 1, bank=1)
    return b[0] | (b[1] << 8)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 6510
    want = int(sys.argv[2]) if len(sys.argv) > 2 else 6
    m = connect(port)

    deadline = time.time() + 120
    while time.time() < deadline:
        m.exit_mon()
        time.sleep(0.5)
        if frames(m) >= want:
            break
    else:
        print("framehash: the engine never reached "
              f"{want} frames", file=sys.stderr)
        return 1

    if m.mem_get(MAPOK, MAPOK, bank=1)[0] != 1:
        print("framehash: the map did not load", file=sys.stderr)
        return 1

    data = m.mem_get(MATRIX, MATRIX + MATRIX_LEN - 1, bank=1)
    nz = sum(1 for x in data if x)
    print(f"frames {frames(m)}  matrix {len(data)}B  "
          f"nonzero {100.0 * nz / len(data):.1f}%")
    print(f"sha256 {hashlib.sha256(data).hexdigest()}")
    m.quit()
    return 0


if __name__ == "__main__":
    sys.exit(main())
