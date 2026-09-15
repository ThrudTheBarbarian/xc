// xe_banked_method_struct.xc — Phase 1c: struct field access through
// (self),Y inside a `:banked` heap-class method body.
//
// Until Phase 1c patched the struct-field read/write paths in
// MemberAccess.m / ExprAssign.m, this fixture corrupted self's
// pointer slot — `at.x = x` in install() emitted naked
// `STA ($self),Y` with PORTB on the method's code bank, and
// `return at.x` in pX() did the matching naked LDA. Both wrote /
// read into the wrong bank window.

#import "Stdio.xc"
#import "Assert.xc"

struct Point { u16 x; u16 y; }

class Sprite
{
    Point at;
    u16 colour;

    void place(u16 x, u16 y, u16 c) :banked
    {
        at.x = x;
        at.y = y;
        colour = c;
    }

    u16 pX(void) :banked      { return at.x; }
    u16 pY(void) :banked      { return at.y; }
    u16 col(void) :banked     { return colour; }
}

void main(void)
{
    Assert.reset();
    Sprite* s = new Sprite();
    s.place(100, 200, 7);
    Assert.isEqual(s.pX(), 100);
    Assert.isEqual(s.pY(), 200);
    Assert.isEqual(s.col(),  7);
    Assert.summary();
    return;
}
