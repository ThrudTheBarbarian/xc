// tuple_scope_sibling_array.xc — a tuple-declared local beside a sibling
// block's array of the same name.
//
// `(float ax, float ay) = pair(10.0)` declares ax in the first block; the
// second block declares `float ax[6]`. The array needs a frame slot, and the
// tuple's ax was read from that slot instead of from its own value, so f(7)
// returned 12 rather than 1112.
#import <Stdio.xc>

float, float pair(float a) { return a + 1.0, a + 2.0; }

float f(i32 s) {
    if (s == 7) {
        (float ax, float ay) = pair(10.0);
        return ax * 100.0 + ay;
    }
    if (s == 9) {
        float ax[6];
        ax[0] = 5.0;
        return ax[0];
    }
    return 0.0;
}

// The array first, then the tuple, with integer values.
i32, i32 split(i32 v) { return v / 10, v % 10; }

i32 g(i32 s) {
    if (s == 1) {
        i32 hi[4];
        hi[0] = 40;
        hi[3] = 3;
        return hi[0] + hi[3];
    }
    if (s == 2) {
        (i32 hi, i32 lo) = split(87);
        return hi * 100 + lo;
    }
    return -1;
}

i32 main(i32 argc, u8** argv) {
    Stdio.printf("f(7)=%f\n", (double)f(7));
    Stdio.printf("f(9)=%f\n", (double)f(9));
    Stdio.printf("f(0)=%f\n", (double)f(0));
    Stdio.printf("g(1)=%d\n", g(1));
    Stdio.printf("g(2)=%d\n", g(2));
    return 0;
}
