// operator-bracket — a bracket operator lowers to the method call it resolved
// to, as a prefix operator does: `|a|` calls V.size, `‖a‖` V.norm, `⌈a⌉`
// V.same and the static `⌊v⌋` V.low. `x | y` between operands is still a
// bitwise or.
class V
    {
    u8 x;
    u8 size() :operator(|self|) { return x; }
    V* norm() :operator(‖self‖) { return self; }
    V* same() :operator(⌈self⌉) { return self; }
    static u8 low(V* v) :operator(⌊v⌋) { return v.x; }
    }

    u8
    run(V* a, u8 x, u8 y)
    {
    return |a| + |‖a‖| + ⌊⌈a⌉⌋ + (x | y);
    }
