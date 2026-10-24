#!/usr/bin/env python3
"""Generate desktop/z80core.pbi: the same Z80 core as src/z80.pico, for
PureBasic x64 (C back end) on the PC.

The handler text is the Pico core's, from tools/gen_z80.py; this tool only
changes how dispatch is written:
  - ProcedureRAM -> Procedure, no ReserveRegister, no inline assembly;
  - the .Label tables become static C arrays of label addresses inside
    Z80Run (PureBasic names a procedure label ll_<procedure>_<label>), and a
    computed jump is "! goto *z80_<page>[g_z80dop];" (labels as values);
  - the machine's hooks are Declared, so it may define them after the include.
Every rewrite must match the expected number of times, or the tool stops.

    py -3 tools/gen_z80_desktop.py          # writes desktop/z80core.pbi
    py -3 tools/gen_z80_desktop.py --check  # fails if it is stale
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_z80 as g  # noqa: E402

OUT = os.path.join(g.ROOT, 'desktop', 'z80core.pbi')


def strip_asm_branches(lines):
    """Keep only the CompilerElse part of every 'CompilerIf #Z80_ASM_TAIL = 1'."""
    out = []
    i = 0
    n = 0
    while i < len(lines):
        if lines[i].strip() == 'CompilerIf #Z80_ASM_TAIL = 1':
            n += 1
            depth, j = 0, i + 1
            els = end = None
            while j < len(lines):
                s = lines[j].strip()
                if s.startswith('CompilerIf '):
                    depth += 1
                elif s == 'CompilerEndIf':
                    if depth == 0:
                        end = j
                        break
                    depth -= 1
                elif s == 'CompilerElse' and depth == 0:
                    els = j
                j += 1
            if end is None or els is None:
                raise SystemExit('unbalanced #Z80_ASM_TAIL block at line %d' % (i + 1))
            out.extend(strip_asm_branches(lines[els + 1:end]))
            i = end + 1
            continue
        out.append(lines[i])
        i += 1
    return out


def must(text, old, new, count=1):
    k = text.count(old)
    if k != count:
        raise SystemExit('rewrite expected %d match(es), found %d: %r' % (count, k, old[:70]))
    return text.replace(old, new)


def c_table(name, labels):
    rows = ['! static void *%s[%d] = {' % (name, len(labels))]
    for i in range(0, len(labels), 8):
        part = ', '.join('&&ll_z80run_%s' % l.lower() for l in labels[i:i + 8])
        rows.append('!   %s%s' % (part, ',' if i + 8 < len(labels) else ''))
    rows.append('! };')
    return rows


def lib_text():
    # "Data" is a PureBasic keyword.
    t = must(g.LIB_TEXT, 'Procedure Z80IntRequest(data.i)\n  Z80IntData = data & 255',
             'Procedure Z80IntRequest(busbyte.i)\n  Z80IntData = busbyte & 255')
    return t


def build():
    cfg = dict(g.TARGETS['pico'])
    base, _ = g.build_main(None)
    ix, ixpass = g.build_main('IX')
    iy, iypass = g.build_main('IY')
    cb = g.build_cb()
    ed = g.build_ed()
    xcb, xcopy = g.build_xcb()
    run = g.run_text(cfg, base, ix, ixpass, iy, iypass, cb, ed, xcb, xcopy)

    lines = strip_asm_branches(run.split('\n'))
    text = '\n'.join(lines)

    # Drop the .Label table set-up: the tables are static C arrays below.
    a = text.index('  If Z80Ready = 0\n    Z80InitTables()\n')
    b = text.index('    Z80Ready = 1\n  EndIf\n', a)
    text = text[:a] + '  If Z80Ready = 0\n    Z80InitTables()\n' + text[b:]

    # Dispatch macros: written out in place, since a "!" line belongs at
    # the statement level of the procedure.
    for tbl in ('Base', 'CB', 'ED', 'DD', 'FD', 'XCB'):
        m = re.search(r'Macro Dispatch%s\(\)\n(.*?)EndMacro\n' % tbl, text, re.S)
        if not m:
            raise SystemExit('no Dispatch%s macro' % tbl)
        text = text[:m.start()] + text[m.end():]
    idx = {'Base': 'g_z80dop', 'CB': 'g_z80dop', 'ED': 'g_z80dop', 'DD': 'g_z80dop',
           'FD': 'g_z80dop', 'XCB': 'g_z80dop >> 3'}

    def dispatch(mo):
        ind, tbl = mo.group(1), mo.group(2)
        return ('%sZ80DOp = Z80Mem(Z80PC)\n%sZ80PC = (Z80PC + 1) & $FFFF\n! goto *z80_%s[%s];'
                % (ind, ind, tbl.lower(), idx[tbl]))
    text, k = re.subn(r'^( *)Dispatch(Base|CB|ED|DD|FD|XCB)\(\)$', dispatch, text, flags=re.M)
    if k < 700:
        raise SystemExit('only %d dispatch sites rewritten' % k)

    text = must(text, '  op = Z80Mem((Z80PC - 1) & $FFFF)\n  Goto Z80OpBase(op)',
                '  Z80DOp = Z80Mem((Z80PC - 1) & $FFFF)\n! goto *z80_base[g_z80dop];')
    text, k = re.subn(r'^( *)Goto Z80OpXCopy\(op\)$', r'\1Z80DOp = op\n! goto *z80_xcopy[g_z80dop];', text, flags=re.M)
    if k != 24:
        raise SystemExit('XCopy jumps: %d, expected 24' % k)
    if 'Goto Z80Op' in text or '.Label' in text or 'ASM ' in text:
        raise SystemExit('a Pico-only construct survived the rewrite')

    # The tables, at the top of Z80Run.
    tables = []
    tables += c_table('z80_base', [base.entries[o] for o in range(256)])
    tables += c_table('z80_cb', [cb.entries[o] for o in range(256)])
    tables += c_table('z80_ed', [ed.entries.get(o, 'EDNop') for o in range(256)])
    for pg, nm in ((ix, 'z80_dd'), (iy, 'z80_fd')):
        tables += ['CompilerIf #Z80_TIMED = 1']
        tables += c_table(nm, [pg.entries.get(o, 'XPass') for o in range(256)])
        tables += ['CompilerElse']
        tables += c_table(nm, [pg.entries.get(o, base.entries[o]) for o in range(256)])
        tables += ['CompilerEndIf']
    tables += c_table('z80_xcb', [xcb.entries[gx] for gx in range(32)])
    tables += c_table('z80_xcopy', [xcopy.entries[k] for k in range(16)])
    text = must(text, '  Protected op.i, t.i, v.i, ea.i, r.i, n2.i, qm.i\n',
                '  Protected op.i, t.i, v.i, ea.i, r.i, n2.i, qm.i\n' + '\n'.join(tables) + '\n')
    text = must(text, 'ProcedureRAM.i Z80Run(n.i)', 'Procedure.i Z80Run(n.i)')
    # PureBasic macros are global: RSet/RGet would hide PureBasic's RSet().
    for old, new, k in (('RSet(', 'Z80RSetM(', 2), ('RGet(', 'Z80RGetM(', 2)):
        text, n = re.subn(r'\b' + re.escape(old), new, text)
        if n != k:
            raise SystemExit('%s: %d matches, expected %d' % (old, n, k))

    head = g.HEADER % dict(target='the PC (PureBasic x64, C back end)')
    head = must(head, '; Generated by tools/gen_z80.py. Edit the generator, then regenerate.',
                '; Generated by tools/gen_z80_desktop.py from the handlers of tools/gen_z80.py.\n'
                '; Edit the generator, then regenerate. Same core as src/z80.pico.')
    head = must(head, ';   #Z80_ASM_TAIL  = 1  inline-assembly dispatch tail; 0 plain computed Goto.\n',
                ';   (no #Z80_ASM_TAIL here: dispatch is labels-as-values through the C back end)\n')
    o = [head,
         'EnableExplicit',
         '#Z80_QNONE = $7FFFFFFF',
         'Global Dim Z80Mem.a(65536)',
         'CompilerIf #Z80_MEM_HOOKS = 1',
         '  Global Dim Z80PageRd.a(256)',
         '  Global Dim Z80PageWr.a(256)',
         '  Declare.i Z80MemRead(addr.i)',
         '  Declare Z80MemWrite(addr.i, value.i)',
         'CompilerEndIf',
         'Declare.i Z80PortIn(port.i)',
         'Declare Z80PortOut(port.i, value.i)',
         'Global Dim Z80SZ53.a(256)', 'Global Dim Z80SZ53P.a(256)',
         'Global Dim Z80IncF.a(256)', 'Global Dim Z80DecF.a(256)',
         'Global Dim Z80HVC.a(32)', 'Global Dim Z80HVCN.a(32)',
         'Global Z80PC.i, Z80A.i, Z80F.i, Z80Left.i',
         'Global Z80BC.i, Z80DE.i, Z80HL.i, Z80IX.i, Z80IY.i, Z80SP.i, Z80WZ.i',
         'Global Z80AF2.i, Z80BC2.i, Z80DE2.i, Z80HL2.i',
         'Global Z80I.i, Z80R7.i, Z80RCnt.i, Z80ICount.i, Z80IM.i, Z80IFF1.i, Z80IFF2.i',
         'Global Z80Halted.i, Z80IntLine.i, Z80IntData.i, Z80NmiLine.i, Z80EiShadow.i',
         'Global Z80Stopped.i, Z80Error.i, Z80TStates.i, Z80QLast.i',
         'Global Z80Budget.i, Z80Saved.i, Z80Ready.i, Z80InitI.i',
         'Global Z80DOp.i   ; the byte a computed jump indexes with',
         '',
         lib_text(),
         text]
    pages = dict(base=base, ix=ix, iy=iy, cb=cb, ed=ed, xcb=xcb, xcopy=xcopy)
    return '\n'.join(o) + '\n', o[:-1], text, pages


if __name__ == '__main__':
    out = build()[0]
    if '--check' in sys.argv:
        cur = open(OUT, encoding='utf-8').read() if os.path.exists(OUT) else ''
        if cur != out:
            raise SystemExit('desktop/z80core.pbi is stale: run py -3 tools/gen_z80_desktop.py')
        print('desktop/z80core.pbi is current')
    else:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT, 'w', newline='\n', encoding='utf-8') as f:
            f.write(out)
        print('wrote', OUT, len(out.split('\n')), 'lines')
