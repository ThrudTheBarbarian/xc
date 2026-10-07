// fp_to_u64_unrolled.xc — float to u64 in an unrolled loop beside another
// loop-carried value (bug 631). x86-64 has no unsigned conversion: values
// from 2^63 up are converted less 2^63 and the top bit put back. The top bit
// was put back with 2^63 in r11, a register the allocator also homes values
// in, so in the unrolled loop it overwrote the previous copy's result and
// the sum came out wrong at -O2.
#import "Stdio.xc"
#define N 64
float f[N];
i64 b[N];
i32 main(void)
    {
    for (u32 i in 0..N)
        {
        f[i] = (float)i * 1.0e17f;
        b[i] = (i64)i * (i64)3;
        }
    u64 h = (u64)0;
    i64 sh = (i64)0;
    for (u32 i in 0..N)
        {
        h = h + (u64)f[i];
        sh = sh * (i64)31 + b[i];
        }
    Stdio.printf("%016llx %lld\n", h, sh);
    return (i32)0;
    }
