u16 compute(u8 lo, u16 mid, u32 hi)
    {
    u16 lo_w = lo;
    u16 hi_t = hi;
    return lo_w + mid + hi_t;
    }

u16 run(void)
    {
    return compute(1, 100, 1000000);
    }
