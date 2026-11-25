// par_fuse.xc — adjacent par blocks fused into one (#147): two blocks with
// nothing between them, over the same range, where each array one writes is
// touched by the other only at the loop's index, run as one loop. Each case
// prints what the blocks compute, which is the same fused or apart
// (-fno-par-fuse); tests/par/fuse.sh checks which pairs fused (-Wpar-auto).
//
//xtc-na: xt6502 — no par runtime on this target (no ParDevice)
#import "Stdio.xc"
#import "Par.xc"

#define N 100003

u32 bump(u32 v) { return v + 1; }

float gx[N];
float gy[N];

// Two pointers that may be one array: the blocks stay apart.
float viaPointers(float* p, float* q)
{
    par ptrWrite
    {
        for (u32 i in 0..N)
            p[i] = (float)i * 0.5;
    }
    par ptrRead
    {
        for (u32 i in 0..N)
            q[i] = q[i] + 1.0;
    }
    float s = 0.0;
    for (u32 i = 0; i < N; i++) s = s + p[i] + q[i];
    return s;
}

i32 main(void)
{
    float* x = new float[N];
    float* y = new float[N];
    float* z = new float[N];
    float* w = new float[N];
    u32* k = new u32[N];
    for (u32 i = 0; i < N; i++)
    {
        x[i] = (float)(i % 977) * 0.25;
        k[i] = i * 7;
    }

    // Fused: y written at i, read at i; a reduction carried over.
    u64 tot = 0;
    par scale
    {
        for (u32 i in 0..N)
            y[i] = x[i] * 2.0 + 1.0;
    }
    par square :reduce(+ tot)
    {
        for (u32 j in 0..N)
        {
            float v = y[j] * y[j];
            z[j] = v;
            tot = tot + (u64)v;
        }
    }
    float s1 = 0.0;
    for (u32 i = 0; i < N; i++) s1 = s1 + z[i];
    Stdio.printf("chain: %llu %.1f\n", tot, s1);

    // Three in a row, all fused; the last writes what the first read.
    par c1
    {
        for (u32 i in 0..N)
            w[i] = x[i] + 1.0;
    }
    par c2
    {
        for (u32 i in 0..N)
            w[i] = w[i] * 3.0;
    }
    par c3
    {
        for (u32 i in 0..N)
            x[i] = w[i] - x[i];
    }
    float s2 = 0.0;
    for (u32 i = 0; i < N; i++) s2 = s2 + x[i] + w[i];
    Stdio.printf("three: %.1f\n", s2);

    // A neighbour read: apart.
    par shiftA
    {
        for (u32 i in 1..N)
            y[i] = z[i] * 0.5;
    }
    par shiftB
    {
        for (u32 i in 1..N)
            z[i] = y[i - 1] + 1.0;
    }
    float s3 = 0.0;
    for (u32 i = 0; i < N; i++) s3 = s3 + z[i];
    Stdio.printf("neighbour: %.1f\n", s3);

    // The second reads what the first reduces: apart.
    u64 m = 0;
    par redA :reduce(+ m)
    {
        for (u32 i in 0..N)
            m = m + (u64)k[i];
    }
    par redB
    {
        for (u32 i in 0..N)
            y[i] = x[i] / ((float)(m % 1000) + 1.0);
    }
    float s4 = 0.0;
    for (u32 i = 0; i < N; i++) s4 = s4 + y[i];
    Stdio.printf("reduction: %llu %.1f\n", m, s4);

    // Different goals: apart.
    par goalA :goal(accuracy)
    {
        for (u32 i in 0..N)
            y[i] = x[i] * x[i] + 1.0;
    }
    par goalB
    {
        for (u32 i in 0..N)
            z[i] = y[i] * 2.0;
    }
    float s5 = 0.0;
    for (u32 i = 0; i < N; i++) s5 = s5 + z[i];
    Stdio.printf("goals: %.1f\n", s5);

    // A call to a function of the program's: apart.
    par callA
    {
        for (u32 i in 0..N)
            k[i] = bump(k[i]);
    }
    par callB
    {
        for (u32 i in 0..N)
            k[i] = k[i] * 3;
    }
    u32 s6 = 0;
    for (u32 i = 0; i < N; i++) s6 = s6 + k[i];
    Stdio.printf("call: %u\n", s6);

    // Different ranges: apart.
    par rangeA
    {
        for (u32 i in 0..N)
            y[i] = x[i] + 2.0;
    }
    par rangeB
    {
        for (u32 i in 0..N - 1)
            z[i] = y[i] + 2.0;
    }
    float s7 = 0.0;
    for (u32 i = 0; i < N - 1; i++) s7 = s7 + z[i];
    Stdio.printf("ranges: %.1f\n", s7);

    // The second body reads a variable named as the first loop's: apart.
    u32 i0 = 5;
    par nameA
    {
        for (u32 i0 in 0..N)
            y[i0] = x[i0] + 1.0;
    }
    par nameB
    {
        for (u32 j in 0..N)
            z[j] = y[j] + (float)i0 + (float)(j % 2) * (float)i0;
    }
    float s8 = 0.0;
    for (u32 i = 0; i < N; i++) s8 = s8 + z[i];
    Stdio.printf("names: %.1f\n", s8);

    // Two global arrays of a size known when the program is built: fused.
    for (u32 i = 0; i < N; i++) gx[i] = (float)(i % 31);
    par glob1
    {
        for (u32 i in 0..N)
            gy[i] = gx[i] + 1.0;
    }
    par glob2
    {
        for (u32 i in 0..N)
            gx[i] = gy[i] * 2.0;
    }
    float s9 = 0.0;
    for (u32 i = 0; i < N; i++) s9 = s9 + gx[i];
    Stdio.printf("globals: %.1f\n", s9);

    Stdio.printf("pointers: %.1f\n", viaPointers(y, z));
    return 0;
}
