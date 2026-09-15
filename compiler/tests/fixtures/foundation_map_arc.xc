// foundation_map_arc.xc — Map's ownership semantics under ARC.
//
// Mirror of foundation_array_arc but for Map's (key, value)
// pairs. The Map holds +1 strong refs on both, so a key/value
// passed in from a caller's scope survives the caller dropping
// its own reference, and remove / removeAll drop the strong
// refs.
//
//   T1   set retains both key and value across caller scope.
//   T2   remove releases the slot's key+value.
//   T3   removeAll releases every slot.
//   T4   set on an existing key releases the prior value before
//        retaining the replacement.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── T1: set retains across caller-scope drop ─────────────────
    Map* m = new Map();
    // Inline `_stash` block — keys / values created in an inner
    // scope, dropped at scope exit. If set didn't retain, the
    // Number blocks would be freed before the lookup below and
    // the heap churn that follows would overwrite them.
    {
        Number* k = Number.withU16((u16)$00AB);
        Number* v = Number.withU16((u16)$1234);
        m.set(k, v);
    }
    // Heap churn between the helper return and the lookup — if the
    // Map's stored key/value were freed, the next allocations would
    // reuse those blocks and the lookup would read garbage.
    for (u16 i = (u16)0; i < (u16)16; i = i + (u16)1) {
        Number* junk = Number.withU16((u16)$5555);
    }
    Number* kProbe = Number.withU16((u16)$00AB);
    Object* got = m.get(kProbe);
    Assert.isTrue(got != (Object*)0);                            // T1a
    Number* gotN = (Number* ?)got;
    Assert.isEqual(gotN.asU16(), (u16)$1234);                    // T1b

    // ── T2: remove releases slot ─────────────────────────────────
    Number* k2 = Number.withU16((u16)2);
    Number* v2 = Number.withU16((u16)$22);
    m.set(k2, v2);
    Assert.isEqual(m.count(), (u16)2);                           // T2a — T1 entry + T2 entry
    m.remove(k2);
    Assert.isEqual(m.count(), (u16)1);                           // T2b
    Object* removed = m.get(k2);
    Assert.isTrue(removed == (Object*)0);                        // T2c

    // ── T3: removeAll empties every slot ─────────────────────────
    Number* k3 = Number.withU16((u16)3);
    Number* v3 = Number.withU16((u16)$33);
    m.set(k3, v3);
    Assert.isEqual(m.count(), (u16)2);                           // T3a
    m.removeAll();
    Assert.isEqual(m.count(), (u16)0);                           // T3b
    Assert.isTrue(m.isEmpty());                                  // T3c

    // ── T4: overwrite drops the prior value ──────────────────────
    Number* k4 = Number.withU16((u16)4);
    Number* v4a = Number.withU16((u16)$44);
    m.set(k4, v4a);
    Number* v4b = Number.withU16((u16)$45);
    m.set(k4, v4b);
    Assert.isEqual(m.count(), (u16)1);                           // T4a — overwrite, count unchanged
    Number* readBack = (Number* ?)m.get(k4);
    Assert.isEqual(readBack.asU16(), (u16)$45);                  // T4b — new value visible

    Assert.summary();
    return;
}
