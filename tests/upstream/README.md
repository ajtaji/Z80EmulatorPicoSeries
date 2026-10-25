# Test inputs from elsewhere

- **ZEXDOC / ZEXALL** (`zexdoc.com`, `zexall.com`): the Z80 instruction
  exercisers, Copyright (C) 1994 Frank D. Cringle, GNU GPL v2 or later. They
  are **not in this repository**. `py -3 tools/fetch_zex.py` downloads them from
  a public copy (`github.com/anotherlin/z80emu`, `testfiles/`, where their
  sources `zexdoc.z80` / `zexall.z80` are too), checks them against
  `sha256.txt`, and embeds them for the test programs.
- **SingleStepTests/z80** (`sst/head/*.json`): the first 16 KB of each of the
  1,604 opcode files of `v1/` of github.com/SingleStepTests/z80, MIT
  (`licenses/SingleStepTests-MIT.txt`), fetched with HTTP range requests by
  `sst/fetch.sh`. `tools/embed_sst.py` takes the first five complete vectors of
  each into `tests/sst_batch*` (board) and `desktop/gen/sst_vectors.pbi`.
