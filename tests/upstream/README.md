# Test inputs from elsewhere

- `zexdoc.com`, `zexall.com`, `zexdoc.z80`, `zexall.z80`: the Z80 instruction
  exercisers, Copyright (C) 1994 Frank D. Cringle, GNU GPL v2 or later (see the
  header of each `.z80`). Fetched 2026-10-23 from
  `github.com/anotherlin/z80emu` `testfiles/`.
  SHA-256 sums: `sha256.txt`.
- `sst/head/*.json`: the first 16 KB of each of the 1,604 opcode files of
  SingleStepTests/z80 `v1/` (MIT, `licenses/SingleStepTests-MIT.txt`),
  fetched 2026-10-23 with HTTP range requests. `tools/embed_sst.py` takes
  the first five complete vectors of each.
