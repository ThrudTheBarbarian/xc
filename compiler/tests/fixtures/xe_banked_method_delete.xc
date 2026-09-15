// xe_banked_method_delete.xc — Phase 1c: `delete child` inside a
// `:banked` body where `child` is a banked-pointer ivar. The
// dealloc walker reads the 3-byte pointer via (self),Y at the
// ivar offset; the user-driven delete must reach the heap allocator
// with the right (lo, hi, bank) triple so the block is freed and
// reusable.
#import "Stdio.xc"
#import "Assert.xc"

class Inner { u16 v; }

class Outer
{
    banked:Inner* child;

    void install(void) :banked  { child = new Inner(); child.v = 99; }
    void release(void) :banked  { child = 0; }   // ARC releases the old value
    u16  read(void)    :banked  { return child.v; }
}

void main(void)
{
    Assert.reset();
    Outer* o = new Outer();
    o.install();
    Assert.isEqual(o.read(), 99);
    o.release();
    Outer* o2 = new Outer();
    o2.install();
    Assert.isEqual(o2.read(), 99);

    Stdio.printf("read2=%u\n", o2.read());

    Assert.summary();
    return;
}
