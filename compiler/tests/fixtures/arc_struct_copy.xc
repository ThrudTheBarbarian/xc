// arc_struct_copy.xc — ARC retain/release on struct copy-assignment.
//
// A struct-copy `dst = src;` where the struct type contains strong
// class-pointer fields used to produce an unsafe alias: both locals
// point at the same heap blocks, both scope-exits decref, double
// free. This fix retains each source field's pointer and releases
// each destination field's old pointer before the byte-copy, so
// the invariant holds: every heap block's refcount matches the
// number of strong references aimed at it.
//
// Test surface:
//   T1  dst = src bumps deallocCount via the old-dst release
//       (dst.payload was null, so no dealloc fires yet — count=0)
//       but the shared Item now has refcount 2.
//   T2  After dst's field is overwritten (second copy), dst's old
//       payload (shared with src) is released → refcount 2 → 1,
//       no dealloc yet.
//   T3  At function scope exit both dst and src release their
//       payloads. dst.payload (points at Item #2) refcount 2 → 1
//       (src still holds), then src.payload refcount 1 → 0,
//       dealloc fires. Final count = 1 (one Item freed).
//   T4  Self-assign (`src = src;`) is a no-op at the refcount
//       level (retain + release cancel), then byte-copy onto itself.
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

struct Holder
{
    Item* payload;
    u8    flags;
}

u8 exerciseStructCopy(void)
{
    Holder src;
    Holder dst;

    src.payload = new Item();
    src.payload.id = 11;
    src.flags = 1;

    // First copy: dst.payload was null, so release-old is a no-op.
    // Retain bumps Item #1's refcount to 2. After the copy:
    //   src.payload == dst.payload == Item#1, refcount 2.
    dst = src;
    u16 mid1 = itemDealloc;        // expect 0 — nothing freed yet

    // Overwrite dst.payload with a new Item. Release-old fires on
    // the shared Item#1 (refcount 2 → 1). Then dst.payload points
    // at Item#2 (refcount 1), src still holds Item#1.
    dst.payload = new Item();
    dst.payload.id = 22;
    u16 mid2 = itemDealloc;        // expect 0 — Item#1 still held by src

    // Self-assign: retain + release cancel on each field; net
    // refcount unchanged. No dealloc fires.
    src = src;
    u16 mid3 = itemDealloc;        // expect 0

    // Function scope exit: dst's walker releases Item#2 (refcount
    // 1 → 0, Item#2.dealloc fires). src's walker releases Item#1
    // (refcount 1 → 0, Item#1.dealloc fires). Total deallocs = 2.
    return (u8)(mid1 + mid2 + mid3);
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;

    u8 mid = exerciseStructCopy();

    Assert.isEqual(mid, 0);                          // T1+T2+T3 mid-body
    Assert.isEqual(itemDealloc, 2);                  // T4 both items freed at scope exit

    Assert.summary();
    return;
}
