// FloatPackKinds.xc — conversions for the packs whose special values are not
// IEEE's, and for the unsigned scale: f8 (OCP FP8 E4M3), f8:pack(ue8m0), and
// any pack written with the kind finite or none.
//
// The compiler imports this file, beside FloatPack.xc, into a unit that uses
// such a pack. Each routine is FloatPack.xc's of the same name with a `k`
// added, and takes the pack as (e, m, k): the exponent and mantissa widths,
// and the pack word k:
//
//   k & 3   the special values: 0 ieee (the all-ones exponent is infinity or
//           NaN), 1 finite (no infinity; only the all-ones pattern is NaN),
//           2 none (no infinity and no NaN)
//   k & 4   unsigned: ue8m0, the value 2^(E-127) for E from 0 to 254, 0xFF NaN,
//           no sign, no zero, no infinity
//   k & 8   a value beyond the largest finite one becomes NaN (finite packs;
//           an unsigned one too) instead of saturating
//   k & 16  a value beyond the largest finite one, and an infinity, become the
//           largest finite value (ieee packs) instead of an infinity
//
// The compiler passes only the kind and 4; the explicit conversions (Fp8.xc)
// pass 8 and 16. Rounding is to nearest, ties to even, with subnormals kept.
// By default a pack without infinity saturates: a value too large becomes its
// largest finite value, as an infinity does. A NaN becomes the all-ones
// pattern of its sign (finite), 0xFF (unsigned) or +0 (none, which has no
// NaN). For ue8m0, zero and values below 2^-127 become 2^-127 (0x00), and a
// negative value becomes NaN. Patterns travel as u16.

// A value given as its sign, the unbiased exponent of bit 31 of sig, and sig,
// rounded to the pack (FloatPack.xc's _xt_fpk_round, with the kinds). Bit 0
// of sig may be a sticky bit for anything below it.
u16 _xt_fpk_roundk(u32 sign, i32 unb, u32 sig, u32 e, u32 m, u32 k)
{
    u32 one = 1;
    if ((k & 4) != 0)
        {
        // The nearest power of two, ties to the even exponent.
        if (sign != 0)
            return 0xFF;
        while ((sig & (u32)0x80000000) == 0)
            {
            sig = sig << 1;
            unb = unb - 1;
            }
        i32 ue = unb + 127;
        u32 urem = sig & (u32)0x7FFFFFFF;
        if (urem > (u32)0x40000000 || (urem == (u32)0x40000000 && (ue & 1) != 0))
            ue = ue + 1;
        if (ue < 0)
            return 0;
        if (ue > 254)
            {
            if ((k & 8) != 0)
                return 0xFF;
            return 0xFE;
            }
        return (u16)ue;
        }
    i32 bias = (i32)((one << (e - one)) - one);
    i32 te = unb + bias;
    i32 s = 31 - (i32)m;
    if (te < 1)
        {
        s = s + 1 - te;
        te = 1;
        }
    u32 q = 0;
    if (s == 32)
        {
        if (sig > (u32)0x80000000)
            q = 1;
        }
    else if (s < 32)
        {
        u32 us = (u32)s;
        q = sig >> us;
        u32 rem = sig & ((one << us) - one);
        u32 half = one << (us - one);
        if (rem > half || (rem == half && (q & one) != 0))
            q = q + one;
        }
    u32 bits = ((u32)(te - 1) << m) + q;
    u32 all = (one << (e + m)) - one;
    u32 inf = ((one << e) - one) << m;
    u32 kind = k & 3;
    if (kind == 0 && bits >= inf)
        {
        bits = inf;
        if ((k & 16) != 0)
            bits = inf - one;
        }
    else if (kind == 1 && bits >= all)
        {
        bits = all - one;
        if ((k & 8) != 0)
            bits = all;
        }
    else if (kind == 2 && bits > all)
        bits = all;
    return (u16)((sign << (e + m)) | bits);
}

// An infinity (top 0) or a NaN (top: the source mantissa's top bits, nonzero)
// of the given sign, as the pack takes it.
u16 _xt_fpk_specialk(u32 sign, u32 top, u32 e, u32 m, u32 k)
{
    u32 one = 1;
    u32 kind = k & 3;
    if ((k & 4) != 0)
        {
        if (top != 0 || sign != 0 || (k & 8) != 0)
            return 0xFF;
        return 0xFE;
        }
    u32 all = (one << (e + m)) - one;
    u32 sbit = sign << (e + m);
    u32 inf = ((one << e) - one) << m;
    if (top == 0)
        {
        if (kind == 0)
            {
            if ((k & 16) != 0)
                return (u16)(sbit | (inf - one));
            return (u16)(sbit | inf);
            }
        if (kind == 1)
            {
            if ((k & 8) != 0)
                return (u16)(sbit | all);
            return (u16)(sbit | (all - one));
            }
        return (u16)(sbit | all);
        }
    if (kind == 1)
        return (u16)(sbit | all);
    if (kind == 2)
        return 0;
    return (u16)(sbit | inf | (one << (m - one)) | (top >> (32 - m)));
}

// A zero of the given sign: ue8m0 has none, and takes its smallest value.
u16 _xt_fpk_zerok(u32 sign, u32 e, u32 m, u32 k)
{
    if ((k & 4) != 0)
        return 0;
    return (u16)(sign << (e + m));
}

u16 _xt_fpk_pack_f32k(f32 f, u32 e, u32 m, u32 k)
{
    u32 x = *(u32*)&f;
    u32 sign = x >> 31;
    u32 ex = (x >> 23) & (u32)0xFF;
    u32 mant = x & (u32)0x7FFFFF;
    if (ex == (u32)0xFF)
        return _xt_fpk_specialk(sign, mant << 9, e, m, k);
    if (ex == 0)
        {
        if (mant == 0)
            return _xt_fpk_zerok(sign, e, m, k);
        return _xt_fpk_roundk(sign, -126, mant << 8, e, m, k);
        }
    return _xt_fpk_roundk(sign, (i32)ex - 127, (mant | (u32)0x800000) << 8, e, m, k);
}

u16 _xt_fpk_pack_f64k(f64 d, u32 e, u32 m, u32 k)
{
    u64 x = *(u64*)&d;
    u32 hi = (u32)(x >> 32);
    u32 lo = (u32)x;
    u32 sign = hi >> 31;
    u32 ex = (hi >> 20) & (u32)0x7FF;
    u32 mhi = hi & (u32)0xFFFFF;
    // The top 31 bits of the 52-bit mantissa below bit 31, the rest folded
    // into a sticky bit 0.
    u32 sig = (mhi << 11) | (lo >> 21);
    if ((lo & (u32)0x1FFFFF) != 0)
        sig = sig | 1;
    if (ex == (u32)0x7FF)
        {
        if (mhi == 0 && lo == 0)
            return _xt_fpk_specialk(sign, 0, e, m, k);
        return _xt_fpk_specialk(sign, (sig << 1) | 1, e, m, k);
        }
    if (ex == 0)
        {
        if (mhi == 0 && lo == 0)
            return _xt_fpk_zerok(sign, e, m, k);
        return _xt_fpk_roundk(sign, -1022, sig, e, m, k);
        }
    return _xt_fpk_roundk(sign, (i32)ex - 1023, sig | (u32)0x80000000, e, m, k);
}

u16 _xt_fpk_mag32k(u32 v, u32 sign, u32 e, u32 m, u32 k)
{
    if (v == 0)
        return _xt_fpk_zerok(0, e, m, k);
    i32 unb = 31;
    while ((v & (u32)0x80000000) == 0)
        {
        v = v << 1;
        unb = unb - 1;
        }
    return _xt_fpk_roundk(sign, unb, v, e, m, k);
}

u16 _xt_fpk_mag64k(u64 v, u32 sign, u32 e, u32 m, u32 k)
{
    u32 hi = (u32)(v >> 32);
    u32 lo = (u32)v;
    if (hi == 0)
        return _xt_fpk_mag32k(lo, sign, e, m, k);
    i32 unb = 63;
    while ((hi & (u32)0x80000000) == 0)
        {
        hi = (hi << 1) | (lo >> 31);
        lo = lo << 1;
        unb = unb - 1;
        }
    if (lo != 0)
        hi = hi | 1;
    return _xt_fpk_roundk(sign, unb, hi, e, m, k);
}

u16 _xt_fpk_pack_u32k(u32 v, u32 e, u32 m, u32 k)
{
    return _xt_fpk_mag32k(v, 0, e, m, k);
}

u16 _xt_fpk_pack_i32k(i32 v, u32 e, u32 m, u32 k)
{
    if (v < 0)
        return _xt_fpk_mag32k(0 - (u32)v, 1, e, m, k);
    return _xt_fpk_mag32k((u32)v, 0, e, m, k);
}

u16 _xt_fpk_pack_u64k(u64 v, u32 e, u32 m, u32 k)
{
    return _xt_fpk_mag64k(v, 0, e, m, k);
}

u16 _xt_fpk_pack_i64k(i64 v, u32 e, u32 m, u32 k)
{
    if (v < 0)
        return _xt_fpk_mag64k(0 - (u64)v, 1, e, m, k);
    return _xt_fpk_mag64k((u64)v, 0, e, m, k);
}

// The f32 holding a pack's value, which it always holds exactly (a finite or
// none pack has at most 7 exponent bits, so its top binade fits f32).
f32 _xt_fpk_unpackk(u16 h, u32 e, u32 m, u32 k)
{
    u32 one = 1;
    u32 x = h;
    u32 bits = 0;
    if ((k & 4) != 0)
        {
        u32 ue = x & (u32)0xFF;
        if (ue == (u32)0xFF)
            bits = (u32)0x7FC00000;
        else if (ue == 0)
            bits = (u32)0x00400000;                  // 2^-127, an f32 subnormal
        else
            bits = ue << 23;
        return *(f32*)&bits;
        }
    u32 sign = (x >> (e + m)) & one;
    u32 emax = (one << e) - one;
    u32 mmax = (one << m) - one;
    u32 ex = (x >> m) & emax;
    u32 mant = x & mmax;
    u32 sh = 23 - m;
    i32 bias = (i32)((one << (e - one)) - one);
    u32 kind = k & 3;
    if (ex == emax && kind == 0)
        bits = (u32)0x7F800000 | (mant << sh);
    else if (ex == emax && kind == 1 && mant == mmax)
        bits = (u32)0x7FC00000;
    else if (ex == 0)
        {
        if (mant != 0)
            {
            i32 unb = 1 - bias;
            while ((mant & (one << m)) == 0)
                {
                mant = mant << 1;
                unb = unb - 1;
                }
            bits = ((u32)(unb + 127) << 23) | ((mant & mmax) << sh);
            }
        }
    else
        bits = ((u32)((i32)ex - bias + 127) << 23) | (mant << sh);
    bits = bits | (sign << 31);
    return *(f32*)&bits;
}
