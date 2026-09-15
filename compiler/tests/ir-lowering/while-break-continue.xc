// while-break-continue — break / continue inside a while loop.
// lowerWhileStmt never registered a loop frame, so any break or
// continue in a while body abandoned with "break/continue outside
// loop". wsum(10): i counts 1..; skip adding 3 (continue), stop at 7
// (break) ⇒ 1+2+4+5+6 = 18.
u16 wsum(u16 n)
    {
    u16 i = (u16)0;
    u16 acc = (u16)0;
    while (i < n)
        {
        i = i + (u16)1;
        if (i == (u16)3)
            {
            continue;
            }
        if (i == (u16)7)
            {
            break;
            }
        acc = acc + i;
        }
    return acc;
    }
