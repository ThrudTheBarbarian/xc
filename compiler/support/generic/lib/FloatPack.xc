// FloatPack.xc — conversions for the 16-bit float types, f16 (IEEE binary16,
// pack e5m10) and bf16 (pack e8m7).
//
// The compiler imports this file into a unit that names either type. Their
// values are 16-bit patterns; an operation converts its operands to f32,
// works in f32, and rounds the result back with one of these calls. The
// conversion to f32 is exact, and f32 has more than twice the precision of
// either type plus two bits, so rounding once gives the correctly rounded
// result of the operation.
//
// Every routine takes the pack as its exponent and mantissa widths (e, m),
// with the IEEE special values: the all-ones exponent is infinity (mantissa
// 0) or NaN. Rounding is to nearest, ties to even; subnormals are kept; a
// result too large for the pack is an infinity of its sign. A NaN keeps its
// sign and the top bits of its payload, and is made quiet.

// A float's bits and back. A GPU kernel prints these as its own bit casts
// (the par kernel printers recognise the names); on the CPU they inline to
// the same loads.
u32 _xt_fpk_bits(f32 f)
{
    return *(u32*)&f;
}

f32 _xt_fpk_float(u32 u)
{
    return *(f32*)&u;
}

u64 _xt_fpk_bits64(f64 d)
{
    return *(u64*)&d;
}

// A value given as its sign (0 or 1), the unbiased exponent of bit 31 of sig,
// and sig, rounded to the pack. sig need not have bit 31 set: a value from
// below the normal range of its source passes its bits as they stand. Bit 0
// of sig may be a sticky bit for anything below it.
u16 _xt_fpk_round(u32 sign, i32 unb, u32 sig, u32 e, u32 m)
{
    u32 one = 1;
    i32 bias = (i32)((one << (e - one)) - one);
    i32 te = unb + bias;
    i32 s = 31 - (i32)m;
    if (te < 1)
        {
        // Below the normal range: shift further, to the subnormal scale.
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
    // q holds the leading one at bit m for a normal result, so adding it to
    // the exponent less one gives the encoding; a carry out of the mantissa
    // moves to the next exponent, and a subnormal that rounds up becomes the
    // smallest normal.
    u32 inf = ((one << e) - one) << m;
    u32 bits = ((u32)(te - 1) << m) + q;
    if (bits > inf)
        bits = inf;
    return (u16)((sign << (e + m)) | bits);
}

// A NaN or an infinity of the pack, from a source mantissa's top bits.
u16 _xt_fpk_special(u32 sign, u32 top, u32 e, u32 m)
{
    u32 one = 1;
    u32 inf = ((one << e) - one) << m;
    if (top != 0)
        inf = inf | (one << (m - one)) | (top >> (32 - m));
    return (u16)((sign << (e + m)) | inf);
}

u16 _xt_fpk_pack_f32(f32 f, u32 e, u32 m)
{
    u32 x = _xt_fpk_bits(f);
    u32 sign = x >> 31;
    u32 ex = (x >> 23) & (u32)0xFF;
    u32 mant = x & (u32)0x7FFFFF;
    if (ex == (u32)0xFF)
        return _xt_fpk_special(sign, mant << 9, e, m);
    if (ex == 0)
        {
        if (mant == 0)
            return (u16)(sign << (e + m));
        return _xt_fpk_round(sign, -126, mant << 8, e, m);
        }
    return _xt_fpk_round(sign, (i32)ex - 127, (mant | (u32)0x800000) << 8, e, m);
}

u16 _xt_fpk_pack_f64(f64 d, u32 e, u32 m)
{
    u64 x = _xt_fpk_bits64(d);
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
            return _xt_fpk_special(sign, 0, e, m);
        return _xt_fpk_special(sign, (sig << 1) | 1, e, m);
        }
    if (ex == 0)
        {
        if (mhi == 0 && lo == 0)
            return (u16)(sign << (e + m));
        return _xt_fpk_round(sign, -1022, sig, e, m);
        }
    return _xt_fpk_round(sign, (i32)ex - 1023, sig | (u32)0x80000000, e, m);
}

u16 _xt_fpk_mag32(u32 v, u32 sign, u32 e, u32 m)
{
    if (v == 0)
        return 0;
    i32 unb = 31;
    while ((v & (u32)0x80000000) == 0)
        {
        v = v << 1;
        unb = unb - 1;
        }
    return _xt_fpk_round(sign, unb, v, e, m);
}

u16 _xt_fpk_mag64(u64 v, u32 sign, u32 e, u32 m)
{
    u32 hi = (u32)(v >> 32);
    u32 lo = (u32)v;
    if (hi == 0)
        return _xt_fpk_mag32(lo, sign, e, m);
    i32 unb = 63;
    while ((hi & (u32)0x80000000) == 0)
        {
        hi = (hi << 1) | (lo >> 31);
        lo = lo << 1;
        unb = unb - 1;
        }
    if (lo != 0)
        hi = hi | 1;
    return _xt_fpk_round(sign, unb, hi, e, m);
}

u16 _xt_fpk_pack_u32(u32 v, u32 e, u32 m)
{
    return _xt_fpk_mag32(v, 0, e, m);
}

u16 _xt_fpk_pack_i32(i32 v, u32 e, u32 m)
{
    if (v < 0)
        return _xt_fpk_mag32(0 - (u32)v, 1, e, m);
    return _xt_fpk_mag32((u32)v, 0, e, m);
}

u16 _xt_fpk_pack_u64(u64 v, u32 e, u32 m)
{
    return _xt_fpk_mag64(v, 0, e, m);
}

u16 _xt_fpk_pack_i64(i64 v, u32 e, u32 m)
{
    if (v < 0)
        return _xt_fpk_mag64(0 - (u64)v, 1, e, m);
    return _xt_fpk_mag64((u64)v, 0, e, m);
}

// The f32 holding a pack's value, which it always holds exactly.
f32 _xt_fpk_unpack(u16 h, u32 e, u32 m)
{
    u32 one = 1;
    u32 x = h;
    u32 sign = (x >> (e + m)) & one;
    u32 emax = (one << e) - one;
    u32 ex = (x >> m) & emax;
    u32 mant = x & ((one << m) - one);
    u32 sh = 23 - m;
    i32 bias = (i32)((one << (e - one)) - one);
    u32 bits = 0;
    if (ex == emax)
        bits = (u32)0x7F800000 | (mant << sh);
    else if (ex == 0)
        {
        if (mant != 0 && e == 8)
            bits = mant << sh;                  // f32's own exponent range
        else if (mant != 0)
            {
            i32 unb = 1 - bias;
            while ((mant & (one << m)) == 0)
                {
                mant = mant << 1;
                unb = unb - 1;
                }
            bits = ((u32)(unb + 127) << 23) | ((mant & ((one << m) - one)) << sh);
            }
        }
    else
        bits = ((u32)((i32)ex - bias + 127) << 23) | (mant << sh);
    bits = bits | (sign << 31);
    return _xt_fpk_float(bits);
}

// NaN by its bits: a software float's comparison need not see one.
bool _xt_fpk_nan(f32 x)
{
    u32 b = _xt_fpk_bits(x);
    return (b & (u32)0x7FFFFFFF) > (u32)0x7F800000;
}

// To an integer: toward zero, a value beyond the range saturates to its end,
// and a NaN is 0. lo and hi are the destination type's range.
i32 _xt_fpk_sat_i32(f32 x, i32 lo, i32 hi)
{
    if (_xt_fpk_nan(x))
        return 0;
    if (x <= (f32)lo)
        return lo;
    if (x >= (f32)hi)
        return hi;
    return (i32)x;
}

u32 _xt_fpk_sat_u32(f32 x, u32 hi)
{
    if (_xt_fpk_nan(x) || x <= 0.0)
        return 0;
    if (x >= (f32)hi)
        return hi;
    return (u32)x;
}

i64 _xt_fpk_sat_i64(f32 x, i64 lo, i64 hi)
{
    if (_xt_fpk_nan(x))
        return 0;
    if (x <= (f32)lo)
        return lo;
    if (x >= (f32)hi)
        return hi;
    return (i64)x;
}

u64 _xt_fpk_sat_u64(f32 x, u64 hi)
{
    if (_xt_fpk_nan(x) || x <= 0.0)
        return 0;
    if (x >= (f32)hi)
        return hi;
    return (u64)x;
}
