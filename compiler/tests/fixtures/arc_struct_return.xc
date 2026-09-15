// arc_struct_return.xc — ARC retain/release on struct-return paths.
//
// When a function returns a struct with strong class-pointer fields,
// the callee's local gets released at scope exit — which would free
// the very blocks the caller is about to receive. The fix: the
// callee retains each strong field after copying the return bytes
// into the register window (small) or via __retbuf (large), so the
// local's scope-exit release nets to +1 per field for the caller.
// Symmetric caller-side fix: reassignment `dst = f();` releases
// dst's old strong fields before the call's result overwrites them.
//
// Test surface:
//   T1  decl-init: `Holder x = makeHolder();` — Item#1 survives
//       callee return. No dealloc fires at the call boundary.
//   T2  reassignment: `x = makeHolder();` — the old x.payload
//       (Item#1) is released exactly once; Item#2 is live.
//   T3  function scope exit: x.payload (Item#2) is released,
//       taking deallocCount to 2 total across the run.
//
// Both a small-struct variant (≤ 8 bytes, $B0..$B7 register-window
// path) and a large-struct variant (> 8 bytes, __retbuf path) are
// exercised.
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 itemDealloc;

class Item
{
    u8 id;
    void dealloc(void)
    {
        itemDealloc = itemDealloc + 1;
    }
}

// Small (3 bytes) — fits in $B0..$B7 register window.
struct Small
{
    Item* payload;
    u8    flags;
}

// Large (~12 bytes) — triggers __retbuf lowering.
struct Large
{
    Item* payload;
    u16   a; u16 b; u16 c; u16 d;
    u16   e;
}

Small makeSmall(u8 id)
{
    Small h;
    h.payload = new Item();
    h.payload.id = id;
    h.flags = 7;
    return h;
}

Large makeLarge(u8 id)
{
    Large h;
    h.payload = new Item();
    h.payload.id = id;
    h.a = 1; h.b = 2; h.c = 3; h.d = 4; h.e = 5;
    return h;
}

u16 exerciseSmall(void)
{
    Small x = makeSmall(1);             // decl-init, Item#1 alive
    u16 mid1 = itemDealloc;             // expect 0

    x = makeSmall(2);                   // reassign: release Item#1, recv Item#2
    u16 mid2 = itemDealloc;             // expect 1
    return mid1 * 100 + mid2;
    // scope exit releases x.payload (Item#2) → dealloc 2
}

u16 exerciseLarge(void)
{
    Large x = makeLarge(1);
    u16 mid1 = itemDealloc;

    x = makeLarge(2);
    u16 mid2 = itemDealloc;
    return mid1 * 100 + mid2;
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;

    u16 smallMid = exerciseSmall();
    Assert.isEqual(smallMid, 1);                  // T1: mid1=0, mid2=1
    Assert.isEqual(itemDealloc, 2);               // T2: Item#2 released at scope exit

    itemDealloc = 0;
    u16 largeMid = exerciseLarge();
    Assert.isEqual(largeMid, 1);                  // T3: same pattern for large
    Assert.isEqual(itemDealloc, 2);               // T4

    Assert.summary();
    return;
}
