; float-param.harness.asm — run() computes gResult = 4*10 + 1 = 41
; via addf(float,float) and scalef(i16,float,i16). Validates float
; params passing on the xt6502 stack (callee spills width-driven).
; Expected: "41".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59             ; SAVMSC = $9C00
    LDA #0
    STA $94             ; screen column = 0

    JSR _run
    LDA _gResult
    LDX _gResult+1
    JSR print_i16
    BRK

.include "../../support/xt6502/asm/float/fpAdd.asm"
.include "../../support/xt6502/asm/float/fpToI32.asm"
_fpAdd = fpAdd
_fpToI32 = fpToI32
