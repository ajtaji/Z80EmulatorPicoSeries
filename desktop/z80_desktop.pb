; Z80 emulator for the desktop: the same Z80 core as the Pico build
; (generated from the same handlers), in PureBasic, with a Neon Arcade
; Display Engine front end and a CP/M-style machine (BDOS 2 and 9).
;
;   z80_desktop.exe                    the window
;   z80_desktop.exe <file.com|bin>     ... with a program loaded (.com at 100h under
;                                      the BDOS stub, anything else raw at 0)
; Window options (any order):
;   --show-tests        run the board's suites (SST, API) when the window opens
;   --zexdoc / --zexall load that exerciser (built in) and run it
;   --run               start the loaded program
;   --screenshot <png>  save the window's own picture and close
;   --shot-after <n>    ... after n frames (default 120)
;   --ui-log <file>     write each control's rectangle and the state every frame
;                       (for driving the window with a real pointer in a test)
;   --pointer-test <file>     every control against a synthetic pointer, then close
;   --fullscreen-test <file>  F11 and Esc posted to the window: full screen and
;                       the way back are checked, then close
;   --fullscreen-shot <png>   ... saving the full-screen picture on the way
;   --output-tab <n>    open the Output panel on tab n (0 console, 1 tests, 2 Controls)
; Keys: one table, controls.pbi (F11 full screen, Esc leaves it). The machine
; itself takes no keys: its CP/M console only writes.
; The console build (console_main.pb, z80_console.exe) runs every suite
; including ZEXDOC/ZEXALL, and the benchmarks.
;
; Build with desktop/build.ps1 (x64, C back end, /DPIAWARE, /OPTIMIZER).

#Z80_TIMED = 1
#Z80_SHARED_TAIL = 0
#Z80_MEM_HOOKS = 1
#Z80_Q = 1
#Z80_TRACK_R = 1
#SST_SABOTAGE = 0
#SST_HOOK_ALL = 0
EnableExplicit

; The engine first (its procedures use plain names the test code also uses).
CompilerIf Not Defined(GL_ENGINE_DIR$, #PB_Constant)
  #GL_ENGINE_DIR$ = "../../Neon-Arcade-Dispay-Engine/"   ; build.ps1 passes the real path
CompilerEndIf
XIncludeFile #GL_ENGINE_DIR$ + "GlTypes.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUtilities.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlMath.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlSpriteFunctions.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUI.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUIChrome.pbi"

XIncludeFile "z80core.pbi"
XIncludeFile "io_desktop.pbi"
XIncludeFile "machine.pbi"
XIncludeFile "z80_tests.pbi"
XIncludeFile "z80disasm.pbi"
XIncludeFile "controls.pbi"          ; every key the window answers to, one table

Global Win.i, Gl.i
Global Running.i, BreakAt.i = -1, BreakText.String, BreakCaret.i
Global Status$ = "Load a CP/M .COM program, or run ZEXDOC / ZEXALL or the test suites."
Global RateShown.d, RateWindowT.q, RateWindowStart.q
Global DisTop.i, MemTab.i, MemTop.i, LogTab.i, LogTop.i
Global Wheel.i, KeyCode.i, KeyChar.i
Global TestsRun.i, TestsFailed.i, TestLog$, ShotPath$, ShotFrames.i, ShotAfter.i = 120
Global RealTime.i, RealClock.q, RealDone.q

#REAL_KHZ = 4000     ; a 4 MHz Z80 in real-time mode

; --ui-log <file>: every frame, each clickable control's rectangle (canvas
; units), the control under the pointer and the program's state, for driving
; the window with a real pointer from a test script.
Global UiLogPath$, UiRects$, UiHover$
Declare BuildFonts(s.f)
Declare ControlsPane(x.f, y.f, w.f, h.f)
Declare EnterFullScreen()

; --pointer-test <file>: the window drives itself with a synthetic pointer
; (no real cursor, no clicks outside it). For every control it puts the
; pointer just inside each corner and just outside the bottom-right one,
; feeds it to Neon_ChromeBeginFrame as a physical client position, checks
; the control under it, then clicks at the bottom-right corner and checks the
; control did its job. The report goes to <file>; the window then closes.
Structure UiBox
  x.f : y.f : w.f : h.f
EndStructure
Global NewMap UiBoxes.UiBox()
Global PtTest.i, PtOut$, PtStep.i, PtFrame.i, PtX.f, PtY.f, PtDown.i, PtDone.i
Global PtWarm.i, PtChecks.i, PtFails.i, PtReport$, PtOpened.i, PtPc.i, PtMemTop.i, PtKey$, PtClick.i, PtStatus$
Global NewList PtSteps.s()

Procedure UiRect(name.s, x.f, y.f, w.f, h.f)
  If UiLogPath$ = "" And PtTest = 0 : ProcedureReturn : EndIf
  UiRects$ + "RECT " + name + " " + StrF(x, 1) + " " + StrF(y, 1) + " " + StrF(w, 1) + " " + StrF(h, 1) + #LF$
  If Neon_Hit(x, y, w, h) : UiHover$ + name + " " : EndIf
  If PtTest
    AddMapElement(UiBoxes(), name)
    UiBoxes()\x = x : UiBoxes()\y = y : UiBoxes()\w = w : UiBoxes()\h = h
  EndIf
EndProcedure

Procedure UiTabs(id.i, prefix.s)
  Protected i.i
  If UiLogPath$ = "" And PtTest = 0 : ProcedureReturn : EndIf
  If FindMapElement(Neon_TabLayout(), Str(id))
    For i = 0 To Neon_TabLayout()\Count - 1
      If Neon_TabLayout()\W(i) > 0
        UiRect(prefix + Str(i), Neon_TabLayout()\X(i), Neon_TabLayout()\Y, Neon_TabLayout()\W(i), Neon_TabLayout()\H)
      EndIf
    Next
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; Running
; ---------------------------------------------------------------------------
Procedure.s H2(v.i)
  ProcedureReturn RSet(Hex(v & $FF), 2, "0")
EndProcedure
Procedure.s H4(v.i)
  ProcedureReturn RSet(Hex(v & $FFFF), 4, "0")
EndProcedure

Procedure CheckStop()
  If (Z80Stopped Or Z80Halted) And LogTab = 0
    LogTop = 1 << 30           ; show the end of the output
  EndIf
  If Z80Stopped
    Running = 0
    Select Z80Error
      Case 2 : Status$ = "Stopped: IM 0 with a bus byte that is not RST (error 2)."
      Case 3 : Status$ = "Stopped: LD A,R in a build without R tracking (error 3)."
      Default : Status$ = "Stopped (error " + Str(Z80Error) + ")."
    EndSelect
  ElseIf Z80Halted And Z80IntLine = 0 And Z80NmiLine = 0
    ; this machine has no interrupt source: a HALT is the end of the program
    Running = 0
    If Z80PC = 1
      Status$ = "The program ended: warm boot (HALT at 0000h)."
      If ZexOk + ZexErr > 0
        Status$ + "  Exerciser verdicts: " + Str(ZexOk) + " OK, " + Str(ZexErr) + " ERROR."
      EndIf
    Else
      Status$ = "HALT at " + H4((Z80PC - 1) & $FFFF) + "h: nothing here can interrupt it."
    EndIf
  EndIf
EndProcedure

Procedure StepOne()
  Z80Run(1)
  CheckStop()
EndProcedure

; Runs for about budgetMs of wall time: as fast as it goes, or at 4 MHz in
; real-time mode; instruction by instruction while a breakpoint is set.
Procedure RunFor(budgetMs.i)
  Protected t0.q = ElapsedMilliseconds(), due.q, chunk.i, used.q, k.i
  If RealTime
    If RealClock = 0 : RealClock = t0 : RealDone = 0 : EndIf
    due = (t0 - RealClock) * #REAL_KHZ - RealDone
    If due > #REAL_KHZ * 50 : RealClock = t0 : RealDone = 0 : due = #REAL_KHZ * 16 : EndIf
  EndIf
  While Running
    If RealTime
      If due <= 0 : Break : EndIf
      chunk = due
      If chunk > 200000 : chunk = 200000 : EndIf
    Else
      If ElapsedMilliseconds() - t0 >= budgetMs : Break : EndIf
      chunk = 2000000
    EndIf
    If BreakAt >= 0
      For k = 1 To 20000
        used = Z80Run(1)
        RealDone + used : due - used : RateWindowT + used
        If Z80PC = BreakAt
          Running = 0 : Status$ = "Stopped at the breakpoint " + H4(BreakAt) + "h."
          Break
        EndIf
        If Z80Stopped Or Z80Halted : Break : EndIf
        If RealTime And due <= 0 : Break : EndIf
      Next
    Else
      used = Z80Run(chunk)
      RealDone + used : due - used : RateWindowT + used
    EndIf
    CheckStop()
  Wend
EndProcedure

Procedure StartExerciser(all.i)
  Running = 0
  If ZexLoad(all) = 0
    Status$ = #ZEX_MISSING$ + "."
    TestLog$ = #ZEX_MISSING$ + #LF$
    LogTab = 1
    ProcedureReturn
  EndIf
  IoLog$ = "" : IoLine$ = ""
  ZexLast = Micros()
  LogTab = 0 : LogTop = 0 : DisTop = Z80PC
  RealTime = 0
  Running = 1
  If all : Status$ = "Running ZEXALL at full speed (about 15 s on this PC)." : Else : Status$ = "Running ZEXDOC at full speed (about 15 s on this PC)." : EndIf
EndProcedure

Procedure RunTestsInWindow()
  Protected keepLog$ = IoLog$, keepLine$ = IoLine$, *keep = AllocateMemory(65536)
  Protected pc.i = Z80PC, sp.i = Z80SP
  Running = 0
  CopyMemory(@Z80Mem(0), *keep, 65536)
  IoLog$ = "" : IoLine$ = ""
  TestsFailed = RunAllTests(0)
  CompilerIf #Z80_HAVE_ZEX = 0
    Say("(ZEXDOC and ZEXALL: " + #ZEX_MISSING$ + ")") : Eol()
  CompilerEndIf
  TestLog$ = IoLog$
  TestsRun = 1
  ; give the user's program back
  IoLog$ = keepLog$ : IoLine$ = keepLine$
  Z80Reset()
  CopyMemory(*keep, @Z80Mem(0), 65536)
  FreeMemory(*keep)
  Z80PC = pc : Z80SP = sp
  HookMode = #HOOK_CPM
  LogTab = 1 : LogTop = 0
  If TestsFailed = 0
    Status$ = "SingleStepTests (8,020 vectors) and the API checks pass on the desktop core - the board's own suites."
  Else
    Status$ = Str(TestsFailed) + " suite(s) FAILED - see Test results."
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; Drawing
; ---------------------------------------------------------------------------
Procedure DrawLine(x.f, y.f, t.s, r.f = -1, g.f = 0, b.f = 0)
  If r < 0
    Neon_Text(*Neon_FontMono, x, y, t, Neon_C_TextR, Neon_C_TextG, Neon_C_TextB)
  Else
    Neon_Text(*Neon_FontMono, x, y, t, r, g, b)
  EndIf
EndProcedure

Procedure.s FlagString(f.i)
  Protected s.s, names.s = "S Z Y H X PVN C ", i.i, nm.s
  For i = 0 To 7
    nm = Trim(Mid(names, i * 2 + 1, 2))
    If i = 5 : nm = "PV" : EndIf
    If i = 6 : nm = "N" : EndIf
    If i = 7 : nm = "C" : EndIf
    If f & (128 >> i) : s + nm + " " : Else : s + LCase(nm) + " " : EndIf
  Next
  ProcedureReturn s
EndProcedure

Procedure DrawCpuPanel(x.f, y.f, w.f, h.f)
  Protected lh.f = Neon_S(18), yy.f, s.s, x0.f = x + Neon_S(10)
  Neon_Panel(x, y, w, h, "Z80", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
  yy = y + Neon_S(34)
  DrawLine(x0, yy, "PC " + H4(Z80PC) + "   SP " + H4(Z80SP) + "   WZ " + H4(Z80WZ)) : yy + lh
  DrawLine(x0, yy, "AF " + H2(Z80A) + H2(Z80F) + "   AF' " + H4(Z80AF2)) : yy + lh
  DrawLine(x0, yy, "BC " + H4(Z80BC) + "   BC' " + H4(Z80BC2)) : yy + lh
  DrawLine(x0, yy, "DE " + H4(Z80DE) + "   DE' " + H4(Z80DE2)) : yy + lh
  DrawLine(x0, yy, "HL " + H4(Z80HL) + "   HL' " + H4(Z80HL2)) : yy + lh
  DrawLine(x0, yy, "IX " + H4(Z80IX) + "   IY  " + H4(Z80IY)) : yy + lh * 1.4
  DrawLine(x0, yy, FlagString(Z80F), Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB) : yy + lh * 1.4
  DrawLine(x0, yy, "I " + H2(Z80I) + "  R " + H2(Z80GetR()) + "  IM " + Str(Z80IM) + "  IFF1 " + Str(Z80IFF1) + " IFF2 " + Str(Z80IFF2)) : yy + lh
  s = "running"
  If Running = 0 : s = "stopped" : EndIf
  If Z80Halted : s + ", HALT" : EndIf
  DrawLine(x0, yy, "state  " + s) : yy + lh
  DrawLine(x0, yy, "T-states " + Str(Z80TStates)) : yy + lh * 1.4
  DrawLine(x0, yy, "(SP)  " + H4(Z80Mem(Z80SP) | (Z80Mem((Z80SP + 1) & $FFFF) << 8)) + " " +
                   H4(Z80Mem((Z80SP + 2) & $FFFF) | (Z80Mem((Z80SP + 3) & $FFFF) << 8)) + " " +
                   H4(Z80Mem((Z80SP + 4) & $FFFF) | (Z80Mem((Z80SP + 5) & $FFFF) << 8)), Neon_C_DimR, Neon_C_DimG, Neon_C_DimB) : yy + lh
  DrawLine(x0, yy, "(HL)  " + H2(Z80Mem(Z80HL)) + "   (BC) " + H2(Z80Mem(Z80BC)) + "   (DE) " + H2(Z80Mem(Z80DE)), Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
EndProcedure

Procedure DrawDisasm(x.f, y.f, w.f, h.f)
  Protected lh.f = Neon_S(18), rows.i, i.i, adr.i, n.i, t.s, yy.f, k.i, found.i, bytes.s
  Neon_Panel(x, y, w, h, "Disassembly  (click a line for a breakpoint)", Neon_C_VioR, Neon_C_VioG, Neon_C_VioB)
  rows = Int((h - Neon_S(40)) / lh)
  adr = DisTop
  For i = 0 To rows - 3
    If adr = Z80PC : found = 1 : Break : EndIf
    Z80Disasm(adr, @n) : adr = (adr + n) & $FFFF
  Next
  If found = 0 : DisTop = Z80PC : EndIf
  adr = DisTop
  yy = y + Neon_S(32)
  For i = 0 To rows - 1
    t = Z80Disasm(adr, @n)
    If adr = Z80PC
      Neon_Box(x + Neon_S(4), yy - Neon_S(2), w - Neon_S(8), lh, Neon_C_AccR, Neon_C_AccG, Neon_C_AccB, 0.18)
    EndIf
    If adr = BreakAt
      Neon_Box(x + Neon_S(6), yy + Neon_S(3), Neon_S(8), Neon_S(8), Neon_C_RedR, Neon_C_RedG, Neon_C_RedB)
    EndIf
    If i < 6 : UiRect("dis" + Str(i) + ":" + H4(adr), x, yy - Neon_S(2), w, lh) : EndIf
    If Neon_MouseClicked And Neon_Hit(x, yy - Neon_S(2), w, lh)
      If BreakAt = adr : BreakAt = -1 : BreakText\s = "" : Else : BreakAt = adr : BreakText\s = H4(adr) : EndIf
    EndIf
    bytes = ""
    For k = 0 To n - 1
      bytes + H2(Z80Mem((adr + k) & $FFFF))
    Next
    DrawLine(x + Neon_S(20), yy, H4(adr) + "  " + LSet(bytes, 9) + t)
    yy + lh
    adr = (adr + n) & $FFFF
  Next
EndProcedure

Procedure DrawMemory(x.f, y.f, w.f, h.f)
  Protected lh.f = Neon_S(18), rows.i, r.i, c.i, a.i, s.s, yy.f, base.i, ch.s, b.i, anchor.i
  Neon_Panel(x, y, w, h, "Memory", Neon_C_GrnR, Neon_C_GrnG, Neon_C_GrnB)
  MemTab = Neon_TabStrip(101, x + Neon_S(2), y + Neon_S(28), w - Neon_S(4), Neon_S(26), "All 64 KB|At PC|At HL|At SP", MemTab)
  UiTabs(101, "memtab")
  rows = Int((h - Neon_S(70)) / lh)
  If MemTab = 0
    If Neon_Hit(x, y, w, h) And Wheel : MemTop - Wheel * 3 : EndIf
    UiRect("memscroll", x + w - Neon_S(14), y + Neon_S(58), Neon_S(12), h - Neon_S(62))
    Neon_ScrollBarV(102, x + w - Neon_S(14), y + Neon_S(58), Neon_S(12), h - Neon_S(62), 4096, rows, @MemTop)
    If MemTop > 4096 - rows : MemTop = 4096 - rows : EndIf
    If MemTop < 0 : MemTop = 0 : EndIf
    anchor = MemTop * 16
  Else
    Select MemTab
      Case 1 : anchor = Z80PC
      Case 2 : anchor = Z80HL
      Case 3 : anchor = Z80SP
    EndSelect
    anchor = (anchor & $FFF0) - 32
  EndIf
  yy = y + Neon_S(62)
  For r = 0 To rows - 1
    base = (anchor + r * 16) & $FFFF
    s = H4(base) + "  " : ch = ""
    For c = 0 To 15
      a = (base + c) & $FFFF
      b = Z80Mem(a)
      s + H2(b) + " "
      If b >= 32 And b < 127 : ch + Chr(b) : Else : ch + "." : EndIf
    Next
    DrawLine(x + Neon_S(10), yy, s + " " + ch)
    yy + lh
  Next
EndProcedure

Procedure DrawLog(x.f, y.f, w.f, h.f)
  Protected lh.f = Neon_S(17), rows.i, n.i, i.i, t.s, yy.f, line.s
  Neon_Panel(x, y, w, h, "Output", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB)
  LogTab = Neon_TabStrip(201, x + Neon_S(2), y + Neon_S(28), w - Neon_S(4), Neon_S(26), "CP/M console (BDOS 2, 9)|Test results|Controls", LogTab)
  UiTabs(201, "logtab")
  If LogTab = 2 : ControlsPane(x, y + Neon_S(60), w, h - Neon_S(60)) : ProcedureReturn : EndIf
  If LogTab = 0 : t = IoLog$ + IoLine$ : Else : t = TestLog$ : EndIf
  If t = "" : t = "(nothing yet)" : EndIf
  n = CountString(t, #LF$) + 1
  rows = Int((h - Neon_S(66)) / lh)
  ; follow the end while output grows, unless scrolled away
  If Neon_Hit(x, y, w, h) And Wheel : LogTop - Wheel * 3 : EndIf
  If Running And LogTab = 0 : LogTop = n - rows : EndIf
  UiRect("logscroll", x + w - Neon_S(14), y + Neon_S(58), Neon_S(12), h - Neon_S(62))
  Neon_ScrollBarV(202, x + w - Neon_S(14), y + Neon_S(58), Neon_S(12), h - Neon_S(62), n, rows, @LogTop)
  If LogTop > n - rows : LogTop = n - rows : EndIf
  If LogTop < 0 : LogTop = 0 : EndIf
  yy = y + Neon_S(60)
  For i = LogTop To LogTop + rows - 1
    If i >= n : Break : EndIf
    line = StringField(t, i + 1, #LF$)
    If FindString(line, "FAIL") Or FindString(line, "ERROR")
      DrawLine(x + Neon_S(10), yy, line, Neon_C_RedR, Neon_C_RedG, Neon_C_RedB)
    ElseIf FindString(line, "PASS") Or FindString(line, "OK")
      DrawLine(x + Neon_S(10), yy, line, Neon_C_GrnR, Neon_C_GrnG, Neon_C_GrnB)
    Else
      DrawLine(x + Neon_S(10), yy, line)
    EndIf
    yy + lh
  Next
EndProcedure

Procedure DrawToolbar(w.f)
  Protected x.f = Neon_S(10), y.f = Neon_S(8), bh.f = Neon_S(30), f.s, label.s, k.i, r.d
  Neon_Box(0, 0, w, Neon_S(46), Neon_C_HeadR, Neon_C_HeadG, Neon_C_HeadB)
  UiRect("open", x, y, Neon_S(80), bh)
  If Neon_Button(x, y, Neon_S(80), bh, "Open...")
    If PtTest
      PtOpened = 1 : f = ""   ; the pointer test stops short of the modal dialog
    Else
      f = OpenFileRequester("Load a Z80 program", "", "CP/M program (*.com)|*.com|Raw image at 0 (*.bin;*.rom)|*.bin;*.rom|All files (*.*)|*.*", 0)
    EndIf
    If f <> ""
      Running = 0
      IoLog$ = "" : IoLine$ = ""
      If LoadProgram(f)
        Status$ = "Loaded " + LoadedName$ + " (" + Str(LoadedSize) + " bytes)." : DisTop = Z80PC : LogTab = 0
      Else
        Status$ = "Could not read " + f
      EndIf
    EndIf
  EndIf
  x + Neon_S(88)
  UiRect("reset", x, y, Neon_S(64), bh)
  If Neon_Button(x, y, Neon_S(64), bh, "Reset")
    Running = 0 : Z80Reset() : Status$ = "Reset: PC 0000h, interrupts off. Memory kept."
  EndIf
  x + Neon_S(72)
  label = "Run"
  If Running : label = "Stop" : EndIf
  UiRect("run", x, y, Neon_S(64), bh)
  If Neon_Button(x, y, Neon_S(64), bh, label, Running)
    Running = Bool(Running = 0)
    If Running
      If Z80Stopped : Running = 0 : Status$ = "Reset or load a program first." : EndIf
      If Running And Z80PC = BreakAt : StepOne() : EndIf
      If Running : Status$ = "Running." : RealClock = 0 : EndIf
    Else
      Status$ = "Stopped at " + H4(Z80PC) + "h."
    EndIf
  EndIf
  x + Neon_S(72)
  UiRect("step", x, y, Neon_S(60), bh)
  If Neon_Button(x, y, Neon_S(60), bh, "Step", #False, Bool(Running = 0))
    StepOne() : Status$ = "Stepped to " + H4(Z80PC) + "h."
  EndIf
  x + Neon_S(68)
  UiRect("step100", x, y, Neon_S(84), bh)
  If Neon_Button(x, y, Neon_S(84), bh, "Step 100", #False, Bool(Running = 0))
    For k = 1 To 100
      StepOne()
      If Z80PC = BreakAt Or Z80Stopped Or Running = 0 And Z80Halted : Break : EndIf
    Next
    Status$ = "Stepped to " + H4(Z80PC) + "h."
  EndIf
  x + Neon_S(92)
  Neon_Text(*Neon_FontUI, x, y + Neon_S(6), "Break at", Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  x + Neon_S(62)
  UiRect("breakat", x, y, Neon_S(70), bh)
  If Neon_TextInput(301, x, y, Neon_S(70), bh, @BreakText, "hex", @BreakCaret)
    If Trim(BreakText\s) = "" : BreakAt = -1 : Else : BreakAt = Val("$" + Trim(BreakText\s)) & $FFFF : EndIf
  EndIf
  x + Neon_S(78)
  UiRect("runtests", x, y, Neon_S(96), bh)
  If Neon_Button(x, y, Neon_S(96), bh, "Run tests", Bool(TestsRun And TestsFailed = 0))
    RunTestsInWindow()
  EndIf
  x + Neon_S(104)
  UiRect("zexdoc", x, y, Neon_S(84), bh)
  If Neon_Button(x, y, Neon_S(84), bh, "ZEXDOC")
    StartExerciser(0)
  EndIf
  x + Neon_S(92)
  UiRect("zexall", x, y, Neon_S(84), bh)
  If Neon_Button(x, y, Neon_S(84), bh, "ZEXALL")
    StartExerciser(1)
  EndIf
  x + Neon_S(92)
  label = "Full speed"
  If RealTime : label = "4 MHz" : EndIf
  UiRect("speed", x, y, Neon_S(96), bh)
  If Neon_Button(x, y, Neon_S(96), bh, label, RealTime)
    RealTime = Bool(RealTime = 0) : RealClock = 0
  EndIf
  x + Neon_S(104)
  UiRect("fullscreen", x, y, Neon_S(130), bh)
  If Neon_Button(x, y, Neon_S(130), bh, "Full screen  " + CtlActionKeys(#CTL_FULLSCREEN))
    EnterFullScreen()
  EndIf
  r = RateShown / 1000000.0
  Neon_TextRight(*Neon_FontUI, w - Neon_S(12), y + Neon_S(6), StrD(r, 1) + " emulated MHz", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
EndProcedure

; The window's own back buffer, read before the flip, written as a PNG.
Procedure SaveShot(pw.i, ph.i)
  Protected *px = AllocateMemory(pw * ph * 4), img.i, x.i, y.i, c.l
  glReadPixels_(0, 0, pw, ph, #GL_RGBA, #GL_UNSIGNED_BYTE, *px)
  img = CreateImage(#PB_Any, pw, ph, 24)
  If img And StartDrawing(ImageOutput(img))
    For y = 0 To ph - 1
      For x = 0 To pw - 1
        c = PeekL(*px + ((ph - 1 - y) * pw + x) * 4)
        Plot(x, y, RGB(c & 255, (c >> 8) & 255, (c >> 16) & 255))
      Next
    Next
    StopDrawing()
    SaveImage(img, ShotPath$, #PB_ImagePlugin_PNG)
  EndIf
  FreeMemory(*px)
  ShotPath$ = ""
  ShotFrames = -1
EndProcedure

; --- full screen ---------------------------------------------------------------
; A borderless window over the monitor the window is on (no display-mode
; change); the windowed placement and style are kept and put back exactly on
; leaving. F11 or the Full screen button toggles it, Esc leaves it: the CP/M
; console has no keyboard input, so nothing is taken from the machine. Only
; the machine's screen is drawn: the console as an 80 x 24 terminal at a 4:3
; tube's shape, centred on black. The machine runs on unchanged; the pointer
; hides after two idle seconds and comes back when it moves.
#FS_COLS = 80
#FS_ROWS = 24
Global FullScreen.i, FsStyle.i, FsPlacement.WINDOWPLACEMENT, FsCursorHidden.i, FsMouseX.i, FsMouseY.i, FsMouseMs.q
Global FsTermX.f, FsTermY.f, FsTermW.f, FsTermH.f, *FsFont, FsFontFor.f, FsTextW.f

Procedure FsShowCursor(show.i)
  If show And FsCursorHidden : ShowCursor_(#True) : FsCursorHidden = 0 : EndIf
  If show = 0 And FsCursorHidden = 0 : ShowCursor_(#False) : FsCursorHidden = 1 : EndIf
EndProcedure

Procedure EnterFullScreen()
  Protected hwnd.i = WindowID(Win), mi.MONITORINFO
  If FullScreen : ProcedureReturn : EndIf
  FsPlacement\length = SizeOf(WINDOWPLACEMENT) : GetWindowPlacement_(hwnd, @FsPlacement)
  FsStyle = GetWindowLongPtr_(hwnd, #GWL_STYLE)
  mi\cbSize = SizeOf(MONITORINFO) : GetMonitorInfo_(MonitorFromWindow_(hwnd, 2), @mi)   ; 2: the nearest monitor
  SetWindowLongPtr_(hwnd, #GWL_STYLE, FsStyle & ~(#WS_CAPTION | #WS_THICKFRAME | #WS_MINIMIZEBOX | #WS_MAXIMIZEBOX | #WS_SYSMENU))
  SetWindowPos_(hwnd, #HWND_TOP, mi\rcMonitor\left, mi\rcMonitor\top, mi\rcMonitor\right - mi\rcMonitor\left,
                mi\rcMonitor\bottom - mi\rcMonitor\top, #SWP_FRAMECHANGED | #SWP_NOOWNERZORDER | #SWP_SHOWWINDOW)
  FullScreen = 1 : FsMouseMs = ElapsedMilliseconds()
EndProcedure

Procedure LeaveFullScreen()
  Protected hwnd.i = WindowID(Win)
  If FullScreen = 0 : ProcedureReturn : EndIf
  SetWindowLongPtr_(hwnd, #GWL_STYLE, FsStyle)
  SetWindowPlacement_(hwnd, @FsPlacement)
  SetWindowPos_(hwnd, 0, 0, 0, 0, 0, #SWP_FRAMECHANGED | #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOZORDER | #SWP_NOOWNERZORDER)
  FullScreen = 0 : FsShowCursor(1)
EndProcedure

; The window's actions, from the key table.
Procedure DoAction(action.i)
  Select action
    Case #CTL_FULLSCREEN : If FullScreen : LeaveFullScreen() : Else : EnterFullScreen() : EndIf
    Case #CTL_LEAVEFULL : LeaveFullScreen()
  EndSelect
EndProcedure

; The terminal's rectangle on a pw x ph canvas: 4:3, as large as fits, centred.
Procedure FsLayout(pw.i, ph.i)
  FsTermH = ph
  If FsTermH * 4.0 / 3.0 > pw : FsTermH = pw * 3.0 / 4.0 : EndIf
  FsTermW = FsTermH * 4.0 / 3.0
  FsTermX = (pw - FsTermW) / 2 : FsTermY = (ph - FsTermH) / 2
EndProcedure

; Full screen's frame: the CP/M console only, its last 24 rows of 80 columns
; (longer lines wrap, as on a terminal).
Procedure FsDraw(pw.i, ph.i)
  Protected lh.f, px.i, t.s, n.i, i.i, line.s, k.i, x0.f, y0.f, parts.i, j.i
  Protected Dim row.s(#FS_ROWS - 1)
  glClearColor_(0.0, 0.0, 0.0, 1.0) : glClear_(#GL_COLOR_BUFFER_BIT)
  FsLayout(pw, ph)
  Neon_Box(FsTermX, FsTermY, FsTermW, FsTermH, 0.02, 0.045, 0.03)
  lh = FsTermH * 0.92 / #FS_ROWS
  If FsFontFor <> FsTermH
    ; a monospaced font whose line fills a row and whose 80 columns fit the width
    px = Int(lh / 1.2)
    If *FsFont : FreeGLFont(*FsFont) : EndIf
    *FsFont = Neon_CreateFontPx("Consolas", px)
    FsTextW = GetGLTextWidth(*FsFont, LSet("", #FS_COLS, "M"))
    If FsTextW > FsTermW * 0.94
      px = Int(px * FsTermW * 0.94 / FsTextW)
      FreeGLFont(*FsFont) : *FsFont = Neon_CreateFontPx("Consolas", px)
      FsTextW = GetGLTextWidth(*FsFont, LSet("", #FS_COLS, "M"))
    EndIf
    GLFontSetSnapToPixel(*FsFont, #True)
    FsFontFor = FsTermH
  EndIf
  t = IoLog$ + IoLine$
  If t = "" : t = "(no console output yet - Esc leaves full screen)" : EndIf
  ; the last rows, filled from the bottom
  k = #FS_ROWS - 1
  n = CountString(t, #LF$) + 1
  For i = n To 1 Step -1
    line = RTrim(StringField(t, i, #LF$), #CR$)
    If i = n And line = "" And n > 1 : Continue : EndIf
    parts = (Len(line) - 1) / #FS_COLS
    If parts < 0 : parts = 0 : EndIf
    For j = parts To 0 Step -1
      If k < 0 : Break 2 : EndIf
      row(k) = Mid(line, j * #FS_COLS + 1, #FS_COLS) : k - 1
    Next
  Next
  x0 = FsTermX + (FsTermW - FsTextW) / 2 : y0 = FsTermY + FsTermH * 0.04
  ; a terminal fills from the top until it is full, then scrolls
  For i = k + 1 To #FS_ROWS - 1
    If row(i) <> "" : Neon_Text(*FsFont, x0, y0 + (i - k - 1) * lh, row(i), 0.35, 1.0, 0.55) : EndIf
  Next
EndProcedure

; The Controls tab: every key the window answers to, read from controls.pbi.
Procedure ControlsPane(x.f, y.f, w.f, h.f)
  Protected lh.f = Neon_S(19), yy.f = y + Neon_S(4), c1.f = x + Neon_S(14), c2.f = x + Neon_S(240)
  Neon_Text(*Neon_FontBold, c1, yy, "The machine", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB)
  yy + lh
  Neon_Text(*Neon_FontUI, c1, yy, "No keys: the CP/M console only writes (BDOS 2 and 9). No gamepad.", Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  yy + lh * 1.5
  Neon_Text(*Neon_FontBold, c1, yy, "Window", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB)
  Neon_Text(*Neon_FontBold, c2, yy, "Key", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB)
  yy + lh
  ForEach CtlKeys()
    Neon_Text(*Neon_FontUI, c1, yy, CtlKeys()\what$, Neon_C_TextR, Neon_C_TextG, Neon_C_TextB)
    Neon_Text(*Neon_FontMono, c2, yy, CtlKeys()\key$, Neon_C_GrnR, Neon_C_GrnG, Neon_C_GrnB)
    yy + lh
  Next
  Neon_Text(*Neon_FontUI, c1, yy, "Full screen is also the toolbar button. It shows the CP/M console only; the machine runs on.",
            Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  yy + lh * 1.5
  Neon_Text(*Neon_FontBold, c1, yy, "Mouse", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB)
  yy + lh
  Neon_Text(*Neon_FontUI, c1, yy, "Click a disassembly row: set or clear the breakpoint there. Wheel: scroll the pane under the pointer.",
            Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
EndProcedure

; --- the synthetic pointer test ---------------------------------------------

Procedure PtSay(t.s)
  PtReport$ + t + #LF$
EndProcedure

Procedure PtCheck(what.s, ok.i, detail.s)
  PtChecks + 1
  If ok
    PtSay("  ok    " + what)
  Else
    PtFails + 1 : PtSay("  FAIL  " + what + " - " + detail)
  EndIf
EndProcedure

Procedure PtSetup()
  Protected s.s
  ; control | what the click must do
  s = "open|opened reset|reset step|pc step100|stepped speed|realtime1 speed|realtime0 breakat|focus " +
      "runtests|tests memtab1|memtab1 memtab2|memtab2 memtab3|memtab3 memtab0|memtab0 memscroll|memtop " +
      "dis2|break dis2|unbreak logtab2|logtab2 logtab1|logtab1 logtab0|logtab0 logscroll|hover fullscreen|fullscreen zexdoc|zex run|stopifrunning " +
      "zexall|zex run|stopifrunning run|running speed|realtime1 speed|realtime0 run|stopped"
  Protected i.i
  For i = 1 To CountString(s, " ") + 1
    AddElement(PtSteps()) : PtSteps() = StringField(s, i, " ")
  Next
  FirstElement(PtSteps())
  PtSay("pointer test: window scale " + StrF(Neon_UIScale, 3) + ", canvas " + Str(Util_BaseWidth) + "x" + Str(Util_BaseHeight) +
        " physical, window " + Str(Util_WinWidth) + "x" + Str(Util_WinHeight) + " logical")
EndProcedure

Procedure.s PtExpect(act.s)
  Select act
    Case "opened"   : If PtOpened = 0 : ProcedureReturn "Open... did not fire" : EndIf
    Case "reset"    : If Left(Status$, 6) <> "Reset:" : ProcedureReturn Status$ : EndIf
    Case "pc"       : If Z80PC = PtPc : ProcedureReturn "PC stayed " + H4(PtPc) : EndIf
    Case "stepped"  : If Left(Status$, 10) <> "Stepped to" : ProcedureReturn Status$ : EndIf
    Case "realtime1" : If RealTime <> 1 : ProcedureReturn "still full speed" : EndIf
    Case "realtime0" : If RealTime <> 0 : ProcedureReturn "still 4 MHz" : EndIf
    Case "focus"    : If Neon_FocusID <> 301 : ProcedureReturn "focus " + Str(Neon_FocusID) : EndIf
    Case "tests"    : If TestsRun = 0 Or LogTab <> 1 : ProcedureReturn "tests did not run" : EndIf
    Case "memtab0", "memtab1", "memtab2", "memtab3"
      If MemTab <> Val(Right(act, 1)) : ProcedureReturn "memory tab " + Str(MemTab) : EndIf
    Case "logtab0", "logtab1", "logtab2"
      If LogTab <> Val(Right(act, 1)) : ProcedureReturn "output tab " + Str(LogTab) : EndIf
    Case "fullscreen"
      If FullScreen = 0 : ProcedureReturn "did not go full screen" : EndIf
      LeaveFullScreen()
    Case "memtop"   : If MemTop <= PtMemTop : ProcedureReturn "memory top " + Str(PtMemTop) + " -> " + Str(MemTop) : EndIf
    Case "break"    : If BreakAt <> Val("$" + StringField(PtKey$, 2, ":")) : ProcedureReturn "break at " + Str(BreakAt) : EndIf
    Case "unbreak"  : If BreakAt <> -1 : ProcedureReturn "break at " + Str(BreakAt) : EndIf
    Case "zex"
      If FindString(Status$, "not fetched") = 0 And (Running = 0 Or LoadedName$ = "")
        ProcedureReturn "running=" + Str(Running) + " " + Status$
      EndIf
    Case "stopifrunning", "stopped" : If Running : ProcedureReturn "still running" : EndIf
    Case "running"
      ; with nothing loaded the machine runs into the warm-boot HALT at once
      If Running = 0 And (Status$ = PtStatus$ Or FindString(Status$, "ended") = 0)
        ProcedureReturn "did not run: " + Status$
      EndIf
  EndSelect
  ProcedureReturn ""
EndProcedure

; Called at the top of every frame, before Neon_ChromeBeginFrame: reads what
; the last frame drew under the pointer, then sets the pointer for this one.
; Per control: frames 0-9 the four inner corners and one point outside (set,
; then check), 10 press at the bottom-right corner, 11 release, 15 check.
Procedure PtDrive()
  Protected name.s, act.s, k.s, e.s, corner.i, hit.i, x.f, y.f, inset.f = 2
  If PtStep = 0 And PtFrame = 0 : PtSetup() : EndIf
  If ListIndex(PtSteps()) < 0 : PtDone = 1 : ProcedureReturn : EndIf
  name = StringField(PtSteps(), 1, "|") : act = StringField(PtSteps(), 2, "|")
  If PtFrame = 0
    PtKey$ = ""
    ForEach UiBoxes()
      k = MapKey(UiBoxes())
      If k = name Or Left(k, Len(name) + 1) = name + ":" : PtKey$ = k : Break : EndIf
    Next
    If PtKey$ = ""
      PtCheck(name + " is drawn", #False, "no such control")
      PtFrame = 99
    Else
      PtSay(PtKey$)
      PtClick = Bool(act <> "hover" And Not (act = "stopifrunning" And Running = 0))
    EndIf
  EndIf
  If PtFrame < 99 And FindMapElement(UiBoxes(), PtKey$)
    corner = PtFrame / 2
    If PtFrame >= 10 : corner = 3 : EndIf
    Select corner
      Case 0 : x = UiBoxes()\x + inset : y = UiBoxes()\y + inset
      Case 1 : x = UiBoxes()\x + UiBoxes()\w - inset : y = UiBoxes()\y + inset
      Case 2 : x = UiBoxes()\x + inset : y = UiBoxes()\y + UiBoxes()\h - inset
      Case 3 : x = UiBoxes()\x + UiBoxes()\w - inset : y = UiBoxes()\y + UiBoxes()\h - inset
      Case 4 : x = UiBoxes()\x + UiBoxes()\w + inset : y = UiBoxes()\y + UiBoxes()\h + inset
    EndSelect
    If PtFrame < 10 And PtFrame & 1
      ; the last frame drew with the pointer at this point
      hit = Bool(FindString(" " + UiHover$, " " + PtKey$ + " "))
      e = "pointer " + StrF(PtX, 1) + "," + StrF(PtY, 1) + " read as " + StrF(Neon_MX, 1) + "," + StrF(Neon_MY, 1) + ", under it: " + UiHover$
      If corner = 4
        PtCheck("not hovered just outside its bottom-right corner (" + StrF(PtX, 0) + "," + StrF(PtY, 0) + ")", Bool(hit = 0), e)
      Else
        PtCheck("hovered at its " + StringField("top-left top-right bottom-left bottom-right", corner + 1, " ") +
                " corner (" + StrF(PtX, 0) + "," + StrF(PtY, 0) + ")",
                Bool(hit And Abs(Neon_MX - PtX) < 0.51 And Abs(Neon_MY - PtY) < 0.51), e)
      EndIf
    EndIf
    PtX = x : PtY = y : PtDown = 0
    If PtFrame = 10 And PtClick : PtDown = 1 : PtPc = Z80PC : PtMemTop = MemTop : PtOpened = 0 : PtStatus$ = Status$ : EndIf
    If PtFrame = 10 And PtClick = 0 : PtFrame = 99 : EndIf
  EndIf
  If PtFrame = 15
    e = PtExpect(act)
    PtCheck("click does its job (" + act + ")", Bool(e = ""), e)
    PtFrame = 99
  EndIf
  If PtFrame = 99
    PtFrame = 0 : PtStep + 1
    If NextElement(PtSteps()) = 0 : PtDone = 1 : EndIf
  Else
    PtFrame + 1
  EndIf
EndProcedure

Procedure Frame()
  Protected r.RECT, pw.i, ph.i, mx.i, my.i, down.b, w.f, h.f, colW.f, top.f, logH.f, now.q, midH.f
  Protected lw.i, lh.i, s.f, f.i
  SetGadgetAttribute(Gl, #PB_OpenGL_SetContext, #True)
  GetClientRect_(WindowID(Win), @r)
  pw = r\right - r\left : ph = r\bottom - r\top
  If pw < 1 Or ph < 1 : ProcedureReturn : EndIf
  If GadgetWidth(Gl) <> WindowWidth(Win) Or GadgetHeight(Gl) <> WindowHeight(Win)
    ResizeGadget(Gl, 0, 0, WindowWidth(Win), WindowHeight(Win))
  EndIf
  ; Engine hosting block 5a: canvas and viewport are the PHYSICAL client size,
  ; Util_Win* the LOGICAL one, Neon_UIScale = physical / logical, and the mouse
  ; goes in as WindowMouseX/Y give it (already physical: no scaling).
  lw = WindowWidth(Win, #PB_Window_InnerCoordinate) : lh = WindowHeight(Win, #PB_Window_InnerCoordinate)
  If lw < 1 Or lh < 1 : ProcedureReturn : EndIf
  s = pw / lw
  If Abs(s - Neon_UIScale) > 0.01 : BuildFonts(s) : EndIf   ; moved to a monitor with another scale
  Util_BaseWidth = pw : Util_BaseHeight = ph
  Util_WinWidth = lw : Util_WinHeight = lh
  GL_ViewportX = 0 : GL_ViewportY = 0 : GL_ViewportW = pw : GL_ViewportH = ph
  UI_UseCRT = #False     ; no CRT pass here: left on, the barrel warp bends the pointer
  mx = WindowMouseX(Win) : my = WindowMouseY(Win)
  down = Bool(GetAsyncKeyState_(#VK_LBUTTON) & $8000)
  If PtTest
    PtWarm + 1
    If PtWarm > 5 : PtDrive() : EndIf
    mx = PtX : my = PtY : down = PtDown : Wheel = 0 : KeyCode = 0 : KeyChar = 0
    ClearMap(UiBoxes())
  EndIf
  UiRects$ = "" : UiHover$ = ""
  Neon_ChromeBeginFrame(mx, my, down, Wheel, KeyCode, KeyChar, 1.0 / 60.0)
  Wheel = 0 : KeyCode = 0 : KeyChar = 0
  glBindFramebuffer(#GL_FRAMEBUFFER, 0)
  glDisable_(#GL_SCISSOR_TEST)
  glViewport_(0, 0, pw, ph)
  glClearColor_(Neon_C_BgR, Neon_C_BgG, Neon_C_BgB, 1.0)
  glClear_(#GL_COLOR_BUFFER_BIT)

  If Running : RunFor(12) : Else : RealClock = 0 : EndIf
  now = ElapsedMilliseconds()
  If now - RateWindowStart >= 500
    RateShown = RateWindowT * 1000.0 / (now - RateWindowStart)
    RateWindowT = 0 : RateWindowStart = now
  EndIf

  If FullScreen
    FsDraw(pw, ph)
    ; the pointer hides after two idle seconds and comes back when it moves
    If PtTest = 0
      If WindowMouseX(Win) <> FsMouseX Or WindowMouseY(Win) <> FsMouseY
        FsMouseX = WindowMouseX(Win) : FsMouseY = WindowMouseY(Win) : FsMouseMs = now : FsShowCursor(1)
      ElseIf now - FsMouseMs > 2000
        FsShowCursor(0)
      EndIf
    EndIf
  Else
    w = pw : h = ph
    top = Neon_S(52)
    logH = Neon_S(260)
    colW = Neon_S(330)
    midH = h - top - logH - Neon_S(40)
    DrawToolbar(w)
    DrawCpuPanel(Neon_S(8), top, colW, midH)
    DrawDisasm(colW + Neon_S(16), top, Neon_S(470), midH)
    DrawMemory(colW + Neon_S(494), top, w - colW - Neon_S(502), midH)
    DrawLog(Neon_S(8), h - logH - Neon_S(32), w - Neon_S(16), logH)
    Neon_Box(0, h - Neon_S(26), w, Neon_S(26), Neon_C_HeadR, Neon_C_HeadG, Neon_C_HeadB)
    Neon_Text(*Neon_FontSmall, Neon_S(10), h - Neon_S(21), "Program: " + LoadedName$ + "     " + Status$, Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  EndIf
  Neon_ChromeEndFrame()
  If UiLogPath$ <> ""
    f = CreateFile(#PB_Any, UiLogPath$)
    If f
      WriteString(f, UiRects$)
      WriteStringN(f, "HOVER " + UiHover$)
      WriteStringN(f, "STATE running=" + Str(Running) + " logtab=" + Str(LogTab) + " memtab=" + Str(MemTab) +
                      " breakat=" + Str(BreakAt) + " realtime=" + Str(RealTime) + " pc=" + Str(Z80PC) +
                      " memtop=" + Str(MemTop) + " testsrun=" + Str(TestsRun) + " focus=" + Str(Neon_FocusID) +
                      " mx=" + StrF(Neon_MX, 1) + " my=" + StrF(Neon_MY, 1) + " scale=" + StrF(Neon_UIScale, 3) +
                      " loaded=" + LoadedName$)
      WriteStringN(f, "STATUS " + Status$)
      CloseFile(f)
    EndIf
  EndIf
  If ShotPath$ <> ""
    ShotFrames + 1
    If ShotFrames >= ShotAfter And (Running = 0 Or ShotAfter > 0)
      SaveShot(pw, ph)
    EndIf
  EndIf
  SetGadgetAttribute(Gl, #PB_OpenGL_FlipBuffers, #True)
EndProcedure

; The four chrome fonts at logical size * s (engine hosting block 5a).
Procedure BuildFonts(s.f)
  Neon_UIScale = s
  *Neon_FontUI = Neon_CreateFontPx("Segoe UI", Round(14 * s, #PB_Round_Nearest))
  *Neon_FontSmall = Neon_CreateFontPx("Segoe UI", Round(12 * s, #PB_Round_Nearest))
  *Neon_FontBold = Neon_CreateFontPx("Segoe UI", Round(15 * s, #PB_Round_Nearest), #PB_Font_Bold)
  *Neon_FontMono = Neon_CreateFontPx("Consolas", Round(14 * s, #PB_Round_Nearest))
  GLFontSetSnapToPixel(*Neon_FontUI, #True)
  GLFontSetSnapToPixel(*Neon_FontSmall, #True)
  GLFontSetSnapToPixel(*Neon_FontBold, #True)
  GLFontSetSnapToPixel(*Neon_FontMono, #True)
EndProcedure

Procedure.f DisplayScale()
  Protected lib.i, fn.i, dpi.i
  lib = OpenLibrary(#PB_Any, "user32.dll")
  If lib
    fn = GetFunction(lib, "GetDpiForWindow")
    If fn And Win : dpi = CallFunctionFast(fn, WindowID(Win)) : EndIf
    CloseLibrary(lib)
  EndIf
  If dpi <= 0 : ProcedureReturn 1.0 : EndIf
  ProcedureReturn dpi / 96.0
EndProcedure

; --- --fullscreen-test ------------------------------------------------------
; Full screen by its own keys, without the real pointer: F11 is posted to the
; GL gadget and Esc to the window (the engine's Esc shortcut, menu 1001). A
; small program prints to the console and counts in HL, so the check can see
; the machine run on. Checked: the window covers its monitor, the terminal is
; 4:3 and centred, Esc leaves, and the windowed rectangle and style come back.
Global FsTest.i, FsTestFile$, FsTestShot$, FsTestStep.i, FsTestWait.i, FsTestFails.i, FsTestLog$
Global FsTestRect.RECT, FsTestStyle.i, FsTestHL.i

Procedure FsTestCheck(ok.i, what$)
  If ok : FsTestLog$ + "  ok    " : Else : FsTestFails + 1 : FsTestLog$ + "  FAIL  " : EndIf
  FsTestLog$ + what$ + #LF$
EndProcedure

; Prints a few lines through BDOS 9, then counts in HL for ever.
Procedure FsTestProgram()
  Protected m$ = "A>FSTEST" + #CR$ + #LF$ + "PureMetal Z80 - full screen check." + #CR$ + #LF$ +
                 "The CP/M console, 80 x 24, at a 4:3 tube's shape. Esc leaves." + #CR$ + #LF$ + "$"
  Protected *b = AllocateMemory(16 + Len(m$)), i.i
  PokeA(*b, $11) : PokeW(*b + 1, $010C)          ; LD DE,msg
  PokeA(*b + 3, $0E) : PokeA(*b + 4, 9)          ; LD C,9
  PokeA(*b + 5, $CD) : PokeW(*b + 6, $0005)      ; CALL 5
  PokeA(*b + 8, $23)                             ; loop: INC HL
  PokeA(*b + 9, $C3) : PokeW(*b + 10, $0108)     ; JP loop
  For i = 1 To Len(m$) : PokeA(*b + 11 + i, Asc(Mid(m$, i, 1))) : Next
  LoadComFromData(*b, 12 + Len(m$), "fstest.com")
  FreeMemory(*b)
  IoLog$ = "" : IoLine$ = "" : Running = 1 : Status$ = "Running."
EndProcedure

Procedure FsTestTick()
  Protected r.RECT, mi.MONITORINFO, hwnd.i = WindowID(Win), f.i, aspect.f, cw.i, ch.i
  FsTestWait + 1 : If FsTestWait < 30 : ProcedureReturn : EndIf
  FsTestWait = 0 : FsTestStep + 1
  Select FsTestStep
    Case 1
      GetWindowRect_(hwnd, @FsTestRect) : FsTestStyle = GetWindowLongPtr_(hwnd, #GWL_STYLE)
      FsTestLog$ + "windowed: " + Str(FsTestRect\left) + "," + Str(FsTestRect\top) + " " + Str(FsTestRect\right - FsTestRect\left) + "x" +
                   Str(FsTestRect\bottom - FsTestRect\top) + ", scale " + StrF(Neon_UIScale, 2) + #LF$
      FsTestHL = Z80HL
      PostMessage_(GadgetID(Gl), #WM_KEYDOWN, #VK_F11, 0) : PostMessage_(GadgetID(Gl), #WM_KEYUP, #VK_F11, 0)
    Case 2
      GetWindowRect_(hwnd, @r) : mi\cbSize = SizeOf(MONITORINFO) : GetMonitorInfo_(MonitorFromWindow_(hwnd, 2), @mi)
      cw = mi\rcMonitor\right - mi\rcMonitor\left : ch = mi\rcMonitor\bottom - mi\rcMonitor\top
      FsTestCheck(FullScreen, "F11 entered full screen")
      FsTestCheck(Bool(r\left = mi\rcMonitor\left And r\top = mi\rcMonitor\top And r\right = mi\rcMonitor\right And r\bottom = mi\rcMonitor\bottom),
                  "the window covers its monitor " + Str(cw) + "x" + Str(ch))
      FsTestCheck(Bool(Util_BaseWidth = cw And Util_BaseHeight = ch), "the canvas is the whole monitor (" + Str(Util_BaseWidth) + "x" + Str(Util_BaseHeight) + ")")
      aspect = FsTermW / FsTermH
      FsTestCheck(Bool(Abs(aspect - 4.0 / 3.0) < 0.002), "the terminal " + StrF(FsTermW, 1) + "x" + StrF(FsTermH, 1) + " is 4:3 (" + StrF(aspect, 4) + ")")
      FsTestCheck(Bool(Abs(FsTermX * 2 + FsTermW - cw) <= 1 And Abs(FsTermY * 2 + FsTermH - ch) <= 1), "it is centred at " + StrF(FsTermX, 1) + "," + StrF(FsTermY, 1))
      FsTestCheck(Bool(FsTextW > 0 And FsTextW <= FsTermW), "80 columns fit: " + StrF(FsTextW, 1) + " of " + StrF(FsTermW, 1))
      FsTestCheck(Bool(Running And Z80HL <> FsTestHL), "the machine runs on (HL " + H4(FsTestHL) + " -> " + H4(Z80HL) + ")")
      FsTestCheck(Bool(Abs(Neon_UIScale - Util_BaseWidth / Util_WinWidth) < 0.01), "the scale is re-measured: " + StrF(Neon_UIScale, 3))
      If FsTestShot$ <> "" : ShotPath$ = FsTestShot$ : ShotAfter = 1 : ShotFrames = 0 : EndIf
    Case 3
      PostMessage_(hwnd, #WM_KEYDOWN, #VK_ESCAPE, 0) : PostMessage_(hwnd, #WM_KEYUP, #VK_ESCAPE, 0)
    Case 4
      GetWindowRect_(hwnd, @r)
      FsTestCheck(Bool(FullScreen = 0), "Esc left full screen")
      FsTestCheck(Bool(r\left = FsTestRect\left And r\top = FsTestRect\top And r\right = FsTestRect\right And r\bottom = FsTestRect\bottom),
                  "the windowed rectangle came back: " + Str(r\left) + "," + Str(r\top) + " " + Str(r\right - r\left) + "x" + Str(r\bottom - r\top))
      FsTestCheck(Bool(GetWindowLongPtr_(hwnd, #GWL_STYLE) = FsTestStyle), "the window's frame and style came back")
      FsTestCheck(Bool(Abs(Neon_UIScale - Util_BaseWidth / Util_WinWidth) < 0.01), "the scale is re-measured: " + StrF(Neon_UIScale, 3))
      FsTestLog$ + "fullscreen-test: failures=" + Str(FsTestFails) + StringField(" PASS| FAIL", Bool(FsTestFails > 0) + 1, "|") + #LF$
      f = CreateFile(#PB_Any, FsTestFile$) : If f : WriteString(f, FsTestLog$) : CloseFile(f) : EndIf
      PtDone = 2
  EndSelect
EndProcedure

Procedure WindowMain()
  Protected ev.i, s.f, w.i = 1440, h.i = 900, quit.i, et.i, sc.f, f.i
  ExamineDesktops()
  ; the start size is LOGICAL; the work area is physical
  sc = DesktopResolutionX()
  If sc <= 0 : sc = 1 : EndIf
  If w > DesktopWidth(0) / sc - 40 : w = DesktopWidth(0) / sc - 40 : EndIf
  If h > DesktopHeight(0) / sc - 80 : h = DesktopHeight(0) / sc - 80 : EndIf
  Gl = OpenGLWindow("Z80 emulator - PureBasic, Neon Arcade", w, h,
                    #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_SizeGadget | #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget)
  Win = Util_MainWindowID
  BuildFonts(DisplayScale())
  RateWindowStart = ElapsedMilliseconds()
  Repeat
    Repeat
      ev = WindowEvent()
      If ev = #PB_Event_CloseWindow : quit = 1 : EndIf
      ; the engine maps Esc to menu event 1001 on the window
      If ev = #PB_Event_Menu And EventMenu() = 1001 : DoAction(CtlAction(#VK_ESCAPE)) : EndIf
      If ev = #PB_Event_Gadget And EventGadget() = Gl
        et = EventType()
        If et = #PB_EventType_MouseWheel
          Wheel + GetGadgetAttribute(Gl, #PB_OpenGL_WheelDelta)
        ElseIf et = #PB_EventType_KeyDown
          KeyCode = GetGadgetAttribute(Gl, #PB_OpenGL_Key)
          If CtlAction(KeyCode) : DoAction(CtlAction(KeyCode)) : EndIf   ; F11 (controls.pbi)
        ElseIf et = #PB_EventType_Input
          KeyChar = GetGadgetAttribute(Gl, #PB_OpenGL_Input)
        EndIf
      EndIf
    Until ev = 0
    Frame()
    If FsTest : FsTestTick() : EndIf
    If ShotFrames < 0 And FsTest = 0 : quit = 1 : EndIf
    If PtDone = 2 : quit = 1 : EndIf
    If PtDone = 1
      PtSay("pointer test: checks=" + Str(PtChecks) + " failures=" + Str(PtFails) + StringField(" PASS| FAIL", Bool(PtFails > 0) + 1, "|"))
      f = CreateFile(#PB_Any, PtOut$)
      If f : WriteString(f, PtReport$) : CloseFile(f) : EndIf
      quit = 1
    EndIf
    If Running = 0 : Delay(10) : EndIf
  Until quit
  LeaveFullScreen()
  FsShowCursor(1)
EndProcedure

UsePNGImageEncoder()
Z80Reset()
CpmPageZero()
Define argi.i, arg$, showTests.i, startRun.i, zex.i = -1
For argi = 0 To CountProgramParameters() - 1
  arg$ = ProgramParameter(argi)
  Select LCase(arg$)
    Case "--show-tests" : showTests = 1
    Case "--run" : startRun = 1
    Case "--zexdoc" : zex = 0
    Case "--zexall" : zex = 1
    Case "--screenshot" : argi + 1 : ShotPath$ = ProgramParameter(argi)
    Case "--shot-after" : argi + 1 : ShotAfter = Val(ProgramParameter(argi))
    Case "--ui-log" : argi + 1 : UiLogPath$ = ProgramParameter(argi)
    Case "--pointer-test" : argi + 1 : PtOut$ = ProgramParameter(argi) : PtTest = 1
    Case "--fullscreen-test" : argi + 1 : FsTestFile$ = ProgramParameter(argi) : FsTest = 1
    Case "--fullscreen-shot" : argi + 1 : FsTestShot$ = ProgramParameter(argi)
    Case "--output-tab" : argi + 1 : LogTab = Val(ProgramParameter(argi))
    Default
      If LoadProgram(arg$)
        Status$ = "Loaded " + LoadedName$ + " (" + Str(LoadedSize) + " bytes)."
      EndIf
  EndSelect
Next
CtlInit()
If FsTest : FsTestProgram() : EndIf
If showTests : RunTestsInWindow() : EndIf
If zex >= 0 : StartExerciser(zex) : EndIf
If startRun : Running = 1 : EndIf
WindowMain()
