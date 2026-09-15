// heap_self_chain_bank.xc — chained banked-ivar access inside the
// owning class's own method body must dereference all three bytes
// of the banked pointer ivar.
//
// `child.v = X` inside Container.init() compiles to a chained
// member access where `child` is read from self, then `.v` is
// stored at offset+1 of *child*. Earlier emitExprToA loaded only
// (lo, hi) from (self),Y for a 3-byte banked-pointer ivar; the
// caller's downstream banked-store logic stashed Y as the bank,
// but Y at that point held the LDY-offset of the high-byte read
// (= ivarOffset+1) — not the actual bank byte at slot+2 of self.
// `child.v` then routed through whatever bank that offset value
// happened to encode.
//
// Coincidence shape: when child sits at ivar offset 1, Y at the end
// of the load was 2 — and if Inner happened to land in bank 2, the
// store appeared to work. Allocating Inner in bank 1 (the common
// default heap_bank_first case) breaks the coincidence: the write
// routes through bank 2, the read through bank 1, and the readback
// returns the class-id-stamp byte (or zero-init).

#import "Stdio.xc"
#import "Assert.xc"

class Inner { u16 v; }
class Container {
    banked:Inner* child;
    void init(void) {
        child = new Inner();
        child.v = $5678;
    }
}

void main(void)
{
    Assert.reset();
    banked:Container* c = new Container();
    Assert.isEqual(c.child.v, $5678);
    Assert.summary();
    return;
}
