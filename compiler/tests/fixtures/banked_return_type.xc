// banked_return_type.xc — `banked:T@` is valid as a function or
// method return type.
//
// Pre-fix the parser's looksLikeFunctionDecl lookahead helper
// didn't consume the placement / weak qualifier, so a function
// like `banked:Inner@ getChild(void) { ... }` failed lookahead
// (`banked` isn't a type keyword) and the parser fell through
// to a variable-declaration parse, which then errored on `return`
// inside the `{ ... }` body.

#import "Stdio.xc"
#import "Assert.xc"

class Inner { u16 v; }
class Container {
    banked:Inner* child;
    void init(void) { child = new Inner(); }
    banked:Inner* getChild(void) { return child; }
}

// Free-function form too — same parser path.
banked:Inner* allocSlot(u16 m)
{
    banked:Inner* s = new Inner();
    s.v = m;
    return s;
}

void main(void)
{
    Assert.reset();
    u8* filler = new u8[4080];
    banked:Container* c = new Container();
    c.child.v = $5678;

    banked:Inner* p = c.getChild();
    Assert.isEqual(p.v, $5678);

    banked:Inner* q = allocSlot($1234);
    Assert.isEqual(q.v, $1234);

    Assert.summary();
    return;
}
