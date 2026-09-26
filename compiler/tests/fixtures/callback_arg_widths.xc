// callback_arg_widths.xc — an argument passed through a callback or a function
// pointer is adjusted to the SIGNATURE's parameter, as a direct call's is to
// the declaration's (bug 285).
//
// It was not: the argument kept its own width. A byte literal passed to an
// `i32` parameter pushed one byte on xt6502, where the callee reads four, so
// `tab[0](5)` returned garbage there. On every target a negative `i8` passed
// to an `i64` parameter arrived zero-extended. Arguments already of the
// parameter's type were unaffected, which is why fixtures that cast each
// argument never saw it.
//
// Each callee shape, with literal, narrow, signed and exact-width arguments,
// 0, 1 and several parameters, and u8, u16, i32 and i64 returns:
//
//   T1  a callback LOCAL
//   T2  an ARRAY element, global and local
//   T3  a STRUCT field
//   T4  a GLOBAL
//   T5  a callback a function RETURNED
//   T6  a callback rebuilt from a raw pointer
//   T7  an ivar, called from inside its class and from outside it
//   T8  a plain function pointer
//
// One function per shape: xt6502 gives a function's frame a fixed budget.
#import "Stdio.xc"

i32 dbl(i32 x)                  { return x * (i32)2; }
i32 sq(i32 x)                   { return x * x; }
u8  none(void)                  { return (u8)7; }
u16 mix(u8 a, u16 b, i32 c)     { return (u16)((i32)a + (i32)b + c); }
i64 wide(i64 x)                 { return x + (i64)1; }
i32 sum4(i8 a, i16 b, i32 c, i64 d) { return (i32)a + (i32)b + c + (i32)d; }

typedef i32 unop_t(i32);

struct Slot { callback fn i32(i32 x); u8 tag; }

callback gOp i32(i32 x);
callback gTab i32(i32 x)[2] = { &dbl, &sq };

i8  gM = (i8)-3;
u8  gB = (u8)200;
u16 gU = (u16)40000;

class Acc
{
    i32 total;
    callback hook i32(i32 x);
    void init(void)     { total = (i32)0; }
    i32 add(i32 n)      { total = total + n; return total; }
    i32 fire(u8 v)      { return hook(v); }
}

callback pick i32(i32 x) chooser(bool first)
{
    if (first) { return &dbl; }
    return &sq;
}

// T1: a local.
void t1(void)
{
    i8 m = gM; u8 b = gB; u16 u = gU; i32 v = (i32)7;
    callback f i32(i32 x) = &dbl;
    callback z u8(void) = &none;
    callback x3 u16(u8 a, u16 b, i32 c) = &mix;
    Stdio.printf("T1 %d %d %d %d %d\n", f(5), f(m), f(b), f(u), f(v));
    Stdio.printf("T1 %d %d %d\n", (i32)z(), (i32)x3(1, 2, 3), (i32)x3(b, b, m));
}

void t1w(void)
{
    i8 m = gM; u16 u = gU;
    callback w i64(i64 x) = &wide;
    callback s4 i32(i8 a, i16 b, i32 c, i64 d) = &sum4;
    Stdio.printf("T1 %ld %ld %ld\n", w(m), w(-1), w(u));
    Stdio.printf("T1 %d %d\n", s4(1, 2, 3, 4), s4(m, m, m, m));
}

// T2: an array element, global and local.
void t2(void)
{
    i8 m = gM; u8 b = gB;
    callback tab[2] i32(i32 x);
    tab[0] = &sq;
    tab[1] = &dbl;
    Stdio.printf("T2 %d %d %d %d\n", gTab[0](5), gTab[1](5), gTab[0](m), gTab[1](b));
    Stdio.printf("T2 %d %d\n", tab[0](5), tab[1](m));
}

// T3: a struct field.
void t3(void)
{
    Slot sl;
    sl.fn = &sq;
    sl.tag = (u8)1;
    Stdio.printf("T3 %d %d\n", sl.fn(6), sl.fn(gM));
}

// T4: a global.
void t4(void)
{
    gOp = &dbl;
    Stdio.printf("T4 %d %d\n", gOp(21), gOp(gM));
}

// T5: returned from a function, called in place and after binding.
void t5(void)
{
    callback r i32(i32 x) = chooser(false);
    Stdio.printf("T5 %d %d %d\n", chooser(true)(4), r(9), r(gM));
}

// T6: rebuilt from a raw pointer.
void t6(void)
{
    callback f i32(i32 x) = &dbl;
    pointer q = (pointer)f;
    callback g i32(i32 x) = (callback i32(i32 x))(q);
    Stdio.printf("T6 %d %d\n", g(21), g(gM));
}

// T7: an ivar, bound to a method of another object.
void t7(void)
{
    Acc* a = new Acc();
    Acc* t = new Acc();
    a.hook = &t.add;
    Stdio.printf("T7 %d %d %d\n", a.fire((u8)10), a.hook(5), a.hook(gM));
}

// T8: a plain function pointer.
void t8(void)
{
    unop_t* fp = &sq;
    Stdio.printf("T8 %d %d\n", fp(7), fp(gM));
}

i32 main(void)
{
    t1(); t1w(); t2(); t3(); t4(); t5(); t6(); t7(); t8();
    return 0;
}
