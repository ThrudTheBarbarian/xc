// ParSoftFloat.xc — float division and square root, correctly rounded, in
// integer arithmetic: what a `par` block whose goal is accuracy calls on a GPU
// that does not round them exactly (Vulkan and WebGPU allow 2.5 ulp for a
// division and more for a square root).
//
// The GPU emitters call these in place of the hardware operation; on the CPU
// they are not used (its division and square root are exact). They read a
// float's bits through xcF32Bits / xcF32FromBits, which the GPU emitters turn
// into a bit cast. Round to nearest, ties to even, subnormals in and out; a
// NaN operand is returned quieted, an invalid operation gives the default NaN.

u32 xcF32Bits(float f)
    {
    return *(u32*)&f;
    }

float xcF32FromBits(u32 u)
    {
    return *(float*)&u;
    }

// The leading zeros of a nonzero 32-bit value.
u32 xcSfClz(u32 x)
    {
    u32 n = (u32)0;
    if ((x & (u32)0xFFFF0000) == (u32)0) { n = n + (u32)16; x = x << (u32)16; }
    if ((x & (u32)0xFF000000) == (u32)0) { n = n + (u32)8; x = x << (u32)8; }
    if ((x & (u32)0xF0000000) == (u32)0) { n = n + (u32)4; x = x << (u32)4; }
    if ((x & (u32)0xC0000000) == (u32)0) { n = n + (u32)2; x = x << (u32)2; }
    if ((x & (u32)0x80000000) == (u32)0) { n = n + (u32)1; }
    return n;
    }

// A result from its sign, its unbiased exponent and a 26-bit significand
// whose top bit (bit 25) is the leading one, plus a sticky flag for anything
// below it: rounded to nearest even, to a subnormal or an infinity as the
// exponent requires.
u32 xcSfRound(u32 sign, i32 e, u32 m, bool sticky)
    {
    i32 be = e + (i32)127;
    if (be <= (i32)0)
        {
        // Subnormal: shift right by 1 - be more, folding what falls off into
        // the sticky flag.
        u32 sh = (u32)((i32)1 - be);
        if (sh > (u32)26)
            {
            sticky = sticky || m != (u32)0;
            m = (u32)0;
            }
        else
            {
            sticky = sticky || (m & (((u32)1 << sh) - (u32)1)) != (u32)0;
            m = m >> sh;
            }
        be = (i32)0;
        }
    // m: 24 result bits, then the round bit and one more (guard) bit.
    u32 keep = m >> (u32)2;
    u32 rest = m & (u32)3;
    bool up = rest > (u32)2 || (rest == (u32)2 && (sticky || (keep & (u32)1) != (u32)0));
    if (up)
        keep = keep + (u32)1;
    if (be == (i32)0)
        {
        // A subnormal that rounded up into the normal range becomes the
        // smallest normal: bit 23 set is exactly that encoding.
        return sign | keep;
        }
    if (keep == (u32)0x1000000)
        {
        keep = (u32)0x800000;
        be = be + (i32)1;
        }
    if (be >= (i32)255)
        return sign | (u32)0x7F800000;
    return sign | ((u32)be << (u32)23) | (keep & (u32)0x7FFFFF);
    }

float xcFdivRn(float a, float b)
    {
    u32 x = xcF32Bits(a);
    u32 y = xcF32Bits(b);
    u32 sign = (x ^ y) & (u32)0x80000000;
    u32 ex = (x >> (u32)23) & (u32)0xFF;
    u32 ey = (y >> (u32)23) & (u32)0xFF;
    u32 mx = x & (u32)0x7FFFFF;
    u32 my = y & (u32)0x7FFFFF;
    if (ex == (u32)0xFF && mx != (u32)0)
        return xcF32FromBits(x | (u32)0x400000);
    if (ey == (u32)0xFF && my != (u32)0)
        return xcF32FromBits(y | (u32)0x400000);
    if (ex == (u32)0xFF)
        {
        if (ey == (u32)0xFF)
            return xcF32FromBits((u32)0x7FC00000);              // inf / inf
        return xcF32FromBits(sign | (u32)0x7F800000);
        }
    if (ey == (u32)0xFF)
        return xcF32FromBits(sign);                             // x / inf
    if (ey == (u32)0 && my == (u32)0)
        {
        if (ex == (u32)0 && mx == (u32)0)
            return xcF32FromBits((u32)0x7FC00000);              // 0 / 0
        return xcF32FromBits(sign | (u32)0x7F800000);           // x / 0
        }
    if (ex == (u32)0 && mx == (u32)0)
        return xcF32FromBits(sign);                             // 0 / y
    // Unbiased exponents and 24-bit significands, subnormals normalised.
    i32 eA = (i32)ex - (i32)127;
    i32 eB = (i32)ey - (i32)127;
    if (ex == (u32)0)
        {
        u32 s = xcSfClz(mx) - (u32)8;
        mx = mx << s;
        eA = (i32)-126 - (i32)s;
        }
    else
        mx = mx | (u32)0x800000;
    if (ey == (u32)0)
        {
        u32 s = xcSfClz(my) - (u32)8;
        my = my << s;
        eB = (i32)-126 - (i32)s;
        }
    else
        my = my | (u32)0x800000;
    i32 e = eA - eB;
    if (mx < my)
        {
        mx = mx << (u32)1;
        e = e - (i32)1;
        }
    // 26 quotient bits (the leading one, 23 more, the round bit and a guard
    // bit) by restoring division; what is left over is the sticky flag.
    u32 q = (u32)0;
    u32 r = mx;
    for (u32 k = (u32)0; k < (u32)26; k = k + (u32)1)
        {
        q = q << (u32)1;
        if (r >= my)
            {
            r = r - my;
            q = q | (u32)1;
            }
        r = r << (u32)1;
        }
    return xcF32FromBits(xcSfRound(sign, e, q, r != (u32)0));
    }

float xcFsqrtRn(float a)
    {
    u32 x = xcF32Bits(a);
    u32 ex = (x >> (u32)23) & (u32)0xFF;
    u32 mx = x & (u32)0x7FFFFF;
    if (ex == (u32)0xFF && mx != (u32)0)
        return xcF32FromBits(x | (u32)0x400000);
    if ((x & (u32)0x7FFFFFFF) == (u32)0)
        return a;                                               // ±0
    if ((x & (u32)0x80000000) != (u32)0)
        return xcF32FromBits((u32)0x7FC00000);                  // negative
    if (ex == (u32)0xFF)
        return a;                                               // +inf
    i32 e = (i32)ex - (i32)127;
    if (ex == (u32)0)
        {
        u32 s = xcSfClz(mx) - (u32)8;
        mx = mx << s;
        e = (i32)-126 - (i32)s;
        }
    else
        mx = mx | (u32)0x800000;
    // value = mx * 2^(e - 23). Make the exponent even, so the root's is half.
    if ((e & (i32)1) != (i32)0)
        {
        mx = mx << (u32)1;
        e = e - (i32)1;
        }
    // The root of R = mx * 2^27, in [2^50, 2^52): 26 two-bit digits by the
    // digit-by-digit method, giving 26 root bits with the leading one at bit
    // 25. The root is sqrt(value) * 2^(25 - e/2). R is held as hi (its bits
    // 51..32) and lo (31..0).
    u32 hi = mx >> (u32)5;
    u32 lo = mx << (u32)27;
    u32 root = (u32)0;
    u32 rem = (u32)0;
    for (u32 k = (u32)0; k < (u32)26; k = k + (u32)1)
        {
        // The next two bits of R from the top: bits 51 and 50 of what is left.
        u32 d = (hi >> (u32)18) & (u32)3;
        hi = ((hi << (u32)2) | (lo >> (u32)30)) & (u32)0xFFFFF;
        lo = lo << (u32)2;
        rem = (rem << (u32)2) | d;
        u32 t = (root << (u32)2) | (u32)1;
        root = root << (u32)1;
        if (rem >= t)
            {
            rem = rem - t;
            root = root | (u32)1;
            }
        }
    return xcF32FromBits(xcSfRound((u32)0, e / (i32)2, root, rem != (u32)0));
    }
