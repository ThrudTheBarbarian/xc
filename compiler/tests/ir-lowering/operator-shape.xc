// operator-shape — an operator of a class's own shape lowers to the method
// call it resolved to, as a built-in operator's overload does: `a ** b` calls
// V.pow, `a ⊗ b` V.kron and `√a` V.root. Where `**` also reads the old way,
// `x**p` on an integer and a pointer is still `x * *p`.
class V
    {
    u8 x;
    V* pow(V* o) :operator(self ** o) :precedence(above *, right) { return o; }
    V* kron(V* o) :operator(self ⊗ o) { return self; }
    V* root() :operator(√self) { return self; }
    }

    u8
    run(V* a, V* b, u8 x, u8* p)
    {
    V* c = a ** b;
    V* d = a ⊗ b;
    V* e = √a;
    return c.x + d.x + e.x + x**p;
    }
