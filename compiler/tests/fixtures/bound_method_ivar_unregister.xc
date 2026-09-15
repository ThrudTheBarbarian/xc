// bound_method_ivar_unregister.xc — a `^` ivar must UNLINK when its holder dies.
//
// Bug 030. Storing a bound method in an ivar links that slot into the
// RECEIVER's auto-zero chain, so `if (f)` goes false the moment the receiver
// dies (bound_method_weak.xc covers that direction). The reverse was never
// done: when the HOLDER died, its link stayed in the receiver's chain, pointing
// into a block the allocator was free to hand out again. The receiver's own
// dealloc then walked that chain — writing a zero into whatever now lived
// there, and following a `next` pointer out of freed memory.
//
// Two things made it hard to see. It needed no threads and no `weak` keyword —
// a plain `^` ivar is an auto-zeroing slot. And the crash landed in an
// unrelated object's teardown, one recycled allocation later.
//
// A class whose ONLY reference-flavoured ivar is a `^` also got no synthesised
// `$dealloc` at all, so there was nowhere for the unlink to happen even in
// principle. That is the second half of the fix.
//
//   T1  holder dies, then receiver dies — no corruption, both destructors run
//   T2  MANY holders on one receiver: the chain unlinks from the middle, not
//       just the head (the head-only case passes even with a broken pprev)
//   T3  the receiver still auto-zeroes a `^` in a holder that is STILL ALIVE —
//       the fix must not unlink slots that are still live
//   T4  the holder's own destructor still runs (the synthesised dealloc did not
//       displace a user-declared one)

#import "Stdio.xc"
#import "Assert.xc"

typedef void act_t(void);

u16 gTargetGone = (u16)0;
u16 gHolderGone = (u16)0;

class Target
{
    u16 v;
    void init(void)    { v = (u16)7; }
    void go(void)      { }
    void dealloc(void) { gTargetGone = gTargetGone + (u16)1; }
}

// Only ARC-relevant ivar is the `^` — this class used to get no destructor.
class Holder
{
    act_t^ f;
    void init(void) { }
}

// Same, but with a user destructor, so the two paths are both covered.
class LoudHolder
{
    act_t^ f;
    void init(void)    { }
    void dealloc(void) { gHolderGone = gHolderGone + (u16)1; }
}

void main(void)
{
    // ── T1: holder first, then receiver.
    {
        Target* t = new Target();
        {
            Holder* h = new Holder();
            h.f = &t.go;
        }                                       // h dies: must unlink from t
        Assert.isEqual(gTargetGone, (u16)0);    // T1a — t still alive
    }                                           // t dies: walks a chain that
                                                // must no longer name h
    Assert.isEqual(gTargetGone, (u16)1);        // T1b

    // ── T2: several holders, dying in the middle of the chain.
    gTargetGone = (u16)0;
    {
        Target* t = new Target();
        Holder* first = new Holder();
        first.f = &t.go;
        {
            Holder* mid1 = new Holder();  mid1.f = &t.go;
            Holder* mid2 = new Holder();  mid2.f = &t.go;
            Holder* mid3 = new Holder();  mid3.f = &t.go;
        }                                       // three interior links go
        Holder* last = new Holder();
        last.f = &t.go;
        Assert.isTrue(first.f != 0);            // T2a — survivors intact
        Assert.isTrue(last.f != 0);             // T2b
    }
    Assert.isEqual(gTargetGone, (u16)1);        // T2c — one clean teardown

    // ── T3: auto-zeroing still works for a holder that outlives its receiver.
    gTargetGone = (u16)0;
    {
        Holder* h = new Holder();
        {
            Target* t = new Target();
            h.f = &t.go;
            Assert.isTrue(h.f != 0);            // T3a — live
        }                                       // t dies
        Assert.isEqual(gTargetGone, (u16)1);    // T3b
        // Falsiness, not `h.f == 0`: comparing a `^` to zero compares the whole
        // PAIR, and auto-zeroing clears only the word the truth test reads — so
        // `== 0` answers a different question on xt6502 than it does on arm64.
        // That is bug 031, with its own guard (bound_method_eq_zero.xc); this
        // fixture is about the unlink, and uses the test the language defines.
        Assert.isFalse(h.f ? true : false);     // T3c — zeroed, not dangling
    }

    // ── T4: a user destructor still runs, and still unlinks.
    gTargetGone = (u16)0;
    gHolderGone = (u16)0;
    {
        Target* t = new Target();
        {
            LoudHolder* lh = new LoudHolder();
            lh.f = &t.go;
        }
        Assert.isEqual(gHolderGone, (u16)1);    // T4a — user dealloc ran
        Assert.isEqual(gTargetGone, (u16)0);    // T4b — target untouched
    }
    Assert.isEqual(gTargetGone, (u16)1);        // T4c

    Assert.summary();
}
