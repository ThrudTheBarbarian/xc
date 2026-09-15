// break-exit-value — a local mutated before a `break` must reach
// post-loop code with its break-point value. Previously the loop exit
// reused the header (loop-carried) value, so `r` read back as its
// value *entering* the breaking iteration rather than after the
// in-iteration update. bsum(10): r += 10 each pass, break when i==2,
// so r is bumped on i=0,1,2 ⇒ 30 (not the pre-fix 20).
u16 bsum(u16 n)
    {
    u16 r = (u16)0;
    u16 i = (u16)0;
    while (i < n)
        {
        r = r + (u16)10;
        if (i == (u16)2)
            {
            break;
            }
        i = i + (u16)1;
        }
    return r;
    }
