// par_vec_chain.xc — par bodies that are a serial chain per item, the shape
// the escape vectoriser takes for a par item loop (2026-10-30): an in-place
// u32 multiply-add, a shift/xor/add, a float multiply-add and a narrow
// multiply, each over a range that is no multiple of 16 so the vector loop,
// its interleaved copies and the scalar remainder all run. Each block's
// answer is checked against the same work done serially.
#import "Stdio.xc"
#import "Par.xc"
#define N 100003
#define ROUNDS 37
i32 main(i32 argc, u8** argv)
{
    u32* a = new u32[N];
    u32* b = new u32[N];
    u32* c = new u32[N];
    float* f = new float[N];
    u32* sa = new u32[N];
    u32* sb = new u32[N];
    u32* sc = new u32[N];
    float* sf = new float[N];
    for (u32 i in 0..N)
    {
        a[i] = i * (u32)2654435761;
        b[i] = i;
        c[i] = i & (u32)$FFF;
        f[i] = (float)(i & (u32)1023) * 0.001;
        sa[i] = a[i]; sb[i] = b[i]; sc[i] = c[i]; sf[i] = f[i];
    }
    par mulchain
    {
        for (u32 i in 0..N)
        {
            u32 v = a[i];
            for (u32 k in 0..ROUNDS)
                v = v * (u32)1664525 + (u32)1013904223 + i;
            a[i] = v;
        }
    }
    par shiftchain
    {
        for (u32 i in 0..N)
        {
            u32 v = b[i];
            for (u32 k in 0..ROUNDS)
                v = ((v << (u32)5) ^ (v >> (u32)3)) + (u32)1013904223 + i;
            b[i] = v;
        }
    }
    par floatchain
    {
        for (u32 i in 0..N)
        {
            float v = f[i];
            for (u32 k in 0..ROUNDS)
                v = v * 0.999 + 0.001;
            f[i] = v;
        }
    }
    par narrowchain
    {
        for (u32 i in 0..N)
        {
            u32 v = c[i];
            for (u32 k in 0..ROUNDS)
                v = ((v & (u32)$FFF) * (u32)$9C5) & (u32)$FFFFFF;
            c[i] = v;
        }
    }
    for (u32 i in 0..N)
    {
        u32 v = sa[i];
        for (u32 k in 0..ROUNDS) v = v * (u32)1664525 + (u32)1013904223 + i;
        sa[i] = v;
        v = sb[i];
        for (u32 k in 0..ROUNDS) v = ((v << (u32)5) ^ (v >> (u32)3)) + (u32)1013904223 + i;
        sb[i] = v;
        v = sc[i];
        for (u32 k in 0..ROUNDS) v = ((v & (u32)$FFF) * (u32)$9C5) & (u32)$FFFFFF;
        sc[i] = v;
    }
    u32 bad = (u32)0;
    u32 fbad = (u32)0;
    for (u32 i in 0..N)
    {
        if (a[i] != sa[i] || b[i] != sb[i] || c[i] != sc[i]) bad = bad + (u32)1;
        float v = sf[i];
        for (u32 k in 0..ROUNDS) v = v * 0.999 + 0.001;
        float d = f[i] - v;
        if (d > 0.0001 || d < -0.0001) fbad = fbad + (u32)1;
    }
    Stdio.printf("integer items wrong %u, float items off %u\n", bad, fbad);
    return 0;
}
