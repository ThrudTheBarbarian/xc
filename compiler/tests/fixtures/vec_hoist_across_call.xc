// vec_hoist_across_call.xc — a vector value must not be hoisted out of a loop
// that calls a function. Every vector register is the caller's to save, and
// no back end saves one across a call, so a value hoisted out of the outer
// loop below comes back from noise() as whatever noise left in it. The inner
// loop reads its counter (a lane-index vector, <0,1,2,...>, loaded once);
// hoisted to the function's entry, it was clobbered, and x86-64's AVX2 and
// AVX-512 versions of main (the default -msimd=auto picks one at load) summed
// garbage while the SSE version was right.
#import "Stdio.xc"

// Not inlined (recursive), so the outer loop really calls.
u32 noise(u32 x)
{
    if (x > (u32)100)
        return noise(x - (u32)100) + (u32)1;
    return x * (u32)3 + (u32)1;
}

i32 main(void)
{
    u32 total = (u32)0;
    u32 keep = (u32)0;
    for (u32 rep in 0..3)
    {
        total = (u32)0;
        u32 t0 = noise(rep * (u32)150);
        if (t0 == (u32)7)
            total = (u32)1;
        for (u32 i in 0..100003)
        {
            u32 a = (u32)0x67452301;
            u32 b = (u32)0xefcdab89;
            u32 c = (u32)0x98badcfe;
            u32 d = (u32)0x10325476;
            u32 f = (b & c) | (~b & d);
            u32 x = a + f + i + (u32)0xd76aa478;
            a = b + ((x << (u32)7) | (x >> (u32)25));
            total = total + (a + (u32)0x67452301) + (b + (u32)0xefcdab89) + (c + (u32)0x98badcfe) + (d + (u32)0x10325476);
        }
        keep = keep ^ (total + t0);
    }
    Stdio.printf("total %u keep %u\n", total, keep);
    return 0;
}
