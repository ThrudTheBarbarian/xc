; struct-ivar.harness.asm — call si(), print u16 result. Expected: "42".
;
; Box layout: refcount byte at offset −1, then [vtable ptr (2 bytes),
; Point at (u16 x, u16 y = 4 bytes)] = 6 payload bytes. The bezier-style
; struct ivar `at` is written/read via FieldAddr(self,#1)+FieldAddr.
;
; ZP scratch (mirrors class-basic.harness):
;   $90/$91 — _xtc_new_Box allocation cursor (transient)
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

    JSR _si
    JSR print_u16
    BRK

; ── Runtime stubs ────────────────────────────────────────────────
;
; _xtc_new_Box: bump-allocate 7 bytes (1 refcount + 6 payload), set
; refcount = 1, zero the payload, return pointer skipping the refcount
; byte in A:X (low:high).
__xtc_alloc:   ; B1: generic allocator; (count,stride,deallocPtr) on stack ignored, fixed Box size
    LDA $92
    STA $90
    LDA $93
    STA $91
    ; bump heap_ptr by 7
    CLC
    LDA $92
    ADC #7
    STA $92
    LDA $93
    ADC #0
    STA $93
    ; refcount = 1 at offset 0
    LDA #1
    LDY #0
    STA ($90),Y
    ; payload zero-fill (6 bytes: vtbl_lo, vtbl_hi, x_lo, x_hi, y_lo, y_hi)
    LDA #0
    LDX #6
nb_zero:
    INY
    STA ($90),Y
    DEX
    BNE nb_zero
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

; _xtc_retain: A:X = object ptr. Refcount at ptr-1, ++. Saturates at 255.
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

; _xtc_release: A:X = object ptr. Refcount at ptr-1, --. On zero, bump
; the dealloc counter. (No actual free — bump allocator never reclaims.)
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
