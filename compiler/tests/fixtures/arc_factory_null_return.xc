// arc_factory_null_return.xc — a factory that returns `new T` on one path and
// a null pointer on another must be inferred returnsRetained (+1).
//
// The returnsRetained pre-scan classifies a class-pointer function as +1 iff
// every `return` is owned. A `return (T@)0` is a null constant: it owns nothing
// and needs no retain/release, so it must NOT veto the +1 inference. Before the
// fix the null path demoted the factory to +0 (borrowed); the caller then failed
// to adopt the allocator's +1 and the object was over-released at scope exit — a
// double free that aborted the process at teardown.
//
//   T1  factory-returned object deallocs exactly once (no double free, no leak)
//   T2  the null path frees nothing

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

u16 deallocCount;

// Mixed-return factory: `new` when asked, null otherwise.
Tracker* makeIf(u8 want)
{
    if (want != (u8)0) { return new Tracker(); }
    return (Tracker*)0;
}

void useOne(void)
{
    Tracker* t = makeIf((u8)1);   // adopts the allocator's +1
    t.tag = (u8)7;                // touch it so it can't be optimised away
    // scope exit releases exactly once → dealloc fires once
}

void useNull(void)
{
    Tracker* t = makeIf((u8)0);   // null; scope-exit release is a no-op
    if (t != (Tracker*)0) { t.tag = (u8)9; }
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;

    useOne();
    Assert.isEqual(deallocCount, 1);   // one object, freed exactly once

    useNull();
    Assert.isEqual(deallocCount, 1);   // null path frees nothing

    Assert.summary();
    return;
}
