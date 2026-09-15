// Regression for `return tmp.sub;` — returning a struct-typed field
// chain as the result of a large-struct-returning function. Before
// the fix, emitReturn's large-struct branch only accepted a bare
// local-struct identifier as the return expression; any
// XTMemberAccessNode form diagnosed with "large-struct return
// supports only a local struct identifier".
//
// emitReturn now resolves the field chain to (base, byte offset)
// via flattenStructFieldChain and byte-copies `width` bytes from
// `base + offset` into `*__retbuf`. Handles both ZP-resident and
// spill-labelled base structs, and arbitrarily deep nesting.
//
// Standard target only — the banked target has the same
// pre-existing caller-side large-struct read-truncation issue
// noted in struct_return_expr_large.xc.

#import "Stdio.xc"

struct Inner {
    u16 a; u16 b; u16 c;
    u16 d; u16 e; u16 f;
}

struct Outer { u16 tag; Inner sub; }

struct Mid { u8  tag; Inner payload; }
struct Top { u16 n;   Mid   m; }

// T1: `return o.sub;` — one-level chain, base is a parameter.
Inner pluck(Outer o)
{
    return o.sub;
}

// T2: `return t.m.payload;` — two-level chain off a parameter.
Inner deepPluck(Top t)
{
    return t.m.payload;
}

// T3: `return g.sub;` — one-level chain off a ZP-resident global.
Outer gOuter;

Inner pluckGlobal(void)
{
    return gOuter.sub;
}

void main(void)
{
    Outer o;
    o.tag = 7;
    o.sub.a = 100; o.sub.b = 200; o.sub.c = 300;
    o.sub.d = 400; o.sub.e = 500; o.sub.f = 600;

    Inner r = pluck(o);
    if (r.a == 100 && r.b == 200 && r.c == 300 &&
        r.d == 400 && r.e == 500 && r.f == 600) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL %u %u %u %u %u %u\n",
                     r.a, r.b, r.c, r.d, r.e, r.f);
    }

    Top t;
    t.n = 42;
    t.m.tag = 9;
    t.m.payload.a = 11; t.m.payload.b = 22; t.m.payload.c = 33;
    t.m.payload.d = 44; t.m.payload.e = 55; t.m.payload.f = 66;

    Inner r2 = deepPluck(t);
    if (r2.a == 11 && r2.b == 22 && r2.c == 33 &&
        r2.d == 44 && r2.e == 55 && r2.f == 66) {
        Stdio.printf("T2 PASS\n");
    } else {
        Stdio.printf("T2 FAIL %u %u %u %u %u %u\n",
                     r2.a, r2.b, r2.c, r2.d, r2.e, r2.f);
    }

    gOuter.tag = 1;
    gOuter.sub.a = 1000; gOuter.sub.b = 1001; gOuter.sub.c = 1002;
    gOuter.sub.d = 1003; gOuter.sub.e = 1004; gOuter.sub.f = 1005;

    Inner r3 = pluckGlobal();
    if (r3.a == 1000 && r3.b == 1001 && r3.c == 1002 &&
        r3.d == 1003 && r3.e == 1004 && r3.f == 1005) {
        Stdio.printf("T3 PASS\n");
    } else {
        Stdio.printf("T3 FAIL %u %u %u %u %u %u\n",
                     r3.a, r3.b, r3.c, r3.d, r3.e, r3.f);
    }
}
