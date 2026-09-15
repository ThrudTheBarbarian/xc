// indirect_callee_shapes.xc — a call's callee may be an EXPRESSION, not only
// a bare identifier (private:docs/bugs/074).
//
// Storing a callback in an array, a struct field or another object's ivar
// always worked; CALLING it from there did not, and each shape failed with a
// different message naming something the user never wrote — `<indirect>`,
// "method call on non-class receiver", "No method 'onChange' on class 'V'".
// The workaround was to copy to a local first, which also meant the natural
// spelling of a dispatch table could not be written at all.
//
// `block` had the same hole, for the same reason, so both are pinned here: it
// is ONE call-site rule, and fixing it for one type while leaving the other
// would have left a gap nothing was watching.
//
//   T1  callee is a SUBSCRIPT           tbl[i](x)
//   T2  callee is a CALL RESULT         pick(o)(x)
//   T3  callee is another object's IVAR w.onChange(x)
//   T4  callee is a STRUCT FIELD        s.fn(x)
//   T5  callee is a block-typed IVAR    h.cb(x)   — `.invoke` dispatch
//   T6  an ARRAY of callbacks in the NEW spelling, called through the
//       subscript. The name-second header had no declarator slot, so this
//       could only be written with the `^` sigil — the transitional form
//       expressing something its replacement could not.
//   T7  the same for `block`, because the two headers are one grammar.
#import "Stdio.xc"
#import "Foundation.xc"

typedef i32 op_t(i32);

struct Slot { op_t^ fn; i32 tag; }

class Ops
{
    i32 base;
    void init(void)  { base = (i32)100; }
    i32 inc(i32 n)   { return n + (i32)1; }
    i32 dec(i32 n)   { return n - (i32)1; }
    i32 add(i32 n)   { return base + n; }
}

class Model
{
    i32 v;
    void init(void)   { v = (i32)0; }
    void set(i32 n)   { v = n; }
}

class View
{
    callback onChange void(i32 n);
    void init(void) { }
}

class Holder
{
    block cb u32(u32 n);
    void init(void) { }
}

callback op i32(i32 n) pick(Ops* o, bool up)
{
    if (up) { return &o.inc; }
    return &o.dec;
}

i32 main(void)
{
    Ops* o = new Ops();

    // T1: a dispatch table, called through the subscript.
    op_t^ tbl[2];
    tbl[0] = &o.inc;
    tbl[1] = &o.dec;
    Stdio.printf("T1 %d %d\n", tbl[0]((i32)5), tbl[1]((i32)5));

    // T2: the callee is what a call returned.
    Stdio.printf("T2 %d %d\n", pick(o, true)((i32)9), pick(o, false)((i32)9));

    // T3: the callee is an ivar of another object, reached from outside it.
    Model* m = new Model();
    View*  w = new View();
    w.onChange = &m.set;
    w.onChange((i32)42);
    Stdio.printf("T3 %d\n", m.v);

    // T4: the callee is a struct field.
    Slot s;
    s.fn  = &o.add;
    s.tag = (i32)1;
    Stdio.printf("T4 %d\n", s.fn((i32)7));

    // T5: the callee is a BLOCK-typed ivar — a block call is `.invoke`
    // dispatch, which the parser only ever rewrote for a block LOCAL.
    Holder* h = new Holder();
    h.cb = block u32(u32 n) { return n + (u32)3; };
    Stdio.printf("T5 %ld\n", h.cb((u32)39));

    // T6: an array of callbacks, declared in the new spelling.
    callback tbl2[2] i32(i32 n);
    tbl2[0] = &o.inc;
    tbl2[1] = &o.add;
    Stdio.printf("T6 %d %d\n", tbl2[0]((i32)5), tbl2[1]((i32)5));

    // T7: an array of blocks.
    block bt[2] u32(u32 n);
    bt[0] = block u32(u32 n) { return n + (u32)1; };
    bt[1] = block u32(u32 n) { return n * (u32)2; };
    Stdio.printf("T7 %ld %ld\n", bt[0]((u32)10), bt[1]((u32)10));
    return 0;
}
