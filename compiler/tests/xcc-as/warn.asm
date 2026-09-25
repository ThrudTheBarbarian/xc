; Warnings: undefined symbols, $0000 operands, a label that looks like a Z80
; hex literal, and a zero-page pointer that is not in zero page.
        .org $3000
0abch:  NOP
        LDA 0abch
        LDA 0abch
        LDA nowhere
        STA nothere,X
        LDA (farptr),Y
        JMP 0abch
        .include "missing.inc"
farptr: .word 0
