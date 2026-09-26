//xtc-na: xt6502 — its primitive-array allocator stores no count, so a runtime-sized `.length` is a compile-time error there
// new_array_zero_length.xc — a runtime-sized heap array of zero elements has
// `.length` 0, and for-in over it runs no iterations.
//
// Bug 472: the allocator stored a count of 0 as 1, so `.length` read 1 and
// for-in visited one element past the end of an empty array.

#import "Stdio.xc"

u16 pick(u16 n) { return n; }

i16 main(void)
{
    for (u16 n = (u16)0; n < (u16)3; n = n + (u16)1)
    {
        u16* buf = new u16[pick(n)];
        u16 visits = (u16)0;
        for (u16 v in buf) visits = visits + (u16)1;
        Stdio.printf("n=%d length=%d visits=%d\n", n, (u16)buf.length, visits);
        delete buf;
    }
    return 0;
}
