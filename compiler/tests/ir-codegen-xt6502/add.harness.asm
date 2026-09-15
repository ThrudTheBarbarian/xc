; add.harness.asm — call add(5, 6), print u8 result.
; Expected: "11".

.org $2000
start:
    ; SAVMSC = $9C00 — xts dumps screen RAM from this base.
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94           ; screen column = 0

    ; add(5, 6): u8 a, u8 b → u8. Push right-to-left.
    LDA #6
    PHA               ; b = 6
    LDA #5
    PHA               ; a = 5
    JSR _add
    ADD SP, #2        ; caller cleanup

    LDX #0            ; result is u8 in A; print as u16 with high=0
    JSR print_u16
    BRK
