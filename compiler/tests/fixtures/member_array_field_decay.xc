//xtc-flags: target=arm64
// member_array_field_decay.xc — bug 182 (c2xc bug 22). A struct's ARRAY field
// decays to a pointer-to-element when passed to a pointer parameter; loading
// the whole aggregate and passing it to a u8* segfaulted.
i32 printf(u8* f, ...);
struct N { i32 id; u8 name[20]; };
N g;
i32 slen(u8* p) { i32 n = 0; while (p[n] != 0) { n = n + 1; } return n; }
i32 main(void) {
    N s;
    s.id = 1;  s.name[0] = 104; s.name[1] = 105; s.name[2] = 0;
    g.id = 12; g.name[0] = 111; g.name[1] = 0;
    printf("%d %d %d\n", slen(s.name), slen(g.name), g.id);
    return 0;
}
