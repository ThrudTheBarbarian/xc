// A protocol that requires `+` gives up the built-in `+` for its values:
// `p + step` is not a pointer step.
// xtc: error "'Numeric' has no '+' taking 'i32'"
protocol Numeric
    {
    Numeric* plus(Numeric* o) :operator(self + o);
    }

class Money <Numeric>
    {
    i32 cents;
    Numeric* plus(Numeric* o) :operator(self + o) { return o; }
    }

i32 main(void)
    {
    Numeric* p = new Money();
    i32 step = 1;
    Numeric* q = p + step;
    return q == p ? 0 : 1;
    }
