// A protocol value and a class value in one operator expression: the left
// operand's operators come first. `p + m` is the protocol's `+`, which takes
// any `Numeric`; `m + p` is Money's; `p * m` is Money's static `*`, found on
// the right operand's class, since the protocol has no `*`.
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
    static Money* times(Numeric* k, Money* m) :operator(k * m) { return Money.of(k.value() * m.cents); }
    i32 value(void) { return cents; }
    }

class Score <Numeric>
    {
    i32 points;
    static Score* of(i32 p) { Score* s = new Score(); s.points = p; return s; }
    Numeric* plus(Numeric* o) :operator(self + o) { return Score.of(points + 10 * o.value()); }
    i32 value(void) { return points; }
    }

i32 main(void)
    {
    Numeric* p = Score.of(3);
    Money* m = Money.of(40);
    Stdio.printf("p + m %d\n", (p + m).value());
    Stdio.printf("m + p %d\n", (m + p).value());
    Stdio.printf("p * m %d\n", (p * m).value());
    Stdio.printf("chain %d\n", (p + m + p).value());
    return 0;
    }
