// bigapp.xc — 1.2 MB of static data of its own, a library with 400 KB more,
// heap objects and a deep call chain: none of them may overwrite another.
#import "Stdio.xc"
#import <BigLib>

u32 appTable[300000];

u32 depth(u32 n)
    {
    u32 pad[64];
    for (u32 k = (u32)0; k < (u32)64; k = k + (u32)1)
        pad[k] = n + k;
    if (n == (u32)0)
        return pad[3];
    return depth(n - (u32)1) + pad[63] - n - (u32)63;
    }

void main(void)
    {
    for (u32 k = (u32)0; k < (u32)300000; k = k + (u32)1)
        appTable[k] = k * (u32)3;
    libFill((u32)7);
    // 4 MB of heap, written through.
    u32 blocks = (u32)0;
    for (u32 b = (u32)0; b < (u32)16; b = b + (u32)1)
        {
        u32* h = new u32[65536];
        for (u32 k = (u32)0; k < (u32)65536; k = k + (u32)1)
            h[k] = (u32)$FFFFFFFF;
        blocks = blocks + (u32)1;
        }
    // 2,000 frames of 256+ bytes: half the 1 MiB stack.
    u32 d = depth((u32)2000);
    u32 bad = (u32)0;
    for (u32 k = (u32)0; k < (u32)300000; k = k + (u32)1)
        if (appTable[k] != k * (u32)3)
            bad = bad + (u32)1;
    Stdio.printf("blocks %u depth %u app damage %u lib damage %u\n",
                 blocks, d, bad, libDamage((u32)7));
    }
