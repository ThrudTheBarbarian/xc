// par_array_reduce.xc — `:reduce(op h[])`: a written par block that updates
// an array through an index read from data. Each chunk updates a private copy
// of the array, filled with the operator's identity, and the copies are
// folded into the array when the block ends, so the result is the serial
// loop's whatever the thread count (XC_PAR_THREADS). Such a block has no GPU
// version yet and runs on the CPU's threads.
//
// A local u32 histogram with +, a global u16 array with |, a global u8 array
// with & (identity all ones) and a local u64 array with ^; each checked
// against the same loop run serially. The arrays start non-zero, so the fold
// into the array itself is checked too.
//
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

u8 keys[20000];
u16 bits[16];
u8 masks[8];

i32 main(void)
    {
    u32 seed = (u32)12345;
    for (u32 i in 0..20000)
        {
        seed = seed * (u32)1103515245 + (u32)12345;
        keys[i] = (u8)(seed >> (u32)16);
        }
    u32 hist[64];
    u32 want[64];
    for (u32 b in 0..64)
        {
        hist[b] = b;
        want[b] = b;
        }
    par count :reduce(+ hist[])
        {
        for (u32 i in 0..20000)
            hist[(u32)(keys[i] & (u8)63)] = hist[(u32)(keys[i] & (u8)63)] + (u32)1;
        }
    for (u32 i in 0..20000)
        want[(u32)(keys[i] & (u8)63)] = want[(u32)(keys[i] & (u8)63)] + (u32)1;
    u32 bad = (u32)0;
    u32 total = (u32)0;
    for (u32 b in 0..64)
        {
        if (hist[b] != want[b])
            bad = bad + (u32)1;
        total = total + hist[b];
        }
    Stdio.printf("hist: bad=%u total=%u hist[5]=%u\n", bad, total, hist[5]);

    u16 wantBits[16];
    for (u32 b in 0..16)
        {
        bits[b] = (u16)(b << (u32)12);
        wantBits[b] = bits[b];
        }
    par :reduce(| bits[])
        {
        for (u32 i in 0..20000)
            bits[(u32)(keys[i] & (u8)15)] = bits[(u32)(keys[i] & (u8)15)] | (u16)((u32)1 << (u32)(keys[i] >> (u8)4));
        }
    for (u32 i in 0..20000)
        wantBits[(u32)(keys[i] & (u8)15)] = wantBits[(u32)(keys[i] & (u8)15)] | (u16)((u32)1 << (u32)(keys[i] >> (u8)4));
    bad = (u32)0;
    for (u32 b in 0..16)
        if (bits[b] != wantBits[b])
            bad = bad + (u32)1;
    Stdio.printf("bits: bad=%u bits[3]=%u\n", bad, (u32)bits[3]);

    u8 wantMasks[8];
    for (u32 b in 0..8)
        {
        masks[b] = (u8)255;
        wantMasks[b] = (u8)255;
        }
    par :reduce(& masks[])
        {
        for (u32 i in 1000..1024)
            masks[(u32)(keys[i] & (u8)7)] = masks[(u32)(keys[i] & (u8)7)] & (u8)(keys[i] | (u8)1);
        }
    for (u32 i in 1000..1024)
        wantMasks[(u32)(keys[i] & (u8)7)] = wantMasks[(u32)(keys[i] & (u8)7)] & (u8)(keys[i] | (u8)1);
    bad = (u32)0;
    for (u32 b in 0..8)
        if (masks[b] != wantMasks[b])
            bad = bad + (u32)1;
    Stdio.printf("masks: bad=%u masks[2]=%u\n", bad, (u32)masks[2]);

    u64 mix[32];
    u64 wantMix[32];
    for (u32 b in 0..32)
        {
        mix[b] = (u64)b * (u64)977;
        wantMix[b] = mix[b];
        }
    par :reduce(^ mix[])
        {
        for (u32 i in 0...19999)
            mix[(u32)(keys[i] & (u8)31)] = mix[(u32)(keys[i] & (u8)31)] ^ (u64)i * (u64)2654435761;
        }
    for (u32 i in 0...19999)
        wantMix[(u32)(keys[i] & (u8)31)] = wantMix[(u32)(keys[i] & (u8)31)] ^ (u64)i * (u64)2654435761;
    bad = (u32)0;
    for (u32 b in 0..32)
        if (mix[b] != wantMix[b])
            bad = bad + (u32)1;
    Stdio.printf("mix: bad=%u\n", bad);
    return (i32)0;
    }
