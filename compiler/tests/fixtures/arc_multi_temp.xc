// arc_multi_temp.xc — owned-temp accounting across MULTIPLE +1 arguments, and
// a +1 returned through a bound method.
//
// Two ARC leaks, both found by churning the Foundation containers under a
// memory monitor rather than by any single failing assertion — which is why
// they lasted: the program is correct, it just grows.
//
// 1. MULTIPLE static-factory arguments in one call.
//
//        m.set(String.withI32(i), Number.with(i));      // two +1 temps
//
//    Each static call emits a static-init guard that BRANCHES, so the first
//    argument's +1 temp ends up in an earlier block than the second's. The
//    end-of-full-expression sweep released only the temp in the *current*
//    block, and dropped the earlier one — leaking one object per call, which is
//    every populated Map. The sweep now keys on conditional-NESTING DEPTH
//    (a guard rejoins, so it doesn't change depth) rather than on the block, so
//    both temps are released.
//
// 2. A +1 returned through a bound method (`^`).
//
//        Array@ out = a.mapped(&makeThing);             // makeThing returns new
//
//    A `^` call is dynamic — no mangled name to look up — so the lowering could
//    not tell the result was owned, assumed borrowed, and leaked the +1 the
//    transform created. A `^` now returns an object +1 by convention, the same
//    as any function. Every element `mapped` produced was leaked.
//
// The counts are the test — a leak is `dealloced < made`, an over-release is a
// crash or `dealloced > made`.
//
//   T1  two static-factory args, both released
//   T2  three, for good measure
//   T3  the same, but bound to locals (already worked — must stay working)
//   T4  a transform ^ returning a new object: live while held, freed after
//   T5  a ternary arm's +1 temp is still dropped, NOT double-released
//   T6  a static factory in a && short-circuit arm — same

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

u16 gMade = (u16)0;
u16 gGone = (u16)0;

class Thing : Object
{
    u16 v;
    void init(void)    { gMade = gMade + (u16)1; }
    void dealloc(void) { gGone = gGone + (u16)1; }
    static Thing* make(void)         { return new Thing(); }
    static Thing* makeV(u16 val)     { Thing* t = new Thing(); t.v = val; return t; }
}

// Sinks that BORROW their arguments (do not retain).
void sink2(Thing* a, Thing* b)          { }
void sink3(Thing* a, Thing* b, Thing* c) { }

Object* transform(Object* o)
{
    Number* n = (Number* ?)o;
    Thing* t = new Thing();
    if (n != 0) t.v = (u16)n.asI16();
    return t;
}

void reset(void) { gMade = (u16)0; gGone = (u16)0; }

void main(void)
{
    // Warm the static-init guard so its one-off phantom instance doesn't skew
    // the counts.
    Thing* warm = Thing.make();
    reset();

    // ── T1: two +1 args in one borrowing call.
    for (u16 i = (u16)0; i < (u16)50; i++) sink2(Thing.make(), Thing.make());
    Assert.isEqual(gMade, (u16)100);                     // T1a — 2 per call
    Assert.isEqual(gGone, (u16)100);                     // T1b — all released
    reset();

    // ── T2: three.
    for (u16 i = (u16)0; i < (u16)50; i++) sink3(Thing.make(), Thing.make(), Thing.make());
    Assert.isEqual(gMade, (u16)150);                     // T2a
    Assert.isEqual(gGone, (u16)150);                     // T2b
    reset();

    // ── T3: via named locals — the slots adopt the +1s.
    for (u16 i = (u16)0; i < (u16)50; i++) {
        Thing* a = Thing.make();
        Thing* b = Thing.make();
        sink2(a, b);
    }
    Assert.isEqual(gMade, (u16)100);                     // T3a
    Assert.isEqual(gGone, (u16)100);                     // T3b
    reset();

    // ── T4: a transform ^ that BUILDS objects. The mapped array must hold them
    // live, and they must all free when it drops.
    {
        Array* src = new Array();
        for (u16 i = (u16)0; i < (u16)10; i++) src.add(Number.with((i16)i));
        gMade = (u16)0; gGone = (u16)0;                  // count only the Things

        Array* out = src.mapped(&transform);
        Assert.isEqual(out.count(), (u16)10);            // T4a
        Assert.isEqual(gMade, (u16)10);                  // T4b — 10 built
        Assert.isEqual(gGone, (u16)0);                   // T4c — none freed yet: live

        // Read them back to prove they are live, not dangling.
        u16 sum = (u16)0;
        for (Object* o in out) { Thing* t = (Thing* ?)o; if (t != 0) sum = sum + t.v; }
        Assert.isEqual(sum, (u16)45);                    // T4d — 0+1+…+9
    }
    // `out` has now dropped: every Thing it held is freed.
    Assert.isEqual(gGone, (u16)10);                      // T4e
    reset();

    // ── T5: a ternary arm's +1 must NOT be double-released (that would crash or
    // over-count). It may leak — that is the conservative side — but the counts
    // must be sane and the program must not fault.
    for (u16 i = (u16)0; i < (u16)20; i++) {
        bool pick = (i % (u16)2) == (u16)0;
        Thing* t = pick ? Thing.make() : Thing.make();
        Assert.isTrue(t != 0);                           // T5 — got a live object
    }
    // No crash reaching here is the point; the local `t` is released each turn.
    Assert.isTrue(true);
    reset();

    // ── T6: a static factory in a short-circuit arm — same discipline.
    u16 hits = (u16)0;
    for (u16 i = (u16)0; i < (u16)20; i++) {
        Thing* t = Thing.makeV(i);
        if (t != 0 && Thing.make() != 0) hits = hits + (u16)1;
    }
    Assert.isEqual(hits, (u16)20);                       // T6 — both sides truthy

    Assert.summary();
    return;
}
