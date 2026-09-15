// xe_banked_method_calls.xc — Phase 1c fixture #2.
//
// Exercises additional (self),Y emit-site categories in :banked
// heap-class method bodies on xe:
//
//   * `:banked` method calling another `:banked` sibling on the
//     same instance via the implicit `self` receiver — sibling
//     dispatch must keep PORTB tracking right across the JSR pair.
//   * Compound-assignment to a u16 ivar inside a banked body —
//     hits the read-modify-write path, which goes through both the
//     ivar load and the ivar store helpers in sequence.
//   * Chained ivar STORE through a banked-pointer field —
//     `child.v = X` inside a banked body. The receiver-load leg
//     reads three bytes from (self),Y; the inner store goes through
//     _banked_store_byte (PORTB-aware already).

#import "Stdio.xc"
#import "Assert.xc"

class Inner { u16 v; }

class Counter
{
    u16 hits;
    banked:Inner* leaf;

    void prime(void) :banked
    {
        leaf = new Inner();
        leaf.v = 0;
    }

    void bump(u16 step) :banked
    {
        hits = hits + 1;
        leaf.v = leaf.v + step;
    }

    u16 hitCount(void) :banked   { return hits; }
    u16 leafTotal(void) :banked  { return leaf.v; }
}

void main(void)
{
    Assert.reset();
    Counter* c = new Counter();
    c.prime();
    c.bump(10);
    c.bump(20);
    c.bump(30);
    Assert.isEqual(c.hitCount(),  3);   // T1
    Assert.isEqual(c.leafTotal(), 60);  // T2
    Assert.summary();
    return;
}
