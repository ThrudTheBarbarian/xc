// par_gpu_wide_div.xc — 64-bit division, remainder and float conversion in a
// `par` block: u64 and i64 quotients and remainders of hashed values by
// divisors of every size, and u64/i64 to float and back. WGSL has no 64-bit
// integers, so on WebGPU each is a helper over pairs of 32-bit words: long
// division, and conversions rounded to nearest even by hand. The results must
// be the CPU's, bit for bit.
#import "Stdio.xc"
#import "Par.xc"

#define N 2000

u64 quot[N];
u64 rems[N];
i64 squot[N];
i64 srems[N];
float fl[N];
float sfl[N];
u64 back[N];
i64 sback[N];

i32 main(void)
    {
    par divs
        {
        for (u32 i in 0..N)
            {
            u64 x = (u64)i * (u64)0x9E3779B97F4A7C15 + (u64)0xD1B54A32D192ED03;
            x = x ^ (x >> (u64)29);
            u64 d = (x >> (u64)(i % (u32)61 + (u32)1)) | (u64)1;
            quot[i] = x / d;
            rems[i] = x % d;
            i64 s = (i64)x;
            i64 sd = (i64)(d >> (u64)3) | (i64)1;
            if ((i & (u32)1) != (u32)0)
                sd = (i64)0 - sd;
            squot[i] = s / sd;
            srems[i] = s % sd;
            fl[i] = (float)x;
            sfl[i] = (float)s;
            back[i] = (u64)(fl[i] * 0.25f);
            sback[i] = (i64)(sfl[i] * 0.25f);
            }
        }
    u64 h = (u64)0;
    i64 sh = (i64)0;
    for (u32 i in 0..N)
        {
        h = h * (u64)1099511628211 + quot[i] + rems[i] * (u64)3 + (u64)fl[i] + back[i];
        sh = sh * (i64)31 + squot[i] + srems[i] * (i64)7 + (i64)sfl[i] + sback[i];
        }
    Stdio.printf("hash %016llx signed %lld\n", h, sh);
    Stdio.printf("quot[5] %llu rems[5] %llu squot[6] %lld srems[7] %lld\n", quot[5], rems[5], squot[6], srems[7]);
    Stdio.printf("fl[9] %llu sfl[10] %lld back[11] %llu sback[12] %lld\n", (u64)fl[9], (i64)sfl[10], back[11], sback[12]);
    return (i32)0;
    }
