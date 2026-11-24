// opobj.xc — the `-c` object half of operators.sh: a class whose operators a
// program in another module uses through this object's interface.
class Money
    {
    i32 cents;
    static Money* of(i32 c) { Money* m = new Money(); m.cents = c; return m; }
    Money* plus(Money* o) :operator(self + o) { return Money.of(cents + o.cents); }
    Money* negated() :operator(-self) { return Money.of(0 - cents); }
    static Money* times(i32 k, Money* m) :operator(k * m) { return Money.of(k * m.cents); }
    void addIn(Money* o) :operator(self += o) { cents = cents + o.cents; }
    }

// Index operators: a get and a set taking two indices, and a range get.
class Ledger
    {
    i32 cells[6];
    i32 at(i32 r, i32 c) :operator(self[r, c]) { return cells[r * 3 + c]; }
    void put(i32 r, i32 c, i32 x) :operator(self[r, c] = x) { cells[r * 3 + c] = x; }
    i32 ends(i32 lo, i32 hi) :operator(self[lo..hi]) { return cells[lo] + cells[hi - 1]; }
    }

// Operators of the class's own shape: `**` grouping from the right above `*`,
// and `⊗` from the Unicode block. Their shapes and the precedence travel in
// the interface, so the program parses them as this module does.
class Pow
    {
    i32 v;
    static Pow* of(i32 x) { Pow* p = new Pow(); p.v = x; return p; }
    Pow* raise(Pow* e) :operator(self ** e) :precedence(above *, right)
        {
        i32 r = 1;
        for (i32 i = 0; i < e.v; i++) : serial
            r = r * v;
        return Pow.of(r);
        }
    static Pow* scaled(i32 k, Pow* p) :operator(k * p) { return Pow.of(k * p.v); }
    Pow* kron(Pow* o) :operator(self ⊗ o) { return Pow.of(v * 100 + o.v); }
    }

// Bracket operators: `|v|` and the static `⌊x⌋`. The interface carries their
// shapes, so a `|` where the program's operand starts opens a bar.
class Span
    {
    i32 lo;
    i32 hi;
    static Span* of(i32 a, i32 b) { Span* s = new Span(); s.lo = a; s.hi = b; return s; }
    i32 width() :operator(|self|) { return hi - lo; }
    static i32 low(Span* s) :operator(⌊s⌋) { return s.lo; }
    }
