// loop_goal_matmul.xc — `for (...) :goal(speed|accuracy)` on a matrix multiply.
// Under accuracy (a plain loop's default) a NaN input keeps its payload, bit
// for bit, as the loop computes it. Under speed the arm64 SME kernel may hand
// back the default NaN instead: still a NaN, in the same places, and every
// other element the same. So the speed half prints only which elements are
// NaN, and the values of the rest. The goal holds for the loops inside the
// annotated one, down to one that sets its own.
#import "Stdio.xc"

#define M 20

void exact(float* a, float* b, float* c)
    {
    for (u32 i = (u32)0; i < (u32)M; i++) :goal(accuracy)
        for (u32 j = (u32)0; j < (u32)M; j++)
            {
            float s = 0.0;
            for (u32 k = (u32)0; k < (u32)M; k++)
                s = s + a[i * (u32)M + k] * b[k * (u32)M + j];
            c[i * (u32)M + j] = s;
            }
    }

void fast(float* a, float* b, float* c)
    {
    for (u32 i in 0..M) :goal(speed)
        for (u32 j in 0..M)
            {
            float s = 0.0;
            for (u32 k in 0..M)
                s = s + a[i * (u32)M + k] * b[k * (u32)M + j];
            c[i * (u32)M + j] = s;
            }
    }

u32 sum(u32* cb, bool skipNaN)
    {
    u32 h = (u32)0;
    for (u32 i in 0..M * M)
        {
        bool nan = (cb[i] & (u32)$7FFFFFFF) > (u32)$7F800000;
        if (nan && skipNaN)
            h = h * (u32)31 + (u32)1;
        else
            h = h * (u32)31 + cb[i];
        }
    return h;
    }

i32 main(void)
    {
    float* a = new float[M * M];
    float* b = new float[M * M];
    float* c = new float[M * M];
    u32* ab = (u32*)a;
    u32* cb = (u32*)c;
    for (u32 i in 0..M * M)
        {
        a[i] = (float)((i * (u32)7) % (u32)13) - 6.0;
        b[i] = (float)((i * (u32)5) % (u32)11) * 0.5;
        }
    ab[3 * M + 4] = (u32)$7FC01234;   // a quiet NaN with a payload: row 3 of C
    exact(a, b, c);
    Stdio.printf("accuracy: c[3][0] = %08x, c[2][5] = %08x, all %08x\n", cb[3 * M], cb[2 * M + 5], sum(cb, false));
    fast(a, b, c);
    u32 nans = (u32)0;
    for (u32 i in 0..M * M)
        if ((cb[i] & (u32)$7FFFFFFF) > (u32)$7F800000)
            nans = nans + (u32)1;
    Stdio.printf("speed: %u NaNs, c[2][5] = %08x, the rest %08x\n", nans, cb[2 * M + 5], sum(cb, true));
    exact(a, b, c);
    Stdio.printf("accuracy again: rest %08x\n", sum(cb, true));
    return (i32)0;
    }
