// Fp4.xc — f4 (OCP MX FP4, e2m1) conversions by name, and an atomic store of
// one element of an f4 array.
//
// fp4E2M1 rounds an f64 to f4 as a cast does: to nearest, ties to even, a
// value beyond 6 and an infinity becoming ±6, and NaN +0. fp4E2M1Value gives
// an f4's value, exactly. Both are `extern`, so C may call them: C has no
// 4-bit float type and sees an f4 as its bit pattern in the low nibble of a
// uint8_t, and an f4 array as bytes, two elements to each, element 0 in the
// low nibble:
//
//   uint8_t fp4E2M1(double x);
//   float fp4E2M1Value(uint8_t v);
//
// f4StoreAtomic(a, i, v) stores element i of a in one atomic step. `a[i] = v`
// reads the element's byte, replaces one nibble and writes the byte back, so
// two threads writing the two elements of one byte can lose one of the
// writes. f4StoreAtomic swaps the 32-bit word holding the byte in, compared
// with what it read, and tries again when another thread changed the word
// meanwhile. Not on xt6502 or m68k, which have no threads.

#import "FloatPack.xc"
#import "FloatPackKinds.xc"

extern f4 fp4E2M1(f64 x)
{
    return (f4)x;
}

extern f32 fp4E2M1Value(f4 v)
{
    return v;
}

#if !(ARCH_6502 || ARCH_m68k)
i32 _xt_atomic_load_i32(pointer slot);
i32 _xt_atomic_cas_i32(pointer slot, i32 expected, i32 desired);

void f4StoreAtomic(f4[] a, u64 i, f4 v)
{
    u8* at = (u8*)a + (i >> 1);
    u8* vb = (u8*)&v;
    u32 off = (u32)((u64)at & 3);
    u32 shift = off * 8 + (u32)(i & 1) * 4;
    u32 mask = (u32)15 << shift;
    u32 bits = ((u32)vb[0] & 15) << shift;
    pointer word = (pointer)(at - off);
    while (true)
        {
        i32 old = _xt_atomic_load_i32(word);
        i32 now = (i32)(((u32)old & ~mask) | bits);
        if (_xt_atomic_cas_i32(word, old, now) != 0)
            return;
        }
}
#endif
