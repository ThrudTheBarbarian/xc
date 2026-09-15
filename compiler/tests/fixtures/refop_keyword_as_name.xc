// refop_keyword_as_name.xc — `release`, `retain`, `delete` are
// statement keywords (manual ARC ops) but must also be acceptable
// as method/function names so users can override the auto-generated
// release(void) helper or just pick those names freely.
//
// Pre-fix the parser strictly required XTTokenIdentifier at the
// declarator-name position and at the `.member` access position,
// rejecting `void release(void) { ... }` and `c.release()`.

#import "Stdio.xc"
#import "Assert.xc"

class Slot { u16 marker; }
class Container {
    banked:Slot* child;
    void init(void) { child = new Slot(); }
    void release(void) { child = 0; }   // ARC drops it; `delete` on a class is rejected
    void retain(void) { /* dummy override */ }
}

void main(void)
{
    Assert.reset();
    u8* filler = new u8[4080];

    banked:Container* c = new Container();
    c.child.marker = $ABCD;
    Assert.isEqual(c.child.marker, $ABCD);

    c.release();   // user-defined release method
    c.retain();    // user-defined retain method

    Assert.summary();
    return;
}
