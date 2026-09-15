// recurse-spill.xc — non-leaf recursion with a ZP-overflow pinned local.
//
// `u8 buf[100]` is a pinned aggregate (address-taken) too big for the
// ~96-byte ZP pool, so it spills. The function is non-leaf (it calls
// itself), so the spill must be a *per-invocation* software-stack frame
// (STACK-ABI §11.3) — a static slot would alias `buf` across recursion
// levels and the deepest call (n==0) would clobber every level's
// `buf[0]`, collapsing the sum to 0.
//
// Each level stores its own `n` into `buf[0]`, recurses, then reads
// `buf[0]` back and adds it to the recursive result. Correct framing →
// sumDown(5) = 5+4+3+2+1+0 = 15.
u16 sumDown(u8 n)
    {
    u8 buf[100];
    buf[0] = n;
    if (n == 0)
        return (u16)0;
    u16 rest = sumDown(n - (u8)1);
    return (u16)buf[0] + rest;
    }
