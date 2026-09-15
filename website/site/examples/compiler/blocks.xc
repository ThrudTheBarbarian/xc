// blocks.xc — blocks: function values with captures (xtc 0.4).
#import "Stdio.xc"
#import "Foundation.xc"

// A block as a parameter: `each` drives it, the caller supplies it.
u32 each(block cb u32(u32), u32 n)
{
    u32 acc = (u32)0;
    for (u32 i = (u32)0; i < n; i++) { acc = acc + cb(i); }
    return acc;
}

// A block as a return value: the captures live in the block, so they
// outlive this frame — ARC owns the block like any other object.
block cb u32(u32) makeAdder(u32 base)
{
    block a u32(u32 n) = { return base + n; }
    return a;
}

i32 main(void)
{
    // Declaration with a body; the call reads like any function call.
    block add u32(u16 x, u16 y) = { return (u32)x + (u32)y; }
    Stdio.printf("add(2,3)      = %ld\n", add(2, 3));

    // Captures are BY-VALUE snapshots, taken when the literal runs.
    u32 base = (u32)100;
    block plus u32(u32 n) = { return base + n; }
    base = (u32)999;                       // too late: plus still sees 100
    Stdio.printf("plus(7)       = %ld\n", plus(7));

    // Re-assignment; a bare body inherits the DECLARED signature.
    block op u32(u16 x, u16 y);
    op = add;
    Stdio.printf("op=add        = %ld\n", op(10, 20));
    op = { return (u32)x * (u32)y; };
    Stdio.printf("op={x*y}      = %ld\n", op(6, 7));

    // Inline literal in argument position; auto infers block types.
    Stdio.printf("each(2n)      = %ld\n", each(block u32(u32 v) { return v * (u32)2; }, (u32)5));
    auto add5 = makeAdder((u32)5);
    Stdio.printf("add5(10)      = %ld\n", add5((u32)10));

    // A NAMED literal can call itself — recursion without a declaration.
    auto fact = block f u32(u32 n) { if (n <= (u32)1) { return (u32)1; } return n * f(n - (u32)1); };
    Stdio.printf("fact(5)       = %ld\n", fact((u32)5));

    // `block:` — write-back captures: copy in at creation, copy out at
    // every invocation exit. The loop below never sees the variable; it
    // still holds the total the moment `each` returns.
    block:u32 total = (u32)0;
    u32 r = each(block u32(u32 v) { total = total + v; return v; }, (u32)5);
    Stdio.printf("total,r       = %ld %ld\n", total, r);

    // Null is a first-class block value; test before calling.
    block maybe u32(u32);
    maybe = (block u32(u32))0;
    if (maybe) { Stdio.printf("unreachable\n"); }
    else       { Stdio.printf("null block    = ok\n"); }
    return 0;
}
