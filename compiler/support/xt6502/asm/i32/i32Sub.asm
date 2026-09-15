; i32Sub — signed 32-bit subtraction (same as unsigned for two's complement)
; Input:  $B0-$B3 = operand1, $B4-$B7 = operand2
; Output: $B0-$B3 = operand1 - operand2

i32Sub:
    JMP u32Sub
