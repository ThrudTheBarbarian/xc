//xtc-flags: target=arm64
// arm64_stack_args_over8.xc — arm64 regression (bug 017): a call with more than
// 8 arguments must pass args 9+ on the AAPCS64 outgoing-stack area, and the
// callee must read them back. The arm64 backend previously had NO support for
// stack-passed arguments — the caller dropped every arg past x7 and the callee
// prologue skipped stack params — so any >8-arg call returned garbage. The
// callee here is recursive + called from several sites so it survives inlining
// and a real `bl` with stack args is emitted at -O3.
//
// arm64-scoped: the fix (an outgoing-args area reserved at the frame bottom,
// x29/x30 relocated above it, caller stores + callee loads with Apple natural
// packing) is arm64-specific; each other backend has its own >8-arg convention.
#import <Stdio.xc>

i32 tally(i32 a,i32 b,i32 c,i32 d,i32 e,i32 f,i32 g,i32 h,i32 i,i32 j,i32 k,i32 l) {
    if (a <= 0) return b + c + d + e + f + g + h + i + j + k + l;   // args 2..12
    return a + tally(a - 1, b, c, d, e, f, g, h, i, j, k, l);
}

void main(void) {
    Stdio.printf("t1=%d\n", tally(3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12));   // 3+2+1 + 77 = 83
    Stdio.printf("t2=%d\n", tally(0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1));      // 11
    return;
}
