// simd_offset — pointer arithmetic keeps `simd:`, and a par block over a
// pointer INTO a page-aligned block is sized from where it points to the
// block's end (par-blocks.md §3): the runtime's registry finds the block, so
// `q = p + k` is a GPU array of the right length, not the block header read
// through a pointer that has none at its back. The offsets are both page
// multiples (the shared-in-place case on Metal) and not (the copied case):
// either way every element the block writes must land where the CPU reads it.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

#define N (1 << 18)

u32 touch(simd: u32* p, u32 n)
{
    par fill
    {
        for (u32 i in 0..n)
            p[i] = p[i] * (u32)2654435761 + i;
    }
    u32 s = (u32)0;
    for (u32 i in 0..n)
        s = s ^ p[i];
    return s;
}

i32 main(void)
{
    simd: u32* p = new u32[N];
    for (u32 i in 0..N)
        p[i] = i;
    simd: u32* q = p + (u32)65536;            // 256 KB in: a page multiple
    simd: u32* r = p + (u32)100;              // 400 bytes in: not one
    u32 a = touch(q, (u32)65536);
    u32 b = touch(r, (u32)1000);
    u32 c = touch(p, (u32)N);
    // What the CPU would have made of the same three passes, in order.
    u32* v = new u32[N];
    for (u32 i in 0..N)
        v[i] = i;
    for (u32 i in 0..65536)
        v[65536 + i] = v[65536 + i] * (u32)2654435761 + i;
    for (u32 i in 0..1000)
        v[100 + i] = v[100 + i] * (u32)2654435761 + i;
    for (u32 i in 0..N)
        v[i] = v[i] * (u32)2654435761 + i;
    u32 bad = (u32)0;
    for (u32 i in 0..N)
        if (v[i] != p[i])
            bad = bad + (u32)1;
    Stdio.printf("%u %u %u bad=%u\n", a, b, c, bad);
    return (i32)0;
}
