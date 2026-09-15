// class_inherit_strong_ivar.xc — the previously-untested intersection:
// a class hierarchy where BOTH the base and the subclass own a strong
// class-pointer ivar, freed via the dealloc super-chain.
//
// This is the path the phase-153 teardown rework relies on (release only
// OWN strong ivars, then chain to super so each level frees its own).
// No prior fixture combined inheritance with strong ivars, so the
// own-only release + chain was safe-but-unverified. If the teardown
// released inherited ivars too, a base ivar would be freed twice
// (leafDeallocs == 3); if the chain dropped the base, it'd leak
// (leafDeallocs == 1). Exactly 2 means each strong ivar is freed once.
//
//   T1  both strong ivars (base + derived) freed exactly once.
//   T2  base dealloc ran (reached via the chain).
//   T3  derived dealloc ran.
//   T4  child teardown precedes parent (orderTag 1 → 2).
//   T5  no-user-dealloc subclass: synth $dealloc still frees own +
//       inherited strong ivars via the chain.

#import "Stdio.xc"
#import "Assert.xc"

u16 leafDeallocs;
u16 baseDeallocs;
u16 derivedDeallocs;
u16 orderTag;            // 1 after derived body, 2 after base body

class Leaf
{
    u8 id;
    void dealloc(void) { leafDeallocs = leafDeallocs + 1; }
}

class Base
{
    Leaf* baseLeaf;
    void dealloc(void)
    {
        baseDeallocs = baseDeallocs + 1;
        if (orderTag == 1) { orderTag = 2; }
    }
}

// User dealloc, no explicit super.dealloc() — compiler auto-chains.
class Derived : Base
{
    Leaf* derivedLeaf;
    void dealloc(void)
    {
        derivedDeallocs = derivedDeallocs + 1;
        if (orderTag == 0) { orderTag = 1; }
    }
}

// No dealloc of its own — synth $dealloc must free own + inherited.
class Quiet : Base
{
    Leaf* quietLeaf;
}

void buildDerived(void)
{
    Derived* d = new Derived();
    d.baseLeaf = new Leaf();        // inherited strong ivar
    d.derivedLeaf = new Leaf();     // own strong ivar
    // scope exit: Derived.dealloc (frees derivedLeaf) → Base.dealloc
    //             (frees baseLeaf).
}

void buildQuiet(void)
{
    Quiet* q = new Quiet();
    q.baseLeaf = new Leaf();
    q.quietLeaf = new Leaf();
    // scope exit: synth Quiet.dealloc (frees quietLeaf) → Base.dealloc
    //             (frees baseLeaf).
}

void main(void)
{
    Assert.reset();
    leafDeallocs = 0; baseDeallocs = 0; derivedDeallocs = 0; orderTag = 0;

    buildDerived();
    Assert.isEqual(leafDeallocs, 2);       // T1 both freed once (not 1=leak, not 3=double)
    Assert.isEqual(baseDeallocs, 1);       // T2 base ran via chain
    Assert.isEqual(derivedDeallocs, 1);    // T3 derived ran
    Assert.isEqual(orderTag, 2);           // T4 child before parent

    leafDeallocs = 0; baseDeallocs = 0;
    buildQuiet();
    Assert.isEqual(leafDeallocs, 2);       // T5 synth subclass frees own + inherited

    Assert.summary();
    return;
}
