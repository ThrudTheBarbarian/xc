// par_guard_offset — a par block whose write and read differ by a captured
// offset: `a[i + off] = f(a[i])`. No static test can say whether two work
// items meet, so par-check leaves the run a guard (the header's guard= word)
// and the runtime decides per run: an offset of n keeps the items apart and
// the block runs in parallel; an offset of 1 makes every item read the one
// before it, and the block runs serially, as its source reads. Either way
// the answer is the serial loop's.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
#import "Stdio.xc"
#import "Par.xc"

#define N (1024 * 1024)

void step(u32* a, u32 off)
{
    par shift
    {
        for (u32 i in 0..N)
            a[i + off] = a[i] * (u32)3 + (u32)1;
    }
}

void stepSerial(u32* a, u32 off)
{
    for (u32 i in 0..N)
        a[i + off] = a[i] * (u32)3 + (u32)1;
}

u32 check(u32 off)
{
    u32* a = new u32[2 * N];
    u32* b = new u32[2 * N];
    for (u32 i in 0..2 * N)
    {
        a[i] = i * (u32)2654435761;
        b[i] = a[i];
    }
    step(a, off);
    stepSerial(b, off);
    u32 bad = (u32)0;
    for (u32 i in 0..2 * N)
        if (a[i] != b[i])
            bad = bad + (u32)1;
    delete a;
    delete b;
    return bad;
}

i32 main(void)
{
    Stdio.printf("apart: bad=%u\n", check((u32)N));
    Stdio.printf("meeting: bad=%u\n", check((u32)1));
    return 0;
}
