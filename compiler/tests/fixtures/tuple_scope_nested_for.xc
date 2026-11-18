// tuple_scope_nested_for.xc — tuple-declared locals read inside nested loops.
//
// A perfect loop nest can be run as a parallel grid, and its body then reads
// the enclosing locals as captures. Tuple-declared names were not known to the
// capture analysis, so the body reported "Undefined identifier 'x'".
#import <Stdio.xc>

i32, i32 two(i32 a) { return a + 1, a * 2; }

i32 main(i32 argc, u8** argv) {
    u32 grid[24];
    (i32 x, i32 y) = two(5);
    for (i32 i = 0; i < 4; i++) {
        for (i32 j = 0; j < 6; j++) {
            grid[i * 6 + j] = (u32)(x * 10 + y + i * j);
        }
    }
    u32 sum = 0;
    for (i32 k = 0; k < 24; k++)
        sum = sum + grid[k];
    Stdio.printf("2-deep: x=%d y=%d sum=%u\n", x, y, sum);

    // Three deep, the tuple declared in an inner block.
    u32 cube[2 * 3 * 4];
    if (argc > 0) {
        (i32 p, i32 q) = two(argc + 2);
        for (i32 a = 0; a < 2; a++) {
            for (i32 b = 0; b < 3; b++) {
                for (i32 c = 0; c < 4; c++) {
                    cube[(a * 3 + b) * 4 + c] = (u32)(p * a + q * b + c);
                }
            }
        }
        u32 csum = 0;
        for (i32 k = 0; k < 24; k++)
            csum = csum + cube[k];
        Stdio.printf("3-deep: p=%d q=%d sum=%u\n", p, q, csum);
    }

    // An ordinary nest that accumulates into a scalar.
    i32 total = 0;
    for (i32 i = 0; i < 3; i++) {
        for (i32 j = 0; j < 2; j++) {
            total = total + x * 10 + y;
        }
    }
    Stdio.printf("total=%d\n", total);
    return 0;
}
