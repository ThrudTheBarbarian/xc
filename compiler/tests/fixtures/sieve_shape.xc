// sieve_shape.xc — a sieve whose scan loop has a phi at every join, for the
// x86 branch and copy shape (2026-11-01): each conditional branch one jcc to
// its target with the other edge falling through, and a loop-carried value in
// the same register as its phi (tests/driver/x86-branch-shape.sh).
#import "Stdio.xc"

#define N 8192
u8 flags[N];

i32 main(void)
    {
    u32 total = (u32)0;
    for (u32 round = (u32)0; round < (u32)50; round++)
        {
        for (u32 i = (u32)0; i < (u32)N; i++)
            flags[i] = (u8)1;
        u32 count = (u32)0;
        for (u32 i = (u32)2; i < (u32)N; i++)
            {
            if (flags[i] != (u8)0)
                {
                for (u32 k = i + i; k < (u32)N; k = k + i)
                    flags[k] = (u8)0;
                count = count + (u32)1;
                }
            }
        total = total + count;
        }
    Stdio.printf("%u\n", total);
    return 0;
    }
