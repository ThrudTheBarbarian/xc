// tensor_expr.xc — element-wise tensor expressions. Every operator and Math
// function on each element type, checked element by element against the same
// scalar expression: a tensor expression computes each element under the
// scalar rules of its types, so an f16, bf16, f8 or f4 result rounds after
// every operation as scalar code does. Then broadcasting (a row, a column, a
// scalar, a rank below the other's), one long expression made one kernel,
// a new tensor against a write in place and a compound assignment,
// comparisons giving bool tensors, casts, views as operands (transposed,
// sliced, broadcast), f4 results of odd length and byte products long enough
// for whole vectors.
//xtc-na: xt6502 — tensors are not available there
#import "Stdio.xc"
#import "Math.xc"

u16 hb(f16 h) { return *(u16*)&h; }
u16 bb(bf16 g) { return *(u16*)&g; }
u8 eb(f8 e) { return *(u8*)&e; }
u8 e5b(f8:pack(e5m2) e) { return *(u8*)&e; }
u8 qb(f4 q) { f4[] p = &q; return *(u8*)p & 15; }

void report(u8* what, u32 bad)
{
    if (bad == 0)
        Stdio.printf("%s ok\n", what);
    else
        Stdio.printf("%s: %u wrong\n", what, bad);
}

void ints_i8(void)
{
    tensor<i8, 1> x = new tensor<i8, 1>(5);
    tensor<i8, 1> y = new tensor<i8, 1>(5);
    x[0] = (i8)100;
    y[0] = (i8)100;
    x[1] = (i8)(-7);
    y[1] = (i8)3;
    x[2] = (i8)33;
    y[2] = (i8)(-4);
    x[3] = (i8)(-128);
    y[3] = (i8)1;
    x[4] = (i8)5;
    y[4] = (i8)(-2);
    tensor<i8, 1> s = x + y;
    tensor<i8, 1> d = x - y;
    tensor<i8, 1> m = x * y;
    tensor<i8, 1> q = x / y;
    tensor<i8, 1> r = x % y;
    tensor<i8, 1> n = -x;
    tensor<i8, 1> k = x * 3 - 1;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> ge = x >= y;
    tensor<bool, 1> eq = x == y;
    tensor<bool, 1> ne = x != y;
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        i8 a = x[j];
        i8 b = y[j];
        i8 t3 = 3;
        i8 t1 = 1;
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || r[j] != a % b || n[j] != -a || k[j] != a * t3 - t1)
            bad++;
        if (lt[j] != (a < b) || ge[j] != (a >= b) || eq[j] != (a == b) || ne[j] != (a != b))
            bad++;
    }
    tensor<i8, 1> ab = Math.abs(x);
    for (u64 j = 0; j < 5; j++)
        if (ab[j] != Math.abs(x[j]))
            bad++;
    report("i8", bad);
    Stdio.printf("  %d %d %d %d %d\n", (i32)s[0], (i32)m[0], (i32)q[1], (i32)r[1], lt[0] ? 1 : 0);
}

void ints_u8(void)
{
    tensor<u8, 1> x = new tensor<u8, 1>(5);
    tensor<u8, 1> y = new tensor<u8, 1>(5);
    x[0] = (u8)250;
    y[0] = (u8)10;
    x[1] = (u8)7;
    y[1] = (u8)3;
    x[2] = (u8)33;
    y[2] = (u8)4;
    x[3] = (u8)128;
    y[3] = (u8)2;
    x[4] = (u8)5;
    y[4] = (u8)255;
    tensor<u8, 1> s = x + y;
    tensor<u8, 1> d = x - y;
    tensor<u8, 1> m = x * y;
    tensor<u8, 1> q = x / y;
    tensor<u8, 1> r = x % y;
    tensor<u8, 1> n = -x;
    tensor<u8, 1> k = x * 3 - 1;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> ge = x >= y;
    tensor<bool, 1> eq = x == y;
    tensor<bool, 1> ne = x != y;
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        u8 a = x[j];
        u8 b = y[j];
        u8 t3 = 3;
        u8 t1 = 1;
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || r[j] != a % b || n[j] != -a || k[j] != a * t3 - t1)
            bad++;
        if (lt[j] != (a < b) || ge[j] != (a >= b) || eq[j] != (a == b) || ne[j] != (a != b))
            bad++;
    }
    report("u8", bad);
    Stdio.printf("  %d %d %d %d %d\n", (i32)s[0], (i32)m[0], (i32)q[1], (i32)r[1], lt[0] ? 1 : 0);
}

void ints_i16(void)
{
    tensor<i16, 1> x = new tensor<i16, 1>(5);
    tensor<i16, 1> y = new tensor<i16, 1>(5);
    x[0] = (i16)30000;
    y[0] = (i16)30000;
    x[1] = (i16)(-7);
    y[1] = (i16)3;
    x[2] = (i16)333;
    y[2] = (i16)(-4);
    x[3] = (i16)(-32768);
    y[3] = (i16)1;
    x[4] = (i16)5;
    y[4] = (i16)(-2);
    tensor<i16, 1> s = x + y;
    tensor<i16, 1> d = x - y;
    tensor<i16, 1> m = x * y;
    tensor<i16, 1> q = x / y;
    tensor<i16, 1> r = x % y;
    tensor<i16, 1> n = -x;
    tensor<i16, 1> k = x * 3 - 1;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> ge = x >= y;
    tensor<bool, 1> eq = x == y;
    tensor<bool, 1> ne = x != y;
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        i16 a = x[j];
        i16 b = y[j];
        i16 t3 = 3;
        i16 t1 = 1;
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || r[j] != a % b || n[j] != -a || k[j] != a * t3 - t1)
            bad++;
        if (lt[j] != (a < b) || ge[j] != (a >= b) || eq[j] != (a == b) || ne[j] != (a != b))
            bad++;
    }
    tensor<i16, 1> ab = Math.abs(x);
    for (u64 j = 0; j < 5; j++)
        if (ab[j] != Math.abs(x[j]))
            bad++;
    report("i16", bad);
    Stdio.printf("  %d %d %d %d %d\n", (i32)s[0], (i32)m[0], (i32)q[1], (i32)r[1], lt[0] ? 1 : 0);
}

void ints_u16(void)
{
    tensor<u16, 1> x = new tensor<u16, 1>(5);
    tensor<u16, 1> y = new tensor<u16, 1>(5);
    x[0] = (u16)65000;
    y[0] = (u16)1000;
    x[1] = (u16)7;
    y[1] = (u16)3;
    x[2] = (u16)333;
    y[2] = (u16)4;
    x[3] = (u16)32768;
    y[3] = (u16)2;
    x[4] = (u16)5;
    y[4] = (u16)65535;
    tensor<u16, 1> s = x + y;
    tensor<u16, 1> d = x - y;
    tensor<u16, 1> m = x * y;
    tensor<u16, 1> q = x / y;
    tensor<u16, 1> r = x % y;
    tensor<u16, 1> n = -x;
    tensor<u16, 1> k = x * 3 - 1;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> ge = x >= y;
    tensor<bool, 1> eq = x == y;
    tensor<bool, 1> ne = x != y;
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        u16 a = x[j];
        u16 b = y[j];
        u16 t3 = 3;
        u16 t1 = 1;
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || r[j] != a % b || n[j] != -a || k[j] != a * t3 - t1)
            bad++;
        if (lt[j] != (a < b) || ge[j] != (a >= b) || eq[j] != (a == b) || ne[j] != (a != b))
            bad++;
    }
    report("u16", bad);
    Stdio.printf("  %d %d %d %d %d\n", (i32)s[0], (i32)m[0], (i32)q[1], (i32)r[1], lt[0] ? 1 : 0);
}

void ints_i32(void)
{
    tensor<i32, 1> x = new tensor<i32, 1>(5);
    tensor<i32, 1> y = new tensor<i32, 1>(5);
    x[0] = (i32)2000000000;
    y[0] = (i32)2000000000;
    x[1] = (i32)(-7);
    y[1] = (i32)3;
    x[2] = (i32)333;
    y[2] = (i32)(-4);
    x[3] = (i32)(-5);
    y[3] = (i32)1;
    x[4] = (i32)5;
    y[4] = (i32)(-2);
    tensor<i32, 1> s = x + y;
    tensor<i32, 1> d = x - y;
    tensor<i32, 1> m = x * y;
    tensor<i32, 1> q = x / y;
    tensor<i32, 1> r = x % y;
    tensor<i32, 1> n = -x;
    tensor<i32, 1> k = x * 3 - 1;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> ge = x >= y;
    tensor<bool, 1> eq = x == y;
    tensor<bool, 1> ne = x != y;
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        i32 a = x[j];
        i32 b = y[j];
        i32 t3 = 3;
        i32 t1 = 1;
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || r[j] != a % b || n[j] != -a || k[j] != a * t3 - t1)
            bad++;
        if (lt[j] != (a < b) || ge[j] != (a >= b) || eq[j] != (a == b) || ne[j] != (a != b))
            bad++;
    }
    tensor<i32, 1> ab = Math.abs(x);
    for (u64 j = 0; j < 5; j++)
        if (ab[j] != Math.abs(x[j]))
            bad++;
    report("i32", bad);
    Stdio.printf("  %d %d %d %d %d\n", (i32)s[0], (i32)m[0], (i32)q[1], (i32)r[1], lt[0] ? 1 : 0);
}

void ints_u32(void)
{
    tensor<u32, 1> x = new tensor<u32, 1>(5);
    tensor<u32, 1> y = new tensor<u32, 1>(5);
    x[0] = (u32)4000000000;
    y[0] = (u32)1000000000;
    x[1] = (u32)7;
    y[1] = (u32)3;
    x[2] = (u32)333;
    y[2] = (u32)4;
    x[3] = (u32)5;
    y[3] = (u32)2;
    x[4] = (u32)5;
    y[4] = (u32)9;
    tensor<u32, 1> s = x + y;
    tensor<u32, 1> d = x - y;
    tensor<u32, 1> m = x * y;
    tensor<u32, 1> q = x / y;
    tensor<u32, 1> r = x % y;
    tensor<u32, 1> n = -x;
    tensor<u32, 1> k = x * 3 - 1;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> ge = x >= y;
    tensor<bool, 1> eq = x == y;
    tensor<bool, 1> ne = x != y;
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        u32 a = x[j];
        u32 b = y[j];
        u32 t3 = 3;
        u32 t1 = 1;
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || r[j] != a % b || n[j] != -a || k[j] != a * t3 - t1)
            bad++;
        if (lt[j] != (a < b) || ge[j] != (a >= b) || eq[j] != (a == b) || ne[j] != (a != b))
            bad++;
    }
    report("u32", bad);
    Stdio.printf("  %d %d %d %d %d\n", (i32)s[0], (i32)m[0], (i32)q[1], (i32)r[1], lt[0] ? 1 : 0);
}

void ints_i64(void)
{
    tensor<i64, 1> x = new tensor<i64, 1>(5);
    tensor<i64, 1> y = new tensor<i64, 1>(5);
    x[0] = (i64)9000000000000000000;
    y[0] = (i64)9000000000000000000;
    x[1] = (i64)(-7);
    y[1] = (i64)3;
    x[2] = (i64)333;
    y[2] = (i64)(-4);
    x[3] = (i64)(-5);
    y[3] = (i64)1;
    x[4] = (i64)5;
    y[4] = (i64)(-2);
    tensor<i64, 1> s = x + y;
    tensor<i64, 1> d = x - y;
    tensor<i64, 1> m = x * y;
    tensor<i64, 1> q = x / y;
    tensor<i64, 1> r = x % y;
    tensor<i64, 1> n = -x;
    tensor<i64, 1> k = x * 3 - 1;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> ge = x >= y;
    tensor<bool, 1> eq = x == y;
    tensor<bool, 1> ne = x != y;
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        i64 a = x[j];
        i64 b = y[j];
        i64 t3 = 3;
        i64 t1 = 1;
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || r[j] != a % b || n[j] != -a || k[j] != a * t3 - t1)
            bad++;
        if (lt[j] != (a < b) || ge[j] != (a >= b) || eq[j] != (a == b) || ne[j] != (a != b))
            bad++;
    }
    report("i64", bad);
    Stdio.printf("  %d %d %d %d %d\n", (i32)s[0], (i32)m[0], (i32)q[1], (i32)r[1], lt[0] ? 1 : 0);
}

void ints_u64(void)
{
    tensor<u64, 1> x = new tensor<u64, 1>(5);
    tensor<u64, 1> y = new tensor<u64, 1>(5);
    x[0] = (u64)18000000000000000000;
    y[0] = (u64)1000000000000000000;
    x[1] = (u64)7;
    y[1] = (u64)3;
    x[2] = (u64)333;
    y[2] = (u64)4;
    x[3] = (u64)5;
    y[3] = (u64)2;
    x[4] = (u64)5;
    y[4] = (u64)9;
    tensor<u64, 1> s = x + y;
    tensor<u64, 1> d = x - y;
    tensor<u64, 1> m = x * y;
    tensor<u64, 1> q = x / y;
    tensor<u64, 1> r = x % y;
    tensor<u64, 1> n = -x;
    tensor<u64, 1> k = x * 3 - 1;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> ge = x >= y;
    tensor<bool, 1> eq = x == y;
    tensor<bool, 1> ne = x != y;
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        u64 a = x[j];
        u64 b = y[j];
        u64 t3 = 3;
        u64 t1 = 1;
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || r[j] != a % b || n[j] != -a || k[j] != a * t3 - t1)
            bad++;
        if (lt[j] != (a < b) || ge[j] != (a >= b) || eq[j] != (a == b) || ne[j] != (a != b))
            bad++;
    }
    report("u64", bad);
    Stdio.printf("  %d %d %d %d %d\n", (i32)s[0], (i32)m[0], (i32)q[1], (i32)r[1], lt[0] ? 1 : 0);
}

void floats_f64(void)
{
    tensor<f64, 1> x = new tensor<f64, 1>(5);
    tensor<f64, 1> y = new tensor<f64, 1>(5);
    x[0] = 0.25d;
    y[0] = 0.5d;
    x[1] = 1.5d;
    y[1] = -2.0d;
    x[2] = 2.75d;
    y[2] = 0.375d;
    x[3] = -3.125d;
    y[3] = 1.25d;
    x[4] = 10.0d;
    y[4] = 3.0d;
    tensor<f64, 1> s = x + y;
    tensor<f64, 1> d = x - y;
    tensor<f64, 1> m = x * y;
    tensor<f64, 1> q = x / y;
    tensor<f64, 1> n = -x;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> le = x <= y;
    tensor<bool, 1> gt = x > y;
    tensor<f64, 1> ax = Math.abs(x);
    tensor<f64, 1> sq = Math.sqrt(ax);
    tensor<f64, 1> ex = Math.exp(y);
    tensor<f64, 1> lg = Math.ln(ax);
    tensor<f64, 1> si = Math.sin(x);
    tensor<f64, 1> co = Math.cos(x);
    tensor<f64, 1> ta = Math.tan(y);
    tensor<f64, 1> at = Math.atan(x);
    tensor<f64, 1> pw = Math.pow(ax, y);
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        f64 a = x[j];
        f64 b = y[j];
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || n[j] != -a)
            bad++;
        if (lt[j] != (a < b) || le[j] != (a <= b) || gt[j] != (a > b))
            bad++;
        if (ax[j] != Math.abs(a) || sq[j] != Math.sqrt(Math.abs(a)) || ex[j] != Math.exp(b) || lg[j] != Math.ln(Math.abs(a)))
            bad++;
        if (si[j] != Math.sin(a) || co[j] != Math.cos(a) || ta[j] != Math.tan(b) || at[j] != Math.atan(a) || pw[j] != Math.pow(Math.abs(a), b))
            bad++;
    }
    report("f64", bad);
    Stdio.printf("  %.4f %.4f %.4f %.4f\n", (f64)s[3], (f64)q[1], (f64)sq[2], (f64)pw[4]);
}

void floats_f32(void)
{
    tensor<f32, 1> x = new tensor<f32, 1>(5);
    tensor<f32, 1> y = new tensor<f32, 1>(5);
    x[0] = 0.25;
    y[0] = 0.5;
    x[1] = 1.5;
    y[1] = -2.0;
    x[2] = 2.75;
    y[2] = 0.375;
    x[3] = -3.125;
    y[3] = 1.25;
    x[4] = 10.0;
    y[4] = 3.0;
    tensor<f32, 1> s = x + y;
    tensor<f32, 1> d = x - y;
    tensor<f32, 1> m = x * y;
    tensor<f32, 1> q = x / y;
    tensor<f32, 1> n = -x;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> le = x <= y;
    tensor<bool, 1> gt = x > y;
    tensor<f32, 1> ax = Math.abs(x);
    tensor<f32, 1> sq = Math.sqrt(ax);
    tensor<f32, 1> ex = Math.exp(y);
    tensor<f32, 1> lg = Math.ln(ax);
    tensor<f32, 1> si = Math.sin(x);
    tensor<f32, 1> co = Math.cos(x);
    tensor<f32, 1> ta = Math.tan(y);
    tensor<f32, 1> at = Math.atan(x);
    tensor<f32, 1> pw = Math.pow(ax, y);
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        f32 a = x[j];
        f32 b = y[j];
        if (s[j] != a + b || d[j] != a - b || m[j] != a * b || q[j] != a / b || n[j] != -a)
            bad++;
        if (lt[j] != (a < b) || le[j] != (a <= b) || gt[j] != (a > b))
            bad++;
        if (ax[j] != Math.abs(a) || sq[j] != Math.sqrt(Math.abs(a)) || ex[j] != Math.exp(b) || lg[j] != Math.ln(Math.abs(a)))
            bad++;
        if (si[j] != Math.sin(a) || co[j] != Math.cos(a) || ta[j] != Math.tan(b) || at[j] != Math.atan(a) || pw[j] != Math.pow(Math.abs(a), b))
            bad++;
    }
    report("f32", bad);
    Stdio.printf("  %.4f %.4f %.4f %.4f\n", (f64)s[3], (f64)q[1], (f64)sq[2], (f64)pw[4]);
}

void packs_f16(void)
{
    tensor<f16, 1> x = new tensor<f16, 1>(5);
    tensor<f16, 1> y = new tensor<f16, 1>(5);
    x[0] = (f16)0.3;
    y[0] = (f16)1.1;
    x[1] = (f16)1.7;
    y[1] = (f16)-0.45;
    x[2] = (f16)-2.6;
    y[2] = (f16)2.2;
    x[3] = (f16)3.1;
    y[3] = (f16)0.7;
    x[4] = (f16)0.1;
    y[4] = (f16)5.5;
    tensor<f16, 1> s = x + y;
    tensor<f16, 1> d = x - y;
    tensor<f16, 1> m = x * y;
    tensor<f16, 1> q = x / y;
    tensor<f16, 1> n = -x;
    tensor<f16, 1> c = x * 2.0 - 0.5;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> eq = x == y;
    tensor<f16, 1> ax = Math.abs(x);
    tensor<f16, 1> sq = Math.sqrt(ax);
    tensor<f16, 1> ex = Math.exp(x);
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        f16 a = x[j];
        f16 b = y[j];
        f16 two = 2.0;
        f16 half = 0.5;
        f16 ws = a + b;
        f16 wd = a - b;
        f16 wm = a * b;
        f16 wq = a / b;
        f16 wn = -a;
        f16 wc = a * two - half;
        f16 wa = (f16)Math.abs((f32)a);
        f16 wr = (f16)Math.sqrt((f32)wa);
        f16 we = (f16)Math.exp((f32)a);
        if (hb(s[j]) != hb(ws) || hb(d[j]) != hb(wd) || hb(m[j]) != hb(wm) || hb(q[j]) != hb(wq))
            bad++;
        if (hb(n[j]) != hb(wn) || hb(c[j]) != hb(wc) || lt[j] != (a < b) || eq[j] != (a == b))
            bad++;
        if (hb(ax[j]) != hb(wa) || hb(sq[j]) != hb(wr) || hb(ex[j]) != hb(we))
            bad++;
    }
    report("f16", bad);
    Stdio.printf("  %x %x %x %x %x\n", hb(s[0]), hb(m[1]), hb(q[2]), hb(c[3]), hb(sq[4]));
}

void packs_bf16(void)
{
    tensor<bf16, 1> x = new tensor<bf16, 1>(5);
    tensor<bf16, 1> y = new tensor<bf16, 1>(5);
    x[0] = (bf16)0.3;
    y[0] = (bf16)1.1;
    x[1] = (bf16)1.7;
    y[1] = (bf16)-0.45;
    x[2] = (bf16)-2.6;
    y[2] = (bf16)2.2;
    x[3] = (bf16)3.1;
    y[3] = (bf16)0.7;
    x[4] = (bf16)0.1;
    y[4] = (bf16)5.5;
    tensor<bf16, 1> s = x + y;
    tensor<bf16, 1> d = x - y;
    tensor<bf16, 1> m = x * y;
    tensor<bf16, 1> q = x / y;
    tensor<bf16, 1> n = -x;
    tensor<bf16, 1> c = x * 2.0 - 0.5;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> eq = x == y;
    tensor<bf16, 1> ax = Math.abs(x);
    tensor<bf16, 1> sq = Math.sqrt(ax);
    tensor<bf16, 1> ex = Math.exp(x);
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        bf16 a = x[j];
        bf16 b = y[j];
        bf16 two = 2.0;
        bf16 half = 0.5;
        bf16 ws = a + b;
        bf16 wd = a - b;
        bf16 wm = a * b;
        bf16 wq = a / b;
        bf16 wn = -a;
        bf16 wc = a * two - half;
        bf16 wa = (bf16)Math.abs((f32)a);
        bf16 wr = (bf16)Math.sqrt((f32)wa);
        bf16 we = (bf16)Math.exp((f32)a);
        if (bb(s[j]) != bb(ws) || bb(d[j]) != bb(wd) || bb(m[j]) != bb(wm) || bb(q[j]) != bb(wq))
            bad++;
        if (bb(n[j]) != bb(wn) || bb(c[j]) != bb(wc) || lt[j] != (a < b) || eq[j] != (a == b))
            bad++;
        if (bb(ax[j]) != bb(wa) || bb(sq[j]) != bb(wr) || bb(ex[j]) != bb(we))
            bad++;
    }
    report("bf16", bad);
    Stdio.printf("  %x %x %x %x %x\n", bb(s[0]), bb(m[1]), bb(q[2]), bb(c[3]), bb(sq[4]));
}

void packs_f8(void)
{
    tensor<f8, 1> x = new tensor<f8, 1>(5);
    tensor<f8, 1> y = new tensor<f8, 1>(5);
    x[0] = (f8)0.3;
    y[0] = (f8)1.1;
    x[1] = (f8)1.7;
    y[1] = (f8)-0.45;
    x[2] = (f8)-2.6;
    y[2] = (f8)2.2;
    x[3] = (f8)3.1;
    y[3] = (f8)0.7;
    x[4] = (f8)0.1;
    y[4] = (f8)5.5;
    tensor<f8, 1> s = x + y;
    tensor<f8, 1> d = x - y;
    tensor<f8, 1> m = x * y;
    tensor<f8, 1> q = x / y;
    tensor<f8, 1> n = -x;
    tensor<f8, 1> c = x * 2.0 - 0.5;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> eq = x == y;
    tensor<f8, 1> ax = Math.abs(x);
    tensor<f8, 1> sq = Math.sqrt(ax);
    tensor<f8, 1> ex = Math.exp(x);
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        f8 a = x[j];
        f8 b = y[j];
        f8 two = 2.0;
        f8 half = 0.5;
        f8 ws = a + b;
        f8 wd = a - b;
        f8 wm = a * b;
        f8 wq = a / b;
        f8 wn = -a;
        f8 wc = a * two - half;
        f8 wa = (f8)Math.abs((f32)a);
        f8 wr = (f8)Math.sqrt((f32)wa);
        f8 we = (f8)Math.exp((f32)a);
        if (eb(s[j]) != eb(ws) || eb(d[j]) != eb(wd) || eb(m[j]) != eb(wm) || eb(q[j]) != eb(wq))
            bad++;
        if (eb(n[j]) != eb(wn) || eb(c[j]) != eb(wc) || lt[j] != (a < b) || eq[j] != (a == b))
            bad++;
        if (eb(ax[j]) != eb(wa) || eb(sq[j]) != eb(wr) || eb(ex[j]) != eb(we))
            bad++;
    }
    report("f8", bad);
    Stdio.printf("  %x %x %x %x %x\n", eb(s[0]), eb(m[1]), eb(q[2]), eb(c[3]), eb(sq[4]));
}

void packs_e5m2(void)
{
    tensor<f8:pack(e5m2), 1> x = new tensor<f8:pack(e5m2), 1>(5);
    tensor<f8:pack(e5m2), 1> y = new tensor<f8:pack(e5m2), 1>(5);
    x[0] = (f8:pack(e5m2))0.3;
    y[0] = (f8:pack(e5m2))1.1;
    x[1] = (f8:pack(e5m2))1.7;
    y[1] = (f8:pack(e5m2))-0.45;
    x[2] = (f8:pack(e5m2))-2.6;
    y[2] = (f8:pack(e5m2))2.2;
    x[3] = (f8:pack(e5m2))3.1;
    y[3] = (f8:pack(e5m2))0.7;
    x[4] = (f8:pack(e5m2))0.1;
    y[4] = (f8:pack(e5m2))5.5;
    tensor<f8:pack(e5m2), 1> s = x + y;
    tensor<f8:pack(e5m2), 1> d = x - y;
    tensor<f8:pack(e5m2), 1> m = x * y;
    tensor<f8:pack(e5m2), 1> q = x / y;
    tensor<f8:pack(e5m2), 1> n = -x;
    tensor<f8:pack(e5m2), 1> c = x * 2.0 - 0.5;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> eq = x == y;
    tensor<f8:pack(e5m2), 1> ax = Math.abs(x);
    tensor<f8:pack(e5m2), 1> sq = Math.sqrt(ax);
    tensor<f8:pack(e5m2), 1> ex = Math.exp(x);
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        f8:pack(e5m2) a = x[j];
        f8:pack(e5m2) b = y[j];
        f8:pack(e5m2) two = 2.0;
        f8:pack(e5m2) half = 0.5;
        f8:pack(e5m2) ws = a + b;
        f8:pack(e5m2) wd = a - b;
        f8:pack(e5m2) wm = a * b;
        f8:pack(e5m2) wq = a / b;
        f8:pack(e5m2) wn = -a;
        f8:pack(e5m2) wc = a * two - half;
        f8:pack(e5m2) wa = (f8:pack(e5m2))Math.abs((f32)a);
        f8:pack(e5m2) wr = (f8:pack(e5m2))Math.sqrt((f32)wa);
        f8:pack(e5m2) we = (f8:pack(e5m2))Math.exp((f32)a);
        if (e5b(s[j]) != e5b(ws) || e5b(d[j]) != e5b(wd) || e5b(m[j]) != e5b(wm) || e5b(q[j]) != e5b(wq))
            bad++;
        if (e5b(n[j]) != e5b(wn) || e5b(c[j]) != e5b(wc) || lt[j] != (a < b) || eq[j] != (a == b))
            bad++;
        if (e5b(ax[j]) != e5b(wa) || e5b(sq[j]) != e5b(wr) || e5b(ex[j]) != e5b(we))
            bad++;
    }
    report("e5m2", bad);
    Stdio.printf("  %x %x %x %x %x\n", e5b(s[0]), e5b(m[1]), e5b(q[2]), e5b(c[3]), e5b(sq[4]));
}

void packs_f4(void)
{
    tensor<f4, 1> x = new tensor<f4, 1>(5);
    tensor<f4, 1> y = new tensor<f4, 1>(5);
    x[0] = (f4)0.3;
    y[0] = (f4)1.1;
    x[1] = (f4)1.7;
    y[1] = (f4)-0.45;
    x[2] = (f4)-2.6;
    y[2] = (f4)2.2;
    x[3] = (f4)3.1;
    y[3] = (f4)0.7;
    x[4] = (f4)0.1;
    y[4] = (f4)5.5;
    tensor<f4, 1> s = x + y;
    tensor<f4, 1> d = x - y;
    tensor<f4, 1> m = x * y;
    tensor<f4, 1> q = x / y;
    tensor<f4, 1> n = -x;
    tensor<f4, 1> c = x * 2.0 - 0.5;
    tensor<bool, 1> lt = x < y;
    tensor<bool, 1> eq = x == y;
    tensor<f4, 1> ax = Math.abs(x);
    tensor<f4, 1> sq = Math.sqrt(ax);
    tensor<f4, 1> ex = Math.exp(x);
    u32 bad = 0;
    for (u64 j = 0; j < 5; j++)
    {
        f4 a = x[j];
        f4 b = y[j];
        f4 two = 2.0;
        f4 half = 0.5;
        f4 ws = a + b;
        f4 wd = a - b;
        f4 wm = a * b;
        f4 wq = a / b;
        f4 wn = -a;
        f4 wc = a * two - half;
        f4 wa = (f4)Math.abs((f32)a);
        f4 wr = (f4)Math.sqrt((f32)wa);
        f4 we = (f4)Math.exp((f32)a);
        if (qb(s[j]) != qb(ws) || qb(d[j]) != qb(wd) || qb(m[j]) != qb(wm) || qb(q[j]) != qb(wq))
            bad++;
        if (qb(n[j]) != qb(wn) || qb(c[j]) != qb(wc) || lt[j] != (a < b) || eq[j] != (a == b))
            bad++;
        if (qb(ax[j]) != qb(wa) || qb(sq[j]) != qb(wr) || qb(ex[j]) != qb(we))
            bad++;
    }
    report("f4", bad);
    Stdio.printf("  %x %x %x %x %x\n", qb(s[0]), qb(m[1]), qb(q[2]), qb(c[3]), qb(sq[4]));
}

void show(u8* what, tensor<f32, 2> c)
{
    Stdio.printf("%s %dx%d:", what, (i32)c.shape(0), (i32)c.shape(1));
    for (u64 i = 0; i < c.shape(0); i++)
    {
        Stdio.printf(" |");
        for (u64 j = 0; j < c.shape(1); j++)
            Stdio.printf(" %.1f", c[i, j]);
    }
    Stdio.printf("\n");
}

void broadcasting(void)
{
    tensor<f32, 2> m = new tensor<f32, 2>(3, 4);
    for (u64 i = 0; i < 3; i++)
        for (u64 j = 0; j < 4; j++)
            m[i, j] = (f32)(i * 10 + j);
    tensor<f32, 1> row = new tensor<f32, 1>(4);
    tensor<f32, 2> col = new tensor<f32, 2>(3, 1);
    for (u64 j = 0; j < 4; j++)
        row[j] = (f32)j * 100.0;
    for (u64 i = 0; i < 3; i++)
        col[i, 0] = (f32)(i + 1);
    show("row + matrix", m + row);
    show("matrix * column", m * col);
    show("scalar - matrix", 1.0 - m);
    show("column + row", col + row);
    tensor<f32, 3> cube = new tensor<f32, 3>(2, 3, 4);
    for (u64 k = 0; k < 2; k++)
        for (u64 i = 0; i < 3; i++)
            for (u64 j = 0; j < 4; j++)
                cube[k, i, j] = (f32)(k * 1000);
    tensor<f32, 3> c3 = cube + m - row;
    Stdio.printf("rank 3 + rank 2 - rank 1: %d %d %d, %.1f %.1f\n", (i32)c3.shape(0), (i32)c3.shape(1), (i32)c3.shape(2), c3[1, 2, 3], c3[0, 1, 2]);
    tensor<f32, 2> one = new tensor<f32, 2>(1, 1);
    one[0, 0] = 0.5;
    show("1x1 * matrix", one * m);
}

void fusion(void)
{
    tensor<f32, 2> a = new tensor<f32, 2>(4, 5);
    tensor<f32, 2> b = new tensor<f32, 2>(4, 5);
    tensor<f32, 1> c = new tensor<f32, 1>(5);
    tensor<f32, 2> e = new tensor<f32, 2>(4, 1);
    for (u64 i = 0; i < 4; i++)
        for (u64 j = 0; j < 5; j++)
        {
            a[i, j] = (f32)(i + j) * 0.25 + 0.5;
            b[i, j] = (f32)(i * j) - 1.5;
        }
    for (u64 j = 0; j < 5; j++)
        c[j] = (f32)j * 0.75;
    for (u64 i = 0; i < 4; i++)
        e[i, 0] = (f32)i - 2.0;
    tensor<f32, 2> d = Math.sqrt(a * b * b + c) - e / (a + 1.0) * Math.abs(-b + c) + (tensor<f32, 2>)((tensor<f16, 2>)a);
    u32 bad = 0;
    for (u64 i = 0; i < 4; i++)
        for (u64 j = 0; j < 5; j++)
        {
            f32 x = a[i, j];
            f32 y = b[i, j];
            f32 want = Math.sqrt(x * y * y + c[j]) - e[i, 0] / (x + 1.0) * Math.abs(-y + c[j]) + (f32)((f16)x);
            if (d[i, j] != want)
                bad++;
        }
    report("long expression", bad);
    Stdio.printf("  %.4f %.4f storages %d\n", d[0, 0], d[3, 4], (i32)TensorStorage.live());
}

void forms(void)
{
    tensor<i32, 2> a = new tensor<i32, 2>(2, 3);
    tensor<i32, 2> b = new tensor<i32, 2>(2, 3);
    for (u64 i = 0; i < 2; i++)
        for (u64 j = 0; j < 3; j++)
        {
            a[i, j] = (i32)(i * 3 + j);
            b[i, j] = 10;
        }
    tensor<i32, 2> alias = a;
    tensor<i32, 2> c = a + b;
    c[0, 0] = 99;
    Stdio.printf("new: a[0, 0] %d c[0, 0] %d c[1, 2] %d\n", a[0, 0], c[0, 0], c[1, 2]);
    a[.., ..] = b * 2 + a;
    Stdio.printf("in place: a[1, 2] %d alias[1, 2] %d\n", a[1, 2], alias[1, 2]);
    a += b;
    a *= 2;
    a -= 1;
    Stdio.printf("compound: a[0, 1] %d alias[0, 1] %d\n", a[0, 1], alias[0, 1]);
    a[1, ..] = 7;
    a[0, 1..] /= b[0, 1..] - 5;
    Stdio.printf("views: %d %d %d / %d %d %d\n", a[0, 0], a[0, 1], a[0, 2], a[1, 0], a[1, 1], a[1, 2]);
    tensor<i32, 1> r = new tensor<i32, 1>(3);
    r[..] = a[1, ..] % 4 + c[1, ..];
    Stdio.printf("into a rank 1: %d %d %d\n", r[0], r[1], r[2]);
}

void comparisons_and_casts(void)
{
    tensor<f32, 1> x = new tensor<f32, 1>(5);
    for (u64 j = 0; j < 5; j++)
        x[j] = (f32)j * 1.3 - 2.0;
    tensor<bool, 1> pos = x > 0.0;
    tensor<bool, 1> same = pos == (x >= 0.5);
    tensor<i32, 1> n = (tensor<i32, 1>)x;
    tensor<f32, 1> back = (tensor<f32, 1>)n * 0.5;
    tensor<i32, 1> flags = (tensor<i32, 1>)pos;
    tensor<f16, 1> h = (tensor<f16, 1>)x;
    tensor<f4, 1> q = (tensor<f4, 1>)(x * 2.0);
    tensor<i64, 1> wide = (tensor<i64, 1>)n * 3000000000;
    for (u64 j = 0; j < 5; j++)
        Stdio.printf("x %.1f pos %d same %d n %d back %.1f flag %d h %x q %x wide %lld\n", x[j], pos[j] ? 1 : 0, same[j] ? 1 : 0, n[j], back[j], flags[j], hb(h[j]), qb(q[j]), wide[j]);
}

void views(void)
{
    tensor<f32, 2> m = new tensor<f32, 2>(3, 4);
    for (u64 i = 0; i < 3; i++)
        for (u64 j = 0; j < 4; j++)
            m[i, j] = (f32)(i * 4 + j);
    tensor<f32, 2> t = m.transpose();
    tensor<f32, 2> tt = t * 2.0 + t;
    show("transposed", tt);
    tensor<f32, 2> part = m[1.., 1..3] + m[..2, 2..];
    show("sliced", part);
    tensor<f32, 1> col = m[.., 3];
    tensor<f32, 2> wide = m[0, ..].broadcast(3, 4) - m;
    show("broadcast view", wide);
    tensor<f32, 2> mixed = t[1..3, ..] * col;
    show("transposed slice * column", mixed);
}

void f4_odd(void)
{
    tensor<f4, 2> a = new tensor<f4, 2>(3, 5);
    tensor<f4, 1> r = new tensor<f4, 1>(5);
    for (u64 i = 0; i < 3; i++)
        for (u64 j = 0; j < 5; j++)
            a[i, j] = (f4)((f32)(i + j) * 0.5);
    for (u64 j = 0; j < 5; j++)
        r[j] = (f4)((f32)j - 2.0);
    tensor<f4, 2> s = a * r + 0.5;
    tensor<f4, 1> one = r[1..4] + r[..3];
    u32 bad = 0;
    for (u64 i = 0; i < 3; i++)
        for (u64 j = 0; j < 5; j++)
        {
            f4 want = a[i, j] * r[j] + (f4)0.5;
            if (qb(s[i, j]) != qb(want))
                bad++;
        }
    report("f4 3x5", bad);
    for (u64 i = 0; i < 3; i++)
        Stdio.printf("  %x %x %x %x %x\n", qb(s[i, 0]), qb(s[i, 1]), qb(s[i, 2]), qb(s[i, 3]), qb(s[i, 4]));
    Stdio.printf("  odd offset: %x %x %x\n", qb(one[0]), qb(one[1]), qb(one[2]));
    a[1, 1..] = r[1..] * 2.0;
    Stdio.printf("  written row: %x %x %x %x %x, row 0 %x, row 2 %x\n", qb(a[1, 0]), qb(a[1, 1]), qb(a[1, 2]), qb(a[1, 3]), qb(a[1, 4]), qb(a[0, 4]), qb(a[2, 0]));
}

// Long enough for whole vectors: a byte multiply is computed lane by lane
// where the target has one, and stays scalar where it does not.
void long_bytes(void)
{
    tensor<i8, 1> x = new tensor<i8, 1>(37);
    tensor<i8, 1> y = new tensor<i8, 1>(37);
    tensor<u8, 1> u = new tensor<u8, 1>(37);
    tensor<u8, 1> v = new tensor<u8, 1>(37);
    for (u64 j = 0; j < 37; j++)
    {
        x[j] = (i8)((i32)j * 7 - 120);
        y[j] = (i8)(13 - (i32)j * 3);
        u[j] = (u8)(j * 11 + 5);
        v[j] = (u8)(250 - j * 6);
    }
    tensor<i8, 1> m = x * y;
    tensor<u8, 1> w = u * v + u;
    u32 bad = 0;
    for (u64 j = 0; j < 37; j++)
    {
        i8 a = x[j];
        i8 b = y[j];
        u8 c = u[j];
        u8 e = v[j];
        if (m[j] != a * b || w[j] != c * e + c)
            bad++;
    }
    report("long bytes", bad);
}

i32 main(void)
{

    ints_i8();
    ints_u8();
    ints_i16();
    ints_u16();
    ints_i32();
    ints_u32();
    ints_i64();
    ints_u64();
    floats_f64();
    floats_f32();
    packs_f16();
    packs_bf16();
    packs_f8();
    packs_e5m2();
    packs_f4();
    broadcasting();
    fusion();
    forms();
    comparisons_and_casts();
    views();
    f4_odd();
    long_bytes();
    Stdio.printf("storages %d\n", (i32)TensorStorage.live());
    return 0;
}
