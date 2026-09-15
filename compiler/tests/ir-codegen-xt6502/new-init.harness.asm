; new-init.harness.asm — new Box() runs Box.init (v=42); run() == 42.
; Provides a minimal bump-allocator __xtc_new_Box (the codegen test
; harness, unlike the corpus, has no auto-generated alloc stub).
; Expected: "42".

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

    JSR _run            ; u16 result in A:X
    JSR print_u16
    BRK

; __xtc_new_Box — refcount byte at base, object at base+1; return the
; object pointer in A:X (low:high); advance the bump pointer by 16.
__xtc_alloc:   ; B1: generic allocator; (count,stride,deallocPtr) on stack ignored, fixed Box size
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

heap_base:
    .space 256
