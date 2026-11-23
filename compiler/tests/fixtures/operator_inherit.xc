// Operators are inherited and overridable like any method. A subclass with no
// operator of its own uses its parent's; an override is called, whether it
// repeats the pattern or not; and through a parent pointer the call dispatches
// on the object, as any method call does. A static operator is found on an
// operand's class or its ancestors. A subclass of a class that defines `+`
// has `+` defined too, so its pointers lose the built-in `+` as well.
#import <Stdio.xc>

class Money
    {
    i32 cents;
    static Money* of(i32 c) { Money* m = new Money(); m.cents = c; return m; }
    Money* plus(Money* o) :operator(self + o) { return Money.of(cents + o.cents); }
    Money* negated() :operator(-self) { return Money.of(0 - cents); }
    static Money* times(i32 k, Money* m) :operator(k * m) { return Money.of(k * m.cents); }
    string who(void) { return "Money"; }
    }

// Inherits everything.
class Tagged : Money
    {
    i32 tag;
    }

// Overrides `+`, repeating the pattern.
class Loud : Money
    {
    Money* plus(Money* o) :operator(self + o)
        {
        Stdio.printf("  Loud.plus\n");
        return Money.of(cents + o.cents + 1000);
        }
    }

// Overrides `+` without the pattern: still the operator it overrides.
class Quiet : Money
    {
    Money* plus(Money* o)
        {
        Stdio.printf("  Quiet.plus\n");
        return Money.of(cents + o.cents + 2000);
        }
    }

Money* add(Money* a, Money* b)
    {
    return a + b;
    }

i32 main(void)
    {
    Money* m = Money.of(150);
    Tagged* t = new Tagged();
    t.cents = 25;
    Stdio.printf("tagged %d\n", (t + m).cents);
    Stdio.printf("tagged neg %d\n", (-t).cents);
    Stdio.printf("tagged scaled %d\n", (3 * t).cents);
    Loud* l = new Loud();
    l.cents = 1;
    Stdio.printf("loud %d\n", (l + m).cents);
    Quiet* q = new Quiet();
    q.cents = 2;
    Stdio.printf("quiet %d\n", (q + m).cents);
    // Through a parent pointer: dispatch on the object.
    Money* p = l;
    Stdio.printf("via parent %d\n", (p + m).cents);
    p = q;
    Stdio.printf("via parent %d\n", (p + m).cents);
    Stdio.printf("via function %d\n", add(l, m).cents);
    Stdio.printf("via function %d\n", add(m, l).cents);
    return 0;
    }
