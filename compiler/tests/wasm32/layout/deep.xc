// deep.xc — unbounded recursion: the shadow stack overflows, and the program
// must trap rather than run on over the static data above the stack. Each
// frame holds 4 KB, so the 1 MiB shadow stack runs out after about 250 calls,
// long before the engine's own call stack does; 100 calls fit in it, and do
// not fit in a 64 KiB one (--stack-size 65536).
#import "Stdio.xc"

u32 guard[1024];

u32 down(u32 n, u32 limit)
    {
    u32 pad[1024];
    for (u32 k = (u32)0; k < (u32)1024; k = k + (u32)1)
        pad[k] = n ^ k;
    if (n == limit)
        return pad[1];
    return down(n + (u32)1, limit) ^ pad[0] ^ n;
    }

void main(void)
    {
    for (u32 k = (u32)0; k < (u32)1024; k = k + (u32)1)
        guard[k] = k;
    Stdio.printf("shallow %u\n", down((u32)0, (u32)100));
    u32 bad = (u32)0;
    for (u32 k = (u32)0; k < (u32)1024; k = k + (u32)1)
        if (guard[k] != k)
            bad = bad + (u32)1;
    Stdio.printf("guard damage %u\n", bad);
    // Never returns: 4 billion frames do not fit in any stack.
    Stdio.printf("deep %u\n", down((u32)0, (u32)$FFFFFFFF));
    }
