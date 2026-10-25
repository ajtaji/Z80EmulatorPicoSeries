"""Cortex-M33 (Thumb-2) bodies for the hottest Z80 handlers, used by
tools/gen_z80.py for the RP2350 build only (the RP2040 keeps the PureMetal
handlers, byte for byte).

Each body is the WHOLE handler: operands, result, flags, the Q marker, the
budget step and the dispatch tail, in one ASM block per build variant
(#Z80_TIMED x #Z80_TRACK_R x #Z80_Q). The semantics are exactly the PureMetal
handler's, which stays in the #Z80_ASM_TAIL = 0 build.

Registers: r4 Z80PC, r5 Z80F, r8 Z80A, r9 Z80QM (the Q marker), r10 Z80ICount,
r11 Z80Left; r0-r3 scratch.
"""

import os
import re

LDRPC = os.environ.get('Z80_T2_LDRPC', '1') == '1'

PAIR = {'B': ('bc', 1), 'C': ('bc', 0), 'D': ('de', 1), 'E': ('de', 0), 'H': ('hl', 1), 'L': ('hl', 0)}
R8 = ['B', 'C', 'D', 'E', 'H', 'L', '(HL)', 'A']
CC = ['NZ', 'Z', 'NC', 'C', 'PO', 'PE', 'P', 'M']
# condition -> (flag mask, branch-if-NOT-taken mnemonic after tst)
CCTEST = {'NZ': (64, 'bne'), 'Z': (64, 'beq'), 'NC': (1, 'bne'), 'C': (1, 'beq'),
          'PO': (4, 'bne'), 'PE': (4, 'beq'), 'P': (128, 'bne'), 'M': (128, 'beq')}


def get(r, dst='r0'):
    if r == 'A':
        return ['mov %s, r8' % dst]
    pair, off = PAIR[r]
    return ['ldr r3, =global_z80%s' % pair, 'ldrb %s, [r3, #%d]' % (dst, off)]


def put(r, src='r0'):
    if r == 'A':
        return ['mov r8, %s' % src]
    pair, off = PAIR[r]
    return ['ldr r3, =global_z80%s' % pair, 'strb %s, [r3, #%d]' % (src, off)]


def fetch_imm(dst='r0'):
    return ['ldr r3, =global_z80mem', 'ldrb %s, [r3, r4]' % dst, 'adds r4, #1', 'uxth r4, r4']


def tail(timed, track, q, cost, flags, done='done'):
    """Budget step, Q, count, dispatch."""
    o = []
    if timed and track:
        o.append('add r10, r10, #1')
    o.append('subs.w r11, r11, #%d' % (cost if timed else 1))
    if q and flags:
        o.append('mov r9, r11')
    o.append('%s __ul_z80run_%s' % ('ble' if timed else 'beq', done))
    o += ['ldr r1, =global_z80mem', 'ldrb r2, [r1, r4]', 'adds r4, #1', 'uxth r4, r4',
          'ldr r1, =global_z80opbase'] + (['ldr pc, [r1, r2, lsl #2]'] if LDRPC else
                                          ['ldr r1, [r1, r2, lsl #2]', 'bx r1'])
    return o


def alu(op, v='r0'):
    """A = A op v (v in r0). Result flags into r5."""
    if op in ('ADD', 'ADC', 'SUB', 'SBC', 'CP'):
        o = []
        sub = op in ('SUB', 'SBC', 'CP')
        if op in ('ADC', 'SBC'):
            o.append('and r3, r5, #1')
        o.append('%s r1, r8, %s' % ('sub' if sub else 'add', v))
        if op in ('ADC', 'SBC'):
            o.append('%s r1, r1, r3' % ('sub' if sub else 'add'))
        o += ['eor r2, r8, %s' % v, 'eor r2, r2, r1', 'ubfx r2, r2, #4, #5',
              'ldr r3, =global_z80hvc%s' % ('n' if sub else ''), 'ldrb r2, [r3, r2]',
              'uxtb r1, r1', 'ldr r3, =global_z80sz53', 'ldrb r3, [r3, r1]']
        if op == 'CP':
            o += ['and r3, r3, #215', 'and r0, %s, #40' % v, 'orr r3, r3, r0', 'orr r5, r2, r3']
        else:
            o += ['orr r5, r2, r3', 'mov r8, r1']
        return o
    ins = {'AND': 'and', 'XOR': 'eor', 'OR': 'orr'}[op]
    o = ['%s r1, r8, %s' % (ins, v), 'mov r8, r1', 'ldr r3, =global_z80sz53p', 'ldrb r5, [r3, r1]']
    if op == 'AND':
        o.append('orr r5, r5, #16')
    return o


def body(kind, args):
    """(body lines, cost, sets flags, extra) for one handler, or None."""
    if kind == 'alu':
        op, r = args
        o = (fetch_imm() if r == 'n' else get(r)) + alu(op)
        return o, (7 if r == 'n' else 4), True
    if kind == 'incdec':
        op, r = args
        o = get(r) + ['%s r0, r0, #1' % ('add' if op == 'INC' else 'sub'), 'uxtb r0, r0',
                      'and r5, r5, #1', 'ldr r3, =global_z80%s' % ('incf' if op == 'INC' else 'decf'),
                      'ldrb r2, [r3, r0]', 'orr r5, r5, r2'] + put(r)
        return o, 4, True
    if kind == 'ld':
        dst, src = args
        if dst == src:
            return [], 4, False
        return get(src) + put(dst), 4, False
    if kind == 'ldn':
        (dst,) = args
        return fetch_imm() + put(dst), 7, False
    return None


def pagecheck(table, ea, label):
    """Branch to the handler's PureMetal body when ea's page has a hook."""
    return ['lsrs r2, %s, #8' % ea, 'ldr r3, =global_z80page%s' % table, 'ldrb r2, [r3, r2]',
            'cmp r2, #0', 'bne __ul_z80run_%s_pm' % label.lower()]


def pairload(pair, dst):
    return ['ldr r3, =global_z80%s' % pair.lower(), 'ldr %s, [r3]' % dst]


def mem_body(kind, args, label, hooks):
    """Handlers that touch memory or 16-bit registers: (lines, cost, flags)."""
    rd = (lambda ea: pagecheck('rd', ea, label)) if hooks else (lambda ea: [])
    wr = (lambda ea: pagecheck('wr', ea, label)) if hooks else (lambda ea: [])
    mem = ['ldr r3, =global_z80mem']
    if kind == 'ldrhl':
        (r,) = args
        return pairload('HL', 'r1') + rd('r1') + mem + ['ldrb r0, [r3, r1]'] + put(r), 7, False
    if kind == 'sthl':
        (r,) = args
        return pairload('HL', 'r1') + wr('r1') + get(r) + mem + ['strb r0, [r3, r1]'], 7, False
    if kind == 'aluhl':
        (op,) = args
        return pairload('HL', 'r1') + rd('r1') + mem + ['ldrb r0, [r3, r1]'] + alu(op), 7, True
    if kind == 'ldapair':
        (pair,) = args
        return (pairload(pair, 'r1') + rd('r1') + mem + ['ldrb r0, [r3, r1]', 'mov r8, r0',
                'adds r2, r1, #1', 'uxth r2, r2', 'ldr r3, =global_z80wz', 'str r2, [r3]'], 7, False)
    if kind == 'stapair':
        (pair,) = args
        return (pairload(pair, 'r1') + wr('r1') + mem + ['mov r0, r8', 'strb r0, [r3, r1]',
                'adds r2, r1, #1', 'uxtb r2, r2', 'orr r2, r2, r8, lsl #8', 'ldr r3, =global_z80wz', 'str r2, [r3]'], 7, False)
    if kind == 'incrr':
        op, pair = args
        return (['ldr r3, =global_z80%s' % pair.lower(), 'ldr r0, [r3]',
                 '%s r0, #1' % ('adds' if op == 'INC' else 'subs'), 'uxth r0, r0', 'str r0, [r3]'], 6, False)
    if kind == 'ldrr':
        (pair,) = args
        return (['ldr r3, =global_z80mem', 'ldrb r0, [r3, r4]', 'adds r4, #1', 'uxth r4, r4',
                 'ldrb r1, [r3, r4]', 'adds r4, #1', 'uxth r4, r4', 'orr r0, r0, r1, lsl #8',
                 'ldr r3, =global_z80%s' % pair.lower(), 'str r0, [r3]'], 10, False)
    if kind == 'exdehl':
        return (['ldr r3, =global_z80de', 'ldr r0, [r3]', 'ldr r2, =global_z80hl', 'ldr r1, [r2]',
                 'str r1, [r3]', 'str r0, [r2]'], 4, False)
    if kind == 'jp':
        return (['ldr r3, =global_z80mem', 'ldrb r0, [r3, r4]', 'adds r4, #1', 'uxth r4, r4',
                 'ldrb r1, [r3, r4]', 'orr r4, r0, r1, lsl #8', 'ldr r3, =global_z80wz', 'str r4, [r3]'], 10, False)
    # the stack: check both pages first, so the PureMetal body can start from scratch
    if kind in ('push', 'call'):
        o = ['ldr r3, =global_z80sp', 'ldr r1, [r3]', 'subs r1, #1', 'uxth r1, r1']   # r1 = SP - 1
        if hooks:
            o += pagecheck('wr', 'r1', label) + ['subs r0, r1, #1', 'uxth r0, r0'] + pagecheck('wr', 'r0', label)
        if kind == 'push':
            (pair,) = args
            if pair == 'AF':
                o += ['lsl r0, r8, #8', 'orr r0, r0, r5']
            else:
                o += pairload(pair, 'r0')
            cost = 11
        else:
            # CALL nn: operand, then the return address is the PC after it
            o += ['ldr r3, =global_z80mem', 'ldrb r0, [r3, r4]', 'adds r4, #1', 'uxth r4, r4',
                  'ldrb r2, [r3, r4]', 'adds r4, #1', 'uxth r4, r4', 'orr r2, r0, r2, lsl #8',
                  'ldr r3, =global_z80wz', 'str r2, [r3]', 'mov r0, r4', 'mov r4, r2']
            cost = 17
        o += ['ldr r3, =global_z80mem', 'lsrs r2, r0, #8', 'strb r2, [r3, r1]', 'subs r1, #1', 'uxth r1, r1',
              'strb r0, [r3, r1]', 'ldr r3, =global_z80sp', 'str r1, [r3]']
        return o, cost, False
    if kind in ('pop', 'ret'):
        o = ['ldr r3, =global_z80sp', 'ldr r1, [r3]']
        if hooks:
            o += pagecheck('rd', 'r1', label) + ['adds r0, r1, #1', 'uxth r0, r0'] + pagecheck('rd', 'r0', label)
        o += ['ldr r3, =global_z80mem', 'ldrb r0, [r3, r1]', 'adds r1, #1', 'uxth r1, r1', 'ldrb r2, [r3, r1]',
              'adds r1, #1', 'uxth r1, r1', 'ldr r3, =global_z80sp', 'str r1, [r3]', 'orr r0, r0, r2, lsl #8']
        if kind == 'ret':
            return o + ['mov r4, r0', 'ldr r3, =global_z80wz', 'str r0, [r3]'], 10, False
        (pair,) = args
        if pair == 'AF':
            return o + ['lsrs r8, r0, #8', 'and r5, r0, #255'], 10, False
        return o + ['ldr r3, =global_z80%s' % pair.lower(), 'str r0, [r3]'], 10, False
    if kind == 'ldhln':
        return (pairload('HL', 'r1') + wr('r1') + ['ldr r3, =global_z80mem', 'ldrb r0, [r3, r4]', 'adds r4, #1',
                'uxth r4, r4', 'strb r0, [r3, r1]'], 10, False)
    if kind == 'incdechl':
        (op,) = args
        o = pairload('HL', 'r1')
        if hooks:
            o += pagecheck('rd', 'r1', label) + pagecheck('wr', 'r1', label)
        o += ['ldr r3, =global_z80mem', 'ldrb r0, [r3, r1]', '%s r0, r0, #1' % ('add' if op == 'INC' else 'sub'),
              'uxtb r0, r0', 'strb r0, [r3, r1]', 'and r5, r5, #1',
              'ldr r3, =global_z80%s' % ('incf' if op == 'INC' else 'decf'), 'ldrb r2, [r3, r0]', 'orr r5, r5, r2']
        return o, 11, True
    return None


MEMKINDS = ('ldrhl', 'sthl', 'aluhl', 'ldapair', 'stapair', 'push', 'pop', 'call', 'ret', 'ldhln', 'incdechl')
REGKINDS16 = ('incrr', 'ldrr', 'exdehl', 'jp')


def jump(kind, args, label, timed, track, q):
    """JR e / JR cc,e / DJNZ: two paths with their own budget step."""
    nt = 'z80t2_%s_nt' % label.lower()
    taken = ['ldr r3, =global_z80mem', 'ldrsb r0, [r3, r4]', 'adds r4, #1', 'add r4, r4, r0',
             'uxth r4, r4', 'ldr r3, =global_z80wz', 'str r4, [r3]']
    skip = ['adds r4, #1', 'uxth r4, r4']
    if kind == 'jr':
        return taken + tail(timed, track, q, 12, False)
    if kind == 'jrcc':
        (c,) = args
        mask, br = CCTEST[c]
        return (['tst r5, #%d' % mask, '%s %s' % (br, nt)] + taken + tail(timed, track, q, 12, False) +
                ['%s:' % nt] + skip + tail(timed, track, q, 7, False))
    if kind == 'djnz':
        return (['ldr r3, =global_z80bc', 'ldrb r0, [r3, #1]', 'sub r0, r0, #1', 'uxtb r0, r0',
                 'strb r0, [r3, #1]', 'cmp r0, #0', 'beq %s' % nt] + taken + tail(timed, track, q, 13, False) +
                ['%s:' % nt] + skip + tail(timed, track, q, 8, False))
    return None


def classify(op):
    """Base-page opcode -> (kind, args) for the ones with a Thumb-2 body."""
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    ALU = ['ADD', 'ADC', 'SUB', 'SBC', 'AND', 'XOR', 'OR', 'CP']
    if x == 2 and z != 6:
        return 'alu', (ALU[y], R8[z])
    if x == 3 and z == 6:
        return 'alu', (ALU[y], 'n')
    if x == 0 and z in (4, 5) and y != 6:
        return 'incdec', ('INC' if z == 4 else 'DEC', R8[y])
    if x == 1 and y != 6 and z != 6:
        return 'ld', (R8[y], R8[z])
    if x == 0 and z == 6 and y != 6:
        return 'ldn', (R8[y],)
    if op == 0x18:
        return 'jr', ()
    if x == 0 and z == 0 and y >= 4:
        return 'jrcc', (CC[y - 4],)
    if op == 0x10:
        return 'djnz', ()
    RP = ['BC', 'DE', 'HL', 'SP']
    RP2 = ['BC', 'DE', 'HL', 'AF']
    if x == 1 and z == 6 and y != 6:
        return 'ldrhl', (R8[y],)
    if x == 1 and y == 6 and z != 6:
        return 'sthl', (R8[z],)
    if x == 2 and z == 6:
        return 'aluhl', (ALU[y],)
    if op in (0x0A, 0x1A):
        return 'ldapair', ('BC' if op == 0x0A else 'DE',)
    if op in (0x02, 0x12):
        return 'stapair', ('BC' if op == 0x02 else 'DE',)
    if x == 0 and z == 3:
        return 'incrr', ('INC' if (y & 1) == 0 else 'DEC', RP[y >> 1])
    if x == 0 and z == 1 and (y & 1) == 0:
        return 'ldrr', (RP[y >> 1],)
    if op == 0xEB:
        return 'exdehl', ()
    if op == 0xC3:
        return 'jp', ()
    if x == 3 and z == 5 and (y & 1) == 0:
        return 'push', (RP2[y >> 1],)
    if x == 3 and z == 1 and (y & 1) == 0:
        return 'pop', (RP2[y >> 1],)
    if op == 0xCD:
        return 'call', ()
    if op == 0xC9:
        return 'ret', ()
    if op == 0x36:
        return 'ldhln', ()
    if op in (0x34, 0x35):
        return 'incdechl', ('INC' if op == 0x34 else 'DEC',)
    return None


def variants(op, label):
    """The handler's ASM text for every build variant, wrapped in CompilerIf,
    or None when the opcode keeps its PureMetal body. A handler that touches
    memory has a #Z80_MEM_HOOKS dimension too: with hooks, an address on a
    hooked page sends it to its PureMetal body (label <handler>_pm)."""
    cl = classify(op)
    if cl is None:
        return None
    kind, args = cl
    memk = kind in MEMKINDS

    def block(timed, track, q, hooks):
        if kind in ('jr', 'jrcc', 'djnz'):
            lines = jump(kind, args, label, timed, track, q)
        elif kind in MEMKINDS or kind in REGKINDS16:
            b, cost, fl = mem_body(kind, args, label, hooks)
            lines = b + tail(timed, track, q, cost, fl)
        else:
            b, cost, fl = body(kind, args)
            lines = b + tail(timed, track, q, cost, fl)
        text = chr(10).join(lines)
        named = [('Z80PC', 'r4'), ('Z80F', 'r5'), ('Z80A', 'r8'), ('Z80QM', 'r9'),
                 ('Z80ICount', 'r10'), ('Z80Left', 'r11')]
        uses = [u for u, reg in named if re.search(r'\b' + reg + r'\b', text)]
        return ['ASM Uses ' + ', '.join(uses)] + ['  ' + l for l in lines] + ['EndASM']

    def tree(dims, fixed):
        if not dims:
            return block(fixed.get('timed', False), fixed.get('track', False),
                         fixed.get('q', False), fixed.get('hooks', False))
        name, const = dims[0]
        if name == 'track' and not fixed.get('timed'):
            return tree(dims[1:], dict(fixed, track=False))
        yes = tree(dims[1:], dict(fixed, **{name: True}))
        no = tree(dims[1:], dict(fixed, **{name: False}))
        return (['CompilerIf %s = 1' % const] + ['  ' + l for l in yes] + ['CompilerElse'] +
                ['  ' + l for l in no] + ['CompilerEndIf'])

    dims = [('timed', '#Z80_TIMED'), ('track', '#Z80_TRACK_R'), ('q', '#Z80_Q')]
    if memk:
        dims.append(('hooks', '#Z80_MEM_HOOKS'))
    return tree(dims, {})
