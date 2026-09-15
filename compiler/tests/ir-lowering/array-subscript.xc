// array-subscript — subscripting a value-typed array LOCAL.
//
// `u8 a[4];` is an aggregate, so it gets a pinned frame slot (like a
// struct local). `a[0] = …` / `a[i]` decay `a` to a pointer to its
// first element (AddrOf %a as Ptr(U8)) and ElementAddr by the index.
// u8 elements → element size 1, so it runs on both backends. Written
// then read to avoid the aggregate-initialiser gap. 10 + 32 = 42.
u8 sa(void)
    {
    u8 a[4];
    a[0] = (u8)10;
    a[1] = (u8)32;
    u8 i = (u8)1;
    return a[0] + a[i]; // 42
    }
