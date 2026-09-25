; Branches past +/-127 bytes are rewritten, BRA as a plain JMP.
        .org $2000
top:    BEQ far
        BRA far
        BNE top
        .space 300
far:    BCC top
        RTS
