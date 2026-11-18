// tuple_scope_later_sibling.xc — a tuple-declared name that a LATER sibling
// block declares again, as a scalar whose address is taken and as a struct.
// Each declaration is its own local.
#import <Stdio.xc>

struct Pt { i32 px; i32 py; };

i32, i32 two(i32 a) { return a + 1, a * 2; }

void bump(i32* p) { *p = *p + 1000; return; }

i32 f(i32 s) {
    if (s == 1) {
        (i32 m, i32 n) = two(20);
        return m * 100 + n;
    }
    if (s == 2) {
        i32 m = 3;
        bump(&m);
        return m;
    }
    if (s == 3) {
        Pt n;
        n.px = 7;
        n.py = 8;
        return n.px * 10 + n.py;
    }
    return 0;
}

// The scalar sibling at another width.
i32 g(i32 s) {
    if (s == 1) {
        (i32 k, i32 j) = two(4);
        return k * 10 + j;
    }
    u8 k = 200;
    u8* pk = &k;
    *pk = *pk + 50;
    return (i32)k;
}

i32 main(i32 argc, u8** argv) {
    Stdio.printf("f(1)=%d f(2)=%d f(3)=%d\n", f(1), f(2), f(3));
    Stdio.printf("g(1)=%d g(2)=%d\n", g(1), g(2));
    return 0;
}
