; i32Add — signed 32-bit addition (same as unsigned for two's complement)
; Input:  $B0-$B3 = operand1, $B4-$B7 = operand2
; Output: $B0-$B3 = result

i32Add:
    JMP u32Add
