// heap_chain_method.xc — chained method call on a banked-pointer
// ivar must mangle the method label with the receiver's actual
// class, not synthesise an empty class name.
//
// `c.child.setV(x)` where c is a Container@ and child is a
// banked:Inner@ ivar of Container went out as `JSR _cls__setV`
// (double underscore = empty className) because emitMethodCallExpr's
// receiver-type lookup only ran for XTIdentifierNode receivers.
// xta resolved the unknown symbol to $0000 and the program jumped
// into the JSR vector area. With the chained-receiver branch in
// place, the same call mangles correctly to `_cls_Inner_setV` and
// the bank wrap installs Y from emitExprToA into __self_bank so
// the method body sees the right physical bank.

#import "Stdio.xc"
#import "Assert.xc"

class Inner {
    u16 v;
    void setV(u16 x) { v = x; }
    u16 getV(void) { return v; }
}

class Container {
    banked:Inner* child;
    void init(void) { child = new Inner(); }
}

void main(void)
{
    Assert.reset();

    // Force Inner into bank 2 by filling bank 1 first.
    u8* filler = new u8[4080];
    banked:Container* c = new Container();
    c.child.setV($CAFE);

    delete filler;
    banked:Inner* sibling = new Inner();
    sibling.setV($BEEF);

    Assert.isEqual(c.child.getV(), $CAFE);   // T1
    Assert.isEqual(sibling.getV(),  $BEEF);  // T2

    Stdio.printf("child=%u sibling=%u\n", c.child.getV(), sibling.getV());

    Assert.summary();
    return;
}
