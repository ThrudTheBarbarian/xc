//xtc-flags: target=arm64
// addr_of_local_in_ternary.xc — bug 183 (c2xc bug 19). The address of a local
// taken inside a ternary branch must be pinned; was "& on 'res' not pinned".
i32 printf(u8* f, ...);
i32 f(i32* p) { *p = 7; return 1; }
i32 g(i32* p) { *p = 9; return 2; }
i32 main(void) {
    i32 res = 0; i32 human = 1;
    i32 k = (human != 0 ? f(&res) : g(&res));
    printf("%d %d\n", k, res);
    return 0;
}
