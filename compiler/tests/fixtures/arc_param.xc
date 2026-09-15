// arc_param.xc — validate ARC 2d callee-retains parameter convention.
//
// Under -farc (default on) every strong class-pointer parameter is
// retained on function entry (callee-retains) and released at scope
// exit via the 2a cleanup machinery. The caller holds a +1 in its
// own slot for the duration of the call, so the callee sees a +0
// borrow; the prologue retain turns that into +1 for the duration
// of the body so storing the param into a durable slot (global,
// assignment to outer state) is safe.
//
// Test surface:
//   T1-T2  Plain borrow — callee uses the param, doesn't store it.
//          Retain + release net to zero; the caller's ownership is
//          untouched and the object stays alive after the call.
//   T3-T4  Borrow with aliasing: two params pointing at the same
//          object each get their own retain; refcount = 3 inside
//          the body (caller's 1 + two callee retains); both release
//          on exit; object back to 1.
//   T5-T6  Callee stores param into a global: prologue retain owns
//          +1 for the global's future, scope-exit release drops the
//          callee's local +1, net +1 survives in the global slot.
//          When the global is later reassigned, that +1 gets released.
//   T7-T8  Method params: same retain-on-entry behaviour for methods.

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

class Holder
{
    Tracker* stashed;
    void keep(Tracker* t)
    {
        stashed = t;
    }
}

u16 deallocCount;
Tracker* gStash;

// T1-T2 helper: callee just reads the param.
void justBorrow(Tracker* t)
{
    // Prologue retains t → refcount +1.
    // Body: read t.tag (no effect on refcount).
    u8 unused = t.tag;
    // Scope-exit releases t → refcount -1. Net: 0.
}

// T3-T4 helper: two params aliased.
void twoBorrows(Tracker* a, Tracker* b)
{
    // Prologue retains a → +1; retains b → +1. Net +2.
    u8 ta = a.tag;
    u8 tb = b.tag;
    // Scope-exit releases both. Net 0.
}

// T5-T6 helper: store param into a global.
void stashIntoGlobal(Tracker* t)
{
    // Prologue: t refcount +1.
    gStash = t;   // assignment lowering: release old gStash, retain t (+1 more),
                  // store. Net for t: +1 (from prologue) + +1 (from assign retain).
                  // Scope-exit releases t → -1. Net +1 in gStash.
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;
    gStash = (Tracker*)0;

    // ── T1-T2: plain borrow keeps caller's object alive ──
    Tracker* obj1 = new Tracker();
    obj1.tag = 1;
    u16 before = deallocCount;
    justBorrow(obj1);
    Assert.isEqual(deallocCount, before);           // object still alive
    Assert.isEqual(obj1.tag, 1);                    // readable

    // ── T3-T4: same object aliased through two params ──
    Tracker* obj2 = new Tracker();
    obj2.tag = 2;
    before = deallocCount;
    twoBorrows(obj2, obj2);                         // same pointer twice
    Assert.isEqual(deallocCount, before);           // still alive (caller owns)
    Assert.isEqual(obj2.tag, 2);

    // ── T5-T6: stash into global ──
    Tracker* obj3 = new Tracker();
    obj3.tag = 99;
    before = deallocCount;
    stashIntoGlobal(obj3);                          // gStash now also holds obj3
    Assert.isEqual(deallocCount, before);           // nothing freed
    Assert.isEqual(gStash.tag, 99);                 // visible through global

    // Confirm gStash keeps obj3 alive even after caller's obj3 slot
    // is reassigned: we release obj3 (via reassign), but gStash still
    // owns a +1, so the object stays live.
    obj3 = new Tracker();
    obj3.tag = 5;                                    // obj3 now references a different Tracker
    Assert.isEqual(gStash.tag, 99);                 // old obj3 still reachable via gStash

    // Cleanup the global so it doesn't leak across the summary.
    gStash = (Tracker*)0;                           // release-assign: old value freed

    Assert.summary();
    return;
}
