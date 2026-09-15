; strlit.harness.asm — firstchar() returns "Hi"[0] = 'H' = 72.
; Validates xt6502 string-literal data emission + AddrOf + Load.
; Expected: "72".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59             ; SAVMSC = $9C00
    LDA #0
    STA $94             ; screen column = 0

    JSR _firstchar      ; u8 result in A
    LDX #0              ; print as u16, high = 0
    JSR print_u16
    BRK
