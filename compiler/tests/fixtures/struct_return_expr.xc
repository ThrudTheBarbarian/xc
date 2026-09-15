// Regression for struct-returning calls used in expression
// contexts that used to diagnose with "call to 'f' returns a
// struct — only `StructType v = f(...)` ... supported in the
// first pass". The supported shapes have grown over time; this
// fixture pins them down so future work doesn't silently
// reintroduce the limitations:
//
//   T1  g(f())                 — small struct as an arg to another call
//   T2  f().x                  — field access on a struct-returning call
//   T3  f().x + other          — expression involving a field access
//   T4  return f();            — tail call returning a small struct
//
// Large-struct (>8 bytes) return-f() is covered by the companion
// fixture `struct_return_expr_large.xc`, which only runs on the
// standard target — banked-target large-struct return assignment
// currently truncates to 2 bytes on the CALLER side, unrelated to
// the return-expression work here.
//
// Uses ordinary `if (v == expected) printf("T# PASS")` style so
// the harness just checks for no FAIL lines.

#import "Stdio.xc"

struct Point { u16 x; u16 y; }

Point makePoint(u16 x, u16 y)
{
    Point p;
    p.x = x;
    p.y = y;
    return p;
}

u16 consume(Point p)
{
    return p.x + p.y;
}

Point reemitSmall(Point src)
{
    // return f(); — small struct. Exercises the emitStructExprToB0
    // call-expression branch that runs the nested call under
    // _inStructReturnIntercept, landing bytes in $B0..$B0+W-1.
    return makePoint(src.x + 1, src.y + 1);
}

void main(void)
{
    // T1: g(f()) — struct-returning call as an arg
    u16 s = consume(makePoint(10, 20));
    if (s == 30) { Stdio.printf("T1 PASS\n"); }
    else         { Stdio.printf("T1 FAIL s=%u\n", s); }

    // T2: f().x — field access on a struct-returning call
    u16 x = makePoint(17, 42).x;
    if (x == 17) { Stdio.printf("T2 PASS\n"); }
    else         { Stdio.printf("T2 FAIL x=%u\n", x); }

    // T3: f().x + other — field access used in a larger expression
    u16 sum = makePoint(5, 9).y + 100;
    if (sum == 109) { Stdio.printf("T3 PASS\n"); }
    else            { Stdio.printf("T3 FAIL sum=%u\n", sum); }

    // T4: return f(); small struct
    Point p = reemitSmall(makePoint(10, 20));
    if (p.x == 11 && p.y == 21) { Stdio.printf("T4 PASS\n"); }
    else                        { Stdio.printf("T4 FAIL %u,%u\n", p.x, p.y); }
}
