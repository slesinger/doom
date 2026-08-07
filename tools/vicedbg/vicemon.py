#!/usr/bin/env python3
"""Minimal client for the VICE binary monitor (x64sc -binarymonitor).

Enough of the protocol to inspect a running C64: read memory in a chosen bank,
read CPU registers, set checkpoints/watchpoints, resume, and quit.

Start the emulator with, e.g.:

    xvfb-run -a x64sc -warp +sound +confirmonexit -autostartprgmode 1 \
        -binarymonitor -binarymonitoraddress ip4://127.0.0.1:6510 \
        -autostart build/doom.prg

Note that connecting a binary-monitor client halts the CPU; call exit_mon() to
let the machine run on.
"""
import socket
import struct

STX = 0x02
API = 0x02

# banks reported by MON_CMD_BANKS_AVAILABLE on a C64
BANK_DEFAULT = 0
BANK_RAM = 1        # RAM beneath BASIC/KERNAL ROM -- what the VIC and our
BANK_ROM = 2        # converter actually see; use this, not BANK_DEFAULT,
BANK_IO = 3         # when reading $A000+ or $E000+


class Mon:
    def __init__(self, host="127.0.0.1", port=6510, timeout=30):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.rid = 0

    # -- framing ---------------------------------------------------------
    def _send(self, cmd, body=b""):
        self.rid += 1
        self.s.sendall(struct.pack("<BBIIB", STX, API, len(body), self.rid, cmd) + body)
        return self.rid

    def _recvn(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise EOFError("monitor closed the connection")
            buf += chunk
        return buf

    def cmd(self, cmd, body=b""):
        want = self._send(cmd, body)
        while True:
            stx, _api, blen, rtype, err, rid = struct.unpack("<BBIBBI", self._recvn(12))
            if stx != STX:
                raise ValueError(f"bad STX {stx:#x}")
            payload = self._recvn(blen)
            if rid == want:
                return rtype, err, payload
            # otherwise an asynchronous event (checkpoint hit, stop, ...) -- drop it

    # -- commands --------------------------------------------------------
    def mem_get(self, start, end, bank=BANK_DEFAULT, side_effects=0, memspace=0):
        body = struct.pack("<BHHBH", side_effects, start, end, memspace, bank)
        _, err, b = self.cmd(0x01, body)
        if err:
            raise RuntimeError(f"mem_get failed, err={err}")
        return b[2:2 + struct.unpack("<H", b[:2])[0]]

    def regs(self, memspace=0):
        """-> {register id: value}. Pair with register_names() for labels."""
        _, _, b = self.cmd(0x31, bytes([memspace]))
        n = struct.unpack("<H", b[:2])[0]
        out, off = {}, 2
        for _ in range(n):
            size = b[off]
            out[b[off + 1]] = struct.unpack("<H", b[off + 2:off + 4])[0]
            off += size + 1
        return out

    def register_names(self, memspace=0):
        _, _, b = self.cmd(0x83, bytes([memspace]))
        n = struct.unpack("<H", b[:2])[0]
        out, off = {}, 2
        for _ in range(n):
            size = b[off]
            out[b[off + 1]] = b[off + 4:off + 4 + b[off + 3]].decode()
            off += size + 1
        return out

    def banks(self):
        _, _, b = self.cmd(0x82)
        n = struct.unpack("<H", b[:2])[0]
        out, off = {}, 2
        for _ in range(n):
            size = b[off]
            bid = struct.unpack("<H", b[off + 1:off + 3])[0]
            out[b[off + 4:off + 4 + b[off + 3]].decode()] = bid
            off += size + 1
        return out

    def checkpoint(self, start, end, op, stop=True, enabled=True, temporary=False):
        """op: 1=load, 2=store, 4=exec. Returns the checkpoint number."""
        body = struct.pack("<HHBBBB", start, end, int(stop), int(enabled),
                           op, int(temporary))
        _, err, b = self.cmd(0x12, body)
        if err:
            raise RuntimeError(f"checkpoint failed, err={err}")
        return struct.unpack("<I", b[:4])[0]

    def autostart(self, path, run=True, index=0):
        name = path.encode()
        body = struct.pack("<BHB", int(run), index, len(name)) + name
        _, err, _ = self.cmd(0xDD, body)
        if err:
            raise RuntimeError(f"autostart failed, err={err}")

    def exit_mon(self):
        """Leave the monitor and let the emulated CPU run."""
        return self.cmd(0xAA)

    def quit(self):
        try:
            self.cmd(0xBB)
        except Exception:
            pass
        finally:
            self.s.close()
