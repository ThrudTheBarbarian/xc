//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// par_loop_capture.xc — a `par` block inside a loop uses that loop's
// variable. A loop header's variable was not bound for capture, so the block
// saw it as undefined: in both compilers for `for (T x in a..b)`, and in the
// reference for a C-style `for` too. The block runs once per round.
#import "Stdio.xc"
#import "Par.xc"

u32 a[4096];

void main(void)
    {
    u32 total = (u32)0;
    for (u32 round in 0..3)
        {
        par :reduce(+ total)
            {
            for (u32 i in 0..4096)
                {
                a[i] = i * (u32)3 + round;
                total = total + (a[i] & (u32)1);
                }
            }
        }
    for (u32 k = (u32)10; k < (u32)12; k = k + (u32)1)
        {
        par :reduce(+ total)
            {
            for (u32 i in 0..4096)
                total = total + (k & (u32)1);
            }
        }
    Stdio.printf("total %u a[7]=%u\n", total, a[7]);
    }
