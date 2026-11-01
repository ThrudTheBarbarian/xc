// vec_udiv_const.xc — u32 division by constants in a vectorised loop: the
// lanes' high products (VMulHi) take the odd dwords of two pmuludq, with no
// shuffle of a splat magic number (2026-11-01). Divisors with each shape of
// magic (3, 11: shift only; 7: the 33-bit add-and-shift fix-up; 13, 1000)
// over values that reach both ends of u32.
#import "Stdio.xc"

#define N 1000
u32 a[N];

i32 main(void)
    {
    for (u32 i = (u32)0; i < (u32)N; i++)
        a[i] = (i * (u32)2654435761) ^ (i << (u32)7);
    a[0] = (u32)0;
    a[1] = (u32)1;
    a[2] = (u32)0xFFFFFFFF;
    a[3] = (u32)0xFFFFFFFE;
    a[4] = (u32)0x80000000;
    a[5] = (u32)0x7FFFFFFF;
    a[6] = (u32)6;
    a[7] = (u32)7;
    // One sum per loop, so each vectorises (as int_muldiv's does).
    u32 s3 = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        s3 = s3 + a[i] / (u32)3;
    u32 s7 = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        s7 = s7 + a[i] / (u32)7;
    u32 s11 = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        s11 = s11 + a[i] / (u32)11;
    u32 s13 = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        s13 = s13 + (a[i] * (u32)7) / (u32)13;
    u32 sk = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        sk = sk + a[i] / (u32)1000;
    Stdio.printf("%u %u %u %u %u\n", s3, s7, s11, s13, sk);
    return 0;
    }
