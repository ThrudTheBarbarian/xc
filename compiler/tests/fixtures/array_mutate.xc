// array_mutate.xc — the NSMutableArray insert/remove/replace surface.
//
// self-hosting M2. M1 (private:docs/Design/m1-foundation-surface.md) found Array
// covering 13 of the 30 methods the compiler uses; the missing ten are all
// insert/remove/replace over the existing growable buffer. NSMutableArray is
// 1,625 call sites, third behind the two string classes.
//
// Every case here also checks OWNERSHIP, because that is what an Array does
// that a plain list does not: a slot that goes away is released, a slot that
// arrives is retained. Probe counts its live instances in a static, so a leak
// or an over-release shows up as a number rather than as a crash days later.
//
//   T1  insertAll — including into itself
//   T2  remove (identity) / removeEqual (value)
//   T3  removeRange — clamped length, past the end
//   T4  replaceRange — shorter, longer, and from itself
//   T5  setTo, replaceAt, adding
//   T6  isEqualToArray — pairwise by value, with `equals` left as identity
//   T7  Array.with(…) for one to four elements
//   T8  ownership: every removal releases, every insertion retains

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

// A counted element: live instances are tracked in a GLOBAL, so the fixture can
// assert that removals actually released.
//
// The counter is a global rather than a `static u16` ivar on Probe on purpose:
// a class that mixes a static ivar with instance methods does not work today —
// the instance method's reference to the static name binds to instance storage
// instead, so the count never moves and the instance ivars after it read wrong.
// Not this task's bug; avoided rather than depended on.
u16 gProbeLive;

class Probe <Comparable>
{
    u16 tag;

    void init(void)
    {
        tag = (u16)0;
        gProbeLive = gProbeLive + (u16)1;
    }

    void dealloc(void)
    {
        gProbeLive = gProbeLive - (u16)1;
    }

    static Probe* with(u16 t)
    {
        Probe* p = new Probe();
        p.tag = t;
        return p;
    }

    u16 value(void) { return tag; }

    bool equals(Object* other)
    {
        Probe* o = (Probe* ?)other;
        if (o == 0) return false;
        return o.value() == tag;
    }
}

// Tags of `a`, as a comma-joined String, so a whole array is one assertion.
String* tags(Array* a)
{
    String* out = String.withCString("");
    for (u16 i = (u16)0; i < (u16)a.count(); i = i + (u16)1) {
        if (i > (u16)0) out.appendByte((u8)',');
        Probe* p = (Probe* ?)a.get(i);
        out.append(String.withU16((p == 0) ? (u16)999 : p.value()));
    }
    return out;
}

bool tagsAre(Array* a, string want)
{
    return tags(a).equals(String.withCString(want));
}

Array* build(u16 n)
{
    Array* a = new Array();
    for (u16 i = (u16)0; i < n; i = i + (u16)1) a.add(Probe.with(i));
    return a;
}

void t1_t2(void)
{
    // ── T1: insertAll.
    Array* a = build((u16)3);                        // 0,1,2
    Array* b = new Array();
    b.add(Probe.with((u16)7));
    b.add(Probe.with((u16)8));

    a.insertAll((u16)1, b);
    Assert.isTrue(tagsAre(a, "0,7,8,1,2"));                          // T1a
    Assert.isEqual((u16)a.count(), (u16)5);

    a.insertAll((u16)a.count(), b);                  // at the end == append
    Assert.isTrue(tagsAre(a, "0,7,8,1,2,7,8"));                      // T1b
    a.insertAll((u16)999, b);                        // past the end clamps
    Assert.isTrue(tagsAre(a, "0,7,8,1,2,7,8,7,8"));                  // T1c

    // Into ITSELF — reads slots the insertion is busy shifting unless the
    // source is snapshotted first.
    Array* s = build((u16)3);                        // 0,1,2
    s.insertAll((u16)1, s);
    Assert.isTrue(tagsAre(s, "0,0,1,2,1,2"));                        // T1d

    // ── T2: remove by identity vs by value.
    Array* r = new Array();
    Probe* p1 = Probe.with((u16)1);
    r.add(Probe.with((u16)0));
    r.add(p1);
    r.add(Probe.with((u16)1));                       // EQUAL to p1, not identical

    Assert.isTrue(r.remove(p1));                                     // T2a
    Assert.isTrue(tagsAre(r, "0,1"));
    Assert.isFalse(r.remove(p1));                                    // T2b — gone
    // removeEqual finds the survivor by value.
    Assert.isTrue(r.removeEqual((Comparable*)Probe.with((u16)1)));   // T2c
    Assert.isTrue(tagsAre(r, "0"));
    Assert.isFalse(r.removeEqual((Comparable*)Probe.with((u16)42))); // T2d
}

void t3_t4(void)
{
    // ── T3: removeRange.
    Array* a = build((u16)6);                        // 0..5
    a.removeRange((u16)1, (u16)2);
    Assert.isTrue(tagsAre(a, "0,3,4,5"));                            // T3a
    a.removeRange((u16)2, (u16)999);                 // length clamps
    Assert.isTrue(tagsAre(a, "0,3"));                                // T3b
    a.removeRange((u16)9, (u16)1);                   // start past the end
    Assert.isTrue(tagsAre(a, "0,3"));                                // T3c
    a.removeRange((u16)0, (u16)0);                   // empty range
    Assert.isTrue(tagsAre(a, "0,3"));                                // T3d

    // ── T4: replaceRange, both length relationships.
    Array* b = build((u16)4);                        // 0,1,2,3
    Array* two = new Array();
    two.add(Probe.with((u16)8));
    two.add(Probe.with((u16)9));

    b.replaceRange((u16)1, (u16)1, two);             // longer
    Assert.isTrue(tagsAre(b, "0,8,9,2,3"));                          // T4a

    b.replaceRange((u16)1, (u16)3, Array.with((Object*)Probe.with((u16)5)));  // shorter
    Assert.isTrue(tagsAre(b, "0,5,3"));                              // T4b

    // A null replacement is a plain removal.
    b.replaceRange((u16)0, (u16)1, (Array*)0);
    Assert.isTrue(tagsAre(b, "5,3"));                                // T4c

    // From ITSELF: the removal must not delete what is about to be inserted.
    Array* s = build((u16)3);                        // 0,1,2
    s.replaceRange((u16)0, (u16)1, s);
    Assert.isTrue(tagsAre(s, "0,1,2,1,2"));                          // T4d
}

void t5_t6_t7(void)
{
    // ── T5: setTo / replaceAt / adding.
    Array* a = build((u16)3);
    Array* b = build((u16)2);                        // 0,1
    a.setTo(b);
    Assert.isTrue(tagsAre(a, "0,1"));                                // T5a
    a.setTo(a);                                      // self is a no-op
    Assert.isTrue(tagsAre(a, "0,1"));                                // T5b

    a.replaceAt((u16)0, Probe.with((u16)6));
    Assert.isTrue(tagsAre(a, "6,1"));                                // T5c

    Array* more = a.adding(Probe.with((u16)7));
    Assert.isTrue(tagsAre(more, "6,1,7"));                           // T5d
    Assert.isTrue(tagsAre(a, "6,1"));                                // T5e — untouched

    // ── T6: isEqualToArray is pairwise BY VALUE…
    Array* x = build((u16)3);
    Array* y = build((u16)3);
    Assert.isTrue(x.isEqualToArray(y));                              // T6a — distinct instances
    Assert.isTrue(x.isEqualToArray(x));                              // T6b
    y.add(Probe.with((u16)9));
    Assert.isFalse(x.isEqualToArray(y));                             // T6c — count differs
    Array* z = build((u16)3);
    z.replaceAt((u16)1, Probe.with((u16)99));
    Assert.isFalse(x.isEqualToArray(z));                             // T6d — element differs
    Assert.isFalse(x.isEqualToArray((Array*)0));                     // T6e

    // …and `equals` is still IDENTITY, so an Array is still its own Map key.
    // It is also why the value comparison has its own name: a typed
    // `equals(Array@)` overload loses to the inherited `equals(Object@)` at the
    // call site, and would answer "same pointer?" to a question about contents.
    Assert.isFalse(x.equals(y));                                     // T6f
    Assert.isTrue(x.equals(x));                                      // T6g

    // ── T7: the small fixed-count builders.
    Probe* p0 = Probe.with((u16)0);
    Probe* p1 = Probe.with((u16)1);
    Probe* p2 = Probe.with((u16)2);
    Probe* p3 = Probe.with((u16)3);
    Assert.isTrue(tagsAre(Array.with((Object*)p0), "0"));                              // T7a
    Assert.isTrue(tagsAre(Array.with((Object*)p0, (Object*)p1), "0,1"));               // T7b
    Assert.isTrue(tagsAre(Array.with((Object*)p0, (Object*)p1, (Object*)p2), "0,1,2"));// T7c
    Assert.isTrue(tagsAre(Array.with((Object*)p0, (Object*)p1, (Object*)p2, (Object*)p3),
                          "0,1,2,3"));                                                 // T7d
}

void t8(void)
{
    // ── T8: ownership. Every element removed must be released, and every
    // element inserted retained — a leak and an over-release both show up here
    // as a count, rather than as a crash somewhere else entirely.
    u16 base = gProbeLive;

    Array* a = build((u16)5);
    u16 n = gProbeLive - base;
    Assert.isEqual(n, (u16)5);                                       // T8a

    a.removeRange((u16)0, (u16)2);
    n = gProbeLive - base;
    Assert.isEqual(n, (u16)3);                                       // T8b — released

    a.removeAll();
    n = gProbeLive - base;
    Assert.isEqual(n, (u16)0);                                       // T8c

    // An element inserted into two Arrays outlives the first one emptying.
    Probe* shared = Probe.with((u16)1);
    Array* x = new Array();
    Array* y = new Array();
    x.add(shared);
    y.add(shared);
    n = gProbeLive - base;
    Assert.isEqual(n, (u16)1);                                       // T8d
    x.removeAll();
    n = gProbeLive - base;
    Assert.isEqual(n, (u16)1);                                       // T8e — y still holds it
    Assert.isTrue(tagsAre(y, "1"));                                  // T8f — and it is readable
}

void main(void)
{
    gProbeLive = (u16)0;
    t1_t2();
    t3_t4();
    t5_t6_t7();
    t8();
    Assert.summary();
    return;
}
