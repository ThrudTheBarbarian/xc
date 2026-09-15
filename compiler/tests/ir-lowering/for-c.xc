// for-c — exercises C-style for-loop lowering + postfix increment.
// Sum 0+1+…+9 = 45.
u16 sum10(void)
    {
    u16 total = 0;
    for (u8 i = 0; i < 10; i = i + 1)
        {
        total = total + i;
        }
    return total;
    }
