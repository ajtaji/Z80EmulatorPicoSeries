# Z80 on the Pico series — PureMetal

A Zilog Z80 (NMOS) CPU core for the Raspberry Pi Pico W (RP2040) and Pico 2 W
(RP2350, Arm), written in PureMetal. One SRAM-resident procedure, `Z80Run`,
dispatches through 256-entry `.Label` tables (base, CB, ED, DD, FD) and a
32-entry DDCB/FDCB group table; every handler ends in its own computed-jump
tail (or a shared one, `#Z80_SHARED_TAIL = 1`).

Covered: every documented and undocumented opcode (IXH/IXL/IYH/IYL, SLL,
DDCB/FDCB register copies, ED mirrors), undocumented X/Y flags, MEMPTR (WZ),
the Q latch behind SCF/CCF's X/Y bits, block instructions including the
repeat-interrupted X/Y/H/P flag behaviour, IM 0/1/2, NMI, HALT, the EI delay,
the R register, and T-state counts (switchable timed / untimed build).

Generated source: `src/z80.pico` (Pico W) and `src/z80.pico2` (Pico 2 W),
from `tools/gen_z80.py`. Edit the generator, then `py -3 tools/gen_z80.py`.

## Using the core (the API)

Define every switch, then include the core:

```text
#Z80_TIMED       = 1   ; Z80Run's budget and result are T-states (0: whole instructions)
#Z80_ASM_TAIL    = 1   ; inline-assembly dispatch tail (0: plain computed Goto)
#Z80_SHARED_TAIL = 0   ; 1: one shared tail - smaller SRAM code, slightly slower
#Z80_MEM_HOOKS   = 1   ; per-page data read/write hooks (0: flat 64 KB only)
#Z80_Q           = 1   ; model Q for SCF/CCF X/Y (0: X/Y = (F | A), saves a store per flag op)
#Z80_TRACK_R     = 1   ; exact R in timed builds (0: LD A,R stops the CPU, Z80Error = 3)
XIncludeFile "z80.pico"          ; z80.pico2 on the Pico 2 W
```

PureMetal has no `Defined()`, so a missing switch is a compile error naming it.

The core holds five Globals in registers for the whole program:
**r4 `Z80PC`, r5 `Z80F`, r8 `Z80A`, r10 `Z80ICount`, r11 `Z80Left`**. A
machine must not reserve those registers, and keeps the CPU on one core.

### The machine supplies

```text
Procedure.i Z80PortIn(port.i)            ; return 0..255
Procedure Z80PortOut(port.i, value.i)
; only with #Z80_MEM_HOOKS = 1:
ProcedureRAM.i Z80MemRead(addr.i)        ; return 0..255
ProcedureRAM Z80MemWrite(addr.i, value.i)
```

`port` is the full 16-bit address bus value, as on the chip: `IN A,(n)` and
`OUT (n),A` put A on the high byte (`A << 8 | n`), `IN r,(C)`/`OUT (C),r` and
the block I/O instructions put BC. Pac-Man hardware sets its IM 2 vector with
`OUT (0),A`: test `port & 255`.

Mark the memory hooks `ProcedureRAM`: `Z80Run` is in SRAM, and a call from
SRAM into flash is a long call through a veneer.

### Memory

- `Z80Mem.a(65536)` is the flat 64 KB the CPU sees. **Opcode and operand
  fetches always read `Z80Mem` directly**, never a hook.
- With `#Z80_MEM_HOOKS = 1`, `Z80PageRd.a(256)` and `Z80PageWr.a(256)` flag
  256-byte pages (index `addr >> 8`). A data read from a flagged page calls
  `Z80MemRead(addr)`; a data write to a flagged page calls
  `Z80MemWrite(addr, value)` and does not touch `Z80Mem` (the hook decides:
  ignore a ROM write, latch an I/O register, write a mirror). Unflagged pages
  are plain `Z80Mem` reads and writes. Stack pushes and pops are data
  accesses and go through the hooks.
- ROM banking or overlays: copy the bytes into `Z80Mem`. Fetches cannot be
  trapped, so a latch that real hardware toggles on an opcode fetch (the
  Ms. Pac-Man auxiliary board's decode latch) is the machine's to emulate,
  for example by applying the overlay permanently or between `Z80Run` calls.

### Running and interrupts

```text
Z80Reset()                 ; power-on state (PC 0, SP $FFFF, AF $FFFF, IM 0, DI); memory untouched
used = Z80Run(n)           ; run n T-states (timed) or n instructions (untimed)
Z80IntRequest(data)        ; INT held until accepted, then cleared (HOLD_LINE)
Z80IntClear()              ; drop a request that was never accepted
Z80NmiRequest()            ; NMI (edge)
r = Z80GetR() : Z80SetR(r) ; R outside Z80Run
```

- `Z80Run` returns the units actually used. A timed run can end up to one
  instruction past `n`; carry the overshoot into the next frame. `Z80TStates`
  accumulates every T-state run (timed builds).
- `data` is the byte on the bus at acknowledge: the low byte of the IM 2
  vector address (`I << 8 | data`), or an RST opcode in IM 0. IM 0 with any
  byte other than an RST stops the CPU (`Z80Stopped = 1`, `Z80Error = 2`) —
  that form is not modelled. IM 1 is RST 38h.
- Requests are sampled when `Z80Run` starts, after the instruction that
  follows `EI` (the window is split there and resumed), and when `HALT`
  executes. A request raised by a hook inside a run is seen at the next of
  those points.
- `HALT` executes NOPs (4 T-states and one R step each) for the rest of the
  run; `Z80Halted` is 1 until an interrupt is accepted. The return address
  pushed is the instruction after `HALT`.
- Registers are Globals: `Z80PC Z80SP Z80A Z80F Z80BC Z80DE Z80HL Z80IX
  Z80IY Z80WZ Z80AF2 Z80BC2 Z80DE2 Z80HL2 Z80I Z80IM Z80IFF1 Z80IFF2`
  (pairs hold 0..65535; the primed AF is `A << 8 | F`).

## Verification

See `docs/` for the captured board logs. All runs are on the physical
Pico W (COM7, 200 MHz); no host emulator executes the firmware.

- `tests/sst.picow`: 8,020 SingleStepTests one-instruction vectors (the first
  five of each of the 1,604 opcode files, `tests/upstream/sst`, MIT), in four
  batches: every register, R, WZ, Q, IFF1/2, IM, memory, port traffic and the
  T-state count of each instruction (timed build).
- `tests/zex.picow`: ZEXDOC and ZEXALL (Frank D. Cringle, GPL v2,
  `tests/upstream`) under a minimal CP/M BDOS (functions 2 and 9 through
  `OUT (0),A` at `$FE00`, warm boot = `HALT` at 0).

## Building

```text
tools/build.ps1 -Source tests/zex.picow -Output build/zex.uf2      # build only
tools/board.sh tests/zex.picow build/zex.uf2 600                    # build, upload, capture (shared COM7 lease)
```

`build.ps1` refuses any image that reaches flash `0x10050000` (the NES ROM
store) before uploading.

Original code: MIT. Test inputs keep their own licences (`tests/upstream`).
