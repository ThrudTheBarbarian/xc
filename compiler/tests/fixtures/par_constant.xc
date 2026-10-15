// par_constant — the :constant storage hint (par-blocks.md §3): a captured
// array the body only reads, named in the block's header, is bound by the
// Metal printer in the constant address space (read-only, cached and broadcast
// to every thread); the other GPU forms and the CPU path take it as any other
// read-only array. A hint never changes a result: the lookup table here is
// read by every item and the output is checked on the CPU.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

#define SIZE (256 * 1024)

i32 main(void)
{
    u32 table[256];
    for (u32 i in 0..256)
        table[i] = (i * (u32)2654435761) >> (u32)7;
    u32* xs = new u32[SIZE];
    u32* ys = new u32[SIZE];
    for (u32 i in 0..SIZE)
    {
        xs[i] = i * (u32)40503;
        ys[i] = (u32)0;
    }
    par lookup :constant(table)
    {
        for (u32 i in 0..SIZE)
        {
            u32 v = xs[i];
            u32 h = table[v & (u32)255] ^ table[(v >> (u32)8) & (u32)255];
            h = h + table[(v >> (u32)16) & (u32)255];
            ys[i] = h ^ (v >> (u32)24);
        }
    }
    u32 bad = (u32)0;
    u32 sum = (u32)0;
    for (u32 i in 0..SIZE)
    {
        u32 v = xs[i];
        u32 h = table[v & (u32)255] ^ table[(v >> (u32)8) & (u32)255];
        h = h + table[(v >> (u32)16) & (u32)255];
        if (ys[i] != (h ^ (v >> (u32)24)))
            bad = bad + (u32)1;
        sum = sum + ys[i];
    }
    Stdio.printf("bad=%u sum=%u\n", bad, sum);
    return (i32)0;
}
