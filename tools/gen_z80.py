#!/usr/bin/env python3
"""Generate the PureMetal Z80 core for the Pico (src/z80.pico) and the
Pico 2 (src/z80.pico2).

The core is one ProcedureRAM, Z80Run, with six 256-entry .Label dispatch
tables (base, CB, ED, DD, FD and the shared DDCB/FDCB page). Every handler
ends in its own dispatch tail. Instruction semantics are PureMetal; only the
dispatch tail (fetch, table lookup, bx) is inline assembly when
#Z80_ASM_TAIL = 1.

Edit this file, then run:  py -3 tools/gen_z80.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --------------------------------------------------------------------------
# Targets. Each names its register reservation and its dispatch tails.
# --------------------------------------------------------------------------
TARGETS = {
    'pico': dict(
        out='src/z80.pico',
        reserve='ReserveRegister Z80PC = r4, Z80F = r5, Z80A = r8, Z80ICount = r10, Z80Left = r11',
        pc_low=True,
    ),
    'pico2': dict(
        out='src/z80.pico2',
        reserve='ReserveRegister Z80PC = r4, Z80F = r5, Z80A = r8, Z80ICount = r10, Z80Left = r11',
        pc_low=True,
    ),
}

# Flag bits
FC, FN, FP, FX, FH, FY, FZ, FS = 1, 2, 4, 8, 16, 32, 64, 128

R8 = ['B', 'C', 'D', 'E', 'H', 'L', '(HL)', 'A']
RP = ['BC', 'DE', 'HL', 'SP']
RP2 = ['BC', 'DE', 'HL', 'AF']
CC = ['NZ', 'Z', 'NC', 'C', 'PO', 'PE', 'P', 'M']
ALU = ['ADD', 'ADC', 'SUB', 'SBC', 'AND', 'XOR', 'OR', 'CP']
ROT = ['RLC', 'RRC', 'RL', 'RR', 'SLA', 'SRA', 'SLL', 'SRL']

# condition -> PureMetal test that is true when the condition holds
COND = {
    'NZ': '(Z80F & 64) = 0', 'Z': '(Z80F & 64) <> 0',
    'NC': '(Z80F & 1) = 0', 'C': '(Z80F & 1) <> 0',
    'PO': '(Z80F & 4) = 0', 'PE': '(Z80F & 4) <> 0',
    'P': '(Z80F & 128) = 0', 'M': '(Z80F & 128) <> 0',
}


def pairname(rp, idx=None):
    """16-bit register pair global. idx is None, 'IX' or 'IY'."""
    if rp == 'HL' and idx:
        return 'Z80' + idx
    return 'Z80' + rp


def get8(r, idx=None):
    if r == 'A':
        return 'Z80A'
    pair, off = {'B': ('BC', 1), 'C': ('BC', 0), 'D': ('DE', 1), 'E': ('DE', 0),
                 'H': ('HL', 1), 'L': ('HL', 0)}[r]
    p = pairname(pair, idx)
    return 'PeekA(@%s + 1)' % p if off else 'PeekA(@%s)' % p


def set8(r, expr, idx=None):
    """expr must already be 0..255."""
    if r == 'A':
        return ['Z80A = %s' % expr]
    pair, off = {'B': ('BC', 1), 'C': ('BC', 0), 'D': ('DE', 1), 'E': ('DE', 0),
                 'H': ('HL', 1), 'L': ('HL', 0)}[r]
    p = pairname(pair, idx)
    if off:
        return ['PokeA(@%s + 1, %s)' % (p, expr)]
    return ['PokeA(@%s, %s)' % (p, expr)]


def rname(r, idx):
    if idx and r in ('H', 'L'):
        return idx + r
    return r


# Every handler: (label, comment, lines, cycles, sets_flags)
class Page:
    def __init__(self, name):
        self.name = name
        self.entries = {}     # opcode -> label
        self.handlers = []    # (label, comment, lines, cycles, setsflags)

    def add(self, op, label, comment, lines, cycles, flags=False, tail='op'):
        self.entries[op] = label
        self.handlers.append((label, comment, lines, cycles, flags, tail))

    def alias(self, op, label):
        self.entries[op] = label


# --------------------------------------------------------------------------
# Instruction fragments
# --------------------------------------------------------------------------
def fetch8(dst):
    return ['%s = Z80Mem(Z80PC)' % dst, 'Z80PC = (Z80PC + 1) & $FFFF']


def fetch16(dst):
    return ['%s = Z80Mem(Z80PC) | (Z80Mem((Z80PC + 1) & $FFFF) << 8)' % dst,
            'Z80PC = (Z80PC + 2) & $FFFF']


def fetchdisp_ea(idx):
    """ea = IX/IY + d, WZ = ea. PC advanced past d."""
    return ['ea = (Z80%s + PeekB(@Z80Mem(0) + Z80PC)) & $FFFF' % idx,
            'Z80PC = (Z80PC + 1) & $FFFF',
            'Z80WZ = ea']


def rd(dst, adr):
    return ['MemRd(%s, %s)' % (dst, adr)]


def wr(adr, val):
    return ['MemWr(%s, %s)' % (adr, val)]


def rd16(dst, adr):
    """dst = word at adr (adr is a simple name). Uses t."""
    return ['MemRd(%s, %s)' % (dst, adr),
            't = (%s + 1) & $FFFF' % adr,
            'MemRd(v, t)',
            '%s = %s | (v << 8)' % (dst, dst)]


def wr16(adr, val):
    """word val (simple name) to adr (simple name). Uses t, v."""
    return ['v = %s & 255' % val,
            'MemWr(%s, v)' % adr,
            't = (%s + 1) & $FFFF' % adr,
            'v = %s >> 8' % val,
            'MemWr(t, v)']


def push16(val):
    """val is a simple name holding 0..65535. Uses t, v."""
    return ['Z80SP = (Z80SP - 1) & $FFFF',
            'v = %s >> 8' % val,
            'MemWr(Z80SP, v)',
            'Z80SP = (Z80SP - 1) & $FFFF',
            'v = %s & 255' % val,
            'MemWr(Z80SP, v)']


def pop16(dst):
    """dst = popped word. Uses v."""
    return ['MemRd(%s, Z80SP)' % dst,
            'Z80SP = (Z80SP + 1) & $FFFF',
            'MemRd(v, Z80SP)',
            'Z80SP = (Z80SP + 1) & $FFFF',
            '%s = %s | (v << 8)' % (dst, dst)]


def alu_op(op, v):
    """A = A op v, flags. v is a simple name holding 0..255. Uses r, t.
    t = A ! v ! r holds the carry (borrow) into every bit: bit 4 is H, bit 8
    is C, and bit 7 ! bit 8 is V. Z80HVC((t >> 4) & 31) gives H|V|C from those
    five bits; Z80HVCN adds N."""
    if op in ('ADD', 'ADC', 'SUB', 'SBC'):
        sign = '+' if op in ('ADD', 'ADC') else '-'
        carry = ' %s (Z80F & 1)' % sign if op in ('ADC', 'SBC') else ''
        tbl = 'Z80HVC' if sign == '+' else 'Z80HVCN'
        return ['r = Z80A %s %s%s' % (sign, v, carry),
                'Z80F = Z80SZ53(r & 255) | %s(((Z80A ! %s ! r) >> 4) & 31)' % (tbl, v),
                'Z80A = r & 255']
    if op == 'AND':
        return ['Z80A = Z80A & %s' % v, 'Z80F = Z80SZ53P(Z80A) | 16']
    if op == 'XOR':
        return ['Z80A = Z80A ! %s' % v, 'Z80F = Z80SZ53P(Z80A)']
    if op == 'OR':
        return ['Z80A = Z80A | %s' % v, 'Z80F = Z80SZ53P(Z80A)']
    if op == 'CP':
        return ['r = Z80A - %s' % v,
                'Z80F = (Z80SZ53(r & 255) & $D7) | (%s & $28) | Z80HVCN(((Z80A ! %s ! r) >> 4) & 31)' % (v, v)]
    raise ValueError(op)


def rot_op(op, v):
    """r = rot(v), F = SZ53P(r) | carry. v simple name. Uses r, t."""
    body = {
        'RLC': ['t = %s >> 7' % v, 'r = ((%s << 1) | t) & 255' % v],
        'RRC': ['t = %s & 1' % v, 'r = (%s >> 1) | (t << 7)' % v],
        'RL': ['t = %s >> 7' % v, 'r = ((%s << 1) | (Z80F & 1)) & 255' % v],
        'RR': ['t = %s & 1' % v, 'r = (%s >> 1) | ((Z80F & 1) << 7)' % v],
        'SLA': ['t = %s >> 7' % v, 'r = (%s << 1) & 255' % v],
        'SRA': ['t = %s & 1' % v, 'r = (%s >> 1) | (%s & 128)' % (v, v)],
        'SLL': ['t = %s >> 7' % v, 'r = ((%s << 1) | 1) & 255' % v],
        'SRL': ['t = %s & 1' % v, 'r = %s >> 1' % v],
    }[op]
    return body + ['Z80F = Z80SZ53P(r) | t']


def bit_op(n, v, xy):
    """BIT n of v. xy is the expression giving the X/Y source."""
    return ['t = %s & %d' % (v, 1 << n),
            'Z80F = (Z80F & 1) | 16 | (Z80SZ53P(t) & $C4) | (%s & $28)' % xy]


def inc8(v):
    return ['r = (%s + 1) & 255' % v, 'Z80F = (Z80F & 1) | Z80IncF(r)']


def dec8(v):
    return ['r = (%s - 1) & 255' % v, 'Z80F = (Z80F & 1) | Z80DecF(r)']


def add16(dst, src):
    """dst = dst + src (dst is a pair global, src expression of a pair)."""
    return ['v = %s' % src,
            'Z80WZ = (%s + 1) & $FFFF' % dst,
            'r = %s + v' % dst,
            't = %s ! v ! r' % dst,
            'Z80F = (Z80F & $C4) | ((r >> 8) & $28) | (Z80HVC((t >> 12) & 31) & 17)',
            '%s = r & $FFFF' % dst]


def jump_rel():
    return ['t = PeekB(@Z80Mem(0) + Z80PC)',
            'Z80PC = (Z80PC + 1 + t) & $FFFF',
            'Z80WZ = Z80PC']


# --------------------------------------------------------------------------
# Pages
# --------------------------------------------------------------------------
def r8_operand_read(r, idx, lines, dst='v'):
    """Emit code putting register/memory operand r into dst. For (HL),
    index mode reads (IX+d). Returns lines appended."""
    if r == '(HL)':
        if idx:
            lines += fetchdisp_ea(idx)
        else:
            lines.append('ea = Z80HL')
        lines += rd(dst, 'ea')
    else:
        lines.append('%s = %s' % (dst, get8(r, idx)))


def build_main(idx=None):
    """Base page (idx None) or DD/FD page (idx 'IX'/'IY'). For an index page
    only the opcodes that differ from the base page are generated; the rest
    are reported in the returned set 'passthrough'."""
    pfx = idx or ''
    page = Page(idx or 'Base')
    passthrough = set()
    L = lambda op: ('%sOp%02X' % (pfx, op))
    extra = 4 if idx else 0       # prefix cost

    for op in range(256):
        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        p, q = y >> 1, y & 1
        lines = []
        cyc = None
        flags = False
        cmt = None
        uses_hl = False   # does this op change meaning under an index prefix

        if x == 0:
            if z == 0:
                if y == 0:
                    cmt, cyc = 'NOP', 4
                elif y == 1:
                    cmt, cyc = "EX AF,AF'", 4
                    lines += ['t = (Z80A << 8) | Z80F', 'Z80A = Z80AF2 >> 8', 'Z80F = Z80AF2 & 255', 'Z80AF2 = t']
                elif y == 2:
                    cmt = 'DJNZ e'
                    lines += ['t = (PeekA(@Z80BC + 1) - 1) & 255', 'PokeA(@Z80BC + 1, t)',
                              'If t <> 0'] + ['  ' + s for s in jump_rel()] + ['  Charge(5)', 'Else', '  Z80PC = (Z80PC + 1) & $FFFF', 'EndIf']
                    cyc = 8
                elif y == 3:
                    cmt, cyc = 'JR e', 12
                    lines += jump_rel()
                else:
                    c = CC[y - 4]
                    cmt, cyc = 'JR %s,e' % c, 7
                    lines += ['If ' + COND[c]] + ['  ' + s for s in jump_rel()] + ['  Charge(5)', 'Else', '  Z80PC = (Z80PC + 1) & $FFFF', 'EndIf']
            elif z == 1:
                if q == 0:
                    rp = RP[p]
                    cmt, cyc = 'LD %s,nn' % (idx if (rp == 'HL' and idx) else rp), 10
                    lines += fetch16(pairname(rp, idx))
                    uses_hl = rp == 'HL'
                else:
                    rp = RP[p]
                    d = pairname('HL', idx)
                    cmt, cyc = 'ADD %s,%s' % (idx or 'HL', idx if (rp == 'HL' and idx) else rp), 11
                    lines += add16(d, pairname(rp, idx))
                    flags = True
                    uses_hl = True
            elif z == 2:
                if q == 0:
                    if p == 0:
                        cmt, cyc = 'LD (BC),A', 7
                        lines += ['ea = Z80BC'] + wr('ea', 'Z80A') + ['Z80WZ = ((ea + 1) & 255) | (Z80A << 8)']
                    elif p == 1:
                        cmt, cyc = 'LD (DE),A', 7
                        lines += ['ea = Z80DE'] + wr('ea', 'Z80A') + ['Z80WZ = ((ea + 1) & 255) | (Z80A << 8)']
                    elif p == 2:
                        cmt, cyc = 'LD (nn),%s' % (idx or 'HL'), 16
                        lines += fetch16('ea') + ['n2 = %s' % pairname('HL', idx)] + wr16('ea', 'n2') + ['Z80WZ = (ea + 1) & $FFFF']
                        uses_hl = True
                    else:
                        cmt, cyc = 'LD (nn),A', 13
                        lines += fetch16('ea') + wr('ea', 'Z80A') + ['Z80WZ = ((ea + 1) & 255) | (Z80A << 8)']
                else:
                    if p == 0:
                        cmt, cyc = 'LD A,(BC)', 7
                        lines += ['ea = Z80BC'] + rd('Z80A', 'ea') + ['Z80WZ = (ea + 1) & $FFFF']
                    elif p == 1:
                        cmt, cyc = 'LD A,(DE)', 7
                        lines += ['ea = Z80DE'] + rd('Z80A', 'ea') + ['Z80WZ = (ea + 1) & $FFFF']
                    elif p == 2:
                        cmt, cyc = 'LD %s,(nn)' % (idx or 'HL'), 16
                        lines += fetch16('ea') + rd16('n2', 'ea') + ['%s = n2' % pairname('HL', idx), 'Z80WZ = (ea + 1) & $FFFF']
                        uses_hl = True
                    else:
                        cmt, cyc = 'LD A,(nn)', 13
                        lines += fetch16('ea') + rd('Z80A', 'ea') + ['Z80WZ = (ea + 1) & $FFFF']
            elif z == 3:
                rp = RP[p]
                d = pairname(rp, idx)
                if q == 0:
                    cmt, cyc = 'INC %s' % (idx if (rp == 'HL' and idx) else rp), 6
                    lines += ['%s = (%s + 1) & $FFFF' % (d, d)]
                else:
                    cmt, cyc = 'DEC %s' % (idx if (rp == 'HL' and idx) else rp), 6
                    lines += ['%s = (%s - 1) & $FFFF' % (d, d)]
                uses_hl = rp == 'HL'
            elif z in (4, 5):
                r = R8[y]
                nm = 'INC' if z == 4 else 'DEC'
                f = inc8 if z == 4 else dec8
                flags = True
                if r == '(HL)':
                    uses_hl = True
                    cmt, cyc = '%s (%s)' % (nm, (idx + '+d') if idx else 'HL'), 11
                    if idx:
                        lines += fetchdisp_ea(idx)
                        cyc = 11 + 12 - 4   # 23 with the prefix
                    else:
                        lines.append('ea = Z80HL')
                    lines += rd('v', 'ea') + f('v') + wr('ea', 'r')
                else:
                    uses_hl = r in ('H', 'L')
                    cmt, cyc = '%s %s' % (nm, rname(r, idx)), 4
                    lines += ['v = %s' % get8(r, idx)] + f('v') + set8(r, 'r', idx)
            elif z == 6:
                r = R8[y]
                if r == '(HL)':
                    uses_hl = True
                    cmt, cyc = 'LD (%s),n' % ((idx + '+d') if idx else 'HL'), 10
                    if idx:
                        lines += fetchdisp_ea(idx)
                        cyc = 10 + 9 - 4    # 19 with the prefix
                    else:
                        lines.append('ea = Z80HL')
                    lines += fetch8('v') + wr('ea', 'v')
                else:
                    uses_hl = r in ('H', 'L')
                    cmt, cyc = 'LD %s,n' % rname(r, idx), 7
                    if r == 'A':
                        lines += fetch8('Z80A')
                    else:
                        lines += fetch8('v') + set8(r, 'v', idx)
            else:
                cyc = 4
                flags = True
                if y == 0:
                    cmt = 'RLCA'
                    lines += ['Z80A = ((Z80A << 1) | (Z80A >> 7)) & 255', 'Z80F = (Z80F & $C4) | (Z80A & $29)']
                elif y == 1:
                    cmt = 'RRCA'
                    lines += ['t = Z80A & 1', 'Z80A = (Z80A >> 1) | (t << 7)', 'Z80F = (Z80F & $C4) | (Z80A & $28) | t']
                elif y == 2:
                    cmt = 'RLA'
                    lines += ['t = Z80A >> 7', 'Z80A = ((Z80A << 1) | (Z80F & 1)) & 255', 'Z80F = (Z80F & $C4) | (Z80A & $28) | t']
                elif y == 3:
                    cmt = 'RRA'
                    lines += ['t = Z80A & 1', 'Z80A = (Z80A >> 1) | ((Z80F & 1) << 7)', 'Z80F = (Z80F & $C4) | (Z80A & $28) | t']
                elif y == 4:
                    cmt = 'DAA'
                    lines += ['t = 0', 'r = Z80F & 1',
                              'If ((Z80F & 16) <> 0) Or ((Z80A & 15) > 9)', '  t = 6', 'EndIf',
                              'If (r <> 0) Or (Z80A > $99)', '  t = t | $60', '  r = 1', 'EndIf',
                              'If (Z80F & 2) <> 0', '  v = (Z80A - t) & 255', 'Else', '  v = (Z80A + t) & 255', 'EndIf',
                              'Z80F = Z80SZ53P(v) | (Z80F & 2) | r | ((Z80A ! v) & 16)',
                              'Z80A = v']
                elif y == 5:
                    cmt = 'CPL'
                    lines += ['Z80A = Z80A ! 255', 'Z80F = (Z80F & $C5) | 18 | (Z80A & $28)']
                elif y == 6:
                    cmt = 'SCF'
                    lines += ['QXY(t)', 'Z80F = (Z80F & $C4) | 1 | t']
                else:
                    cmt = 'CCF'
                    lines += ['QXY(t)', 'Z80F = ((Z80F & $C5) | ((Z80F & 1) << 4) | t) ! 1']
        elif x == 1:
            if op == 0x76:
                cmt, cyc = 'HALT', 4
                lines += ['Z80Halted = 1']
                page.add(op, L(op), cmt, lines, cyc + extra, flags, tail='halt')
                if idx:
                    passthrough.add(op)
                    page.entries.pop(op)
                    page.handlers.pop()
                continue
            dst, src = R8[y], R8[z]
            if dst == '(HL)' or src == '(HL)':
                uses_hl = True
                cyc = 7
                if idx:
                    lines += fetchdisp_ea(idx)
                    cyc = 7 + 12 - 4
                else:
                    lines.append('ea = Z80HL')
                if src == '(HL)':
                    cmt = 'LD %s,(%s)' % (dst, (idx + '+d') if idx else 'HL')
                    if dst == 'A':
                        lines += rd('Z80A', 'ea')
                    else:
                        lines += rd('v', 'ea') + set8(dst, 'v')
                else:
                    cmt = 'LD (%s),%s' % ((idx + '+d') if idx else 'HL', src)
                    if src == 'A':
                        lines += wr('ea', 'Z80A')
                    else:
                        lines += ['v = %s' % get8(src)] + wr('ea', 'v')
            else:
                uses_hl = dst in ('H', 'L') or src in ('H', 'L')
                cmt, cyc = 'LD %s,%s' % (rname(dst, idx), rname(src, idx)), 4
                if dst == src:
                    pass
                elif dst == 'A':
                    lines += ['Z80A = %s' % get8(src, idx)]
                else:
                    lines += set8(dst, get8(src, idx), idx)
        elif x == 2:
            r = R8[z]
            flags = True
            if r == '(HL)':
                uses_hl = True
                cmt, cyc = '%s (%s)' % (ALU[y], (idx + '+d') if idx else 'HL'), 7
                if idx:
                    cyc = 7 + 12 - 4
            else:
                uses_hl = r in ('H', 'L')
                cmt, cyc = '%s %s' % (ALU[y], rname(r, idx)), 4
            if r == 'A':
                v = 'Z80A'
                if ALU[y] in ('AND', 'OR'):
                    lines += ['Z80F = Z80SZ53P(Z80A)' + (' | 16' if ALU[y] == 'AND' else '')]
                elif ALU[y] == 'XOR':
                    lines += ['Z80A = 0', 'Z80F = Z80SZ53P(0)']
                else:
                    lines += ['v = Z80A'] + alu_op(ALU[y], 'v')
            else:
                r8_operand_read(r, idx, lines)
                lines += alu_op(ALU[y], 'v')
        else:
            if z == 0:
                c = CC[y]
                cmt, cyc = 'RET %s' % c, 5
                lines += ['If ' + COND[c]] + ['  ' + s for s in pop16('Z80PC')] + ['  Z80WZ = Z80PC', '  Charge(6)', 'EndIf']
            elif z == 1:
                if q == 0:
                    rp = RP2[p]
                    cyc = 10
                    if rp == 'AF':
                        cmt = 'POP AF'
                        lines += pop16('t') + ['Z80A = t >> 8', 'Z80F = t & 255']
                    else:
                        d = pairname(rp, idx)
                        cmt = 'POP %s' % (idx if (rp == 'HL' and idx) else rp)
                        lines += pop16('t') + ['%s = t' % d]
                        uses_hl = rp == 'HL'
                else:
                    if p == 0:
                        cmt, cyc = 'RET', 10
                        lines += pop16('Z80PC') + ['Z80WZ = Z80PC']
                    elif p == 1:
                        cmt, cyc = 'EXX', 4
                        lines += ['t = Z80BC', 'Z80BC = Z80BC2', 'Z80BC2 = t',
                                  't = Z80DE', 'Z80DE = Z80DE2', 'Z80DE2 = t',
                                  't = Z80HL', 'Z80HL = Z80HL2', 'Z80HL2 = t']
                    elif p == 2:
                        cmt, cyc = 'JP (%s)' % (idx or 'HL'), 4
                        lines += ['Z80PC = %s' % pairname('HL', idx)]
                        uses_hl = True
                    else:
                        cmt, cyc = 'LD SP,%s' % (idx or 'HL'), 6
                        lines += ['Z80SP = %s' % pairname('HL', idx)]
                        uses_hl = True
            elif z == 2:
                c = CC[y]
                cmt, cyc = 'JP %s,nn' % c, 10
                lines += fetch16('ea') + ['Z80WZ = ea', 'If ' + COND[c], '  Z80PC = ea', 'EndIf']
            elif z == 3:
                if y == 0:
                    cmt, cyc = 'JP nn', 10
                    lines += fetch16('ea') + ['Z80WZ = ea', 'Z80PC = ea']
                elif y == 1:
                    page.alias(op, 'PfxCB' if not idx else ('PfxXCB' + idx))
                    continue
                elif y == 2:
                    cmt, cyc = 'OUT (n),A', 11
                    lines += fetch8('t') + ['ea = (Z80A << 8) | t', 'Z80PortOut(ea, Z80A)',
                                            'Z80WZ = ((t + 1) & 255) | (Z80A << 8)']
                elif y == 3:
                    cmt, cyc = 'IN A,(n)', 11
                    lines += fetch8('t') + ['ea = (Z80A << 8) | t', 'Z80WZ = (ea + 1) & $FFFF', 'Z80A = Z80PortIn(ea) & 255']
                elif y == 4:
                    cmt, cyc = 'EX (SP),%s' % (idx or 'HL'), 19
                    d = pairname('HL', idx)
                    lines += ['ea = Z80SP'] + rd16('n2', 'ea') + ['r = %s' % d] + wr16('ea', 'r') + ['%s = n2' % d, 'Z80WZ = n2']
                    uses_hl = True
                elif y == 5:
                    cmt, cyc = 'EX DE,HL', 4
                    lines += ['t = Z80DE', 'Z80DE = Z80HL', 'Z80HL = t']
                elif y == 6:
                    cmt, cyc = 'DI', 4
                    lines += ['Z80IFF1 = 0', 'Z80IFF2 = 0']
                else:
                    cmt, cyc = 'EI', 4
                    lines += ['Z80IFF1 = 1', 'Z80IFF2 = 1']
                    page.add(op, L(op), cmt, lines, cyc + extra, False, tail='ei')
                    if idx:
                        passthrough.add(op)
                        page.entries.pop(op)
                        page.handlers.pop()
                    continue
            elif z == 4:
                c = CC[y]
                cmt, cyc = 'CALL %s,nn' % c, 10
                lines += fetch16('ea') + ['Z80WZ = ea', 'If ' + COND[c]] + ['  ' + s for s in push16('Z80PC')] + ['  Z80PC = ea', '  Charge(7)', 'EndIf']
            elif z == 5:
                if q == 0:
                    rp = RP2[p]
                    cyc = 11
                    if rp == 'AF':
                        cmt = 'PUSH AF'
                        lines += ['n2 = (Z80A << 8) | Z80F'] + push16('n2')
                    else:
                        cmt = 'PUSH %s' % (idx if (rp == 'HL' and idx) else rp)
                        lines += ['n2 = %s' % pairname(rp, idx)] + push16('n2')
                        uses_hl = rp == 'HL'
                else:
                    if p == 0:
                        cmt, cyc = 'CALL nn', 17
                        lines += fetch16('ea') + ['Z80WZ = ea'] + push16('Z80PC') + ['Z80PC = ea']
                    elif p == 1:
                        page.alias(op, 'PfxDD' if not idx else 'PfxDDc')
                        continue
                    elif p == 2:
                        page.alias(op, 'PfxED' if not idx else 'PfxEDc')
                        continue
                    else:
                        page.alias(op, 'PfxFD' if not idx else 'PfxFDc')
                        continue
            elif z == 6:
                cmt, cyc = '%s n' % ALU[y], 7
                flags = True
                lines += fetch8('v') + alu_op(ALU[y], 'v')
            else:
                cmt, cyc = 'RST %02XH' % (y * 8), 11
                lines += push16('Z80PC') + ['Z80PC = %d' % (y * 8), 'Z80WZ = Z80PC']

        if idx and not uses_hl:
            passthrough.add(op)
            continue
        page.add(op, L(op), cmt, lines, cyc + extra, flags)
    return page, passthrough


def build_cb():
    page = Page('CB')
    for op in range(256):
        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        r = R8[z]
        lines = []
        mem = r == '(HL)'
        if mem:
            lines += ['ea = Z80HL'] + rd('v', 'ea')
        else:
            lines += ['v = %s' % get8(r)]
        if x == 0:
            cmt = '%s %s' % (ROT[y], r)
            lines += rot_op(ROT[y], 'v')
            lines += wr('ea', 'r') if mem else set8(r, 'r')
            cyc = 15 if mem else 8
            fl = True
        elif x == 1:
            cmt = 'BIT %d,%s' % (y, r)
            lines += bit_op(y, 'v', '(Z80WZ >> 8)' if mem else 'v')
            cyc = 12 if mem else 8
            fl = True
        else:
            cmt = '%s %d,%s' % ('RES' if x == 2 else 'SET', y, r)
            if x == 2:
                lines += ['r = v & %d' % (255 ^ (1 << y))]
            else:
                lines += ['r = v | %d' % (1 << y)]
            lines += wr('ea', 'r') if mem else set8(r, 'r')
            cyc = 15 if mem else 8
            fl = False
        page.add(op, 'CBOp%02X' % op, cmt, lines, cyc, fl)
    return page


def build_xcb():
    """DDCB/FDCB page, dispatched on op >> 3 (32 groups): ea and WZ are
    already IX/IY + d. A rotate, RES or SET then copies its result into the
    register named by op & 7 (undocumented) through Z80OpXCopy: entries 0-7
    after a flag-writing rotate, 8-15 after RES/SET; entry 6/14 copies nothing."""
    page = Page('XCB')
    for g in range(32):
        x, y = g >> 3, g & 7
        lines = rd('v', 'ea')
        if x == 1:
            cmt = 'BIT %d,(IX+d)' % y
            lines += bit_op(y, 'v', '(ea >> 8)')
            page.add(g, 'XCBG%02X' % g, cmt, lines, 20, True)
            continue
        if x == 0:
            cmt = '%s (IX+d)[,r]' % ROT[y]
            lines += rot_op(ROT[y], 'v') + wr('ea', 'r')
            lines += ['op = Z80Mem((Z80PC - 1) & $FFFF) & 7', 'Goto Z80OpXCopy(op)']
        else:
            cmt = '%s %d,(IX+d)[,r]' % ('RES' if x == 2 else 'SET', y)
            if x == 2:
                lines += ['r = v & %d' % (255 ^ (1 << y))]
            else:
                lines += ['r = v | %d' % (1 << y)]
            lines += wr('ea', 'r')
            lines += ['op = (Z80Mem((Z80PC - 1) & $FFFF) & 7) + 8', 'Goto Z80OpXCopy(op)']
        page.add(g, 'XCBG%02X' % g, cmt, lines, 0, False, tail='goto')
    copies = Page('XCopy')
    for k in range(16):
        z = k & 7
        lines = [] if z == 6 else set8(R8[z], 'r')
        copies.add(k, 'XCpy%02d' % k, 'copy to %s' % ('nothing' if z == 6 else R8[z]), lines, 23, k < 8)
    return page, copies


PARITY_TOGGLE = 'If (Z80SZ53P(%s) & 4) = 0\n  Z80F = Z80F ! 4\nEndIf'


def build_ed():
    page = Page('ED')
    for op in range(256):
        x, y, z = op >> 6, (op >> 3) & 7, op & 7
        p, q = y >> 1, y & 1
        lines = []
        fl = False
        cmt = None
        if x == 1:
            if z == 0:
                r = R8[y]
                cmt, cyc = 'IN %s,(C)' % ('F' if r == '(HL)' else r), 12
                lines += ['v = Z80PortIn(Z80BC) & 255', 'Z80WZ = (Z80BC + 1) & $FFFF', 'Z80F = (Z80F & 1) | Z80SZ53P(v)']
                if r != '(HL)':
                    lines += set8(r, 'v')
                fl = True
            elif z == 1:
                r = R8[y]
                cmt, cyc = 'OUT (C),%s' % ('0' if r == '(HL)' else r), 12
                lines += ['Z80PortOut(Z80BC, %s)' % ('0' if r == '(HL)' else get8(r)), 'Z80WZ = (Z80BC + 1) & $FFFF']
            elif z == 2:
                rp = RP[p]
                src = pairname(rp)
                fl = True
                cyc = 15
                if q == 0:
                    cmt = 'SBC HL,%s' % rp
                    lines += ['v = %s' % src, 'Z80WZ = (Z80HL + 1) & $FFFF',
                              'r = Z80HL - v - (Z80F & 1)',
                              't = Z80HL ! v ! r',
                              'Z80F = ((r >> 8) & $A8) | Z80HVCN((t >> 12) & 31)',
                              'r = r & $FFFF', 'If r = 0', '  Z80F = Z80F | 64', 'EndIf', 'Z80HL = r']
                else:
                    cmt = 'ADC HL,%s' % rp
                    lines += ['v = %s' % src, 'Z80WZ = (Z80HL + 1) & $FFFF',
                              'r = Z80HL + v + (Z80F & 1)',
                              't = Z80HL ! v ! r',
                              'Z80F = ((r >> 8) & $A8) | Z80HVC((t >> 12) & 31)',
                              'r = r & $FFFF', 'If r = 0', '  Z80F = Z80F | 64', 'EndIf', 'Z80HL = r']
            elif z == 3:
                rp = RP[p]
                cyc = 20
                if q == 0:
                    cmt = 'LD (nn),%s' % rp
                    lines += fetch16('ea') + ['n2 = %s' % pairname(rp)] + wr16('ea', 'n2') + ['Z80WZ = (ea + 1) & $FFFF']
                else:
                    cmt = 'LD %s,(nn)' % rp
                    lines += fetch16('ea') + rd16('n2', 'ea') + ['%s = n2' % pairname(rp), 'Z80WZ = (ea + 1) & $FFFF']
            elif z == 4:
                cmt, cyc = 'NEG', 8
                lines += ['v = Z80A', 'r = 0 - v', 't = v ! r',
                          'Z80F = Z80SZ53(r & 255) | Z80HVCN((t >> 4) & 31)',
                          'Z80A = r & 255']
                fl = True
            elif z == 5:
                cmt, cyc = 'RETI' if y == 1 else 'RETN', 14
                lines += ['Z80IFF1 = Z80IFF2'] + pop16('Z80PC') + ['Z80WZ = Z80PC']
            elif z == 6:
                im = [0, 0, 1, 2, 0, 0, 1, 2][y]
                cmt, cyc = 'IM %d' % im, 8
                lines += ['Z80IM = %d' % im]
            else:
                if y == 0:
                    cmt, cyc = 'LD I,A', 9
                    lines += ['Z80I = Z80A']
                elif y == 1:
                    cmt, cyc = 'LD R,A', 9
                    lines += ['RSet(Z80A)']
                elif y == 2:
                    cmt, cyc = 'LD A,I', 9
                    lines += ['Z80A = Z80I', 'Z80F = (Z80F & 1) | Z80SZ53(Z80A) | (Z80IFF2 << 2)']
                    fl = True
                elif y == 3:
                    cmt, cyc = 'LD A,R', 9
                    lines += ['RGet(Z80A)', 'Z80F = (Z80F & 1) | Z80SZ53(Z80A) | (Z80IFF2 << 2)']
                    fl = True
                elif y == 4:
                    cmt, cyc = 'RRD', 18
                    lines += ['ea = Z80HL'] + rd('v', 'ea') + ['Z80WZ = (ea + 1) & $FFFF',
                              'r = ((Z80A << 4) | (v >> 4)) & 255'] + wr('ea', 'r') + [
                              'Z80A = (Z80A & $F0) | (v & 15)', 'Z80F = (Z80F & 1) | Z80SZ53P(Z80A)']
                    fl = True
                elif y == 5:
                    cmt, cyc = 'RLD', 18
                    lines += ['ea = Z80HL'] + rd('v', 'ea') + ['Z80WZ = (ea + 1) & $FFFF',
                              'r = ((v << 4) | (Z80A & 15)) & 255'] + wr('ea', 'r') + [
                              'Z80A = (Z80A & $F0) | (v >> 4)', 'Z80F = (Z80F & 1) | Z80SZ53P(Z80A)']
                    fl = True
                else:
                    continue   # ED 77 / ED 7F are NOPs
        elif x == 2 and z <= 3 and y >= 4:
            inc = '+' if (y & 1) == 0 else '-'
            rep = y >= 6
            kind = z
            name = [['LDI', 'CPI', 'INI', 'OUTI'], ['LDD', 'CPD', 'IND', 'OUTD'],
                    ['LDIR', 'CPIR', 'INIR', 'OTIR'], ['LDDR', 'CPDR', 'INDR', 'OTDR']][y - 4][z]
            cmt, cyc = name, 16
            if kind == 0:
                lines += ['ea = Z80HL'] + rd('v', 'ea') + ['t = Z80DE'] + wr('t', 'v') + [
                    'Z80HL = (Z80HL %s 1) & $FFFF' % inc, 'Z80DE = (Z80DE %s 1) & $FFFF' % inc,
                    'Z80BC = (Z80BC - 1) & $FFFF',
                    'n2 = v + Z80A',
                    'Z80F = (Z80F & $C1) | (n2 & 8) | ((n2 & 2) << 4)',
                    'If Z80BC <> 0', '  Z80F = Z80F | 4']
                if rep:
                    lines += ['  Z80PC = (Z80PC - 2) & $FFFF', '  Z80WZ = (Z80PC + 1) & $FFFF',
                              '  Z80F = (Z80F & $D7) | ((Z80PC >> 8) & $28)', '  Charge(5)']
                lines += ['EndIf']
            elif kind == 1:
                lines += ['ea = Z80HL'] + rd('v', 'ea') + [
                    'r = (Z80A - v) & 255',
                    't = (Z80A ! v ! r) & 16',
                    'Z80HL = (Z80HL %s 1) & $FFFF' % inc,
                    'Z80BC = (Z80BC - 1) & $FFFF',
                    'Z80WZ = (Z80WZ %s 1) & $FFFF' % inc,
                    'n2 = r - (t >> 4)',
                    'Z80F = (Z80F & 1) | 2 | (Z80SZ53(r) & $C0) | t | (n2 & 8) | ((n2 & 2) << 4)',
                    'If Z80BC <> 0', '  Z80F = Z80F | 4']
                if rep:
                    lines += ['  If r <> 0', '    Z80PC = (Z80PC - 2) & $FFFF', '    Z80WZ = (Z80PC + 1) & $FFFF',
                              '    Z80F = (Z80F & $D7) | ((Z80PC >> 8) & $28)', '    Charge(5)', '  EndIf']
                lines += ['EndIf']
            else:
                if kind == 2:
                    # INI / IND: WZ from BC before B is decremented
                    lines += ['v = Z80PortIn(Z80BC) & 255',
                              'Z80WZ = (Z80BC %s 1) & $FFFF' % inc,
                              'ea = Z80HL'] + wr('ea', 'v') + [
                              'Z80HL = (Z80HL %s 1) & $FFFF' % inc,
                              'n2 = (PeekA(@Z80BC + 1) - 1) & 255', 'PokeA(@Z80BC + 1, n2)',
                              'r = v + ((PeekA(@Z80BC) %s 1) & 255)' % inc]
                else:
                    # OUTI / OUTD: B is decremented before the port write
                    lines += ['ea = Z80HL'] + rd('v', 'ea') + [
                              'n2 = (PeekA(@Z80BC + 1) - 1) & 255', 'PokeA(@Z80BC + 1, n2)',
                              'Z80PortOut(Z80BC, v)',
                              'Z80WZ = (Z80BC %s 1) & $FFFF' % inc,
                              'Z80HL = (Z80HL %s 1) & $FFFF' % inc,
                              'r = v + PeekA(@Z80HL)']
                lines += ['Z80F = (Z80SZ53(n2) & $E8) | ((v >> 6) & 2) | (Z80SZ53P((r & 7) ! n2) & 4)',
                          'If r > 255', '  Z80F = Z80F | 17', 'EndIf']
                if rep:
                    lines += ['If n2 <> 0',
                              '  Z80PC = (Z80PC - 2) & $FFFF',
                              '  Z80WZ = (Z80PC + 1) & $FFFF',
                              '  Z80F = (Z80F & $D7) | ((Z80PC >> 8) & $28)',
                              '  If (Z80F & 1) <> 0',
                              '    Z80F = Z80F & $EF',
                              '    If (v & $80) <> 0',
                              '      t = (n2 - 1) & 7',
                              '      If (n2 & 15) = 0', '        Z80F = Z80F | 16', '      EndIf',
                              '    Else',
                              '      t = (n2 + 1) & 7',
                              '      If (n2 & 15) = 15', '        Z80F = Z80F | 16', '      EndIf',
                              '    EndIf',
                              '  Else',
                              '    t = n2 & 7',
                              '  EndIf',
                              '  If (Z80SZ53P(t) & 4) = 0', '    Z80F = Z80F ! 4', '  EndIf',
                              '  Charge(5)',
                              'EndIf']
            fl = True
        else:
            continue
        page.add(op, 'EDOp%02X' % op, cmt, lines, cyc, fl)
    return page


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------
HEADER = r'''; Generated by tools/gen_z80.py. Edit the generator, then regenerate.
; Zilog Z80 (NMOS) core for PureMetal, %(target)s.
; All documented and undocumented opcodes, undocumented X/Y flags, MEMPTR,
; Q (SCF/CCF), block instructions, IM 0/1/2, NMI, HALT, EI delay, R.
; Build switches (define before including this file):
;   #Z80_TIMED     = 1  Z80Run's budget and result are T-states;
;                    0  they are whole instructions (prefixes included).
;   #Z80_ASM_TAIL  = 1  inline-assembly dispatch tail; 0 plain computed Goto.
;   #Z80_MEM_HOOKS = 1  data reads/writes of pages flagged in Z80PageRd/
;                       Z80PageWr call Z80MemRead(addr)/Z80MemWrite(addr,v),
;                       which the machine defines. 0: flat 64 KB only.
;   #Z80_Q         = 1  model the Q latch for SCF/CCF X/Y bits (default 1).
;   #Z80_SHARED_TAIL = 1  one shared dispatch tail (smaller, a branch slower);
;                    0  every handler carries its own tail (fastest).
;   #Z80_TRACK_R   = 1  exact R in timed builds (one counter per instruction);
;                       0  LD A,R stops the CPU with Z80Error = 3.
; The machine always defines Z80PortIn(port) and Z80PortOut(port, value).
; Opcode and operand fetches always read Z80Mem directly.
; See README.md for the API.
'''


def emit(target):
    cfg = TARGETS[target]
    base, _ = build_main(None)
    ix, ixpass = build_main('IX')
    iy, iypass = build_main('IY')
    cb = build_cb()
    ed = build_ed()
    xcb, xcopy = build_xcb()

    o = []
    w = o.append
    w(HEADER % dict(target='RP2040 (Pico W)' if target == 'pico' else 'RP2350 Arm (Pico 2 W)'))
    w('EnableExplicit')
    w('; Q marker for "the previous instruction did not write F": a value the')
    w('; budget counter never holds (keep Z80Run budgets below it).')
    w('#Z80_QNONE = $7FFFFFFF')
    w('Global Dim Z80Mem.a(65536)')
    w('CompilerIf #Z80_MEM_HOOKS = 1')
    w('  Global Dim Z80PageRd.a(256)')
    w('  Global Dim Z80PageWr.a(256)')
    w('CompilerEndIf')
    for t in ('Base', 'CB', 'ED', 'DD', 'FD'):
        w('Global Dim Z80Op%s.Label(256)' % t)
    w('Global Dim Z80OpXCB.Label(32)')
    w('Global Dim Z80OpXCopy.Label(16)')
    w('Global Dim Z80SZ53.a(256)')
    w('Global Dim Z80SZ53P.a(256)')
    w('Global Dim Z80IncF.a(256)')
    w('Global Dim Z80DecF.a(256)')
    w('Global Dim Z80HVC.a(32)')
    w('Global Dim Z80HVCN.a(32)')
    w('Global Z80PC.i, Z80A.i, Z80F.i, Z80Left.i')
    w('Global Z80BC.i, Z80DE.i, Z80HL.i, Z80IX.i, Z80IY.i, Z80SP.i, Z80WZ.i')
    w('Global Z80AF2.i, Z80BC2.i, Z80DE2.i, Z80HL2.i')
    w('Global Z80I.i, Z80R7.i, Z80RCnt.i, Z80ICount.i, Z80IM.i, Z80IFF1.i, Z80IFF2.i')
    w('Global Z80Halted.i, Z80IntLine.i, Z80IntData.i, Z80NmiLine.i, Z80EiShadow.i')
    w('Global Z80Stopped.i, Z80Error.i, Z80TStates.i, Z80QLast.i')
    w('Global Z80Budget.i, Z80Saved.i, Z80Ready.i, Z80InitI.i')
    w(cfg['reserve'])
    w('')
    w(LIB_TEXT)
    w(run_text(cfg, base, ix, ixpass, iy, iypass, cb, ed, xcb, xcopy))
    path = os.path.join(ROOT, cfg['out'])
    with open(path, 'w', newline='\n') as f:
        f.write('\n'.join(x for x in o if x is not None) + '\n')
    nh = sum(len(pg.handlers) for pg in (base, ix, iy, cb, ed, xcb, xcopy))
    print('%s: %d handlers' % (cfg['out'], nh))


LIB_TEXT = r'''; ---- flag tables, reset, interrupts ------------------------------------
Procedure Z80InitTables()
  Protected i.i, j.i, p.i, f.i
  For i = 0 To 255
    p = 0
    For j = 0 To 7
      p = p ! ((i >> j) & 1)
    Next
    f = (i & $A8)
    If i = 0
      f = f | 64
    EndIf
    Z80SZ53(i) = f
    If p = 0
      Z80SZ53P(i) = f | 4
    Else
      Z80SZ53P(i) = f
    EndIf
    f = Z80SZ53(i)
    If (i & 15) = 0
      f = f | 16
    EndIf
    If i = $80
      f = f | 4
    EndIf
    Z80IncF(i) = f
    f = Z80SZ53(i) | 2
    If (i & 15) = 15
      f = f | 16
    EndIf
    If i = $7F
      f = f | 4
    EndIf
    Z80DecF(i) = f
  Next
  ; H|V|C from bits 4..8 of (a ! b ! result): bit 0 is H (carry into bit 4),
  ; bit 4 is C (carry out of bit 7), bit 3 ! bit 4 is V.
  For i = 0 To 31
    f = (i & 1) << 4
    f = f | ((i >> 4) & 1)
    If (((i >> 3) ! (i >> 4)) & 1) <> 0
      f = f | 4
    EndIf
    Z80HVC(i) = f
    Z80HVCN(i) = f | 2
  Next
EndProcedure

; Power-on state. Memory is not touched.
Procedure Z80Reset()
  If Z80Ready = 0
    Z80InitTables()
  EndIf
  Z80PC = 0 : Z80SP = $FFFF : Z80A = $FF : Z80F = $FF
  Z80BC = 0 : Z80DE = 0 : Z80HL = 0 : Z80IX = $FFFF : Z80IY = $FFFF
  Z80AF2 = $FFFF : Z80BC2 = 0 : Z80DE2 = 0 : Z80HL2 = 0 : Z80WZ = 0
  Z80I = 0 : Z80R7 = 0 : Z80RCnt = 0 : Z80ICount = 0 : Z80IM = 0
  Z80IFF1 = 0 : Z80IFF2 = 0 : Z80Halted = 0 : Z80EiShadow = 0
  Z80IntLine = 0 : Z80IntData = $FF : Z80NmiLine = 0
  Z80Stopped = 0 : Z80Error = 0 : Z80TStates = 0 : Z80QLast = 0
EndProcedure

; Maskable interrupt request with the byte the device puts on the bus
; (the IM 2 vector low byte, or an RST opcode for IM 0). It is held until
; the CPU accepts it, then cleared (HOLD_LINE). Z80IntClear() drops it.
Procedure Z80IntRequest(data.i)
  Z80IntData = data & 255
  Z80IntLine = 1
EndProcedure
Procedure Z80IntClear()
  Z80IntLine = 0
EndProcedure
; Non-maskable interrupt (edge): accepted at the next instruction boundary
; Z80Run reaches.
Procedure Z80NmiRequest()
  Z80NmiLine = 1
EndProcedure

; The R register as the CPU would read it now.
Procedure.i Z80GetR()
  CompilerIf #Z80_TIMED = 1
    ProcedureReturn ((Z80RCnt + Z80ICount) & 127) | Z80R7
  CompilerElse
    ProcedureReturn (Z80RCnt & 127) | Z80R7
  CompilerEndIf
EndProcedure
Procedure Z80SetR(v.i)
  Z80R7 = v & 128
  CompilerIf #Z80_TIMED = 1
    Z80RCnt = (v & 127) - Z80ICount
  CompilerElse
    Z80RCnt = v & 127
  CompilerEndIf
EndProcedure
'''


def tail_lines(cfg, table, kind, groups=False):
    """Dispatch through Z80Op<table> using the byte at PC (PC advanced)."""
    if cfg['pc_low']:
        asm = ['ASM Uses Z80PC',
               '  ldr r1, =global_z80mem',
               '  ldrb r2, [r1, r4]',
               '  adds r4, #1',
               '  uxth r4, r4'] + (['  lsrs r2, r2, #3'] if groups else []) + [
               '  lsls r2, r2, #2',
               '  ldr r1, =global_z80op%s' % table.lower(),
               '  ldr r1, [r1, r2]',
               '  bx r1',
               'EndASM']
    return asm


def nextop(c, fl):
    """End of an instruction costing c T-states: count it, stop when the
    budget is spent, else dispatch the next opcode. fl: it wrote F, so Q = F."""
    o = []
    if fl:
        o += ['CompilerIf #Z80_Q = 1',
              '  CompilerIf #Z80_TIMED = 1',
              '    qm = Z80Left - %d' % c,
              '  CompilerElse',
              '    qm = Z80Left - 1',
              '  CompilerEndIf',
              'CompilerEndIf']
    o += ['CompilerIf #Z80_SHARED_TAIL = 1',
          '  CompilerIf #Z80_TIMED = 1',
          '    CompilerIf #Z80_ASM_TAIL = 1',
          '      ASM Uses Z80Left',
          '        mov r0, r11',
          '        subs r0, #%d' % c,
          '        mov r11, r0',
          '        ble __ul_z80run_donecnt',
          '      EndASM',
          '    CompilerElse',
          '      Z80Left = Z80Left - %d' % c,
          '      If Z80Left <= 0',
          '        Goto DoneCnt',
          '      EndIf',
          '    CompilerEndIf',
          '    Goto DispShared',
          '  CompilerElse',
          '    Goto NextShared',
          '  CompilerEndIf',
          'CompilerElse',
          'CountInsn()',
          'CompilerIf #Z80_ASM_TAIL = 1',
          '  CompilerIf #Z80_TIMED = 1',
          '    ASM Uses Z80Left',
          '      mov r0, r11',
          '      subs r0, #%d' % c,
          '      mov r11, r0',
          '      ble __ul_z80run_done',
          '    EndASM',
          '  CompilerElse',
          '    ASM Uses Z80Left',
          '      mov r0, r11',
          '      subs r0, #1',
          '      mov r11, r0',
          '      beq __ul_z80run_done',
          '    EndASM',
          '  CompilerEndIf',
          'CompilerElse',
          '  CompilerIf #Z80_TIMED = 1',
          '    Z80Left = Z80Left - %d' % c,
          '    If Z80Left <= 0',
          '      Goto Done',
          '    EndIf',
          '  CompilerElse',
          '    Z80Left = Z80Left - 1',
          '    If Z80Left = 0',
          '      Goto Done',
          '    EndIf',
          '  CompilerEndIf',
          'CompilerEndIf',
          'DispatchBase()',
          'CompilerEndIf']
    return o


def run_text(cfg, base, ix, ixpass, iy, iypass, cb, ed, xcb, xcopy):
    o = []
    w = o.append
    w('''; ---- the run loop --------------------------------------------------------
; Z80Run(n): run until n budget units are used (T-states when #Z80_TIMED = 1,
; whole instructions otherwise). Returns the units used, which can exceed n
; by the remainder of the last instruction (timed). Interrupt requests are
; sampled on entry, after the instruction that follows EI, and after HALT.
ProcedureRAM.i Z80Run(n.i)
  Protected op.i, t.i, v.i, ea.i, r.i, n2.i, qm.i
''')
    # macros
    for tbl in ('Base', 'CB', 'ED', 'DD', 'FD', 'XCB'):
        w('Macro Dispatch%s()' % tbl)
        xg = tbl == 'XCB'
        w('  CompilerIf #Z80_ASM_TAIL = 1')
        for s in tail_lines(cfg, tbl, 'op', xg):
            w('    ' + s)
        w('  CompilerElse')
        w('    op = Z80Mem(Z80PC)')
        w('    Z80PC = (Z80PC + 1) & $FFFF')
        w('    Goto Z80Op%s(op%s)' % (tbl, ' >> 3' if xg else ''))
        w('  CompilerEndIf')
        w('EndMacro')
    w('''Macro Charge(c)
  CompilerIf #Z80_TIMED = 1
    Z80Left = Z80Left - (c)
  CompilerEndIf
EndMacro
Macro CountInsn()
  CompilerIf #Z80_TIMED = 1
    CompilerIf #Z80_TRACK_R = 1
      Z80ICount = Z80ICount + 1
    CompilerEndIf
  CompilerEndIf
EndMacro
; X/Y of SCF/CCF: (Q ! F) | A. Q is F when the previous instruction wrote F.
Macro QXY(dst)
  CompilerIf #Z80_Q = 1
    If qm = Z80Left
      dst = Z80A & $28
    Else
      dst = (Z80F | Z80A) & $28
    EndIf
  CompilerElse
    dst = (Z80F | Z80A) & $28
  CompilerEndIf
EndMacro
Macro MemRd(dst, adr)
  CompilerIf #Z80_MEM_HOOKS = 1
    If Z80PageRd((adr) >> 8) <> 0
      dst = Z80MemRead(adr) & 255
    Else
      dst = Z80Mem(adr)
    EndIf
  CompilerElse
    dst = Z80Mem(adr)
  CompilerEndIf
EndMacro
Macro MemWr(adr, val)
  CompilerIf #Z80_MEM_HOOKS = 1
    If Z80PageWr((adr) >> 8) <> 0
      Z80MemWrite(adr, val)
    Else
      Z80Mem(adr) = val
    EndIf
  CompilerElse
    Z80Mem(adr) = val
  CompilerEndIf
EndMacro
Macro RGet(dst)
  CompilerIf #Z80_TIMED = 1
    CompilerIf #Z80_TRACK_R = 1
      dst = ((Z80RCnt + Z80ICount + 1) & 127) | Z80R7
    CompilerElse
      Z80Error = 3
      Z80Stopped = 1
      Z80PC = (Z80PC - 2) & $FFFF
      Goto Done
    CompilerEndIf
  CompilerElse
    dst = ((Z80RCnt + (Z80Budget - Z80Left - Z80Saved) + 1) & 127) | Z80R7
  CompilerEndIf
EndMacro
Macro RSet(val)
  Z80R7 = (val) & 128
  CompilerIf #Z80_TIMED = 1
    Z80RCnt = ((val) & 127) - Z80ICount - 1
  CompilerElse
    Z80RCnt = ((val) & 127) - (Z80Budget - Z80Left - Z80Saved) - 1
  CompilerEndIf
EndMacro
''')
    # ---- prologue
    w('  If Z80Ready = 0')
    w('    Z80InitTables()')
    for g in range(32):
        w('    Z80OpXCB(%d) = ?%s' % (g, xcb.entries[g]))
    for k in range(16):
        w('    Z80OpXCopy(%d) = ?%s' % (k, xcopy.entries[k]))
    for pg, tbl in ((base, 'Base'), (cb, 'CB')):
        for op in range(256):
            w('    Z80Op%s(%d) = ?%s' % (tbl, op, pg.entries[op]))
    w('    For Z80InitI = 0 To 255')
    w('      Z80OpED(Z80InitI) = ?EDNop')
    w('    Next')
    for op in sorted(ed.entries):
        w('    Z80OpED(%d) = ?%s' % (op, ed.entries[op]))
    for pg, pas, tbl in ((ix, ixpass, 'DD'), (iy, iypass, 'FD')):
        w('    For Z80InitI = 0 To 255')
        w('      CompilerIf #Z80_TIMED = 1')
        w('        Z80Op%s(Z80InitI) = ?XPass' % tbl)
        w('      CompilerElse')
        w('        Z80Op%s(Z80InitI) = Z80OpBase(Z80InitI)' % tbl)
        w('      CompilerEndIf')
        w('    Next')
        for op in sorted(pg.entries):
            w('    Z80Op%s(%d) = ?%s' % (tbl, op, pg.entries[op]))
    w('    Z80Ready = 1')
    w('  EndIf')
    w('''  If n <= 0 Or n >= #Z80_QNONE
    ProcedureReturn 0
  EndIf
  If Z80Stopped <> 0
    ProcedureReturn 0
  EndIf
  Z80Budget = n
  Z80Left = n
  Z80Saved = 0
  CompilerIf #Z80_Q = 1
    If Z80QLast <> 0
      qm = n
    Else
      qm = #Z80_QNONE
    EndIf
  CompilerEndIf
  If Z80EiShadow <> 0
    ; The instruction after EI runs before any interrupt is sampled.
    Z80EiShadow = 0
    If n > 1
      Z80Saved = n - 1
      Z80Left = 1
      CompilerIf #Z80_Q = 1
        If qm <> #Z80_QNONE
          qm = 1
        EndIf
      CompilerEndIf
    EndIf
    DispatchBase()
  EndIf
Resume:
  ; ---- interrupt acceptance at an instruction boundary
  If Z80NmiLine <> 0
    Z80NmiLine = 0
    Z80Halted = 0
    Z80IFF2 = Z80IFF1
    Z80IFF1 = 0
    Z80RCnt = Z80RCnt + 1
    n2 = Z80PC''')
    w('\n'.join('    ' + s for s in push16('n2')))
    w('''    Z80PC = $66
    Z80WZ = Z80PC
    CompilerIf #Z80_TIMED = 1
      Z80Left = Z80Left - 11
    CompilerEndIf
    qm = #Z80_QNONE
  ElseIf (Z80IntLine <> 0) And (Z80IFF1 <> 0)
    Z80IntLine = 0
    Z80Halted = 0
    Z80IFF1 = 0
    Z80IFF2 = 0
    Z80RCnt = Z80RCnt + 1
    n2 = Z80PC''')
    w('\n'.join('    ' + s for s in push16('n2')))
    w('''    If Z80IM = 2
      ea = (Z80I << 8) | Z80IntData''')
    w('\n'.join('      ' + s for s in rd16('n2', 'ea')))
    w('''      Z80PC = n2
      CompilerIf #Z80_TIMED = 1
        Z80Left = Z80Left - 19
      CompilerEndIf
    ElseIf Z80IM = 1
      Z80PC = $38
      CompilerIf #Z80_TIMED = 1
        Z80Left = Z80Left - 13
      CompilerEndIf
    Else
      If (Z80IntData & $C7) = $C7
        Z80PC = Z80IntData & $38
        CompilerIf #Z80_TIMED = 1
          Z80Left = Z80Left - 13
        CompilerEndIf
      Else
        ; IM 0 with a data byte that is not RST: not modelled. Stop loudly.
        Z80SP = (Z80SP + 2) & $FFFF
        Z80Error = 2
        Z80Stopped = 1
        Goto Done
      EndIf
    EndIf
    Z80WZ = Z80PC
    qm = #Z80_QNONE
  EndIf
  If Z80Halted <> 0
    ; HALT executes NOPs (4 T-states, one R step each) until an interrupt.
    If Z80Left > 0
      CompilerIf #Z80_TIMED = 1
        t = (Z80Left + 3) >> 2
        Z80RCnt = Z80RCnt + t
        Z80Left = Z80Left - (t << 2)
      CompilerElse
        Z80Left = 0
      CompilerEndIf
    EndIf
    qm = #Z80_QNONE
    Goto Done
  EndIf
  If Z80Left <= 0
    Goto Done
  EndIf
  DispatchBase()
''')
    # ---- prefix handlers
    w('''; Shared instruction tails (#Z80_SHARED_TAIL = 1): one copy of the dispatch.
NextShared:
  CompilerIf #Z80_ASM_TAIL = 1
    ASM Uses Z80Left
      mov r0, r11
      subs r0, #1
      mov r11, r0
      beq __ul_z80run_done
    EndASM
  CompilerElse
    Z80Left = Z80Left - 1
    If Z80Left = 0
      Goto Done
    EndIf
  CompilerEndIf
DispShared:
  CountInsn()
  DispatchBase()
; Shared timed tail: the instruction that spent the budget, counted here.
DoneCnt:
  CountInsn()
  Goto Done
PfxCB:
  Z80RCnt = Z80RCnt + 1
  DispatchCB()
PfxED:
  Z80RCnt = Z80RCnt + 1
  DispatchED()
PfxDD:
  qm = #Z80_QNONE   ; the prefix is an M1 that writes no flags: Q = 0
  Z80RCnt = Z80RCnt + 1
  DispatchDD()
PfxFD:
  qm = #Z80_QNONE   ; the prefix is an M1 that writes no flags: Q = 0
  Z80RCnt = Z80RCnt + 1
  DispatchFD()
; A prefix after DD/FD: the first one was a 4 T-state NOP.
PfxDDc:
  qm = #Z80_QNONE   ; the prefix is an M1 that writes no flags: Q = 0
  Charge(4)
  Z80RCnt = Z80RCnt + 1
  DispatchDD()
PfxFDc:
  qm = #Z80_QNONE   ; the prefix is an M1 that writes no flags: Q = 0
  Charge(4)
  Z80RCnt = Z80RCnt + 1
  DispatchFD()
PfxEDc:
  Charge(4)
  Z80RCnt = Z80RCnt + 1
  DispatchED()
; DD/FD before an opcode that does not use HL: the base opcode plus 4 T.
XPass:
  Charge(4)
  op = Z80Mem((Z80PC - 1) & $FFFF)
  Goto Z80OpBase(op)
PfxXCBIX:
  ea = (Z80IX + PeekB(@Z80Mem(0) + Z80PC)) & $FFFF
  Z80PC = (Z80PC + 1) & $FFFF
  Z80WZ = ea
  DispatchXCB()
PfxXCBIY:
  ea = (Z80IY + PeekB(@Z80Mem(0) + Z80PC)) & $FFFF
  Z80PC = (Z80PC + 1) & $FFFF
  Z80WZ = ea
  DispatchXCB()
EDNop: ; undefined ED xx: an 8 T-state NOP''')
    w(chr(10).join('  ' + x for x in nextop(8, False)))
    for pg in (base, ix, iy, cb, ed, xcb, xcopy):
        for (label, cmt, lines, cyc, fl, tail) in pg.handlers:
            w('%s: ; %s' % (label, cmt))
            for s in lines:
                for s2 in s.split('\n'):
                    w('  ' + s2)
            if tail == 'goto':
                pass
            elif tail == 'halt':
                w('  Charge(%d)' % cyc)
                w('  CountInsn()')
                w('  CompilerIf #Z80_TIMED = 0')
                w('    Z80Left = Z80Left - 1')
                w('  CompilerEndIf')
                w('  qm = #Z80_QNONE')
                w('  Goto Resume')
            elif tail == 'ei':
                # Arm the window split so that exactly one more instruction
                # runs before Done samples the interrupt lines.
                w('  If (Z80IntLine <> 0) Or (Z80NmiLine <> 0)')
                w('    CompilerIf #Z80_TIMED = 1')
                w('      t = Z80Left - %d' % cyc)
                w('      If t > 0')
                w('        Z80Saved = Z80Saved + Z80Left - %d' % (cyc + 1))
                w('        Z80Left = %d' % (cyc + 1))
                w('      Else')
                w('        Z80EiShadow = 1')
                w('      EndIf')
                w('    CompilerElse')
                w('      If Z80Left > 1')
                w('        Z80Saved = Z80Saved + Z80Left - 2')
                w('        Z80Left = 2')
                w('      Else')
                w('        Z80EiShadow = 1')
                w('      EndIf')
                w('    CompilerEndIf')
                w('  EndIf')
                w(chr(10).join('  ' + x for x in nextop(cyc, False)))
            else:
                w(chr(10).join('  ' + x for x in nextop(cyc, fl)))
    w('''Done:
  If Z80Saved <> 0
    ; End of an EI window split: give back the budget and sample interrupts.
    CompilerIf #Z80_Q = 1
      If qm = Z80Left
        qm = Z80Left + Z80Saved
      Else
        qm = #Z80_QNONE
      EndIf
    CompilerEndIf
    Z80Left = Z80Left + Z80Saved
    Z80Saved = 0
    If Z80Stopped = 0
      If Z80Left > 0
        Goto Resume
      EndIf
    EndIf
  EndIf
  CompilerIf #Z80_Q = 1
    If qm = Z80Left
      Z80QLast = 1
    Else
      Z80QLast = 0
    EndIf
  CompilerEndIf
  t = Z80Budget - Z80Left
  CompilerIf #Z80_TIMED = 1
    Z80TStates = Z80TStates + t
    Z80RCnt = Z80RCnt + Z80ICount
    Z80ICount = 0
  CompilerElse
    Z80RCnt = Z80RCnt + t
  CompilerEndIf
  ProcedureReturn t
EndProcedure
''')
    return '\n'.join(o)


if __name__ == '__main__':
    for t in (sys.argv[1:] or TARGETS.keys()):
        emit(t)
