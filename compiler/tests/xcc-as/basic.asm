; Directives, expressions, local labels, macros and an include.
        .include "inc/defs.inc"
        .org $2000
start:  LDA #<message
        STA $B0
        LDA #>message
        STA $B1
        LDX #COUNT
.loop:  DEX
        BNE .loop
        LDA table,X : STA COLOR0 : TAY
        wait 3, $10
        JSR helper
        LDA #(COUNT*2+1)/3
        LDA #%1010
        LDA #0Fh
        LDA #12
        LDA cOuNt
        ASL
        ROR A
        LDA ($B0),Y
        LDA ($B0,X)
        JMP (vector)
        LDY $1234,X
        LDX $12,Y
        STX $12 , Y
        LDA $0602  ,  Y
        RTS
helper: LDA #1
.loop:  BEQ .loop
        RTS
message: .string "HELLO"
table:  .byte 1, 2, 3, <table, >table
        .word start, helper+2, $BEEF
        .long $12345678, 7
vector: .word start
        .space 4
        .space COUNT
after   = vector + 1
fwd     = later - start
later:  .byte fwd
        .byte $ 5
