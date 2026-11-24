// The MODULE half for operators of a class's own shape: `**` above `*` and
// grouping from the right, `⊗` from the Unicode block, and the brackets `|p|`
// and `⌈p⌉`. The shapes and the
// precedence travel in the .xtc.iface, so use-opshape.xc parses them as this
// module does.
class Pw
    {
    i32 v;
    static Pw* of(i32 x)
        {
        Pw* p = new Pw();
        p.v = x;
        return p;
        }
    Pw* raise(Pw* e) :operator(self ** e) :precedence(above *, right)
        {
        return Pw.of(v + e.v);
        }
    static Pw* scaled(i32 k, Pw* p) :operator(k * p)
        {
        return Pw.of(k * p.v);
        }
    Pw* kron(Pw* o) :operator(self ⊗ o)
        {
        return Pw.of(v * 100 + o.v);
        }
    i32 size() :operator(|self|)
        {
        return v < 0 ? 0 - v : v;
        }
    static i32 up(Pw* p) :operator(⌈p⌉)
        {
        return p.v + 1;
        }
    }
