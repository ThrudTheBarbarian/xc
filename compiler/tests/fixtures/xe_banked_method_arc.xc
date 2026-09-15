// xe_banked_method_arc.xc — Phase 1c fixture #1.
//
// Heap-class method annotated `:banked` that exercises three
// (self),Y emit-site categories beyond the trivial Box.set / Box.get:
//
//   * ARC scope-exit retain/release — every method on a heap class
//     adds an implicit retain at entry and decref at exit. Both
//     paths read self via ($self),Y.
//   * 3-byte banked-pointer ivar store — `child = new Inner()`
//     inside a banked body must store all three bytes (lo, hi, bank)
//     to (self),Y at offsets +1/+2/+3.
//   * Chained ivar read on a banked method's receiver — `child.v`
//     reads the banked pointer ivar then dereferences. The first
//     leg is a (self),Y read of three bytes from `self.child`; the
//     second leg loads `.v` through that pointer.
//
// Each of these emit sites currently emits naked STA/LDA ($self),Y.
// In a `:banked` body PORTB is on the method's CODE bank, not the
// heap bank — so the access lands wrong unless the helper-routing
// gate from Phase 1b applies to that emit site too. Each failure
// surfaces a Phase 1c emit-site to patch.

#import "Stdio.xc"
#import "Assert.xc"

class Inner { u16 v; }

class Outer
{
    banked:Inner* child;

    void install(void) :banked
    {
        child = new Inner();
        child.v = $1234;
    }

    u16 read(void) :banked
    {
        return child.v;
    }
}

void main(void)
{
    Assert.reset();

    // Force Inner to land in a bank ≠ heap_bank_first so the bank
    // byte stored in `child` matters: if any (self),Y access in the
    // chained read uses the wrong PORTB the bank byte read back
    // diverges from the bank actually stored, and `child.v` routes
    // through the wrong bank.  16 KB per bank; two ≥10 KB
    // allocations push Outer/Inner into a later bank.
    u8* pad1 = new u8[10000];
    u8* pad2 = new u8[10000];

    Outer* o = new Outer();
    o.install();                        // T1 setup
    Assert.isEqual(o.read(), $1234);    // T1
    Assert.summary();
    return;
}
