# Z80 on the desktop — PureBasic + Neon Arcade Display Engine

The Pico's Z80 core, on Windows: a PureBasic (C back end, x64) program with a
Neon Arcade Display Engine front end, and console programs that run the
board's own test suites and benchmarks.

## Same core, same API

`z80core.pbi` is **generated** by `tools/gen_z80_desktop.py` from the same
handler text as `src/z80.pico` (`tools/gen_z80.py`). Only dispatch differs:
the `.Label` tables become static C arrays of label addresses inside `Z80Run`,
and a computed jump is `! goto *z80_base[g_z80dop];`. Do not edit it; after any
change to `tools/gen_z80.py`, run `py -3 tools/gen_z80_desktop.py`
(`build_console.ps1` refuses a stale core).

The API is the Pico core's (README.md at the repo root), with the same names
and meaning: `Z80Mem.a(65536)`, `Z80PageRd/Z80PageWr.a(256)` with
`Z80MemRead(addr)`/`Z80MemWrite(addr, value)`, `Z80PortIn(port)`/
`Z80PortOut(port, value)` (port = the 16-bit bus value), `Z80Reset()`,
`Z80Run(n)`, `Z80IntRequest(byte)`/`Z80IntClear()`/`Z80NmiRequest()`,
`Z80GetR()`/`Z80SetR()`, and the register Globals. The core `Declare`s the
hooks, so a machine may define them anywhere (and may Declare them again).
Define `#Z80_TIMED`, `#Z80_SHARED_TAIL`, `#Z80_MEM_HOOKS`, `#Z80_Q` and
`#Z80_TRACK_R` before the include; there is no `#Z80_ASM_TAIL` here.
`Z80Run(1)` runs exactly one instruction in either build (single step).
`z80disasm.pbi` gives `Z80Disasm(addr, @length)` for any machine.

## Programs

| File | What |
|---|---|
| `z80_desktop.exe` | the window: a CP/M-style machine (`.COM` at 100h, BDOS 2 and 9, warm boot = HALT at 0; any other file raw at 0), registers and flags, disassembly with click-to-break, memory, the CP/M console, Run / Stop / Step / Step 100 / Break at, Run tests (SST + API), ZEXDOC and ZEXALL built in, full speed or a real-time 4 MHz |
| `z80_console.exe` | `--test` (SST, API, ZEXDOC, ZEXALL), `--quick`, `--bench`, `--distest`, `--zex <0/1> [first last]`, `--run <file.com>` |
| `z80_console_untimed.exe` | the same, untimed build |
| `z80_console_procs*.exe` | the procedure-table core, kept only for the dispatch measurement |

Window options: `--show-tests`, `--zexdoc`, `--zexall`, `--run`,
`--screenshot <png>` with `--shot-after <frames>` (0 = when the program stops).

Build (PowerShell, not Git Bash, which mangles `/CONSOLE`):

```powershell
.\desktop\build.ps1      # all programs; the engine beside this repo, or at $env:NEON_ENGINE_DIR
```

## Results (i9-11900K, Windows, `/OPTIMIZER`)

`docs/desktop-tests.log`, `docs/desktop-dispatch-bench.log`, and the window's
own pictures `docs/desktop-window-tests.png` and `docs/desktop-window-zexall.png`.

| Suite | timed build | untimed build |
|---|---|---|
| SingleStepTests, 8,020 vectors | 0 failures | 0 failures |
| API / interrupt checks | 19 of 19 | 18 of 18 |
| ZEXDOC | 67 of 67 OK, 13.1 s | 67 of 67 OK, 13.1 s |
| ZEXALL | 67 of 67 OK, 13.2 s | 67 of 67 OK, 13.2 s |
| Disassembler, 40 known encodings | pass | |

The same suites in the window: Run tests passes, and ZEXALL runs to its warm
boot with every test OK (`docs/desktop-window-zexall.png`).

### Dispatch: labels as values beats a procedure table

The same handlers built both ways (`tools/gen_z80_desktop_procs.py` makes the
procedure-table core, which passes every suite too):

| | labels as values | procedure table |
|---|---:|---:|
| ZEXDOC, emulated MHz (timed) | 3,442-3,572 | 2,398 |
| ZEXDOC, M instructions/s (untimed) | 443-484 | 311 |
| register/branch, M instr/s | 304-317 | 246-263 |
| ALU | 476-494 | 267-310 |
| memory | 521-524 | 350-406 |
| LDIR repeats | 174-185 | 132-162 |
| indexed | 392-398 | 280-327 |
| call/stack | 415-435 | 252-257 |

The window keeps up about 1,700-2,200 emulated MHz while it draws.
