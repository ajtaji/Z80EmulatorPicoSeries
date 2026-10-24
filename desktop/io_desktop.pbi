; The board programs' output helpers (tests/io.pico), for the desktop: the
; same names, writing to a log the window shows and, in a console build, to
; the console. USB servicing and the watchdog do not exist here.
Global IoLine$, IoLog$, IoConsole.i, IoQpcFreq.q

Procedure.q Micros()
  Protected c.q
  If IoQpcFreq = 0 : QueryPerformanceFrequency_(@IoQpcFreq) : EndIf
  QueryPerformanceCounter_(@c)
  ProcedureReturn (c / IoQpcFreq) * 1000000 + ((c % IoQpcFreq) * 1000000) / IoQpcFreq
EndProcedure
Procedure IoFlushLine()
  IoLog$ + IoLine$ + #LF$
  If IoConsole : PrintN(IoLine$) : EndIf
  IoLine$ = ""
  If Len(IoLog$) > 400000 : IoLog$ = Right(IoLog$, 300000) : EndIf
EndProcedure
Procedure PutC(c.i)
  c & 255
  If c = 10
    IoFlushLine()
  ElseIf c >= 32 And c < 127
    IoLine$ + Chr(c)
  EndIf
EndProcedure
Procedure Say(t.s)
  Protected i.i
  For i = 1 To Len(t)
    PutC(Asc(Mid(t, i, 1)))
  Next
EndProcedure
Procedure SayA(*p)
  While PeekA(*p)
    PutC(PeekA(*p))
    *p + 1
  Wend
EndProcedure
Procedure Num(v.i)
  Say(Str(v))
EndProcedure
Procedure HexN(v.i, digits.i)
  Say(RSet(Hex(v & ((1 << (digits * 4)) - 1)), digits, "0"))
EndProcedure
Procedure Eol()
  PutC(10)
EndProcedure
Procedure UsbSerialTask()
EndProcedure
Procedure UsbSerialFlush()
EndProcedure
Procedure SafetyPet()
EndProcedure
Procedure.i Rate(count.i, us.i)
  If us <= 0 : ProcedureReturn 0 : EndIf
  ProcedureReturn (count * 1000000) / us
EndProcedure
