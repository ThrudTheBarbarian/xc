// par_auto_library_names — with --par-style=auto (the default), a loop over a
// global or a local named key, value, next, index, size or name becomes a par
// block as a loop over keys does (#261). The par runtime's classes have ivars
// with those names, and the parser kept every class's ivar names after the
// class ended, so a block in main took a global `key` for an ivar it could
// not capture and the loop stayed a loop, with nothing said. A class's ivar
// names now belong to that class and its subclasses: a subclass's loop over
// an inherited ivar is still no block, and -Wpar-auto says why (auto.sh). So
// is a loop over a global named lo or hi, the block's own range fields, which
// the block's run() would find before the global. A local k, o or other, the
// names of a parameter or a local of the block's own methods, is captured.
// Each result is checked against the same loop marked :serial.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
#import "Stdio.xc"
#import "Par.xc"

#define N (256 * 1024)

u32 key[N];
u32 value[N];
u32 next[N];
u32 index[N];
u32 size[N];
u32 name[N];
u32 hi[N];
u32 lo[N];

class Base
{
    u32 k;
}

class Scaled : Base
{
    void setK(u32 v)
    {
        k = v;
    }

    // k is Base's: the block form cannot capture it, so the loop stays a loop.
    void fill(u32* d)
    {
        for (u32 i in 0..N)
            d[i] = i * k;
    }
}

// A local named key, and one named value, in a function of their own.
u32 locals(void)
{
    u32* key = new u32[N];
    u32* value = new u32[N];
    for (u32 i in 0..N)
        key[i] = i ^ (u32)0x5a5a;
    for (u32 i in 0..N)
        value[i] = key[i] * (u32)7;
    u32 s = (u32)0;
    for (u32 i in 0..N) : serial
        s = s * (u32)31 + value[i];
    delete key;
    delete value;
    return s;
}

// A captured pointer named k and sums named o and other: the names of a
// parameter and a local of the block's own methods.
bool blockNames(void)
{
    u32* k = new u32[N];
    for (u32 i in 0..N)
        k[i] = i * (u32)13;
    u32 o = (u32)0;
    for (u32 i in 0..N)
        o = o + (k[i] >> 4);
    u32 other = (u32)0;
    for (u32 i in 0..N)
        other = other ^ k[i];
    u32 wo = (u32)0;
    u32 wother = (u32)0;
    for (u32 i in 0..N) : serial
    {
        wo = wo + ((i * (u32)13) >> 4);
        wother = wother ^ (i * (u32)13);
    }
    delete k;
    return o == wo && other == wother;
}

i32 main(void)
{
    for (u32 i in 0..N)
        key[i] = i * (u32)3;
    for (u32 i in 0..N)
        value[i] = key[i] * (u32)2;
    for (u32 i in 0..N)
        next[i] = value[i] + (u32)1;
    for (u32 i in 0..N)
        index[i] = next[i] ^ i;
    for (u32 i in 0..N)
        size[i] = index[i] >> 1;
    for (u32 i in 0..N)
        name[i] = size[i] + key[i];
    for (u32 i in 0..N)
        hi[i] = name[i] | (u32)1;
    for (u32 i in 0..N)
        lo[i] = hi[i] - i;
    u32 total = (u32)0;
    for (u32 i in 0..N)
        total = total + lo[i];

    u32 want = (u32)0;
    u32 bad = (u32)0;
    for (u32 i in 0..N) : serial
    {
        u32 k = i * (u32)3;
        u32 v = k * (u32)2;
        u32 nx = v + (u32)1;
        u32 ix = nx ^ i;
        u32 sz = ix >> 1;
        u32 nm = sz + k;
        u32 h = nm | (u32)1;
        u32 l = h - i;
        want = want + l;
        if (key[i] != k || value[i] != v || next[i] != nx || index[i] != ix || size[i] != sz || name[i] != nm || hi[i] != h || lo[i] != l)
            bad++;
    }
    Stdio.printf("globals %u, total %s\n", bad, total == want ? "same" : "differs");

    u32 ls = locals();
    u32 lw = (u32)0;
    for (u32 i in 0..N) : serial
        lw = lw * (u32)31 + (i ^ (u32)0x5a5a) * (u32)7;
    Stdio.printf("locals %s\n", ls == lw ? "same" : "differ");
    Stdio.printf("block names %s\n", blockNames() ? "same" : "differ");

    Scaled* sc = new Scaled();
    sc.setK((u32)5);
    u32* d = new u32[N];
    sc.fill(d);
    u32 sbad = (u32)0;
    for (u32 i in 0..N) : serial
        if (d[i] != i * (u32)5)
            sbad++;
    Stdio.printf("inherited %u\n", sbad);
    delete d;
    return 0;
}
