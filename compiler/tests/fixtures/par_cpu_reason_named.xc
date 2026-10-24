//xtc-warn: because it uses an operation its GPU version cannot express yet (IR op Bitcast)
// The CPU-only warning names what its GPU version could not express
// (astronomancy, 2026-10-24): "it uses an operation its GPU version cannot
// express yet" alone left nothing to change. Here a byte view of a u32 array
// (a pointer reinterpreted, IR Bitcast) keeps the block on the CPU; the answer
// is the serial loop's either way.
#import "Stdio.xc"
#import "Par.xc"
#define N 1024
u32 a[N];
i32 main(void)
    {
    for (u32 i in 0..N) a[i] = i * (u32)3;
    i64 total = (i64)0;
    par bytes :reduce(+ total)
        {
        for (u32 i in 0..N)
            {
            u8* bp = (u8*)(pointer)&a[0];
            total = total + (i64)a[i] + (i64)bp[i];
            }
        }
    Stdio.printf("%ld\n", total);
    return 0;
    }
