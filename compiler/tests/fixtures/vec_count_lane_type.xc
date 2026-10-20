// vec_count_lane_type.xc — a vectorised count after a byte loop. The count
// reduction (`if ((w[i] & 0x7fffffff) > 0x7f800000) n++`, a NaN count on
// float bits) splats its mask at the WORD's vector type. The xc compiler
// once kept the type and the preheader of the loop vectorised before it — a
// byte loop's — so the mask became 0xff in every byte, cleared nothing, and
// words with the sign bit set counted when their low 31 bits did not.
#import "Stdio.xc"

#define N 1000

void bump(u8* b, u32 n)
{
    for (u32 i in 0..n)
        b[i] = b[i] + (u8)3;
}

u32 countNaN(u32* w, u32 n)
{
    u32 c = (u32)0;
    for (u32 i in 0..n)
        if ((w[i] & (u32)0x7fffffff) > (u32)0x7f800000)
            c++;
    return c;
}

u32 both(u8* b, u32* w, u32 n)
{
    for (u32 i in 0..n)
        b[i] = b[i] + (u8)1;
    u32 c = (u32)0;
    for (u32 i in 0..n)
        if ((w[i] & (u32)0x7fffffff) > (u32)0x7f800000)
            c++;
    return c;
}

i32 main(void)
{
    u8* b = new u8[N];
    u32* w = new u32[N];
    for (u32 i in 0..N)
    {
        b[i] = (u8)i;
        // Every seventh a NaN (some of them negative); every third of the
        // rest a negative number, whose sign bit only the mask clears.
        if (i % (u32)7 == (u32)0)
            w[i] = (i % (u32)2 == (u32)0 ? (u32)0xffc00000 : (u32)0x7fc00001) + i;
        else if (i % (u32)3 == (u32)0)
            w[i] = (u32)0x80000005 + i;
        else
            w[i] = (u32)0x3f800000 + i;
    }
    bump(b, (u32)N);
    Stdio.printf("countNaN %u\n", countNaN(w, (u32)N));
    Stdio.printf("both %u\n", both(b, w, (u32)N));
    // The same in one function with fixed trips: a byte loop vectorised
    // first, then the count.
    for (u32 i in 0..N)
        b[i] = b[i] + (u8)5;
    u32 nans = (u32)0;
    for (u32 i in 0..N)
        if ((w[i] & (u32)0x7fffffff) > (u32)0x7f800000)
            nans = nans + (u32)1;
    Stdio.printf("inline %u\n", nans);
    u32 s = (u32)0;
    for (u32 i in 0..N)
        s = s + (u32)b[i];
    Stdio.printf("bytes %u\n", s);
    return 0;
}
