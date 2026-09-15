; i64Add — signed 64-bit addition. Identical to unsigned in two's complement.
; Input:  $B0-$B7 = operand1, $B8-$BF = operand2
; Output: $B0-$B7 = result

i64Add:
    JMP u64Add
