; fnptr-callback.harness.asm — callcb() passes &addOne to applyU8 (a
; function-pointer parameter / callback) which dispatches through it.
; addOne(100) = 101. Validates fn-pointer args + indirect dispatch
; inside the callee. Expected: "101".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59             ; SAVMSC = $9C00
    LDA #0
    STA $94             ; screen column = 0

    JSR _callcb
    LDX #$00            ; u8 result in A; clear high byte for print_u16
    JSR print_u16
    BRK
