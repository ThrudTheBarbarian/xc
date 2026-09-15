// arc_struct_walker.xc — ARC 2f struct aggregate walker.
//
// Structs containing strong class-pointer fields need field-wise
// release at scope exit and release-old on field reassignment. This
// fixture exercises both sites with a single stack struct local.
//
// Sequence:
//   1. Declare `Node n;` — strong-field bearing; walker zero-inits
//      the struct storage.
//   2. `n.payload = new Item();` — field reassignment #1, writes
//      into a null slot, no release.
//   3. `n.payload = new Item();` — field reassignment #2, releases
//      Item #1 (dealloc fires → count 1), writes Item #2.
//   4. Function returns — scope-exit walker releases n.payload
//      (dealloc fires → count 2).
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 itemDealloc;

class Item
{
    u8 tag;
    void dealloc(void)
    {
        itemDealloc = itemDealloc + 1;
    }
}

struct Node
{
    Item* payload;
    u8    tagCopy;
}

u16 midCount1;
u16 midCount2;
u16 midCount3;

void exerciseStructWalker(void)
{
    // Site 1: stack struct with strong field — walker zero-inits
    // the struct and registers it for scope-exit cleanup.
    Node n;
    n.tagCopy = 0;

    // Site 3a: first store — old slot is null, no release fires.
    n.payload = new Item();
    n.payload.tag = 11;
    n.tagCopy = n.payload.tag;
    midCount1 = itemDealloc;                 // expect 0

    // Site 3b: second store — old slot held Item #1, release runs
    // → Item #1.dealloc fires, then Item #2 lands.
    n.payload = new Item();
    n.payload.tag = 22;
    n.tagCopy = n.payload.tag;
    midCount2 = itemDealloc;                 // expect 1

    // Just before scope exit. Item #2 is alive; dealloc count still 1.
    midCount3 = itemDealloc;                 // expect 1
    // Scope-exit releases n.payload (Site 1 walker) → Item #2.dealloc.
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;
    midCount1 = $FF;
    midCount2 = $FF;
    midCount3 = $FF;

    exerciseStructWalker();

    Assert.isEqual(midCount1, 0);            // T1: first store, slot was null
    Assert.isEqual(midCount2, 1);            // T2: second store released #1
    Assert.isEqual(midCount3, 1);            // T3: no extra release mid-body
    Assert.isEqual(itemDealloc, 2);          // T4: scope-exit released #2

    Assert.summary();
    return;
}
