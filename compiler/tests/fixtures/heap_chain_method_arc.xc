// heap_chain_method_arc.xc — chained read of a banked-pointer ivar
// inside a method body must dereference via (self),Y (mirror of
// the ExprAssign chained-write fix). Variant with ARC enabled
// (-farc default) so the retain/release scope-exit paths around
// the chained read are also exercised.
//
// `slot.v` inside Holder.readV() compiled to `LDA $8001 ; slot+0`
// — the encoded ivar address as absolute, which is screen RAM.
// That returned 0 instead of the stored marker. Symmetric to the
// chained-write fix: skip the fast staged-pointer path when the
// base is an ivar so the generic emitExprToA branch handles it
// via (self),Y and leaves the bank in Y.

#import "Stdio.xc"
#import "Assert.xc"

class Inner { u16 v; }
class Holder {
    banked:Inner* slot;
    void store(banked:Inner* p) { slot = p; }
    u16 readV(void) { return slot.v; }
}

void main(void)
{
    Assert.reset();
    u8* filler = new u8[4080];

    banked:Inner* src = new Inner();
    src.v = $7777;

    banked:Holder* h = new Holder();
    h.store(src);

    Assert.isEqual(h.readV(), $7777);
    Assert.summary();
    return;
}
