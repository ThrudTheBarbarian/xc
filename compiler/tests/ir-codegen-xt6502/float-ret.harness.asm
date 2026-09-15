; float-ret.harness.asm — run() sets gN = (i16)pi(), pi()=3.25 -> 3.
; Validates the xt6502 float RETURN ABI: pi leaves its float in the
; $B0-$B4 mailbox, run harvests it and truncates via _fpToI32.
; Expected: "3".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59             ; SAVMSC = $9C00
    LDA #0
    STA $94             ; screen column = 0

    JSR _run
    LDA _gN
    LDX _gN+1
    JSR print_i16
    BRK

.include "../../support/xt6502/asm/float/fpToI32.asm"
_fpToI32 = fpToI32
