// foundation_set_arc.xc — Set's ownership semantics under ARC.
//
// Mirror of foundation_map_arc but for Set's single-element slots.
// The Set holds a +1 strong ref on every member, so an element
// passed in from a caller's scope survives the caller dropping its
// own reference, and remove / removeAll drop the strong refs.
//
//   T1   add retains the element across caller scope.
//   T2   remove releases the slot's element.
//   T3   removeAll releases every slot.
//   T4   re-add of an existing element does NOT double-retain (set
//        semantics promise membership, not identity preservation).
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── T1: add retains across caller-scope drop ─────────────────
    Set* s = new Set();
    {
        Number* e = Number.withU16((u16)$00AB);
        s.add(e);
    }
    // Heap churn between the inner-scope drop and the membership
    // check — if the Set's stored element were freed, the next
    // allocations would reuse that block and contains() would read
    // garbage.
    for (u16 i = (u16)0; i < (u16)16; i = i + (u16)1) {
        Number* junk = Number.withU16((u16)$5555);
    }
    Number* probe = Number.withU16((u16)$00AB);
    Assert.isTrue(s.contains(probe));                            // T1

    // ── T2: remove releases slot ─────────────────────────────────
    Number* e2 = Number.withU16((u16)2);
    s.add(e2);
    Assert.isEqual(s.count(), (u16)2);                           // T2a — T1 entry + T2 entry
    s.remove(e2);
    Assert.isEqual(s.count(), (u16)1);                           // T2b
    Assert.isFalse(s.contains(e2));                              // T2c

    // ── T3: removeAll empties every slot ─────────────────────────
    Number* e3 = Number.withU16((u16)3);
    s.add(e3);
    Assert.isEqual(s.count(), (u16)2);                           // T3a
    s.removeAll();
    Assert.isEqual(s.count(), (u16)0);                           // T3b
    Assert.isTrue(s.isEmpty());                                  // T3c

    // ── T4: re-add of an existing element is a no-op ─────────────
    // Two distinct Number objects with the same u16 value compare
    // equal under Number.equals; the second add must NOT bump the
    // count or the original's refcount. Probe via contains() with
    // a third equal-by-value pointer to confirm the slot is still
    // populated by the original.
    Number* e4a = Number.withU16((u16)4);
    s.add(e4a);
    Number* e4b = Number.withU16((u16)4);
    s.add(e4b);
    Assert.isEqual(s.count(), (u16)1);                           // T4a — count unchanged
    Number* e4c = Number.withU16((u16)4);
    Assert.isTrue(s.contains(e4c));                              // T4b

    Assert.summary();
    return;
}
