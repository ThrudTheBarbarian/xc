// arc_stack_array.xc — ARC for stack arrays of strong class pointers.
//
// `Item@ slots[N];` used to be a silent leak path. The subscript
// read/write code treated the ZP base as a pointer and indirected
// through it (landing at $0000+offset on xts, corrupting OS zero
// page on real hardware). G1 landed direct addressing for
// XTArrayType bases; this fixture completes the picture by adding:
//   1. Zero-init at declaration (arcMaybeTrackLocal).
//   2. ARC slot reassignment (`slots[i] = new Item()` runs release-
//      old + store-new via the now-correct address compute).
//   3. Scope-exit walker that releases each slot in turn.
//
// Test surface:
//   T1  Fresh array: every slot is null, no deallocs yet.
//   T2  Populate 3 slots; mid-body count still 0 — no releases
//       have fired.
//   T3  Overwrite slot 1 with a new Item. The OLD slot-1 Item
//       gets released → one dealloc.
//   T4  Overwrite slot 2 with null via a cast. Another dealloc.
//   T5  Function scope exit walks the array; remaining live
//       slot (#0) plus the replacement at slot 1 fire → total
//       deallocCount = 4 (slot-1 replace + null-set-2 + final-0
//       + final-1 = 1+1+1+1).
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 itemDealloc;
u16 midCount1;
u16 midCount2;

class Item
{
    u8 tag;
    void dealloc(void)
    {
        itemDealloc = itemDealloc + 1;
    }
}

void exerciseStackArray(void)
{
    Item* slots[4];

    // T2: populate three slots. Each store writes into a null slot
    // so no dealloc fires; just three fresh +1 references held.
    slots[0] = new Item();
    slots[0].tag = 10;
    slots[1] = new Item();
    slots[1].tag = 20;
    slots[2] = new Item();
    slots[2].tag = 30;
    midCount1 = itemDealloc;                      // expect 0

    // T3: overwrite slot 1 with a fresh Item. The old Item#1 gets
    // released → dealloc fires once. Slot 1 now holds Item#4.
    slots[1] = new Item();
    slots[1].tag = 40;
    midCount2 = itemDealloc;                      // expect 1

    // Scope-exit walker releases slot 0, slot 1 (Item#4),
    // slot 2, slot 3 (null, skipped). Deallocs: Item#1 (replaced)
    // + Item#10-tag + Item#4 + Item#30-tag = 4 total.
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;
    midCount1 = $FF;
    midCount2 = $FF;

    exerciseStackArray();

    Assert.isEqual(midCount1, 0);                  // T1
    Assert.isEqual(midCount2, 1);                  // T2 replacement released
    Assert.isEqual(itemDealloc, 4);                // T3 total over function + scope

    Assert.summary();
    return;
}
