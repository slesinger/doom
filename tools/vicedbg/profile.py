#!/usr/bin/env python3
"""Call counts per frame for the renderer's hot routines.

    python3 tools/vicedbg/profile.py [port] [sample_seconds] [--syms build/main.vs]

Sets a non-stopping exec checkpoint on the entry of each routine named in
ROUTINES, lets the machine run, and reports VICE's hit counters divided by the
frames that elapsed. Multiplied by a routine's hand-counted cycle cost, that is
where the frame actually goes -- which `stats.py`'s workload counters cannot
say, because they count geometry (segs, subsectors) and the frame is mostly
arithmetic underneath it.

Why checkpoints and not more `Count` macros: instrument.asm's nine counters
fill TABLES_FREE to its last byte, and doWall has nineteen spare bytes in its
whole segment (IMPLEMENTATION_PLAN.md §13). This measures the shipping build,
from outside, and costs the engine nothing.

The hit counters are read with MON_CMD_CHECKPOINT_GET, which reports a hit
count VICE maintains itself; nothing is sent per hit, so a checkpoint on a
routine called half a million times a frame does not flood the socket.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from vicemon import Mon, BANK_RAM          # noqa: E402

FRAME_CNT = 0x0F40                          # `.const frameCnt` in src/defs.asm

# Entry points worth counting, in the order they are reported. Anything called
# per column or per pixel is here; so are the two leaves (mul8, udiv) that
# every projection ultimately spends its time in.
ROUTINES = [
    "convert", "flip",
    "bspLoop", "renderSsec", "ssecFetch", "sphereVisible",
    "doWall", "segFacing", "transformPoint", "smulTrig",
    "projSX", "projRow", "lineSetup", "clampAcc",
    "colLoopHead", "spanFill", "spanCells", "spanNextCell",
    # Stage A texturing (§10). texCol/texPix are the strip rebuild, and they
    # are what a finer tile multiplies: a taller tile makes each rebuild
    # longer, a wider one makes rebuilds more frequent.
    "texSetup", "texUpd", "texCol", "texPix", "spanTex", "uAdvance",
    "umul16", "mul8", "udiv", "sdiv", "ssmul32",
]


def load_syms(path):
    """build/main.vs is KickAssembler's VICE symbol file: `al C:addr .name`."""
    out = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 3 and parts[0] == "al":
                out[parts[2].lstrip(".")] = int(parts[1].split(":")[1], 16)
    return out


def hits(m, num):
    """MON_CMD_CHECKPOINT_GET -> the hit count VICE has accumulated."""
    _, err, b = m.cmd(0x11, num.to_bytes(4, "little"))
    if err:
        raise RuntimeError(f"checkpoint_get({num}) failed, err={err}")
    return int.from_bytes(b[0x0D:0x11], "little")


def frames(m):
    return int.from_bytes(m.mem_get(FRAME_CNT, FRAME_CNT + 1, bank=BANK_RAM), "little")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 6510
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
    syms = load_syms(sys.argv[3] if len(sys.argv) > 3 else "build/main.vs")

    for attempt in range(60):
        try:
            m = Mon(port=port)
            break
        except OSError:
            time.sleep(0.5)
    else:
        print("profile: no monitor on port", port, file=sys.stderr)
        return 1

    time.sleep(6.0)                         # let the engine reach steady state
    m.cmd(0xAA)                             # exit_mon: a fresh connection halts the CPU

    cps = {}
    for name in ROUTINES:
        if name in syms:
            cps[name] = m.checkpoint(syms[name], syms[name], op=4, stop=False)
    m.exit_mon()

    f0 = frames(m)
    base = {n: hits(m, c) for n, c in cps.items()}
    m.exit_mon()
    time.sleep(secs)
    f1 = frames(m)
    got = {n: hits(m, c) for n, c in cps.items()}
    m.exit_mon()

    nf = (f1 - f0) & 0xFFFF
    if nf == 0:
        print("profile: no frames elapsed -- raise sample_seconds", file=sys.stderr)
        return 1
    print(f"frames sampled: {nf}\n")
    print(f"{'routine':<16}{'calls/frame':>14}")
    for name in ROUTINES:
        if name in cps:
            print(f"{name:<16}{(got[name] - base[name]) / nf:>14.1f}")
    m.quit()
    return 0


if __name__ == "__main__":
    sys.exit(main())
