// multi_return_class_ptr.xc — function declaring a multi-return
// signature with class-pointer return types parses, sema-checks,
// and the call-site tuple-destructure stores both values into
// pre-declared strong locals.
//
// G2 (see doc/ARC_roadmap.md) — parser accepts `Foo@` at every
// slot in a multi-return signature; the ARC tuple lowering
// needed for inline-declared tuple targets is 2b-multi-return
// follow-up work and intentionally out of scope here.
//
// Flat-heap only (xl-shadow / xe-nobank); banked-heap support is
// Phase 4 territory.

#import "Stdio.xc"
#import "Assert.xc"

class Box
{
    u8 tag;
}

Box*, Box* makePair(void)
{
    Box* a = new Box();
    a.tag = 11;
    Box* b = new Box();
    b.tag = 22;
    return a, b;
}

void main(void)
{
    Assert.reset();

    Box* x;
    Box* y;
    (x, y) = makePair();

    u16 xTag = x.tag;
    u16 yTag = y.tag;

    Assert.isEqual(xTag, 11);        // T1: first return landed in x
    Assert.isEqual(yTag, 22);        // T2: second return landed in y

    Assert.summary();
    return;
}
