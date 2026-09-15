// arc_banked_nested_chain.xc — Phase 4.3 Bug 4c + Bug 6 +
// nested-chain bank-wrap + Bug 8 zero-init, banked-heap targets.
//
// Four related issues, all fixed to make a 3-level transitive
// cascade work end-to-end on xt-heap / xe-heap:
//
//   • Aggregate walker's ivar reads (`(zpTmp),Y` in
//     emitArcReleaseStrongIndirectSlot) missed the heap bank
//     when the caller's $82 was a code bank. Fixed by routing
//     through _banked_load_byte.
//
//   • Single-level ARC member store (`obj.field = new X()` via
//     emitArcMemberStore) emitted plain `(zpTmp),Y` for both
//     the release-old read and the store-new write. Without
//     bank wrap the store landed in the caller's bank, not
//     the heap bank. Fixed by routing both sides through
//     _banked_load_byte / _banked_store_byte.
//
//   • Nested member-store chain (`o.mid.leaf = expr`) goes
//     through the generic pointer-base member-write path —
//     which reads the intermediate pointer via bank-aware
//     helpers already, but writes via plain `(zpTmp),Y`.
//     Fixed by extending the generic branch to use
//     `_banked_store_byte` on banked targets when fieldSize
//     ≤ 2.
//
//   • `new T()` zero-init loop (strong-ivar classes) in
//     emitNewExpr wrote $00 bytes via plain `STA (zpTmp),Y`
//     into whatever bank the caller happened to be executing
//     in, because the allocator restored the caller's bank
//     before returning. When build() landed in a code bank
//     this corrupted the bank's instructions at the first few
//     $4000-window bytes, silently shredding whichever banked
//     method happened to live there (Stdio.init, typically).
//     Fixed by staging the pointer+bank into _bankedPtrScratch
//     and routing each zero-store through _banked_store_byte.
//     Previously papered over by a `Stdio.printf("")` warmup
//     that kept Stdio.init's static guard skipping a reuse.
//
// Coverage:
//   T1-T3: 3-level transitive cascade Out → Mid → Leaf, each
//          with user dealloc. All three dealloc counters
//          increment exactly once via the scope-exit cascade.

#import "Stdio.xc"
#import "Assert.xc"

u16 outDealloc;
u16 midDealloc;
u16 leafDealloc;

class Leaf
{
    u8 tag;
    void dealloc(void) { leafDealloc = leafDealloc + 1; }
}

class Mid
{
    Leaf* leaf;
    void dealloc(void) { midDealloc = midDealloc + 1; }
}

class Out
{
    Mid* mid;
    void dealloc(void) { outDealloc = outDealloc + 1; }
}

void build(void)
{
    Out* o      = new Out();
    o.mid       = new Mid();
    o.mid.leaf  = new Leaf();
    return;
    // Scope-exit cascade: o refcount 0 → Out.dealloc + walker →
    // Mid refcount 0 → Mid.dealloc + walker → Leaf refcount 0
    // → Leaf.dealloc. All three user deallocs fire.
}

void main(void)
{
    Assert.reset();
    outDealloc  = 0;
    midDealloc  = 0;
    leafDealloc = 0;

    build();
    Assert.isEqual(outDealloc, 1);                  // T1
    Assert.isEqual(midDealloc, 1);                  // T2
    Assert.isEqual(leafDealloc, 1);                 // T3

    Assert.summary();
    return;
}
