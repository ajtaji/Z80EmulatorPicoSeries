; The desktop machine around the core: flat 64 KB, a CP/M page zero with
; BDOS functions 2 and 9 (the same stub the board's ZEX runs use), and one
; Z80PortIn/Out/MemRead/MemWrite that routes to the test suite in use.
#HOOK_CPM = 0
#HOOK_SST = 1
#HOOK_API = 2
#HOOK_BENCH = 3
Global HookMode.i = #HOOK_CPM
#BN_TSTATES = 400000000   ; per benchmark sample on the PC
#BN_INSNS = 100000000

XIncludeFile "gen/sst_body.pbi"
XIncludeFile "gen/api_body.pbi"
XIncludeFile "gen/zex_body.pbi"
XIncludeFile "gen/bench_body.pbi"

Procedure.i Z80PortIn(port.i)
  Select HookMode
    Case #HOOK_SST : ProcedureReturn SstPortIn(port)
    Case #HOOK_API : ProcedureReturn ApPortIn(port)
    Case #HOOK_BENCH : ProcedureReturn BnPortIn(port)
  EndSelect
  ProcedureReturn ZexPortIn(port)
EndProcedure
Procedure Z80PortOut(port.i, value.i)
  Select HookMode
    Case #HOOK_SST : SstPortOut(port, value)
    Case #HOOK_API : ApPortOut(port, value)
    Case #HOOK_BENCH : BnPortOut(port, value)
    Default : ZexPortOut(port, value)
  EndSelect
EndProcedure
Procedure.i Z80MemRead(addr.i)
  Select HookMode
    Case #HOOK_API : ProcedureReturn ApMemRead(addr)
    Case #HOOK_BENCH : ProcedureReturn BnMemRead(addr)
  EndSelect
  ProcedureReturn Z80Mem(addr)
EndProcedure
Procedure Z80MemWrite(addr.i, value.i)
  Select HookMode
    Case #HOOK_API : ApMemWrite(addr, value)
    Case #HOOK_BENCH : BnMemWrite(addr, value)
    Default : Z80Mem(addr) = value
  EndSelect
EndProcedure

; CP/M page zero: warm boot is HALT at 0, BDOS at $FE00 is OUT (0),A / RET.
Procedure CpmPageZero()
  Protected k.i
  CompilerIf #Z80_MEM_HOOKS = 1
    For k = 0 To 255
      Z80PageRd(k) = 0 : Z80PageWr(k) = 0
    Next
  CompilerEndIf
  Z80Mem(0) = $76
  Z80Mem(5) = $C3 : Z80Mem(6) = $00 : Z80Mem(7) = $FE
  Z80Mem($FE00) = $D3 : Z80Mem($FE01) = $00 : Z80Mem($FE02) = $C9
EndProcedure

; A .COM file at $100 under the stub, or any other file as a raw image at 0.
Global LoadedName$ = "(none)", LoadedSize.i
Procedure.i LoadProgram(path.s)
  Protected f.i, n.i, com.i = Bool(LCase(GetExtensionPart(path)) = "com")
  f = ReadFile(#PB_Any, path)
  If f = 0 : ProcedureReturn 0 : EndIf
  n = Lof(f)
  HookMode = #HOOK_CPM
  Z80Reset()
  FillMemory(@Z80Mem(0), 65536, 0)
  If com
    If n > $FD00 - $100 : n = $FD00 - $100 : EndIf
    ReadData(f, @Z80Mem($100), n)
    CpmPageZero()
    Z80PC = $100 : Z80SP = $FE00
  Else
    If n > 65536 : n = 65536 : EndIf
    ReadData(f, @Z80Mem(0), n)
  EndIf
  CloseFile(f)
  LoadedName$ = GetFilePart(path) : LoadedSize = n
  ProcedureReturn 1
EndProcedure

; The same, from a DataSection (the exercisers built into the program).
Procedure LoadComFromData(*p, n.i, name.s)
  HookMode = #HOOK_CPM
  Z80Reset()
  FillMemory(@Z80Mem(0), 65536, 0)
  CopyMemory(*p, @Z80Mem($100), n)
  CpmPageZero()
  Z80PC = $100 : Z80SP = $FE00
  LoadedName$ = name : LoadedSize = n
EndProcedure
