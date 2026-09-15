// arc_weak_local_return.xc — a weak local (`weak:T@` or a bound method `^`)
// must be UNREGISTERED from its referent's weak chain when the function
// RETURNS, not only when the scope falls off the end.
//
// A weak slot is linked into the referent's intrusive chain so it auto-zeroes
// if the referent dies. The link points AT THE FRAME SLOT. So when the frame
// goes away, the link has to go with it — otherwise the referent is still
// holding a pointer to a stack slot that no longer exists, and the next time
// that referent is deallocated the runtime walks its chain and writes a zero
// through the stale address.
//
// popArcScopeEmittingReleases: did this. The two teardown loops a `return`
// goes through did NOT. So the bug needed only this much:
//
//     i8 cmp(Object@ a, Object@ b) {
//         Comparable@ c = (Comparable@)a;
//         cmp1_t^ f = &c.compare;      // registers on a's weak chain
//         if (!f) return (i8)0;
//         return f(b);                 // …and RETURNS without unregistering
//     }
//
// which is an entirely ordinary comparator. Sorting an Array of Strings with
// one crashed with a SIGBUS inside _xtc_dealloc, writing into read-only memory,
// long after the comparator had finished — the victim was never the culprit.
//
// Any function that returns while holding a delegate `^` had the same hole, so
// the blast radius was every callback-shaped API in the language.
//
// Test surface — each of these RETURNS while holding a weak slot, then the
// referent is destroyed, which is when a stale chain entry bites:
//
//   T1  a `^` local, function returns normally
//   T2  a `^` local, function returns EARLY (before the slot is even read)
//   T3  a `weak:T@` local, function returns
//   T4  the referent is destroyed AFTER many such calls — the chain must be
//       empty, so this is where a leaked entry surfaces
//   T5  the weak slot still WORKS: it zeroes when the referent dies
//
// If any chain entry survives its frame, this fixture faults rather than
// printing. Reaching the end is the pass.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

class Target
{
    u16 v;
    void init(void)   { v = (u16)7; }
    u16  get(void)    { return v; }
}

typedef u16 getter_t(void);

// T1: takes a `^` on the receiver and RETURNS through it.
u16 viaBound(Target* t)
{
    getter_t^ g = &t.get;
    if (!g) return (u16)0;
    return g();
}

// T2: takes a `^` and returns EARLY, before using it. The slot is registered
// either way — the register happens at the assignment, not at the call.
u16 viaBoundEarly(Target* t, bool bail)
{
    getter_t^ g = &t.get;
    if (bail) return (u16)99;
    if (!g) return (u16)0;
    return g();
}

// T3: a `weak:T@` local, and a return through it.
u16 viaWeakLocal(Target* t)
{
    weak: Target* w = t;
    if (w == 0) return (u16)0;
    return w.get();
}

void main(void)
{
    // ── T1 / T2 / T3: hammer each shape. Every call registers a weak slot on
    // `t`'s chain and returns; if the entry is not removed, `t`'s chain grows
    // a dead stack address per call.
    Target* t = new Target();
    u16 sum = (u16)0;
    for (u16 i = (u16)0; i < (u16)20; i++) {
        sum = sum + viaBound(t);                        // T1
        sum = sum + viaBoundEarly(t, false);            // T2 (taken path)
        sum = sum + viaWeakLocal(t);                    // T3
    }
    Assert.isEqual(sum, (u16)420);                      // 20 * (7 + 7 + 7)

    u16 bailed = viaBoundEarly(t, true);                // T2 (early-return path)
    Assert.isEqual(bailed, (u16)99);

    // ── T4: destroy the referent. THIS is where a leaked chain entry bites —
    // dealloc walks the chain and writes a zero through every slot on it.
    // Sixty dead stack addresses would fault here.
    t = (Target*)0;
    Assert.isTrue(true);                                // reached T4 alive

    // ── T5: the weak slot still does its job — it zeroes when the referent
    // dies. Unregistering on return must not have broken that.
    Target* t2 = new Target();
    weak: Target* w = t2;
    Assert.isTrue(w != 0);                              // T5a — alive
    t2 = (Target*)0;
    Assert.isTrue(w == 0);                              // T5b — auto-zeroed

    // ── T6: the shape that actually found this — a comparator holding a `^`,
    // used to sort an Array of Strings. Crashed in _xtc_dealloc.
    Array* arr = new Array();
    arr.add(String.withCString("pear"));
    arr.add(String.withCString("apple"));
    arr.add(String.withCString("fig"));
    Assert.isTrue(arr.sort());
    String* firstS = (String* ?)arr.get((u16)0);
    Assert.isTrue(firstS != 0);
    Assert.isEqual((u16)firstS.byteAt((u16)0), (u16)'a');  // "apple" sorted first

    Assert.summary();
    return;
}
