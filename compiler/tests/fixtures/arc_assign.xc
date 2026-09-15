// arc_assign.xc — validate ARC 2b assignment lowering.
//
// Under -farc (default on) assignment to a strong class-pointer
// identifier should:
//   • release the old slot value,
//   • retain the new value if the RHS is a borrowed reference
//     (identifier / field / subscript / deref),
//   • skip the retain if the RHS is value-producing (new, call).
//
// Companion fixture to arc_scope_exit.xc — scope-exit cleanup
// machinery (2a + 2c) is reused for the release-old step here.
//
// Test surface:
//   T1-T2  Reassign strong local to `new T()` releases old value,
//          takes over the allocator's +1 (no retain, no leak).
//   T3-T4  Reassign strong local to another identifier (borrowed
//          reference): retain bumps the shared object; both slots
//          stay alive; releasing one alone doesn't free the object.
//   T5-T6  Reassign strong local to null: old value released,
//          slot holds null, scope-exit's null-release is a no-op.
//   T7-T8  Decl with borrowed-reference initialiser (`Foo@ a = b;`):
//          both slots alive after decl; scope-exit releases both
//          correctly.
//   T9     Reassigning a strong global (ZP-resident) behaves like
//          a strong local.

#import "Stdio.xc"
#import "Assert.xc"

class Tracker
{
    u8 tag;
    void dealloc(void)
    {
        deallocCount = deallocCount + 1;
    }
}

u16 deallocCount;

// T9 global (declared before main for ZP priority).
Tracker* gSlot;

void twoLocalsAliased(void)
{
    Tracker* a = new Tracker();  a.tag = 1;     // A live, refcount 1
    Tracker* b = a;                             // b aliases A, refcount 2
    // On scope exit, b releases first (LIFO) → refcount 1,
    // then a releases → refcount 0, dealloc fires, free.
}

void assignToIdent(void)
{
    Tracker* a = new Tracker();  a.tag = 10;    // A live, refcount 1
    Tracker* b = new Tracker();  b.tag = 20;    // B live, refcount 1
    a = b;                                      // reassign: release A,
                                                // retain B → B refcount 2
                                                // A: refcount 0 → dealloc
    // Cleanup order: b (last decl) first. b refcount 2→1 (B still alive
    // in a). a next: refcount 1→0 → B dealloc.
    // Total dealloc events for this function: 2 (A once, B once).
}

void assignToNew(void)
{
    Tracker* a = new Tracker();  a.tag = 30;    // A live, refcount 1
    a = new Tracker();                          // release A → dealloc.
                                                // Take over new +1 → B live.
    // Cleanup: a refcount 1→0, dealloc B. Total: 2 dealloc events.
}

void assignToNull(void)
{
    Tracker* a = new Tracker();  a.tag = 40;    // A live, refcount 1
    a = (Tracker*)0;                            // release A → dealloc. a=null.
    // Cleanup: a=null, skip. Total: 1 dealloc event.
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;

    // ── T1-T2: decl, reassign to new, scope-exit ──
    assignToNew();
    Assert.isEqual(deallocCount, 2);              // old A + scope-exit B
    // By now slots for A and B have both been dealloc'd (in order).

    // ── T3-T4: aliased decl (`Foo@ b = a;`) — retain, release both
    //          at scope exit; only one free event (shared object).
    twoLocalsAliased();
    Assert.isEqual(deallocCount, 3);              // shared object freed once

    // ── T5-T6: reassign to another identifier ──
    assignToIdent();
    Assert.isEqual(deallocCount, 5);              // A freed, then B freed

    // ── T7-T8: reassign to null ──
    assignToNull();
    Assert.isEqual(deallocCount, 6);              // A freed, null slot at exit

    // ── T9: global reassignment ──
    gSlot = new Tracker();    // global decl was never initialised at
                              // compile time, but gSlot is zero-init
                              // as a global so release-of-null is a no-op.
    gSlot.tag = 77;
    gSlot = new Tracker();    // release old gSlot, take new.
    Assert.isEqual(deallocCount, 7);              // old gSlot freed.
    // We don't cleanup globals at scope exit (they outlive main).

    Assert.summary();
    return;
}
