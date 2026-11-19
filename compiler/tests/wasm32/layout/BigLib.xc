// BigLib.xc — a wasm32 library with 400 KB of static data of its own.
#import "Stdio.xc"

u32 libTable[100000];

void libFill(u32 seed)
    {
    for (u32 k = (u32)0; k < (u32)100000; k = k + (u32)1)
        libTable[k] = seed + k;
    }

// The sum of the table less what libFill(seed) wrote: 0 when it is intact.
u32 libDamage(u32 seed)
    {
    u32 bad = (u32)0;
    for (u32 k = (u32)0; k < (u32)100000; k = k + (u32)1)
        if (libTable[k] != seed + k)
            bad = bad + (u32)1;
    return bad;
    }
