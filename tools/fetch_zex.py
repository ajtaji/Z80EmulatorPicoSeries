#!/usr/bin/env python3
"""Fetch ZEXDOC and ZEXALL, check them, and embed them for the test programs.

The exercisers are Frank D. Cringle's (Copyright (C) 1994, GNU GPL v2 or
later). They are not part of this repository: this tool downloads them from a
public copy, refuses any file whose SHA-256 differs from tests/upstream/sha256.txt,
and then runs tools/embed_zex.py, which writes tests/zex_data.pico and
tests/zex_data.pico2 (needed by tests/zex.pico*w and the desktop build).

    py -3 tools/fetch_zex.py              # download, verify, embed
    py -3 tools/fetch_zex.py --from DIR   # use zexdoc.com / zexall.com you already have
"""
import hashlib
import os
import shutil
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UP = os.path.join(ROOT, 'tests', 'upstream')
SOURCE = 'https://raw.githubusercontent.com/anotherlin/z80emu/master/testfiles/'
FILES = ['zexdoc.com', 'zexall.com', 'zexdoc.z80', 'zexall.z80']


def expected():
    sums = {}
    for line in open(os.path.join(UP, 'sha256.txt')):
        h, name = line.split()
        sums[os.path.basename(name.lstrip('*'))] = h
    return sums


def main():
    sums = expected()
    src_dir = sys.argv[sys.argv.index('--from') + 1] if '--from' in sys.argv else None
    for name in FILES:
        dst = os.path.join(UP, name)
        if src_dir:
            p = os.path.join(src_dir, name)
            if not os.path.exists(p):
                if name.endswith('.z80'):
                    continue          # the sources are optional
                raise SystemExit('%s not found in %s' % (name, src_dir))
            shutil.copyfile(p, dst)
        elif not os.path.exists(dst):
            print('downloading', SOURCE + name)
            with urllib.request.urlopen(SOURCE + name) as r:
                open(dst, 'wb').write(r.read())
        h = hashlib.sha256(open(dst, 'rb').read()).hexdigest()
        if h != sums[name]:
            os.remove(dst)
            raise SystemExit('%s has SHA-256 %s, expected %s: not the exerciser this '
                             'repository was tested with; removed.' % (name, h, sums[name]))
        print('ok', name, h[:16])
    subprocess.check_call([sys.executable, os.path.join(ROOT, 'tools', 'embed_zex.py')])


if __name__ == '__main__':
    main()
