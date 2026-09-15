//xtc-flags: expect=sema-error
// The checked effect on a METHOD call. `throws` exists to make a failure path
// impossible to ignore by accident, and that guarantee was enforced for free
// functions and for `super.foo` only — an ordinary `p.risky()` fell through to
// IR lowering, which rejected it with no source location and no name. Since
// real code is overwhelmingly methods, the rule held on the minority of call
// sites. See private:docs/bugs/044.
#import "Foundation.xc"
#import "Error.xc"

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
        return (u16)1;
    }
    static u16 sRisky(u8 c) throws
    {
        if (c == (u8)0) { throw E.with("zero"); }
        return (u16)2;
    }
    // Implicit self, inside a caller that is NOT itself `throws`.
    u16 viaSelf(void) { return risky((u8)1); }
}

i32 main(void)
{
    P* p = new P();
    u16 a = p.risky((u8)1);        // instance method, unguarded
    u16 b = P.sRisky((u8)1);       // static method, unguarded
    return (i32)(a + b);
}
