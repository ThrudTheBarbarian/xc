// tuple_scope_shadow_outer.xc — a tuple-declared name shadows an outer local
// for the rest of its block only, as a plain declaration does.
#import <Stdio.xc>

i32, i32 two(i32 a) { return a + 1, a * 2; }
float, i32 mixed(i32 a) { return (float)a * 0.5, a - 1; }

i32 main(i32 argc, u8** argv) {
    // A plain outer local.
    i32 x = 100;
    {
        (i32 x, i32 y) = two(7);
        Stdio.printf("inner x=%d y=%d\n", x, y);
    }
    Stdio.printf("outer x=%d\n", x);

    // An outer local whose address is taken, shadowed at another type.
    i32 v = 50;
    i32* pv = &v;
    *pv = 51;
    if (argc > 0) {
        (float v, i32 w) = mixed(9);
        Stdio.printf("inner v=%f w=%d\n", (double)v, w);
    }
    Stdio.printf("outer v=%d via p=%d\n", v, *pv);

    // An outer array, shadowed by a tuple scalar inside a loop.
    i32 arr[3];
    arr[0] = 1;
    arr[1] = 2;
    arr[2] = 3;
    i32 acc = 0;
    for (i32 i = 0; i < 3; i++) {
        (i32 arr, i32 extra) = two(i);
        acc = acc + arr * 10 + extra;
    }
    Stdio.printf("acc=%d arr=%d,%d,%d\n", acc, arr[0], arr[1], arr[2]);
    return 0;
}
