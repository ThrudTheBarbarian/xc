// FloatEncoding.xc — a float literal's IEEE-754 bytes.
// =================================================================
//
// self-hosting M4/M5. The port of the literal path in
// src/xtc/support/XTFloatEncoding.m, plus the decimal-text → double conversion
// the Objective-C lexer gets from `-[NSString doubleValue]`.
//
// The lexer converts float literals AT LEX TIME, so the AST carries bytes
// rather than text and the dump compares those bytes. They are IEEE-754,
// little-endian — 4 for a single, 8 for a `d` literal. They did not used to be:
// the literal went through xtc's own flags+exponent+mantissa softfloat format,
// which holds 48 mantissa bits where a double has 53, and the lowering decoded
// it straight back to a double. Every `d` literal lost bits in a detour between
// two IEEE endpoints (Task #835).
//
// The conversion is CORRECTLY ROUNDED, like strtod. It used to be an
// accumulate-and-divide in double arithmetic, which agreed with strtod on the
// literals a program usually writes and disagreed by one unit in the last place
// on three of the series coefficients in support/xt6502/lib/Math.xc — a
// difference the AST harness reported and nothing else would have.
//
// Rounding correctly means deciding on the EXACT value, and the exact value of
// a thirty-digit literal times a power of ten does not fit in a double. So the
// digits go into a BigNat, the power of ten goes into another, the division is
// done bit by bit, and the significand is carried out as integer bits rather
// than as a double — see _convert.

#import "Foundation.xc"
#import "BigNat.xc"

class FloatEncoding
    {
    u8 _unused;
    void init(void)
        {
        _unused = (u8)0;
        }

    // Scan decimal text into an exact integer M and a decimal exponent k, so
    // the value is M × 10^k, and hand that to _convert — which is where the one
    // rounding happens. Handles a leading sign, digits, a fraction, and an
    // `e±nn` exponent: the shapes the lexer accepts. Returns the SIGN; the
    // magnitude comes back in _rHi / _rLo / _rExp.
    static bool _parseInto(String* text)
        {
        u32 i = (u32)0;
        u32 n = text.byteLength();
        bool neg = false;

        if (i < n && (text.byteAt(i) == (u8)'-' || text.byteAt(i) == (u8)'+'))
            {
            neg = (text.byteAt(i) == (u8)'-');
            i = i + (u32)1;
            }

        BigNat* m = BigNat.withU32((u32)0);
        i32 k = (i32)0;
        // A literal with more digits than the BigNat can hold is not a thing
        // any source writes — 400 digits is ~1330 bits, and the buffer is 1536.
        // Past that the extra digits are dropped and the exponent compensates,
        // which is the one place this is not exact.
        u32 digits = (u32)0;
        while (i < n && text.byteAt(i) >= (u8)'0' && text.byteAt(i) <= (u8)'9')
            {
            if (digits < (u32)400)
                {
                m.mulAddSmall((u32)10, (u32)(text.byteAt(i) - (u8)'0'));
                digits = digits + (u32)1;
                }
            else
                {
                k = k + (i32)1;
                }
            i = i + (u32)1;
            }
        if (i < n && text.byteAt(i) == (u8)'.')
            {
            i = i + (u32)1;
            while (i < n && text.byteAt(i) >= (u8)'0' && text.byteAt(i) <= (u8)'9')
                {
                if (digits < (u32)400)
                    {
                    m.mulAddSmall((u32)10, (u32)(text.byteAt(i) - (u8)'0'));
                    digits = digits + (u32)1;
                    k = k - (i32)1;
                    }
                i = i + (u32)1;
                }
            }
        if (i < n && (text.byteAt(i) == (u8)'e' || text.byteAt(i) == (u8)'E'))
            {
            i = i + (u32)1;
            bool expNeg = false;
            if (i < n && (text.byteAt(i) == (u8)'-' || text.byteAt(i) == (u8)'+'))
                {
                expNeg = (text.byteAt(i) == (u8)'-');
                i = i + (u32)1;
                }
            u32 e = (u32)0;
            while (i < n && text.byteAt(i) >= (u8)'0' && text.byteAt(i) <= (u8)'9')
                {
                if (e < (u32)100000)
                    e = e * (u32)10 + (u32)(text.byteAt(i) - (u8)'0');
                i = i + (u32)1;
                }
            if (expNeg)
                k = k - (i32)e;
            else
                k = k + (i32)e;
            }

        FloatEncoding._convert(m, k);
        return neg;
        }

    // M × 10^k → the IEEE-754 bits of the correctly-rounded double, as
    // (sign, biased exponent, 53-bit significand in two halves).
    //
    // The whole job is to know the exact quotient's bits. Write the value as a
    // fraction — numerator M×10^k over 1 when k ≥ 0, M over 10^-k when k < 0 —
    // then shift the numerator until it has exactly 60 more bits than the
    // denominator, so the quotient has 60 or 61 of them. Sixty-one rounds of
    // compare / subtract / halve read those bits off the top: the first 53 from
    // the leading 1 are the significand, the next is the rounding bit, and
    // everything after it (including a non-zero remainder) is the sticky bit.
    // That is enough to round exactly, which double arithmetic never is.
    //
    // The significand is carried as two u32 halves rather than a double,
    // because 53 bits do not fit in one and the point of this routine is to
    // hand back BITS. Results land in _rHi (bits 52..32), _rLo (bits 31..0) and
    // _rExp (unbiased, for the 1.f form); _rZero says the value is zero.
    static u32 _rHi;
    static u32 _rLo;
    static i32 _rExp;
    static bool _rZero;
    static bool _rInf;

    static void _convert(BigNat* m, i32 k)
        {
        _rHi = (u32)0;
        _rLo = (u32)0;
        _rExp = (i32)0;
        _rZero = false;
        _rInf = false;

        if (m.isZero())
            {
            _rZero = true;
            return;
            }
        // Past these the result is inf or 0 and the BigNat would overflow.
        if (k > (i32)400)
            {
            _rInf = true;
            return;
            }
        if (k < (i32)-400)
            {
            _rZero = true;
            return;
            }

        BigNat* num = new BigNat();
        BigNat* den = new BigNat();
        num.copyFrom(m);
        if (k >= (i32)0)
            {
            for (i32 t = (i32)0; t < k; t = t + (i32)1)
                num.mulAddSmall((u32)10, (u32)0);
            den.setU32((u32)1);
            }
        else
            {
            BigNat* p = BigNat.powerOfTen((u32)(0 - k));
            den.copyFrom(p);
            }

        // Align: value = (num/den) × 2^-e2, with bitLength(num) - bitLength(den)
        // brought to exactly 60.
        i32 diff = (i32)num.bitLength() - (i32)den.bitLength();
        i32 shift = (i32)60 - diff;
        i32 e2 = shift;
        if (shift > (i32)0)
            num.shiftLeftBits((u32)shift);
        else if (shift < (i32)0)
            den.shiftLeftBits((u32)(0 - shift));

        // d starts at den × 2^60 — the weight of the first quotient bit.
        BigNat* d = new BigNat();
        d.copyFrom(den);
        d.shiftLeftBits((u32)60);

        u32 bits[61];
        for (u32 b = (u32)0; b < (u32)61; b = b + (u32)1)
            {
            if (num.cmp(d) >= (i16)0)
                {
                num.sub(d);
                bits[b] = (u32)1;
                }
            else
                {
                bits[b] = (u32)0;
                }
            d.shiftRight1();
            }

        // The leading 1 is at index 0 or 1 — the quotient has 60 or 61 bits by
        // construction — so there are always 53 + 1 + 6 bits below it.
        u32 j = (u32)0;
        while (j < (u32)61 && bits[j] == (u32)0)
            j = j + (u32)1;
        // unreachable: num >= den
        if (j >= (u32)61)
            {
            _rZero = true;
            return;
            }

        u32 hi = (u32)0;
        u32 lo = (u32)0;
        for (u32 t = (u32)0; t < (u32)53; t = t + (u32)1)
            {
            hi = ((hi << (u32)1) | (lo >> (u32)31)) & (u32)$1FFFFF;
            lo = (lo << (u32)1) | bits[j + t];
            }
        u32 rbit = bits[j + (u32)53];
        bool sticky = !num.isZero();
        for (u32 t = j + (u32)54; t < (u32)61; t = t + (u32)1)
            if (bits[t] != (u32)0)
                sticky = true;

        // Nearest, ties to even.
        i32 exp = ((i32)60 - (i32)j) - e2; // weight of the significand's top bit
        if (rbit != (u32)0 && (sticky || (lo & (u32)1) != (u32)0))
            {
            lo = lo + (u32)1;
            if (lo == (u32)0)
                hi = hi + (u32)1;
            // carried out of 53 bits: 2^53
            if (hi > (u32)$1FFFFF)
                {
                hi = (u32)$100000;
                lo = (u32)0;
                exp = exp + (i32)1;
                }
            }
        _rHi = hi;
        _rLo = lo;
        _rExp = exp;
        }

    // The IEEE-754 bytes the AST dump compares, little-endian: 8 for a `d`
    // literal, 4 otherwise. The 4-byte form rounds the DOUBLE to a single,
    // which is what the original does with `(float)dVal` — the double rounding
    // is part of the contract, not an oversight.
    static Data* ieeeBytes(String* text, bool isDouble)
        {
        bool neg = FloatEncoding._parseInto(text); // fills _rHi/_rLo/_rExp
        Data* out = Data.withLength(isDouble ? (u32)8 : (u32)4);

        u32 sign = neg ? (u32)1 : (u32)0;
        if (isDouble)
            {
            u32 biased = (u32)0;
            u32 hi = _rHi;
            u32 lo = _rLo;
            if (_rInf)
                {
                biased = (u32)2047;
                hi = (u32)0;
                lo = (u32)0;
                }
            else if (_rZero)
                {
                hi = (u32)0;
                lo = (u32)0;
                }
            else
                {
                i32 b = _rExp + (i32)1023;
                if (b >= (i32)2047)
                    {
                    biased = (u32)2047;
                    hi = (u32)0;
                    lo = (u32)0;
                    }
                else if (b <= (i32)0)
                    {
                    biased = (u32)0;
                    hi = (u32)0;
                    lo = (u32)0;
                    }
                else
                    {
                    biased = (u32)b;
                    }
                }
            u32 frac = hi & (u32)$FFFFF; // 20 bits: significand 51..32
            out.setByteAt((u32)0, (u8)(lo & (u32)$FF));
            out.setByteAt((u32)1, (u8)((lo >> (u32)8) & (u32)$FF));
            out.setByteAt((u32)2, (u8)((lo >> (u32)16) & (u32)$FF));
            out.setByteAt((u32)3, (u8)((lo >> (u32)24) & (u32)$FF));
            out.setByteAt((u32)4, (u8)(frac & (u32)$FF));
            out.setByteAt((u32)5, (u8)((frac >> (u32)8) & (u32)$FF));
            out.setByteAt((u32)6, (u8)(((frac >> (u32)16) & (u32)$0F) | ((biased & (u32)$0F) << (u32)4)));
            out.setByteAt((u32)7, (u8)(((biased >> (u32)4) & (u32)$7F) | (sign << (u32)7)));
            return out;
            }

        // Single: take the 53-bit significand down to 24, nearest-even.
        u32 word = (u32)0;
        if (_rInf)
            {
            word = (sign << (u32)31) | ((u32)255 << (u32)23);
            }
        else if (_rZero)
            {
            word = sign << (u32)31;
            }
        else
            {
            u32 keep = ((_rHi << (u32)3) | (_rLo >> (u32)29)) & (u32)$FFFFFF; // 24 bits
            u32 rbit = (_rLo >> (u32)28) & (u32)1;
            bool sticky = (_rLo & (u32)$0FFFFFFF) != (u32)0;
            i32 exp = _rExp;
            if (rbit != (u32)0 && (sticky || (keep & (u32)1) != (u32)0))
                {
                keep = keep + (u32)1;
                if (keep > (u32)$FFFFFF)
                    {
                    keep = (u32)$800000;
                    exp = exp + (i32)1;
                    }
                }
            i32 b = exp + (i32)127;
            if (b >= (i32)255)
                word = (sign << (u32)31) | ((u32)255 << (u32)23);
            else if (b <= (i32)0)
                word = sign << (u32)31;
            else
                word = (sign << (u32)31) | ((u32)b << (u32)23) | (keep & (u32)$7FFFFF);
            }
        out.setByteAt((u32)0, (u8)(word & (u32)$FF));
        out.setByteAt((u32)1, (u8)((word >> (u32)8) & (u32)$FF));
        out.setByteAt((u32)2, (u8)((word >> (u32)16) & (u32)$FF));
        out.setByteAt((u32)3, (u8)((word >> (u32)24) & (u32)$FF));
        return out;
        }

    // The dump prints the bytes as uppercase hex, which is what the oracle
    // does with its NSData.
    static String* hexOf(Data* d)
        {
        String* out = String.withCString("");
        for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
            {
            u8 v = d.byteAt(i);
            out.appendByte(FloatEncoding._hexDigit(v >> (u8)4));
            out.appendByte(FloatEncoding._hexDigit(v & (u8)$0F));
            }
        return out;
        }

    static u8 _hexDigit(u8 nibble)
        {
        if (nibble < (u8)10)
            return (u8)((u8)'0' + nibble);
        return (u8)((u8)'A' + (nibble - (u8)10));
        }

    // Text → the IEEE hex the AST dump prints. `isDouble` follows the `d`
    // suffix the lexer already stripped.
    static String* hexForLiteral(String* text, bool isDouble)
        {
        return FloatEncoding.hexOf(FloatEncoding.ieeeBytes(text, isDouble));
        }
    }
