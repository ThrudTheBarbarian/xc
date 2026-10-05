//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// par_gpu_helpers.xc — a `par` body that calls helper functions: nested, with
// a branch, and feeding a reduction. On Apple silicon with XC_PAR=gpu the
// helpers are printed into the Metal kernel; the answer is the same anywhere.
#import "Stdio.xc"
#import "Par.xc"

u32 sq(u32 x) { return x * x; }
u32 twice(u32 x) { return sq(x) + sq(x); }
i32 clampTo(i32 v, i32 lo, i32 hi)
    {
    if (v < lo)
        return lo;
    if (v > hi)
        return hi;
    return v;
    }

void main(void)
    {
    u32 a[256];
    i32 c[256];
    u32 total = (u32)0;
    par twiceSq :reduce(+ total)
        {
        for (u32 i in 0..256)
            {
            a[i] = twice(i) % (u32)1000;
            total = total + a[i];
            }
        }
    par clamp
        {
        for (u32 i in 0..256)
            c[i] = clampTo((i32)i - (i32)100, (i32)0, (i32)50);
        }
    Stdio.printf("a[9]=%u a[255]=%u total=%u c[0]=%d c[120]=%d c[255]=%d\n",
                 a[9], a[255], total, c[0], c[120], c[255]);
    }
