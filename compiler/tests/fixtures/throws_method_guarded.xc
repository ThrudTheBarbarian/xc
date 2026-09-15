// The positive half of throws_method_unguarded.xc — the same calls, guarded
// the two ways the effect allows, so the fix for private:docs/bugs/044 cannot buy its
// diagnostic by over-rejecting. Every shape here must COMPILE and RUN.
#import "Foundation.xc"
#import "Error.xc"
#import "Stdio.xc"

class E : Object <Error>
{
    string  m;
    static E* with(string s) { E* e = new E(); e.m = s; return e; }
    string message(void) { return m; }
}

class P : Object
{
    u16 risky(u8 c) throws
    {
        if (c == (u8)0) { throw E.with("zero"); }
        return (u16)(c + (u8)1);
    }
    static u16 sRisky(u8 c) throws
    {
        if (c == (u8)0) { throw E.with("zero"); }
        return (u16)(c + (u8)2);
    }
    // Guard 1: the caller is itself `throws`, so the error propagates.
    u16 propagates(u8 c) throws { return risky(c); }
    // Guard 2: the call is inside a `try`. NOTE the printing happens inside
    // the guarded block rather than assigning out of it — a value assigned
    // inside a `try` does not survive the join today (private:docs/bugs/052), and this
    // fixture is a guard for the EFFECT CHECK, not for that.
    void catches(u8 c)
    {
        try { Stdio.printf("  in-try %d\n", risky(c)); }
        catch (E e) { Stdio.printf("  caught %s\n", e.message()); }
    }
}

i32 main(void)
{
    P* p = new P();
    try { Stdio.printf("method %d\n", p.risky((u8)7)); }
    catch (E e) { Stdio.print("method threw\n"); }

    try { Stdio.printf("static %d\n", P.sRisky((u8)7)); }
    catch (E e) { Stdio.print("static threw\n"); }

    p.catches((u8)0);                 // throws, caught one level down
    p.catches((u8)7);                 // does not throw

    try { Stdio.printf("propagated %d\n", p.propagates((u8)7)); }
    catch (E e) { Stdio.print("propagated threw\n"); }

    try { Stdio.printf("unreached %d\n", p.propagates((u8)0)); }
    catch (E e) { Stdio.print("propagated threw\n"); }
    return 0;
}
