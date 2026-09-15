// arc_bound_method_across_call.xc — a `^` held across a call must survive it.
//
// This was bug 012 — an xt6502-only crash that took three trace passes to pin.
//
// `Array.mapped(&fn)` invokes the transform `^` once per element. On the 6502 a
// `^` is a by-value aggregate, and every aggregate parameter was pinned to a
// frame slot so `.field` access could resolve through an address — which made a
// bare read of the `^` lower to `AddrOf; Load`. The backend keys on that AddrOf
// to force the value into ZERO PAGE (address-taken values need a real 16-bit
// address, which the hidden SP stack can't give). And ZP is exactly what a
// callee reuses for its own locals — so the transform's deep allocating call
// chain overwrote the `^`'s receiver, and the NEXT element's dispatch jumped
// through a wrecked pointer into the heap and crashed.
//
// The fix reads the `^`'s SSA VALUE for the call instead of its address (the
// field values are all `AggExtract` needs), so no AddrOf is emitted, the `^`
// stays on the SP frame, and callees can't reach it.
//
// The reproducer needed a deep, allocating transform to surface the ZP reuse.
// This fixture keeps that shape but pins the CONTRACT rather than the crash:
// the transform is invoked once per element, each element's result is correct,
// and — the load-bearing part — the `^` is still intact for element N+1 after
// element N's transform ran a deep allocating chain.
//
//   T1  mapped over 2 elements, each transform allocates + early-return guards
//   T2  the same over MANY elements, so the `^` survives many deep calls
//   T3  a bound METHOD `^` (carries a receiver) across the same gauntlet
//   T4  the transform's own allocations are still reclaimed (no leak/early free)

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

// The transform from the original bug: split (allocates an Array + substrings),
// a count() early-return guard, then trimmed() (substring → withBytes → alloc).
Object* firstField(Object* o)
{
    String* s = (String* ?)o;
    if (s == 0) return (Object*)0;
    Array* parts = s.splitOnByte((u8)',');
    if (parts.count() < (u16)2) return (Object*)0;      // early return
    return ((String*)parts.get((u16)0)).trimmed();      // deep allocating chain
}

// A bound-method transform — the `^` carries `self`, so this also checks that
// the RECEIVER half of the `^` survives (the exact byte that got clobbered).
class Prefixer
{
    String* tag;
    void init(void) { tag = String.withCString("["); }
    Object* wrap(Object* o)
    {
        String* s = (String* ?)o;
        if (s == 0) return (Object*)0;
        Array* parts = s.splitOnByte((u8)',');
        if (parts.count() < (u16)1) return (Object*)0;   // early return
        String* out = String.withString(tag);           // uses self.tag
        out.append(((String*)parts.get((u16)0)).trimmed());
        return out;
    }
}

u16 gMade = (u16)0;
u16 gGone = (u16)0;
class Probe : Object
{
    u16 v;
    void init(void)    { gMade = gMade + (u16)1; }
    void dealloc(void) { gGone = gGone + (u16)1; }
}

Object* makeProbe(Object* o)
{
    Number* n = (Number* ?)o;
    Array* scratch = new Array();                        // allocate
    scratch.add(new Probe());                            // …a Probe held by scratch
    if (n == 0) return (Object*)0;                       // early return
    return new Probe();                                  // the returned one
}

void main(void)
{
    // ── T1: the exact bug shape — 2 elements, deep transform.
    Array* rows = new Array();
    rows.add(String.withCString("Alice, 30"));
    rows.add(String.withCString("Bob, 25"));
    Array* names = rows.mapped(&firstField);
    Assert.isEqual(names.count(), (u16)2);                            // T1a
    Assert.isTrue(((String*)names.get((u16)0)).equals(String.withCString("Alice")));  // T1b
    Assert.isTrue(((String*)names.get((u16)1)).equals(String.withCString("Bob")));    // T1c

    // ── T2: many elements, so the `^` runs the gauntlet repeatedly. If the `^`
    // were clobbered, this would crash somewhere in the middle rather than
    // completing.
    Array* many = new Array();
    for (u16 i = (u16)0; i < (u16)30; i++)
        many.add(String.withCString("item, tail"));
    Array* got = many.mapped(&firstField);
    Assert.isEqual(got.count(), (u16)30);                            // T2a
    Assert.isTrue(((String*)got.get((u16)0)).equals(String.withCString("item")));     // T2b
    Assert.isTrue(((String*)got.get((u16)29)).equals(String.withCString("item")));    // T2c — last survived

    // ── T3: a bound METHOD `^` — the receiver half must survive too.
    Prefixer* p = new Prefixer();
    Array* src = new Array();
    src.add(String.withCString("one, x"));
    src.add(String.withCString("two, y"));
    src.add(String.withCString("three, z"));
    Array* wrapped = src.mapped(&p.wrap);                            // &p.wrap = a bound ^
    Assert.isEqual(wrapped.count(), (u16)3);                         // T3a
    Assert.isTrue(((String*)wrapped.get((u16)0)).equals(String.withCString("[one")));  // T3b — self.tag intact
    Assert.isTrue(((String*)wrapped.get((u16)2)).equals(String.withCString("[three"))); // T3c — after many calls

    // ── T4: the transform's own allocations balance (no leak, no early free).
    Array* nums = new Array();
    for (u16 i = (u16)0; i < (u16)5; i++) nums.add(Number.with((i16)(i + (u16)1)));
    gMade = (u16)0; gGone = (u16)0;
    {
        Array* probes = nums.mapped(&makeProbe);
        Assert.isEqual(probes.count(), (u16)5);                     // T4a — 5 returned Probes
        // 5 returned + 5 scratch = 10 made; the 5 scratch freed with their
        // scratch Arrays inside the transform.
        Assert.isEqual(gMade, (u16)10);                             // T4b
        Assert.isEqual(gGone, (u16)5);                              // T4c — scratch reclaimed
    }
    // probes dropped → the 5 returned Probes freed.
    Assert.isEqual(gGone, (u16)10);                                 // T4d

    Assert.summary();
    return;
}
