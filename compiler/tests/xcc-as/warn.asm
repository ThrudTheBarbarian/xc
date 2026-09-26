; Warnings: a $0000 operand, a label that looks like a Z80 hex literal, and a
; zero-page pointer that is not in zero page. An undefined symbol is an error
; (undef.asm).
zero    = 0
        .org $3000
0abch:  NOP
        LDA 0abch
        LDA 0abch
        LDA zero
        STA zero,X
        LDA (farptr),Y
        JMP 0abch
        .include "missing.inc"
farptr: .word 0
