// foundation_map_insertion_order.xc — Map and Set enumerate in INSERTION order,
// and that order is stable across runs.
//
// Why this is a fixture and not a nicety: slot order is hash order, and the
// default Object.hash is derived from the object's ADDRESS (Object.xc), so a
// container keyed by user objects used to enumerate in heap-layout order — a
// different order on every run. Anything ordered that way reaching a compiler's
// emitted output makes a 3-stage bootstrap's stage2 and stage3 differ
// intermittently, which is a miserable class of bug to chase.
// See private:docs/Design/self-hosting.md §5.
//
// The four cases below are exactly the ones a naive implementation gets wrong:
//   1. plain insertion order
//   2. order preserved across a RESIZE (slot indices all change)
//   3. order preserved across a REMOVE (the gap must close)
//   4. TOMBSTONE REUSE — remove then insert a different key. _findSlot hands the
//      tombstoned slot to the next insert, so a stale order entry would alias a
//      different key and the element would be yielded twice.
//   5. user-object keys (address hash) — the determinism case itself

#import "Stdio.xc"
#import "Map.xc"
#import "Set.xc"
#import "String.xc"
#import "Number.xc"

// No hash override, so this inherits Object's address-derived hash.
class Key <Hashable, Comparable>
{
    u32 id;
    void init(u32 v) { id = v; }
    u32 ident(void)  { return id; }
}

void main(void)
{
    // 1. Plain insertion order — deliberately NOT alphabetical or sorted.
    Map* m = new Map();
    m.set(String.withCString("delta"),   Number.with((u32)4));
    m.set(String.withCString("alpha"),   Number.with((u32)1));
    m.set(String.withCString("charlie"), Number.with((u32)3));
    m.set(String.withCString("bravo"),   Number.with((u32)2));
    Array* ks = m.allKeys();
    Stdio.printf("order:");
    for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
        Stdio.printf(" %s", ((String*)ks.get(i)).cString());
    Stdio.printf("\n");

    // 3. Remove closes the gap; the survivors keep their order.
    m.remove(String.withCString("charlie"));
    Array* ks2 = m.allKeys();
    Stdio.printf("after-remove:");
    for (u32 i = (u32)0; i < ks2.count(); i = i + (u32)1)
        Stdio.printf(" %s", ((String*)ks2.get(i)).cString());
    Stdio.printf("\n");

    // 2. Resize: 40 entries drives several doublings from the initial 16.
    Map* big = new Map();
    for (u32 i = (u32)0; i < (u32)40; i = i + (u32)1)
        big.set(Number.with(i), Number.with(i * (u32)10));
    Array* bk = big.allKeys();
    bool ordered = true;
    for (u32 i = (u32)0; i < bk.count(); i = i + (u32)1)
        if (((Number*)bk.get(i)).asU32() != i) ordered = false;
    Stdio.printf("resize-order=%d count=%d\n", ordered, big.count());

    // 4. Tombstone reuse — a stale order entry would show key 3 twice.
    Map* t = new Map();
    t.set(Number.with((u32)1), Number.with((u32)100));
    t.set(Number.with((u32)2), Number.with((u32)200));
    t.remove(Number.with((u32)1));
    t.set(Number.with((u32)3), Number.with((u32)300));
    Array* tk = t.allKeys();
    Stdio.printf("reuse:");
    for (u32 i = (u32)0; i < tk.count(); i = i + (u32)1)
        Stdio.printf(" %d", ((Number*)tk.get(i)).asU32());
    Stdio.printf(" count=%d\n", t.count());

    // 5. Address-hashed user keys — the determinism case.
    Map* u = new Map();
    for (u32 i = (u32)0; i < (u32)12; i = i + (u32)1)
        u.set(new Key(i), Number.with(i));
    Array* uk = u.allKeys();
    Stdio.printf("user-keys:");
    for (u32 i = (u32)0; i < uk.count(); i = i + (u32)1)
        Stdio.printf(" %d", ((Key*)uk.get(i)).ident());
    Stdio.printf("\n");

    // Set takes the same treatment; insert descending so sorted != insertion.
    Set* s = new Set();
    for (u32 i = (u32)0; i < (u32)40; i = i + (u32)1)
        s.add(Number.with((u32)39 - i));
    Array* so = s.allObjects();
    bool sOrdered = true;
    for (u32 i = (u32)0; i < so.count(); i = i + (u32)1)
        if (((Number*)so.get(i)).asU32() != (u32)39 - i) sOrdered = false;
    Stdio.printf("set-order=%d count=%d\n", sOrdered, s.count());
}
