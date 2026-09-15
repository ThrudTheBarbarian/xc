// xe_banked_method_inherit.xc — Phase 1c: virtual dispatch through
// a `:banked` heap-class method on an overriding subclass. The
// vtable goes through the cloaked-bracket call wrapper at every
// dispatch site; Phase 3's per-target PORTB literal must resolve
// to the overrider's actual code bank, not the base's.
#import "Stdio.xc"
#import "Assert.xc"

class Base
{
    u16 baseV;
    void set(u16 v) :banked  { baseV = v; }
    u16 read(void)  :banked  { return baseV * 2; }
}

class Derived : Base
{
    u16 read(void) :banked   { return baseV * 3; }
}

void main(void)
{
    Assert.reset();
    Base* b = new Base();
    b.set(10);
    Assert.isEqual(b.read(), 20);

    Derived* d = new Derived();
    d.set(10);
    Assert.isEqual(d.read(), 30);
    Assert.summary();
    return;
}
