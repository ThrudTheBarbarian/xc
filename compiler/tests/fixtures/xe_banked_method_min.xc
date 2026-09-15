// xe_banked_method_min.xc — smallest failing case for an explicit
// `:banked` heap-class method on xe-banked.
//
// One ivar, one setter, one getter. The method body's (self),Y
// touches the heap bank; PORTB at the point of access is selected to
// the method's CODE bank, not the heap bank, so the access lands in
// the wrong window unless the body is bracketed.
//
// Expected at the moment: T1 / T2 fail. The fix walks outward from
// here.

#import "Stdio.xc"
#import "Assert.xc"

// Phase 3: `:banked` on a heap-class method, on xe-family target.
// The body lives in a numbered bank page; the cloaked-bracket call
// wrapper resolves PORTB to that bank's deposit-bits literal at call
// time (Phase 2 substitution). Body-side (self),Y access brackets
// PORTB to the receiver's heap bank via _ivar_store_byte / _load.
class Box {
    u16 v;
    void set(u16 x) :banked { v = x; }
    u16  get(void)  :banked { return v; }
}

void main(void)
{
    Assert.reset();
    Box* b = new Box();
    b.set($BEEF);                       // T1 — store via banked method
    Assert.isEqual(b.get(), $BEEF);     // T2 — load via banked method
    Assert.summary();
    return;
}
