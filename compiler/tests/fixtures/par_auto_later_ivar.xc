//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_later_ivar.xc — with --par-style=auto, a loop in a method that
// names an instance variable the class declares further down builds (#509).
// A block captures an ivar from its declaration, which the parse has not
// reached, so the loop stays a loop; it failed to compile, with "Undefined
// identifier". The same loop in a class that declares its ivars first
// becomes a block.
#import "Stdio.xc"
class Box
{
    void fill(u32 k)
    {
        _a = new u32[100000];
        _n = 100000;
        for (u32 i = 0; i < _n; i++)
            _a[i] = i * k;
    }
    u64 sum()
    {
        u64 t = 0;
        for (u32 i = 0; i < _n; i++)
            t += (u64)_a[i];
        return t;
    }
    u32* _a;
    u32 _n, _k = 3;
}
class Crate
{
    u32* _a;
    u32 _n;
    void fill(u32 k)
    {
        _a = new u32[100000];
        _n = 100000;
        for (u32 i = 0; i < _n; i++)
            _a[i] = i * k;
    }
}
i32 main(void)
{
    Box* b = new Box();
    b.fill(3);
    Crate* g = new Crate();
    g.fill(5);
    u64 t = 0;
    for (u32 i = 0; i < g._n; i++)
        t += (u64)g._a[i];
    Stdio.printf("%u %llu %u %llu\n", b._a[99999], b.sum(), g._a[99999], t);
    return 0;
}
