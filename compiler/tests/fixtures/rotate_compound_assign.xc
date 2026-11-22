//xtc-na: xt6502, m68k — prints 32- and 64-bit values through %ld
// Rotate-assignment (`x <:= n`, `x :>= n`) on every left side a compound
// assignment takes: locals, a pinned local, globals, array and pointer
// elements, fields of struct elements, ivars named bare, a static ivar and
// ivars reached through self or a class pointer. The rotate happens at the
// left side's width. The count is taken as a u8 and masked to the width, so a
// count of 0 or of the width leaves the value as it was. Counts are constants
// and variables of several types. An index with a side effect is evaluated
// once; `calls` would double if it were evaluated twice.
#use Stdio

u8 g8;
u16 g16;
u32 g32;
u64 g64;
i8 gi8;
i32 gi32;
u32 gw[4];
u64 gq[3];
u32 calls;

struct P
{
    u8 a;
    u16 b;
    u32 c;
    u64 d;
    i16 e;
}

P ps[3];

// Returns its argument and counts the call.
u32 at(u32 i)
{
    calls = calls + 1;
    return i;
}

class Rot
{
    u8 a;
    u16 b;
    u32 c;
    u64 d;
    i32 e;
    static u32 s;

    void bare(u8 k, u32 kw)
    {
        a = $81;
        b = $8001;
        c = $80000001;
        d = $8000000000000001;
        e = -2;
        s = $F000000F;
        a <:= 1;    Stdio.printf("ivar u8 <:= 1 %ld\n", (i64)a);
        a :>= k;    Stdio.printf("ivar u8 :>= k %ld\n", (i64)a);
        b <:= 12;   Stdio.printf("ivar u16 <:= 12 %ld\n", (i64)b);
        b :>= kw;   Stdio.printf("ivar u16 :>= kw %ld\n", (i64)b);
        c <:= 31;   Stdio.printf("ivar u32 <:= 31 %ld\n", (i64)c);
        c :>= kw;   Stdio.printf("ivar u32 :>= kw %ld\n", (i64)c);
        d <:= 40;   Stdio.printf("ivar u64 <:= 40 %lx\n", d);
        d :>= k;    Stdio.printf("ivar u64 :>= k %lx\n", d);
        e :>= 1;    Stdio.printf("ivar i32 :>= 1 %ld\n", (i64)e);
        e <:= k;    Stdio.printf("ivar i32 <:= k %ld\n", (i64)e);
        s <:= 4;    Stdio.printf("static u32 <:= 4 %ld\n", (i64)s);
        s :>= kw;   Stdio.printf("static u32 :>= kw %ld\n", (i64)s);
    }

    void viaSelf(u8 k, u32 kw)
    {
        self.a <:= 3;   Stdio.printf("self u8 <:= 3 %ld\n", (i64)self.a);
        self.b :>= k;   Stdio.printf("self u16 :>= k %ld\n", (i64)self.b);
        self.c <:= kw;  Stdio.printf("self u32 <:= kw %ld\n", (i64)self.c);
        self.d :>= 64;  Stdio.printf("self u64 :>= 64 %lx\n", self.d);
        self.d :>= 1;   Stdio.printf("self u64 :>= 1 %lx\n", self.d);
        self.e <:= 0;   Stdio.printf("self i32 <:= 0 %ld\n", (i64)self.e);
        self.e :>= kw;  Stdio.printf("self i32 :>= kw %ld\n", (i64)self.e);
    }
}

void locals(u8 k, u32 kw, i32 ks)
{
    u8 a = $81;
    a <:= 1;    Stdio.printf("u8 <:= 1 %ld\n", (i64)a);
    a <:= 0;    Stdio.printf("u8 <:= 0 %ld\n", (i64)a);
    a :>= 3;    Stdio.printf("u8 :>= 3 %ld\n", (i64)a);
    a <:= 8;    Stdio.printf("u8 <:= 8 %ld\n", (i64)a);
    a :>= 11;   Stdio.printf("u8 :>= 11 %ld\n", (i64)a);
    a <:= k;    Stdio.printf("u8 <:= k %ld\n", (i64)a);
    a :>= kw;   Stdio.printf("u8 :>= kw %ld\n", (i64)a);
    a <:= ks;   Stdio.printf("u8 <:= ks %ld\n", (i64)a);

    u16 b = $8001;
    b <:= 4;    Stdio.printf("u16 <:= 4 %ld\n", (i64)b);
    b :>= 15;   Stdio.printf("u16 :>= 15 %ld\n", (i64)b);
    b <:= 16;   Stdio.printf("u16 <:= 16 %ld\n", (i64)b);
    b :>= k;    Stdio.printf("u16 :>= k %ld\n", (i64)b);
    b <:= kw;   Stdio.printf("u16 <:= kw %ld\n", (i64)b);

    u32 c = $80000001;
    c <:= 1;    Stdio.printf("u32 <:= 1 %ld\n", (i64)c);
    c :>= 4;    Stdio.printf("u32 :>= 4 %ld\n", (i64)c);
    c <:= 31;   Stdio.printf("u32 <:= 31 %ld\n", (i64)c);
    c :>= 32;   Stdio.printf("u32 :>= 32 %ld\n", (i64)c);
    c <:= 37;   Stdio.printf("u32 <:= 37 %ld\n", (i64)c);
    c <:= k;    Stdio.printf("u32 <:= k %ld\n", (i64)c);
    c :>= kw;   Stdio.printf("u32 :>= kw %ld\n", (i64)c);
    c <:= ks;   Stdio.printf("u32 <:= ks %ld\n", (i64)c);

    u64 d = $8000000000000001;
    d <:= 1;    Stdio.printf("u64 <:= 1 %lx\n", d);
    d :>= 8;    Stdio.printf("u64 :>= 8 %lx\n", d);
    d <:= 63;   Stdio.printf("u64 <:= 63 %lx\n", d);
    d :>= 64;   Stdio.printf("u64 :>= 64 %lx\n", d);
    d <:= 70;   Stdio.printf("u64 <:= 70 %lx\n", d);
    d <:= k;    Stdio.printf("u64 <:= k %lx\n", d);
    d :>= kw;   Stdio.printf("u64 :>= kw %lx\n", d);
    d <:= ks;   Stdio.printf("u64 <:= ks %lx\n", d);

    i8 e = -127;
    e <:= 1;    Stdio.printf("i8 <:= 1 %ld\n", (i64)e);
    e :>= 2;    Stdio.printf("i8 :>= 2 %ld\n", (i64)e);
    e :>= k;    Stdio.printf("i8 :>= k %ld\n", (i64)e);

    i32 f = -2;
    f :>= 1;    Stdio.printf("i32 :>= 1 %ld\n", (i64)f);
    f <:= 5;    Stdio.printf("i32 <:= 5 %ld\n", (i64)f);
    f <:= kw;   Stdio.printf("i32 <:= kw %ld\n", (i64)f);

    // A local whose address is taken lives in memory.
    u32 p = $12345678;
    u32* pp = &p;
    p <:= 8;    Stdio.printf("pinned <:= 8 %ld\n", (i64)p);
    p :>= kw;   Stdio.printf("pinned :>= kw %ld %ld\n", (i64)p, (i64)*pp);
}

void globals(u8 k, u32 kw)
{
    g8 = $81;
    g16 = $8001;
    g32 = $80000001;
    g64 = $8000000000000001;
    gi8 = -127;
    gi32 = -2;
    g8 <:= 1;       Stdio.printf("g u8 <:= 1 %ld\n", (i64)g8);
    g8 :>= k;       Stdio.printf("g u8 :>= k %ld\n", (i64)g8);
    g16 <:= 9;      Stdio.printf("g u16 <:= 9 %ld\n", (i64)g16);
    g16 :>= kw;     Stdio.printf("g u16 :>= kw %ld\n", (i64)g16);
    g32 <:= 4;      Stdio.printf("g u32 <:= 4 %ld\n", (i64)g32);
    g32 :>= 0;      Stdio.printf("g u32 :>= 0 %ld\n", (i64)g32);
    g32 :>= kw;     Stdio.printf("g u32 :>= kw %ld\n", (i64)g32);
    g64 <:= 4;      Stdio.printf("g u64 <:= 4 %lx\n", g64);
    g64 :>= kw;     Stdio.printf("g u64 :>= kw %lx\n", g64);
    gi8 :>= 1;      Stdio.printf("g i8 :>= 1 %ld\n", (i64)gi8);
    gi8 <:= kw;     Stdio.printf("g i8 <:= kw %ld\n", (i64)gi8);
    gi32 <:= 31;    Stdio.printf("g i32 <:= 31 %ld\n", (i64)gi32);
    gi32 :>= k;     Stdio.printf("g i32 :>= k %ld\n", (i64)gi32);
}

void elements(u8 k, u32 kw)
{
    calls = 0;
    gw[1] = $80000001;
    gw[2] = $0000FFFF;
    gw[at(1)] <:= 4;    Stdio.printf("gw[1] <:= 4 %ld\n", (i64)gw[1]);
    gw[at(1)] :>= kw;   Stdio.printf("gw[1] :>= kw %ld\n", (i64)gw[1]);
    gw[at(2)] :>= 8;    Stdio.printf("gw[2] :>= 8 %ld\n", (i64)gw[2]);
    gq[0] = $0123456789ABCDEF;
    gq[at(0)] <:= 12;   Stdio.printf("gq[0] <:= 12 %lx\n", gq[0]);
    gq[at(0)] :>= k;    Stdio.printf("gq[0] :>= k %lx\n", gq[0]);

    u16 lh[3];
    lh[2] = $8001;
    lh[at(2)] <:= 1;    Stdio.printf("lh[2] <:= 1 %ld\n", (i64)lh[2]);
    lh[at(2)] :>= kw;   Stdio.printf("lh[2] :>= kw %ld\n", (i64)lh[2]);

    u32* q = &gw[0];
    *q = $000000F1;
    *q <:= 28;          Stdio.printf("@q <:= 28 %ld\n", (i64)gw[0]);
    q[at(3)] = 1;
    q[at(3)] :>= 1;     Stdio.printf("q[3] :>= 1 %ld\n", (i64)gw[3]);
    Stdio.printf("element calls %ld\n", (i64)calls);

    calls = 0;
    ps[1].a = $81;
    ps[1].b = $8001;
    ps[1].c = $80000001;
    ps[2].d = $8000000000000001;
    ps[0].e = -32767;
    ps[at(1)].a <:= 2;      Stdio.printf("ps[1].a <:= 2 %ld\n", (i64)ps[1].a);
    ps[at(1)].a :>= k;      Stdio.printf("ps[1].a :>= k %ld\n", (i64)ps[1].a);
    ps[at(1)].b :>= 4;      Stdio.printf("ps[1].b :>= 4 %ld\n", (i64)ps[1].b);
    ps[at(1)].c <:= kw;     Stdio.printf("ps[1].c <:= kw %ld\n", (i64)ps[1].c);
    ps[at(2)].d <:= 33;     Stdio.printf("ps[2].d <:= 33 %lx\n", ps[2].d);
    ps[at(2)].d :>= kw;     Stdio.printf("ps[2].d :>= kw %lx\n", ps[2].d);
    ps[at(0)].e <:= 1;      Stdio.printf("ps[0].e <:= 1 %ld\n", (i64)ps[0].e);
    ps[at(0)].e :>= 3;      Stdio.printf("ps[0].e :>= 3 %ld\n", (i64)ps[0].e);
    Stdio.printf("field calls %ld\n", (i64)calls);

    P s;
    s.c = $00F0000F;
    s.c <:= 8;              Stdio.printf("s.c <:= 8 %ld\n", (i64)s.c);
    P* sp = &ps[1];
    sp[at(0)].b <:= 3;      Stdio.printf("sp[0].b <:= 3 %ld\n", (i64)ps[1].b);
    (*sp).c :>= 16;         Stdio.printf("(@sp).c :>= 16 %ld\n", (i64)ps[1].c);
}

void main(void)
{
    locals(5, 13, 7);
    globals(5, 13);
    elements(5, 13);
    Rot* r = new Rot();
    r.bare(5, 13);
    r.viaSelf(5, 13);
    r.c <:= 4;      Stdio.printf("r.c <:= 4 %ld\n", (i64)r.c);
    r.a :>= 9;      Stdio.printf("r.a :>= 9 %ld\n", (i64)r.a);
}
