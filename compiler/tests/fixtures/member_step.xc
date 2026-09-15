//xtc-flags: target=arm64
// member_step.xc — bug 35. `s.n++` on a struct MEMBER lvalue (the 0.5 ++/--
// rework dropped the member shape).
i32 printf(u8* f, ...);
struct S { i32 n; };
i32 main(void) { S s; s.n = (i32)5; s.n++; s.n++; printf("%d\n", s.n); return 0; }
