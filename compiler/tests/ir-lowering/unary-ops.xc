// unary-ops — the remaining scalar unary operators: prefix ++/-- and
// logical not (`!`).
//
// The for-loop steps with PREFIX `++i`: like postfix `i++`, this
// rebinds `i`, so the assigned-locals pre-scan must flag it or the
// loop header gets no phi and never sees the bump (would spin / read
// the stale value). Sum 0+1+…+9 = 45.
//
// `!z` lowers to (z == 0) as a bool via ICmp EQ against a Const #0 —
// the same shape as the binary `==` path. z is 0, so the `if` fires:
// 45 - 3 = 42. The trailing `--total; ++total;` exercises prefix
// ++/-- on a plain (non-loop) local; net no-op.
u16 un(void)
    {
    u16 total = (u16)0;
    for (u16 i = (u16)0; i < (u16)10; ++i)
        {
        total = total + i; // 0+1+…+9 = 45
        }
    u16 z = (u16)0;
    if (!z)
        total = total - (u16)3; // !0 → true → 42
    --total;                    // 41
    ++total;                    // 42
    return total;               // 42
    }
