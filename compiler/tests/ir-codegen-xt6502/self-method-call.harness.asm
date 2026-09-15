; self-method-call.harness.asm — count3() calls Counter.run(), which
; calls the sibling method _bump() three times via implicit self.
; Provides a minimal bump-allocator __xtc_new_Counter. Expected: "3".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59             ; SAVMSC = $9C00
    LDA #0
    STA $94             ; screen column = 0

    ; Bump-allocator pointer ($92/$93) = heap_base.
    LDA #<heap_base
    STA $92
    LDA #>heap_base
    STA $93

    JSR _count3         ; u16 result in A:X
    JSR print_u16
    BRK

; __xtc_new_Counter — refcount byte at base, object at base+1; return
; the object pointer in A:X (low:high); advance the bump pointer by 16.
__xtc_alloc:   ; B1: generic allocator; (count,stride,deallocPtr) on stack ignored, fixed Counter size
    LDA $92
    STA $90
    LDA $93
    STA $91             ; $90/$91 = block base
    LDA #1
    LDY #0
    STA ($90),Y         ; refcount = 1
    CLC
    LDA $92
    ADC #16
    STA $92
    LDA $93
    ADC #0
    STA $93             ; bump += 16
    CLC
    LDA $90
    ADC #1
    PHA                 ; object low = base+1
    LDA $91
    ADC #0
    TAX                 ; object high
    PLA
    RTS

; __xtc_retain(A=lo, X=hi) — increment the refcount byte at obj-1.
; Null-safe; balances __xtc_release so the ARC self-retain a heap-receiver
; method now emits (retain on entry, release at exit) nets to zero and the
; object survives the call. Result registers are unused by the caller.
__xtc_retain:
    STA $90
    STX $91
    ORA $91
    BEQ .ret_done       ; null pointer — nothing to do
    SEC
    LDA $90
    SBC #1
    STA $90
    LDA $91
    SBC #0
    STA $91             ; $90/$91 = obj - 1 (refcount cell)
    LDY #0
    LDA ($90),Y
    CLC
    ADC #1
    STA ($90),Y         ; refcount++
.ret_done:
    RTS

; __xtc_release(A=lo, X=hi) — decrement the refcount byte at obj-1.
; Null-safe. The bump allocator never reclaims, so hitting 0 just
; falls through (no dealloc). count3 stashes run()'s result before
; the release, so this only needs to leave the result registers be.
__xtc_release:
    STA $90
    STX $91
    ORA $91
    BEQ .rel_done       ; null pointer — nothing to do
    SEC
    LDA $90
    SBC #1
    STA $90
    LDA $91
    SBC #0
    STA $91             ; $90/$91 = obj - 1 (refcount cell)
    LDY #0
    LDA ($90),Y
    BEQ .rel_done       ; already 0 — leave saturated
    SEC
    SBC #1
    STA ($90),Y         ; refcount--
.rel_done:
    RTS

heap_base:
    .space 256
