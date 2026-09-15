//xtc-flags: target=arm64
// callback_pair_on_stack.xc — bug 185 (c2xc bug 21). A callback pair (two
// words) past x7 is passed on the stack; the two-word aggregate overflowed the
// register bank and crashed.
i32 printf(u8* f, ...);
i32 dbl(i32 x) { return x * 2; }
i32 f(i32 a0, i32 a1, i32 a2, i32 a3, i32 a4, i32 a5, i32 a6, i32 a7,
      callback g i32(i32 x), i32 a9) {
    return g(a9) + a7;
}
i32 main(void) { printf("%d\n", f(0,0,0,0,0,0,0,1,&dbl,20)); return 0; }
