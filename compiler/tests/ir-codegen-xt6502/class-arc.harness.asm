; class-arc.harness.asm — exercises Retain + double Release. The
; lowering emits one Retain (for `Box@ b = a;` borrowed-RHS
; assignment) and two Releases (scope-exit teardown of b then a,
; both aliasing the same SSA value). Refcount trace:
;
;   +1 (new)  +1 (retain)  −1 (release b)  −1 (release a)  =  0
;
; So _xtc_dealloc fires exactly once. The harness prints the
; dealloc counter ($95). Expected output: "1".

.org $2000
start:
    LDA #$00
    STA $58
    LDA #$9C
    STA $59
    LDA #0
    STA $94

    LDA #<heap_base
    STA $92
    LDA #>heap_base
    STA $93
    LDA #0
    STA $95

    JSR _run
    LDA $95           ; dealloc count
    LDX #0
    JSR print_u16
    BRK

; ── Runtime stubs (shared shape with class-basic.harness.asm) ────

__xtc_alloc:   ; B1: generic allocator; (count,stride,deallocPtr) on stack ignored, fixed Box size
    LDA $92
    STA $90
    LDA $93
    STA $91
    CLC
    LDA $92
    ADC #4
    STA $92
    LDA $93
    ADC #0
    STA $93
    LDA #1
    LDY #0
    STA ($90),Y
    LDA #0
    INY
    STA ($90),Y
    INY
    STA ($90),Y
    INY
    STA ($90),Y
    CLC
    LDA $90
    ADC #1
    PHA
    LDA $91
    ADC #0
    TAX
    PLA
    RTS

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
