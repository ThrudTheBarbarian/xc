; array-subscript.harness.asm — call sa(), print u8 result. Expected: "42".
; Proves the local u8 array `a` got a pinned slot and a[i] store/load
; resolved via AddrOf(decay) + ElementAddr (10 + 32).

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    JSR _sa
    ; sa() returns u8 in A. Print as u16 with high byte zero.
    LDX #0
    JSR print_u16
    BRK
