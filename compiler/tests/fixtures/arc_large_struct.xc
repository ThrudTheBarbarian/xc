// arc_large_struct.xc — ARC correctness for strong-field structs
// that don't fit in ZP.
//
// Before this landing, emitLocalVarDecl's heap-bump path would
// allocate a ZP pointer for any `struct BigThing big;` local whose
// size exceeded ZP residency. Field accesses like `big.payload =
// new Item();` then wrote the pointer into `big`'s ZP pointer slot,
// corrupting `big` itself and dropping every field operation on
// the floor. Strong fields inside a heap-bump struct leaked
// unconditionally — the scope-exit walker couldn't find them.
//
// The fix: when a struct type has strong class-pointer fields,
// emitLocalVarDecl skips the heap-bump path. Large strong-field
// structs fall through to the data-section spill path instead,
// where the ARC machinery (arcMaybeTrackLocal, struct-copy,
// scope-exit walker, struct-return release-old) already works
// against absolute spill-label addresses.
//
// Test surface:
//   T1  A 30-byte struct with a strong field round-trips a
//       field assignment + readback.
//   T2  dst = src correctly aliases the strong field (refcount
//       rises to 2, not two separate allocations).
//   T3  Scope exit releases both structs' references, freeing
//       the shared Item exactly once.
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

// Large enough to force spill when two instances are declared in the
// same function alongside a few u8 locals. Item@ is 2 bytes, padding
// pushes total size to ~32 bytes.
struct BigHolder
{
    Item* payload;
    u8    pad[30];
}

void exerciseLargeStruct(void)
{
    BigHolder src;
    BigHolder dst;

    src.payload = new Item();
    src.payload.id = 77;

    // dst = src aliases the strong field. Retain bumps refcount to
    // 2; release old dst.payload (null) is a no-op.
    dst = src;

    // Verify the alias round-trips the payload pointer correctly:
    // dst.payload should name the same Item, id = 77.
    Assert.isTrue(dst.payload.id == 77);          // T1

    // Mid-body sanity: no deallocs have fired yet (refcount is 2).
    midCount = itemDealloc;                        // expect 0

    // Scope exit: dst releases first (refcount 2 → 1, no dealloc),
    // src releases (refcount 1 → 0, dealloc fires once).
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;
    midCount    = $FF;

    exerciseLargeStruct();

    Assert.isEqual(midCount, 0);                   // T2 no mid-body release
    Assert.isEqual(itemDealloc, 1);                // T3 one dealloc at scope exit

    Assert.summary();
    return;
}
