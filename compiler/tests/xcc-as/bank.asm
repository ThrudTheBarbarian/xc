; Two banked pages through the code window and a named .bank region whose
; entry is called from main through its thunk.
        .org $2400
main:   JSR fpAdd
        JSR page2
        RTS
_fpAdd: RTS
        .org $6000
page1:  LDA #1
        RTS
        .org $6000
        .org $6000
page2:  LDA #2
        RTS
        .bank runtime
fpAdd:  LDA #__bank_runtime
        RTS
        .org $D800
tail:   LDA __bank_code_reg
        RTS
