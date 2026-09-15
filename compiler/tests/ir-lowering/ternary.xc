// ternary — `cond ? then : else` as a value-producing expression.
// Both arms are exercised inline in one function (no nested calls,
// so the result is independent of the separate xt6502 ZP-scratch-
// across-calls issue, and no multiply runtime is needed):
//   a takes the THEN arm (x == 0 is true)  → 100
//   b takes the ELSE arm (y == 0 is false) → y + y = 14
// a + b == 114. The condition uses ICmp EQ, so this also covers the
// equality-materialisation path on both backends.
u16 mix(void)
    {
    u16 x = (u16)0;
    u16 y = (u16)7;
    u16 a = (x == (u16)0) ? (u16)100 : (u16)1;
    u16 b = (y == (u16)0) ? (u16)1 : y + y;
    return a + b;
    }
