; Z80 disassembler for the desktop front end (and any machine on the core):
;   text$ = Z80Disasm(addr, @length)
; Every opcode of every page, documented and undocumented, in Zilog
; mnemonics; undocumented forms are spelt as their effect (SLL, IXH, the
; DDCB register copies "RLC (IX+d),B", IN F,(C), OUT (C),0, ED mirrors).
; Reads Z80Mem only, never the hooks.

Procedure.s Z80DisH2(v.i)
  ProcedureReturn RSet(Hex(v & $FF), 2, "0")
EndProcedure
Procedure.s Z80DisH4(v.i)
  ProcedureReturn RSet(Hex(v & $FFFF), 4, "0")
EndProcedure
Procedure.i Z80DisByte(a.i)
  ProcedureReturn Z80Mem(a & $FFFF)
EndProcedure
Procedure.s Z80DisDisp(d.i)
  If d & $80
    ProcedureReturn "-" + Z80DisH2(256 - d) + "h"
  EndIf
  ProcedureReturn "+" + Z80DisH2(d) + "h"
EndProcedure

; Register names for an index prefix: 0 none, 1 IX, 2 IY. (HL) becomes
; (IX+d) with the displacement already read into disp.
Procedure.s Z80DisR(r.i, idx.i, disp.i)
  Protected ix$
  Select idx
    Case 1 : ix$ = "IX"
    Case 2 : ix$ = "IY"
  EndSelect
  Select r
    Case 0 : ProcedureReturn "B"
    Case 1 : ProcedureReturn "C"
    Case 2 : ProcedureReturn "D"
    Case 3 : ProcedureReturn "E"
    Case 4 : If idx : ProcedureReturn ix$ + "H" : EndIf : ProcedureReturn "H"
    Case 5 : If idx : ProcedureReturn ix$ + "L" : EndIf : ProcedureReturn "L"
    Case 6 : If idx : ProcedureReturn "(" + ix$ + Z80DisDisp(disp) + ")" : EndIf : ProcedureReturn "(HL)"
  EndSelect
  ProcedureReturn "A"
EndProcedure
Procedure.s Z80DisRP(p.i, idx.i)
  Select p
    Case 0 : ProcedureReturn "BC"
    Case 1 : ProcedureReturn "DE"
    Case 2
      Select idx
        Case 1 : ProcedureReturn "IX"
        Case 2 : ProcedureReturn "IY"
      EndSelect
      ProcedureReturn "HL"
  EndSelect
  ProcedureReturn "SP"
EndProcedure
Procedure.s Z80DisRP2(p.i, idx.i)
  If p = 3 : ProcedureReturn "AF" : EndIf
  ProcedureReturn Z80DisRP(p, idx)
EndProcedure
Procedure.s Z80DisCC(c.i)
  ProcedureReturn StringField("NZ,Z,NC,C,PO,PE,P,M", c + 1, ",")
EndProcedure
Procedure.s Z80DisAlu(y.i)
  ProcedureReturn StringField("ADD A,|ADC A,|SUB |SBC A,|AND |XOR |OR |CP ", y + 1, "|")
EndProcedure
Procedure.s Z80DisRot(y.i)
  ProcedureReturn StringField("RLC,RRC,RL,RR,SLA,SRA,SLL,SRL", y + 1, ",")
EndProcedure

Procedure.s Z80Disasm(adr.i, *len.Integer)
  Protected p.i = adr & $FFFF, op.i, idx.i, x.i, y.i, z.i, q.i, pp.i, d.i, n.i, nn.i, t$, op2.i
  op = Z80DisByte(p) : p + 1
  If op = $DD Or op = $FD
    idx = 1 + Bool(op = $FD)
    op = Z80DisByte(p)
    If op = $DD Or op = $FD Or op = $ED
      ; a prefix the next byte overrides: a 4 T-state NOP on its own
      If *len : *len\i = 1 : EndIf
      ProcedureReturn "NOP*  (" + StringField("DD,FD", idx, ",") + " ignored)"
    EndIf
    p + 1
  EndIf
  x = op >> 6 : y = (op >> 3) & 7 : z = op & 7 : q = y & 1 : pp = y >> 1

  If op = $CB
    If idx
      d = Z80DisByte(p) : p + 1
      op2 = Z80DisByte(p) : p + 1
      x = op2 >> 6 : y = (op2 >> 3) & 7 : z = op2 & 7
      Select x
        Case 0 : t$ = Z80DisRot(y) + " " + Z80DisR(6, idx, d)
        Case 1 : t$ = "BIT " + Str(y) + "," + Z80DisR(6, idx, d)
        Case 2 : t$ = "RES " + Str(y) + "," + Z80DisR(6, idx, d)
        Case 3 : t$ = "SET " + Str(y) + "," + Z80DisR(6, idx, d)
      EndSelect
      If x <> 1 And z <> 6 : t$ + "," + Z80DisR(z, 0, 0) : EndIf
    Else
      op2 = Z80DisByte(p) : p + 1
      x = op2 >> 6 : y = (op2 >> 3) & 7 : z = op2 & 7
      Select x
        Case 0 : t$ = Z80DisRot(y) + " " + Z80DisR(z, 0, 0)
        Case 1 : t$ = "BIT " + Str(y) + "," + Z80DisR(z, 0, 0)
        Case 2 : t$ = "RES " + Str(y) + "," + Z80DisR(z, 0, 0)
        Case 3 : t$ = "SET " + Str(y) + "," + Z80DisR(z, 0, 0)
      EndSelect
    EndIf
  ElseIf op = $ED
    op2 = Z80DisByte(p) : p + 1
    x = op2 >> 6 : y = (op2 >> 3) & 7 : z = op2 & 7 : q = y & 1 : pp = y >> 1
    t$ = "NOP*  (ED " + Z80DisH2(op2) + ")"
    If x = 1
      Select z
        Case 0
          If y = 6 : t$ = "IN F,(C)" : Else : t$ = "IN " + Z80DisR(y, 0, 0) + ",(C)" : EndIf
        Case 1
          If y = 6 : t$ = "OUT (C),0" : Else : t$ = "OUT (C)," + Z80DisR(y, 0, 0) : EndIf
        Case 2
          If q = 0 : t$ = "SBC HL," : Else : t$ = "ADC HL," : EndIf
          t$ + Z80DisRP(pp, 0)
        Case 3
          nn = Z80DisByte(p) | (Z80DisByte(p + 1) << 8) : p + 2
          If q = 0
            t$ = "LD (" + Z80DisH4(nn) + "h)," + Z80DisRP(pp, 0)
          Else
            t$ = "LD " + Z80DisRP(pp, 0) + ",(" + Z80DisH4(nn) + "h)"
          EndIf
        Case 4 : t$ = "NEG"
        Case 5
          If y = 1 : t$ = "RETI" : Else : t$ = "RETN" : EndIf
        Case 6 : t$ = "IM " + StringField("0,0,1,2,0,0,1,2", y + 1, ",")
        Case 7
          Select y
            Case 0 : t$ = "LD I,A"
            Case 1 : t$ = "LD R,A"
            Case 2 : t$ = "LD A,I"
            Case 3 : t$ = "LD A,R"
            Case 4 : t$ = "RRD"
            Case 5 : t$ = "RLD"
          EndSelect
      EndSelect
    ElseIf x = 2 And z <= 3 And y >= 4
      t$ = StringField("LDI,CPI,INI,OUTI,LDD,CPD,IND,OUTD,LDIR,CPIR,INIR,OTIR,LDDR,CPDR,INDR,OTDR", (y - 4) * 4 + z + 1, ",")
    EndIf
  Else
    ; the base page, with HL/H/L/(HL) replaced under an index prefix
    If idx And ((x = 1 And (y = 6 Or z = 6) And op <> $76) Or (x = 2 And z = 6) Or (x = 0 And (z = 4 Or z = 5 Or z = 6) And y = 6))
      d = Z80DisByte(p) : p + 1
    EndIf
    Select x
      Case 0
        Select z
          Case 0
            Select y
              Case 0 : t$ = "NOP"
              Case 1 : t$ = "EX AF,AF'"
              Case 2, 3
                n = Z80DisByte(p) : p + 1
                nn = (p + n - 256 * Bool(n & $80)) & $FFFF
                If y = 2 : t$ = "DJNZ " : Else : t$ = "JR " : EndIf
                t$ + Z80DisH4(nn) + "h"
              Default
                n = Z80DisByte(p) : p + 1
                nn = (p + n - 256 * Bool(n & $80)) & $FFFF
                t$ = "JR " + Z80DisCC(y - 4) + "," + Z80DisH4(nn) + "h"
            EndSelect
          Case 1
            If q = 0
              nn = Z80DisByte(p) | (Z80DisByte(p + 1) << 8) : p + 2
              t$ = "LD " + Z80DisRP(pp, idx) + "," + Z80DisH4(nn) + "h"
            Else
              t$ = "ADD " + Z80DisRP(2, idx) + "," + Z80DisRP(pp, idx)
            EndIf
          Case 2
            Select y
              Case 0 : t$ = "LD (BC),A"
              Case 1 : t$ = "LD A,(BC)"
              Case 2 : t$ = "LD (DE),A"
              Case 3 : t$ = "LD A,(DE)"
              Default
                nn = Z80DisByte(p) | (Z80DisByte(p + 1) << 8) : p + 2
                Select y
                  Case 4 : t$ = "LD (" + Z80DisH4(nn) + "h)," + Z80DisRP(2, idx)
                  Case 5 : t$ = "LD " + Z80DisRP(2, idx) + ",(" + Z80DisH4(nn) + "h)"
                  Case 6 : t$ = "LD (" + Z80DisH4(nn) + "h),A"
                  Case 7 : t$ = "LD A,(" + Z80DisH4(nn) + "h)"
                EndSelect
            EndSelect
          Case 3
            If q = 0 : t$ = "INC " : Else : t$ = "DEC " : EndIf
            t$ + Z80DisRP(pp, idx)
          Case 4 : t$ = "INC " + Z80DisR(y, idx, d)
          Case 5 : t$ = "DEC " + Z80DisR(y, idx, d)
          Case 6
            n = Z80DisByte(p) : p + 1
            t$ = "LD " + Z80DisR(y, idx, d) + "," + Z80DisH2(n) + "h"
          Case 7
            t$ = StringField("RLCA,RRCA,RLA,RRA,DAA,CPL,SCF,CCF", y + 1, ",")
        EndSelect
      Case 1
        If op = $76
          t$ = "HALT"
        ElseIf y = 6 Or z = 6
          ; with (IX+d) the other operand is the real H or L
          If y = 6
            t$ = "LD " + Z80DisR(6, idx, d) + "," + Z80DisR(z, 0, 0)
          Else
            t$ = "LD " + Z80DisR(y, 0, 0) + "," + Z80DisR(6, idx, d)
          EndIf
        Else
          t$ = "LD " + Z80DisR(y, idx, d) + "," + Z80DisR(z, idx, d)
        EndIf
      Case 2
        t$ = Z80DisAlu(y) + Z80DisR(z, idx, d)
      Case 3
        Select z
          Case 0 : t$ = "RET " + Z80DisCC(y)
          Case 1
            If q = 0
              t$ = "POP " + Z80DisRP2(pp, idx)
            Else
              Select pp
                Case 0 : t$ = "RET"
                Case 1 : t$ = "EXX"
                Case 2 : t$ = "JP (" + Z80DisRP(2, idx) + ")"
                Case 3 : t$ = "LD SP," + Z80DisRP(2, idx)
              EndSelect
            EndIf
          Case 2
            nn = Z80DisByte(p) | (Z80DisByte(p + 1) << 8) : p + 2
            t$ = "JP " + Z80DisCC(y) + "," + Z80DisH4(nn) + "h"
          Case 3
            Select y
              Case 0
                nn = Z80DisByte(p) | (Z80DisByte(p + 1) << 8) : p + 2
                t$ = "JP " + Z80DisH4(nn) + "h"
              Case 2
                n = Z80DisByte(p) : p + 1
                t$ = "OUT (" + Z80DisH2(n) + "h),A"
              Case 3
                n = Z80DisByte(p) : p + 1
                t$ = "IN A,(" + Z80DisH2(n) + "h)"
              Case 4 : t$ = "EX (SP)," + Z80DisRP(2, idx)
              Case 5 : t$ = "EX DE,HL"
              Case 6 : t$ = "DI"
              Case 7 : t$ = "EI"
            EndSelect
          Case 4
            nn = Z80DisByte(p) | (Z80DisByte(p + 1) << 8) : p + 2
            t$ = "CALL " + Z80DisCC(y) + "," + Z80DisH4(nn) + "h"
          Case 5
            If q = 0
              t$ = "PUSH " + Z80DisRP2(pp, idx)
            Else
              nn = Z80DisByte(p) | (Z80DisByte(p + 1) << 8) : p + 2
              t$ = "CALL " + Z80DisH4(nn) + "h"
            EndIf
          Case 6
            n = Z80DisByte(p) : p + 1
            t$ = Z80DisAlu(y) + Z80DisH2(n) + "h"
          Case 7 : t$ = "RST " + Z80DisH2(y * 8) + "h"
        EndSelect
    EndSelect
  EndIf
  If *len : *len\i = (p - adr) & $FFFF : EndIf
  ProcedureReturn t$
EndProcedure
