// An array operand of `+` or `-` decays to a pointer to its element, as in C:
// `b + 1` is `&b[1]`. The array's address was added as a narrow integer
// instead, so `put(b + 1, 7)` crashed at -O0 and failed to assemble at -O2 on
// arm64 (#516). Global, local and struct-field arrays, the array on either
// side, chained offsets, a variable offset, a dereference and a subscript of
// the sum, and the pointer difference with an array operand.
#import "Stdio.xc"

struct Holder
    {
    u32 pad;
    u32 a[8];
    };

u32 g[8];
u16 h[6];
u8 bytes[5];
Holder st;

void put(u32* p, u32 v)
{
    p[0] = v;
}

void put16(u16* p, u16 v)
{
    p[0] = v;
}

void check(string what, bool ok)
{
    Stdio.printf("%s %s\n", what, ok ? "ok" : "wrong");
}

void main(void)
{
    put(g + 1, (u32)7);
    check("global argument", g[1] == (u32)7);

    u32* q = g + 2;
    q[0] = (u32)8;
    check("global initialiser", g[2] == (u32)8);

    put(3 + g, (u32)9);
    check("integer on the left", g[3] == (u32)9);

    put(g - 1 + 5, (u32)10);
    check("chained offsets", g[4] == (u32)10);

    i32 k = 5;
    put(g + k, (u32)11);
    check("variable offset", g[5] == (u32)11);

    *(g + 6) = (u32)12;
    check("dereference", g[6] == (u32)12 && *(g + 6) == (u32)12);

    (g + 7)[0] = (u32)13;
    check("subscript of the sum", g[7] == (u32)13);

    u32* p5 = &g[5];
    check("pointer minus array", p5 - g == 5);
    check("array minus pointer", g - p5 == -5);

    u32 loc[4];
    put(loc + 2, (u32)14);
    u32* lq = loc + 3;
    lq[0] = (u32)15;
    check("local array", loc[2] == (u32)14 && loc[3] == (u32)15);

    put(st.a + 1, (u32)16);
    check("struct field array", st.a[1] == (u32)16);

    put16(h + 4, (u16)17);
    check("u16 array", h[4] == (u16)17);

    u8* bp = bytes + 3;
    bp[0] = (u8)18;
    check("u8 array", bytes[3] == (u8)18);
    return;
}
