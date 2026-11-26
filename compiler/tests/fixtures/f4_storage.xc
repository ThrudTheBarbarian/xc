// f4_storage.xc — f4 arrays, two elements to a byte with element 0 in the
// low nibble: globals and locals of odd and even length, a heap array from
// new, an f4 array in a struct and in a class, an Array<f4>. Each element is
// written and read back, its neighbours are checked untouched, the bytes are
// dumped, and sizeof gives ceil(n / 2). Compound assignment and ++ rewrite
// one nibble, for-in and a slice walk the elements, a fixed array passes to
// an f4[] parameter, and an f4 scalar's address is an f4[] of one element.
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "Foundation.xc"

struct Row
{
    u8 tag;
    f4 w[5];
    u8 end;
};

class Bank
{
    u8 id;
    f4 cells[6];
    u8 last;
}

f4 g7[7];
f4 g8[8];

void dump(u8* p, u32 n)
{
    for (u32 i = 0; i < n; i++)
        Stdio.printf("%x ", (u16)p[i]);
    Stdio.printf("\n");
}

// Element i of a set to v: every other element must keep its value.
u32 lone(f4[] a, u32 n, u32 i, f4 v)
{
    for (u32 k = 0; k < n; k++)
        a[k] = 1.5;
    a[i] = v;
    u32 bad = 0;
    for (u32 k = 0; k < n; k++)
        {
        f4 want = k == i ? v : (f4)1.5;
        if (a[k] != want)
            bad++;
        }
    return bad;
}

u32 sweep(f4[] a, u32 n)
{
    u32 bad = 0;
    for (u32 i = 0; i < n; i++)
        bad = bad + lone(a, n, i, -6.0);
    return bad;
}

f32 sum(f4[] a, u32 n)
{
    f32 s = 0.0;
    for (u32 i = 0; i < n; i++)
        s = s + a[i];
    return s;
}

void setOut(f4[] out, f4 v)
{
    out[0] = v;
}

void globals(void)
{
    for (u32 i = 0; i < 7; i++)
        g7[i] = (f4)(f32)i;
    for (u32 i = 0; i < 8; i++)
        g8[i] = (f4)((f32)i * -0.5);
    dump((u8*)g7, 4);
    dump((u8*)g8, 4);
    Stdio.printf("sizes %d %d %d\n", (i16)sizeof(g7), (i16)sizeof(g8), (i16)sizeof(Row));
    Stdio.printf("len %d %d\n", (i16)g7.length, (i16)g8.length);
    Stdio.printf("sweep %d %d\n", (i16)sweep(g7, 7), (i16)sweep(g8, 8));
}

void zero(u8* p, u32 n)
{
    for (u32 i = 0; i < n; i++)
        p[i] = 0;
}

void locals(void)
{
    f4 a[5];
    f4 b[4];
    zero((u8*)a, 3);
    for (u32 i = 0; i < 5; i++)
        a[i] = (f4)(f32)i;
    for (u32 i = 0; i < 4; i++)
        b[i] = (f4)((f32)i + 0.5);
    dump((u8*)a, 3);
    dump((u8*)b, 2);
    a[2] += 1.0;
    a[3] = -a[3];
    a[0]++;
    b[1] *= 4.0;
    dump((u8*)a, 3);
    dump((u8*)b, 2);
    Stdio.printf("sum %f %f\n", sum(a, 5), sum(b, 4));
    Stdio.printf("sweep %d %d\n", (i16)sweep(a, 5), (i16)sweep(b, 4));
}

void walks(void)
{
    f4 a[7];
    for (u32 i = 0; i < 7; i++)
        a[i] = (f4)((f32)i - 3.0);
    for (f4 v in a)
        Stdio.printf("%f ", v);
    Stdio.printf("\n");
    for (f4 v in a[2..5])
        Stdio.printf("%f ", v);
    Stdio.printf("\n");
}

void heap(void)
{
    f4[] h = new f4[9];
    for (u32 i = 0; i < 9; i++)
        h[i] = (f4)((f32)i * 0.5);
    dump((u8*)h, 5);
    Stdio.printf("hlen %d\n", (i16)h.length);
    Stdio.printf("sweep %d\n", (i16)sweep(h, 9));
    delete h;
}

void aggregates(void)
{
    Row r;
    zero((u8*)&r, 5);
    r.tag = 170;
    r.end = 187;
    r.w[4] = 6.0;
    r.w[0] = 0.5;
    r.w[1] = -1.0;
    dump((u8*)&r, 5);
    Bank* k = new Bank();
    k.id = 1;
    k.last = 2;
    for (u32 i = 0; i < 6; i++)
        k.cells[i] = (f4)(f32)i;
    k.cells[3] += 1.0;
    Stdio.printf("bank %f %f %f\n", k.cells[0], k.cells[3], k.cells[5]);
    Stdio.printf("id %d %d\n", (i16)k.id, (i16)k.last);
}

void scalars(void)
{
    f4 x = 2.0;
    setOut(&x, 3.0);
    f4 c[3];
    setOut(&c[0], -0.5);
    Stdio.printf("x %f c %f\n", x, c[0]);
    Array<f4>* l = new Array();
    l.add(c[0]);
    l.add(x);
    f4 front = l.get(0);
    f4 back = l.get(1);
    Stdio.printf("array %f %f\n", front, back);
}

i32 main(void)
{
    globals();
    locals();
    walks();
    heap();
    aggregates();
    scalars();
    return 0;
}
