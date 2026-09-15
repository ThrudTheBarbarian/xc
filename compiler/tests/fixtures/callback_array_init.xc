// Global aggregate initialiser with symbol-address elements (c2xc bug 11 / xcc
// 167): a callback array `= {&a,&b}` (each element widened to a {recv,code} pair,
// stored into the auto-zeroing slot's payload) and a plain function-pointer array.
i32 printf(u8* f, ...);
i32 dbl(i32 x) { return x * 2; }
i32 sq(i32 x)  { return x * x; }
callback tab i32(i32 x)[2] = { &dbl, &sq };
pointer fns[2] = { (pointer)&dbl, (pointer)&sq };
i32 main(void) {
    i32 a = 0; i32 b = 0;
    if (tab[0]) a = tab[0](5);
    if (tab[1]) b = tab[1](5);
    printf("%d %d %d\n", a, b, fns[0] == (pointer)&dbl ? 1 : 0);
    return 0;
}
