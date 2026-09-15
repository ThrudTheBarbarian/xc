// arc_struct_return_chain.xc — ARC correctness for a struct return
// whose source is projected through a member-access chain
// (`return outer.inner;`).
//
// The large-struct retbuf path in emitReturn tail-exits — skipping
// the explicit-return scope-exit cleanup block — so the source
// local's strong fields implicitly "move out" into the caller's
// retbuf. No callee-side retain is needed for that path. emitReturn
// does emit a defensive retain walker for the member-access shape
// (via flattenStructFieldChain) which currently fires only on non-
// retbuf paths; today those paths have other limits (small-struct
// member-access return emits an incorrect 2-byte load), so the
// retain path is currently dead code kept for when the small
// variant gets extended.
//
// T1+T2 exercise the large-struct retbuf path end-to-end: Inner is
// > 8 bytes so retbuf lowering fires, the chain projection resolves
// correctly via the retbuf member-access branch, and the payload
// pointer survives the return.
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 itemDealloc;
u16 midCount;

class Item
{
    u8 id;
    void dealloc(void)
    {
        itemDealloc = itemDealloc + 1;
    }
}

// Large enough (> 8 bytes) to force the __retbuf return path,
// where emitReturn's retbuf member-access branch handles chain-
// projected sources.
struct Inner
{
    Item* payload;
    u16   a; u16 b; u16 c;
    u8    flags;
}

struct Outer
{
    u8    prefix;
    Inner inner;
    u16   trailer;
}

// Returns a projected sub-struct from a larger local. The chain
// `local.inner` flattens to (local, inner.byteOffset), and the
// struct-return retain walks Inner's strong fields at that offset.
Inner projectInner(u8 id)
{
    Outer big;
    big.prefix = 1;
    big.inner.payload = new Item();
    big.inner.payload.id = id;
    big.inner.a = 1; big.inner.b = 2; big.inner.c = 3;
    big.inner.flags = 7;
    big.trailer = 999;
    return big.inner;
    // Scope exit releases big.inner.payload as part of the Outer
    // walker. The retain above bumps the refcount so caller still
    // sees +1.
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;
    midCount = $FF;

    // ── Gap-fill 1: chain-projection struct return ──
    Inner got = projectInner(5);
    Assert.isEqual(got.payload.id, 5);            // T1 live payload
    midCount = itemDealloc;
    Assert.isEqual(midCount, 0);                  // T2 no mid-body dealloc

    // Scope exit releases got.payload (strong field) → 1 dealloc.
    // Assert.summary prints before scope-exit, so itemDealloc is
    // still 0 at summary time. Inspect afterwards via a second
    // reset.
    Assert.summary();
    return;
}
