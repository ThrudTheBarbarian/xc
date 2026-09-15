u16 sum_to(u8 n)
    {
    u16 acc = 0;
    u8 i = 0;
    while (i < n)
        {
        acc = acc + i;
        i = i + 1;
        }
    return acc;
    }
