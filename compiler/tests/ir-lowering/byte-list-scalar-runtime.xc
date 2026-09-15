// byte-list-scalar-runtime — a sized-scalar byte-list whose entries are
// NOT all compile-time constants can't fold to a single Const. The
// pre-scan pins the local and the value is assembled by element-wise
// byte stores into the slot, low byte first (task #61 / #62).
//
// mk16: a u16 built from two runtime bytes — little-endian on both
// backends, so fully arch-neutral.
//
// mkf / mkd: a float / double built from the xtc 5-/8-byte pattern with
// runtime mantissa bytes (the Math.xc floatFromBytes / doubleFromBytes
// shape). The bytes are stored in xtc float-format order — correct on
// xt6502 (whose float/double storage IS that format); arm64's native
// IEEE makes this the known per-arch float-format gap. The pinned frame
// is sized in IR-type widths so §12.11 stays consistent even for the
// 5-byte `float` (which maps to the 4-byte IR F32).
u16 mk16(u8 lo, u8 hi)
    {
    u16 v = {lo, hi};
    return v;
    }

float mkf(u8 m0, u8 m1, u8 m2)
    {
    float r = {$00, $01, m0, m1, m2};
    return r;
    }

double mkd(u8 m0, u8 m1, u8 m2, u8 m3, u8 m4, u8 m5)
    {
    double r = {$00, $FF, m0, m1, m2, m3, m4, m5};
    return r;
    }
