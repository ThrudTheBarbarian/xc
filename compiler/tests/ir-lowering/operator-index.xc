// operator-index — index and compound operators lower to the method calls
// they resolved to: `v[i]` calls V.at, `v[i] = x` calls V.put, `v[i] += x`
// calls at then put with the base and index evaluated once, first, and
// `v += w` calls V.addIn. `p -= q` on a class with only `-` is `p = p - q`.
class V
    {
    u8 items[4];
    u8 at(u8 i) :operator(self[i]) { return items[i]; }
    void put(u8 i, u8 x) :operator(self[i] = x) { items[i] = x; }
    void addIn(V* o) :operator(self += o) { }
    V* minus(V* o) :operator(self - o) { return o; }
    }

V* pick(V* a)
    {
    return a;
    }

    u8
    run(V* a, V* b, u8 i)
    {
    a[i] = 3;
    u8 r = a[i + 1];
    pick(a)[i] += 2;
    a += b;
    a -= b;
    return r;
    }
