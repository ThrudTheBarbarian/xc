; recurse-spill.harness.asm — call sumDown(5), print the u16 result.
; Exercises the non-leaf software-stack spill frame (STACK-ABI §11.3):
; each recursion level gets its own frame, so buf[0] survives the
; recursive call. Expected: 5+4+3+2+1+0 = "15".

.org $2000
start:
    ; SAVMSC = $9C00 — xts dumps screen RAM from this base.
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94           ; screen column = 0

    ; Software-stack pointer + frame pointer = base of the model's
    ; software-stack region. In the xts -d sim the screen-write log
    ; window runs $9C00..$BB3F, so the test region sits at $C000 (above
    ; it); production HW has no such window and uses $A000-$CFFF.
    LDA #$00
    STA $8A
    STA $8C
    LDA #$C0
    STA $8B
    STA $8D           ; SSP = FP = $C000

    LDA #5
    PHA               ; n = 5 (u8)
    JSR _sumDown
    ADD SP, #1        ; caller cleanup

    ; result is u16 in A (low) / X (high)
    JSR print_u16
    BRK
