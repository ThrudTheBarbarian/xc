// A protocol can require an operator: generic code over `Numeric` writes
// `a + b`, and the call dispatches on the object as `a.plus(b)` does. Each
// conforming class repeats the pattern; its parameter may have another name,
// since operands match by position. Through a `Numeric*` only `+` is an
// operator: `<` keeps its built-in meaning.
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

class Score <Numeric>
    {
    i32 points;
    static Score* of(i32 p) { Score* s = new Score(); s.points = p; return s; }
    Numeric* plus(Numeric* other) :operator(self + other) { return Score.of(points + 10 * other.value()); }
    i32 value(void) { return points; }
    }

Numeric* sum3(Numeric* a, Numeric* b, Numeric* c)
    {
    return a + b + c;
    }

i32 main(void)
    {
    Money* m = Money.of(150);
    Score* s = Score.of(7);
    Numeric* a = m;
    Numeric* b = s;
    Stdio.printf("money %d\n", (a + b).value());
    Stdio.printf("score %d\n", (b + a).value());
    Stdio.printf("sum3 %d\n", sum3(m, s, m).value());
    Stdio.printf("sum3 %d\n", sum3(s, m, s).value());
    Stdio.printf("named %d\n", a.plus(a).value());
    Stdio.printf("compare %d\n", (a < b || b < a) ? 1 : 0);
    return 0;
    }
