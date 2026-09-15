// struct-param — value-typed struct PARAMETER passed by value.
//
// `sumpt(Point p)` takes a struct by value: the param `p` is an
// aggregate, so member reads (`p.x`, `p.y`) must resolve through its
// address. The param value-id already gets a backend slot (the
// prologue allocates + spills every param), so it's registered as a
// pinned local — member access becomes AddrOf %p + FieldAddr + Load.
//
// `sp()` builds a struct local `q`, then calls `sumpt(q)`: the caller
// pushes q's bytes by value (AddrOf %q + Load(Agg) + Call). 40 + 2 = 42.
struct Point
    {
    u16 x;
    u16 y;
    }

    u16
    sumpt(Point p)
    {
    return p.x + p.y;
    }

u16 sp(void)
    {
    Point q;
    q.x = (u16)40;
    q.y = (u16)2;
    return sumpt(q); // 42
    }
