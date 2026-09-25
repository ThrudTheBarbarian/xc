; .code_regions with an auto-spill across the gap, a .spill_point, and a JMP
; bridge when code falls through.
        .code_regions $2000-$201F, $3000-$30FF
        .org $2000
first:  LDA #1
        LDA #2
        LDA #3
        LDA #4
        LDA #5
        LDA #6
        LDA #7
        LDA #8
        LDA #9
        LDA #10
        LDA #11
        LDA #12
        LDA #13
        JMP second
second: LDA #12
        RTS
        .spill_point
        .byte 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
        RTS
