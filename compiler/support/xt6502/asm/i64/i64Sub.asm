; i64Sub — signed 64-bit subtraction. Identical to unsigned in two's complement.
; Input:  $B0-$B7 = operand1, $B8-$BF = operand2
; Output: $B0-$B7 = operand1 - operand2

i64Sub:
    JMP u64Sub
