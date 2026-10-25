// u64_double_spill.xc — a u64 converted to double after a par reduction in a
// loop, where the value lives in a frame slot (2026-10-25, reported by the
// Astronomancy stream): arm64 loaded the slot into a 32-bit scratch and
// converted only the low half, 8779000000 printing as 189065408.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Par.xc"

void show(float* cnt, u32 n, u32 passes)
    {
    u64 total = (u64)0;
    for (u32 pass = (u32)1; pass <= passes; pass = pass + (u32)1)
        {
        if (pass == (u32)1)
            {
            u64 counted = (u64)0;
            par countAll :reduce(+ counted)
                {
                for (u32 i in 0..n)
                    counted = counted + (u64)cnt[i];
                }
            total = counted;
            }
        }
    Stdio.printf("%llu as double %.0f (want 8779000000)\n", total, (double)total);
    }

i32 main(void)
    {
    u32 n = (u32)1000000;
    float* cnt = new float[n];
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        cnt[i] = (float)8779.0;
    show(cnt, n, (u32)3);
    return (i32)0;
    }
