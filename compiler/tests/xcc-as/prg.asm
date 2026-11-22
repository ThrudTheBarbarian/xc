; A BASIC stub, 10 SYS 2064, then the program at $0810.
        .org $0801
        .word $080B, 10
        .byte $9E
        .string "2064"
        .word 0
        .org $0810
        LDA #1
        RTS
        .org $0820
        .byte 1,2,3
