// Standard-target-only companion to struct_return_expr.xc.
// Covers the one remaining shape: `return f();` where f returns a
// struct >8 bytes. On the standard target, large-struct-returning
// functions are lowered to take a hidden `__retbuf` pointer as
// their first arg, and `return f()` here forwards the outer
// function's __retbuf straight to f's __retbuf — f writes directly
// into the outer caller's destination and the current function
// just RTSes.
//
// Banked target has a separate pre-existing limitation: the
// banked large-struct return assignment path only reads $B0..$B1
// on the caller side, losing bytes 2..N-1 even for a simple
// `Big r = makeBig(1);` without any expression nesting. That's
// unrelated to the return-expression work here, so this fixture
// runs on standard only. The smaller `struct_return_expr.xc`
// already covers banked's struct-return-expression contexts at
// the ≤ 8-byte struct level.

#import "Stdio.xc"

struct Big {
    u16 a; u16 b; u16 c;
    u16 d; u16 e; u16 f;
}

Big makeBig(u16 seed)
{
    Big b;
    b.a = seed;
    b.b = seed + 1;
    b.c = seed + 2;
    b.d = seed + 3;
    b.e = seed + 4;
    b.f = seed + 5;
    return b;
}

Big passthru(Big src)
{
    // return f(); — LARGE struct. The outer function's hidden
    // __retbuf pointer is forwarded to makeBig's __retbuf arg so
    // makeBig writes directly into the outer caller's destination.
    return makeBig(src.a + 100);
}

void main(void)
{
    Big r = passthru(makeBig(1));
    if (r.a == 101 && r.b == 102 && r.c == 103 &&
        r.d == 104 && r.e == 105 && r.f == 106) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL %u %u %u %u %u %u\n",
                     r.a, r.b, r.c, r.d, r.e, r.f);
    }
}
