// f8_storage.xc — 8-bit float values held everywhere a value can be: locals,
// globals with initialisers, arrays, struct fields, a struct passed and
// returned by value and copied, a class's ivars, an Array<f8> (boxed as the
// float that holds the value exactly), a heap array from new, parameters and
// returns, and printf, which takes a small float as a double. Each pack is 1
// byte, aligned to 1. Every value is a short binary fraction, so each target
// prints the same digits.
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "Foundation.xc"

struct Trio
{
    f8 a;
    f8:pack(e5m2) b;
    f8:pack(ue8m0) s;
};

struct Mixed
{
    u8 tag;
    f8 w;
    u16 more;
    f8:pack(e5m2) g;
};

class Holder
{
    f8 v;
    f8:pack(e5m2) w;
    f8:pack(ue8m0) scale;
    void init(void)
    {
        v = 0.5;
        w = 3.0;
        scale = 0.125;
    }
    f8 get(void) { return v; }
}

f8 gW = 1.75;
f8:pack(e5m2) gG = -2.5;
f8:pack(ue8m0) gS = 1024;
f8 gTable[4] = {0.5, 0.25, -0.125, 448};

Trio swapTrio(Trio t)
{
    Trio q;
    q.a = (f8)t.b;
    q.b = (f8:pack(e5m2))t.a;
    q.s = t.s * t.s;
    return q;
}

f8:pack(e5m2) halfOf(f8:pack(e5m2) x) { return x / 2; }

f8 sumOf(f8* v, u32 n)
{
    f8 s = 0;
    for (u32 i = 0; i < n; i++)
        s += v[i];
    return s;
}

void plain(void)
{
    Stdio.printf("sizes %d %d %d\n", (i16)sizeof(f8), (i16)sizeof(f8:pack(ue8m0)), (i16)sizeof(Trio));
    Stdio.printf("globals %f %f %f\n", gW, gG, gS);
    Stdio.printf("table %f %f\n", gTable[0], gTable[1]);
    Stdio.printf("table %f %f\n", gTable[2], gTable[3]);
    gTable[2] = gTable[2] * 4;
    Stdio.printf("sum %f\n", sumOf(&gTable[0], 4));
    f8 local[3] = {1.5, 2.5, 3.5};
    local[1] = local[0] + local[2];
    Stdio.printf("local %f %f %f\n", local[0], local[1], local[2]);
}

void aggregates(void)
{
    Trio t;
    t.a = 1.5;
    t.b = 96.0;
    t.s = 4;
    Trio q = swapTrio(t);
    Trio r = q;
    r.a = r.a + 1;
    Stdio.printf("trio %f %f %f\n", q.a, q.b, q.s);
    Stdio.printf("copy %f %f\n", r.a, r.b);
    Mixed m = {7, 0.75, 9, 6.0};
    Stdio.printf("mixed %d %f %d %f\n", (i16)m.tag, m.w, (i16)m.more, m.g);
    Stdio.printf("half %f\n", halfOf((f8:pack(e5m2))7.0));
    f64 wd = t.b;
    Stdio.printf("widen %f\n", wd);
}

void objects(void)
{
    Holder* h = new Holder();
    h.v = h.v * 3;
    Stdio.printf("ivar %f %f %f\n", h.get(), h.w, h.scale);
    Array<f8>* arr = new Array();
    arr.add((f8)1.25);
    arr.add((f8)2.5);
    f8 second = arr.get(1);
    Stdio.printf("Array<f8> %d %f %f\n", (i16)arr.count(), arr.get(0), second);
    f8* heap = new f8[4];
    for (u32 i = 0; i < 4; i++)
        heap[i] = (f8)i * 0.5;
    Stdio.printf("heap %f %f\n", heap[3], heap[1]);
    delete heap;
    f32 widened = second;
    Stdio.printf("widen %f\n", (f64)widened);
}

i32 main(void)
{
    plain();
    aggregates();
    objects();
    return 0;
}
