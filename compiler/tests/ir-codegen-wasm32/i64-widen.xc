// i64 on wasm: shift counts arrive as narrow IR values and must widen to
// i64 (wasm requires count and value the same width); >32-bit literals must
// survive every stage.
extern void putw(i32 v);

void main(void)
    {
    i64 v = 1;
    u8 s = 40;
    i64 big = v << s;       // 1 << 40 — the count is a u8
    putw((i32)(big >> 36)); // 16

    i64 lit = $123456789A;  // literal above 32 bits
    putw((i32)(lit >> 32)); // $12 = 18

    u64 u = 18446744073709551615; // 2^64 - 1
    putw((i32)(u >> 60));         // 15 (logical shift — unsigned)
    }
