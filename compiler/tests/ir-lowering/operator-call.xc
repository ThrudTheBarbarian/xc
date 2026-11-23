// operator-call — an overloaded operator lowers to the method call it
// resolved to: `a + b` calls V.plus, `-a` calls V.neg, and `2 * a` calls the
// static V.scaled with the scalar first. Each call's result is an owned
// temporary, released at the end of its full expression.
class V
    {
    u8 x;
    V* plus(V* o) :operator(self + o) { return o; }
    V* neg() :operator(-self) { return self; }
    static V* scaled(u8 k, V* v) :operator(k * v) { return v; }
    }

    u8
    run(V* a, V* b)
    {
    V* c = a + b;
    V* d = -a;
    V* e = 2 * a;
    return c.x + d.x + e.x;
    }
