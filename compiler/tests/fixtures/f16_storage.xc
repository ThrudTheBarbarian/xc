// f16_storage.xc — f16 and bf16 values held everywhere a value can be: locals,
// globals, arrays, struct fields, a struct passed and returned by value and
// copied, a class's ivars, an Array<f16> (boxed as the float that holds the
// value exactly), a heap array from new, parameters and returns, and printf,
// which takes a 16-bit float as a double. Each type is 2 bytes, aligned as
// u16 is on the target. Every value is a short binary fraction, so each target
// prints the same digits.
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "Foundation.xc"

struct Pair
{
    f16 a;
    bf16 b;
};

struct Mixed
{
    u8 tag;
    f16 h;
    u8 more;
    bf16 g;
};

class Holder
{
    f16 v;
    bf16 w;
    void init(void)
    {
        v = 0.5;
        w = 3.0;
    }
    f16 get(void) { return v; }
}

f16 gHalf = 1.75;
bf16 gBrain = -2.5;
f16 gTable[4] = {0.5, 0.25, -0.125, 1024};

Pair swapPair(Pair p)
{
    Pair q;
    q.a = (f16)p.b;
    q.b = (bf16)p.a;
    return q;
}

bf16 halfOf(bf16 x) { return x / 2; }

f16 sumOf(f16* v, u32 n)
{
    f16 s = 0;
    for (u32 i = 0; i < n; i++)
        s += v[i];
    return s;
}

void plain(void)
{
    Stdio.printf("sizes %d %d %d\n", (i16)sizeof(f16), (i16)sizeof(bf16), (i16)sizeof(Pair));
    Stdio.printf("globals %f %f\n", gHalf, gBrain);
    Stdio.printf("table %f %f\n", gTable[0], gTable[1]);
    Stdio.printf("table %f %f\n", gTable[2], gTable[3]);
    gTable[2] = gTable[2] * 4;
    Stdio.printf("sum %f\n", sumOf(&gTable[0], 4));

    f16 local[3] = {1.5, 2.5, 3.5};
    local[1] = local[0] + local[2];
    Stdio.printf("local %f %f %f\n", local[0], local[1], local[2]);

}

void aggregates(void)
{
    Pair p;
    p.a = 1.5;
    p.b = 100.0;
    Pair q = swapPair(p);
    Pair r = q;
    r.a = r.a + 1;
    Stdio.printf("pair %f %f\n", q.a, q.b);
    Stdio.printf("copy %f %f\n", r.a, r.b);
    Mixed m = {7, 0.75, 9, 6.5};
    Stdio.printf("mixed %d %f %d %f\n", (i16)m.tag, m.h, (i16)m.more, m.g);

    Stdio.printf("half %f\n", halfOf((bf16)7.0));
    f64 wd = p.b;
    Stdio.printf("widen %f\n", wd);
}

void objects(void)
{
    Holder* h = new Holder();
    h.v = h.v * 3;
    Stdio.printf("ivar %f %f\n", h.get(), h.w);

    Array<f16>* arr = new Array();
    arr.add((f16)1.25);
    arr.add((f16)2.5);
    f16 second = arr.get(1);
    Stdio.printf("Array<f16> %d %f %f\n", (i16)arr.count(), arr.get(0), second);

    f16* heap = new f16[4];
    for (u32 i = 0; i < 4; i++)
        heap[i] = (f16)i * 0.5;
    Stdio.printf("heap %f %f\n", heap[3], heap[1]);
    delete heap;

    f32 widened = second;
    Stdio.printf("widen %f\n", widened);
}

i32 main(void)
{
    plain();
    aggregates();
    objects();
    return 0;
}
