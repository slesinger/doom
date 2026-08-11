#!/usr/bin/env python3
"""A 6502 core, complete enough to run a SID tune's player offline.

Why this exists: a `.sid` file is player *code*, and the only way to learn
what a player writes to the SID is to execute it. The engine cannot execute
it (IMPLEMENTATION_PLAN.md §14: the tune wants 11.6 KB at $0FF6 and the
machine has ~360 free bytes), so it is executed here instead and the register
writes are what ship. `tools/sid2reu.py` is the driver.

Scope: every documented opcode, plus the undocumented ones SID players
actually use (LAX/SAX/DCP/ISC/SLO/RLA/SRE/RRA/ANC/ALR/ARR/SBX and the NOP
family). Decimal mode is implemented for ADC/SBC because a handful of players
set D. Cycle counts include page-cross and branch-taken penalties; they are
reported, not used for scheduling.

Memory is a `Bus` object with `read(addr) -> int` and `write(addr, value)`,
which is where the C64 (banking, SID capture, CIA/VIC stubs) lives.

Stdlib only, like every other tool in this directory.
"""

from __future__ import annotations

# flag bits
C, Z, I, D, B, U, V, N = 1, 2, 4, 8, 16, 32, 64, 128


class Cpu6502:
    """Registers, decode, execute. One instruction per `step()`."""

    def __init__(self, bus):
        self.bus = bus
        self.a = self.x = self.y = 0
        self.sp = 0xFD
        self.pc = 0
        self.p = U | I
        self.cycles = 0
        self.illegal = None          # opcode of the first JAM hit, if any

    # ---- memory helpers -------------------------------------------------
    def rd(self, addr):
        return self.bus.read(addr & 0xFFFF)

    def wr(self, addr, val):
        self.bus.write(addr & 0xFFFF, val & 0xFF)

    def rd16(self, addr):
        return self.rd(addr) | (self.rd(addr + 1) << 8)

    def rd16_zp(self, addr):
        """Zero-page pointer read: the high byte wraps inside page 0."""
        return self.rd(addr & 0xFF) | (self.rd((addr + 1) & 0xFF) << 8)

    def rd16_bug(self, addr):
        """JMP ($xxFF) reads the high byte from the same page. Real hardware."""
        hi = (addr & 0xFF00) | ((addr + 1) & 0x00FF)
        return self.rd(addr) | (self.rd(hi) << 8)

    def push(self, val):
        self.wr(0x0100 | self.sp, val)
        self.sp = (self.sp - 1) & 0xFF

    def pop(self):
        self.sp = (self.sp + 1) & 0xFF
        return self.rd(0x0100 | self.sp)

    # ---- flag helpers ---------------------------------------------------
    def set_nz(self, val):
        val &= 0xFF
        self.p = (self.p & ~(N | Z)) | (Z if val == 0 else 0) | (val & N)
        return val

    def set_flag(self, mask, on):
        if on:
            self.p |= mask
        else:
            self.p &= ~mask

    # ---- addressing modes ------------------------------------------------
    # Each returns (address, page_crossed). Immediate returns the operand's
    # own address, so every opcode can just read through the address.
    def _imm(self):
        a = self.pc
        self.pc = (self.pc + 1) & 0xFFFF
        return a, False

    def _zp(self):
        a = self.rd(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return a, False

    def _zpx(self):
        a = (self.rd(self.pc) + self.x) & 0xFF
        self.pc = (self.pc + 1) & 0xFFFF
        return a, False

    def _zpy(self):
        a = (self.rd(self.pc) + self.y) & 0xFF
        self.pc = (self.pc + 1) & 0xFFFF
        return a, False

    def _abs(self):
        a = self.rd16(self.pc)
        self.pc = (self.pc + 2) & 0xFFFF
        return a, False

    def _abx(self):
        base = self.rd16(self.pc)
        self.pc = (self.pc + 2) & 0xFFFF
        a = (base + self.x) & 0xFFFF
        return a, (base & 0xFF00) != (a & 0xFF00)

    def _aby(self):
        base = self.rd16(self.pc)
        self.pc = (self.pc + 2) & 0xFFFF
        a = (base + self.y) & 0xFFFF
        return a, (base & 0xFF00) != (a & 0xFF00)

    def _idx(self):                      # (zp,X)
        z = (self.rd(self.pc) + self.x) & 0xFF
        self.pc = (self.pc + 1) & 0xFFFF
        return self.rd16_zp(z), False

    def _idy(self):                      # (zp),Y
        z = self.rd(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        base = self.rd16_zp(z)
        a = (base + self.y) & 0xFFFF
        return a, (base & 0xFF00) != (a & 0xFF00)

    def _rel(self):
        off = self.rd(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        if off & 0x80:
            off -= 0x100
        a = (self.pc + off) & 0xFFFF
        return a, (self.pc & 0xFF00) != (a & 0xFF00)

    # ---- arithmetic shared by the legal and illegal forms ---------------
    def _adc(self, val):
        if self.p & D:
            lo = (self.a & 0x0F) + (val & 0x0F) + (self.p & C)
            hi = (self.a >> 4) + (val >> 4)
            if lo > 9:
                lo += 6
                hi += 1
            # N and V are set from the binary-ish intermediate, as on NMOS
            bin_sum = (self.a + val + (self.p & C)) & 0xFF
            self.set_flag(Z, bin_sum == 0)
            self.set_flag(N, ((hi << 4) & 0x80) != 0)
            self.set_flag(V, (~(self.a ^ val) & (self.a ^ (hi << 4)) & 0x80) != 0)
            if hi > 9:
                hi += 6
            self.set_flag(C, hi > 15)
            self.a = ((hi << 4) | (lo & 0x0F)) & 0xFF
        else:
            s = self.a + val + (self.p & C)
            self.set_flag(C, s > 0xFF)
            self.set_flag(V, (~(self.a ^ val) & (self.a ^ s) & 0x80) != 0)
            self.a = self.set_nz(s)

    def _sbc(self, val):
        if self.p & D:
            borrow = (self.p & C) ^ 1
            lo = (self.a & 0x0F) - (val & 0x0F) - borrow
            hi = (self.a >> 4) - (val >> 4)
            if lo & 0x10:
                lo -= 6
                hi -= 1
            if hi & 0x10:
                hi -= 6
            diff = self.a - val - borrow
            self.set_flag(C, (diff & 0x100) == 0)
            self.set_flag(V, ((self.a ^ val) & (self.a ^ diff) & 0x80) != 0)
            self.set_nz(diff & 0xFF)
            self.a = ((hi << 4) | (lo & 0x0F)) & 0xFF
        else:
            self._adc(val ^ 0xFF)

    def _cmp(self, reg, val):
        d = (reg - val) & 0x1FF
        self.set_flag(C, reg >= val)
        self.set_nz(d & 0xFF)

    def _branch(self, mask, want):
        addr, crossed = self._rel()
        if bool(self.p & mask) == want:
            self.cycles += 2 if crossed else 1
            self.pc = addr

    # ---- the interpreter -------------------------------------------------
    def step(self):
        """Execute one instruction. Returns the cycles it took."""
        start = self.cycles
        op = self.rd(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        entry = _TABLE[op]
        if entry is None:
            self.illegal = op
            self.cycles += 2
            return self.cycles - start
        fn, mode, base = entry
        self.cycles += base
        fn(self, mode)
        return self.cycles - start

    def run_until(self, sentinel, max_cycles=20_000_000):
        """Run until PC hits `sentinel`. Returns cycles spent.

        The caller pushes `sentinel - 1` so the routine's own RTS lands here;
        that is how a JSR from outside the emulated machine is expressed.
        """
        spent = 0
        while self.pc != sentinel:
            spent += self.step()
            if self.illegal is not None:
                raise RuntimeError(f"JAM opcode ${self.illegal:02X} at "
                                   f"${self.pc - 1:04X}")
            if spent > max_cycles:
                raise RuntimeError(f"ran {spent} cycles without returning to "
                                   f"${sentinel:04X} -- runaway player?")
        return spent


# ---------------------------------------------------------------------------
# opcode implementations
#
# Each takes the addressing-mode function. Modes that can cross a page add a
# cycle only for the read-style opcodes -- the read-modify-write and store
# forms always pay the fixed cost, which is why `crossed` is consulted here
# and not in the mode helpers.
# ---------------------------------------------------------------------------

def _op_lda(c, m):
    a, x = m(c)
    c.cycles += x
    c.a = c.set_nz(c.rd(a))


def _op_ldx(c, m):
    a, x = m(c)
    c.cycles += x
    c.x = c.set_nz(c.rd(a))


def _op_ldy(c, m):
    a, x = m(c)
    c.cycles += x
    c.y = c.set_nz(c.rd(a))


def _op_sta(c, m):
    a, _ = m(c)
    c.wr(a, c.a)


def _op_stx(c, m):
    a, _ = m(c)
    c.wr(a, c.x)


def _op_sty(c, m):
    a, _ = m(c)
    c.wr(a, c.y)


def _op_adc(c, m):
    a, x = m(c)
    c.cycles += x
    c._adc(c.rd(a))


def _op_sbc(c, m):
    a, x = m(c)
    c.cycles += x
    c._sbc(c.rd(a))


def _op_and(c, m):
    a, x = m(c)
    c.cycles += x
    c.a = c.set_nz(c.a & c.rd(a))


def _op_ora(c, m):
    a, x = m(c)
    c.cycles += x
    c.a = c.set_nz(c.a | c.rd(a))


def _op_eor(c, m):
    a, x = m(c)
    c.cycles += x
    c.a = c.set_nz(c.a ^ c.rd(a))


def _op_cmp(c, m):
    a, x = m(c)
    c.cycles += x
    c._cmp(c.a, c.rd(a))


def _op_cpx(c, m):
    a, _ = m(c)
    c._cmp(c.x, c.rd(a))


def _op_cpy(c, m):
    a, _ = m(c)
    c._cmp(c.y, c.rd(a))


def _op_bit(c, m):
    a, _ = m(c)
    v = c.rd(a)
    c.set_flag(Z, (c.a & v) == 0)
    c.set_flag(N, (v & 0x80) != 0)
    c.set_flag(V, (v & 0x40) != 0)


def _op_inc(c, m):
    a, _ = m(c)
    c.wr(a, c.set_nz(c.rd(a) + 1))


def _op_dec(c, m):
    a, _ = m(c)
    c.wr(a, c.set_nz(c.rd(a) - 1))


def _op_asl(c, m):
    a, _ = m(c)
    v = c.rd(a)
    c.set_flag(C, (v & 0x80) != 0)
    c.wr(a, c.set_nz(v << 1))


def _op_lsr(c, m):
    a, _ = m(c)
    v = c.rd(a)
    c.set_flag(C, (v & 1) != 0)
    c.wr(a, c.set_nz(v >> 1))


def _op_rol(c, m):
    a, _ = m(c)
    v = c.rd(a)
    carry = c.p & C
    c.set_flag(C, (v & 0x80) != 0)
    c.wr(a, c.set_nz((v << 1) | carry))


def _op_ror(c, m):
    a, _ = m(c)
    v = c.rd(a)
    carry = (c.p & C) << 7
    c.set_flag(C, (v & 1) != 0)
    c.wr(a, c.set_nz((v >> 1) | carry))


def _op_asl_a(c, m):
    c.set_flag(C, (c.a & 0x80) != 0)
    c.a = c.set_nz(c.a << 1)


def _op_lsr_a(c, m):
    c.set_flag(C, (c.a & 1) != 0)
    c.a = c.set_nz(c.a >> 1)


def _op_rol_a(c, m):
    carry = c.p & C
    c.set_flag(C, (c.a & 0x80) != 0)
    c.a = c.set_nz((c.a << 1) | carry)


def _op_ror_a(c, m):
    carry = (c.p & C) << 7
    c.set_flag(C, (c.a & 1) != 0)
    c.a = c.set_nz((c.a >> 1) | carry)


def _op_jmp(c, m):
    c.pc, _ = m(c)


def _op_jmp_ind(c, m):
    ptr = c.rd16(c.pc)
    c.pc = c.rd16_bug(ptr)


def _op_jsr(c, m):
    target = c.rd16(c.pc)
    ret = (c.pc + 1) & 0xFFFF          # JSR pushes the address of the last byte
    c.push(ret >> 8)
    c.push(ret & 0xFF)
    c.pc = target


def _op_rts(c, m):
    lo = c.pop()
    hi = c.pop()
    c.pc = ((hi << 8) | lo) + 1 & 0xFFFF


def _op_rti(c, m):
    c.p = (c.pop() & ~B) | U
    lo = c.pop()
    hi = c.pop()
    c.pc = ((hi << 8) | lo) & 0xFFFF


def _op_brk(c, m):
    c.pc = (c.pc + 1) & 0xFFFF
    c.push(c.pc >> 8)
    c.push(c.pc & 0xFF)
    c.push(c.p | B | U)
    c.p |= I
    c.pc = c.rd16(0xFFFE)


def _op_php(c, m):
    c.push(c.p | B | U)


def _op_plp(c, m):
    c.p = (c.pop() & ~B) | U


def _op_pha(c, m):
    c.push(c.a)


def _op_pla(c, m):
    c.a = c.set_nz(c.pop())


def _op_tax(c, m):
    c.x = c.set_nz(c.a)


def _op_tay(c, m):
    c.y = c.set_nz(c.a)


def _op_txa(c, m):
    c.a = c.set_nz(c.x)


def _op_tya(c, m):
    c.a = c.set_nz(c.y)


def _op_tsx(c, m):
    c.x = c.set_nz(c.sp)


def _op_txs(c, m):
    c.sp = c.x


def _op_inx(c, m):
    c.x = c.set_nz(c.x + 1)


def _op_iny(c, m):
    c.y = c.set_nz(c.y + 1)


def _op_dex(c, m):
    c.x = c.set_nz(c.x - 1)


def _op_dey(c, m):
    c.y = c.set_nz(c.y - 1)


def _op_nop(c, m):
    if m is not None:
        _, x = m(c)
        c.cycles += x


def _op_clc(c, m):
    c.p &= ~C


def _op_sec(c, m):
    c.p |= C


def _op_cli(c, m):
    c.p &= ~I


def _op_sei(c, m):
    c.p |= I


def _op_clv(c, m):
    c.p &= ~V


def _op_cld(c, m):
    c.p &= ~D


def _op_sed(c, m):
    c.p |= D


def _op_bpl(c, m):
    c._branch(N, False)


def _op_bmi(c, m):
    c._branch(N, True)


def _op_bvc(c, m):
    c._branch(V, False)


def _op_bvs(c, m):
    c._branch(V, True)


def _op_bcc(c, m):
    c._branch(C, False)


def _op_bcs(c, m):
    c._branch(C, True)


def _op_bne(c, m):
    c._branch(Z, False)


def _op_beq(c, m):
    c._branch(Z, True)


# ---- undocumented ---------------------------------------------------------

def _op_lax(c, m):
    a, x = m(c)
    c.cycles += x
    v = c.rd(a)
    c.a = c.x = c.set_nz(v)


def _op_sax(c, m):
    a, _ = m(c)
    c.wr(a, c.a & c.x)


def _op_dcp(c, m):
    a, _ = m(c)
    v = (c.rd(a) - 1) & 0xFF
    c.wr(a, v)
    c._cmp(c.a, v)


def _op_isc(c, m):
    a, _ = m(c)
    v = (c.rd(a) + 1) & 0xFF
    c.wr(a, v)
    c._sbc(v)


def _op_slo(c, m):
    a, _ = m(c)
    v = c.rd(a)
    c.set_flag(C, (v & 0x80) != 0)
    v = (v << 1) & 0xFF
    c.wr(a, v)
    c.a = c.set_nz(c.a | v)


def _op_rla(c, m):
    a, _ = m(c)
    v = c.rd(a)
    carry = c.p & C
    c.set_flag(C, (v & 0x80) != 0)
    v = ((v << 1) | carry) & 0xFF
    c.wr(a, v)
    c.a = c.set_nz(c.a & v)


def _op_sre(c, m):
    a, _ = m(c)
    v = c.rd(a)
    c.set_flag(C, (v & 1) != 0)
    v >>= 1
    c.wr(a, v)
    c.a = c.set_nz(c.a ^ v)


def _op_rra(c, m):
    a, _ = m(c)
    v = c.rd(a)
    carry = (c.p & C) << 7
    c.set_flag(C, (v & 1) != 0)
    v = (v >> 1) | carry
    c.wr(a, v)
    c._adc(v)


def _op_anc(c, m):
    a, _ = m(c)
    c.a = c.set_nz(c.a & c.rd(a))
    c.set_flag(C, (c.a & 0x80) != 0)


def _op_alr(c, m):
    a, _ = m(c)
    v = c.a & c.rd(a)
    c.set_flag(C, (v & 1) != 0)
    c.a = c.set_nz(v >> 1)


def _op_arr(c, m):
    a, _ = m(c)
    v = c.a & c.rd(a)
    c.a = ((c.p & C) << 7) | (v >> 1)
    c.set_nz(c.a)
    c.set_flag(C, (c.a & 0x40) != 0)
    c.set_flag(V, (((c.a >> 6) ^ (c.a >> 5)) & 1) != 0)


def _op_sbx(c, m):
    a, _ = m(c)
    v = c.rd(a)
    t = (c.a & c.x) - v
    c.set_flag(C, t >= 0)
    c.x = c.set_nz(t & 0xFF)


def _op_las(c, m):
    a, x = m(c)
    c.cycles += x
    v = c.rd(a) & c.sp
    c.a = c.x = c.sp = c.set_nz(v)


def _op_shy(c, m):
    a, _ = m(c)
    c.wr(a, c.y & ((a >> 8) + 1))


def _op_shx(c, m):
    a, _ = m(c)
    c.wr(a, c.x & ((a >> 8) + 1))


# ---------------------------------------------------------------------------
# the decode table: opcode -> (handler, addressing mode, base cycles)
# ---------------------------------------------------------------------------
_A = None            # accumulator / implied: no mode function

_TABLE = [None] * 256


def _e(op, fn, mode, cyc):
    _TABLE[op] = (fn, mode, cyc)


_IMM, _ZP, _ZPX, _ZPY = Cpu6502._imm, Cpu6502._zp, Cpu6502._zpx, Cpu6502._zpy
_ABS, _ABX, _ABY = Cpu6502._abs, Cpu6502._abx, Cpu6502._aby
_IDX, _IDY = Cpu6502._idx, Cpu6502._idy

for op, mode, cyc in ((0xA9, _IMM, 2), (0xA5, _ZP, 3), (0xB5, _ZPX, 4),
                      (0xAD, _ABS, 4), (0xBD, _ABX, 4), (0xB9, _ABY, 4),
                      (0xA1, _IDX, 6), (0xB1, _IDY, 5)):
    _e(op, _op_lda, mode, cyc)

for op, mode, cyc in ((0xA2, _IMM, 2), (0xA6, _ZP, 3), (0xB6, _ZPY, 4),
                      (0xAE, _ABS, 4), (0xBE, _ABY, 4)):
    _e(op, _op_ldx, mode, cyc)

for op, mode, cyc in ((0xA0, _IMM, 2), (0xA4, _ZP, 3), (0xB4, _ZPX, 4),
                      (0xAC, _ABS, 4), (0xBC, _ABX, 4)):
    _e(op, _op_ldy, mode, cyc)

for op, mode, cyc in ((0x85, _ZP, 3), (0x95, _ZPX, 4), (0x8D, _ABS, 4),
                      (0x9D, _ABX, 5), (0x99, _ABY, 5), (0x81, _IDX, 6),
                      (0x91, _IDY, 6)):
    _e(op, _op_sta, mode, cyc)

for op, mode, cyc in ((0x86, _ZP, 3), (0x96, _ZPY, 4), (0x8E, _ABS, 4)):
    _e(op, _op_stx, mode, cyc)

for op, mode, cyc in ((0x84, _ZP, 3), (0x94, _ZPX, 4), (0x8C, _ABS, 4)):
    _e(op, _op_sty, mode, cyc)

for base, fn in ((0x60, _op_adc), (0xE0, _op_sbc), (0x20, _op_and),
                 (0x00, _op_ora), (0x40, _op_eor), (0xC0, _op_cmp)):
    for off, mode, cyc in ((0x09, _IMM, 2), (0x05, _ZP, 3), (0x15, _ZPX, 4),
                           (0x0D, _ABS, 4), (0x1D, _ABX, 4), (0x19, _ABY, 4),
                           (0x01, _IDX, 6), (0x11, _IDY, 5)):
        _e(base + off, fn, mode, cyc)

_e(0xE4, _op_cpx, _ZP, 3)
_e(0xE0, _op_cpx, _IMM, 2)
_e(0xEC, _op_cpx, _ABS, 4)
_e(0xC4, _op_cpy, _ZP, 3)
_e(0xC0, _op_cpy, _IMM, 2)
_e(0xCC, _op_cpy, _ABS, 4)
_e(0x24, _op_bit, _ZP, 3)
_e(0x2C, _op_bit, _ABS, 4)

for op, mode, cyc in ((0xE6, _ZP, 5), (0xF6, _ZPX, 6), (0xEE, _ABS, 6),
                      (0xFE, _ABX, 7)):
    _e(op, _op_inc, mode, cyc)

for op, mode, cyc in ((0xC6, _ZP, 5), (0xD6, _ZPX, 6), (0xCE, _ABS, 6),
                      (0xDE, _ABX, 7)):
    _e(op, _op_dec, mode, cyc)

for base, fn in ((0x00, _op_asl), (0x40, _op_lsr), (0x20, _op_rol),
                 (0x60, _op_ror)):
    for off, mode, cyc in ((0x06, _ZP, 5), (0x16, _ZPX, 6), (0x0E, _ABS, 6),
                           (0x1E, _ABX, 7)):
        _e(base + off, fn, mode, cyc)

_e(0x0A, _op_asl_a, _A, 2)
_e(0x4A, _op_lsr_a, _A, 2)
_e(0x2A, _op_rol_a, _A, 2)
_e(0x6A, _op_ror_a, _A, 2)

_e(0x4C, _op_jmp, _ABS, 3)
_e(0x6C, _op_jmp_ind, _A, 5)
_e(0x20, _op_jsr, _A, 6)
_e(0x60, _op_rts, _A, 6)
_e(0x40, _op_rti, _A, 6)
_e(0x00, _op_brk, _A, 7)

_e(0x08, _op_php, _A, 3)
_e(0x48, _op_pha, _A, 3)
_e(0x28, _op_plp, _A, 4)
_e(0x68, _op_pla, _A, 4)

for op, fn in ((0xAA, _op_tax), (0xA8, _op_tay), (0x8A, _op_txa),
               (0x98, _op_tya), (0xBA, _op_tsx), (0x9A, _op_txs),
               (0xE8, _op_inx), (0xC8, _op_iny), (0xCA, _op_dex),
               (0x88, _op_dey), (0x18, _op_clc), (0x38, _op_sec),
               (0x58, _op_cli), (0x78, _op_sei), (0xB8, _op_clv),
               (0xD8, _op_cld), (0xF8, _op_sed), (0xEA, _op_nop)):
    _e(op, fn, _A, 2)

for op, fn in ((0x10, _op_bpl), (0x30, _op_bmi), (0x50, _op_bvc),
               (0x70, _op_bvs), (0x90, _op_bcc), (0xB0, _op_bcs),
               (0xD0, _op_bne), (0xF0, _op_beq)):
    _e(op, fn, _A, 2)

# undocumented, the subset players use
for op, mode, cyc in ((0xA7, _ZP, 3), (0xB7, _ZPY, 4), (0xAF, _ABS, 4),
                      (0xBF, _ABY, 4), (0xA3, _IDX, 6), (0xB3, _IDY, 5),
                      (0xAB, _IMM, 2)):
    _e(op, _op_lax, mode, cyc)

for op, mode, cyc in ((0x87, _ZP, 3), (0x97, _ZPY, 4), (0x8F, _ABS, 4),
                      (0x83, _IDX, 6)):
    _e(op, _op_sax, mode, cyc)

for base, fn in ((0xC0, _op_dcp), (0xE0, _op_isc), (0x00, _op_slo),
                 (0x20, _op_rla), (0x40, _op_sre), (0x60, _op_rra)):
    for off, mode, cyc in ((0x07, _ZP, 5), (0x17, _ZPX, 6), (0x0F, _ABS, 6),
                           (0x1F, _ABX, 7), (0x1B, _ABY, 7), (0x03, _IDX, 8),
                           (0x13, _IDY, 8)):
        _e(base + off, fn, mode, cyc)

_e(0x0B, _op_anc, _IMM, 2)
_e(0x2B, _op_anc, _IMM, 2)
_e(0x4B, _op_alr, _IMM, 2)
_e(0x6B, _op_arr, _IMM, 2)
_e(0xCB, _op_sbx, _IMM, 2)
_e(0xEB, _op_sbc, _IMM, 2)
_e(0xBB, _op_las, _ABY, 4)
_e(0x9C, _op_shy, _ABX, 5)
_e(0x9E, _op_shx, _ABY, 5)

# the NOP family: implied, immediate, zp and absolute forms
for op in (0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA):
    _e(op, _op_nop, _A, 2)
for op in (0x80, 0x82, 0x89, 0xC2, 0xE2):
    _e(op, _op_nop, _IMM, 2)
for op in (0x04, 0x44, 0x64):
    _e(op, _op_nop, _ZP, 3)
for op in (0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4):
    _e(op, _op_nop, _ZPX, 4)
_e(0x0C, _op_nop, _ABS, 4)
for op in (0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC):
    _e(op, _op_nop, _ABX, 4)
