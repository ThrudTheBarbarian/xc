//xtc-na: xt6502, m68k — prints 32- and 64-bit values through %ld
// A compound assignment to a field of an array element (`a[i].f op= x`):
// every operator, on fields of elements of a global and a local struct array
// and through a pointer, at several field widths and signedness, on a class
// ivar reached through an array of class pointers, and nested as
// `a[i].b[j].c op= x`. The element's base is formed once, so `a[at(i)].f += 1`
// calls at() once; `calls` would double if the index were evaluated twice.
#use Stdio

struct S
{
    u8 a;
    i16 b;
    u32 c;
    i64 d;
    double e;
}

struct In
{
    i32 c;
    u8 m;
}

struct Out
{
    i16 k;
    In b[3];
}

struct Arr
{
    i32 v[4];
}

class Box
{
    i32 n;
    u8 m;
}

S gs[4];
Out go[3];
Arr ga[2];
Box* objs[2];
u32 calls;
u32 cursor;

// Returns its argument and counts the call.
u32 at(u32 i)
{
    calls = calls + 1;
    return i;
}

// Moves the cursor on and returns its new position.
u32 bump(void)
{
    cursor = cursor + 1;
    return cursor;
}

void main(void)
{
    // u8 field, global array: computed at u8, so it wraps.
    calls = 0;
    gs[1].a = 250;
    gs[at(1)].a += 10;      Stdio.printf("u8 += %ld\n", (i64)gs[1].a);
    gs[at(1)].a -= 5;       Stdio.printf("u8 -= %ld\n", (i64)gs[1].a);
    gs[at(1)].a *= 3;       Stdio.printf("u8 *= %ld\n", (i64)gs[1].a);
    gs[at(1)].a /= 7;       Stdio.printf("u8 /= %ld\n", (i64)gs[1].a);
    gs[at(1)].a %= 5;       Stdio.printf("u8 %%= %ld\n", (i64)gs[1].a);
    gs[at(1)].a |= $F0;     Stdio.printf("u8 |= %ld\n", (i64)gs[1].a);
    gs[at(1)].a &= $3C;     Stdio.printf("u8 &= %ld\n", (i64)gs[1].a);
    gs[at(1)].a ^= $FF;     Stdio.printf("u8 ^= %ld\n", (i64)gs[1].a);
    gs[at(1)].a <<= 2;      Stdio.printf("u8 <<= %ld\n", (i64)gs[1].a);
    gs[at(1)].a >>= 3;      Stdio.printf("u8 >>= %ld\n", (i64)gs[1].a);
    Stdio.printf("u8 calls %ld\n", (i64)calls);

    // i16 field, global array.
    calls = 0;
    gs[2].b = -1000;
    gs[at(2)].b += 300;     Stdio.printf("i16 += %ld\n", (i64)gs[2].b);
    gs[at(2)].b -= 32000;   Stdio.printf("i16 -= %ld\n", (i64)gs[2].b);
    gs[at(2)].b -= 100;     Stdio.printf("i16 -= %ld\n", (i64)gs[2].b);
    gs[at(2)].b *= 2;       Stdio.printf("i16 *= %ld\n", (i64)gs[2].b);
    gs[at(2)].b /= 5;       Stdio.printf("i16 /= %ld\n", (i64)gs[2].b);
    gs[at(2)].b %= 5;       Stdio.printf("i16 %%= %ld\n", (i64)gs[2].b);
    gs[at(2)].b &= $0FF0;   Stdio.printf("i16 &= %ld\n", (i64)gs[2].b);
    gs[at(2)].b ^= $00FF;   Stdio.printf("i16 ^= %ld\n", (i64)gs[2].b);
    gs[at(2)].b <<= 4;      Stdio.printf("i16 <<= %ld\n", (i64)gs[2].b);
    gs[at(2)].b >>= 2;      Stdio.printf("i16 >>= %ld\n", (i64)gs[2].b);
    gs[at(2)].b |= 3;       Stdio.printf("i16 |= %ld\n", (i64)gs[2].b);
    Stdio.printf("i16 calls %ld\n", (i64)calls);

    // u32 field, local array.
    S ls[3];
    calls = 0;
    ls[2].c = 4000000000;
    ls[at(2)].c += 500000000;   Stdio.printf("u32 += %ld\n", (i64)ls[2].c);
    ls[at(2)].c -= 205032705;   Stdio.printf("u32 -= %ld\n", (i64)ls[2].c);
    ls[at(2)].c *= 3;           Stdio.printf("u32 *= %ld\n", (i64)ls[2].c);
    ls[at(2)].c /= 10;          Stdio.printf("u32 /= %ld\n", (i64)ls[2].c);
    ls[at(2)].c %= 1000;        Stdio.printf("u32 %%= %ld\n", (i64)ls[2].c);
    ls[at(2)].c |= $10000;      Stdio.printf("u32 |= %ld\n", (i64)ls[2].c);
    ls[at(2)].c &= $1F0F0;      Stdio.printf("u32 &= %ld\n", (i64)ls[2].c);
    ls[at(2)].c ^= $FFFFFFFF;   Stdio.printf("u32 ^= %ld\n", (i64)ls[2].c);
    ls[at(2)].c >>= 20;         Stdio.printf("u32 >>= %ld\n", (i64)ls[2].c);
    ls[at(2)].c <<= 24;         Stdio.printf("u32 <<= %ld\n", (i64)ls[2].c);
    Stdio.printf("u32 calls %ld\n", (i64)calls);

    // i64 field through a pointer into the global array, variable shift.
    S* p = &gs[0];
    u32 sh = 33;
    calls = 0;
    p[3].d = -7;
    p[at(3)].d *= 1000000007;   Stdio.printf("i64 *= %ld\n", p[3].d);
    p[at(3)].d += 3;            Stdio.printf("i64 += %ld\n", p[3].d);
    p[at(3)].d -= 9000000000;   Stdio.printf("i64 -= %ld\n", p[3].d);
    p[at(3)].d /= 4;            Stdio.printf("i64 /= %ld\n", p[3].d);
    p[at(3)].d %= 1000000;      Stdio.printf("i64 %%= %ld\n", p[3].d);
    p[at(3)].d <<= sh;          Stdio.printf("i64 <<= %ld\n", p[3].d);
    p[at(3)].d >>= 30;          Stdio.printf("i64 >>= %ld\n", p[3].d);
    p[at(3)].d |= 1;            Stdio.printf("i64 |= %ld\n", p[3].d);
    p[at(3)].d &= -16;          Stdio.printf("i64 &= %ld\n", p[3].d);
    p[at(3)].d ^= 255;          Stdio.printf("i64 ^= %ld\n", p[3].d);
    Stdio.printf("i64 gs[3].d %ld calls %ld\n", gs[3].d, (i64)calls);

    // double field, local array and pointer.
    calls = 0;
    ls[1].e = 2.5d;
    ls[at(1)].e += 1.25d;       Stdio.printf("double += %ld\n", (i64)(ls[1].e * 100.0d));
    ls[at(1)].e -= 0.5d;        Stdio.printf("double -= %ld\n", (i64)(ls[1].e * 100.0d));
    p[at(0)].e = 3.0d;
    p[at(0)].e *= 4.0d;         Stdio.printf("double *= %ld\n", (i64)(gs[0].e * 100.0d));
    p[at(0)].e /= 8.0d;         Stdio.printf("double /= %ld\n", (i64)(gs[0].e * 100.0d));
    Stdio.printf("double calls %ld\n", (i64)calls);

    // An index whose value changes on every call: read and store reach the
    // same element.
    cursor = 0;
    gs[0].c = 0; gs[1].c = 0; gs[2].c = 0; gs[3].c = 0;
    gs[bump()].c += 10;
    gs[bump()].c += 20;
    gs[bump()].c |= 7;
    Stdio.printf("bump %ld %ld %ld %ld cursor %ld\n", (i64)gs[0].c, (i64)gs[1].c, (i64)gs[2].c, (i64)gs[3].c, (i64)cursor);

    // Nested: a field of an element of a member array of an element.
    calls = 0;
    go[1].b[2].c = 100;
    go[1].b[2].m = 250;
    go[at(1)].b[at(2)].c += 5;      Stdio.printf("nested += %ld\n", (i64)go[1].b[2].c);
    go[at(1)].b[at(2)].c *= 3;      Stdio.printf("nested *= %ld\n", (i64)go[1].b[2].c);
    go[at(1)].b[at(2)].c -= 400;    Stdio.printf("nested -= %ld\n", (i64)go[1].b[2].c);
    go[at(1)].b[at(2)].m += 10;     Stdio.printf("nested u8 += %ld\n", (i64)go[1].b[2].m);
    go[at(1)].b[at(2)].m <<= 3;     Stdio.printf("nested u8 <<= %ld\n", (i64)go[1].b[2].m);
    go[at(2)].k = 7;
    go[at(2)].k ^= 5;               Stdio.printf("nested k %ld\n", (i64)go[2].k);
    Stdio.printf("nested calls %ld\n", (i64)calls);
    cursor = 0;
    go[bump()].b[at(1)].c += 1;
    go[bump()].b[at(1)].c += 2;
    Stdio.printf("nested bump %ld %ld %ld cursor %ld\n", (i64)go[1].b[2].c, (i64)go[1].b[1].c, (i64)go[2].b[1].c, (i64)cursor);

    // An element of a member array of an element.
    calls = 0;
    ga[1].v[2] = 9;
    ga[at(1)].v[at(2)] += 3;
    ga[at(1)].v[at(2)] *= 7;
    Stdio.printf("member array %ld calls %ld\n", (i64)ga[1].v[2], (i64)calls);

    // A dereferenced pointer to a struct.
    S* q = &ls[0];
    ls[0].b = 40;
    (*q).b += 2;
    (*q).b *= 3;
    Stdio.printf("deref %ld\n", (i64)ls[0].b);

    // Class ivars through an array of class pointers.
    objs[0] = new Box();
    objs[1] = new Box();
    calls = 0;
    objs[1].n = 5;
    objs[1].m = 200;
    objs[at(1)].n += 37;
    objs[at(1)].n *= 2;
    objs[at(1)].m += 100;
    objs[at(1)].m >>= 1;
    objs[at(0)].n -= 1;
    Stdio.printf("class %ld %ld %ld calls %ld\n", (i64)objs[1].n, (i64)objs[1].m, (i64)objs[0].n, (i64)calls);
}
