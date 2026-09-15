// arc_ivar_store.xc — ARC assignment lowering for ivar stores
// inside method bodies.
//
// Under -farc, `field = expr;` inside a method (where `field` is
// a strong-class-pointer ivar of the enclosing class, addressed
// via the implicit __self pointer) should emit the same release-
// old / retain-if-borrowed / store sequence as a top-level member
// store. Before this landing, ivar stores bypassed the ARC
// interceptor (the ivar's encoded address has bit 15 set, which
// the old ZP-local-only check filtered out) so old values leaked.
//
// Test surface:
//   T1-T2  `field = new Inner()` inside a method stores a fresh +1
//          into the ivar slot; subsequent calls replace cleanly
//          (old value released, new +1 transferred).
//   T3     `field = other` with `other` a strong param retains the
//          param so the ivar owns its own +1.
//   T4     `field = null` releases the prior value and nulls out.
//   T5     Container's destruction releases the ivar transitively
//          (shared with the arc_member_store fixture — sanity
//          check that method-body ivar stores and out-of-method
//          aggregate walkers agree on the semantics).

#import "Stdio.xc"
#import "Assert.xc"

class Inner
{
    u8 mark;
    void dealloc(void)
    {
        innerDeallocs = innerDeallocs + 1;
    }
}

class Box
{
    Inner* held;

    // Method body ivar stores — these are the 2b follow-up the
    // fixture exercises.
    void put(Inner* newInner)
    {
        held = newInner;
    }

    void putFresh(void)
    {
        held = new Inner();
    }

    void clear(void)
    {
        held = (Inner*)0;
    }
}

u16 innerDeallocs;

void main(void)
{
    Assert.reset();
    innerDeallocs = 0;

    // ── T1: two putFresh() calls — first stores Inner#1 (old null,
    //        no release), second stores Inner#2 after releasing #1.
    Box* b = new Box();
    b.putFresh();                        // held <- Inner#1 (old null, no release)
    b.putFresh();                        // held <- Inner#2 (release Inner#1)
    Assert.isEqual(innerDeallocs, 1);

    // ── T2: put() with a parameter that'll be released at method
    //        exit — the ivar store retains so the ivar owns its
    //        own +1. Prior held value (Inner#2) released here.
    Inner* keeper = new Inner();
    b.put(keeper);                       // held <- keeper (release Inner#2, retain keeper)
    Assert.isEqual(innerDeallocs, 2);

    // ── T3: keeper is still alive — the Box and the caller both
    //        own +1.
    keeper.mark = 99;                    // writable through the caller's ref
    Assert.isEqual(keeper.mark, 99);

    // ── T4: clear() nulls out — previous held value (keeper)
    //        decrements to 1 (caller still owns).
    b.clear();
    Assert.isEqual(innerDeallocs, 2);    // keeper still alive via caller

    // ── T5: Box going out of scope releases whatever it holds.
    //        After clear() held is null, so b's cleanup has
    //        nothing to do for held. Only keeper's caller-side
    //        release at main()'s scope exit frees it.
    Assert.summary();
    return;
}
