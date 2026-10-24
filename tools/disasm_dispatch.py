#!/usr/bin/env python3
"""Disassemble handlers straight from a built UF2 (the bytes that are flashed,
not the listing). Usage: disasm_dispatch.py <image.uf2> <label> [label]...
Addresses come from the build's <image>.uf2.sym; Capstone decodes Thumb."""
import struct
import sys
import capstone

uf2, labels = sys.argv[1], sys.argv[2:]
img = {}
data = open(uf2, 'rb').read()
for o in range(0, len(data), 512):
    addr, size = struct.unpack_from('<II', data, o + 12)
    for i in range(size):
        img[addr + i] = data[o + 32 + i]
sym = {}
for line in open(uf2 + '.sym'):
    if '=' in line:
        k, v = line.strip().split('=', 1)
        if v.isdigit():
            sym[k] = int(v)
# Z80Run is ProcedureRAM: the .sym gives its SRAM layout as offsets from
# 0x10000000 (Z80Run itself), and the startup copy's source sits somewhere in
# flash. Find that source: the place where the handlers that follow an
# assembly tail start right after its "bx r1" (0x4708).
tails = [v - 0x10000000 for k, v in sym.items() if k.startswith('__ul_z80run_op')]
lo = min(img)
best, score = None, 0
for base in range(lo, lo + 0x40000, 2):
    n = 0
    for t in tails[:40]:
        if img.get(base + t - 2) == 0x08 and img.get(base + t - 1) == 0x47:
            n += 1
    if n > score:
        best, score = base, n
print('Z80Run copy source in flash: 0x%08X (%d of %d handler starts follow bx r1); runs at 0x20000000' % (best, score, min(40, len(tails))))
md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_THUMB | capstone.CS_MODE_MCLASS)
for lab in labels:
    off = sym['__ul_z80run_' + lab] - 0x10000000
    code = bytes(img.get(best + off + i, 0) for i in range(400))
    print('%s at 0x%08X in SRAM (flash 0x%08X)' % (lab, 0x20000000 + off, best + off))
    for ins in md.disasm(code, 0x20000000 + off):
        print('  %08X  %-8s %-24s %s' % (ins.address, ins.bytes.hex(), ins.mnemonic, ins.op_str))
        if ins.mnemonic == 'bx' and ins.op_str == 'r1':
            break
