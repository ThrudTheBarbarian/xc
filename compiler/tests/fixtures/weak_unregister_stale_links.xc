//xtc-flags: target=arm64
// weak_unregister_stale_links.xc — bug 176. Storing a callback into a slot
// unregisters the OLD value from its weak chain first. When the old 16 bytes
// are STALE — a reused union member (c2xc emits unions as a raw byte overlay)
// that last held a double, a string, or a RETURN ADDRESS — the slot's pprev
// link is non-null but bogus, and the old code wrote `*pprev = next` straight
// through it: SIGBUS, writing into read-only code (a converted C server died
// this way, in __xtc_weak_unregister, unlinking a return address as a node).
//
// The fix validates the intrusive chain's back-pointer invariant — *pprev ==
// slot for a validly-linked slot — before unlinking, and bails on a mismatch.
//
// This overlays a callback slot on a Raw struct whose first pointer is a
// readable-but-wrong code address (a stale "pprev"), then stores a callback
// through a parameter (so the store is not a statically-widened skip and the
// runtime unregister actually runs). arm64-only: the overlay matches the
// 64-bit weak-slot layout.

i32 printf(u8* f, ...);

struct Raw { pointer p0; pointer p1; pointer p2; pointer p3; }
struct Slot { callback i32(i32 x) get; }

i32 triple(i32 x) { return x * 3; }

// cb comes in as a parameter (unknown provenance), so the store registers and
// the runtime unregisters the slot's current (bogus) links first.
void setIt(Slot* s, callback i32(i32 x) cb) { s.get = cb; }

i32 main(void)
{
    Raw r;
    r.p0 = (pointer)&triple;   // pprev = a readable code address, != the slot
    r.p1 = (pointer)0;         // next  = null
    r.p2 = (pointer)0;
    r.p3 = (pointer)0;

    callback i32(i32 x) f = &triple;
    setIt((Slot*)&r, f);       // used to SIGBUS in __xtc_weak_unregister

    Slot* s = (Slot*)&r;
    printf("result %d\n", s.get(5));   // 15, and no fault
    return (i32)0;
}
