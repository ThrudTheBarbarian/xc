; class-basic.harness.asm — call run(), print u8 result. Expected: "42".
;
; The class-basic fixture exercises FieldAddr + Load + Store + Call +
; Release on the xt6502 backend. Refcount header sits at offset −1
; from the object pointer; runtime stubs maintain a fixed-size bump
; allocator + a dealloc counter (unused in this fixture; arc.harness
; uses it).
;
; ZP scratch this harness uses:
;   $90/$91 — _xtc_new_Foo allocation cursor (transient)
;   $92/$93 — bump-allocator heap pointer (persistent across calls)
;   $94    — print_u16 column counter (caller-owned, see print.asm)
;   $95    — _xtc_dealloc counter

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    ; Initialise bump allocator: heap pointer = heap_base.
    LDA #<heap_base
    STA $92
    LDA #>heap_base
    STA $93
    LDA #0
    STA $95

    JSR _run
    ; run() returns u8 in A. Print as u16 with high byte zero.
    LDX #0
    JSR print_u16
    BRK

; ── Runtime stubs ────────────────────────────────────────────────
;
; _xtc_new_Foo: bump-allocate 4 bytes (1 refcount + 3 Foo), set
; refcount = 1, zero the payload, return pointer skipping the
; refcount byte in A:X (low:high). Double-underscore label because
; the IR's `_xtc_new_Foo` RuntimeHelper symbol is emitted as
; `JSR __xtc_new_Foo` (the backend prefixes every sym name with
; `_`; the runtime helper itself already starts with `_`, so the
; emitted label has two underscores).
__xtc_alloc:   ; B1: generic allocator; (count,stride,deallocPtr) on stack ignored, fixed Foo size
    ; save current heap_ptr into $90/$91
    LDA $92
    STA $90
    LDA $93
    STA $91
    ; bump heap_ptr by 4
    CLC
    LDA $92
    ADC #4
    STA $92
    LDA $93
    ADC #0
    STA $93
    ; refcount = 1 at offset 0
    LDA #1
    LDY #0
    STA ($90),Y
    ; payload zero-fill (3 bytes: vtable_lo, vtable_hi, x)
    LDA #0
    INY
    STA ($90),Y
    INY
    STA ($90),Y
    INY
    STA ($90),Y
    ; Return pointer = $90/$91 + 1.
    CLC
    LDA $90
    ADC #1
    PHA
    LDA $91
    ADC #0
    TAX
    PLA
    RTS

; _xtc_retain: A:X = object ptr. Find refcount at ptr-1, ++.
; Saturates at 255.
__xtc_retain:
    STA $90
    STX $91
    SEC
    LDA $90
    SBC #1
    STA $90
    LDA $91
    SBC #0
    STA $91
    LDY #0
    LDA ($90),Y
    CMP #$FF
    BEQ rt_done
    CLC
    ADC #1
    STA ($90),Y
rt_done:
    RTS

; _xtc_release: A:X = object ptr. Refcount at ptr-1, --. On zero,
; bump dealloc counter. (No actual free — bump allocator never
; reclaims.)
__xtc_release:
    STA $90
    STX $91
    SEC
    LDA $90
    SBC #1
    STA $90
    LDA $91
    SBC #0
    STA $91
    LDY #0
    LDA ($90),Y
    CMP #$FF
    BEQ rl_done
    SEC
    SBC #1
    STA ($90),Y
    BNE rl_done
    INC $95
rl_done:
    RTS

heap_base:
    .space 256
