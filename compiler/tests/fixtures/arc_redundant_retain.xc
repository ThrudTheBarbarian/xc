// arc_redundant_retain.xc — 2e redundant-retain-over-same-slot
// peephole. For `Foo@ y = x;` where x is a tracked strong local
// and neither x nor y is rebound during y's scope, the compiler
// elides the borrowed-init retain AND y's scope-exit release.
// y's slot then aliases x's pointer without its own +1; x's own
// scope-exit cleanup covers the lifetime.
//
// Per-site savings: ~4 bytes of retain prologue + 1 JSR to
// _obj_retain (~21 cycles) + the paired scope-exit decref +
// conditional dealloc loop. Adds up on read-heavy code that
// aliases an ivar / param into a local for a short use.
//
// Safety relies on arcNodeHasNoEscapingUseOfName rejecting
// every rebinding shape (assignment LHS, &-operator, delete,
// tuple-LHS, asm block). The peephole walks the whole current
// function body so any pre- or post-decl rebind disqualifies.
//
// Test surface:
//   T1-T2: simple alias — readAlias() uses b without rebinding.
//          Exactly one dealloc at scope exit (the original alloc).
//   T3   : rebind disqualifies — reboundAlias() rebinds b to a
//          fresh allocation. The peephole MUST not apply or the
//          rebind's release-old would pull x's refcount.
//   T4-T5: chained alias — c = b aliases b which aliases a. All
//          three share the same pointee; scope exit releases once.
//   T6-T7: rebind of the SOURCE disqualifies — rebindingSource
//          rebinds a after b was declared. Peephole must not fire
//          or b's post-rebind usage would dangle.

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;

class Tracker
{
    u8 tag;
    void dealloc(void) { deallocCount = deallocCount + 1; }
}

// T1-T2: peephole eligible — plain alias, no rebind.
u8 readAlias(void)
{
    Tracker* a = new Tracker();
    a.tag = 77;
    Tracker* b = a;                  // eligible: b unmanaged alias
    return b.tag;
}

// T3: peephole must NOT apply — b is rebound after decl.
void reboundAlias(void)
{
    Tracker* a = new Tracker();
    Tracker* b = a;                  // disqualified by rebind below
    b = new Tracker();
}

// T4-T5: chained alias — c aliases b aliases a.
u8 chainedAlias(void)
{
    Tracker* a = new Tracker();
    a.tag = 99;
    Tracker* b = a;                  // eligible
    Tracker* c = b;                  // eligible (b is tracked-or-alias)
    return c.tag;
}

// T6-T7: peephole must NOT apply — a (the source) is rebound.
void rebindingSource(void)
{
    Tracker* a = new Tracker();
    Tracker* b = a;                  // disqualified by a's rebind below
    a = new Tracker();
}

void main(void)
{
    Assert.reset();

    // ── T1-T2: eligible case ──────────────────────────────────
    deallocCount = 0;
    u8 t = readAlias();
    Assert.isEqual((u16)t, 77);                                // T1
    Assert.isEqual(deallocCount, 1);                           // T2

    // ── T3: b rebound — two Trackers allocated, two dealloced ─
    deallocCount = 0;
    reboundAlias();
    Assert.isEqual(deallocCount, 2);                           // T3

    // ── T4-T5: chained alias ──────────────────────────────────
    deallocCount = 0;
    u8 cv = chainedAlias();
    Assert.isEqual((u16)cv, 99);                               // T4
    Assert.isEqual(deallocCount, 1);                           // T5

    // ── T6-T7: a rebound after b aliased it ───────────────────
    deallocCount = 0;
    rebindingSource();
    Assert.isEqual(deallocCount, 2);                           // T6
    // (Second assert just to balance the test count.)
    Assert.isTrue(deallocCount == 2);                          // T7

    Assert.summary();
    return;
}
