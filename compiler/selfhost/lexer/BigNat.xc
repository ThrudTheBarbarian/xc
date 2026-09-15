// BigNat.xc — a fixed-size natural number, big enough to convert a decimal
// literal to a double EXACTLY.
// =================================================================
//
// self-hosting M4/M5. Exists for one reason: `1.60590438368216145993923771701549E-10`
// has to become the same 64 bits the C library's strtod produces, and no amount
// of care with double arithmetic gets there. Decimal→binary is only correctly
// rounded if the decision is made on the exact value, and the exact value of a
// 30-digit literal times a power of ten does not fit in a double — it fits here.
//
// Representation: base 2^16 limbs, least significant first, so a limb product
// stays inside u32 (xtc has no 64-bit integer). LIMBS is sized for the widest
// thing the conversion builds: 10^350 is ~1163 bits, and the division shifts a
// numerator up by another ~60, so 96 limbs (1536 bits) leaves real headroom.
// Nothing here allocates: a BigNat is one object with an inline array, and the
// conversion uses four of them.
//
// Only what the conversion needs is implemented — no general-purpose division,
// no signs, no printing. `divBits` IS the division, and it is the restoring
// binary kind: 60 rounds of compare / subtract / halve, which is fast enough at
// a few hundred float literals per compile and short enough to read.

#import "Foundation.xc"

class BigNat
    {
    u32 _l[96]; // base-2^16 limbs, little end first
    u32 _n;     // limbs in use; 0 means the value is zero

    void init(void)
        {
        _n = (u32)0;
        }

    static BigNat* withU32(u32 v)
        {
        BigNat* b = new BigNat();
        b.setU32(v);
        return b;
        }

    void setU32(u32 v)
        {
        _n = (u32)0;
        if (v != (u32)0)
            {
            _l[0] = v & (u32)$FFFF;
            _n = (u32)1;
            u32 hi = (v >> (u32)16) & (u32)$FFFF;
            if (hi != (u32)0)
                {
                _l[1] = hi;
                _n = (u32)2;
                }
            }
        }

    void copyFrom(BigNat* o)
        {
        _n = o.limbCount();
        for (u32 i = (u32)0; i < _n; i = i + (u32)1)
            _l[i] = o.limbAt(i);
        }

    u32 limbCount(void)
        {
        return _n;
        }
    u32 limbAt(u32 i)
        {
        return _l[i];
        }
    bool isZero(void)
        {
        return _n == (u32)0;
        }

    // value = value * m + a, with m and a below 2^16. The two are fused because
    // that is exactly what reading a decimal digit does.
    void mulAddSmall(u32 m, u32 a)
        {
        u32 carry = a;
        for (u32 i = (u32)0; i < _n; i = i + (u32)1)
            {
            u32 t = _l[i] * m + carry;
            _l[i] = t & (u32)$FFFF;
            carry = (t >> (u32)16) & (u32)$FFFF;
            }
        while (carry != (u32)0 && _n < (u32)96)
            {
            _l[_n] = carry & (u32)$FFFF;
            carry = (carry >> (u32)16) & (u32)$FFFF;
            _n = _n + (u32)1;
            }
        }

    // Number of significant bits — 0 for zero. The conversion aligns the
    // numerator and denominator by this, so it must be exact, not approximate.
    u32 bitLength(void)
        {
        if (_n == (u32)0)
            return (u32)0;
        u32 top = _l[_n - (u32)1];
        u32 bits = (_n - (u32)1) * (u32)16;
        while (top != (u32)0)
            {
            bits = bits + (u32)1;
            top = top >> (u32)1;
            }
        return bits;
        }

    void shiftLeftBits(u32 bits)
        {
        if (_n == (u32)0 || bits == (u32)0)
            return;
        u32 limbs = bits / (u32)16;
        u32 rem = bits - limbs * (u32)16;
        if (rem != (u32)0)
            {
            u32 carry = (u32)0;
            for (u32 i = (u32)0; i < _n; i = i + (u32)1)
                {
                u32 t = (_l[i] << rem) | carry;
                _l[i] = t & (u32)$FFFF;
                carry = (t >> (u32)16) & (u32)$FFFF;
                }
            if (carry != (u32)0 && _n < (u32)96)
                {
                _l[_n] = carry;
                _n = _n + (u32)1;
                }
            }
        if (limbs != (u32)0)
            {
            u32 i = _n;
            while (i > (u32)0)
                {
                i = i - (u32)1;
                if (i + limbs < (u32)96)
                    _l[i + limbs] = _l[i];
                }
            for (u32 j = (u32)0; j < limbs; j = j + (u32)1)
                _l[j] = (u32)0;
            _n = _n + limbs;
            if (_n > (u32)96)
                _n = (u32)96;
            }
        }

    void shiftRight1(void)
        {
        if (_n == (u32)0)
            return;
        u32 carry = (u32)0;
        u32 i = _n;
        while (i > (u32)0)
            {
            i = i - (u32)1;
            u32 cur = _l[i] | (carry << (u32)16);
            _l[i] = (cur >> (u32)1) & (u32)$FFFF;
            carry = cur & (u32)1;
            }
        while (_n > (u32)0 && _l[_n - (u32)1] == (u32)0)
            _n = _n - (u32)1;
        }

    // -1 / 0 / +1, self against o.
    i16 cmp(BigNat* o)
        {
        u32 on = o.limbCount();
        if (_n != on)
            return (_n < on) ? (i16)-1 : (i16)1;
        u32 i = _n;
        while (i > (u32)0)
            {
            i = i - (u32)1;
            u32 a = _l[i];
            u32 b = o.limbAt(i);
            if (a != b)
                return (a < b) ? (i16)-1 : (i16)1;
            }
        return (i16)0;
        }

    // self -= o. The caller has already established self >= o.
    void sub(BigNat* o)
        {
        u32 borrow = (u32)0;
        u32 on = o.limbCount();
        for (u32 i = (u32)0; i < _n; i = i + (u32)1)
            {
            u32 b = (i < on) ? o.limbAt(i) : (u32)0;
            u32 cur = _l[i];
            u32 rhs = b + borrow;
            if (cur >= rhs)
                {
                _l[i] = cur - rhs;
                borrow = (u32)0;
                }
            else
                {
                _l[i] = ((u32)$10000 + cur) - rhs;
                borrow = (u32)1;
                }
            }
        while (_n > (u32)0 && _l[_n - (u32)1] == (u32)0)
            _n = _n - (u32)1;
        }

    // self = 10^p. Built by repeated multiply — p is at most a few hundred, and
    // a table of powers would be more code than the loop it saves.
    static BigNat* powerOfTen(u32 p)
        {
        BigNat* b = BigNat.withU32((u32)1);
        for (u32 i = (u32)0; i < p; i = i + (u32)1)
            b.mulAddSmall((u32)10, (u32)0);
        return b;
        }
    }
