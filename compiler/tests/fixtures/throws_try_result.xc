// throws_try_result.xc — RED GUARD for private:docs/bugs/052.
//
// The canonical shape of the feature: run something that can fail, keep the
// answer on success and a fallback on failure. Neither value survives the join
// today — the try lowering builds the blocks but never merges the per-local SSA
// bindings, so `v` keeps whatever it had before the `try`.
//
// The oracle below is the CORRECT output. It fails until 052 is fixed.
#import "Foundation.xc"
#import "Error.xc"
#import "Stdio.xc"

class E : Object <Error>
{
    string  m;
    static E* with(string s) { E* e = new E(); e.m = s; return e; }
    string message(void) { return m; }
}

u16 risky(u8 c) throws
{
    if (c == (u8)0) { throw E.with("zero"); }
    return (u16)(c + (u8)1);
}

i32 main(void)
{
    u16 ok = (u16)0;
    try { ok = risky((u8)7); } catch (E e) { ok = (u16)99; }

    u16 failed = (u16)0;
    try { failed = risky((u8)0); } catch (E e) { failed = (u16)99; }

    Stdio.printf("ok=%d failed=%d\n", ok, failed);
    return 0;
}
