// float-param — exercises float PARAMETER passing on both
// backends (arm64 AAPCS v0/v1; xt6502 stack). `addf` takes two
// float params, `scalef` mixes int + float + int to test the
// independent GP/FP register counters. run stores integer
// results to globals so the harness prints without %f.
// addf(1.5, 3.25) = 4.75 -> (i16)4 ; scalef(2, 1.5, 3) reads
// b=1.5 -> (i16)1.
float addf(float a, float b)
    {
    return a + b;
    }

float scalef(i16 lo, float b, i16 hi)
    {
    return b;
    }

i16 gResult;

void run(void)
    {
    i16 a = (i16)addf(1.5, 3.25);   // 4.75 -> 4
    i16 s = (i16)scalef(2, 1.5, 3); // returns b=1.5 -> 1
    gResult = a + s + 100;          // 105 (inline add — no helper)
    }
