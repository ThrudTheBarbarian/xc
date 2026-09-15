// byte-list-scalar-float — runtime-byte float construction, executed.
//
// `m` is an identifier, so the byte-list `{$00,$01,m,$00,$00}` is NOT
// all-constant and takes the element-wise byte-store path (task #62):
// the float local is pinned and assembled byte-by-byte, then read back
// as F32. The bytes are xtc's 5-byte float format for 3.0 (the same
// pattern byte-list-init's `three()` uses as a constant), so on xt6502
// the round-trip is exact and (i16)r == 3.
//
// The xt6502 codegen harness calls mkf3() and prints the i16 — proving
// the 5 stored bytes load back as the correct float, not just that the
// IR is well-formed.
i16 mkf3(void)
    {
    u8 m = $80;
    float r = {$00, $01, m, $00, $00};
    return (i16)r;
    }
