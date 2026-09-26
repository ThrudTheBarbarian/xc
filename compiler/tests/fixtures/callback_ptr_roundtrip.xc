// Callback <-> raw pointer at the C boundary (c2xc bugs 13, 14).
// 13: (pointer)f on a callback VARIABLE yields the code address (the recv word).
// 14: (callback SIG)(p) builds a callable {recv=p, trampoline} pair, so a
// function pointer received from C (signal's old handler, dlsym) can be called.
#import "Stdio.xc"
i32 dbl(i32 x) { return x * 2; }
i32 main(void) {
    callback f i32(i32 x) = &dbl;
    pointer q = (pointer)f;                             // 13: extract code address
    callback g i32(i32 x) = (callback i32(i32 x))(q);  // 14: rebuild a callable pair
    i32 got = 0;
    if (g) got = g(21);
    Stdio.printf("%d %d\n", q == (pointer)&dbl ? 1 : 0, got);
    return 0;
}
