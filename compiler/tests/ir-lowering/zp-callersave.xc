// zp-callersave — regression for the xt6502 ZP caller-save fix
// (task #64). `a` is held in a ZP slot across the applyD call; applyD's
// callee (addOne) reuses the same ZP pool. Before the fix, addOne
// clobbered `a` and run() returned 210; with caller-save it returns 115.
u8 addOne(u8 x)
    {
    return x + (u8)1;
    }
u8 applyD(u8 x)
    {
    return addOne(x);
    }

u8 run(void)
    {
    u8 a = addOne((u8)5);   // 6  — kept live across the applyD call
    u8 b = addOne((u8)7);   // 8
    u8 c = applyD((u8)100); // 101
    return a + b + c;       // 115
    }
