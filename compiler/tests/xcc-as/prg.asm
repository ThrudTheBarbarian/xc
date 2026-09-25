        .org $0801
        .word $080B, 10
        .byte $9E, "2061", 0
        .org $0810
        LDA #1
        RTS
        .org $0820
        .byte 1,2,3
