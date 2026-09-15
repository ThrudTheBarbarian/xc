// arc_banked_new_bank.xc — preserve allocator's Y=bank when
// widening a Heap-placement RHS into a Banked-placement LHS.
//
// Context (Banked ARC Bug 2): `banked:Item@ p = new Item();` on
// xt-heap / xe-heap. The RHS `new Item()` resolves to Heap
// placement (2 bytes) per sema; the LHS is Banked (3 bytes).
// The widening helper fires (rhsWidth < lhsWidth) and needs to
// synthesise a bank byte in Y so the caller's STY writes the
// third byte. Before the fix the helper emitted `LDY #$00`
// unconditionally — clobbering the allocator's already-correct
// Y=bank and leaving the slot's bank byte as 0. Subsequent
// `p.field = val` via `_banked_store_byte` then targeted bank
// 0 and either crashed or corrupted main RAM.
//
// Fix: when the innermost RHS expression (after peeling cast
// wrappers) is an XTNewExprNode, skip the LDY — the allocator
// already left the correct bank in Y. For non-new RHS on
// banked targets, emit `LDY #heap_bank_first` (matching the
// Heap-placement implicit bank) instead of `LDY #$00`. The
// original `&fn` case still works because `heap_bank_first` is
// safely outside the PORTB window's routing — main-RAM casts
// were previously papering over the issue with bank 0 by
// coincidence.
//
// T1: allocator's bank preserved — p.field round-trips.
// T2: second allocation's bank also preserved (covers the case
//     where the allocator picks different banks for sequential
//     allocations under pressure).

#import "Stdio.xc"
#import "Assert.xc"

class Item
{
    u8 id;
    u8 value;
}

void main(void)
{
    Assert.reset();

    banked:Item* p = new Item();
    p.id = 42;
    p.value = 77;
    Assert.isEqual((u16)p.id, 42);                   // T1
    Assert.isEqual((u16)p.value, 77);                // T2

    banked:Item* q = new Item();
    q.id = 100;
    q.value = 200;
    Assert.isEqual((u16)q.id, 100);                  // T3
    Assert.isEqual((u16)q.value, 200);               // T4

    // p must still hold its original values — the second alloc
    // shouldn't have corrupted p's bank byte.
    Assert.isEqual((u16)p.id, 42);                   // T5
    Assert.isEqual((u16)p.value, 77);                // T6

    Assert.summary();
    return;
}
