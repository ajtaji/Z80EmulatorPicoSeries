; The controls: every key the window answers to, in ONE table. The window's
; key handling, the Controls tab and the Full screen button's label all read
; it, so what the window shows is what it does.
;
; The emulated machine takes no keys: its CP/M console only writes (BDOS 2
; and 9), and there is no gamepad input. Every key here is the window's own.

#CTL_FULLSCREEN = 1
#CTL_LEAVEFULL  = 2

Structure CtlBinding
  action.i      ; #CTL_*
  key.i         ; a #PB_Shortcut_ code (the virtual-key code on Windows, the X keysym on Linux)
  key$          ; the key as the window shows it
  what$         ; what it does
EndStructure
Global NewList CtlKeys.CtlBinding()

Procedure CtlInit()
  Protected a.i, k.i, n$, w$
  ClearList(CtlKeys())
  Restore CtlKeyTable
  Repeat
    Read.i a : If a < 0 : Break : EndIf
    Read.i k : Read.s n$ : Read.s w$
    AddElement(CtlKeys()) : CtlKeys()\action = a : CtlKeys()\key = k : CtlKeys()\key$ = n$ : CtlKeys()\what$ = w$
  ForEver
EndProcedure

; The window action a key starts (0: none).
Procedure.i CtlAction(key.i)
  ForEach CtlKeys()
    If CtlKeys()\key = key : ProcedureReturn CtlKeys()\action : EndIf
  Next
  ProcedureReturn 0
EndProcedure

; The key(s) for a window action, as shown ("F11").
Procedure.s CtlActionKeys(action.i)
  Protected t$
  ForEach CtlKeys()
    If CtlKeys()\action = action
      If t$ <> "" : t$ + " / " : EndIf
      t$ + CtlKeys()\key$
    EndIf
  Next
  ProcedureReturn t$
EndProcedure

DataSection
  CtlKeyTable:
  ; action, key, key as shown, what it does
  Data.i #CTL_FULLSCREEN, #PB_Shortcut_F11 : Data.s "F11", "full screen on / off"
  Data.i #CTL_LEAVEFULL, #PB_Shortcut_Escape : Data.s "Esc", "leave full screen"
  Data.i -1
EndDataSection
