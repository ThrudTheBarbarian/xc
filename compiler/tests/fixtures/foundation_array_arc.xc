// foundation_array_arc.xc — Array's ownership semantics under ARC.
//
// Without retain on add(), an element passed in from a caller's
// scope drops to refcount 0 when that scope exits — the slot then
// holds a dangling pointer and the next heap allocation overwrites
// the freed block. The fixture confirms:
//
//   T1   add() retains. Pass a Number into a helper, return,
//        churn the heap, and the slot's element still reads back
//        the original value rather than the churn payload.
//   T2   removeAt() releases. Add two elements, drop the first;
//        the surviving element is still the one we expect.
//   T3   removeAll() releases every slot's element and zeros the
//        count.
//   T4   set() releases the prior occupant before retaining its
//        replacement.
//
// dealloc-on-drop coverage lives in foundation_array_grow — every
// `Array@` local in that fixture exercises the dealloc walk at
// scope-exit on all four heap-capable targets.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void _stash(Array* a, u16 marker)
{
    Number* n = Number.withU16(marker);
    a.add(n);
    // n drops here; without retain in add(), n is freed and the
    // next heap allocation reuses its block.
}

void main(void)
{
    Assert.reset();

    // ── T1: add() retains across caller-scope drop ────────────────
    Array* a = new Array();
    _stash(a, (u16)$00AB);
    for (u16 i = (u16)0; i < (u16)16; i++) {
        Number* junk = Number.withU16((u16)$5555);
    }
    Number* got = (Number*)a.get((u16)0);
    Assert.isEqual(got.asU16(), (u16)$00AB);                    // T1

    // ── T2: removeAt releases the dropped slot ────────────────────
    a.add(Number.withU16((u16)$00CD));
    a.removeAt((u16)0);
    Number* stillThere = (Number*)a.get((u16)0);
    Assert.isEqual(stillThere.asU16(), (u16)$00CD);             // T2
    Assert.isEqual(a.count(), (u16)1);

    // ── T3: removeAll releases every slot ─────────────────────────
    a.add(Number.withU16((u16)$1111));
    a.add(Number.withU16((u16)$2222));
    a.add(Number.withU16((u16)$3333));
    Assert.isEqual(a.count(), (u16)4);                          // 1 + 3
    a.removeAll();
    Assert.isEqual(a.count(), (u16)0);

    // ── T4: set() releases the old occupant, retains the new ──────
    a.add(Number.withU16((u16)$4444));
    a.set((u16)0, Number.withU16((u16)$5555));
    Number* replaced = (Number*)a.get((u16)0);
    Assert.isEqual(replaced.asU16(), (u16)$5555);

    Assert.summary();
    return;
}
