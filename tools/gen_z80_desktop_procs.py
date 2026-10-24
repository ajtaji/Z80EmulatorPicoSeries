#!/usr/bin/env python3
"""The procedure-table variant of the desktop core, for the dispatch
measurement the desktop brief asked for: desktop/z80core_procs.pbi.

The same handler text as desktop/z80core.pbi (built by gen_z80_desktop.py),
but every handler is its own procedure, called through tables of procedure
addresses from a fetch loop, and Z80Run's locals are Globals. Same API.

    py -3 tools/gen_z80_desktop_procs.py
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_z80_desktop as d  # noqa: E402

OUTP = os.path.join(d.g.ROOT, 'desktop', 'z80core_procs.pbi')
LOCALS = ['op', 't', 'v', 'ea', 'r', 'n2', 'qm']
NAMES = {'base': 'Z80PBase', 'cb': 'Z80PCB', 'ed': 'Z80PED', 'dd': 'Z80PDD', 'fd': 'Z80PFD',
         'xcb': 'Z80PXCB', 'xcopy': 'Z80PXCopy'}


def globalise(line):
    """Z80Run's locals become Globals (each handler is its own procedure)."""
    st = line.lstrip()
    if st.startswith('!') or st.startswith(';'):
        return line
    code, sep, cmt = line.partition(';')
    for name in LOCALS:
        code = re.sub(r'(?<![\w@#$.])%s\b(?!\()' % name, 'Z80L_' + name, code)
    return code + sep + cmt


def keep_else(lines, cond):
    """Keep only the CompilerElse part of every 'CompilerIf <cond>'."""
    out, i = [], 0
    while i < len(lines):
        if lines[i].strip() == cond:
            depth, j, els, end = 0, i + 1, None, None
            while j < len(lines):
                st = lines[j].strip()
                if st.startswith('CompilerIf '):
                    depth += 1
                elif st == 'CompilerEndIf':
                    if depth == 0:
                        end = j
                        break
                    depth -= 1
                elif st == 'CompilerElse' and depth == 0:
                    els = j
                j += 1
            if els is None or end is None:
                raise SystemExit('unbalanced ' + cond)
            out.extend(keep_else(lines[els + 1:end], cond))
            i = end + 1
            continue
        out.append(lines[i])
        i += 1
    return out


def jump(tbl, ix):
    return 'CallFunctionFast(%s(%s))' % (NAMES[tbl], ix.replace('g_z80dop', 'Z80DOp'))


def build_procs():
    _, head_lines, text, pages = d.build()
    L = [ln for ln in text.split('\n')
         if not (ln.strip().startswith('! static') or ln.strip().startswith('!   &&') or ln.strip() == '! };')]
    text = d.must('\n'.join(L), 'CompilerIf #Z80_TIMED = 1\nCompilerElse\nCompilerEndIf\n', '', 2)
    text = d.must(text, '  Protected op.i, t.i, v.i, ea.i, r.i, n2.i, qm.i\n', '')
    L = keep_else(text.split('\n'), 'CompilerIf #Z80_SHARED_TAIL = 1')
    a = L.index('Procedure.i Z80Run(n.i)')
    macros_end = next(k for k in range(a, len(L)) if L[k] == '  If Z80Ready = 0')
    first_handler = next(k for k in range(a, len(L)) if L[k] == 'NextShared:')
    done = L.index('Done:')
    macros, prologue = L[a + 1:macros_end], L[macros_end:first_handler]
    handlers, epilogue = L[first_handler:done], L[done:]

    # one procedure per handler label
    procs, cur, body = [], None, []
    label_re = re.compile(r'^([A-Za-z]\w*):( ;.*)?$')
    for ln in handlers:
        m = label_re.match(ln)
        if m:
            if cur:
                procs.append((cur, body))
            cur, body = m.group(1), []
        elif cur:
            body.append(ln)
    procs.append((cur, body))
    out = []
    for name, body in procs:
        if name in ('NextShared', 'DispShared', 'DoneCnt'):
            continue
        out.append('Procedure Z80P_%s()' % name)
        for k, ln in enumerate(body):
            st = ln.strip()
            mo = re.match(r'^! goto \*z80_(\w+)\[(.*)\];$', st)
            ind = ln[:len(ln) - len(ln.lstrip())] or '  '
            if mo:
                tbl, ix = mo.group(1), mo.group(2)
                if tbl == 'base' and k >= 2 and body[k - 2].strip() == 'Z80DOp = Z80Mem(Z80PC)':
                    out.pop()
                    out.pop()          # the fetch loop fetches the next opcode
                    out.append('  ProcedureReturn')
                else:
                    out.append('  ' + jump(tbl, ix))
            elif st == 'Goto Done':
                out += [ind + 'Z80Brk = 1', ind + 'ProcedureReturn']
            elif st == 'Goto Resume':
                out += [ind + 'Z80Brk = 2', ind + 'ProcedureReturn']
            elif st.startswith('Goto '):
                raise SystemExit('%s: unexpected %s' % (name, st))
            else:
                out.append(globalise(ln))
        out.append('EndProcedure')

    pro = '\n'.join(globalise(x) for x in prologue)
    pro, k = re.subn(r'\n( *)Z80DOp = Z80Mem\(Z80PC\)\n *Z80PC = \(Z80PC \+ 1\) & \$FFFF\n! goto \*z80_base\[g_z80dop\];',
                     r'\n\1Goto FetchLoop', pro)
    if k != 2:
        raise SystemExit('driver dispatch sites: %d' % k)
    init = []
    for tbl, pg in (('base', pages['base']), ('cb', pages['cb'])):
        init += ['    %s(%d) = @Z80P_%s()' % (NAMES[tbl], o, pg.entries[o]) for o in range(256)]
    init += ['    Z80PED(%d) = @Z80P_%s()' % (o, pages['ed'].entries.get(o, 'EDNop')) for o in range(256)]
    for tbl, pg in (('dd', pages['ix']), ('fd', pages['iy'])):
        for o in range(256):
            if o in pg.entries:
                init.append('    %s(%d) = @Z80P_%s()' % (NAMES[tbl], o, pg.entries[o]))
            else:
                init += ['    CompilerIf #Z80_TIMED = 1',
                         '      %s(%d) = @Z80P_XPass()' % (NAMES[tbl], o),
                         '    CompilerElse',
                         '      %s(%d) = @Z80P_%s()' % (NAMES[tbl], o, pages['base'].entries[o]),
                         '    CompilerEndIf']
    init += ['    Z80PXCB(%d) = @Z80P_%s()' % (gx, pages['xcb'].entries[gx]) for gx in range(32)]
    init += ['    Z80PXCopy(%d) = @Z80P_%s()' % (kx, pages['xcopy'].entries[kx]) for kx in range(16)]
    pro = d.must(pro, '  If Z80Ready = 0\n    Z80InitTables()\n',
                 '  If Z80Ready = 0\n    Z80InitTables()\n' + '\n'.join(init) + '\n')
    drv = ['Procedure.i Z80Run(n.i)', pro,
           'FetchLoop:',
           '  Repeat',
           '    Z80DOp = Z80Mem(Z80PC)',
           '    Z80PC = (Z80PC + 1) & $FFFF',
           '    CallFunctionFast(Z80PBase(Z80DOp))',
           '  Until Z80Left <= 0 Or Z80Brk <> 0',
           '  If Z80Brk = 2',
           '    Z80Brk = 0',
           '    Goto Resume',
           '  EndIf',
           '  Z80Brk = 0']
    drv += [globalise(x) for x in epilogue]
    mac = [globalise(x).replace('Goto Done', 'Z80Brk = 1 : ProcedureReturn') for x in macros]
    head = list(head_lines)
    head[0] = '; PROCEDURE-TABLE VARIANT, for the dispatch measurement only.\n' + head[0]
    res = head + ['Global Z80L_op.i, Z80L_t.i, Z80L_v.i, Z80L_ea.i, Z80L_r.i, Z80L_n2.i, Z80L_qm.i, Z80Brk.i',
                  'Global Dim Z80PBase.i(256), Dim Z80PCB.i(256), Dim Z80PED.i(256), Dim Z80PDD.i(256)',
                  'Global Dim Z80PFD.i(256), Dim Z80PXCB.i(32), Dim Z80PXCopy.i(16)'] + mac + out + drv
    return '\n'.join(res) + '\n'


if __name__ == '__main__':
    txt = build_procs()
    with open(OUTP, 'w', newline='\n', encoding='utf-8') as f:
        f.write(txt)
    print('wrote', OUTP, len(txt.split('\n')), 'lines')
