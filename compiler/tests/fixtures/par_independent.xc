//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// par_independent.xc — what the independence rule (par-blocks.md §4) lets a
// `par` body do: read and rewrite its own element, write at a fixed offset
// from i and read that same element back, gather from another buffer through
// an index table, and write two elements per item. Same answer on any number
// of threads.
#import "Stdio.xc"
#import "Par.xc"

u32 g[64];

void main(void)
    {
    u32 a[64];
    u32 b[64];
    u32 idx[64];
    u32 pair[128];
    for (u32 i in 0..64)
        {
        a[i] = i;
        b[i] = (u32)100;
        idx[i] = (u32)63 - i;
        g[i] = i * (u32)2;
        }
    par same { for (u32 i in 0..64) { b[i] = b[i] + a[i]; } }
    par shifted { for (u32 i in 0..63) { b[i + 1] = b[i + 1] * (u32)2; } }
    par gather { for (u32 i in 0..64) { a[i] = g[idx[i]]; } }
    par twowrite { for (u32 i in 0..64) { pair[(u32)2 * i] = i; pair[(u32)2 * i + (u32)1] = pair[(u32)2 * i] + (u32)1; } }
    par own { for (u32 i in 0..64) { g[i] = g[i] + (u32)1; } }
    Stdio.printf("b[0]=%u b[5]=%u a[0]=%u a[63]=%u pair[9]=%u g[10]=%u\n",
                 b[0], b[5], a[0], a[63], pair[9], g[10]);
    }
