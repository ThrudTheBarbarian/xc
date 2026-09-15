// weak_scope_exit.xc — weak local scope-exit unregisters without
// touching the referent's refcount.
//
// Validates that a `weak:T@` local going out of scope emits a
// _weak_unregister call and nothing else. No _obj_decref, no
// dealloc(), no _heap_free — the whole point of weak is that its
// lifecycle is invisible to the strong ARC machinery.
//
// The observable signal is dealloc count: if scope exit
// incorrectly decref'd through the weak slot, the referent's
// refcount would hit zero prematurely and dealloc would fire.
// We set up a strong-only chain where dropping the last strong
// reference is what MUST trigger dealloc; a weak temporarily
// attached inside a helper function must not bump the count.
//
// Test surface:
//   T1  After helper(s) returns with a weak local, the strong is
//       still alive and its dealloc count is unchanged.
//   T2  Freeing the strong globally triggers exactly one dealloc.

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;

class Tracker
{
    u8 tag;
    void dealloc(void) { deallocCount = deallocCount + 1; }
}

Tracker* gT;

void makeWeakLocalAndReturn(void)
{
    weak:Tracker* wLocal = gT;   // scope-local weak references gT
    // On return:
    //   1. wLocal goes out of scope → _weak_unregister.
    //   2. gT's refcount is UNCHANGED (weak doesn't retain/release).
    // If scope-exit accidentally decref'd through the weak slot,
    // gT's refcount would drop from 1 to 0 here and dealloc would
    // fire — the T1 assertion would catch that.
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;

    gT = new Tracker();              // gT: refcount 1
    gT.tag = (u8)99;

    u16 before = deallocCount;
    makeWeakLocalAndReturn();        // attach + release weak — no dealloc
    Assert.isEqual(deallocCount, before);   // T1: strong untouched

    gT = (Tracker*)0;                // release gT: refcount 0 → dealloc
    Assert.isEqual(deallocCount, before + 1);  // T2: exactly one dealloc

    Assert.summary();
    return;
}
