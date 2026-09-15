; protocol-dispatch.harness.asm — call run(), print the u16 result.
; Exercises protocol/virtual dispatch (VTblDispatch, task #58): run()
; news a Square + a Circle and dispatches area() through a Shape@.
; The lowering sets each object's vtable pointer; VTblDispatch follows
; obj -> vtbl -> vtbl[slot*2] -> the right area() body. Expected "7".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59           ; SAVMSC = $9C00
    LDA #0
    STA $94           ; screen column = 0

    ; Bump-allocator init: heap pointer at $92/$93 -> $4000 (free RAM in
    ; the golden sim; code is at $2000, screen at $9C00).
    LDA #$00
    STA $92
    LDA #$40
    STA $93

    JSR _run
    ; result is u16 in A (low) / X (high)
    JSR print_u16
    BRK

; new helpers: allocate a fixed 8-byte instance (covers the 2-byte
; vtable slot the lowering then fills) and return the pointer in A:X.
; Square and Circle share the same shape here.
__xtc_alloc:          ; B1: one generic allocator for Square + Circle (same 8-byte shape)
    LDA $92           ; ptr = heap pointer
    PHA
    LDA $93
    TAX               ; high byte in X
    CLC
    LDA $92
    ADC #8
    STA $92
    LDA $93
    ADC #0
    STA $93           ; bump by 8
    PLA               ; low byte in A
    RTS

; ARC stubs — no-ops for this test (A:X = object pointer on entry).
; The lowering emits retain/release around the class-pointer locals;
; correctness here is the dispatch result, not refcount bookkeeping.
__xtc_retain:
__xtc_release:
    RTS
