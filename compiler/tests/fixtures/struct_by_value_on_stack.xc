//xtc-flags: target=arm64
// struct_by_value_on_stack.xc — bug 185 (c2xc bug 20). A by-value aggregate
// past x7 is passed ENTIRELY on the AAPCS outgoing stack. Was left in no-home
// and read frame litter.
i32 printf(u8* f, ...);
struct S { i64 a; i64 b; i64 c; };
i64 f(i32 a0, i32 a1, i32 a2, i32 a3, i32 a4, i32 a5, i32 a6, i32 a7, S s) {
    return s.a + s.b + s.c + (i64)a7;
}
i64 g(S s, i32 k) { return s.a + (i64)k; }
i32 main(void) {
    S s; s.a = 1; s.b = 2; s.c = 3;
    printf("%d %d\n", (i32)g(s, 4), (i32)f(0,0,0,0,0,0,0,7,s));
    return 0;
}
