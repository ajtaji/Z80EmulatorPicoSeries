; Console build of the desktop core: the board's suites and the benchmarks.
;   z80_console.exe --test        SST, API, ZEXDOC, ZEXALL
;   z80_console.exe --quick       SST and API only
;   z80_console.exe --bench       instruction-mix benchmarks
;   z80_console.exe --distest     the disassembler against known encodings
;   z80_console.exe --zex <0|1> [first] [last]
;   z80_console.exe --run <file.com>   a CP/M program under the BDOS stub
CompilerIf Not Defined(Z80_TIMED, #PB_Constant)
  #Z80_TIMED = 1
CompilerEndIf
#Z80_SHARED_TAIL = 0
#Z80_MEM_HOOKS = 1
#Z80_Q = 1
#Z80_TRACK_R = 1
#SST_SABOTAGE = 0
EnableExplicit
CompilerIf Not Defined(Z80_PROCS, #PB_Constant)
  #Z80_PROCS = 0
CompilerEndIf
CompilerIf #Z80_PROCS = 1
  XIncludeFile "z80core_procs.pbi"   ; procedure-table dispatch (measurement only)
CompilerElse
  XIncludeFile "z80core.pbi"         ; labels as values
CompilerEndIf
XIncludeFile "io_desktop.pbi"
XIncludeFile "machine.pbi"
XIncludeFile "z80_tests.pbi"
XIncludeFile "z80disasm.pbi"
XIncludeFile "distest.pbi"

OpenConsole()
IoConsole = 1
Define arg$ = LCase(ProgramParameter(0)), rc.i
Select arg$
  Case "--test" : rc = RunAllTests(1)
  Case "--quick" : rc = RunAllTests(0)
  Case "--bench" : RunBench()
  Case "--distest" : rc = RunDisTest()
  Case "--zex"
    If CountProgramParameters() > 3
      rc = RunZex(Val(ProgramParameter(1)), Val(ProgramParameter(2)), Val(ProgramParameter(3)))
    Else
      rc = RunZex(Val(ProgramParameter(1)))
    EndIf
  Case "--run"
    If LoadProgram(ProgramParameter(1))
      Repeat
        Z80Run(50000000)
      Until Z80Halted <> 0 Or Z80Stopped <> 0
      Eol()
    Else
      PrintN("cannot read " + ProgramParameter(1)) : rc = 2
    EndIf
  Default
    PrintN("z80_console --test | --quick | --bench | --zex <0|1> [first last] | --run <file.com>")
EndSelect
End rc
