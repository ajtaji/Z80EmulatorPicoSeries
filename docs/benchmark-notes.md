# Benchmark notes (Pico W, 200 MHz, COM7)

## Register move tried and reverted (2026-10-23 18:32)

`Z80Left` from r11 to r6, `@Z80Mem(0)` held in r9 and `@Z80OpBase(0)` in r11
(two fewer instructions per budget step, two literal loads fewer per dispatch).
Untimed, per-handler tails, 1,000,000 instructions per sample:

| Mix | r4 r5 r8 r10 r11 (kept) | + r6 r9 r11 move |
|---|---:|---:|
| register/branch | 4,082,432 | 4,073,021 |
| alu | 3,651,100 | 3,564,338 |
| memory | 5,013,637 | 4,595,968 |
| ldir | 1,177,327 | 1,070,297 |
| indexed | 3,619,804 | 3,402,784 |
| call/stack | 2,626,636 | 2,254,420 |

Taking r6 out of the register allocator's pool costs more in the handlers'
own code than the tail saves. Raw log: `benchmark-register-move-r6-r9-r11.log`.
(Left-hand column: the 17:18 run, which already had the H/V/C table but not
two later Q fixes and the inlining of one ALU temporary; those touch only
SCF/CCF, DD/FD prefixes and the ALU group, and cannot explain the memory and
call/stack losses. The final table in README.md is measured on the final core.)
