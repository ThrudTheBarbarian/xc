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
