; An undefined symbol is an error, reported once per name with its line.
; Assembled as 0 it would build a JSR $0000.
        .org $3000
        JSR nowhere
        LDA nothere
        STA nothere,X
        .word nowhere
        RTS
