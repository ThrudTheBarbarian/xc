// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// JSON.xc — JSON text to Foundation objects and back (NSJSONSerialization in
// shape).
// ===========================================================================
//
//     Object* v = JSON.parse(String.withCString("{\"name\":\"xc\",\"tags\":[1,2.5,true,null]}"));
//     Map* m = (Map*)v;
//     String* name = (String*)m.get(String.withCString("name"));
//     String* back = JSON.stringify(v);        // {"name":"xc","tags":[1,2.5,true,null]}
//
// ── The mapping ─────────────────────────────────────────────────────────────
//
//     JSON            Foundation
//     object          Map, String keys in the order the text has them
//     array           Array
//     string          String (UTF-8; \u escapes and surrogate pairs decoded)
//     number          Number: an Int when written without '.' or an exponent
//                     and it fits 64 bits, otherwise a double
//     true / false    Number.withBool(…)
//     null            Null.null()
//
// Numbers are exact both ways: an integer keeps all 64 bits, a double is read
// correctly rounded and written in the shortest form that reads back as the
// same bits, always with a '.' or an exponent (3.0, 1.0e+300) so it reads
// back as a double. A key that appears twice in one object keeps its last value.
// Nesting deeper than 256 is refused.
//
// Writing accepts the same classes (a null reference is written as null) and
// throws a JSONError for anything else: another class, a Map key that is not
// a String, a NaN or infinite double, or a String that is not valid UTF-8.
//
// ── Errors ──────────────────────────────────────────────────────────────────
//
// `parse`, `parseData`, `stringify` and `stringifyPretty` throw a JSONError
// (see Error.xc) whose message gives the byte offset of bad input:
//
//     try   { Object* v = JSON.parse(text); … }
//     catch (JSONError e) { Stdio.printf("%s\n", e.message().cString()); }
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every target except xt6502. Coder's archives are read with the same parser.

#if ARCH_6502
#error "JSON: not available on xt6502"
#endif

#import "Foundation.xc"
#import "Error.xc"
#import "Null.xc"

void _json_free(pointer p)
    {
    __arc_release(p);
    }

// A double's bits, and back. The language has no bit cast, so go through
// memory; `double` is IEEE binary64 on every target this file builds for.
u64 _json_dbits(double d)
    {
    double v = d;
    u64* p = (u64*)&v;
    return *p;
    }

double _json_dfrom(u64 bits)
    {
    double v = 0.0d;
    u64* p = (u64*)&v;
    *p = bits;
    return v;
    }

// ═════════════════════════════════════════════════════════════════════════════
// _JSONBig — just enough unsigned bignum for exact decimal <-> double.
// ═════════════════════════════════════════════════════════════════════════════
//
// Little-endian 32-bit limbs, always normalised (no zero limb on top), so a
// zero value has no limbs at all.

class _JSONBig
    {
    u32* _w;
    u32 _n;
    u32 _cap;

    void init(void)
        {
        _w = (u32*)0;
        _n = (u32)0;
        _cap = (u32)0;
        }

    void dealloc(void)
        {
        _json_free((pointer)_w);
        }

    static _JSONBig* withU64(u64 v)
        {
        _JSONBig* b = new _JSONBig();
        b._ensure((u32)2);
        u32* w = b._w;
        w[0] = (u32)v;
        w[1] = (u32)(v >> (u64)32);
        b._n = (u32)2;
        b._trim();
        return b;
        }

    _JSONBig* dup(void)
        {
        _JSONBig* b = new _JSONBig();
        b._ensure(_n + (u32)1);
        u32* s = _w;
        u32* d = b._w;
        for (u32 i = (u32)0; i < _n; i++)
            d[i] = s[i];
        b._n = _n;
        return b;
        }

    void _ensure(u32 need)
        {
        if (need <= _cap)
            return;
        u32 cap = _cap * (u32)2;
        if (cap < need)
            cap = need + (u32)4;
        u32* fresh = new u32[cap];
        u32* old = _w;
        for (u32 i = (u32)0; i < _n; i++)
            fresh[i] = old[i];
        _w = fresh;
        _cap = cap;
        _json_free((pointer)old);
        }

    void _trim(void)
        {
        u32* w = _w;
        while (_n > (u32)0 && w[_n - (u32)1] == (u32)0)
            _n = _n - (u32)1;
        }

    bool isZero(void)
        {
        return _n == (u32)0;
        }

    // self = self * m + a
    void mulAdd(u32 m, u32 a)
        {
        u64 carry = (u64)a;
        u32* w = _w;
        for (u32 i = (u32)0; i < _n; i++)
            {
            u64 t = (u64)w[i] * (u64)m + carry;
            w[i] = (u32)t;
            carry = t >> (u64)32;
            }
        if (carry != (u64)0)
            {
            _ensure(_n + (u32)1);
            w = _w;
            w[_n] = (u32)carry;
            _n = _n + (u32)1;
            }
        }

    // self = self * 5^e
    void mulPow5(u32 e)
        {
        while (e >= (u32)13)
            {
            mulAdd((u32)1220703125, (u32)0);
            e = e - (u32)13;
            }
        u32 m = (u32)1;
        while (e > (u32)0)
            {
            m = m * (u32)5;
            e = e - (u32)1;
            }
        if (m != (u32)1)
            mulAdd(m, (u32)0);
        }

    void shl(u32 bits)
        {
        if (_n == (u32)0 || bits == (u32)0)
            return;
        u32 words = bits >> (u32)5;
        u32 r = bits & (u32)31;
        _ensure(_n + words + (u32)1);
        u32* w = _w;
        if (r == (u32)0)
            {
            for (u32 i = _n; i > (u32)0; i--)
                w[i - (u32)1 + words] = w[i - (u32)1];
            }
        else
            {
            u32 top = w[_n - (u32)1] >> ((u32)32 - r);
            for (u32 i = _n - (u32)1; i > (u32)0; i--)
                w[i + words] = (w[i] << r) | (w[i - (u32)1] >> ((u32)32 - r));
            w[words] = w[0] << r;
            w[_n + words] = top;
            }
        for (u32 i = (u32)0; i < words; i++)
            w[i] = (u32)0;
        _n = _n + words + (u32)1;
        _trim();
        }

    void shr1(void)
        {
        u32* w = _w;
        for (u32 i = (u32)0; i < _n; i++)
            {
            u32 hi = (i + (u32)1 < _n) ? w[i + (u32)1] : (u32)0;
            w[i] = (w[i] >> (u32)1) | (hi << (u32)31);
            }
        _trim();
        }

    u32 bitLength(void)
        {
        if (_n == (u32)0)
            return (u32)0;
        u32* w = _w;
        u32 top = w[_n - (u32)1];
        u32 bits = (u32)0;
        while (top != (u32)0)
            {
            bits = bits + (u32)1;
            top = top >> (u32)1;
            }
        return (_n - (u32)1) * (u32)32 + bits;
        }

    i32 cmp(_JSONBig* o)
        {
        if (_n != o._n)
            return (_n > o._n) ? (i32)1 : (i32)-1;
        u32* a = _w;
        u32* b = o._w;
        for (u32 i = _n; i > (u32)0; i--)
            {
            u32 x = a[i - (u32)1];
            u32 y = b[i - (u32)1];
            if (x != y)
                return (x > y) ? (i32)1 : (i32)-1;
            }
        return (i32)0;
        }

    // self = self - o, where self >= o.
    void sub(_JSONBig* o)
        {
        u32* a = _w;
        u32* b = o._w;
        u64 borrow = (u64)0;
        for (u32 i = (u32)0; i < _n; i++)
            {
            u64 y = (i < o._n) ? (u64)b[i] : (u64)0;
            u64 t = (u64)a[i] - y - borrow;
            a[i] = (u32)t;
            borrow = t >> (u64)63;
            }
        _trim();
        }

    // self = self / d; returns the remainder.
    u32 divSmall(u32 d)
        {
        u64 rem = (u64)0;
        u32* w = _w;
        for (u32 i = _n; i > (u32)0; i--)
            {
            u64 cur = (rem << (u64)32) | (u64)w[i - (u32)1];
            w[i - (u32)1] = (u32)(cur / (u64)d);
            rem = cur % (u64)d;
            }
        _trim();
        return (u32)rem;
        }

    u32 _limb(u32 i)
        {
        if (i >= _n)
            return (u32)0;
        u32* w = _w;
        return w[i];
        }

    // The 64 bits starting at bit `s`.
    u64 bitsFrom(u32 s)
        {
        u32 q = s >> (u32)5;
        u32 off = s & (u32)31;
        u64 lo = ((u64)_limb(q + (u32)1) << (u64)32) | (u64)_limb(q);
        if (off == (u32)0)
            return lo;
        u64 hi = (u64)_limb(q + (u32)2);
        return (lo >> (u64)off) | (hi << (u64)((u32)64 - off));
        }

    // Is any bit below bit `s` set?
    bool anyBelow(u32 s)
        {
        u32 q = s >> (u32)5;
        u32* w = _w;
        for (u32 i = (u32)0; i < q && i < _n; i++)
            {
            if (w[i] != (u32)0)
                return true;
            }
        u32 off = s & (u32)31;
        if (off != (u32)0 && q < _n)
            {
            if ((w[q] & (((u32)1 << off) - (u32)1)) != (u32)0)
                return true;
            }
        return false;
        }

    // Decimal digits, most significant first. Destroys the value.
    String* toDecimal(void)
        {
        String* out = String.withCString("");
        if (_n == (u32)0)
            {
            out.appendByte((u8)'0');
            return out;
            }
        u32 chunks = (u32)0;
        u32* parts = new u32[_n * (u32)2 + (u32)2];
        while (_n != (u32)0)
            {
            parts[chunks] = divSmall((u32)1000000000);
            chunks = chunks + (u32)1;
            }
        u8 buf[10];
        for (u32 c = chunks; c > (u32)0; c--)
            {
            u32 v = parts[c - (u32)1];
            for (u32 k = (u32)0; k < (u32)9; k++)
                {
                buf[(u32)8 - k] = (u8)((u8)'0' + (u8)(v % (u32)10));
                v = v / (u32)10;
                }
            u32 from = (u32)0;
            if (c == chunks)
                {
                while (from < (u32)8 && buf[from] == (u8)'0')
                    from = from + (u32)1;
                }
            for (u32 k = from; k < (u32)9; k++)
                out.appendByte(buf[k]);
            }
        _json_free((pointer)parts);
        return out;
        }
    }

// ── Correctly rounded conversion to double ──────────────────────────────────

u32 _json_bitlen64(u64 v)
    {
    u32 n = (u32)0;
    while (v != (u64)0)
        {
        n = n + (u32)1;
        v = v >> (u64)1;
        }
    return n;
    }

// q * 2^e2, plus a nonzero amount smaller than 2^e2 when `sticky`, rounded to
// the nearest double, ties to even. Handles subnormals, overflow to infinity
// and underflow to zero.
double _json_round(u64 q, i32 e2, bool sticky)
    {
    if (q == (u64)0)
        return 0.0d;
    i32 len = (i32)_json_bitlen64(q);
    i32 top = len - (i32)1 + e2;
    if (top > (i32)1023)
        return _json_dfrom((u64)0x7FF0000000000000);
    i32 shift = len - (i32)53;
    if (top < (i32)-1022)
        shift = (i32)-1074 - e2;
    u64 mant = q;
    i32 e = e2;
    if (shift > (i32)0)
        {
        if (shift > (i32)64)
            return 0.0d;
        u64 half = (u64)1 << (u64)(shift - (i32)1);
        u64 rest = (shift == (i32)64) ? q : (q & (((u64)1 << (u64)shift) - (u64)1));
        mant = (shift == (i32)64) ? (u64)0 : (q >> (u64)shift);
        e = e2 + shift;
        bool up = false;
        if (rest > half)
            up = true;
        else if (rest == half)
            up = sticky || ((mant & (u64)1) != (u64)0);
        else
            up = false;
        if (up)
            mant = mant + (u64)1;
        if (mant == ((u64)1 << (u64)53))
            {
            mant = mant >> (u64)1;
            e = e + (i32)1;
            }
        }
    else if (shift < (i32)0)
        {
        mant = q << (u64)(-shift);
        e = e2 + shift;
        }
    if (mant >= ((u64)1 << (u64)52))
        {
        i32 biased = e + (i32)1075;
        if (biased >= (i32)2047)
            return _json_dfrom((u64)0x7FF0000000000000);
        u64 bits = ((u64)biased << (u64)52) | (mant - ((u64)1 << (u64)52));
        return _json_dfrom(bits);
        }
    return _json_dfrom(mant);
    }

// n * 2^e2, rounded.
double _json_bigToDouble(_JSONBig* n, i32 e2)
    {
    u32 len = n.bitLength();
    if (len <= (u32)64)
        return _json_round(n.bitsFrom((u32)0), e2, false);
    u32 s = len - (u32)64;
    return _json_round(n.bitsFrom(s), e2 + (i32)s, n.anyBelow(s));
    }

// d * 10^e10, rounded; `ndig` is the digit count of d, for the range check.
// `d` is consumed.
double _json_toDouble(_JSONBig* d, i32 e10, u32 ndig)
    {
    if (d.isZero())
        return 0.0d;
    i32 mag = (i32)ndig + e10;
    if (mag > (i32)310)
        return _json_dfrom((u64)0x7FF0000000000000);
    if (mag < (i32)-330)
        return 0.0d;
    if (e10 >= (i32)0)
        {
        d.mulPow5((u32)e10);
        d.shl((u32)e10);
        return _json_bigToDouble(d, (i32)0);
        }
    // d / 10^-e10: scale so the quotient has 57 or 58 bits, divide, and let
    // the remainder decide the sticky bit.
    _JSONBig* m = _JSONBig.withU64((u64)1);
    m.mulPow5((u32)(-e10));
    m.shl((u32)(-e10));
    i32 k = (i32)57 + (i32)m.bitLength() - (i32)d.bitLength();
    if (k > (i32)0)
        d.shl((u32)k);
    else if (k < (i32)0)
        m.shl((u32)(-k));
    _JSONBig* t = m.dup();
    t.shl((u32)58);
    u64 q = (u64)0;
    for (i32 i = (i32)58; i >= (i32)0; i--)
        {
        if (d.cmp(t) >= (i32)0)
            {
            d.sub(t);
            q = q | ((u64)1 << (u64)i);
            }
        t.shr1();
        }
    return _json_round(q, -k, !d.isZero());
    }

// A JSON number's text as a double, correctly rounded. The syntax has already
// been checked by the parser.
double _json_parseDouble(u8* s, u32 n)
    {
    u32 i = (u32)0;
    bool neg = false;
    if (i < n && s[i] == (u8)'-')
        {
        neg = true;
        i = i + (u32)1;
        }
    _JSONBig* d = new _JSONBig();
    u32 ndig = (u32)0;
    i32 e10 = (i32)0;
    bool dropped = false;
    while (i < n && s[i] >= (u8)'0' && s[i] <= (u8)'9')
        {
        u32 v = (u32)(s[i] - (u8)'0');
        if (ndig == (u32)0 && v == (u32)0)
            {
            // a leading zero adds nothing
            }
        else if (ndig < (u32)800)
            {
            d.mulAdd((u32)10, v);
            ndig = ndig + (u32)1;
            }
        else
            {
            e10 = e10 + (i32)1;
            if (v != (u32)0)
                dropped = true;
            }
        i = i + (u32)1;
        }
    if (i < n && s[i] == (u8)'.')
        {
        i = i + (u32)1;
        while (i < n && s[i] >= (u8)'0' && s[i] <= (u8)'9')
            {
            u32 v = (u32)(s[i] - (u8)'0');
            if (ndig == (u32)0 && v == (u32)0)
                {
                e10 = e10 - (i32)1;
                }
            else if (ndig < (u32)800)
                {
                d.mulAdd((u32)10, v);
                ndig = ndig + (u32)1;
                e10 = e10 - (i32)1;
                }
            else if (v != (u32)0)
                {
                dropped = true;
                }
            i = i + (u32)1;
            }
        }
    if (i < n && (s[i] == (u8)'e' || s[i] == (u8)'E'))
        {
        i = i + (u32)1;
        bool eneg = false;
        if (i < n && (s[i] == (u8)'+' || s[i] == (u8)'-'))
            {
            eneg = s[i] == (u8)'-';
            i = i + (u32)1;
            }
        i32 ev = (i32)0;
        while (i < n && s[i] >= (u8)'0' && s[i] <= (u8)'9')
            {
            if (ev < (i32)100000)
                ev = ev * (i32)10 + (i32)(s[i] - (u8)'0');
            i = i + (u32)1;
            }
        e10 = eneg ? e10 - ev : e10 + ev;
        }
    // Digits past the 800th only matter as "a little more than this"; 800 is
    // more than the 767 a double can ever need to be decided.
    if (dropped)
        {
        d.mulAdd((u32)10, (u32)1);
        ndig = ndig + (u32)1;
        e10 = e10 - (i32)1;
        }
    double v = _json_toDouble(d, e10, ndig);
    // Negation flips the sign bit, so -0.0 comes back as itself.
    if (neg)
        return -v;
    return v;
    }

// ── Shortest round-trip formatting ──────────────────────────────────────────

// Round the decimal digit string `digits` (value 0.digits * 10^point) to at
// most `p` significant digits, ties to even, trailing zeros removed. Returns
// the digits; the new point comes back through `pointOut`.
String* _json_roundDigits(String* digits, u32 p, i32 point, i32* pointOut)
    {
    u32 len = digits.byteLength();
    u8* s = digits.cString();
    *pointOut = point;
    String* r = String.withCString("");
    if (len <= p)
        {
        r.appendBytes(s, len);
        }
    else
        {
        u8 next = s[p];
        bool rest = false;
        for (u32 i = p + (u32)1; i < len; i++)
            {
            if (s[i] != (u8)'0')
                {
                rest = true;
                break;
                }
            }
        bool up = next > (u8)'5' || (next == (u8)'5' && (rest || ((s[p - (u32)1] - (u8)'0') & (u8)1) != (u8)0));
        r.appendBytes(s, p);
        if (up)
            {
            u8* b = r.cString();
            u32 i = p;
            while (i > (u32)0)
                {
                i = i - (u32)1;
                if (b[i] == (u8)'9')
                    {
                    b[i] = (u8)'0';
                    if (i == (u32)0)
                        {
                        r.insertByte((u32)0, (u8)'1');
                        *pointOut = point + (i32)1;
                        }
                    }
                else
                    {
                    b[i] = b[i] + (u8)1;
                    break;
                    }
                }
            }
        }
    // trailing zeros
    u32 keep = r.byteLength();
    u8* b = r.cString();
    while (keep > (u32)1 && b[keep - (u32)1] == (u8)'0')
        keep = keep - (u32)1;
    if (keep < r.byteLength())
        r.deleteByteRange(keep, r.byteLength() - keep);
    return r;
    }

double _json_digitsToDouble(String* digits, i32 point)
    {
    _JSONBig* d = new _JSONBig();
    u8* s = digits.cString();
    u32 n = digits.byteLength();
    for (u32 i = (u32)0; i < n; i++)
        d.mulAdd((u32)10, (u32)(s[i] - (u8)'0'));
    return _json_toDouble(d, point - (i32)n, n);
    }

// Append a finite double in the shortest form that reads back as the same
// value: as a double, or, when `single`, as the float it came from. Always
// has a '.' or an exponent, so it reads back as a float and not an integer.
void _json_appendDouble(String* out, double v, bool single)
    {
    u64 bits = _json_dbits(v);
    bool neg = (bits >> (u64)63) != (u64)0;
    u32 ex = (u32)((bits >> (u64)52) & (u64)0x7FF);
    u64 man = bits & (u64)0x000FFFFFFFFFFFFF;
    if (neg)
        out.appendByte((u8)'-');
    if (ex == (u32)0 && man == (u64)0)
        {
        out.appendCString("0.0");
        return;
        }
    u64 m = man;
    i32 e2 = (i32)-1074;
    if (ex != (u32)0)
        {
        m = man | ((u64)1 << (u64)52);
        e2 = (i32)ex - (i32)1075;
        }
    while (m != (u64)0 && (m & (u64)1) == (u64)0)
        {
        m = m >> (u64)1;
        e2 = e2 + (i32)1;
        }
    // m * 2^e2 as an exact decimal: digits * 10^dexp
    _JSONBig* n = _JSONBig.withU64(m);
    i32 dexp = (i32)0;
    if (e2 > (i32)0)
        {
        n.shl((u32)e2);
        }
    else if (e2 < (i32)0)
        {
        n.mulPow5((u32)(-e2));
        dexp = e2;
        }
    String* all = n.toDecimal();
    i32 point = (i32)all.byteLength() + dexp;
    double mag = _json_dfrom(bits & (u64)0x7FFFFFFFFFFFFFFF);
    u32 lo = single ? (u32)6 : (u32)15;
    u32 hi = single ? (u32)9 : (u32)17;
    // A subnormal carries fewer digits, so its shortest form can be shorter
    // than the search would otherwise start at.
    if (ex == (u32)0 || (single && ex < (u32)897))
        lo = (u32)1;
    String* digits = (String*)0;
    i32 dpoint = point;
    for (u32 p = lo; p <= hi; p++)
        {
        i32 np = point;
        digits = _json_roundDigits(all, p, point, &np);
        dpoint = np;
        double back = _json_digitsToDouble(digits, np);
        if (single)
            {
            if ((float)back == (float)mag)
                break;
            }
        else if (_json_dbits(back) == _json_dbits(mag))
            {
            break;
            }
        }
    // d.ddd * 10^k
    i32 k = dpoint - (i32)1;
    u8* d = digits.cString();
    u32 nd = digits.byteLength();
    if (k >= (i32)-5 && k <= (i32)16)
        {
        if (dpoint <= (i32)0)
            {
            out.appendCString("0.");
            for (i32 z = dpoint; z < (i32)0; z++)
                out.appendByte((u8)'0');
            out.appendBytes(d, nd);
            }
        else if ((u32)dpoint >= nd)
            {
            out.appendBytes(d, nd);
            for (u32 z = nd; z < (u32)dpoint; z++)
                out.appendByte((u8)'0');
            out.appendCString(".0");
            }
        else
            {
            out.appendBytes(d, (u32)dpoint);
            out.appendByte((u8)'.');
            out.appendBytes(&d[dpoint], nd - (u32)dpoint);
            }
        return;
        }
    out.appendByte(d[0]);
    out.appendByte((u8)'.');
    if (nd > (u32)1)
        out.appendBytes(&d[1], nd - (u32)1);
    else
        out.appendByte((u8)'0');
    out.appendByte((u8)'e');
    if (k < (i32)0)
        {
        out.appendByte((u8)'-');
        k = -k;
        }
    else
        {
        out.appendByte((u8)'+');
        }
    out.append(String.withI32(k));
    }

// ═════════════════════════════════════════════════════════════════════════════
// _JSONNode / _JSONReader — a JSON document tree and the parser that builds it.
// ═════════════════════════════════════════════════════════════════════════════

enum _JSONKind = {JK_NULL, JK_FALSE, JK_TRUE, JK_NUMBER, JK_STRING, JK_ARRAY, JK_OBJECT};

class _JSONNode
    {
    u8 kind;        // a _JSONKind
    String* text;   // a string's value, or a number's text
    Array* items;   // an array's elements, or an object's values
    Array* keys;    // an object's keys (String), parallel to items

    // The value under `key` in an object node, or null. With `dollar`, the key
    // is matched with one extra '$' in front (the escaped form of a user key
    // that begins with '$').
    _JSONNode* field(u8* key, bool dollar)
        {
        if (kind != JK_OBJECT)
            return (_JSONNode*)0;
        u32 klen = String._cstringLen(key);
        u32 want = dollar ? klen + (u32)1 : klen;
        u32 n = keys.count();
        for (u32 i = (u32)0; i < n; i++)
            {
            String* k = (String*)keys.get(i);
            if (k.byteLength() != want)
                continue;
            u8* b = k.cString();
            u32 at = (u32)0;
            if (dollar)
                {
                if (b[0] != (u8)'$')
                    continue;
                at = (u32)1;
                }
            bool same = true;
            for (u32 j = (u32)0; j < klen; j++)
                {
                if (b[at + j] != key[j])
                    {
                    same = false;
                    break;
                    }
                }
            if (same)
                return (_JSONNode*)items.get(i);
            }
        return (_JSONNode*)0;
        }

    bool isString(string s)
        {
        return kind == JK_STRING && textIs(s);
        }

    // The node's text (a string's value or a number's digits) is `s`.
    bool textIs(string s)
        {
        if (text == 0)
            return false;
        u32 n = String._cstringLen(s);
        if (text.byteLength() != n)
            return false;
        u8* b = text.cString();
        for (u32 i = (u32)0; i < n; i++)
            {
            if (b[i] != s[i])
                return false;
            }
        return true;
        }

    // A number written without a fraction or an exponent.
    bool isInteger(void)
        {
        if (kind != JK_NUMBER)
            return false;
        u8* b = text.cString();
        u32 n = text.byteLength();
        for (u32 i = (u32)0; i < n; i++)
            {
            u8 c = b[i];
            if (c == (u8)'.' || c == (u8)'e' || c == (u8)'E')
                return false;
            }
        return true;
        }
    }

class _JSONReader
    {
    u8* _p;
    u32 _n;
    u32 _i;
    u32 _depth;
    String* _error;

    _JSONNode* parse(u8* p, u32 n)
        {
        _p = p;
        _n = n;
        _i = (u32)0;
        _depth = (u32)0;
        _error = (String*)0;
        _ws();
        _JSONNode* v = _value();
        if (_error != 0)
            return (_JSONNode*)0;
        _ws();
        if (_i != _n)
            {
            _fail("unexpected text after the JSON value");
            return (_JSONNode*)0;
            }
        return v;
        }

    void _fail(string why)
        {
        if (_error != 0)
            return;
        _error = String.withCString("bad JSON at byte ");
        _error.append(String.withU32(_i));
        _error.appendCString(": ");
        _error.appendCString(why);
        }

    void _ws(void)
        {
        u8* p = _p;
        while (_i < _n)
            {
            u8 c = p[_i];
            if (c != (u8)' ' && c != (u8)'\t' && c != (u8)'\n' && c != (u8)'\r')
                return;
            _i = _i + (u32)1;
            }
        }

    bool _word(string w, u32 len)
        {
        if (_i + len > _n)
            return false;
        u8* p = _p;
        for (u32 k = (u32)0; k < len; k++)
            {
            if (p[_i + k] != w[k])
                return false;
            }
        _i = _i + len;
        return true;
        }

    _JSONNode* _node(_JSONKind kind)
        {
        _JSONNode* n = new _JSONNode();
        n.kind = (u8)kind;
        return n;
        }

    _JSONNode* _value(void)
        {
        if (_i >= _n)
            {
            _fail("unexpected end of input");
            return (_JSONNode*)0;
            }
        u8* p = _p;
        u8 c = p[_i];
        if (c == (u8)'{')
            return _object();
        if (c == (u8)'[')
            return _array();
        if (c == (u8)'"')
            {
            _JSONNode* s = _node(JK_STRING);
            s.text = _string();
            return s;
            }
        if (c == (u8)'-' || (c >= (u8)'0' && c <= (u8)'9'))
            return _number();
        if (_word("true", (u32)4))
            return _node(JK_TRUE);
        if (_word("false", (u32)5))
            return _node(JK_FALSE);
        if (_word("null", (u32)4))
            return _node(JK_NULL);
        _fail("expected a value");
        return (_JSONNode*)0;
        }

    bool _digits(void)
        {
        u8* p = _p;
        u32 start = _i;
        while (_i < _n && p[_i] >= (u8)'0' && p[_i] <= (u8)'9')
            _i = _i + (u32)1;
        return _i > start;
        }

    _JSONNode* _number(void)
        {
        u8* p = _p;
        u32 start = _i;
        if (p[_i] == (u8)'-')
            _i = _i + (u32)1;
        if (_i < _n && p[_i] == (u8)'0')
            {
            _i = _i + (u32)1;
            }
        else if (!_digits())
            {
            _fail("bad number");
            return (_JSONNode*)0;
            }
        if (_i < _n && p[_i] == (u8)'.')
            {
            _i = _i + (u32)1;
            if (!_digits())
                {
                _fail("bad number");
                return (_JSONNode*)0;
                }
            }
        if (_i < _n && (p[_i] == (u8)'e' || p[_i] == (u8)'E'))
            {
            _i = _i + (u32)1;
            if (_i < _n && (p[_i] == (u8)'+' || p[_i] == (u8)'-'))
                _i = _i + (u32)1;
            if (!_digits())
                {
                _fail("bad number");
                return (_JSONNode*)0;
                }
            }
        _JSONNode* n = _node(JK_NUMBER);
        n.text = String.withBytes(&p[start], _i - start);
        return n;
        }

    u32 _hex4(void)
        {
        if (_i + (u32)4 > _n)
            {
            _fail("unexpected end of input");
            return (u32)0;
            }
        u8* p = _p;
        u32 v = (u32)0;
        for (u32 k = (u32)0; k < (u32)4; k++)
            {
            u8 c = p[_i + k];
            u32 d = (u32)0;
            if (c >= (u8)'0' && c <= (u8)'9')
                d = (u32)(c - (u8)'0');
            else if (c >= (u8)'a' && c <= (u8)'f')
                d = (u32)(c - (u8)'a') + (u32)10;
            else if (c >= (u8)'A' && c <= (u8)'F')
                d = (u32)(c - (u8)'A') + (u32)10;
            else
                {
                _fail("bad \\u escape");
                return (u32)0;
                }
            v = (v << (u32)4) | d;
            }
        _i = _i + (u32)4;
        return v;
        }

    // At the opening quote. Returns the decoded string.
    String* _string(void)
        {
        u8* p = _p;
        String* s = String.withCString("");
        _i = _i + (u32)1;
        while (true)
            {
            if (_i >= _n)
                {
                _fail("unterminated string");
                return s;
                }
            u8 c = p[_i];
            if (c == (u8)'"')
                {
                _i = _i + (u32)1;
                return s;
                }
            if (c < (u8)$20)
                {
                _fail("control character in a string");
                return s;
                }
            if (c != (u8)'\\')
                {
                // copy the run up to the next quote, backslash or control byte
                u32 start = _i;
                while (_i < _n && p[_i] != (u8)'"' && p[_i] != (u8)'\\' && p[_i] >= (u8)$20)
                    _i = _i + (u32)1;
                s.appendBytes(&p[start], _i - start);
                continue;
                }
            _i = _i + (u32)1;
            if (_i >= _n)
                {
                _fail("unterminated string");
                return s;
                }
            u8 e = p[_i];
            _i = _i + (u32)1;
            if (e == (u8)'"' || e == (u8)'\\' || e == (u8)'/')
                s.appendByte(e);
            else if (e == (u8)'n')
                s.appendByte((u8)$0A);
            else if (e == (u8)'r')
                s.appendByte((u8)$0D);
            else if (e == (u8)'t')
                s.appendByte((u8)$09);
            else if (e == (u8)'b')
                s.appendByte((u8)$08);
            else if (e == (u8)'f')
                s.appendByte((u8)$0C);
            else if (e == (u8)'u')
                {
                u32 cp = _hex4();
                if (_error != 0)
                    return s;
                // a surrogate pair is one code point
                if (cp >= (u32)0xD800 && cp <= (u32)0xDBFF && _i + (u32)6 <= _n
                    && p[_i] == (u8)'\\' && p[_i + (u32)1] == (u8)'u')
                    {
                    u32 save = _i;
                    _i = _i + (u32)2;
                    u32 lo = _hex4();
                    if (_error != 0)
                        return s;
                    if (lo >= (u32)0xDC00 && lo <= (u32)0xDFFF)
                        cp = (u32)0x10000 + ((cp - (u32)0xD800) << (u32)10) + (lo - (u32)0xDC00);
                    else
                        _i = save;
                    }
                s.appendChar(cp);
                }
            else
                {
                _fail("bad escape in a string");
                return s;
                }
            }
        return s;
        }

    _JSONNode* _array(void)
        {
        _depth = _depth + (u32)1;
        if (_depth > (u32)256)
            {
            _fail("nested too deeply");
            return (_JSONNode*)0;
            }
        _JSONNode* a = _node(JK_ARRAY);
        a.items = new Array();
        _i = _i + (u32)1;
        _ws();
        u8* p = _p;
        if (_i < _n && p[_i] == (u8)']')
            {
            _i = _i + (u32)1;
            _depth = _depth - (u32)1;
            return a;
            }
        while (true)
            {
            _ws();
            _JSONNode* v = _value();
            if (_error != 0)
                return (_JSONNode*)0;
            a.items.add(v);
            _ws();
            if (_i >= _n)
                {
                _fail("unterminated array");
                return (_JSONNode*)0;
                }
            u8 c = p[_i];
            _i = _i + (u32)1;
            if (c == (u8)']')
                break;
            if (c != (u8)',')
                {
                _i = _i - (u32)1;
                _fail("expected ',' or ']'");
                return (_JSONNode*)0;
                }
            }
        _depth = _depth - (u32)1;
        return a;
        }

    _JSONNode* _object(void)
        {
        _depth = _depth + (u32)1;
        if (_depth > (u32)256)
            {
            _fail("nested too deeply");
            return (_JSONNode*)0;
            }
        _JSONNode* o = _node(JK_OBJECT);
        o.items = new Array();
        o.keys = new Array();
        _i = _i + (u32)1;
        _ws();
        u8* p = _p;
        if (_i < _n && p[_i] == (u8)'}')
            {
            _i = _i + (u32)1;
            _depth = _depth - (u32)1;
            return o;
            }
        while (true)
            {
            _ws();
            if (_i >= _n || p[_i] != (u8)'"')
                {
                _fail("expected a key");
                return (_JSONNode*)0;
                }
            String* k = _string();
            if (_error != 0)
                return (_JSONNode*)0;
            _ws();
            if (_i >= _n || p[_i] != (u8)':')
                {
                _fail("expected ':'");
                return (_JSONNode*)0;
                }
            _i = _i + (u32)1;
            _ws();
            _JSONNode* v = _value();
            if (_error != 0)
                return (_JSONNode*)0;
            o.keys.add(k);
            o.items.add(v);
            _ws();
            if (_i >= _n)
                {
                _fail("unterminated object");
                return (_JSONNode*)0;
                }
            u8 c = p[_i];
            _i = _i + (u32)1;
            if (c == (u8)'}')
                break;
            if (c != (u8)',')
                {
                _i = _i - (u32)1;
                _fail("expected ',' or '}'");
                return (_JSONNode*)0;
                }
            }
        _depth = _depth - (u32)1;
        return o;
        }
    }

// ═════════════════════════════════════════════════════════════════════════════
// JSONError — what parse and stringify throw.
// ═════════════════════════════════════════════════════════════════════════════

class JSONError <Error>
    {
    String* _message;

    void init(String* message)
        {
        _message = message;
        }

    String* message(void)
        {
        return _message;
        }
    }

// ═════════════════════════════════════════════════════════════════════════════
// JSON — the public entry points.
// ═════════════════════════════════════════════════════════════════════════════

class JSON
    {
    // ── Reading ──────────────────────────────────────────────────────────

    // The value `text` holds: a Map, Array, String, Number or Null.
    static Object* parse(String* text) throws
        {
        if (text == 0)
            throw new JSONError(String.withCString("JSON: no text"));
        return JSON._parseBytes(text.cString(), text.byteLength());
        }

    // The same, from UTF-8 bytes.
    static Object* parseData(Data* data) throws
        {
        if (data == 0)
            throw new JSONError(String.withCString("JSON: no data"));
        return JSON._parseBytes(data.bytes(), data.length());
        }

    static Object* _parseBytes(u8* p, u32 n) throws
        {
        _JSONReader* reader = new _JSONReader();
        _JSONNode* root = reader.parse(p, n);
        if (root == 0)
            throw new JSONError(reader._error);
        return JSON._objectOf(root);
        }

    static Object* _objectOf(_JSONNode* node)
        {
        if (node.kind == JK_NULL)
            return (Object*)Null.null();
        if (node.kind == JK_TRUE)
            return (Object*)Number.withBool(true);
        if (node.kind == JK_FALSE)
            return (Object*)Number.withBool(false);
        if (node.kind == JK_NUMBER)
            return (Object*)JSON._numberOf(node);
        if (node.kind == JK_STRING)
            return (Object*)node.text;
        u32 n = node.items.count();
        if (node.kind == JK_ARRAY)
            {
            Array* a = new Array();
            for (u32 i = (u32)0; i < n; i++)
                a.add(JSON._objectOf((_JSONNode*)node.items.get(i)));
            return (Object*)a;
            }
        Map* m = new Map();
        for (u32 i = (u32)0; i < n; i++)
            m.set((String*)node.keys.get(i), JSON._objectOf((_JSONNode*)node.items.get(i)));
        return (Object*)m;
        }

    // ── Writing ──────────────────────────────────────────────────────────

    // `v` as compact JSON text: no spaces or newlines.
    static String* stringify(Object* v) throws
        {
        String* out = String.withCString("");
        JSON._write(out, v, false, (u32)0);
        return out;
        }

    // `v` as indented JSON text: two spaces a level, `"key": value`, one
    // member or element a line, and a final newline.
    static String* stringifyPretty(Object* v) throws
        {
        String* out = String.withCString("");
        JSON._write(out, v, true, (u32)0);
        out.appendByte((u8)'\n');
        return out;
        }

    // `v` as compact JSON in UTF-8 bytes.
    static Data* data(Object* v) throws
        {
        String* s = JSON.stringify(v);
        return Data.withBytes(s.cString(), s.byteLength());
        }

    static void _newline(String* out, u32 level)
        {
        out.appendByte((u8)'\n');
        for (u32 i = (u32)0; i < level; i++)
            out.appendCString("  ");
        }

    static void _write(String* out, Object* v, bool pretty, u32 level) throws
        {
        if (v == 0 || Null.isNull(v))
            {
            out.appendCString("null");
            return;
            }
        String* str = (String* ?)v;
        if (str != 0)
            {
            if (!str.isValidUtf8())
                throw new JSONError(String.withCString("JSON: a String that is not valid UTF-8"));
            JSON._appendString(out, str.cString(), str.byteLength());
            return;
            }
        Number* num = (Number* ?)v;
        if (num != 0)
            {
            if (num.isBool())
                out.appendCString(num.asBool() ? "true" : "false");
            else if (num.isInt())
                out.append(String.withI64(num.asI64()));
            else
                {
                double d = num.asDouble();
                if (d != d || d - d != 0.0d)
                    throw new JSONError(String.withCString("JSON: NaN and the infinities have no JSON spelling"));
                _json_appendDouble(out, d, false);
                }
            return;
            }
        Array* arr = (Array* ?)v;
        if (arr != 0)
            {
            u32 n = arr.count();
            out.appendByte((u8)'[');
            for (u32 i = (u32)0; i < n; i++)
                {
                if (i > (u32)0)
                    out.appendByte((u8)',');
                if (pretty)
                    JSON._newline(out, level + (u32)1);
                JSON._write(out, arr.get(i), pretty, level + (u32)1);
                }
            if (pretty && n > (u32)0)
                JSON._newline(out, level);
            out.appendByte((u8)']');
            return;
            }
        Map* map = (Map* ?)v;
        if (map != 0)
            {
            u32 n = map.count();
            out.appendByte((u8)'{');
            for (u32 i = (u32)0; i < n; i++)
                {
                String* key = (String* ?)map.enumAt(i);
                if (key == 0)
                    throw new JSONError(String.withCString("JSON: a Map key that is not a String"));
                if (!key.isValidUtf8())
                    throw new JSONError(String.withCString("JSON: a String that is not valid UTF-8"));
                if (i > (u32)0)
                    out.appendByte((u8)',');
                if (pretty)
                    JSON._newline(out, level + (u32)1);
                JSON._appendString(out, key.cString(), key.byteLength());
                out.appendCString(pretty ? ": " : ":");
                JSON._write(out, map.get(key), pretty, level + (u32)1);
                }
            if (pretty && n > (u32)0)
                JSON._newline(out, level);
            out.appendByte((u8)'}');
            return;
            }
        String* msg = String.withCString("JSON: a ");
        msg.append(v.className());
        msg.appendCString(" cannot be written as JSON");
        throw new JSONError(msg);
        }

    // ── Shared with Coder ────────────────────────────────────────────────

    // JSON string body: escapes for '"', '\' and the control characters; every
    // other byte, UTF-8 included, as it is.
    static void _appendEscaped(String* s, u8* p, u32 n)
        {
        u32 i = (u32)0;
        while (i < n)
            {
            u32 start = i;
            while (i < n && p[i] >= (u8)$20 && p[i] != (u8)'"' && p[i] != (u8)'\\')
                i = i + (u32)1;
            if (i > start)
                s.appendBytes(&p[start], i - start);
            if (i >= n)
                break;
            u8 c = p[i];
            i = i + (u32)1;
            s.appendByte((u8)'\\');
            if (c == (u8)'"' || c == (u8)'\\')
                s.appendByte(c);
            else if (c == (u8)$0A)
                s.appendByte((u8)'n');
            else if (c == (u8)$0D)
                s.appendByte((u8)'r');
            else if (c == (u8)$09)
                s.appendByte((u8)'t');
            else if (c == (u8)$08)
                s.appendByte((u8)'b');
            else if (c == (u8)$0C)
                s.appendByte((u8)'f');
            else
                {
                s.appendCString("u00");
                s.appendByte(Data._hexDigit(c >> (u8)4));
                s.appendByte(Data._hexDigit(c & (u8)$0F));
                }
            }
        }

    static void _appendString(String* s, u8* p, u32 n)
        {
        s.appendByte((u8)'"');
        JSON._appendEscaped(s, p, n);
        s.appendByte((u8)'"');
        }

    static Number* _numberOf(_JSONNode* node)
        {
        if (node.isInteger())
            {
            bool neg = false;
            bool over = false;
            u64 mag = JSON._magnitude(node.text, &neg, &over);
            if (!over)
                {
                if (!neg && mag <= (u64)0x7FFFFFFFFFFFFFFF)
                    return Number.withI64((i64)mag);
                if (neg && mag <= (u64)0x8000000000000000)
                    return Number.withI64((i64)((u64)0 - mag));
                if (!neg)
                    return Number.withU64(mag);
                }
            }
        return Number.withDouble(_json_parseDouble(node.text.cString(), node.text.byteLength()));
        }

    // The digits of an integer node as an unsigned magnitude.
    static u64 _magnitude(String* text, bool* neg, bool* over)
        {
        u8* b = text.cString();
        u32 n = text.byteLength();
        u32 i = (u32)0;
        *neg = false;
        *over = false;
        if (n > (u32)0 && b[0] == (u8)'-')
            {
            *neg = true;
            i = (u32)1;
            }
        u64 v = (u64)0;
        while (i < n)
            {
            u64 d = (u64)(b[i] - (u8)'0');
            if (v > ((u64)0xFFFFFFFFFFFFFFFF - d) / (u64)10)
                {
                *over = true;
                return (u64)0;
                }
            v = v * (u64)10 + d;
            i = i + (u32)1;
            }
        return v;
        }
    }
