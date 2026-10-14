// simd_ptr — the `simd:` pointer qualifier (page-aligned / GPU-reachable
// storage) parses and prints on a global, a parameter and a local, exactly
// like `weak:` does. (Allocation alignment and the conversion ban are checked
// by their own stages; this pins the parse/type-spelling parity.)
simd: u8* g;
void touch(simd: u8* p) { p[0] = (u8)1; }
i32 main(void)
{
    simd: u8* local;
    local = g;
    touch(local);
    return 0;
}
