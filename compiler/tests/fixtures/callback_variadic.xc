// A VARIADIC callback FIELD (bug 165b) — `callback void(u8* a0, ...) pr;`, the
// shape c2xc emits for a variadic C function pointer. A
// callback is erased to a 2-word bound pair whatever its signature, so the
// trailing `...` types the field exactly like its non-variadic prefix
// `void(u8*)`; it is accepted, stored, and called through the field. Both
// compilers must accept it and agree byte-for-byte — the port used to SILENTLY
// DROP the whole declaration, the reference errored "Unknown type '...'".
i32 printf(u8* fmt, ...);

struct sink { i32 tag; callback void(u8* a0, ...) pr; }

// A concrete handler stored into the variadic field (its erased type is the
// non-variadic prefix, so a void(u8*) function matches).
void emit(u8* a0) { printf("emit %s\n", a0); }

i32 main(void) {
    sink s;
    s.tag = 9;
    s.pr = &emit;
    s.pr("hi");
    printf("tag=%d\n", s.tag);
    return 0;
}
