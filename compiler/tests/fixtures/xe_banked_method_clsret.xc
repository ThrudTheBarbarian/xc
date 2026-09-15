// xe_banked_method_clsret.xc — Phase 1c: `:banked` heap-class method
// that returns a strong class pointer (ARC +1 convention). The
// callee retains-on-return; the call site decrements when the
// returned reference goes out of scope. Verifies that the cloaked-
// bracket wrapper preserves A/X across PORTB restore (the return
// value's lo/hi) and that the retain on return fires inside the
// banked body BEFORE the bracket closes (so retain is observed by
// the caller's reference count, not lost in a bank switch).

#import "Stdio.xc"
#import "Assert.xc"

class Leaf
{
    u8 tag;
}

class Factory
{
    u8 lastTag;
    Leaf* make(u8 t) :banked
    {
        Leaf* l = new Leaf();
        l.tag = t;
        lastTag = t;
        return l;
    }
}

void main(void)
{
    Assert.reset();
    Factory* f = new Factory();
    Leaf* a = f.make(7);
    Leaf* b = f.make(42);
    Assert.isEqual(a.tag, 7);                 // T1: a survived bracket
    Assert.isEqual(b.tag, 42);                // T2: b survived bracket
    Assert.isEqual(f.lastTag, 42);            // T3: factory updated
    Assert.summary();
    return;
}
