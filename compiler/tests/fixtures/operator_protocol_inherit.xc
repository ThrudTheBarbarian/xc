// Conformance and operators are both inherited. A subclass of a conforming
// class is a `Numeric` and uses its parent's `+`; an override, with the
// pattern or without, is the operator, and a call through the protocol
// dispatches to it.
#import <Stdio.xc>

protocol Numeric
    {
    Numeric* plus(Numeric* o) :operator(self + o);
    i32 value(void);
    }

class Money <Numeric>
    {
    i32 cents;
    static Money* of(i32 c) { Money* m = new Money(); m.cents = c; return m; }
    Numeric* plus(Numeric* o) :operator(self + o) { return Money.of(cents + o.value()); }
    i32 value(void) { return cents; }
    }

// Inherits the conformance and the operator.
class Tagged : Money
    {
    i32 tag;
    }

// Overrides `+` without the pattern: still the operator.
class Quiet : Money
    {
    Numeric* plus(Numeric* o)
        {
        Stdio.printf("  Quiet.plus\n");
        return Money.of(cents + o.value() + 2000);
        }
    }

// Overrides `+`, repeating the pattern.
class Loud : Money
    {
    Numeric* plus(Numeric* o) :operator(self + o) { return Money.of(cents + o.value() + 500); }
    }

Numeric* add(Numeric* a, Numeric* b)
    {
    return a + b;
    }

i32 main(void)
    {
    Tagged* t = new Tagged();
    t.cents = 25;
    Quiet* q = new Quiet();
    q.cents = 2;
    Loud* d = new Loud();
    d.cents = 7;
    Money* m = Money.of(100);
    Stdio.printf("tagged %d\n", add(t, m).value());
    Stdio.printf("quiet %d\n", add(q, m).value());
    Stdio.printf("loud %d\n", add(d, m).value());
    Stdio.printf("money %d\n", add(m, d).value());
    return 0;
    }
