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
EnableExplicit

; The engine first (its procedures use plain names the test code also uses).
CompilerIf Not Defined(GL_ENGINE_DIR$, #PB_Constant)
  #GL_ENGINE_DIR$ = "C:/Users/ajtaj/Desktop/Neon-Arcade-Dispay-Engine/"
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

Global Win.i, Gl.i
Global Running.i, BreakAt.i = -1, BreakText.String, BreakCaret.i
Global Status$ = "Load a CP/M .COM program, or run ZEXDOC / ZEXALL or the test suites."
Global RateShown.d, RateWindowT.q, RateWindowStart.q
Global DisTop.i, MemTab.i, MemTop.i, LogTab.i, LogTop.i
Global Wheel.i, KeyCode.i, KeyChar.i
Global TestsRun.i, TestsFailed.i, TestLog$, ShotPath$, ShotFrames.i, ShotAfter.i = 120
Global RealTime.i, RealClock.q, RealDone.q

#REAL_KHZ = 4000     ; a 4 MHz Z80 in real-time mode

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
  ZexLoad(all)
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
  rows = Int((h - Neon_S(70)) / lh)
  If MemTab = 0
    If Neon_Hit(x, y, w, h) And Wheel : MemTop - Wheel * 3 : EndIf
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
  LogTab = Neon_TabStrip(201, x + Neon_S(2), y + Neon_S(28), w - Neon_S(4), Neon_S(26), "CP/M console (BDOS 2, 9)|Test results", LogTab)
  If LogTab = 0 : t = IoLog$ + IoLine$ : Else : t = TestLog$ : EndIf
  If t = "" : t = "(nothing yet)" : EndIf
  n = CountString(t, #LF$) + 1
  rows = Int((h - Neon_S(66)) / lh)
  ; follow the end while output grows, unless scrolled away
  If Neon_Hit(x, y, w, h) And Wheel : LogTop - Wheel * 3 : EndIf
  If Running And LogTab = 0 : LogTop = n - rows : EndIf
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
  If Neon_Button(x, y, Neon_S(80), bh, "Open...")
    f = OpenFileRequester("Load a Z80 program", "", "CP/M program (*.com)|*.com|Raw image at 0 (*.bin;*.rom)|*.bin;*.rom|All files (*.*)|*.*", 0)
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
  If Neon_Button(x, y, Neon_S(64), bh, "Reset")
    Running = 0 : Z80Reset() : Status$ = "Reset: PC 0000h, interrupts off. Memory kept."
  EndIf
  x + Neon_S(72)
  label = "Run"
  If Running : label = "Stop" : EndIf
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
  If Neon_Button(x, y, Neon_S(60), bh, "Step", #False, Bool(Running = 0))
    StepOne() : Status$ = "Stepped to " + H4(Z80PC) + "h."
  EndIf
  x + Neon_S(68)
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
  If Neon_TextInput(301, x, y, Neon_S(70), bh, @BreakText, "hex", @BreakCaret)
    If Trim(BreakText\s) = "" : BreakAt = -1 : Else : BreakAt = Val("$" + Trim(BreakText\s)) & $FFFF : EndIf
  EndIf
  x + Neon_S(78)
  If Neon_Button(x, y, Neon_S(96), bh, "Run tests", Bool(TestsRun And TestsFailed = 0))
    RunTestsInWindow()
  EndIf
  x + Neon_S(104)
  If Neon_Button(x, y, Neon_S(84), bh, "ZEXDOC")
    StartExerciser(0)
  EndIf
  x + Neon_S(92)
  If Neon_Button(x, y, Neon_S(84), bh, "ZEXALL")
    StartExerciser(1)
  EndIf
  x + Neon_S(92)
  label = "Full speed"
  If RealTime : label = "4 MHz" : EndIf
  If Neon_Button(x, y, Neon_S(96), bh, label, RealTime)
    RealTime = Bool(RealTime = 0) : RealClock = 0
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

Procedure Frame()
  Protected r.RECT, pw.i, ph.i, mx.i, my.i, down.b, w.f, h.f, colW.f, top.f, logH.f, now.q, midH.f
  SetGadgetAttribute(Gl, #PB_OpenGL_SetContext, #True)
  GetClientRect_(WindowID(Win), @r)
  pw = r\right - r\left : ph = r\bottom - r\top
  If pw < 1 Or ph < 1 : ProcedureReturn : EndIf
  If GadgetWidth(Gl) <> WindowWidth(Win) Or GadgetHeight(Gl) <> WindowHeight(Win)
    ResizeGadget(Gl, 0, 0, WindowWidth(Win), WindowHeight(Win))
  EndIf
  Util_BaseWidth = pw : Util_BaseHeight = ph
  ; the logical size that DesktopScaledX/Y() turns back into the physical drawable
  Util_WinWidth = Round(pw / DesktopResolutionX(), #PB_Round_Nearest)
  Util_WinHeight = Round(ph / DesktopResolutionY(), #PB_Round_Nearest)
  GL_ViewportX = 0 : GL_ViewportY = 0 : GL_ViewportW = pw : GL_ViewportH = ph
  mx = WindowMouseX(Win) * DesktopResolutionX() : my = WindowMouseY(Win) * DesktopResolutionY()
  down = Bool(GetAsyncKeyState_(#VK_LBUTTON) & $8000)
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
  Neon_ChromeEndFrame()
  If ShotPath$ <> ""
    ShotFrames + 1
    If ShotFrames >= ShotAfter And (Running = 0 Or ShotAfter > 0)
      SaveShot(pw, ph)
    EndIf
  EndIf
  SetGadgetAttribute(Gl, #PB_OpenGL_FlipBuffers, #True)
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

Procedure WindowMain()
  Protected ev.i, s.f, w.i = 1440, h.i = 900, quit.i, et.i, sc.f
  ExamineDesktops()
  ; the start size is LOGICAL; the work area is physical
  sc = DesktopResolutionX()
  If sc <= 0 : sc = 1 : EndIf
  If w > DesktopWidth(0) / sc - 40 : w = DesktopWidth(0) / sc - 40 : EndIf
  If h > DesktopHeight(0) / sc - 80 : h = DesktopHeight(0) / sc - 80 : EndIf
  Gl = OpenGLWindow("Z80 emulator - PureBasic, Neon Arcade", w, h,
                    #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_SizeGadget | #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget)
  Win = Util_MainWindowID
  s = DisplayScale()
  Neon_UIScale = s
  *Neon_FontUI = Neon_CreateFontPx("Segoe UI", Round(14 * s, #PB_Round_Nearest))
  *Neon_FontSmall = Neon_CreateFontPx("Segoe UI", Round(12 * s, #PB_Round_Nearest))
  *Neon_FontBold = Neon_CreateFontPx("Segoe UI", Round(15 * s, #PB_Round_Nearest), #PB_Font_Bold)
  *Neon_FontMono = Neon_CreateFontPx("Consolas", Round(14 * s, #PB_Round_Nearest))
  GLFontSetSnapToPixel(*Neon_FontUI, #True)
  GLFontSetSnapToPixel(*Neon_FontSmall, #True)
  GLFontSetSnapToPixel(*Neon_FontBold, #True)
  GLFontSetSnapToPixel(*Neon_FontMono, #True)
  RateWindowStart = ElapsedMilliseconds()
  Repeat
    Repeat
      ev = WindowEvent()
      If ev = #PB_Event_CloseWindow : quit = 1 : EndIf
      If ev = #PB_Event_Gadget And EventGadget() = Gl
        et = EventType()
        If et = #PB_EventType_MouseWheel
          Wheel + GetGadgetAttribute(Gl, #PB_OpenGL_WheelDelta)
        ElseIf et = #PB_EventType_KeyDown
          KeyCode = GetGadgetAttribute(Gl, #PB_OpenGL_Key)
        ElseIf et = #PB_EventType_Input
          KeyChar = GetGadgetAttribute(Gl, #PB_OpenGL_Input)
        EndIf
      EndIf
    Until ev = 0
    Frame()
    If ShotFrames < 0 : quit = 1 : EndIf
    If Running = 0 : Delay(10) : EndIf
  Until quit
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
    Default
      If LoadProgram(arg$)
        Status$ = "Loaded " + LoadedName$ + " (" + Str(LoadedSize) + " bytes)."
      EndIf
  EndSelect
Next
If showTests : RunTestsInWindow() : EndIf
If zex >= 0 : StartExerciser(zex) : EndIf
If startRun : Running = 1 : EndIf
WindowMain()
