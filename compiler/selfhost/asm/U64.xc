// U64.xc — a 64-bit unsigned value built from two u32 halves.
// =================================================================
//
// self-hosting M18. xtc has no 64-bit integer, and the arm64 assembler needs
// one in three places that cannot be worked around: the logical-immediate
// (bitmask) encoding is defined over the full 64-bit pattern, `mov Xd, #imm`
// searches four 16-bit lanes of one, and `.quad` emits eight bytes of one.
//
// Everything here is exact — there is no rounding, no saturation and no
// wrapping surprise: `hi` and `lo` are each a full u32 and every operation is
// written so the carry between them is explicit. Only what the assembler uses
// is implemented; this is not a general bignum, and BigNat already exists for
// the decimal conversion that needs one.

#import "Foundation.xc"

class U64
    {
    u32 _hi;
    u32 _lo;

    void init(void)
        {
        _hi = (u32)0;
        _lo = (u32)0;
        }

    static U64* with(u32 hi, u32 lo)
        {
        U64* v = new U64();
        v._hi = hi;
        v._lo = lo;
        return v;
        }

    static U64* fromU32(u32 lo)
        {
        return U64.with((u32)0, lo);
        }
    static U64* zero(void)
        {
        return U64.with((u32)0, (u32)0);
        }
    static U64* ones(void)
        {
        return U64.with((u32)$FFFF_FFFF, (u32)$FFFF_FFFF);
        }

    u32 hi(void)
        {
        return _hi;
        }
    u32 lo(void)
        {
        return _lo;
        }

    bool isZero(void)
        {
        return _hi == (u32)0 && _lo == (u32)0;
        }
    bool isOnes(void)
        {
        return _hi == (u32)$FFFF_FFFF && _lo == (u32)$FFFF_FFFF;
        }
    bool equals64(U64* o)
        {
        return _hi == o._hi && _lo == o._lo;
        }

    U64* notted(void)
        {
        return U64.with(~_hi, ~_lo);
        }
    U64* anded(U64* o)
        {
        return U64.with(_hi & o._hi, _lo & o._lo);
        }
    U64* ored(U64* o)
        {
        return U64.with(_hi | o._hi, _lo | o._lo);
        }
    U64* xored(U64* o)
        {
        return U64.with(_hi ^ o._hi, _lo ^ o._lo);
        }

    // Shifts take the count MODULO NOTHING: a count of 64 or more is a zero
    // result, not the undefined behaviour a bare shift instruction would give.
    U64* shl(u32 n)
        {
        if (n == (u32)0)
            return U64.with(_hi, _lo);
        if (n >= (u32)64)
            return U64.zero();
        if (n >= (u32)32)
            return U64.with(_lo << (n - (u32)32), (u32)0);
        return U64.with((_hi << n) | (_lo >> ((u32)32 - n)), _lo << n);
        }

    U64* shr(u32 n)
        {
        if (n == (u32)0)
            return U64.with(_hi, _lo);
        if (n >= (u32)64)
            return U64.zero();
        if (n >= (u32)32)
            return U64.with((u32)0, _hi >> (n - (u32)32));
        return U64.with(_hi >> n, (_lo >> n) | (_hi << ((u32)32 - n)));
        }

    // The carry out of the low half is the only thing that makes this more
    // than two independent adds.
    U64* plus(U64* o)
        {
        u32 lo = _lo + o._lo;
        u32 carry = lo < _lo ? (u32)1 : (u32)0;
        return U64.with(_hi + o._hi + carry, lo);
        }

    U64* minus(U64* o)
        {
        u32 lo = _lo - o._lo;
        u32 borrow = _lo < o._lo ? (u32)1 : (u32)0;
        return U64.with(_hi - o._hi - borrow, lo);
        }

    bool lessThan(U64* o)
        {
        if (_hi != o._hi)
            return _hi < o._hi;
        return _lo < o._lo;
        }

    // Count trailing zeros; 64 for a zero value, matching the C builtin the
    // reference calls.
    u32 ctz(void)
        {
        if (_lo != (u32)0)
            return ctz32(_lo);
        if (_hi != (u32)0)
            return (u32)32 + ctz32(_hi);
        return (u32)64;
        }

    u32 clz(void)
        {
        if (_hi != (u32)0)
            return clz32(_hi);
        if (_lo != (u32)0)
            return (u32)32 + clz32(_lo);
        return (u32)64;
        }

    static u32 ctz32(u32 v)
        {
        if (v == (u32)0)
            return (u32)32;
        u32 n = (u32)0;
        while ((v & (u32)1) == (u32)0)
            {
            v = v >> (u32)1;
            n = n + (u32)1;
            }
        return n;
        }

    static u32 clz32(u32 v)
        {
        if (v == (u32)0)
            return (u32)32;
        u32 n = (u32)0;
        while ((v & (u32)$8000_0000) == (u32)0)
            {
            v = v << (u32)1;
            n = n + (u32)1;
            }
        return n;
        }

    // The all-ones mask of the low `n` bits. n == 0 gives zero, n >= 64 gives
    // all ones — the two ends a shift-based expression gets wrong.
    static U64* maskLow(u32 n)
        {
        if (n == (u32)0)
            return U64.zero();
        if (n >= (u32)64)
            return U64.ones();
        return U64.ones().shr((u32)64 - n);
        }

    u32 byteAt(u32 i)
        {
        if (i < (u32)4)
            return (_lo >> ((u32)8 * i)) & (u32)$FF;
        if (i < (u32)8)
            return (_hi >> ((u32)8 * (i - (u32)4))) & (u32)$FF;
        return (u32)0;
        }

    // Two's-complement negation, for a literal that was written with a leading
    // minus sign.
    U64* negated(void)
        {
        return notted().plus(U64.fromU32((u32)1));
        }
    }
