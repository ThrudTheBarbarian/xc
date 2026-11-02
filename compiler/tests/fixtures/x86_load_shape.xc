// x86_load_shape.xc — an insertion sort (its inner load's index and loaded value
// share a register) and a byte-flag scan, for the x86-64 load shapes
// (2026-11-02): a value is loaded straight into its home even when the address
// names it, a byte is zero-extended into the whole register, and every
// function starts on 16 bytes.
#import "Stdio.xc"

#define N 64
u32 a[N];
u8 flags[N];

u32 count(void)
    {
    u32 c = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        if (flags[i] != (u8)0)
            c = c + (u32)1;
    return c;
    }

i32 main(i32 argc, u8** argv)
    {
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)50; r++)
        {
        for (u32 i = (u32)0; i < (u32)N; i++)
            {
            a[i] = ((i * (u32)2654435761) ^ (r * (u32)40503)) + (u32)argc;
            flags[i] = (u8)(a[i] & (u32)1);
            }
        for (u32 i = (u32)1; i < (u32)N; i++)
            {
            u32 v = a[i]; u32 j = i;
            while (j > (u32)0 && a[j - (u32)1] > v) { a[j] = a[j - (u32)1]; j = j - (u32)1; }
            a[j] = v;
            }
        acc = acc + a[0] + a[N - 1] + count();
        }
    Stdio.printf("%u\n", acc);
    return 0;
    }
