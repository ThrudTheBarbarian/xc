// opobj.xc — the `-c` object half of operators.sh: a class whose operators a
// program in another module uses through this object's interface.
class Money
    {
    i32 cents;
    static Money* of(i32 c) { Money* m = new Money(); m.cents = c; return m; }
    Money* plus(Money* o) :operator(self + o) { return Money.of(cents + o.cents); }
    Money* negated() :operator(-self) { return Money.of(0 - cents); }
    static Money* times(i32 k, Money* m) :operator(k * m) { return Money.of(k * m.cents); }
    }
