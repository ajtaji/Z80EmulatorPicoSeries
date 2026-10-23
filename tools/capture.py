#!/usr/bin/env python3
"""Read a board's USB serial port until a line matches a pattern.
Usage: capture.py PORT MAX_SECONDS REGEX LOGFILE
Waits up to 30 s for the port to appear (after an upload), raises DTR so the
program's UsbSerialReady() sees a reader, and prints every line it gets."""
import re
import sys
import time
import serial

port, maxs, pat, log = sys.argv[1], float(sys.argv[2]), re.compile(sys.argv[3]), sys.argv[4]
t0 = time.time()
ser = None
while time.time() - t0 < 30:
    try:
        ser = serial.Serial(port, 115200, timeout=1)
        break
    except serial.SerialException:
        time.sleep(0.5)
if ser is None:
    print('capture: %s never appeared within 30 s' % port)
    sys.exit(2)
ser.dtr = True
buf = b''
found = 1
with open(log, 'a', encoding='utf-8') as fh:
    while time.time() - t0 < maxs:
        data = ser.read(4096)
        if not data:
            continue
        buf += data
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            text = line.decode('utf-8', 'replace').rstrip('\r')
            print(text, flush=True)
            fh.write(text + '\n')
            fh.flush()
            if pat.search(text):
                found = 0
                break
        if found == 0:
            break
ser.close()
if found:
    print('capture: no line matched within %d s' % maxs)
sys.exit(found)
