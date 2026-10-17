// par_guard_two — indexes with two captured integers: `a[i + off + base]`.
// Read and written by the same item it needs no check at all (the terms
// cancel); against `a[i + base]` the run checks the elements are apart,
// running in parallel when they are and serially, as the source reads,
// when they are not. Each block's answer is the serial loop's.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
#import "Stdio.xc"
#import "Par.xc"

#define N (256 * 1024)

void inPlace(u32* a, u32 off, u32 base)
{
    par inplace
    {
        for (u32 i in 0..N)
            a[i + off + base] = a[i + off + base] * (u32)3 + i;
    }
}

void shifted(u32* a, u32 off, u32 base)
{
    par shifted
    {
        for (u32 i in 0..N)
            a[i + off + base] = a[i + base] * (u32)5 + (u32)1;
    }
}

void twoEach(u32* a, u32 o1, u32 o2, u32 o3)
{
    par twoeach
    {
        for (u32 i in 0..N)
            a[(u32)2 * i + o1 + o2] = a[i + o3 + o1] + (u32)7;
    }
}

void inPlaceSerial(u32* a, u32 off, u32 base)
{
    for (u32 i in 0..N)
        a[i + off + base] = a[i + off + base] * (u32)3 + i;
}

void shiftedSerial(u32* a, u32 off, u32 base)
{
    for (u32 i in 0..N)
        a[i + off + base] = a[i + base] * (u32)5 + (u32)1;
}

void twoEachSerial(u32* a, u32 o1, u32 o2, u32 o3)
{
    for (u32 i in 0..N)
        a[(u32)2 * i + o1 + o2] = a[i + o3 + o1] + (u32)7;
}

u32 differ(u32* a, u32* b)
{
    u32 bad = (u32)0;
    for (u32 i in 0..4 * N)
        if (a[i] != b[i])
            bad = bad + (u32)1;
    return bad;
}

void fill(u32* a, u32* b)
{
    for (u32 i in 0..4 * N)
    {
        a[i] = i * (u32)2654435761;
        b[i] = a[i];
    }
}

i32 main(void)
{
    u32* a = new u32[4 * N];
    u32* b = new u32[4 * N];
    u32 offs[3] = {(u32)1, (u32)300, (u32)N};
    for (u32 t in 0..3)
    {
        u32 off = offs[t];
        fill(a, b);
        inPlace(a, off, (u32)17);
        inPlaceSerial(b, off, (u32)17);
        Stdio.printf("inplace %u: %u differ\n", off, differ(a, b));
        fill(a, b);
        shifted(a, off, (u32)17);
        shiftedSerial(b, off, (u32)17);
        Stdio.printf("shifted %u: %u differ\n", off, differ(a, b));
        fill(a, b);
        twoEach(a, (u32)5, off, (u32)2 * N + off);
        twoEachSerial(b, (u32)5, off, (u32)2 * N + off);
        Stdio.printf("twoeach %u: %u differ\n", off, differ(a, b));
        fill(a, b);
        twoEach(a, (u32)5, off, (u32)0);
        twoEachSerial(b, (u32)5, off, (u32)0);
        Stdio.printf("twoeach-overlap %u: %u differ\n", off, differ(a, b));
    }
    return 0;
}
