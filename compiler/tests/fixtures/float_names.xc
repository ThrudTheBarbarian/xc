// float_names.xc — `f32` and `f64` name the floating point types, and `float`
// and `double` are aliases for them. Each pair is one type: values move between
// the spellings in both directions with no conversion and no warning, sizeof
// agrees, a cast to either spelling is the same cast, and an Array<f32> is an
// Array<float>. The names are built-in type names, not keywords, so a variable
// or parameter may still be called f32 or f64. Every value is exactly
// representable in both widths, so the printed digits are the same everywhere.
// The 64-bit collection element needs Number's wide storage on xt6502.
#define ENABLE_64BIT 1

#import "Stdio.xc"
#import "Foundation.xc"

struct Sample
{
    f32 x;
    float y;
    f64 z;
    double w;
};

f32 gTable[4] = { 0.5, 1.5, 2.5, 3.5 };
double gWide[3];

// A declaration in one spelling, its uses in the other.
f64 twice(double d)
{
    return d * 2;
}

float half(f32 v)
{
    return v / 2;
}

f32 sumOf(float* p, u32 n)
{
    f32 s = 0;
    for (u32 i in 0..n)
        s = s + p[i];
    return s;
}

// The names are not reserved: a parameter or a local may be called f32,
// and `(f64 ? …)` is a conditional, not a cast.
i32 pick(i32 f32, bool f64)
{
    f32 = f32 + 1;
    i32 f32x = f64 ? f32 : 0;
    return (f64 ? f32x : 0) + (f32 > 100 ? 1 : 0);
}

void scalars(void)
{
    f32 a = 1.5;
    float b = a;
    f32 c = b + a;
    a = b * 2;
    f64 d = 2.25;
    double e = d;
    f64 g = e * d;
    d = e + 1;
    double mixed = c + d;
    f64 widened = a;
    f32 narrowed = g;
    Stdio.printf("f32 %f %f %f\n", a, b, c);
    Stdio.printf("f64 %f %f %f %f\n", d, e, g, mixed);
    Stdio.printf("convert %f %f\n", widened, narrowed);
}

void sizes(void)
{
    f32 a = 0;
    double d = 0;
    Stdio.printf("sizeof %d %d %d %d %d %d\n", (i32)sizeof(f32), (i32)sizeof(float),
                 (i32)sizeof(f64), (i32)sizeof(double), (i32)sizeof(a), (i32)sizeof(d));
}

void casts(void)
{
    double d = 7.75;
    f32 a = 2.5;
    Stdio.printf("cast %f %f %d %f\n", (f32)d, (f64)a, (i32)(f32)d, (float)(i32)a);
    float* p = &a;
    f32* q = p;
    f64* r = &d;
    Stdio.printf("pointer %f %f\n", *q, *r);
    Stdio.printf("call %f %f\n", twice(a), half((f32)d));
}

void aggregates(void)
{
    f32 local[4];
    for (u32 i in 0..4)
        local[i] = gTable[i] + (float)i;
    Stdio.printf("array %f %f\n", sumOf(local, 4), sumOf(gTable, 4));
    for (u32 i in 0..3)
        gWide[i] = twice((f64)i);
    Stdio.printf("global %f %f %f\n", gWide[0], gWide[1], gWide[2]);

    Sample s;
    s.x = 0.25;
    s.y = s.x * 2;
    s.z = s.y;
    s.w = s.z + s.x;
    Stdio.printf("struct %f %f %f %f %d\n", s.x, s.y, s.z, s.w, (i32)sizeof(Sample));
}

void collections(void)
{
    Array<f32>* arr = new Array();
    arr.add((f32)1.25);
    arr.add((float)2.5);
    Array<float>* same = arr;
    f32 first = same.get(0);
    float second = arr.get(1);
    Stdio.printf("Array<f32> %d %f %f\n", (i32)arr.count(), first, second);
    Array<double>* wide = new Array();
    wide.add((f64)0.125);
    f64 back = wide.get(0);
    Stdio.printf("Array<double> %f\n", back);
}

i32 main(void)
{
    scalars();
    sizes();
    casts();
    aggregates();
    collections();
    Stdio.printf("names %d %d\n", pick(5, true), pick(5, false));
    return 0;
}
