; fnptr-basic.harness.asm — callit() takes &addOne, calls through the
; pointer with arg 5, returns 6. Validates the indirect-call trampoline
; (AddrOf function symbol + CallIndirect) end-to-end. Expected: "6".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59             ; SAVMSC = $9C00
    LDA #0
    STA $94             ; screen column = 0

    JSR _callit
    LDX #$00            ; u8 result in A; clear high byte for print_u16
    JSR print_u16
    BRK
