// blocks_escape.xc — blocks v1, the ownership shapes: a block RETURNED
// from its creating function (the captures outlive the frame — they are
// ivars of the impl instance, which ARC owns), a block stored in an ivar
// and dispatched from a method, the null cast + guard, a block capturing
// another block, and named-literal recursion (the name dispatches on
// `self` — the literal IS the impl instance).
#import "Stdio.xc"
#import "Foundation.xc"

block cb u32(u32 n) makeAdder(u32 base)
{
    block a u32(u32 n) = { return base + n; }
    return a;
}

class Holder
{
    u32 pad;
    block cb u32(u32 n);
    void init(void) { pad = (u32)0; cb = (block u32(u32))0; }
    void set(block c u32(u32)) { cb = c; }
    u32 run(u32 v) { return cb(v); }
}

i32 main(void)
{
    // escaping: block returned from a function, called later
    auto add5 = makeAdder((u32)5);
    auto add9 = makeAdder((u32)9);
    Stdio.printf("T1 %ld %ld\n", add5((u32)10), add9((u32)10));

    // stored in an ivar, invoked through a method
    Holder* h = new Holder();
    String* tag = String.withCString("x");
    h.set(block u32(u32 n) { return n + tag.byteLength(); });
    Stdio.printf("T2 %ld\n", h.run((u32)41));

    // null test + guarded call
    block maybe u32(u32 n);
    maybe = (block u32(u32))0;
    if (maybe) { Stdio.printf("bad\n"); } else { Stdio.printf("T3 null ok\n"); }

    // block capturing a block
    auto twice = makeAdder((u32)1);
    block wrap u32(u32 n) = { return twice(n) + twice(n); }
    Stdio.printf("T4 %ld\n", wrap((u32)3));

    // named literal recursion: factorial
    auto fact = block f u32(u32 n) { if (n <= (u32)1) { return (u32)1; } return n * f(n - (u32)1); };
    Stdio.printf("T5 %ld\n", fact((u32)5));
    return 0;
}
