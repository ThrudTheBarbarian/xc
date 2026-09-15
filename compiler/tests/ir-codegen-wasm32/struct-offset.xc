// Recorded struct offsets (type-width invariant): the FE lays out once at
// cap 8 and the backend reads layout.fields[i].byteOffset verbatim. A width
// disagreement shows up as a wrong ADDRESS, so every mixed-width field is
// written then read back.
extern void putw(i32 v);

// sizeof 32
struct Mix
    {
    u8 a;     // @0
    i32 b;    // @4
    u16 c;    // @8
    double d; // @16
    u8 e;     // @24
    }

    void main(void)
    {
    Mix m;
    m.a = 7;
    m.b = 123456;
    m.c = 999;
    m.d = 2.5;
    m.e = 42;
    putw(m.a);
    putw(m.b);
    putw(m.c);
    putw((i32)m.d); // 2 (truncating float→int)
    putw(m.e);
    }
