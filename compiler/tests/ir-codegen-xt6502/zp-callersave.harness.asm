; zp-callersave.harness.asm — run() sums three call results while holding
; `a` live across a nested call. Validates ZP caller-save (task #64):
; without it the callee clobbers `a` and the sum is wrong. Expected: "115".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59             ; SAVMSC = $9C00
    LDA #0
    STA $94             ; screen column = 0

    JSR _run
    LDX #$00            ; u8 result in A; clear high byte for print_u16
    JSR print_u16
    BRK
