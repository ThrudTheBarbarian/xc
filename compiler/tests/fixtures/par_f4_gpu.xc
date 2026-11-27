// par_f4_gpu.xc — par blocks reading and writing f4 arrays, two elements to
// a byte, on the GPU against the CPU, bit for bit. Each block runs once with
// :device(cpu) and once with :device(gpu), into arrays whose bytes are
// cleared first; every byte of the two results is compared, so a nibble
// written outside the range or lost to a neighbour's write shows. The ranges
// have odd and even lengths (1001, 4097, 4096 and one or two items) and start
// on even and odd items, so a range that starts on the other parity than the
// block's writes has its first item run apart. Writes at a[i] (parity 0) and
// at a[i + 1] (parity 1), every f4 pattern read back, a read-modify-write of
// each element, a reduction over the codes, and a heap array large enough to
// reach the GPU. On a target with no GPU both blocks run on the CPU, and the
// output is the same.
//xtc-na: xt6502, m68k — par has no threads there
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "Par.xc"

#define N 4098
#define NB 2049
#define NH 262144

f32 xs[N];
f4 pat[N];
f4 ac[N];
f4 ag[N];
f32 wc[N];
f32 wg[N];

u32 _seed;

u32 next(void)
{
    u32 x = _seed;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    _seed = x;
    return x;
}

void clear(void)
{
    u8* c = (u8*)&ac[0];
    u8* g = (u8*)&ag[0];
    for (u32 i in 0..NB) : serial
    {
        c[i] = 0;
        g[i] = 0;
    }
}

// Bytes that differ between the CPU's and the GPU's array.
u32 differ(u8* a, u8* b, u32 n)
{
    u32 bad = 0;
    for (u32 i in 0..n) : serial
        if (a[i] != b[i])
            bad++;
    return bad;
}

// f32 patterns that differ.
u32 differ32(u32* a, u32* b, u32 n)
{
    u32 bad = 0;
    for (u32 i in 0..n) : serial
        if (a[i] != b[i])
            bad++;
    return bad;
}

void inputs(void)
{
    u32* s = (u32*)&xs[0];
    u8* p = (u8*)&pat[0];
    _seed = 2463534242;
    for (u32 i in 0..N) : serial
    {
        u32 r = next();
        // Every sixteenth to the eighth a pattern of any exponent (infinities
        // and NaNs too), else a multiple of 1/16 in [-7, 7]: the ties of
        // e2m1 (0.25, 0.75, 1.25, 1.75, 2.5, 3.5, 5) and past its range.
        if ((i & 7) == 0)
            s[i] = r;
        else
            xs[i] = (f32)((i32)(r % 225) - 112) / 16.0;
    }
    // Every code in turn, then the codes from the generator.
    for (u32 i in 0..NB) : serial
    {
        if (i < 128)
            p[i] = (u8)(i * 17 + (i >> 4));
        else
            p[i] = (u8)next();
    }
}

// Rounding to f4, a[i] = (f4)x: each range on both devices.
u32 encode(u32 lo, u32 hi)
{
    clear();
    par encCpu :device(cpu) { for (u32 i in lo..hi) ac[i] = (f4)xs[i]; }
    par encGpu :device(gpu) { for (u32 i in lo..hi) ag[i] = (f4)xs[i]; }
    return differ((u8*)&ac[0], (u8*)&ag[0], NB);
}

// The odd parity: a[i + 1] = (f4)x.
u32 encodeUp(u32 lo, u32 hi)
{
    clear();
    par upCpu :device(cpu) { for (u32 i in lo..hi) ac[i + 1] = (f4)xs[i]; }
    par upGpu :device(gpu) { for (u32 i in lo..hi) ag[i + 1] = (f4)xs[i]; }
    return differ((u8*)&ac[0], (u8*)&ag[0], NB);
}

// Every pattern widened, f32 = (f32)a[i]: a block that only reads f4.
u32 decode(u32 lo, u32 hi)
{
    for (u32 i in 0..N) : serial
    {
        wc[i] = 0.0;
        wg[i] = 0.0;
    }
    par decCpu :device(cpu) { for (u32 i in lo..hi) wc[i] = (f32)pat[i] * 3.0; }
    par decGpu :device(gpu) { for (u32 i in lo..hi) wg[i] = (f32)pat[i] * 3.0; }
    return differ32((u32*)&wc[0], (u32*)&wg[0], N);
}

// Read and write in one block: a[i] from pat[i], then a[i] from itself.
u32 rewrite(u32 lo, u32 hi)
{
    clear();
    par mixCpu :device(cpu) { for (u32 i in lo..hi) ac[i] = (f4)((f32)pat[i] * 1.5 + xs[i]); }
    par mixGpu :device(gpu) { for (u32 i in lo..hi) ag[i] = (f4)((f32)pat[i] * 1.5 + xs[i]); }
    par selfCpu :device(cpu) { for (u32 i in lo..hi) ac[i] = (f4)((f32)ac[i] * -0.5); }
    par selfGpu :device(gpu) { for (u32 i in lo..hi) ag[i] = (f4)((f32)ag[i] * -0.5); }
    return differ((u8*)&ac[0], (u8*)&ag[0], NB);
}

// A reduction beside the writes: the sum of the codes it writes.
u32 reduce(u32 lo, u32 hi)
{
    clear();
    u32 sc = 0;
    u32 sg = 0;
    par redCpu :device(cpu) :reduce(+ sc)
    {
        for (u32 i in lo..hi)
        {
            ac[i] = pat[i];
            sc += (u32)((f32)pat[i] * 2.0 + 12.0);
        }
    }
    par redGpu :device(gpu) :reduce(+ sg)
    {
        for (u32 i in lo..hi)
        {
            ag[i] = pat[i];
            sg += (u32)((f32)pat[i] * 2.0 + 12.0);
        }
    }
    return differ((u8*)&ac[0], (u8*)&ag[0], NB) + (sc != sg ? 1 : 0);
}

// A heap array of NH elements (128 KB): its own pages, so its size is known.
u32 heap(u32 lo, u32 hi)
{
    f4[] hc = new f4[NH];
    f4[] hg = new f4[NH];
    u8* bc = (u8*)hc;
    u8* bg = (u8*)hg;
    for (u32 i in 0..NH / 2) : serial
    {
        bc[i] = 0;
        bg[i] = 0;
    }
    par heapCpu :device(cpu) { for (u32 i in lo..hi) hc[i] = (f4)xs[i & 4095]; }
    par heapGpu :device(gpu) { for (u32 i in lo..hi) hg[i] = (f4)xs[i & 4095]; }
    return differ(bc, bg, NH / 2);
}

i32 main(void)
{
    inputs();
    u32 los[6];
    u32 his[6];
    los[0] = 0; his[0] = 1001;
    los[1] = 1; his[1] = 1001;
    los[2] = 0; his[2] = 4097;
    los[3] = 3; his[3] = 4097;
    los[4] = 1; his[4] = 4097;
    los[5] = 0; his[5] = 4096;
    for (u32 k in 0..6) : serial
    {
        u32 lo = los[k];
        u32 hi = his[k];
        Stdio.printf("[%d, %d): encode %d up %d decode %d rewrite %d reduce %d\n", (i32)lo, (i32)hi, (i32)encode(lo, hi),
                     (i32)encodeUp(lo, hi), (i32)decode(lo, hi), (i32)rewrite(lo, hi), (i32)reduce(lo, hi));
    }
    Stdio.printf("one item: %d %d %d %d\n", (i32)encode(1, 2), (i32)encode(2, 3), (i32)encodeUp(0, 1), (i32)encodeUp(5, 6));
    Stdio.printf("two items: %d %d\n", (i32)encode(1, 3), (i32)encodeUp(1, 3));
    Stdio.printf("heap %d %d\n", (i32)heap(0, NH), (i32)heap(1, NH - 1));
    return 0;
}
