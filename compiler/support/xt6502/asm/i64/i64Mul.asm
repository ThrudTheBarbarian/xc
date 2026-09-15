; i64Mul — signed 64-bit multiply.
; Input:  $B0-$B7 = operand1, $B8-$BF = operand2
; Output: $B0-$B7 = low 64 bits of the product
;
; The low 64 bits of a two's-complement product are the same whether the
; operands are read as signed or unsigned, so this is u64Mul — exactly as
; i32Mul defers to u32Mul.

i64Mul:
    JMP u64Mul
