; static-field.harness.asm — Counter.bump() x3 then get() == 3.
; Validates static-method class-field access via __sdata on xt6502.
; Expected: "3".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94
    JSR _run            ; u16 result in A:X
    JSR print_u16
    BRK
