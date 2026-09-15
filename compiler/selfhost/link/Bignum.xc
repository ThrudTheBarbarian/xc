// Bignum.xc — big unsigned integers, for RSA signing AND key generation.
// =================================================================
//
// Fixed-size limb arrays, not Array<Number>. The first cut used boxed numbers
// and a signature took THIRTY SECONDS; key generation needs hundreds of modular
// exponentiations for the primality tests, which at that speed is an hour. The
// arithmetic is identical — the representation is the whole difference.
//
// 160 limbs of 32 bits. A 2048-bit modulus is 64 limbs, so a product is 128 —
// and Montgomery reduction adds m*n on top of that, whose carry lands in limb
// 2k+1. At exactly 128 that carry fell off the end and the reduction was
// silently wrong for a full-size key while every small modulus still passed.
// The headroom is the fix; the bound is checked everywhere it is indexed.

#import "Foundation.xc"

class Bignum
    {
    u32 _l[160];
    u32 _n; // limbs in use

    void init(void)
        {
        setZero();
        }

    void setZero(void)
        {
        for (u32 i = (u32)0; i < (u32)160; i = i + (u32)1)
            _l[i] = (u32)0;
        _n = (u32)0;
        }
    u32 count(void)
        {
        return _n;
        }
    u32 limb(u32 i)
        {
        return i < _n ? _l[i] : (u32)0;
        }
    void setLimb(u32 i, u32 v)
        {
        if (i >= (u32)160)
            return;
        _l[i] = v;
        if (v != (u32)0 && i + (u32)1 > _n)
            _n = i + (u32)1;
        }
    void trim(void)
        {
        while (_n > (u32)0 && _l[_n - (u32)1] == (u32)0)
            _n = _n - (u32)1;
        }
    bool isZero(void)
        {
        return _n == (u32)0;
        }
    bool isOdd(void)
        {
        return _n > (u32)0 && (_l[0] & (u32)1) != (u32)0;
        }

    static Bignum* fromU32(u32 v)
        {
        Bignum* r = new Bignum();
        if (v != (u32)0)
            {
            r._l[0] = v;
            r._n = (u32)1;
            }
        return r;
        }
    static Bignum* copyOf(Bignum* a)
        {
        Bignum* r = new Bignum();
        for (u32 i = (u32)0; i < a._n; i = i + (u32)1)
            r._l[i] = a._l[i];
        r._n = a._n;
        return r;
        }
    void assign(Bignum* a)
        {
        for (u32 i = (u32)0; i < (u32)160; i = i + (u32)1)
            _l[i] = i < a._n ? a._l[i] : (u32)0;
        _n = a._n;
        }

    // Big-endian bytes, as every crypto value is written.
    static Bignum* fromBytes(Array* bytes)
        {
        Bignum* r = new Bignum();
        u32 n = bytes.count();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u32 b = ((Number*)bytes.get(n - (u32)1 - i)).asU32() & (u32)$FF;
            u32 li = i >> (u32)2;
            if (li >= (u32)160)
                break;
            r._l[li] = r._l[li] | (b << ((i & (u32)3) << (u32)3));
            if (li + (u32)1 > r._n)
                r._n = li + (u32)1;
            }
        r.trim();
        return r;
        }
    Array* toBytes(u32 width)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < width; i = i + (u32)1)
            {
            u32 idx = width - (u32)1 - i;
            out.add((Object*)Number.withU32((limb(idx >> (u32)2) >> ((idx & (u32)3) << (u32)3)) & (u32)$FF));
            }
        return out;
        }

    static i32 cmp(Bignum* a, Bignum* b)
        {
        u32 n = a._n > b._n ? a._n : b._n;
        u32 i = n;
        while (i > (u32)0)
            {
            i = i - (u32)1;
            u32 x = a.limb(i);
            u32 y = b.limb(i);
            if (x != y)
                return x > y ? (i32)1 : (i32)-1;
            }
        return (i32)0;
        }

    static void addInto(Bignum* a, Bignum* b)
        {
        u64 carry = (u64)0;
        u32 n = a._n > b._n ? a._n : b._n;
        for (u32 i = (u32)0; i < n || carry != (u64)0; i = i + (u32)1)
            {
            if (i >= (u32)160)
                break;
            u64 s = (u64)a.limb(i) + (u64)b.limb(i) + carry;
            a._l[i] = (u32)(s & (u64)$FFFFFFFF);
            if (i + (u32)1 > a._n)
                a._n = i + (u32)1;
            carry = s >> (u64)32;
            }
        a.trim();
        }
    // a -= b, requiring a >= b
    static void subInto(Bignum* a, Bignum* b)
        {
        u64 borrow = (u64)0;
        for (u32 i = (u32)0; i < a._n; i = i + (u32)1)
            {
            u64 x = (u64)a._l[i];
            u64 y = (u64)b.limb(i) + borrow;
            if (x >= y)
                {
                a._l[i] = (u32)(x - y);
                borrow = (u64)0;
                }
            else
                {
                a._l[i] = (u32)(x + (u64)$100000000 - y);
                borrow = (u64)1;
                }
            }
        a.trim();
        }
    static void dbl(Bignum* a)
        {
        u32 carry = (u32)0;
        for (u32 i = (u32)0; i < a._n; i = i + (u32)1)
            {
            u32 v = a._l[i];
            a._l[i] = (v << (u32)1) | carry;
            carry = v >> (u32)31;
            }
        if (carry != (u32)0 && a._n < (u32)160)
            {
            a._l[a._n] = carry;
            a._n = a._n + (u32)1;
            }
        }
    void shrOne(void)
        {
        u32 i = _n;
        u32 carry = (u32)0;
        while (i > (u32)0)
            {
            i = i - (u32)1;
            u32 v = _l[i];
            _l[i] = (v >> (u32)1) | (carry << (u32)31);
            carry = v & (u32)1;
            }
        trim();
        }

    bool bitAt(u32 i)
        {
        return ((limb(i >> (u32)5) >> (i & (u32)31)) & (u32)1) != (u32)0;
        }
    u32 bitLength(void)
        {
        if (_n == (u32)0)
            return (u32)0;
        u32 v = _l[_n - (u32)1];
        u32 k = (u32)0;
        while (v != (u32)0)
            {
            k = k + (u32)1;
            v = v >> (u32)1;
            }
        return (_n - (u32)1) * (u32)32 + k;
        }

    // Full product. `r` must not alias a or b.
    static Bignum* mul(Bignum* a, Bignum* b)
        {
        Bignum* r = new Bignum();
        for (u32 i = (u32)0; i < a._n; i = i + (u32)1)
            {
            u64 carry = (u64)0;
            u32 ai = a._l[i];
            if (ai == (u32)0)
                continue;
            for (u32 j = (u32)0; j < b._n || carry != (u64)0; j = j + (u32)1)
                {
                u32 at = i + j;
                if (at >= (u32)160)
                    break;
                u64 cur = (u64)r._l[at] + (u64)ai * (u64)b.limb(j) + carry;
                r._l[at] = (u32)(cur & (u64)$FFFFFFFF);
                if (at + (u32)1 > r._n)
                    r._n = at + (u32)1;
                carry = cur >> (u64)32;
                }
            }
        r.trim();
        return r;
        }

    static Bignum* mulSmall(Bignum* a, u32 w)
        {
        Bignum* r = new Bignum();
        u64 carry = (u64)0;
        for (u32 i = (u32)0; i < a._n || carry != (u64)0; i = i + (u32)1)
            {
            if (i >= (u32)160)
                break;
            u64 cur = (u64)a.limb(i) * (u64)w + carry;
            r._l[i] = (u32)(cur & (u64)$FFFFFFFF);
            if (i + (u32)1 > r._n)
                r._n = i + (u32)1;
            carry = cur >> (u64)32;
            }
        r.trim();
        return r;
        }
    static u32 modSmall(Bignum* a, u32 w)
        {
        u64 rem = (u64)0;
        u32 i = a._n;
        while (i > (u32)0)
            {
            i = i - (u32)1;
            rem = ((rem << (u64)32) | (u64)a._l[i]) % (u64)w;
            }
        return (u32)rem;
        }
    static Bignum* divSmall(Bignum* a, u32 w)
        {
        Bignum* r = new Bignum();
        u64 rem = (u64)0;
        u32 i = a._n;
        r._n = a._n;
        while (i > (u32)0)
            {
            i = i - (u32)1;
            u64 cur = (rem << (u64)32) | (u64)a._l[i];
            r._l[i] = (u32)(cur / (u64)w);
            rem = cur % (u64)w;
            }
        r.trim();
        return r;
        }

    // a mod m, by shift-and-subtract.
    static Bignum* mod(Bignum* a, Bignum* m)
        {
        Bignum* r = new Bignum();
        u32 i = a.bitLength();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            Bignum.dbl(r);
            if (a.bitAt(i))
                {
                if (r._n == (u32)0)
                    {
                    r._l[0] = (u32)1;
                    r._n = (u32)1;
                    }
                else
                    r._l[0] = r._l[0] | (u32)1;
                }
            if (Bignum.cmp(r, m) >= (i32)0)
                Bignum.subInto(r, m);
            }
        return r;
        }
    // (a*b) mod m, the general form: full multiply then binary reduce. Kept for
    // the few places that reduce ONCE — the exponentiation below does not use
    // it, because `mod` is the expensive half.
    static Bignum* modmul(Bignum* a, Bignum* b, Bignum* m)
        {
        return Bignum.mod(Bignum.mul(a, b), m);
        }

    // ── Montgomery ───────────────────────────────────────────────────────
    //
    // `mod` is binary long division: one iteration per BIT of the dividend,
    // each a shift, compare and conditional subtract across every limb — so
    // O(bits x limbs) against the multiply's O(limbs^2). Measured on this
    // machine: a 1024-bit multiply is 5us and the reduction after it is 85us,
    // so seventeen parts in eighteen of a modexp were the REDUCTION. Key
    // generation is ~240 modexps and took 31 seconds.
    //
    // Montgomery reduction replaces the division with a multiply and a shift,
    // making the reduction the same order as the multiply. It works only for an
    // ODD modulus, which every RSA modulus and prime is.

    // -n^-1 mod 2^32, by Newton iteration: each step doubles the correct bits,
    // so five steps cover 32.
    static u32 montInv(u32 n0)
        {
        u32 x = n0; // correct to 3 bits for odd n0
        x = x * ((u32)2 - n0 * x);
        x = x * ((u32)2 - n0 * x);
        x = x * ((u32)2 - n0 * x);
        x = x * ((u32)2 - n0 * x);
        x = x * ((u32)2 - n0 * x);
        return (u32)0 - x; // negate: we want -n^-1
        }

    // REDC: (T + m*n) / R, where m = (T mod R) * n' mod R and R = 2^(32*k).
    // Interleaved per limb, so no value wider than the product is ever formed.
    static Bignum* montReduce(Bignum* t, Bignum* n, u32 nprime)
        {
        u32 k = n.count();
        Bignum* a = Bignum.copyOf(t);
        for (u32 i = (u32)0; i < k; i = i + (u32)1)
            {
            u32 m = (u32)(((u64)a.limb(i) * (u64)nprime) & (u64)$FFFFFFFF);
            u64 carry = (u64)0;
            for (u32 j = (u32)0; j < k; j = j + (u32)1)
                {
                u32 at = i + j;
                if (at >= (u32)160)
                    break;
                u64 cur = (u64)a.limb(at) + (u64)m * (u64)n.limb(j) + carry;
                a.setLimb(at, (u32)(cur & (u64)$FFFFFFFF));
                carry = cur >> (u64)32;
                }
            // Propagate the carry past the window.
            u32 at = i + k;
            while (carry != (u64)0 && at < (u32)160)
                {
                u64 cur = (u64)a.limb(at) + carry;
                a.setLimb(at, (u32)(cur & (u64)$FFFFFFFF));
                carry = cur >> (u64)32;
                at = at + (u32)1;
                }
            }
        // Divide by R: drop the low k limbs.
        Bignum* r = new Bignum();
        for (u32 i = (u32)0; i + k < (u32)160; i = i + (u32)1)
            r.setLimb(i, a.limb(i + k));
        r.trim();
        if (Bignum.cmp(r, n) >= (i32)0)
            Bignum.subInto(r, n);
        return r;
        }

    static Bignum* montMul(Bignum* a, Bignum* b, Bignum* n, u32 nprime)
        {
        return Bignum.montReduce(Bignum.mul(a, b), n, nprime);
        }

    // base^exp mod m. Montgomery when m is odd — which is every case this
    // compiler signs with — and the plain binary form otherwise, so the
    // function is correct for any modulus and merely slower for an even one.
    static Bignum* modexp(Bignum* base, Bignum* exp, Bignum* m)
        {
        if (!m.isOdd())
            {
            Bignum* r = Bignum.fromU32((u32)1);
            Bignum* b = Bignum.mod(base, m);
            u32 i = exp.bitLength();
            while (i > (u32)0)
                {
                i = i - (u32)1;
                r = Bignum.modmul(r, r, m);
                if (exp.bitAt(i))
                    r = Bignum.modmul(r, b, m);
                }
            return r;
            }

        u32 k = m.count();
        u32 nprime = Bignum.montInv(m.limb((u32)0));

        // R mod m and R^2 mod m, computed once with the slow reduction — the
        // only two divisions in the whole exponentiation.
        Bignum* rr = new Bignum();
        rr.setLimb(k, (u32)1); // R = 2^(32k)
        Bignum* rmod = Bignum.mod(rr, m);
        Bignum* r2 = Bignum.mod(Bignum.mul(rmod, rmod), m);

        Bignum* x = Bignum.montMul(Bignum.mod(base, m), r2, m, nprime); // to Montgomery form
        Bignum* acc = Bignum.copyOf(rmod);                              // 1, in that form
        u32 i = exp.bitLength();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            acc = Bignum.montMul(acc, acc, m, nprime);
            if (exp.bitAt(i))
                acc = Bignum.montMul(acc, x, m, nprime);
            }
        Bignum* one = Bignum.fromU32((u32)1);
        return Bignum.montMul(acc, one, m, nprime); // back out
        }
    }
