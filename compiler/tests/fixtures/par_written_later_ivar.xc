//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_written_later_ivar.xc — a written `par` block in a method that names
// an instance variable the class declares further down builds (#513), as
// one in a class that declares its ivars first does: the block captures the
// ivar with the type its declaration gives it. It failed to compile with
// "Undefined identifier". Box declares its ivars after its methods, two of
// them in one declaration; Crate declares them first.
#import "Stdio.xc"
#import "Par.xc"
class Box
{
    void fill(u32 k)
    {
        _a = new u32[100000];
        _n = 100000;
        _k = k;
        par { for (u32 i in 0.._n) _a[i] = i * _k; }
    }
    u64 sum()
    {
        u64 t = 0;
        par :reduce(+ t) { for (u32 i in 0.._n) t += (u64)_a[i]; }
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
        par { for (u32 i in 0.._n) _a[i] = i * k; }
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
