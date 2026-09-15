; u64Shifts — 64-bit shift-left, logical shift-right and arithmetic
; shift-right.
;
; Input:  $B0-$B7 = value, $B8 = count
; Output: $B0-$B7 = result
;
; The 32-bit trio lives in xt6502-harness.asm, which every binary includes.
; These do not: at eight bytes each loop body is four times the size, and a
; program that never says i64 should not carry them. XTIRRuntimeEmitter pulls
; this file in only when the generated asm calls one of them.
; every width. A count of zero returns untouched, as the narrower ones do.

_u64Shl:
    LDX $B8
    BEQ _u64_ret
_u64Shl_l:
    ASL $B0
    ROL $B1
    ROL $B2
    ROL $B3
    ROL $B4
    ROL $B5
    ROL $B6
    ROL $B7
    DEX
    BNE _u64Shl_l
_u64_ret:
    RTS

_u64LShr:
    LDX $B8
    BEQ _u64_ret
_u64LShr_l:
    LSR $B7
    ROR $B6
    ROR $B5
    ROR $B4
    ROR $B3
    ROR $B2
    ROR $B1
    ROR $B0
    DEX
    BNE _u64LShr_l
    RTS

_u64AShr:
    LDX $B8
    BEQ _u64_ret
_u64AShr_l:
    LDA $B7
    AND #$80            ; isolate the sign bit
    STA $B9             ; $B9 is free here: the count is one byte at $B8
    LSR $B7
    ROR $B6
    ROR $B5
    ROR $B4
    ROR $B3
    ROR $B2
    ROR $B1
    ROR $B0
    LDA $B7
    ORA $B9             ; re-extend the sign
    STA $B7
    DEX
    BNE _u64AShr_l
    RTS
