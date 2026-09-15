// arc_weak_into_strong.xc — reading a WEAK reference into a STRONG slot.
//
// `T@ v = h.owner;` where `owner` is `weak:T@` emitted no retain and then
// released `v` at scope exit — a net -1 on every call. An object with one real
// owner therefore died on the FIRST read, while its owner was still holding it
// and still using it.
//
// The retain was skipped because the guard asked whether the SOURCE type was a
// class pointer, and that predicate answers NO for a weak pointer — correctly,
// because a weak SLOT is not ARC-tracked storage. But a weak VALUE bound into a
// strong destination is the other question, and the answer is the one ObjC ARC
// gives: the destination takes ownership, so it retains. Getting it backwards
// is a use-after-free rather than a leak.
//
// Found in the Rocks/XG framework: the AppKit tree-draw
// path reads `sv.document().owner` — a weak back-pointer from a view to the
// tree that owns it — and freed the window's entire view tree during the first
// draw, then walked it. Guard Malloc showed the block unmapped; an extra strong
// reference did not help, because the release was unbalanced rather than
// merely early.
//
//   T1  the object survives a weak read into a strong local
//   T2  ...and repeated reads (the count must not drift down)
//   T3  a weak read into a strong IVAR
//   T4  a weak read into a strong GLOBAL
//   T5  everything still dies exactly once when the owner drops

#import "Stdio.xc"
#import "Assert.xc"

u16 gLive;
Leaf* gSlot;                       // T4: a strong global

class Leaf
{
    u16 tag;
    void init(void)    { tag = (u16)0; gLive = gLive + (u16)1; }
    void dealloc(void) { gLive = gLive - (u16)1; }
    u16 value(void)    { return tag; }
}

class Back
{
    weak:Leaf* owner;              // the owner holds us, so this is weak
    void init(void) { owner = (Leaf*)0; }
    void point(Leaf* l) { owner = l; }
}

class Holder
{
    Back* back;                    // strong
    Leaf* leaf;                    // strong — the only real owner of the leaf
    Leaf* cached;                  // T3: a strong ivar written from a weak read
    void init(void)
    {
        back = new Back();
        leaf = new Leaf();
        leaf.tag = (u16)7;
        back.point(leaf);
        cached = (Leaf*)0;
    }
    Back* backing(void) { return back; }
    void cacheFromWeak(void) { cached = back.owner; }      // T3
    u16 cachedValue(void)    { return cached.value(); }
}

// The shape from the report: a weak field reached through a returned object,
// bound to a strong local, used, and dropped.
u16 readThroughWeak(Holder* h)
{
    Leaf* v = h.backing().owner;
    return v.value();
}

void main(void)
{
    Holder* h = new Holder();
    u16 base = gLive;

    Assert.isEqual(readThroughWeak(h), (u16)7);    // T1
    Assert.isEqual(gLive, base);                    // …and it is still alive

    for (u16 i = (u16)0; i < (u16)20; i = i + (u16)1) {
        Assert.isEqual(readThroughWeak(h), (u16)7); // T2 — no drift over repeats
    }
    Assert.isEqual(gLive, base);

    h.cacheFromWeak();                              // T3 — into a strong ivar
    Assert.isEqual(h.cachedValue(), (u16)7);
    Assert.isEqual(gLive, base);

    gSlot = h.backing().owner;                      // T4 — into a strong global
    Assert.isEqual(gSlot.value(), (u16)7);
    Assert.isEqual(gLive, base);

    gSlot = (Leaf*)0;
    Assert.summary();                               // T5: the owner still holds it
}
