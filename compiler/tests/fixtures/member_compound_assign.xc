//xtc-flags: target=arm64
// member_compound_assign.xc — bug 35. `gS.n += k` on a struct MEMBER lvalue;
// the port rejected a member LHS with "assignment target".
i32 printf(u8* f, ...);
struct S { i32 n; }; S gS;
i32 main(void) { gS.n = (i32)10; gS.n += (i32)5; printf("%d\n", gS.n); return 0; }
