// CodeSign.xc — identity (developer) code signing for Mach-O, in xtc: the
// mirror of XTDer / XTDerReader / XTIdentity / XTPkcs8 / XTCms / XTCodeSign
// (docs/mobile/signing.md, Phase A+B). No Apple API anywhere: DER, SHA-1 and
// SHA-256, HMAC / PBKDF2, 3DES (the PKCS#8 wrap macOS exports), RSA PKCS#1
// v1.5 over the ported Bignum, CMS SignedData, and the Mach-O re-splice that
// replaces an ad-hoc signature with the identity's. Byte-identical to the
// reference for the same identity and signing time — that is the harness.
//
// Bytes are Array@ of Number (the port's convention for images).

#import "Foundation.xc"
#import "Files.xc"
#import "MachO.xc" // Sha256
#import "Bignum.xc"
#import "ApkSign.xc" // apkAppend

// ── byte helpers ────────────────────────────────────────────────────────
class Bytes
    {
    void init(void)
        {
        }
    static Array* of(u32 n, u32 v)
        {
        Array* a = new Array();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            a.add((Object*)Number.withU32(v));
        return a;
        }
    static u32 at(Array* a, u32 i)
        {
        return ((Number*)a.get(i)).asU32();
        }
    static void put(Array* a, u32 i, u32 v)
        {
        a.set(i, (Object*)Number.withU32(v & (u32)$FF));
        }
    static void add(Array* a, u32 v)
        {
        a.add((Object*)Number.withU32(v & (u32)$FF));
        }
    static Array* slice(Array* a, u32 from, u32 len)
        {
        Array* o = new Array();
        for (u32 i = (u32)0; i < len; i = i + (u32)1)
            o.add(a.get(from + i));
        return o;
        }
    static Array* copy(Array* a)
        {
        return Bytes.slice(a, (u32)0, a.count());
        }
    static bool equal(Array* a, Array* b)
        {
        if (a.count() != b.count())
            return false;
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (Bytes.at(a, i) != Bytes.at(b, i))
                return false;
        return true;
        }
    static i32 compare(Array* a, Array* b)
        {
        u32 m = a.count() < b.count() ? a.count() : b.count();
        for (u32 i = (u32)0; i < m; i = i + (u32)1)
            {
            if (Bytes.at(a, i) < Bytes.at(b, i))
                return (i32)-1;
            if (Bytes.at(a, i) > Bytes.at(b, i))
                return (i32)1;
            }
        if (a.count() < b.count())
            return (i32)-1;
        if (a.count() > b.count())
            return (i32)1;
        return (i32)0;
        }
    static Array* fromString(String* s)
        {
        Array* o = new Array();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            Bytes.add(o, (u32)s.byteAt(i));
        return o;
        }
    static Array* fromData(Data* d)
        {
        Array* o = new Array();
        for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
            Bytes.add(o, (u32)d.byteAt(i));
        return o;
        }
    static Data* toData(Array* a)
        {
        Data* d = Data.withCapacity(a.count());
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            d.appendByte((u8)Bytes.at(a, i));
        return d;
        }
    static u32 rd32le(Array* a, u32 o)
        {
        return Bytes.at(a, o) | (Bytes.at(a, o + (u32)1) << (u32)8) | (Bytes.at(a, o + (u32)2) << (u32)16) | (Bytes.at(a, o + (u32)3) << (u32)24);
        }
    static void wr32le(Array* a, u32 o, u32 v)
        {
        for (u32 i = (u32)0; i < (u32)4; i = i + (u32)1)
            Bytes.put(a, o + i, v >> (i * (u32)8));
        }
    static void put32be(Array* a, u32 v)
        {
        Bytes.add(a, v >> (u32)24);
        Bytes.add(a, v >> (u32)16);
        Bytes.add(a, v >> (u32)8);
        Bytes.add(a, v);
        }
    static void put64be(Array* a, u32 hi, u32 lo)
        {
        Bytes.put32be(a, hi);
        Bytes.put32be(a, lo);
        }
    static Array* sha256(Array* a)
        {
        Sha256* h = new Sha256();
        h.update(a, (u32)0, a.count());
        Array* out = new Array();
        h.finalise(out);
        return out;
        }
    }

    // ── SHA-1 (PBKDF2's default PRF in the exported identity) ───────────────
    class Sha1
    {
    void init(void)
        {
        }
    static u32 rol(u32 x, u32 r)
        {
        return (x << r) | (x >> ((u32)32 - r));
        }
    static Array* digest(Array* msg)
        {
        u32 h0 = (u32)$67452301;
        u32 h1 = (u32)$EFCDAB89;
        u32 h2 = (u32)$98BADCFE;
        u32 h3 = (u32)$10325476;
        u32 h4 = (u32)$C3D2E1F0;
        Array* m = Bytes.copy(msg);
        u32 ml = msg.count();
        Bytes.add(m, (u32)$80);
        while ((m.count() % (u32)64) != (u32)56)
            Bytes.add(m, (u32)0);
        u32 bits = ml * (u32)8;
        Bytes.add(m, (u32)0);
        Bytes.add(m, (u32)0);
        Bytes.add(m, (u32)0);
        Bytes.add(m, ml >> (u32)29);
        Bytes.add(m, bits >> (u32)24);
        Bytes.add(m, bits >> (u32)16);
        Bytes.add(m, bits >> (u32)8);
        Bytes.add(m, bits);
        u32 w[80];
        for (u32 off = (u32)0; off < m.count(); off = off + (u32)64)
            {
            for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
                w[i] = (Bytes.at(m, off + i * (u32)4) << (u32)24) | (Bytes.at(m, off + i * (u32)4 + (u32)1) << (u32)16) | (Bytes.at(m, off + i * (u32)4 + (u32)2) << (u32)8) | Bytes.at(m, off + i * (u32)4 + (u32)3);
            for (u32 i = (u32)16; i < (u32)80; i = i + (u32)1)
                w[i] = Sha1.rol(w[i - (u32)3] ^ w[i - (u32)8] ^ w[i - (u32)14] ^ w[i - (u32)16], (u32)1);
            u32 a = h0;
            u32 b = h1;
            u32 c = h2;
            u32 d = h3;
            u32 e = h4;
            for (u32 i = (u32)0; i < (u32)80; i = i + (u32)1)
                {
                u32 f;
                u32 k;
                if (i < (u32)20)
                    {
                    f = (b & c) | (~b & d);
                    k = (u32)$5A827999;
                    }
                else if (i < (u32)40)
                    {
                    f = b ^ c ^ d;
                    k = (u32)$6ED9EBA1;
                    }
                else if (i < (u32)60)
                    {
                    f = (b & c) | (b & d) | (c & d);
                    k = (u32)$8F1BBCDC;
                    }
                else
                    {
                    f = b ^ c ^ d;
                    k = (u32)$CA62C1D6;
                    }
                u32 t = Sha1.rol(a, (u32)5) + f + e + k + w[i];
                e = d;
                d = c;
                c = Sha1.rol(b, (u32)30);
                b = a;
                a = t;
                }
            h0 = h0 + a;
            h1 = h1 + b;
            h2 = h2 + c;
            h3 = h3 + d;
            h4 = h4 + e;
            }
        Array* out = new Array();
        Bytes.put32be(out, h0);
        Bytes.put32be(out, h1);
        Bytes.put32be(out, h2);
        Bytes.put32be(out, h3);
        Bytes.put32be(out, h4);
        return out;
        }
    }

    // ── HMAC / PBKDF2 over either hash ──────────────────────────────────────
    class Kdf
    {
    void init(void)
        {
        }
    static Array* hash(bool sha256, Array* m)
        {
        return sha256 ? Bytes.sha256(m) : Sha1.digest(m);
        }
    static Array* hmac(bool sha256, Array* key, Array* msg)
        {
        u32 bs = (u32)64;
        Array* k = Bytes.copy(key);
        if (k.count() > bs)
            k = Kdf.hash(sha256, k);
        while (k.count() < bs)
            Bytes.add(k, (u32)0);
        Array* inner = new Array();
        Array* outer = new Array();
        for (u32 i = (u32)0; i < bs; i = i + (u32)1)
            {
            Bytes.add(inner, Bytes.at(k, i) ^ (u32)$36);
            Bytes.add(outer, Bytes.at(k, i) ^ (u32)$5c);
            }
        apkAppend(inner, msg);
        apkAppend(outer, Kdf.hash(sha256, inner));
        return Kdf.hash(sha256, outer);
        }
    static Array* pbkdf2(bool sha256, Array* pw, Array* salt, u32 iters, u32 dkLen)
        {
        u32 hLen = sha256 ? (u32)32 : (u32)20;
        Array* dk = new Array();
        u32 block = (u32)1;
        while (dk.count() < dkLen)
            {
            Array* t = Bytes.copy(salt);
            Bytes.put32be(t, block);
            Array* u = Kdf.hmac(sha256, pw, t);
            Array* acc = Bytes.copy(u);
            for (u32 i = (u32)1; i < iters; i = i + (u32)1)
                {
                u = Kdf.hmac(sha256, pw, u);
                for (u32 j = (u32)0; j < hLen; j = j + (u32)1)
                    Bytes.put(acc, j, Bytes.at(acc, j) ^ Bytes.at(u, j));
                }
            apkAppend(dk, acc);
            block = block + (u32)1;
            }
        return Bytes.slice(dk, (u32)0, dkLen);
        }
    }

    // ── 3DES-EDE CBC (des-ede3-cbc), the PKCS#8 wrap macOS exports ──────────
    class Des
    {
    void init(void)
        {
        }
    static u32 ipTab(u32 i)
        {
        u32 t[64] = {58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7};
        return t[i];
        }
    static u32 fpTab(u32 i)
        {
        u32 t[64] = {40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25};
        return t[i];
        }
    static u32 eTab(u32 i)
        {
        u32 t[48] = {32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1};
        return t[i];
        }
    static u32 pTab(u32 i)
        {
        u32 t[32] = {16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25};
        return t[i];
        }
    static u32 pc1Tab(u32 i)
        {
        u32 t[56] = {57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4};
        return t[i];
        }
    static u32 pc2Tab(u32 i)
        {
        u32 t[48] = {14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2, 41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32};
        return t[i];
        }
    static u32 shiftTab(u32 i)
        {
        u32 t[16] = {1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1};
        return t[i];
        }
    static u32 sbox(u32 b, u32 i)
        {
        u32 s0[64] = {14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13};
        u32 s1[64] = {15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9};
        u32 s2[64] = {10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12};
        u32 s3[64] = {7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14};
        u32 s4[64] = {2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3};
        u32 s5[64] = {12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13};
        u32 s6[64] = {4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12};
        u32 s7[64] = {13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11};
        if (b == (u32)0)
            return s0[i];
        if (b == (u32)1)
            return s1[i];
        if (b == (u32)2)
            return s2[i];
        if (b == (u32)3)
            return s3[i];
        if (b == (u32)4)
            return s4[i];
        if (b == (u32)5)
            return s5[i];
        if (b == (u32)6)
            return s6[i];
        return s7[i];
        }
    // 64-bit values as (hi, lo) u32 pairs; a bit `n` (1-based from the left of an
    // inBits-wide value) is read with getBit.
    static u32 getBit(u32 hi, u32 lo, u32 n, u32 inBits)
        {
        u32 pos = inBits - n; // 0-based from the right
        if (pos >= (u32)32)
            return (hi >> (pos - (u32)32)) & (u32)1;
        return (lo >> pos) & (u32)1;
        }
    // permute into out[0]=hi, out[1]=lo
    static void permute(u32 hi, u32 lo, u32 which, u32 n, u32 inBits, u32* out)
        {
        u32 ohi = (u32)0;
        u32 olo = (u32)0;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u32 t;
            if (which == (u32)0)
                t = Des.ipTab(i);
            else if (which == (u32)1)
                t = Des.fpTab(i);
            else if (which == (u32)2)
                t = Des.eTab(i);
            else if (which == (u32)3)
                t = Des.pTab(i);
            else if (which == (u32)4)
                t = Des.pc1Tab(i);
            else
                t = Des.pc2Tab(i);
            u32 bit = Des.getBit(hi, lo, t, inBits);
            ohi = (ohi << (u32)1) | (olo >> (u32)31);
            olo = (olo << (u32)1) | bit;
            }
        out[0] = ohi;
        out[1] = olo;
        }
    // 16 round keys, each 48 bits as (hi, lo)
    static void keys(Array* k, u32 off, u32* rhi, u32* rlo)
        {
        u32 khi = (Bytes.at(k, off) << (u32)24) | (Bytes.at(k, off + (u32)1) << (u32)16) | (Bytes.at(k, off + (u32)2) << (u32)8) | Bytes.at(k, off + (u32)3);
        u32 klo = (Bytes.at(k, off + (u32)4) << (u32)24) | (Bytes.at(k, off + (u32)5) << (u32)16) | (Bytes.at(k, off + (u32)6) << (u32)8) | Bytes.at(k, off + (u32)7);
        u32 cd[2];
        Des.permute(khi, klo, (u32)4, (u32)56, (u32)64, cd);
        // cd is 56 bits: c = top 28, d = low 28
        u32 c = ((cd[0] << (u32)4) | (cd[1] >> (u32)28)) & (u32)$FFFFFFF;
        u32 d = cd[1] & (u32)$FFFFFFF;
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            u32 s = Des.shiftTab(i);
            c = ((c << s) | (c >> ((u32)28 - s))) & (u32)$FFFFFFF;
            d = ((d << s) | (d >> ((u32)28 - s))) & (u32)$FFFFFFF;
            // cdc = c<<28 | d (56 bits) as hi/lo of a 56-bit value: hi = top 24 bits, lo = low 32
            u32 hi = c >> (u32)4;
            u32 lo = (c << (u32)28) | d;
            u32 rk[2];
            Des.permute(hi, lo, (u32)5, (u32)48, (u32)56, rk);
            rhi[i] = rk[0];
            rlo[i] = rk[1];
            }
        }
    static void crypt(u32 bhi, u32 blo, u32* rhi, u32* rlo, bool decrypt, u32* out)
        {
        u32 ip[2];
        Des.permute(bhi, blo, (u32)0, (u32)64, (u32)64, ip);
        u32 l = ip[0];
        u32 r = ip[1];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            u32 ri = decrypt ? (u32)15 - i : i;
            u32 er[2];
            Des.permute((u32)0, r, (u32)2, (u32)48, (u32)32, er);
            u32 ehi = er[0] ^ rhi[ri];
            u32 elo = er[1] ^ rlo[ri];
            u32 o = (u32)0;
            for (u32 b = (u32)0; b < (u32)8; b = b + (u32)1)
                {
                u32 shift = (u32)42 - (u32)6 * b; // 48-bit value in (ehi:16 bits, elo:32)
                u32 six;
                if (shift >= (u32)32)
                    six = (ehi >> (shift - (u32)32)) & (u32)$3F;
                else if (shift > (u32)26)
                    six = ((ehi << ((u32)32 - shift)) | (elo >> shift)) & (u32)$3F;
                else
                    six = (elo >> shift) & (u32)$3F;
                u32 row = ((six & (u32)$20) >> (u32)4) | (six & (u32)1);
                u32 col = (six >> (u32)1) & (u32)$F;
                o = (o << (u32)4) | Des.sbox(b, row * (u32)16 + col);
                }
            u32 f[2];
            Des.permute((u32)0, o, (u32)3, (u32)32, (u32)32, f);
            u32 nl = r;
            r = l ^ f[1];
            l = nl;
            }
        Des.permute(r, l, (u32)1, (u32)64, (u32)64, out);
        }
    static Array* cbcDecrypt3(Array* key24, Array* iv, Array* ct)
        {
        if (key24.count() != (u32)24 || iv.count() != (u32)8 || (ct.count() % (u32)8) != (u32)0)
            return (Array*)0;
        u32 h1[16];
        u32 l1[16];
        u32 h2[16];
        u32 l2[16];
        u32 h3[16];
        u32 l3[16];
        Des.keys(key24, (u32)0, h1, l1);
        Des.keys(key24, (u32)8, h2, l2);
        Des.keys(key24, (u32)16, h3, l3);
        u32 phi = (Bytes.at(iv, (u32)0) << (u32)24) | (Bytes.at(iv, (u32)1) << (u32)16) | (Bytes.at(iv, (u32)2) << (u32)8) | Bytes.at(iv, (u32)3);
        u32 plo = (Bytes.at(iv, (u32)4) << (u32)24) | (Bytes.at(iv, (u32)5) << (u32)16) | (Bytes.at(iv, (u32)6) << (u32)8) | Bytes.at(iv, (u32)7);
        Array* out = new Array();
        for (u32 off = (u32)0; off < ct.count(); off = off + (u32)8)
            {
            u32 chi = (Bytes.at(ct, off) << (u32)24) | (Bytes.at(ct, off + (u32)1) << (u32)16) | (Bytes.at(ct, off + (u32)2) << (u32)8) | Bytes.at(ct, off + (u32)3);
            u32 clo = (Bytes.at(ct, off + (u32)4) << (u32)24) | (Bytes.at(ct, off + (u32)5) << (u32)16) | (Bytes.at(ct, off + (u32)6) << (u32)8) | Bytes.at(ct, off + (u32)7);
            u32 t[2];
            Des.crypt(chi, clo, h3, l3, true, t);
            Des.crypt(t[0], t[1], h2, l2, false, t);
            Des.crypt(t[0], t[1], h1, l1, true, t);
            u32 xhi = t[0] ^ phi;
            u32 xlo = t[1] ^ plo;
            phi = chi;
            plo = clo;
            Bytes.add(out, xhi >> (u32)24);
            Bytes.add(out, xhi >> (u32)16);
            Bytes.add(out, xhi >> (u32)8);
            Bytes.add(out, xhi);
            Bytes.add(out, xlo >> (u32)24);
            Bytes.add(out, xlo >> (u32)16);
            Bytes.add(out, xlo >> (u32)8);
            Bytes.add(out, xlo);
            }
        return out;
        }
    // EDE encrypt, E(k1) D(k2) E(k3), chained. `pt` is already padded to 8.
    static Array* cbcEncrypt3(Array* key24, Array* iv, Array* pt)
        {
        if (key24.count() != (u32)24 || iv.count() != (u32)8 || (pt.count() % (u32)8) != (u32)0)
            return (Array*)0;
        u32 h1[16];
        u32 l1[16];
        u32 h2[16];
        u32 l2[16];
        u32 h3[16];
        u32 l3[16];
        Des.keys(key24, (u32)0, h1, l1);
        Des.keys(key24, (u32)8, h2, l2);
        Des.keys(key24, (u32)16, h3, l3);
        u32 phi = (Bytes.at(iv, (u32)0) << (u32)24) | (Bytes.at(iv, (u32)1) << (u32)16) | (Bytes.at(iv, (u32)2) << (u32)8) | Bytes.at(iv, (u32)3);
        u32 plo = (Bytes.at(iv, (u32)4) << (u32)24) | (Bytes.at(iv, (u32)5) << (u32)16) | (Bytes.at(iv, (u32)6) << (u32)8) | Bytes.at(iv, (u32)7);
        Array* out = new Array();
        for (u32 off = (u32)0; off < pt.count(); off = off + (u32)8)
            {
            u32 bhi = (Bytes.at(pt, off) << (u32)24) | (Bytes.at(pt, off + (u32)1) << (u32)16) | (Bytes.at(pt, off + (u32)2) << (u32)8) | Bytes.at(pt, off + (u32)3);
            u32 blo = (Bytes.at(pt, off + (u32)4) << (u32)24) | (Bytes.at(pt, off + (u32)5) << (u32)16) | (Bytes.at(pt, off + (u32)6) << (u32)8) | Bytes.at(pt, off + (u32)7);
            u32 t[2];
            Des.crypt(bhi ^ phi, blo ^ plo, h1, l1, false, t);
            Des.crypt(t[0], t[1], h2, l2, true, t);
            Des.crypt(t[0], t[1], h3, l3, false, t);
            phi = t[0];
            plo = t[1];
            Bytes.add(out, phi >> (u32)24);
            Bytes.add(out, phi >> (u32)16);
            Bytes.add(out, phi >> (u32)8);
            Bytes.add(out, phi);
            Bytes.add(out, plo >> (u32)24);
            Bytes.add(out, plo >> (u32)16);
            Bytes.add(out, plo >> (u32)8);
            Bytes.add(out, plo);
            }
        return out;
        }
    }

    // ── DER: writer ─────────────────────────────────────────────────────────
    class Der
    {
    void init(void)
        {
        }
    static Array* tlv(u32 tag, Array* content)
        {
        return ApkSign.derTagged(tag, content);
        }
    static Array* integer(Array* mag)
        {
        return ApkSign.derInteger(mag);
        }
    static Array* integerU32(u32 v)
        {
        Array* be = new Array();
        Bytes.add(be, (u32)0);
        Bytes.add(be, (u32)0);
        Bytes.add(be, (u32)0);
        Bytes.add(be, (u32)0);
        Bytes.put32be(be, v);
        return Der.integer(be);
        }
    static Array* null(void)
        {
        return Der.tlv((u32)$05, new Array());
        }
    static Array* octetString(Array* b)
        {
        return Der.tlv((u32)$04, b);
        }
    static Array* oid(String* dotted)
        {
        Array* parts = dotted.splitOnByte((u8)'.');
        Array* content = new Array();
        u32 a1 = Der.dec((String*)parts.get((u32)0));
        u32 a2 = Der.dec((String*)parts.get((u32)1));
        Der.emitArc(content, (u32)40 * a1 + a2);
        for (u32 i = (u32)2; i < parts.count(); i = i + (u32)1)
            Der.emitArc(content, Der.dec((String*)parts.get(i)));
        return Der.tlv((u32)$06, content);
        }
    static u32 dec(String* s)
        {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            v = v * (u32)10 + (u32)(s.byteAt(i) - (u8)'0');
        return v;
        }
    static void emitArc(Array* content, u32 v)
        {
        u32 st[10];
        u32 n = (u32)0;
        st[n] = v & (u32)$7F;
        n = n + (u32)1;
        v = v >> (u32)7;
        while (v != (u32)0)
            {
            st[n] = (v & (u32)$7F) | (u32)$80;
            n = n + (u32)1;
            v = v >> (u32)7;
            }
        while (n > (u32)0)
            {
            n = n - (u32)1;
            Bytes.add(content, st[n]);
            }
        }
    static Array* stringOf(u32 tag, String* s)
        {
        return Der.tlv(tag, Bytes.fromString(s));
        }
    static Array* generalizedTime(String* s)
        {
        return Der.stringOf((u32)$18, s);
        }
    static Array* concat(Array* elems)
        {
        Array* o = new Array();
        for (u32 i = (u32)0; i < elems.count(); i = i + (u32)1)
            apkAppend(o, (Array*)elems.get(i));
        return o;
        }
    static Array* sequence(Array* elems)
        {
        return Der.tlv((u32)$30, Der.concat(elems));
        }
    static Array* setOf(Array* elems)
        {
        Array* sorted = new Array();
        for (u32 i = (u32)0; i < elems.count(); i = i + (u32)1)
            {
            Array* e = (Array*)elems.get(i);
            u32 at = sorted.count();
            for (u32 k = (u32)0; k < sorted.count(); k = k + (u32)1)
                if (Bytes.compare((Array*)sorted.get(k), e) > (i32)0)
                    {
                    at = k;
                    break;
                    }
            sorted.insert(at, (Object*)e);
            }
        return Der.tlv((u32)$31, Der.concat(sorted));
        }
    static Array* explicitTag(u32 n, Array* contentTLV)
        {
        return Der.tlv((u32)$A0 | n, contentTLV);
        }
    static Array* implicitTag(u32 n, bool constructed, Array* contentTLV)
        {
        u32 i = (u32)1;
        u32 l0 = Bytes.at(contentTLV, i);
        i = i + (u32)1;
        u32 vlen;
        if (l0 < (u32)$80)
            vlen = l0;
        else
            {
            u32 ln = l0 & (u32)$7F;
            vlen = (u32)0;
            for (u32 k = (u32)0; k < ln; k = k + (u32)1)
                {
                vlen = (vlen << (u32)8) | Bytes.at(contentTLV, i);
                i = i + (u32)1;
                }
            }
        Array* value = Bytes.slice(contentTLV, i, vlen);
        return Der.tlv((u32)$80 | n | (constructed ? (u32)$20 : (u32)0), value);
        }
    static Array* two(Array* a, Array* b)
        {
        Array* l = new Array();
        l.add((Object*)a);
        l.add((Object*)b);
        return l;
        }
    static Array* one(Array* a)
        {
        Array* l = new Array();
        l.add((Object*)a);
        return l;
        }
    }

    // ── DER: reader ─────────────────────────────────────────────────────────
    class DerReader
    {
    Array* _b;
    u32 _start;
    u32 _end;
    u32 _pos;
    u32 _lastTag;
    void init(void)
        {
        _pos = (u32)0;
        _lastTag = (u32)0;
        }
    static DerReader* over(Array* b, u32 start, u32 end)
        {
        DerReader* r = new DerReader();
        r._b = b;
        r._start = start;
        r._end = end;
        r._pos = start;
        return r;
        }
    static DerReader* of(Array* b)
        {
        return DerReader.over(b, (u32)0, b.count());
        }
    bool atEnd(void)
        {
        return _pos >= _end;
        }
    u32 lastTag(void)
        {
        return _lastTag;
        }
    // returns false when nothing parseable is here; else fills tag/valueOff/valueLen/next
    bool peek(u32* out)
        {
        u32 i = _pos;
        if (i >= _end)
            return false;
        u32 t = Bytes.at(_b, i);
        i = i + (u32)1;
        if (i >= _end)
            return false;
        u32 l0 = Bytes.at(_b, i);
        i = i + (u32)1;
        u32 vlen;
        if (l0 < (u32)$80)
            vlen = l0;
        else
            {
            u32 nb = l0 & (u32)$7F;
            if (nb == (u32)0 || nb > (u32)4 || i + nb > _end)
                return false;
            vlen = (u32)0;
            for (u32 k = (u32)0; k < nb; k = k + (u32)1)
                {
                vlen = (vlen << (u32)8) | Bytes.at(_b, i);
                i = i + (u32)1;
                }
            }
        if (i + vlen > _end)
            return false;
        out[0] = t;
        out[1] = i;
        out[2] = vlen;
        out[3] = i + vlen;
        return true;
        }
    u32 peekTag(void)
        {
        u32 p[4];
        if (!peek(p))
            return (u32)$FFFFFFFF;
        return p[0];
        }
    // the VALUE bytes; tag via lastTag()
    Array* readTLV(void)
        {
        u32 p[4];
        if (!peek(p))
            return (Array*)0;
        _pos = p[3];
        _lastTag = p[0];
        return Bytes.slice(_b, p[1], p[2]);
        }
    // the whole element (tag + length + value)
    Array* readElement(void)
        {
        u32 p[4];
        if (!peek(p))
            return (Array*)0;
        Array* whole = Bytes.slice(_b, _pos, p[3] - _pos);
        _pos = p[3];
        _lastTag = p[0];
        return whole;
        }
    DerReader* readConstructed(void)
        {
        u32 p[4];
        if (!peek(p))
            return (DerReader*)0;
        if ((p[0] & (u32)$20) == (u32)0)
            return (DerReader*)0;
        _pos = p[3];
        _lastTag = p[0];
        return DerReader.over(_b, p[1], p[3]);
        }
    // issuer Name (verbatim TLV) and serialNumber (value) of an X.509 cert
    static bool certificate(Array* certDer, Array** issuerOut, Array** serialOut)
        {
        DerReader* top = DerReader.of(certDer);
        DerReader* cert = top.readConstructed();
        if (cert == (DerReader*)0)
            return false;
        DerReader* tbs = cert.readConstructed();
        if (tbs == (DerReader*)0)
            return false;
        if (tbs.peekTag() == (u32)$A0)
            tbs.readElement(); // version
        Array* serial = tbs.readTLV();
        if (serial == (Array*)0 || tbs.lastTag() != (u32)$02)
            return false;
        tbs.readElement(); // signatureAlg
        Array* issuer = tbs.readElement();
        if (issuer == (Array*)0)
            return false;
        *serialOut = serial;
        *issuerOut = issuer;
        return true;
        }
    // subject organizationalUnit (2.5.4.11) — Apple's Team ID
    static String* teamId(Array* certDer)
        {
        DerReader* top = DerReader.of(certDer);
        DerReader* cert = top.readConstructed();
        if (cert == (DerReader*)0)
            return (String*)0;
        DerReader* tbs = cert.readConstructed();
        if (tbs == (DerReader*)0)
            return (String*)0;
        if (tbs.peekTag() == (u32)$A0)
            tbs.readElement();
        tbs.readTLV();
        tbs.readElement();
        tbs.readElement();
        tbs.readElement(); // serial, sigalg, issuer, validity
        DerReader* subject = tbs.readConstructed();
        if (subject == (DerReader*)0)
            return (String*)0;
        while (!subject.atEnd())
            {
            DerReader* rdn = subject.readConstructed();
            if (rdn == (DerReader*)0)
                break;
            while (!rdn.atEnd())
                {
                DerReader* atv = rdn.readConstructed();
                if (atv == (DerReader*)0)
                    break;
                Array* oid = atv.readTLV();
                Array* val = atv.readTLV();
                if (oid != (Array*)0 && val != (Array*)0 && oid.count() == (u32)3 && Bytes.at(oid, (u32)0) == (u32)$55 && Bytes.at(oid, (u32)1) == (u32)$04 && Bytes.at(oid, (u32)2) == (u32)$0b)
                    {
                    String* s = new String();
                    for (u32 i = (u32)0; i < val.count(); i = i + (u32)1)
                        s.appendByte((u8)Bytes.at(val, i));
                    return s;
                    }
                }
            }
        return (String*)0;
        }
    }

    // ── PEM / base64 ────────────────────────────────────────────────────────
    class PemBlock
    {
    String* _label;
    Array* _der;
    void init(void)
        {
        }
    String* label(void)
        {
        return _label;
        }
    Array* der(void)
        {
        return _der;
        }
    } class Pem
    {
    void init(void)
        {
        }
    static u32 b64val(u32 c)
        {
        if (c >= (u32)'A' && c <= (u32)'Z')
            return c - (u32)'A';
        if (c >= (u32)'a' && c <= (u32)'z')
            return c - (u32)'a' + (u32)26;
        if (c >= (u32)'0' && c <= (u32)'9')
            return c - (u32)'0' + (u32)52;
        if (c == (u32)'+')
            return (u32)62;
        if (c == (u32)'/')
            return (u32)63;
        return (u32)$FFFFFFFF;
        }
    static Array* base64Decode(String* s)
        {
        Array* out = new Array();
        u32 acc = (u32)0;
        u32 nbits = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u32 c = (u32)s.byteAt(i);
            if (c == (u32)'=')
                break;
            u32 v = Pem.b64val(c);
            if (v == (u32)$FFFFFFFF)
                continue; // whitespace and the like
            acc = (acc << (u32)6) | v;
            nbits = nbits + (u32)6;
            if (nbits >= (u32)8)
                {
                nbits = nbits - (u32)8;
                Bytes.add(out, (acc >> nbits) & (u32)$FF);
                }
            }
        return out;
        }
    // Standard base64 (A-Za-z0-9+/, '=' padded). Deterministic, so it matches
    // NSData's encoder byte for byte — used for the CodeResources hashes.
    static String* base64Encode(Array* bytes)
        {
        String* A = String.withCString("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
        String* out = String.withCString("");
        u32 n = bytes.count();
        u32 i = (u32)0;
        while (i + (u32)3 <= n)
            {
            u32 v = (Bytes.at(bytes, i) << (u32)16) | (Bytes.at(bytes, i + (u32)1) << (u32)8) | Bytes.at(bytes, i + (u32)2);
            out.appendByte(A.byteAt((v >> (u32)18) & (u32)63));
            out.appendByte(A.byteAt((v >> (u32)12) & (u32)63));
            out.appendByte(A.byteAt((v >> (u32)6) & (u32)63));
            out.appendByte(A.byteAt(v & (u32)63));
            i = i + (u32)3;
            }
        u32 rem = n - i;
        if (rem == (u32)1)
            {
            u32 v = Bytes.at(bytes, i) << (u32)16;
            out.appendByte(A.byteAt((v >> (u32)18) & (u32)63));
            out.appendByte(A.byteAt((v >> (u32)12) & (u32)63));
            out.appendByte((u8)'=');
            out.appendByte((u8)'=');
            }
        else if (rem == (u32)2)
            {
            u32 v = (Bytes.at(bytes, i) << (u32)16) | (Bytes.at(bytes, i + (u32)1) << (u32)8);
            out.appendByte(A.byteAt((v >> (u32)18) & (u32)63));
            out.appendByte(A.byteAt((v >> (u32)12) & (u32)63));
            out.appendByte(A.byteAt((v >> (u32)6) & (u32)63));
            out.appendByte((u8)'=');
            }
        return out;
        }
    // base64 in 64-column lines joined by CR LF — NSData's
    // NSDataBase64Encoding64CharacterLineLength with no line-ending option,
    // which is what the identity bundles have always been written with.
    static String* base64Lines(Array* bytes)
        {
        String* flat = Pem.base64Encode(bytes);
        String* out = String.withCString("");
        u32 n = flat.byteLength();
        for (u32 i = (u32)0; i < n; i = i + (u32)64)
            {
            if (i > (u32)0)
                out.appendCString("\r\n");
            u32 len = n - i < (u32)64 ? n - i : (u32)64;
            out.append(flat.substringBytes(i, len));
            }
        return out;
        }
    // One PEM block: -----BEGIN L-----\n<base64 lines>\n-----END L-----\n
    static String* block(String* label, Array* der)
        {
        String* s = String.withCString("-----BEGIN ");
        s.append(label);
        s.appendCString("-----\n");
        s.append(Pem.base64Lines(der));
        s.appendCString("\n-----END ");
        s.append(label);
        s.appendCString("-----\n");
        return s;
        }
    static Array* blocks(String* text)
        {
        Array* out = new Array();
        String* BEGIN = String.withCString("-----BEGIN ");
        u32 pos = (u32)0;
        while (true)
            {
            u32 b = text.byteIndexOf(BEGIN, pos);
            if (b == String.notFound())
                break;
            u32 ls = b + BEGIN.byteLength();
            u32 le = text.byteIndexOf(String.withCString("-----"), ls);
            if (le == String.notFound())
                break;
            String* label = text.substringBytes(ls, le - ls);
            String* endMarker = String.withCString("-----END ");
            endMarker.append(label);
            endMarker.appendCString("-----");
            u32 bodyStart = le + (u32)5;
            u32 e = text.byteIndexOf(endMarker, bodyStart);
            if (e == String.notFound())
                break;
            PemBlock* blk = new PemBlock();
            blk._label = label;
            blk._der = Pem.base64Decode(text.substringBytes(bodyStart, e - bodyStart));
            out.add((Object*)blk);
            pos = e + endMarker.byteLength();
            }
        return out;
        }
    }

    // ── PKCS#8: EncryptedPrivateKeyInfo (PBES2 / PBKDF2 / des-ede3-cbc) ──────
    // ── CodeResources sealer (docs/ios/bundle-signing.md, gate 1/3) ──────────
    // Byte-identical to Apple codesign's _CodeSignature/CodeResources. The caller
    // (which has Files) passes parallel arrays: `names` (String* relative paths)
    // and `contents` (Array* raw bytes). rules/rules2 are the constant default set,
    // embedded verbatim from the golden; only files/files2 are dynamic. Keys are
    // emitted ascending by byte value, matching CoreFoundation's plist writer.
    class CodeRes
    {
    void init(void)
        {
        }
    static bool omit2(String* n)
        {
        if (n.equals(String.withCString("Info.plist")))
            return true;
        if (n.equals(String.withCString("PkgInfo")))
            return true;
        u32 L = n.byteLength();
        if (L >= (u32)9 && n.substringBytes(L - (u32)9, (u32)9).equals(String.withCString(".DS_Store")))
            return true;
        return false;
        }
    static i32 nameCmp(String* a, String* b)
        {
        u32 la = a.byteLength();
        u32 lb = b.byteLength();
        u32 m = la < lb ? la : lb;
        for (u32 i = (u32)0; i < m; i = i + (u32)1)
            {
            u32 x = (u32)a.byteAt(i);
            u32 y = (u32)b.byteAt(i);
            if (x < y)
                return (i32)-1;
            if (x > y)
                return (i32)1;
            }
        if (la < lb)
            return (i32)-1;
        if (la > lb)
            return (i32)1;
        return (i32)0;
        }
    static String* build(Array* names, Array* contents)
        {
        Array* idx = new Array();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            idx.add((Object*)Number.withU32(i));
        for (u32 i = (u32)1; i < idx.count(); i = i + (u32)1)
            {
            Object* k = idx.get(i);
            u32 kv = ((Number*)k).asU32();
            u32 j = i;
            while (j > (u32)0 && CodeRes.nameCmp((String*)names.get(((Number*)idx.get(j - (u32)1)).asU32()), (String*)names.get(kv)) > (i32)0)
                {
                idx.set(j, idx.get(j - (u32)1));
                j = j - (u32)1;
                }
            idx.set(j, k);
            }
        String* out = String.withCString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n");
        out.appendCString("\t<key>files</key>\n\t<dict>\n");
        for (u32 t = (u32)0; t < idx.count(); t = t + (u32)1)
            {
            u32 i = ((Number*)idx.get(t)).asU32();
            String* nm = (String*)names.get(i);
            Array* by = (Array*)contents.get(i);
            String* h = Pem.base64Encode(Sha1.digest(by));
            out.appendCString("\t\t<key>");
            out.append(nm);
            out.appendCString("</key>\n\t\t<data>\n\t\t");
            out.append(h);
            out.appendCString("\n\t\t</data>\n");
            }
        out.appendCString("\t</dict>\n\t<key>files2</key>\n\t<dict>\n");
        for (u32 t = (u32)0; t < idx.count(); t = t + (u32)1)
            {
            u32 i = ((Number*)idx.get(t)).asU32();
            String* nm = (String*)names.get(i);
            if (CodeRes.omit2(nm))
                continue;
            Array* by = (Array*)contents.get(i);
            String* h = Pem.base64Encode(Bytes.sha256(by));
            out.appendCString("\t\t<key>");
            out.append(nm);
            out.appendCString("</key>\n\t\t<dict>\n\t\t\t<key>hash2</key>\n\t\t\t<data>\n\t\t\t");
            out.append(h);
            out.appendCString("\n\t\t\t</data>\n\t\t</dict>\n");
            }
        out.appendCString("\t</dict>\n");
        out.appendCString("\t<key>rules</key>\n\t<dict>\n\t\t<key>^.*</key>\n\t\t<true/>\n\t\t<key>^.*\\.lproj/</key>\n\t\t<dict>\n\t\t\t<key>optional</key>\n\t\t\t<true/>\n\t\t\t<key>weight</key>\n\t\t\t<real>1000</real>\n\t\t</dict>\n\t\t<key>^.*\\.lproj/locversion.plist$</key>\n\t\t<dict>\n\t\t\t<key>omit</key>\n\t\t\t<true/>\n\t\t\t<key>weight</key>\n\t\t\t<real>1100</real>\n\t\t</dict>\n\t\t<key>^Base\\.lproj/</key>\n\t\t<dict>\n\t\t\t<key>weight</key>\n\t\t\t<real>1010</real>\n\t\t</dict>\n\t\t<key>^version.plist$</key>\n\t\t<true/>\n\t</dict>\n\t<key>rules2</key>\n\t<dict>\n\t\t<key>.*\\.dSYM($|/)</key>\n\t\t<dict>\n\t\t\t<key>weight</key>\n\t\t\t<real>11</real>\n\t\t</dict>\n\t\t<key>^(.*/)?\\.DS_Store$</key>\n\t\t<dict>\n\t\t\t<key>omit</key>\n\t\t\t<true/>\n\t\t\t<key>weight</key>\n\t\t\t<real>2000</real>\n\t\t</dict>\n\t\t<key>^.*</key>\n\t\t<true/>\n\t\t<key>^.*\\.lproj/</key>\n\t\t<dict>\n\t\t\t<key>optional</key>\n\t\t\t<true/>\n\t\t\t<key>weight</key>\n\t\t\t<real>1000</real>\n\t\t</dict>\n\t\t<key>^.*\\.lproj/locversion.plist$</key>\n\t\t<dict>\n\t\t\t<key>omit</key>\n\t\t\t<true/>\n\t\t\t<key>weight</key>\n\t\t\t<real>1100</real>\n\t\t</dict>\n\t\t<key>^Base\\.lproj/</key>\n\t\t<dict>\n\t\t\t<key>weight</key>\n\t\t\t<real>1010</real>\n\t\t</dict>\n\t\t<key>^Info\\.plist$</key>\n\t\t<dict>\n\t\t\t<key>omit</key>\n\t\t\t<true/>\n\t\t\t<key>weight</key>\n\t\t\t<real>20</real>\n\t\t</dict>\n\t\t<key>^PkgInfo$</key>\n\t\t<dict>\n\t\t\t<key>omit</key>\n\t\t\t<true/>\n\t\t\t<key>weight</key>\n\t\t\t<real>20</real>\n\t\t</dict>\n\t\t<key>^embedded\\.provisionprofile$</key>\n\t\t<dict>\n\t\t\t<key>weight</key>\n\t\t\t<real>20</real>\n\t\t</dict>\n\t\t<key>^version\\.plist$</key>\n\t\t<dict>\n\t\t\t<key>weight</key>\n\t\t\t<real>20</real>\n\t\t</dict>\n\t</dict>\n");
        out.appendCString("</dict>\n</plist>\n");
        return out;
        }
    }

    class Pkcs8
    {
    String* _why;
    void init(void)
        {
        }
    String* why(void)
        {
        return _why;
        }
    Array* fail(string m)
        {
        _why = String.withCString(m);
        return (Array*)0;
        }
    static bool oidIs(Array* got, u32* want, u32 n)
        {
        if (got == (Array*)0 || got.count() != n)
            return false;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            if (Bytes.at(got, i) != want[i])
                return false;
        return true;
        }
    Array* decrypt(Array* der, String* passphrase)
        {
        DerReader* top = DerReader.of(der);
        DerReader* epki = top.readConstructed();
        if (epki == (DerReader*)0)
            return fail("not EncryptedPrivateKeyInfo");
        DerReader* alg = epki.readConstructed();
        if (alg == (DerReader*)0)
            return fail("no encryptionAlgorithm");
        Array* algOid = alg.readTLV();
        if (algOid == (Array*)0 || alg.lastTag() != (u32)$06)
            return fail("no alg OID");
        u32 pbes2[9] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d};
        if (!Pkcs8.oidIs(algOid, pbes2, (u32)9))
            return fail("only PBES2 is supported");
        DerReader* params = alg.readConstructed();
        if (params == (DerReader*)0)
            return fail("no PBES2 params");
        DerReader* kdf = params.readConstructed();
        if (kdf == (DerReader*)0)
            return fail("no KDF");
        Array* kdfOid = kdf.readTLV();
        u32 pbkdf2[9] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c};
        if (!Pkcs8.oidIs(kdfOid, pbkdf2, (u32)9))
            return fail("only PBKDF2 key derivation is supported");
        DerReader* kdfp = kdf.readConstructed();
        if (kdfp == (DerReader*)0)
            return fail("no PBKDF2 params");
        Array* salt = kdfp.readTLV();
        if (salt == (Array*)0 || kdfp.lastTag() != (u32)$04)
            return fail("bad PBKDF2 salt");
        Array* iterData = kdfp.readTLV();
        if (iterData == (Array*)0 || kdfp.lastTag() != (u32)$02)
            return fail("bad PBKDF2 iterations");
        u32 iters = (u32)0;
        for (u32 i = (u32)0; i < iterData.count(); i = i + (u32)1)
            iters = (iters << (u32)8) | Bytes.at(iterData, i);
        bool prfSha256 = false;
        if (kdfp.peekTag() == (u32)$30)
            {
            DerReader* prf = kdfp.readConstructed();
            Array* prfOid = prf.readTLV();
            u32 hmacSha256[8] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09};
            if (Pkcs8.oidIs(prfOid, hmacSha256, (u32)8))
                prfSha256 = true;
            }
        DerReader* enc = params.readConstructed();
        if (enc == (DerReader*)0)
            return fail("no encryption scheme");
        Array* cipherOid = enc.readTLV();
        Array* iv = enc.readTLV();
        if (iv == (Array*)0 || enc.lastTag() != (u32)$04)
            return fail("bad cipher IV");
        u32 des3[8] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x03, 0x07};
        if (!Pkcs8.oidIs(cipherOid, des3, (u32)8))
            return fail("only des-ede3-cbc is supported");
        Array* ct = epki.readTLV();
        if (ct == (Array*)0 || epki.lastTag() != (u32)$04)
            return fail("no encryptedData");
        Array* dk = Kdf.pbkdf2(prfSha256, Bytes.fromString(passphrase), salt, iters, (u32)24);
        Array* plain = Des.cbcDecrypt3(dk, iv, ct);
        if (plain == (Array*)0 || plain.count() == (u32)0)
            return fail("decryption failed");
        u32 pad = Bytes.at(plain, plain.count() - (u32)1);
        if (pad == (u32)0 || pad > (u32)8 || pad > plain.count())
            return fail("bad passphrase (padding)");
        for (u32 i = plain.count() - pad; i < plain.count(); i = i + (u32)1)
            if (Bytes.at(plain, i) != pad)
                return fail("bad passphrase (padding)");
        return Bytes.slice(plain, (u32)0, plain.count() - pad);
        }
    // The inverse: wrap `keyDer` as an EncryptedPrivateKeyInfo under PBES2
    // (PBKDF2-HMAC-SHA1, 2048 rounds, des-ede3-cbc) — the form macOS exports,
    // so `decrypt` reads both. The caller supplies 8 bytes each of salt and IV
    // from the OS; this class has no entropy of its own.
    static Array* encrypt(Array* keyDer, String* passphrase, Array* salt, Array* iv)
        {
        u32 iters = (u32)2048;
        Array* dk = Kdf.pbkdf2(false, Bytes.fromString(passphrase), salt, iters, (u32)24);
        Array* padded = Bytes.copy(keyDer);
        u32 pad = (u32)8 - (keyDer.count() % (u32)8);
        for (u32 i = (u32)0; i < pad; i = i + (u32)1)
            Bytes.add(padded, pad);
        Array* ct = Des.cbcEncrypt3(dk, iv, padded);
        if (ct == (Array*)0)
            return (Array*)0;
        Array* kdf = Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.5.12")),
                                          Der.sequence(Der.two(Der.octetString(salt), Der.integerU32(iters)))));
        Array* enc = Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.3.7")),
                                          Der.octetString(iv)));
        Array* algid = Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.5.13")),
                                            Der.sequence(Der.two(kdf, enc))));
        return Der.sequence(Der.two(algid, Der.octetString(ct)));
        }
    }

    // ── the identity bundle ─────────────────────────────────────────────────
    class Identity
    {
    Array* _leaf;  // leaf certificate DER
    Array* _chain; // Array@ of DER
    Array* _modulus;
    Array* _privExp;
    Array* _entitlements; // XML bytes or nil
    String* _why;
    void init(void)
        {
        _chain = new Array();
        }
    Array* leaf(void)
        {
        return _leaf;
        }
    Array* chain(void)
        {
        return _chain;
        }
    Array* modulus(void)
        {
        return _modulus;
        }
    Array* privateExponent(void)
        {
        return _privExp;
        }
    Array* entitlements(void)
        {
        return _entitlements;
        }
    String* why(void)
        {
        return _why;
        }

    // RSAPrivateKey (PKCS#1) or PrivateKeyInfo (PKCS#8) wrapping one
    static bool rsaKey(Array* der, Array** nOut, Array** dOut)
        {
        DerReader* top = DerReader.of(der);
        DerReader* seq = top.readConstructed();
        if (seq == (DerReader*)0)
            return false;
        Array* first = seq.readTLV();
        if (first == (Array*)0 || seq.lastTag() != (u32)$02)
            return false;
        u32 nt = seq.peekTag();
        if (nt == (u32)$30)
            {
            seq.readElement(); // algorithm
            Array* inner = seq.readTLV();
            if (inner == (Array*)0 || seq.lastTag() != (u32)$04)
                return false;
            return Identity.rsaKey(inner, nOut, dOut);
            }
        Array* n = seq.readTLV();
        if (n == (Array*)0 || seq.lastTag() != (u32)$02)
            return false;
        seq.readTLV(); // e
        Array* d = seq.readTLV();
        if (d == (Array*)0 || seq.lastTag() != (u32)$02)
            return false;
        *nOut = n;
        *dOut = d;
        return true;
        }
    static Identity* fromPEM(String* text, String* passphrase)
        {
        Identity* id = new Identity();
        Array* blocks = Pem.blocks(text);
        Array* certs = new Array();
        Array* keyDer = (Array*)0;
        bool keyEncrypted = false;
        for (u32 i = (u32)0; i < blocks.count(); i = i + (u32)1)
            {
            PemBlock* b = (PemBlock*)blocks.get(i);
            if (b.label().equals(String.withCString("CERTIFICATE")))
                certs.add((Object*)b.der());
            else if (b.label().equals(String.withCString("ENCRYPTED PRIVATE KEY")))
                {
                keyDer = b.der();
                keyEncrypted = true;
                }
            else if (b.label().hasSuffix(String.withCString("PRIVATE KEY")))
                keyDer = b.der();
            else if (b.label().equals(String.withCString("XCC ENTITLEMENTS")))
                id._entitlements = b.der();
            }
        if (certs.count() == (u32)0)
            {
            id._why = String.withCString("no CERTIFICATE in the identity bundle");
            return id;
            }
        if (keyDer == (Array*)0)
            {
            id._why = String.withCString("no PRIVATE KEY in the identity bundle");
            return id;
            }
        if (keyEncrypted)
            {
            if (passphrase == (String*)0)
                {
                id._why = String.withCString("the key is encrypted — a passphrase is required");
                return id;
                }
            Pkcs8* p8 = new Pkcs8();
            Array* plain = p8.decrypt(keyDer, passphrase);
            if (plain == (Array*)0)
                {
                id._why = p8.why();
                return id;
                }
            keyDer = plain;
            }
        Array* n = (Array*)0;
        Array* d = (Array*)0;
        if (!Identity.rsaKey(keyDer, &n, &d))
            {
            id._why = String.withCString("private key is not a parseable RSA key");
            return id;
            }
        id._leaf = (Array*)certs.get((u32)0);
        for (u32 i = (u32)1; i < certs.count(); i = i + (u32)1)
            id._chain.add(certs.get(i));
        id._modulus = n;
        id._privExp = d;
        return id;
        }
    // The bundle `fromPEM` reads: the leaf, its chain, the key block under
    // `keyLabel`, and the entitlements XML when there is one.
    static String* pemBundle(Array* leaf, Array* chain, Array* keyBlock, String* keyLabel, Array* entitlementsXml)
        {
        String* s = Pem.block(String.withCString("CERTIFICATE"), leaf);
        for (u32 i = (u32)0; i < chain.count(); i = i + (u32)1)
            s.append(Pem.block(String.withCString("CERTIFICATE"), (Array*)chain.get(i)));
        s.append(Pem.block(keyLabel, keyBlock));
        if (entitlementsXml != (Array*)0)
            s.append(Pem.block(String.withCString("XCC ENTITLEMENTS"), entitlementsXml));
        return s;
        }
    }

    // ── RSA PKCS#1 v1.5 + CMS SignedData ────────────────────────────────────
    class Cms
    {
    void init(void)
        {
        }
    static Array* rsaSignPKCS1(Array* digestInfo, Array* modulus, Array* privExp)
        {
        u32 s = (u32)0;
        while (s < modulus.count() && Bytes.at(modulus, s) == (u32)0)
            s = s + (u32)1;
        Array* mod = Bytes.slice(modulus, s, modulus.count() - s);
        u32 mlen = mod.count();
        if (mlen < digestInfo.count() + (u32)11)
            return (Array*)0;
        Array* em = new Array();
        Bytes.add(em, (u32)0);
        Bytes.add(em, (u32)1);
        u32 psLen = mlen - digestInfo.count() - (u32)3;
        for (u32 i = (u32)0; i < psLen; i = i + (u32)1)
            Bytes.add(em, (u32)$FF);
        Bytes.add(em, (u32)0);
        apkAppend(em, digestInfo);
        Bignum* m = Bignum.fromBytes(em);
        Bignum* d = Bignum.fromBytes(privExp);
        Bignum* n = Bignum.fromBytes(mod);
        Bignum* sig = Bignum.modexp(m, d, n);
        return sig.toBytes(mlen);
        }
    static Array* sha256DigestInfo(Array* digest)
        {
        Array* algo = Der.sequence(Der.two(Der.oid(String.withCString("2.16.840.1.101.3.4.2.1")), Der.null()));
        return Der.sequence(Der.two(algo, Der.octetString(digest)));
        }
    // A detached SignedData over the CodeDirectory hash, one RSA/SHA-256 signer.
    static Array* signedData(Array* cdHash, Array* leaf, Array* chain, Array* modulus, Array* privExp, String* signingTime)
        {
        Array* issuer = (Array*)0;
        Array* serial = (Array*)0;
        if (!DerReader.certificate(leaf, &issuer, &serial))
            return (Array*)0;
        String* oidData = String.withCString("1.2.840.113549.1.7.1");
        Array* attrContentType = Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.9.3")), Der.setOf(Der.one(Der.oid(oidData)))));
        Array* attrMsgDigest = Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.9.4")), Der.setOf(Der.one(Der.octetString(cdHash)))));
        Array* attrSigningTime = Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.9.5")), Der.setOf(Der.one(Der.generalizedTime(signingTime)))));
        Array* attrs = new Array();
        attrs.add((Object*)attrContentType);
        attrs.add((Object*)attrMsgDigest);
        attrs.add((Object*)attrSigningTime);
        Array* attrsForSigning = Der.setOf(attrs);
        Array* signature = Cms.rsaSignPKCS1(Cms.sha256DigestInfo(Bytes.sha256(attrsForSigning)), modulus, privExp);
        if (signature == (Array*)0)
            return (Array*)0;
        Array* signedAttrsImplicit = Der.implicitTag((u32)0, true, attrsForSigning);
        Array* sid = Der.sequence(Der.two(issuer, Der.tlv((u32)$02, serial)));
        Array* digAlg = Der.sequence(Der.two(Der.oid(String.withCString("2.16.840.1.101.3.4.2.1")), Der.null()));
        Array* sigAlg = Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.1.1")), Der.null()));
        Array* si = new Array();
        si.add((Object*)Der.integerU32((u32)1));
        si.add((Object*)sid);
        si.add((Object*)digAlg);
        si.add((Object*)signedAttrsImplicit);
        si.add((Object*)sigAlg);
        si.add((Object*)Der.octetString(signature));
        Array* signerInfo = Der.sequence(si);
        Array* certs = new Array();
        certs.add((Object*)leaf);
        for (u32 i = (u32)0; i < chain.count(); i = i + (u32)1)
            certs.add(chain.get(i));
        Array* certSet = Der.implicitTag((u32)0, true, Der.sequence(certs));
        Array* digAlgs = Der.setOf(Der.one(Der.sequence(Der.two(Der.oid(String.withCString("2.16.840.1.101.3.4.2.1")), Der.null()))));
        Array* encap = Der.sequence(Der.one(Der.oid(oidData)));
        Array* sd = new Array();
        sd.add((Object*)Der.integerU32((u32)1));
        sd.add((Object*)digAlgs);
        sd.add((Object*)encap);
        sd.add((Object*)certSet);
        sd.add((Object*)Der.setOf(Der.one(signerInfo)));
        Array* signedData = Der.sequence(sd);
        return Der.sequence(Der.two(Der.oid(String.withCString("1.2.840.113549.1.7.2")), Der.explicitTag((u32)0, signedData)));
        }
    }

    // ── the Mach-O re-splice ─────────────────────────────────────────────────
    // ── DER entitlements (CD slot 7) ────────────────────────────────────────
    // iOS installd requires the entitlements DER-encoded in slot 7 (macOS
    // codesign --verify does not). Minimal flat-dict plist parser (key -> string
    // or bool) + the encoder codesign uses: APPLICATION-16 { INTEGER v=1,
    // CONTEXT-16 { SEQUENCE{key,val}... } }, keys sorted ascending. Byte-identical
    // to Apple's blob (tests/ios/bundle-golden/der-entitlements.golden).
    class DerEnt
    {
    void init(void)
        {
        }
    static Array* utf8(String* s)
        {
        return Der.stringOf((u32)$0c, s);
        }
    static Array* boolean(bool v)
        {
        Array* b = new Array();
        Bytes.add(b, v ? (u32)$FF : (u32)0);
        return Der.tlv((u32)$01, b);
        }
    static bool startsAt(String* s, u32 at, String* lit)
        {
        if (at + lit.byteLength() > s.byteLength())
            return false;
        for (u32 i = (u32)0; i < lit.byteLength(); i = i + (u32)1)
            if (s.byteAt(at + i) != lit.byteAt(i))
                return false;
        return true;
        }
    static u32 skipWs(String* s, u32 p)
        {
        while (p < s.byteLength())
            {
            u32 c = (u32)s.byteAt(p);
            if (c == (u32)32 || c == (u32)10 || c == (u32)9 || c == (u32)13)
                p = p + (u32)1;
            else
                break;
            }
        return p;
        }
    // Parse ONE plist value starting at/after `vp`; return its DER (0 if a type
    // is unsupported), and write the position just past the value into end[0].
    // string -> UTF8String, <true/>/<false/> -> BOOLEAN, <array> -> SEQUENCE of
    // its elements in order (recursive).
    static Array* parseValue(String* xml, u32 vp, Array* end)
        {
        vp = DerEnt.skipWs(xml, vp);
        if (DerEnt.startsAt(xml, vp, String.withCString("<string>")))
            {
            u32 vs = vp + (u32)8;
            u32 ve = xml.byteIndexOf(String.withCString("</string>"), vs);
            if (ve == String.notFound())
                return (Array*)0;
            end.set((u32)0, (Object*)Number.withU32(ve + (u32)9));
            return DerEnt.utf8(xml.substringBytes(vs, ve - vs));
            }
        if (DerEnt.startsAt(xml, vp, String.withCString("<true/>")))
            {
            end.set((u32)0, (Object*)Number.withU32(vp + (u32)7));
            return DerEnt.boolean(true);
            }
        if (DerEnt.startsAt(xml, vp, String.withCString("<false/>")))
            {
            end.set((u32)0, (Object*)Number.withU32(vp + (u32)8));
            return DerEnt.boolean(false);
            }
        if (DerEnt.startsAt(xml, vp, String.withCString("<array>")))
            {
            u32 p = vp + (u32)7;
            Array* content = new Array();
            while (true)
                {
                p = DerEnt.skipWs(xml, p);
                if (DerEnt.startsAt(xml, p, String.withCString("</array>")))
                    {
                    p = p + (u32)8;
                    break;
                    }
                if (p >= xml.byteLength())
                    return (Array*)0;
                Array* ed = DerEnt.parseValue(xml, p, end);
                if (ed == (Array*)0)
                    return (Array*)0;
                p = ((Number*)end.get((u32)0)).asU32();
                apkAppend(content, ed);
                }
            end.set((u32)0, (Object*)Number.withU32(p));
            return Der.tlv((u32)$30, content); // SEQUENCE
            }
        return (Array*)0;
        }
    // Build the slot-7 DER from entitlements XML bytes; 0 if a value type is unsupported.
    static Array* build(Array* xmlBytes)
        {
        String* xml = String.withCString("");
        for (u32 i = (u32)0; i < xmlBytes.count(); i = i + (u32)1)
            xml.appendByte((u8)Bytes.at(xmlBytes, i));
        Array* keys = new Array();
        Array* vals = new Array();
        String* KEYO = String.withCString("<key>");
        String* KEYC = String.withCString("</key>");
        Array* end = new Array();
        end.add((Object*)Number.withU32((u32)0));
        u32 pos = (u32)0;
        while (true)
            {
            u32 k0 = xml.byteIndexOf(KEYO, pos);
            if (k0 == String.notFound())
                break;
            u32 ks = k0 + KEYO.byteLength();
            u32 ke = xml.byteIndexOf(KEYC, ks);
            if (ke == String.notFound())
                break;
            String* key = xml.substringBytes(ks, ke - ks);
            Array* vd = DerEnt.parseValue(xml, ke + KEYC.byteLength(), end);
            if (vd == (Array*)0)
                return (Array*)0;
            pos = ((Number*)end.get((u32)0)).asU32();
            keys.add((Object*)key);
            vals.add((Object*)vd);
            }
        // sort indices by key ascending (byte order)
        Array* idx = new Array();
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            idx.add((Object*)Number.withU32(i));
        for (u32 i = (u32)1; i < idx.count(); i = i + (u32)1)
            {
            Object* kk = idx.get(i);
            u32 kv = ((Number*)kk).asU32();
            u32 j = i;
            while (j > (u32)0 && CodeRes.nameCmp((String*)keys.get(((Number*)idx.get(j - (u32)1)).asU32()), (String*)keys.get(kv)) > (i32)0)
                {
                idx.set(j, idx.get(j - (u32)1));
                j = j - (u32)1;
                }
            idx.set(j, kk);
            }
        Array* pairs = new Array();
        for (u32 t = (u32)0; t < idx.count(); t = t + (u32)1)
            {
            u32 i = ((Number*)idx.get(t)).asU32();
            Array* kv = new Array();
            apkAppend(kv, DerEnt.utf8((String*)keys.get(i)));
            apkAppend(kv, (Array*)vals.get(i));
            pairs.add((Object*)Der.tlv((u32)$30, kv));
            }
        Array* pairsContent = Der.concat(pairs);
        Array* ctx = Der.tlv((u32)$B0, pairsContent);
        Array* inner = new Array();
        apkAppend(inner, Der.integerU32((u32)1));
        apkAppend(inner, ctx);
        return Der.tlv((u32)$70, inner);
        }
    }

    class CodeSign
    {
    String* _why;
    void init(void)
        {
        }
    String* why(void)
        {
        return _why;
        }
    Array* fail(string m)
        {
        _why = String.withCString(m);
        return (Array*)0;
        }

    static Array* wrapBlob(u32 magic, Array* body)
        {
        Array* d = new Array();
        Bytes.put32be(d, magic);
        Bytes.put32be(d, (u32)8 + body.count());
        apkAppend(d, body);
        return d;
        }

    // CodeDirectory v0x20400. `specialSlots`/`specialHashes` are parallel arrays.
    static Array* codeDirectory(String* ident, u32 codeLimit, u32 nCodeSlots, u32 execSegLimit,
                                Array* specialSlots, Array* specialHashes, Array* codeHashes, String* teamId)
        {
        u32 hashSize = (u32)32;
        u32 idLen = ident.byteLength();
        u32 teamLen = teamId == (String*)0 ? (u32)0 : teamId.byteLength();
        bool team = teamId != (String*)0 && teamLen > (u32)0;
        u32 nSpecial = (u32)0;
        for (u32 i = (u32)0; i < specialSlots.count(); i = i + (u32)1)
            {
            u32 s = Bytes.at(specialSlots, i);
            if (s > nSpecial)
                nSpecial = s;
            }
        u32 hdr = (u32)88;
        u32 identOffset = hdr;
        u32 teamOffset = team ? identOffset + idLen + (u32)1 : (u32)0;
        u32 afterStrings = identOffset + idLen + (u32)1 + (team ? teamLen + (u32)1 : (u32)0);
        u32 hashOffset = afterStrings + nSpecial * hashSize;
        u32 cdLength = hashOffset + nCodeSlots * hashSize;
        Array* cd = new Array();
        Bytes.put32be(cd, (u32)$fade0c02);
        Bytes.put32be(cd, cdLength);
        Bytes.put32be(cd, (u32)$20400);
        Bytes.put32be(cd, (u32)0); // flags
        Bytes.put32be(cd, hashOffset);
        Bytes.put32be(cd, identOffset);
        Bytes.put32be(cd, nSpecial);
        Bytes.put32be(cd, nCodeSlots);
        Bytes.put32be(cd, codeLimit);
        Bytes.add(cd, hashSize);
        Bytes.add(cd, (u32)2);
        Bytes.add(cd, (u32)0);
        Bytes.add(cd, (u32)12);
        Bytes.put32be(cd, (u32)0);
        Bytes.put32be(cd, (u32)0);
        Bytes.put32be(cd, teamOffset);
        Bytes.put32be(cd, (u32)0);
        Bytes.put64be(cd, (u32)0, (u32)0);       // codeLimit64
        Bytes.put64be(cd, (u32)0, (u32)0);       // execSegBase
        Bytes.put64be(cd, (u32)0, execSegLimit); // execSegLimit
        Bytes.put64be(cd, (u32)0, (u32)1);       // execSegFlags = MAIN_BINARY
        apkAppend(cd, Bytes.fromString(ident));
        Bytes.add(cd, (u32)0);
        if (team)
            {
            apkAppend(cd, Bytes.fromString(teamId));
            Bytes.add(cd, (u32)0);
            }
        for (u32 i = nSpecial; i >= (u32)1; i = i - (u32)1)
            {
            Array* h = (Array*)0;
            for (u32 k = (u32)0; k < specialSlots.count(); k = k + (u32)1)
                if (Bytes.at(specialSlots, k) == i)
                    h = (Array*)specialHashes.get(k);
            if (h != (Array*)0)
                apkAppend(cd, h);
            else
                apkAppend(cd, Bytes.of((u32)32, (u32)0));
            if (i == (u32)1)
                break;
            }
        apkAppend(cd, codeHashes);
        return cd;
        }
    static Array* superBlob(Array* slots, Array* datas)
        {
        u32 count = slots.count();
        u32 headerAndIndex = (u32)12 + count * (u32)8;
        u32 total = headerAndIndex;
        for (u32 i = (u32)0; i < count; i = i + (u32)1)
            total = total + ((Array*)datas.get(i)).count();
        Array* sb = new Array();
        Bytes.put32be(sb, (u32)$fade0cc0);
        Bytes.put32be(sb, total);
        Bytes.put32be(sb, count);
        u32 off = headerAndIndex;
        for (u32 i = (u32)0; i < count; i = i + (u32)1)
            {
            Bytes.put32be(sb, Bytes.at(slots, i));
            Bytes.put32be(sb, off);
            off = off + ((Array*)datas.get(i)).count();
            }
        for (u32 i = (u32)0; i < count; i = i + (u32)1)
            apkAppend(sb, (Array*)datas.get(i));
        return sb;
        }
    static u32 roundUp(u32 v, u32 a)
        {
        return (v + a - (u32)1) & ~(a - (u32)1);
        }

    Array* resign(Array* macho, String* identifier, Identity* id, Array* entitlementsXml, Array* infoPlist, Array* codeResources, String* signingTime)
        {
        u32 flen = macho.count();
        if (flen < (u32)32)
            return fail("file too small");
        if (Bytes.rd32le(macho, (u32)0) != (u32)$FEEDFACF)
            return fail("not a 64-bit little-endian Mach-O");
        u32 ncmds = Bytes.rd32le(macho, (u32)16);
        u32 textFilesize = (u32)0;
        u32 linkeditCmdOff = (u32)0;
        u32 linkeditFileoff = (u32)0;
        u32 csCmdOff = (u32)0;
        u32 csDataoff = (u32)0;
        u32 p = (u32)32;
        for (u32 i = (u32)0; i < ncmds && p + (u32)8 <= flen; i = i + (u32)1)
            {
            u32 cmd = Bytes.rd32le(macho, p);
            u32 csize = Bytes.rd32le(macho, p + (u32)4);
            if (csize < (u32)8 || p + csize > flen)
                return fail("bad load command");
            if (cmd == (u32)$19)
                {
                String* seg = new String();
                for (u32 k = (u32)0; k < (u32)16; k = k + (u32)1)
                    {
                    u32 c = Bytes.at(macho, p + (u32)8 + k);
                    if (c == (u32)0)
                        break;
                    seg.appendByte((u8)c);
                    }
                if (seg.equals(String.withCString("__TEXT")))
                    textFilesize = Bytes.rd32le(macho, p + (u32)48);
                else if (seg.equals(String.withCString("__LINKEDIT")))
                    {
                    linkeditCmdOff = p;
                    linkeditFileoff = Bytes.rd32le(macho, p + (u32)40);
                    }
                }
            else if (cmd == (u32)$1d)
                {
                csCmdOff = p;
                csDataoff = Bytes.rd32le(macho, p + (u32)8);
                }
            p = p + csize;
            }
        if (linkeditCmdOff == (u32)0)
            return fail("no __LINKEDIT");
        if (csCmdOff == (u32)0)
            return fail("no LC_CODE_SIGNATURE (binary is not even ad-hoc signed)");
        u32 codeLimit = csDataoff;
        if (codeLimit == (u32)0 || codeLimit > flen)
            return fail("bad code-signature offset");
        u32 nCodeSlots = (codeLimit + (u32)4095) / (u32)4096;
        String* teamId = DerReader.teamId(id.leaf());
        Array* reqBody = new Array();
        Bytes.put32be(reqBody, (u32)0);
        Array* reqBlob = CodeSign.wrapBlob((u32)$fade0c01, reqBody);
        Array* specialSlots = new Array();
        Array* specialBlobs = new Array();
        Bytes.add(specialSlots, (u32)2);
        specialBlobs.add((Object*)reqBlob);
        Array* entBlob = (Array*)0;
        Array* derBlob = (Array*)0;
        if (entitlementsXml != (Array*)0)
            {
            entBlob = CodeSign.wrapBlob((u32)$fade7171, entitlementsXml);
            Bytes.add(specialSlots, (u32)5);
            specialBlobs.add((Object*)entBlob);
            // DER entitlements (slot 7): iOS installd requires it (macOS
            // codesign --verify does not — a device rejects the app 0xe8008029).
            Array* der = DerEnt.build(entitlementsXml);
            if (der != (Array*)0)
                {
                derBlob = CodeSign.wrapBlob((u32)$fade7172, der);
                Bytes.add(specialSlots, (u32)7);
                specialBlobs.add((Object*)derBlob);
                }
            }
        Array* specialHashes = new Array();
        for (u32 i = (u32)0; i < specialBlobs.count(); i = i + (u32)1)
            specialHashes.add((Object*)Bytes.sha256((Array*)specialBlobs.get(i)));
        // Bundle-mode hash-only slots: Info.plist (slot 1) and CodeResources
        // (slot 3). Appended to the parallel slot/hash arrays AFTER the blob
        // hashes so indices stay aligned; NO SuperBlob entry (docs/ios/bundle-signing.md).
        if (infoPlist != (Array*)0)
            {
            Bytes.add(specialSlots, (u32)1);
            specialHashes.add((Object*)Bytes.sha256(infoPlist));
            }
        if (codeResources != (Array*)0)
            {
            Bytes.add(specialSlots, (u32)3);
            specialHashes.add((Object*)Bytes.sha256(codeResources));
            }
        // size the signature with a placeholder CMS and CD
        Array* cmsProbe = Cms.signedData(Bytes.of((u32)32, (u32)0), id.leaf(), id.chain(), id.modulus(), id.privateExponent(), signingTime);
        if (cmsProbe == (Array*)0)
            return fail("CMS build failed (bad cert/key?)");
        Array* cmsProbeBlob = CodeSign.wrapBlob((u32)$fade0b01, cmsProbe);
        Array* cdProbe = CodeSign.codeDirectory(identifier, codeLimit, nCodeSlots, textFilesize, specialSlots, specialHashes,
                                                Bytes.of(nCodeSlots * (u32)32, (u32)0), teamId);
        Array* slots = new Array();
        Array* datas = new Array();
        Bytes.add(slots, (u32)0);
        datas.add((Object*)cdProbe);
        Bytes.add(slots, (u32)2);
        datas.add((Object*)reqBlob);
        if (entBlob != (Array*)0)
            {
            Bytes.add(slots, (u32)5);
            datas.add((Object*)entBlob);
            }
        if (derBlob != (Array*)0)
            {
            Bytes.add(slots, (u32)7);
            datas.add((Object*)derBlob);
            }
        slots.add((Object*)Number.withU32((u32)$10000));
        datas.add((Object*)cmsProbeBlob); // not Bytes.add: a slot is not a byte
        u32 sigSize = CodeSign.superBlob(slots, datas).count();
        // The signature is the file's LAST bytes: exact filesize, page-rounded
        // vmsize (iOS/codesign reject trailing padding — bug 148).
        u32 newLinkeditFilesz = (codeLimit + sigSize) - linkeditFileoff;
        u32 newLinkeditVmsz = CodeSign.roundUp(newLinkeditFilesz, (u32)$4000);
        Array* work = Bytes.slice(macho, (u32)0, codeLimit);
        Bytes.wr32le(work, csCmdOff + (u32)12, sigSize);
        Bytes.wr32le(work, linkeditCmdOff + (u32)32, newLinkeditVmsz);
        Bytes.wr32le(work, linkeditCmdOff + (u32)36, (u32)0);
        Bytes.wr32le(work, linkeditCmdOff + (u32)48, newLinkeditFilesz);
        Bytes.wr32le(work, linkeditCmdOff + (u32)52, (u32)0);
        Array* codeHashes = new Array();
        for (u32 i = (u32)0; i < nCodeSlots; i = i + (u32)1)
            {
            u32 off = i * (u32)4096;
            u32 len = codeLimit - off;
            if (len > (u32)4096)
                len = (u32)4096;
            Sha256* h = new Sha256();
            h.update(work, off, len);
            h.finalise(codeHashes);
            }
        Array* cd = CodeSign.codeDirectory(identifier, codeLimit, nCodeSlots, textFilesize, specialSlots, specialHashes, codeHashes, teamId);
        Array* cms = Cms.signedData(Bytes.sha256(cd), id.leaf(), id.chain(), id.modulus(), id.privateExponent(), signingTime);
        if (cms == (Array*)0)
            return fail("CMS build failed");
        datas.set((u32)0, (Object*)cd);
        datas.set(datas.count() - (u32)1, (Object*)CodeSign.wrapBlob((u32)$fade0b01, cms));
        Array* sb = CodeSign.superBlob(slots, datas);
        if (sb.count() != sigSize)
            return fail("sig size drift");
        Array* out = work;
        apkAppend(out, sb);
        // No trailing pad: the file ends at the signature (148).
        return out;
        }
    }
