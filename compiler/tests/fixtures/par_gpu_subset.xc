//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
//xtc-warn: because it uses double, which Apple GPUs do not have
// par_gpu_subset.xc — what a `par` body MAY do (par-blocks.md §2): call
// helpers that stay in the subset (transitively), use the maths intrinsics,
// read a global, write a global ARRAY element by element, use a struct and a
// value it captured. The subset check passes and the block runs.
#import "Stdio.xc"
#import "Math.xc"
#import "Par.xc"

struct Px
    {
    u8 r;
    u8 g;
    }

u32 bias = (u32)5;
u32 out[64];

u32 sq(u32 x) { return x * x; }
u32 twice(u32 x) { return sq(x) + sq(x); }

void main(void)
    {
    double d[64];
    Px p;
    p.r = (u8)3;
    p.g = (u8)4;
    u32 total = (u32)0;
    par fill :reduce(+ total)
        {
        for (u32 i in 0..64)
            {
            out[i] = twice(i) + bias + (u32)p.r;
            d[i] = Math.sqrt((double)i);
            total = total + out[i];
            }
        }
    Stdio.printf("out[7]=%u d[49]=%.1f total=%u\n", out[7], d[49], total);
    }
