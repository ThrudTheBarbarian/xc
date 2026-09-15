// xe_banked_method_float.xc — Phase 1c: float ivar (5-byte) read +
// write through (self),Y inside a `:banked` heap-class method body.
//
// The float-store and float-load paths in +FloatStruct.m emit a
// per-byte (self),Y for each of the 5 bytes; until Phase 1c routed
// them through the helper, all five bytes landed in the wrong bank
// when the method ran with PORTB on its code bank.

#import "Stdio.xc"
#import "Assert.xc"

class FBox
{
    float f;

    void set(float x) :banked  { f = x; }
    float get(void) :banked    { return f; }
}

void main(void)
{
    Assert.reset();
    FBox* b = new FBox();
    b.set(3.14);
    Assert.isTrue(b.get() > 3.13);
    Assert.isTrue(b.get() < 3.15);
    Assert.summary();
    return;
}
