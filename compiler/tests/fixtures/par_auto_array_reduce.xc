// par_auto_array_reduce — with --par-style=auto (the default), a plain loop that
// updates an outer array through an index read from data, and uses the array
// in no other way, becomes a par block with an array reduction, as if it were
// written `par :reduce(op h[])`: hist[k] += x on a local u32 array, bits[k] |= x
// on a global u8 array, hist[k]++, h[k] = h[k] + x, and &= and ^= beside a
// scalar sum. A loop that also reads its array another way, and a loop over a
// float array, stay as they are. Each result is checked against the same loop
// marked :serial, so the answer is the serial loop's whatever the thread count.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
#import "Stdio.xc"
#import "Par.xc"

#define N (1024 * 1024)

u8 bits[32];
u8 wantBits[32];

i32 main(void)
{
    u32* key = new u32[N];
    for (u32 i in 0..N)
        key[i] = (i * (u32)2654435761) >> 8;

    // hist[k] += x: a + reduction into a local u32 array.
    u32 hist[256];
    u32 want[256];
    for (u32 b in 0..256)
    {
        hist[b] = b;
        want[b] = b;
    }
    for (u32 i in 0..N)
        hist[key[i] & (u32)255] += key[i] >> (u32)20;
    for (u32 i in 0..N) : serial
        want[key[i] & (u32)255] += key[i] >> (u32)20;
    u32 bad = (u32)0;
    for (u32 b in 0..256)
        if (hist[b] != want[b])
            bad++;
    Stdio.printf("+=: bad=%u hist[7]=%u\n", bad, hist[7]);

    // bits[k] |= x: an | reduction into a global u8 array.
    for (u32 i in 0..N)
        bits[(key[i] >> (u32)3) & (u32)31] |= (u8)((u32)1 << (key[i] & (u32)7));
    for (u32 i in 0..N) : serial
        wantBits[(key[i] >> (u32)3) & (u32)31] |= (u8)((u32)1 << (key[i] & (u32)7));
    bad = (u32)0;
    for (u32 b in 0..32)
        if (bits[b] != wantBits[b])
            bad++;
    Stdio.printf("|=: bad=%u bits[3]=%u\n", bad, (u32)bits[3]);

    // hist[k]++: a + reduction, one at a time.
    u16 count[64];
    u16 wantCount[64];
    for (u32 b in 0..64)
    {
        count[b] = (u16)0;
        wantCount[b] = (u16)0;
    }
    for (u32 i in 0..N)
        count[key[i] % (u32)64]++;
    for (u32 i in 0..N) : serial
        wantCount[key[i] % (u32)64]++;
    bad = (u32)0;
    for (u32 b in 0..64)
        if (count[b] != wantCount[b])
            bad++;
    Stdio.printf("++: bad=%u count[9]=%u\n", bad, (u32)count[9]);

    // h[k] = h[k] + x, the same index on both sides.
    u64 sum[16];
    u64 wantSum[16];
    for (u32 b in 0..16)
    {
        sum[b] = (u64)b;
        wantSum[b] = (u64)b;
    }
    for (u32 i in 0..N)
        sum[key[i] & (u32)15] = sum[key[i] & (u32)15] + (u64)key[i] * (u64)3;
    for (u32 i in 0..N) : serial
        wantSum[key[i] & (u32)15] = wantSum[key[i] & (u32)15] + (u64)key[i] * (u64)3;
    bad = (u32)0;
    for (u32 b in 0..16)
        if (sum[b] != wantSum[b])
            bad++;
    Stdio.printf("= +: bad=%u\n", bad);

    // &= and ^= into two arrays, and a scalar sum beside them.
    u32 mask[8];
    u32 wantMask[8];
    i32 mix[8];
    i32 wantMix[8];
    for (u32 b in 0..8)
    {
        mask[b] = (u32)$FFFFFFFF;
        wantMask[b] = (u32)$FFFFFFFF;
        mix[b] = (i32)b;
        wantMix[b] = (i32)b;
    }
    u32 total = (u32)0;
    for (u32 i in 0..N)
    {
        u32 k = key[i] & (u32)7;
        mask[k] &= key[i] | (u32)$FFFF0F0F;
        mix[k] ^= (i32)(key[i] * (u32)977);
        total += key[i] & (u32)255;
    }
    u32 wantTotal = (u32)0;
    for (u32 i in 0..N) : serial
    {
        u32 k = key[i] & (u32)7;
        wantMask[k] &= key[i] | (u32)$FFFF0F0F;
        wantMix[k] ^= (i32)(key[i] * (u32)977);
        wantTotal += key[i] & (u32)255;
    }
    bad = (u32)0;
    for (u32 b in 0..8)
        if (mask[b] != wantMask[b] || mix[b] != wantMix[b])
            bad++;
    Stdio.printf("&= ^=: bad=%u total ok=%d\n", bad, (i32)(total == wantTotal));

    // The array read another way as well: no reduction, the loop as it was.
    u32 run[256];
    u32 wantRun[256];
    for (u32 b in 0..256)
    {
        run[b] = (u32)0;
        wantRun[b] = (u32)0;
    }
    for (u32 i in 0..N)
        run[key[i] & (u32)255] += run[(key[i] >> (u32)8) & (u32)255] & (u32)1;
    for (u32 i in 0..N) : serial
        wantRun[key[i] & (u32)255] += wantRun[(key[i] >> (u32)8) & (u32)255] & (u32)1;
    bad = (u32)0;
    for (u32 b in 0..256)
        if (run[b] != wantRun[b])
            bad++;
    Stdio.printf("read too: bad=%u\n", bad);

    // A float array: no reduction (it would reassociate the sums).
    float fh[16];
    float wantFh[16];
    for (u32 b in 0..16)
    {
        fh[b] = 0.0f;
        wantFh[b] = 0.0f;
    }
    for (u32 i in 0..N)
        fh[key[i] & (u32)15] += (float)(key[i] & (u32)3) * 0.5f;
    for (u32 i in 0..N) : serial
        wantFh[key[i] & (u32)15] += (float)(key[i] & (u32)3) * 0.5f;
    bad = (u32)0;
    for (u32 b in 0..16)
        if (fh[b] != wantFh[b])
            bad++;
    Stdio.printf("float: bad=%u\n", bad);
    delete key;
    return 0;
}
