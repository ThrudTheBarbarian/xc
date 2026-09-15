// arc_banked_placement.xc — end-to-end banked:T@ placement on
// banked-heap targets. Exercises the four Bug-cluster fixes that
// make explicit 3-byte `banked:T@` slots correct:
//
//   • Bug 4d — aggregate walker reads each strong ivar's
//     per-instance bank from slot+2 (not #heap_bank_first) and
//     propagates it through _obj_decref / _arc_dealloc_tramp /
//     _heap_free.
//   • Bug 5 — scope-exit walker strides banked arrays by 3 bytes
//     (not 2) and reads each element's bank from slot+2.
//   • Bug 6 — ident-assign + subscript-assign handle 3-byte slots
//     (read old bank, decref with per-instance bank, write new
//     lo/hi/bank from allocator's A/X/Y).
//   • Bug 7b — method call on a banked receiver passes the
//     receiver's bank via the static __self_bank scratch; the
//     callee's self-retain / self-release uses it for Y=bank so
//     refcount touches land on the right block even when the
//     receiver lives in bank 2+.
//
// Coverage:
//   T1   Simple banked:T@ scope-exit releases the object.
//   T2-3 Aggregate walker cascade through a banked:T@ ivar fires
//        both the outer and inner dealloc.
//   T4   Banked array scope-exit releases every element.
//   T5   Ident-assign reassignment triggers release-old on the
//        banked slot.
//   T6   Method call on a banked receiver balances self-retain /
//        self-release (slot's +1 still owns the object after
//        return).
//
// Banked-heap targets only. Flat layouts treat `banked:` as a
// warning (Main placement) and the whole fixture is redundant
// with arc_scope_exit / arc_assign / arc_member_store coverage.

#import "Stdio.xc"
#import "Assert.xc"

u16 leafDealloc;
u16 holderDealloc;
u16 boxDealloc;

class Leaf
{
    u8 tag;
    void dealloc(void) { leafDealloc = leafDealloc + 1; }
}

class Holder
{
    banked:Leaf* leaf;
    void dealloc(void) { holderDealloc = holderDealloc + 1; }
}

class Box
{
    u8 id;
    void dealloc(void) { boxDealloc = boxDealloc + 1; }
    void doWork(void) { id = 99; }
    void helper(void) { id = 42; }
    // Nested method call on the SAME receiver — exercises the
    // __self_bank snapshot save/restore path across nesting.
    // helper's wrap overwrites __self_bank; nested's scope-exit
    // reads from its prologue snapshot.
    void nested(void) { helper(); }
}

void simpleScopeExit(void)
{
    banked:Leaf* l = new Leaf();
    return;  // scope-exit releases l
}

void aggregateCascade(void)
{
    banked:Holder* h = new Holder();
    h.leaf = new Leaf();
    return;  // scope-exit → Holder.dealloc, walker releases h.leaf
}

void bankedArray(void)
{
    banked:Leaf* arr[3];
    arr[0] = new Leaf();
    arr[1] = new Leaf();
    arr[2] = new Leaf();
    return;  // scope-exit walks all three
}

void identReassign(void)
{
    banked:Leaf* l = new Leaf();
    l = new Leaf();            // release-old fires
    return;                    // scope-exit releases the second
}

void bankedCallerMethodCall(void)
{
    // Banked-caller test: this helper is packed into a bank page,
    // so its inline method call has to route through the main-code
    // `_method_call_tramp` to avoid swapping the caller's own
    // code page out mid-bank-switch.
    banked:Box* b = new Box();
    b.doWork();
    return;
}

void main(void)
{
    Assert.reset();
    leafDealloc   = 0;
    holderDealloc = 0;
    boxDealloc    = 0;

    simpleScopeExit();
    Assert.isEqual(leafDealloc, 1);                        // T1

    leafDealloc = 0;
    aggregateCascade();
    Assert.isEqual(holderDealloc, 1);                      // T2
    Assert.isEqual(leafDealloc, 1);                        // T3

    leafDealloc = 0;
    bankedArray();
    Assert.isEqual(leafDealloc, 3);                        // T4

    leafDealloc = 0;
    identReassign();
    Assert.isEqual(leafDealloc, 2);                        // T5

    // T6: method call on a banked receiver, called from main (main
    // code region — no banked-caller trampoline needed on this
    // path).
    boxDealloc = 0;
    banked:Box* b = new Box();
    b.doWork();
    b = new Box();   // release-old: first Box's dealloc fires
    Assert.isEqual(boxDealloc, 1);                         // T6

    // T7: method call on a banked receiver, called from a BANKED
    // caller (helper function packed into a code bank). Exercises
    // `_method_call_tramp` — the caller's return address is popped
    // into a static, the bank switched, the method JSRed with args
    // at the same hw-stack depth a direct JSR would have produced,
    // then the caller-return pushed back before RTSing.
    boxDealloc = 0;
    bankedCallerMethodCall();
    Assert.isEqual(boxDealloc, 1);                         // T7

    // T8: nested banked-receiver method call. Outer.nested()'s
    // body calls helper() on the same banked receiver (itself a
    // banked method call). The nested wrap overwrites __self_bank
    // mid-execution — Outer.nested's scope-exit release must read
    // the prologue-snapshot bank (__self_bank_frame), not the
    // corrupted static. Same receiver means same bank here, so
    // the bug is only latent without the snapshot; the fixture
    // exercises the code path end-to-end.
    boxDealloc = 0;
    banked:Box* n = new Box();
    n.nested();
    n = new Box();   // reassign to release the first Box
    Assert.isEqual(boxDealloc, 1);                         // T8

    Assert.summary();
    return;
}
