; Disassembler self-check: known encodings and the text they must give
; (console --distest). Each case: bytes as hex, expected text, expected length.
DataSection
DisCases:
  Data.s "00", "NOP", "1"
  Data.s "3E7F", "LD A,7Fh", "2"
  Data.s "2134 12", "LD HL,1234h", "3"
  Data.s "DD2134 12", "LD IX,1234h", "4"
  Data.s "DD7E05", "LD A,(IX+05h)", "3"
  Data.s "FD77FE", "LD (IY-02h),A", "3"
  Data.s "DD3610 99", "LD (IX+10h),99h", "4"
  Data.s "DD66 01", "LD H,(IX+01h)", "3"
  Data.s "DD64", "LD IXH,IXH", "2"
  Data.s "FD7D", "LD A,IYL", "2"
  Data.s "DDE9", "JP (IX)", "2"
  Data.s "DDEB", "EX DE,HL", "2"
  Data.s "CB37", "SLL A", "2"
  Data.s "CB46", "BIT 0,(HL)", "2"
  Data.s "DDCB0306", "RLC (IX+03h)", "4"
  Data.s "DDCB0300", "RLC (IX+03h),B", "4"
  Data.s "FDCBFF7E", "BIT 7,(IY-01h)", "4"
  Data.s "FDCB10C1", "SET 0,(IY+10h),C", "4"
  Data.s "ED70", "IN F,(C)", "2"
  Data.s "ED71", "OUT (C),0", "2"
  Data.s "ED4B 3412", "LD BC,(1234h)", "4"
  Data.s "ED5F", "LD A,R", "2"
  Data.s "EDB0", "LDIR", "2"
  Data.s "EDBB", "OTDR", "2"
  Data.s "ED4C", "NEG", "2"
  Data.s "ED7E", "IM 2", "2"
  Data.s "ED00", "NOP*  (ED 00)", "2"
  Data.s "18FE", "JR 0100h", "2"
  Data.s "10FE", "DJNZ 0100h", "2"
  Data.s "20 02", "JR NZ,0104h", "2"
  Data.s "C3 0001", "JP 0100h", "3"
  Data.s "CD 3412", "CALL 1234h", "3"
  Data.s "FF", "RST 38h", "1"
  Data.s "D3FE", "OUT (FEh),A", "2"
  Data.s "08", "EX AF,AF'", "1"
  Data.s "DDDD00", "NOP*  (DD ignored)", "1"
  Data.s "76", "HALT", "1"
  Data.s "DD09", "ADD IX,BC", "2"
  Data.s "DD29", "ADD IX,IX", "2"
  Data.s "DDE3", "EX (SP),IX", "2"
  Data.s "", "", ""
EndDataSection

Procedure.i RunDisTest()
  Protected b$, want$, wlen.i, got$, n.i, i.i, fails.i, cases.i
  Restore DisCases
  Repeat
    Read.s b$ : Read.s want$ : Read.s got$
    If b$ = "" : Break : EndIf
    wlen = Val(got$)
    b$ = RemoveString(b$, " ")
    FillMemory(@Z80Mem($100), 8, 0)
    For i = 0 To Len(b$) / 2 - 1
      Z80Mem($100 + i) = Val("$" + Mid(b$, i * 2 + 1, 2))
    Next
    got$ = Z80Disasm($100, @n)
    cases + 1
    If got$ <> want$ Or n <> wlen
      fails + 1
      Say("disasm FAIL " + b$ + ": got '" + got$ + "' length " + Str(n) + ", want '" + want$ + "' length " + Str(wlen)) : Eol()
    EndIf
  ForEver
  Say("disassembler cases=" + Str(cases) + " failures=" + Str(fails))
  If fails = 0 : Say(" PASS") : Else : Say(" FAIL") : EndIf
  Eol()
  ProcedureReturn fails
EndProcedure
