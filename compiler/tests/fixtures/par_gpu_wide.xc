// par_gpu_wide.xc — 64-bit integers in a `par` block: a hash built from
// multiplies, xors and shifts of u64 values, signed i64 comparisons and
// arithmetic shifts, and a u64 reduction. WGSL has no 64-bit integers, so on
// WebGPU every one of these is a pair of 32-bit words; the results must still
// be the CPU's, bit for bit.
#import "Stdio.xc"
#import "Par.xc"

#define N 2000

u64 hashes[N];
i64 signedOut[N];

i32 main(void)
    {
    u64 seed = (u64)0x9E3779B97F4A7C15;
    u64 total = (u64)0;
    par mix :reduce(+ total)
        {
        for (u32 i in 0..N)
            {
            u64 x = (u64)i * seed + (u64)0xD1B54A32D192ED03;
            x = x ^ (x >> (u64)31);
            x = x * (u64)0xBF58476D1CE4E5B9;
            x = x ^ (x << (u64)17) ^ (x >> (u64)43);
            hashes[i] = x;
            total = total + (x >> (u64)7);
            i64 s = (i64)x;
            i64 shifted = s >> (i64)5;                      // arithmetic: keeps the sign
            signedOut[i] = s < (i64)0 ? shifted - (i64)i : shifted + (i64)(i * (u32)3);
            }
        }
    u64 h = (u64)0;
    i64 sg = (i64)0;
    u32 neg = (u32)0;
    for (u32 i in 0..N)
        {
        h = h * (u64)1099511628211 + hashes[i];
        sg = sg + (signedOut[i] >> (i64)8);
        if (signedOut[i] < (i64)0)
            neg = neg + (u32)1;
        }
    Stdio.printf("hash %016llx signed %lld negatives %u total %016llx\n", h, sg, neg, total);
    Stdio.printf("hashes[1999] %016llx signedOut[7] %lld\n", hashes[1999], signedOut[7]);
    return (i32)0;
    }
