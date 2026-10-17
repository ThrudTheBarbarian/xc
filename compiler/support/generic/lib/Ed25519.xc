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

// Ed25519.xc — Ed25519 signatures (RFC 8032): a 32-byte private seed, a
// 32-byte public key, a 64-byte signature over a message of any length.
//
//     u8 seed[32];  SecureRandom.fill(&seed[0], (u32)32);
//     Data* pub = Ed25519.publicKey(&seed[0]);
//     Data* sig = Ed25519.sign(msg, n, &seed[0]);
//     bool ok   = Ed25519.verify(msg, n, sig.bytes(), pub.bytes());
//
// Verification is strict (RFC 8032 §5.1.7, bundles-and-plugins.md review
// 12): S must be below the group order L, the public key and R must be
// canonical encodings (y below p) of points not of small order. The field and
// group arithmetic follow TweetNaCl's (public domain): 16 limbs of 16 bits in
// i64s, reduced mod 2^255 - 19. Not constant-time-hardened beyond that
// arithmetic's own shape; signing keys belong to the developer's machine.
#import "Foundation.xc"
#import "Sha512.xc"

i64 _ed_D[16] = { (i64)0x78a3, (i64)0x1359, (i64)0x4dca, (i64)0x75eb, (i64)0xd8ab, (i64)0x4141, (i64)0x0a4d, (i64)0x0070,
                  (i64)0xe898, (i64)0x7779, (i64)0x4079, (i64)0x8cc7, (i64)0xfe73, (i64)0x2b6f, (i64)0x6cee, (i64)0x5203 };
i64 _ed_D2[16] = { (i64)0xf159, (i64)0x26b2, (i64)0x9b94, (i64)0xebd6, (i64)0xb156, (i64)0x8283, (i64)0x149a, (i64)0x00e0,
                   (i64)0xd130, (i64)0xeef3, (i64)0x80f2, (i64)0x198e, (i64)0xfce7, (i64)0x56df, (i64)0xd9dc, (i64)0x2406 };
i64 _ed_X[16] = { (i64)0xd51a, (i64)0x8f25, (i64)0x2d60, (i64)0xc956, (i64)0xa7b2, (i64)0x9525, (i64)0xc760, (i64)0x692c,
                  (i64)0xdc5c, (i64)0xfdd6, (i64)0xe231, (i64)0xc0a4, (i64)0x53fe, (i64)0xcd6e, (i64)0x36d3, (i64)0x2169 };
i64 _ed_Y[16] = { (i64)0x6658, (i64)0x6666, (i64)0x6666, (i64)0x6666, (i64)0x6666, (i64)0x6666, (i64)0x6666, (i64)0x6666,
                  (i64)0x6666, (i64)0x6666, (i64)0x6666, (i64)0x6666, (i64)0x6666, (i64)0x6666, (i64)0x6666, (i64)0x6666 };
i64 _ed_I[16] = { (i64)0xa0b0, (i64)0x4a0e, (i64)0x1b27, (i64)0xc4ee, (i64)0xe478, (i64)0xad2f, (i64)0x1806, (i64)0x2f43,
                  (i64)0xd7a7, (i64)0x3dfb, (i64)0x0099, (i64)0x2b4d, (i64)0xdf0b, (i64)0x4fc1, (i64)0x2480, (i64)0x2b83 };
// The group order L, little-endian bytes.
i64 _ed_L[32] = { (i64)0xed, (i64)0xd3, (i64)0xf5, (i64)0x5c, (i64)0x1a, (i64)0x63, (i64)0x12, (i64)0x58,
                  (i64)0xd6, (i64)0x9c, (i64)0xf7, (i64)0xa2, (i64)0xde, (i64)0xf9, (i64)0xde, (i64)0x14,
                  (i64)0, (i64)0, (i64)0, (i64)0, (i64)0, (i64)0, (i64)0, (i64)0,
                  (i64)0, (i64)0, (i64)0, (i64)0, (i64)0, (i64)0, (i64)0, (i64)0x10 };

class Ed25519
    {
    // ── the field, mod 2^255 - 19: an element is 16 i64 limbs ────────────
    static void _set(i64* r, i64* a)
        {
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            r[i] = a[i];
        }
    static void _zero(i64* r)
        {
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            r[i] = (i64)0;
        }
    static void _one(i64* r)
        {
        Ed25519._zero(r);
        r[0] = (i64)1;
        }
    static void _car(i64* o)
        {
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            o[i] = o[i] + ((i64)1 << (i64)16);
            i64 c = o[i] >> (i64)16;
            if (i < (u32)15)
                o[i + (u32)1] = o[i + (u32)1] + c - (i64)1;
            else
                o[0] = o[0] + (i64)38 * (c - (i64)1);
            o[i] = o[i] - (c << (i64)16);
            }
        }
    // Swap p and q when b is 1, without a branch on b.
    static void _sel(i64* p, i64* q, i64 b)
        {
        i64 c = ~(b - (i64)1);
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            i64 t = c & (p[i] ^ q[i]);
            p[i] = p[i] ^ t;
            q[i] = q[i] ^ t;
            }
        }
    static void _pack(u8* o, i64* n)
        {
        i64 m[16];
        i64 t[16];
        Ed25519._set(&t[0], n);
        Ed25519._car(&t[0]);
        Ed25519._car(&t[0]);
        Ed25519._car(&t[0]);
        for (u32 j = (u32)0; j < (u32)2; j = j + (u32)1)
            {
            m[0] = t[0] - (i64)0xffed;
            for (u32 i = (u32)1; i < (u32)15; i = i + (u32)1)
                {
                m[i] = t[i] - (i64)0xffff - ((m[i - (u32)1] >> (i64)16) & (i64)1);
                m[i - (u32)1] = m[i - (u32)1] & (i64)0xffff;
                }
            m[15] = t[15] - (i64)0x7fff - ((m[14] >> (i64)16) & (i64)1);
            i64 b = (m[15] >> (i64)16) & (i64)1;
            m[14] = m[14] & (i64)0xffff;
            Ed25519._sel(&t[0], &m[0], (i64)1 - b);
            }
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            o[(u32)2 * i] = (u8)(t[i] & (i64)0xff);
            o[(u32)2 * i + (u32)1] = (u8)((t[i] >> (i64)8) & (i64)0xff);
            }
        }
    static bool _neq(i64* a, i64* b)
        {
        u8 c[32];
        u8 d[32];
        Ed25519._pack(&c[0], a);
        Ed25519._pack(&d[0], b);
        u32 diff = (u32)0;
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            diff = diff | (u32)(c[i] ^ d[i]);
        return diff != (u32)0;
        }
    static i64 _par(i64* a)
        {
        u8 d[32];
        Ed25519._pack(&d[0], a);
        return (i64)(d[0] & (u8)1);
        }
    static void _unpack(i64* o, u8* n)
        {
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            o[i] = (i64)n[(u32)2 * i] + ((i64)n[(u32)2 * i + (u32)1] << (i64)8);
        o[15] = o[15] & (i64)0x7fff;
        }
    static void _add(i64* o, i64* a, i64* b)
        {
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            o[i] = a[i] + b[i];
        }
    static void _sub(i64* o, i64* a, i64* b)
        {
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            o[i] = a[i] - b[i];
        }
    static void _mul(i64* o, i64* a, i64* b)
        {
        i64 t[31];
        for (u32 i = (u32)0; i < (u32)31; i = i + (u32)1)
            t[i] = (i64)0;
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            for (u32 j = (u32)0; j < (u32)16; j = j + (u32)1)
                t[i + j] = t[i + j] + a[i] * b[j];
        for (u32 i = (u32)0; i < (u32)15; i = i + (u32)1)
            t[i] = t[i] + (i64)38 * t[i + (u32)16];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            o[i] = t[i];
        Ed25519._car(o);
        Ed25519._car(o);
        }
    static void _inv(i64* o, i64* i)
        {
        i64 c[16];
        Ed25519._set(&c[0], i);
        for (i32 a = (i32)253; a >= (i32)0; a = a - (i32)1)
            {
            Ed25519._mul(&c[0], &c[0], &c[0]);
            if (a != (i32)2 && a != (i32)4)
                Ed25519._mul(&c[0], &c[0], i);
            }
        Ed25519._set(o, &c[0]);
        }
    static void _pow2523(i64* o, i64* i)
        {
        i64 c[16];
        Ed25519._set(&c[0], i);
        for (i32 a = (i32)250; a >= (i32)0; a = a - (i32)1)
            {
            Ed25519._mul(&c[0], &c[0], &c[0]);
            if (a != (i32)1)
                Ed25519._mul(&c[0], &c[0], i);
            }
        Ed25519._set(o, &c[0]);
        }

    // ── the group: a point is four field elements (X, Y, Z, T), 64 limbs ──
    static void _padd(i64* p, i64* q)
        {
        i64 a[16];
        i64 b[16];
        i64 c[16];
        i64 d[16];
        i64 t[16];
        i64 e[16];
        i64 f[16];
        i64 g[16];
        i64 h[16];
        Ed25519._sub(&a[0], p + (u32)16, p);
        Ed25519._sub(&t[0], q + (u32)16, q);
        Ed25519._mul(&a[0], &a[0], &t[0]);
        Ed25519._add(&b[0], p, p + (u32)16);
        Ed25519._add(&t[0], q, q + (u32)16);
        Ed25519._mul(&b[0], &b[0], &t[0]);
        Ed25519._mul(&c[0], p + (u32)48, q + (u32)48);
        Ed25519._mul(&c[0], &c[0], &_ed_D2[0]);
        Ed25519._mul(&d[0], p + (u32)32, q + (u32)32);
        Ed25519._add(&d[0], &d[0], &d[0]);
        Ed25519._sub(&e[0], &b[0], &a[0]);
        Ed25519._sub(&f[0], &d[0], &c[0]);
        Ed25519._add(&g[0], &d[0], &c[0]);
        Ed25519._add(&h[0], &b[0], &a[0]);
        Ed25519._mul(p, &e[0], &f[0]);
        Ed25519._mul(p + (u32)16, &h[0], &g[0]);
        Ed25519._mul(p + (u32)32, &g[0], &f[0]);
        Ed25519._mul(p + (u32)48, &e[0], &h[0]);
        }
    static void _cswap(i64* p, i64* q, i64 b)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            Ed25519._sel(p + i * (u32)16, q + i * (u32)16, b);
        }
    static void _ppack(u8* r, i64* p)
        {
        i64 tx[16];
        i64 ty[16];
        i64 zi[16];
        Ed25519._inv(&zi[0], p + (u32)32);
        Ed25519._mul(&tx[0], p, &zi[0]);
        Ed25519._mul(&ty[0], p + (u32)16, &zi[0]);
        Ed25519._pack(r, &ty[0]);
        r[31] = r[31] ^ (u8)(Ed25519._par(&tx[0]) << (i64)7);
        }
    static void _identity(i64* p)
        {
        Ed25519._zero(p);
        Ed25519._one(p + (u32)16);
        Ed25519._one(p + (u32)32);
        Ed25519._zero(p + (u32)48);
        }
    // p = s * q (s: 32 little-endian bytes); q is consumed.
    static void _smul(i64* p, i64* q, u8* s)
        {
        Ed25519._identity(p);
        for (i32 i = (i32)255; i >= (i32)0; i = i - (i32)1)
            {
            i64 b = (i64)((s[(u32)i / (u32)8] >> (u8)((u32)i & (u32)7)) & (u8)1);
            Ed25519._cswap(p, q, b);
            Ed25519._padd(q, p);
            Ed25519._padd(p, p);
            Ed25519._cswap(p, q, b);
            }
        }
    static void _sbase(i64* p, u8* s)
        {
        i64 q[64];
        Ed25519._set(&q[0], &_ed_X[0]);
        Ed25519._set(&q[16], &_ed_Y[0]);
        Ed25519._one(&q[32]);
        Ed25519._mul(&q[48], &_ed_X[0], &_ed_Y[0]);
        Ed25519._smul(p, &q[0], s);
        }

    // ── scalars mod L ─────────────────────────────────────────────────────
    static void _modL(u8* r, i64* x)
        {
        for (i32 i = (i32)63; i >= (i32)32; i = i - (i32)1)
            {
            i64 carry = (i64)0;
            i32 j = i - (i32)32;
            while (j < i - (i32)12)
                {
                x[j] = x[j] + carry - (i64)16 * x[i] * _ed_L[j - (i - (i32)32)];
                carry = (x[j] + (i64)128) >> (i64)8;
                x[j] = x[j] - (carry << (i64)8);
                j = j + (i32)1;
                }
            x[j] = x[j] + carry;
            x[i] = (i64)0;
            }
        i64 carry = (i64)0;
        for (u32 j = (u32)0; j < (u32)32; j = j + (u32)1)
            {
            x[j] = x[j] + carry - (x[31] >> (i64)4) * _ed_L[j];
            carry = x[j] >> (i64)8;
            x[j] = x[j] & (i64)255;
            }
        for (u32 j = (u32)0; j < (u32)32; j = j + (u32)1)
            x[j] = x[j] - carry * _ed_L[j];
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            {
            x[i + (u32)1] = x[i + (u32)1] + (x[i] >> (i64)8);
            r[i] = (u8)(x[i] & (i64)255);
            }
        }
    // A 64-byte hash reduced mod L, in place (into its first 32 bytes).
    static void _reduce(u8* r)
        {
        i64 x[64];
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
            {
            x[i] = (i64)r[i];
            r[i] = (u8)0;
            }
        Ed25519._modL(r, &x[0]);
        }
    // Whether the 32-byte little-endian scalar is below L (canonical S).
    static bool _belowL(u8* s)
        {
        for (i32 i = (i32)31; i >= (i32)0; i = i - (i32)1)
            {
            if ((i64)s[i] < _ed_L[i])
                return true;
            if ((i64)s[i] > _ed_L[i])
                return false;
            }
        return false;
        }
    // Whether a 32-byte point encoding has y below p = 2^255 - 19 (canonical).
    static bool _canonicalY(u8* e)
        {
        if ((e[31] & (u8)0x7f) != (u8)0x7f)
            return true;
        for (u32 i = (u32)30; i >= (u32)1; i = i - (u32)1)
            if (e[i] != (u8)0xff)
                return true;
        return e[0] < (u8)0xed;
        }

    // The point -A for an encoding (r = -A), false when it is not a point.
    static bool _unpackNeg(i64* r, u8* p)
        {
        i64 t[16];
        i64 chk[16];
        i64 num[16];
        i64 den[16];
        i64 den2[16];
        i64 den4[16];
        i64 den6[16];
        i64 zero[16];
        Ed25519._zero(&zero[0]);
        Ed25519._one(r + (u32)32);
        Ed25519._unpack(r + (u32)16, p);
        Ed25519._mul(&num[0], r + (u32)16, r + (u32)16);
        Ed25519._mul(&den[0], &num[0], &_ed_D[0]);
        Ed25519._sub(&num[0], &num[0], r + (u32)32);
        Ed25519._add(&den[0], r + (u32)32, &den[0]);
        Ed25519._mul(&den2[0], &den[0], &den[0]);
        Ed25519._mul(&den4[0], &den2[0], &den2[0]);
        Ed25519._mul(&den6[0], &den4[0], &den2[0]);
        Ed25519._mul(&t[0], &den6[0], &num[0]);
        Ed25519._mul(&t[0], &t[0], &den[0]);
        Ed25519._pow2523(&t[0], &t[0]);
        Ed25519._mul(&t[0], &t[0], &num[0]);
        Ed25519._mul(&t[0], &t[0], &den[0]);
        Ed25519._mul(&t[0], &t[0], &den[0]);
        Ed25519._mul(r, &t[0], &den[0]);
        Ed25519._mul(&chk[0], r, r);
        Ed25519._mul(&chk[0], &chk[0], &den[0]);
        if (Ed25519._neq(&chk[0], &num[0]))
            Ed25519._mul(r, r, &_ed_I[0]);
        Ed25519._mul(&chk[0], r, r);
        Ed25519._mul(&chk[0], &chk[0], &den[0]);
        if (Ed25519._neq(&chk[0], &num[0]))
            return false;
        if (Ed25519._par(r) == (i64)(p[31] >> (u8)7))
            Ed25519._sub(r, &zero[0], r);
        Ed25519._mul(r + (u32)48, r, r + (u32)16);
        return true;
        }
    // Whether the point (any sign) has small order: 8P is the identity.
    static bool _smallOrder(i64* p)
        {
        i64 q[64];
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
            q[i] = p[i];
        Ed25519._padd(&q[0], &q[0]);
        Ed25519._padd(&q[0], &q[0]);
        Ed25519._padd(&q[0], &q[0]);
        // The identity has X = 0 and Y = Z.
        i64 zero[16];
        Ed25519._zero(&zero[0]);
        return !Ed25519._neq(&q[0], &zero[0]) && !Ed25519._neq(&q[16], &q[32]);
        }

    // ── the API ───────────────────────────────────────────────────────────
    // The 64-byte expanded secret: SHA-512 of the seed, clamped.
    static void _expand(u8* d, u8* seed)
        {
        Sha512.into(d, seed, (u32)32);
        d[0] = d[0] & (u8)248;
        d[31] = d[31] & (u8)127;
        d[31] = d[31] | (u8)64;
        }

    // The public key (32 bytes) of a 32-byte seed.
    static Data* publicKey(u8* seed)
        {
        u8 d[64];
        i64 p[64];
        Ed25519._expand(&d[0], seed);
        Ed25519._sbase(&p[0], &d[0]);
        Data* pk = Data.withLength((u32)32);
        Ed25519._ppack(pk.bytes(), &p[0]);
        return pk;
        }

    // The signature (64 bytes) of n bytes of msg with a 32-byte seed.
    static Data* sign(u8* msg, u32 n, u8* seed)
        {
        u8 d[64];
        u8 r[64];
        u8 h[64];
        i64 p[64];
        i64 x[64];
        Ed25519._expand(&d[0], seed);
        Data* pk = Ed25519.publicKey(seed);
        // r = H(prefix || M) mod L
        Data* buf = Data.withLength(n + (u32)64);
        u8* b = buf.bytes();
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            b[(u32)32 + i] = d[(u32)32 + i];
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            b[(u32)64 + i] = msg[i];
        Sha512.into(&r[0], b + (u32)32, n + (u32)32);
        Ed25519._reduce(&r[0]);
        Data* sig = Data.withLength((u32)64);
        u8* s = sig.bytes();
        Ed25519._sbase(&p[0], &r[0]);
        Ed25519._ppack(s, &p[0]);
        // k = H(R || A || M) mod L
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            {
            b[i] = s[i];
            b[(u32)32 + i] = pk.bytes()[i];
            }
        Sha512.into(&h[0], b, n + (u32)64);
        Ed25519._reduce(&h[0]);
        // S = r + k * a mod L
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
            x[i] = (i64)0;
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            x[i] = (i64)r[i];
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            for (u32 j = (u32)0; j < (u32)32; j = j + (u32)1)
                x[i + j] = x[i + j] + (i64)h[i] * (i64)d[j];
        Ed25519._modL(s + (u32)32, &x[0]);
        return sig;
        }

    // Whether sig (64 bytes) is a valid signature of n bytes of msg under the
    // 32-byte public key: strict, as the header says.
    static bool verify(u8* msg, u32 n, u8* sig, u8* pub)
        {
        if (!Ed25519._belowL(sig + (u32)32))
            return false;
        if (!Ed25519._canonicalY(pub) || !Ed25519._canonicalY(sig))
            return false;
        i64 q[64];
        i64 p[64];
        i64 rr[64];
        if (!Ed25519._unpackNeg(&q[0], pub) || Ed25519._smallOrder(&q[0]))
            return false;
        if (!Ed25519._unpackNeg(&rr[0], sig) || Ed25519._smallOrder(&rr[0]))
            return false;
        u8 h[64];
        Data* buf = Data.withLength(n + (u32)64);
        u8* b = buf.bytes();
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            {
            b[i] = sig[i];
            b[(u32)32 + i] = pub[i];
            }
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            b[(u32)64 + i] = msg[i];
        Sha512.into(&h[0], b, n + (u32)64);
        Ed25519._reduce(&h[0]);
        // [S]B - [k]A, packed, must be R.
        Ed25519._smul(&p[0], &q[0], &h[0]);
        i64 sb[64];
        Ed25519._sbase(&sb[0], sig + (u32)32);
        Ed25519._padd(&p[0], &sb[0]);
        u8 t[32];
        Ed25519._ppack(&t[0], &p[0]);
        u32 diff = (u32)0;
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            diff = diff | (u32)(t[i] ^ sig[i]);
        return diff == (u32)0;
        }
    }
