// operator-protocol — an operator a protocol requires lowers, on a value typed
// as the protocol, to the call through the protocol that `a.plus(b)` makes:
// `a + b` calls P.plus, `a[i]` P.at, `a[i] = v` P.put and `|a|` P.size.
protocol P
    {
    P* plus(P* o) :operator(self + o);
    u8 at(u8 i) :operator(self[i]);
    void put(u8 i, u8 v) :operator(self[i] = v);
    u8 size() :operator(|self|);
    }

class V <P>
    {
    u8 x;
    P* plus(P* o) :operator(self + o) { return self; }
    u8 at(u8 i) :operator(self[i]) { return x + i; }
    void put(u8 i, u8 v) :operator(self[i] = v) { x = i + v; }
    u8 size() :operator(|self|) { return x; }
    }

    u8
    run(P* a, P* b, u8 i)
    {
    a[i] = 3;
    return (a + b)[i] + |b|;
    }
