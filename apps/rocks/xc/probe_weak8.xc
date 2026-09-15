// probe_weak8.xc — what happens to the VALUE assigned into a weak slot?
//
// Companion to probe_weak6/7 (bug 036).  Those measured the READ side: a weak
// reference copied into a strong return value was not retained.  This measures
// the WRITE side, which the fix for that makes reachable: a weak slot is
// non-owning, so a +1 value assigned into one has nobody to release it.
//
// Measured with a dealloc override rather than by inference — gLive is the count
// of objects alive, so a leak is a number that does not come back down and an
// over-release is one that goes below zero.  (The instrument is checked first:
// if the baseline row is wrong, none of the rest means anything.)
//
// MEASURED on the compiler installed 2026-09-04 22:10, BEFORE the 036 fix:
//
//   ok          weak = borrowedLocal
//   LEAK +1     weak = new Obj()                 <- +1 RHS, weak slot owns nothing
//   LEAK +1     weak = mkStrong()                <- ditto, via a method
//   LEAK +1     weak LOCAL = new Obj()           <- and it is not only FIELDS
//   ok          weak reassigned a -> b -> 0      <- the old value is not over-released
//   ok          strong = weakGetter()
//   ok          weak   = weakGetter()            <- balanced only because +0 today
//
// Two things to carry into the fix:
//
//   The leak is on the weak-ASSIGNMENT path and it is pre-existing — a weak slot
//   is non-owning, so a +1 right-hand side has nobody to release it.  It shows up
//   for a weak LOCAL as well as a weak field, so releasing only on field stores
//   would leave half of it.
//
//   The last row is the trade: it balances today only because a weak getter
//   returns +0.  Once the 036 fix makes that +1 — which is right — this row
//   becomes a leak unless the weak-assignment path releases its RHS.  Re-run
//   this probe after the fix and the interesting diff is exactly that row.
#import <Stdio.xc>
#import "Array.xc"

i32 gLive;
class Obj : Object
    {
    i32 tag;
    void init(void)
        {
        tag = (i32)0;
        gLive = gLive + (i32)1;
        }
    void dealloc(void)
        {
        gLive = gLive - (i32)1;
        }
    }

    class H : Object
    {
    weak : Obj* w;
    Obj* s;
    void init(void)
        {
        w = (Obj*)0;
        s = (Obj*)0;
        }
    // returns +1
    Obj* mkStrong(void)
        {
        return new Obj();
        }
    // weak-typed return
    weak : Obj* getWeak(void)
        {
        return w;
        }
    // strong field, +1 (correct today)
    Obj* getStrongField(void)
        {
        return s;
        }
    }

    i32 gFails;
// Measured as a DELTA around each shape, not against a running total: every
// scope here is self-contained, so a correct shape leaves the live count exactly
// as it found it.  (Comparing against a cumulative figure mislabels every shape
// after the first leak, which is how I first misread this.)
void expect(u8* what, i32 before)
    {
    i32 delta = gLive - before;
    if (delta == (i32)0)
        {
        Stdio.printf("  ok            %s\n", what);
        }
    else if (delta > (i32)0)
        {
        Stdio.printf("  LEAK (+%d)     %s\n", (i16)delta, what);
        gFails = gFails + (i32)1;
        }
    else
        {
        Stdio.printf("  OVER-REL (%d) %s\n", (i16)delta, what);
        gFails = gFails + (i32)1;
        }
    }

// --- the shapes, each in its own scope so scope-exit behaviour is visible ----
// fwd-declared holder
void sBaselineStrongTemp(void)
    {
    Obj* o = h0.mkStrong();
    }
H* h0;

void sWeakGetsNew(void)
    {
    H* h = new H();
    h.w = new Obj();
    }
void sWeakGetsPlusOne(void)
    {
    H* h = new H();
    h.w = h.mkStrong();
    }
void sWeakGetsBorrowed(void)
    {
    H* h = new H();
    Obj* o = new Obj();
    h.w = o;
    }
void sWeakGetsWeakGetter(void)
    {
    H* h = new H();
    Obj* o = new Obj();
    h.w = o;
    H* h2 = new H();
    h2.w = h.getWeak();
    }
void sStrongGetsWeakGetter(void)
    {
    H* h = new H();
    Obj* o = new Obj();
    h.w = o;
    Obj* got = h.getWeak();
    }
void sWeakLocalGetsNew(void)
    {
weak:
    Obj* wl = new Obj();
    }
void sWeakReassigned(void)
    {
    H* h = new H();
    Obj* a = new Obj();
    Obj* b = new Obj();
    h.w = a;
    h.w = b;
    h.w = (Obj*)0;
    }

void main(void)
    {
    gLive = (i32)0;
    gFails = (i32)0;
    i32 b = (i32)0;
    h0 = new H();

    Stdio.printf("-- instrument baseline --\n");
    b = gLive;
    sBaselineStrongTemp();
    expect((u8*)"a +1 return into a STRONG local, scope exits", b);

    Stdio.printf("-- assigning INTO a weak slot --\n");
    b = gLive;
    sWeakGetsBorrowed();
    expect((u8*)"weak = borrowed local            ", b);
    b = gLive;
    sWeakGetsNew();
    expect((u8*)"weak = new Obj()          (+1 RHS)", b);
    b = gLive;
    sWeakGetsPlusOne();
    expect((u8*)"weak = mkStrong()         (+1 RHS)", b);
    b = gLive;
    sWeakLocalGetsNew();
    expect((u8*)"weak LOCAL = new Obj()    (+1 RHS)", b);
    b = gLive;
    sWeakReassigned();
    expect((u8*)"weak reassigned a,b,0            ", b);

    Stdio.printf("-- the weak GETTER, both destinations --\n");
    b = gLive;
    sStrongGetsWeakGetter();
    expect((u8*)"strong = weakGetter()            ", b);
    b = gLive;
    sWeakGetsWeakGetter();
    expect((u8*)"weak   = weakGetter()            ", b);

    Stdio.printf("(a correct shape leaves the live count where it found it)\n");
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: every shape balances\n");
        }
    else
        {
        Stdio.printf("FAIL: %d shape(s) unbalanced\n", (i16)gFails);
        }
    }
