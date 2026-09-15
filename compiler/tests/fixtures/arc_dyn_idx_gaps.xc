// arc_dyn_idx_gaps.xc — two dynamic-index gaps closed.
//
// Before this landing the codegen had two deferred holes where a
// non-constant subscript on a stack array of strong-bearing
// structs silently leaked or hard-errored:
//
//   1. `arr[i].field = new X()` — the existing ARC member-store
//      dispatch for subscript bases required a constant index so
//      the element's absolute address was known at compile time.
//      Dynamic index fell through to the generic subscript-member-
//      write path, which stored the new value correctly but
//      skipped the release-old step for the field. Old strong
//      reference leaked silently; the new value was still picked
//      up by the array's scope-exit walker, so crashes were rare
//      but memory accumulated.
//
//   2. `arr[i] = f()` where `f` returns a small struct (≤ 8 B)
//      and `i` is dynamic. The codegen emitted a diagnostic and
//      bailed. The problem was that emitSubscriptAddrToZp runs
//      u16Mul for dynamic indices, clobbering $B0..$B3 — which
//      holds the small-struct register-result return slot. Both
//      the ARC strong-bearing case (release-old + call + byte
//      copy) and the plain small-struct case (call + byte copy)
//      needed to survive that clobber.
//
// Fix 1: emitAssignExpr's subscript-base ARC branch learned a
// dynamic-index path that calls a new
// `emitArcSubscriptMemberStoreIndirect` helper. The helper
// evaluates the RHS first (staging to _arc_retval_*), retains if
// borrowed, computes the element pointer into zpTmp via
// emitSubscriptAddrToZp, stashes it to _arc_tx_ptr_* (the
// existing scratch the release helper reloads zpTmp from between
// its JSRs), calls emitArcReleaseStrongIndirectSlot at the field
// offset, then reloads zpTmp and stores through (zpTmp),Y.
//
// Fix 2: `arr[i] = f()` small-struct path stages $B0..$B(W-1)
// onto the hw stack (PHA per byte) before running
// emitSubscriptAddrToZp, then pops them back in reverse order
// into (zpTmp),Y. `width` is ≤ 8 so the hw-stack cost is
// bounded. Constant-index path is unchanged — it doesn't go
// through u16Mul.
//
// Flat-heap only (xl-shadow, xe-nobank). Banked targets remain
// Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 itemDealloc;

class Item
{
    u8 id;
    void dealloc(void) { itemDealloc = itemDealloc + 1; }
}

struct Holder
{
    Item* payload;
    u16   mark;
}

Holder makeHolder(u8 id)
{
    Holder h;
    h.payload = new Item();
    h.payload.id = id;
    h.mark = 777;
    return h;
}

struct Small
{
    u16 id;
    u8  tag;
}  // 3 bytes — fits in $B0..$B2

Small makeSmall(u8 tag)
{
    Small s;
    s.id = 1000;
    s.tag = tag;
    return s;
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;

    // ── Fix 1: arr[i].field = new X() ─────────────────────────
    Holder harr[3];
    harr[0].payload = new Item();                         // const — primes
    harr[1].payload = new Item();
    harr[2].payload = new Item();
    Assert.isEqual(itemDealloc, 0);                       // T1

    // Dynamic-index overwrites each slot; release-old must fire.
    u16 i;
    i = 1;
    harr[i].payload = new Item();
    Assert.isEqual(itemDealloc, 1);                       // T2

    i = 0;
    harr[i].payload = new Item();
    Assert.isEqual(itemDealloc, 2);                       // T3

    // Dynamic-index into a null slot shouldn't trip the null-
    // check (no extra dealloc).
    Holder harr2[3];
    u16 j;
    j = 2;
    harr2[j].payload = new Item();
    Assert.isEqual(itemDealloc, 2);                       // T4

    // ── Fix 2: arr[i] = f() with small-struct return ─────────
    Small sarr[4];
    u16 k;
    k = 0;
    sarr[k] = makeSmall(11);
    k = 1;
    sarr[k] = makeSmall(22);
    k = 2;
    sarr[k] = makeSmall(33);
    k = 3;
    sarr[k] = makeSmall(44);

    Small s;
    s = sarr[0];
    Assert.isEqual(s.id, 1000);                           // T5
    Assert.isEqual((u16)s.tag, 11);                       // T6
    s = sarr[2];
    Assert.isEqual((u16)s.tag, 33);                       // T7
    s = sarr[3];
    Assert.isEqual((u16)s.tag, 44);                       // T8

    // ── Fix 2 + ARC: arr[i] = f() where f returns a strong-
    //    bearing small struct. Release-old is already handled by
    //    the existing indirect-release path; the hw-stack stage
    //    is the new piece that lets the subsequent byte-copy
    //    survive u16Mul.
    Holder sharr[3];
    u16 m;
    m = 0;
    sharr[m] = makeHolder(1);                             // slot null
    Assert.isEqual(itemDealloc, 2);                       // T9
    m = 0;
    sharr[m] = makeHolder(2);                             // release-old fires
    Assert.isEqual(itemDealloc, 3);                       // T10

    // Verify mark survived the hw-stack round-trip.
    Holder check;
    check = sharr[0];
    Assert.isEqual(check.mark, 777);                      // T11

    Assert.summary();
    return;
    // Scope-exit: harr[0..2], harr2[2], sharr[0] all release
    // their payloads. sharr[1..2] are null — no extra deallocs.
}
