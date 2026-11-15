// sysv_agg_stack.xc — a struct argument past the integer argument registers
// (#301). Under x86-64 SysV a struct that does not fit in the registers left
// goes whole on the stack, and the registers left still take later integer
// arguments. Calls through a plain call, a class's vtable and a protocol, a
// struct after five and after six integers, an integer after it, and an
// unused struct parameter (it still takes its registers) all print what the
// arm64 build prints.
#import "Stdio.xc"

struct Pair { i64 x; i64 y; }
struct Tri { i64 a; i64 b; i64 c; }

protocol Summer
{
    i64 sum6(i64 a, i64 b, i64 c, i64 d, i64 e, Pair p);
}

class Base : Object <Summer>
{
    i64 sum6(i64 a, i64 b, i64 c, i64 d, i64 e, Pair p) { return a + b + c + d + e + p.x * (i64)100 + p.y * (i64)10000; }
    i64 mix(i64 a, i64 b, i64 c, i64 d, i64 e, Pair p, i64 g) { return 0; }
}

class Derived : Base
{
    i64 mix(i64 a, i64 b, i64 c, i64 d, i64 e, Pair p, i64 g) { return a + b + c + d + e + p.x * (i64)7 + p.y * (i64)11 + g * (i64)13; }
}

i64 five(i64 a, i64 b, i64 c, i64 d, i64 e, Pair p)
{
    return a + b + c + d + e + p.x * (i64)100 + p.y * (i64)10000;
}

i64 fiveThen(i64 a, i64 b, i64 c, i64 d, i64 e, Pair p, i64 g)
{
    return a + b + c + d + e + p.x * (i64)3 + p.y * (i64)5 + g * (i64)1000;
}

i64 sixThen(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, Tri t, i64 h)
{
    return a + b + c + d + e + f + t.a * (i64)2 + t.b * (i64)4 + t.c * (i64)8 + h * (i64)16;
}

i64 unused(i64 a, Pair skip, i64 b, i64 c)
{
    return a * (i64)1000 + b * (i64)10 + c;
}

i32 main(void)
{
    Pair p;
    p.x = (i64)3;
    p.y = (i64)4;
    Tri t;
    t.a = (i64)5;
    t.b = (i64)6;
    t.c = (i64)7;
    Stdio.printf("%lld\n", five((i64)1, (i64)2, (i64)3, (i64)4, (i64)5, p));
    Stdio.printf("%lld\n", fiveThen((i64)1, (i64)2, (i64)3, (i64)4, (i64)5, p, (i64)9));
    Stdio.printf("%lld\n", sixThen((i64)1, (i64)2, (i64)3, (i64)4, (i64)5, (i64)6, t, (i64)9));
    Stdio.printf("%lld\n", unused((i64)8, p, (i64)2, (i64)1));
    Base* b = new Derived();
    Stdio.printf("%lld\n", b.mix((i64)1, (i64)2, (i64)3, (i64)4, (i64)5, p, (i64)9));
    Summer* s = b;
    Stdio.printf("%lld\n", s.sum6((i64)1, (i64)2, (i64)3, (i64)4, (i64)5, p));
    return 0;
}
