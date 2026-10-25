; The board's suites on the desktop core: SingleStepTests (all 8,020 vectors
; in one pass), the interrupt/API checks, and ZEXDOC/ZEXALL under the CP/M
; stub. Each returns its failure count and prints the board's own verdicts.
XIncludeFile "gen/sst_vectors.pbi"
; ZEXDOC/ZEXALL (GPL, not in the repository) are built in only when fetched:
; py -3 tools/fetch_zex.py writes tests/zex_data.pico, and desktop/build.ps1
; then passes /CONSTANT Z80_HAVE_ZEX=1. Without them everything else builds.
CompilerIf Not Defined(Z80_HAVE_ZEX, #PB_Constant)
  #Z80_HAVE_ZEX = 0
CompilerEndIf
CompilerIf #Z80_HAVE_ZEX = 1
  XIncludeFile "../tests/zex_data.pico"
CompilerEndIf
#ZEX_MISSING$ = "ZEXDOC/ZEXALL not fetched - run  py -3 tools/fetch_zex.py  and rebuild"

Procedure.i RunSst()
  HookMode = #HOOK_SST
  Say("SingleStepTests on the desktop core, timed=") : Num(#Z80_TIMED) : Eol()
  SstStart = Micros()
  SstRun()
  Say("SST vectors=") : Num(SstN) : Say(" failures=") : Num(SstFail) : Say(" us=") : Num(Micros() - SstStart)
  If SstFail = 0 And SstN = #SST_BATCH_COUNT : Say(" PASS") : Else : Say(" FAIL") : EndIf
  Eol()
  HookMode = #HOOK_CPM
  ProcedureReturn Bool(SstFail <> 0 Or SstN <> #SST_BATCH_COUNT)
EndProcedure

Procedure.i RunApi()
  HookMode = #HOOK_API
  ApN = 0 : ApFail = 0 : ApHookRd = 0 : ApHookWr = 0
  Say("API checks timed=") : Num(#Z80_TIMED) : Eol()
  ApRun()
  Say("API checks=") : Num(ApN) : Say(" failures=") : Num(ApFail)
  If ApFail = 0 : Say(" PASS") : Else : Say(" FAIL") : EndIf
  Eol()
  HookMode = #HOOK_CPM
  ProcedureReturn ApFail
EndProcedure

; Selects tests first..last-1 of the exerciser loaded at $100, as the board
; harness does: the table address follows "ld hl," at start + 12.
Procedure.i ZexSelect(first.i, last.i)
  Protected start.i, word.i
  start = Z80Mem($101) | (Z80Mem($102) << 8)
  If Z80Mem(start + 12) <> $21 : ProcedureReturn 0 : EndIf
  ZexTests = Z80Mem(start + 13) | (Z80Mem(start + 14) << 8)
  ZexCount = 0
  While (Z80Mem(ZexTests + ZexCount * 2) | Z80Mem(ZexTests + ZexCount * 2 + 1)) <> 0
    ZexCount + 1
  Wend
  word = ZexTests + first * 2
  Z80Mem(start + 13) = word & 255 : Z80Mem(start + 14) = word >> 8
  If last < ZexCount
    Z80Mem(ZexTests + last * 2) = 0 : Z80Mem(ZexTests + last * 2 + 1) = 0
  EndIf
  ProcedureReturn 1
EndProcedure

; Loads an exerciser; 0 when this build has none.
Procedure.i ZexLoad(all.i)
  CompilerIf #Z80_HAVE_ZEX = 1
    If all
      LoadComFromData(?ZexAll, ?ZexAllEnd - ?ZexAll, "zexall.com")
    Else
      LoadComFromData(?ZexDoc, ?ZexDocEnd - ?ZexDoc, "zexdoc.com")
    EndIf
    ZexOk = 0 : ZexErr = 0
    ProcedureReturn 1
  CompilerElse
    ProcedureReturn 0
  CompilerEndIf
EndProcedure

Procedure.i RunZex(all.i, first.i = 0, last.i = 67)
  Protected used.q, t0.q, ins.q
  If ZexLoad(all) = 0
    Say(#ZEX_MISSING$) : Eol()
    ProcedureReturn -1
  EndIf
  If all : Say("ZEXALL") : Else : Say("ZEXDOC") : EndIf
  If ZexSelect(first, last) = 0
    Say(" layout not recognised FAIL") : Eol() : ProcedureReturn 1
  EndIf
  Say(" tests ") : Num(first) : Say("..") : Num(last - 1) : Say(" of ") : Num(ZexCount) : Eol()
  t0 = Micros()
  ZexLast = t0
  ZexMillions = 0
  Repeat
    used + Z80Run(50000000)
  Until Z80Halted <> 0 Or Z80Stopped <> 0
  t0 = Micros() - t0
  Eol()
  CompilerIf #Z80_TIMED = 1
    Say("T-states=") : Num(used) : Say(" us=") : Num(t0) : Say(" emulated MHz=") : Num(used / t0) : Eol()
  CompilerElse
    Say("instructions=") : Num(used) : Say(" us=") : Num(t0) : Say(" instructions/s=") : Num(Rate(used, t0)) : Eol()
  CompilerEndIf
  Say("ZEX ok=") : Num(ZexOk) : Say(" errors=") : Num(ZexErr)
  If ZexErr = 0 And ZexOk = last - first And Z80PC = 1 And Z80Stopped = 0
    Say(" PASS") : Eol() : ProcedureReturn 0
  EndIf
  Say(" FAIL") : Eol()
  ProcedureReturn 1
EndProcedure

Procedure RunBench()
  HookMode = #HOOK_BENCH
  CompilerIf #Z80_MEM_HOOKS = 1
    Z80PageRd($50) = 1 : Z80PageWr($50) = 1
  CompilerEndIf
  Say("Z80 desktop bench timed=") : Num(#Z80_TIMED) : Say(" hooks=") : Num(#Z80_MEM_HOOKS) : Say(" shared=") : Num(#Z80_SHARED_TAIL) : Eol()
  BnRun(?BnNameReg, ?BnReg, ?BnRegEnd - ?BnReg)
  BnRun(?BnNameAlu, ?BnAlu, ?BnAluEnd - ?BnAlu)
  BnRun(?BnNameMem, ?BnMem, ?BnMemEnd - ?BnMem)
  BnRun(?BnNameBlk, ?BnBlk, ?BnBlkEnd - ?BnBlk)
  BnRun(?BnNameIdx, ?BnIdx, ?BnIdxEnd - ?BnIdx)
  BnRun(?BnNameCall, ?BnCall, ?BnCallEnd - ?BnCall)
  HookMode = #HOOK_CPM
EndProcedure

; Every suite, as the board runs them. Returns the number of suites failed.
Procedure.i RunAllTests(withZex.i = 1)
  Protected bad.i
  IoLog$ = ""
  bad + Bool(RunSst() <> 0)
  bad + Bool(RunApi() <> 0)
  If withZex
    CompilerIf #Z80_HAVE_ZEX = 1
      bad + Bool(RunZex(0) <> 0)
      bad + Bool(RunZex(1) <> 0)
    CompilerElse
      Say(#ZEX_MISSING$) : Eol()
    CompilerEndIf
  EndIf
  Say("Suites failed: ") : Num(bad) : Eol()
  ProcedureReturn bad
EndProcedure
