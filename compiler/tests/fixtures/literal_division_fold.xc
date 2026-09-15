// literal_division_fold.xc — bug 27. Folding `a / b` when BOTH are integer
// literals must not truncate the operands to the RESULT's type. `840 / 56` is
// 15, whose type is u8 — but sizing the fold node from that u8 truncated the
// dividend to 840 & 0xFF = 72, giving 72/56 = 1 and 72/7 = 10. The fold node's
// type must be the WIDER of the operand-widened type and the result type.
i32 printf(u8* f, ...);

i32 main(void)
{
    i32 ok = (i32)0;
    if (840 / 56 == 15)  ok = ok + (i32)1;   // was 1 (72/56)
    if (840 / 7  == 120) ok = ok + (i32)1;   // was 10 (72/7)
    if (100 / 3  == 33)  ok = ok + (i32)1;   // small dividend: was already right
    if (15 * 56 / 56 == 15) ok = ok + (i32)1;  // must keep the wide multiply
    if (65535 / 3 == 21845) ok = ok + (i32)1;
    if (1000000 / 1000 == 1000) ok = ok + (i32)1;   // 32-bit dividend
    printf("ok %d/6\n", ok);
    return (i32)0;
}
