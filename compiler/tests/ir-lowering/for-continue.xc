// for-continue — `continue` in a C-style for loop must run the
// increment before retesting, otherwise the counter never advances
// and the loop spins forever. fsum(10): sum 0..9 skipping 3 =
// 45 - 3 = 42. If continue skipped i++, the loop would hang at i==3.
u16 fsum(u16 n)
    {
    u16 acc = (u16)0;
    for (u16 i = (u16)0; i < n; i++)
        {
        if (i == (u16)3)
            {
            continue;
            }
        acc = acc + i;
        }
    return acc;
    }
