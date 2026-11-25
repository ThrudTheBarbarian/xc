// opprotolib.xc — the `-c` object half of opprotocols.sh: a protocol whose
// requirements are operators, a class that conforms to it, and a function
// that uses the operators on any conforming object.
protocol Numeric
    {
    Numeric* plus(Numeric* o) :operator(self + o);
    Numeric* pow(Numeric* e) :operator(self ** e) :precedence(above *, right);
    Numeric* times(Numeric* o) :operator(self * o);
    i32 digit(i32 i) :operator(self[i]);
    i32 size(void) :operator(|self|);
    i32 value(void);
    }

class Money <Numeric>
    {
    i32 cents;
    static Money* of(i32 c) { Money* m = new Money(); m.cents = c; return m; }
    Numeric* plus(Numeric* o) :operator(self + o) { return Money.of(cents + o.value()); }
    static i32 power(i32 b, i32 e) { return e == 0 ? 1 : b * Money.power(b, e - 1); }
    static i32 shifted(i32 v, i32 i) { return i == 0 ? v : Money.shifted(v / 10, i - 1); }
    Numeric* pow(Numeric* e) :operator(self ** e) :precedence(above *, right) { return Money.of(Money.power(cents, e.value())); }
    Numeric* times(Numeric* o) :operator(self * o) { return Money.of(cents * o.value()); }
    i32 digit(i32 i) :operator(self[i]) { return Money.shifted(cents, i) % 10; }
    i32 size(void) :operator(|self|) { return cents < 0 ? 0 - cents : cents; }
    i32 value(void) { return cents; }
    }

// Sums any two conforming objects, whichever module their classes are in.
Numeric* sumOf(Numeric* a, Numeric* b)
    {
    return a + b;
    }
