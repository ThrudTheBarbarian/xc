// Es256.xc — ECDSA over P-256 with SHA-256 (JOSE "ES256"), in xtc.
//
// App Store Connect authenticates a request with a JWT signed by the
// account's API key, an EC P-256 key in an AuthKey_*.p8 file. This is that
// signature: field arithmetic in Montgomery form over the ported Bignum,
// Jacobian point arithmetic, and a deterministic nonce (RFC 6979), so the
// same key and message always give the same signature and a known-answer
// test pins it.
//
// Bytes are Array@ of Number, as in CodeSign.xc.

#import "Foundation.xc"
#import "Bignum.xc"
#import "CodeSign.xc"

class EcPoint
    {
    Bignum* x; // Jacobian, Montgomery form; z == 0 is the point at infinity
    Bignum* y;
    Bignum* z;
    void init(void)
        {
        }
    }

class P256
    {
    Bignum* _p;
    Bignum* _n;
    u32 _np;       // -p^-1 mod 2^32
    Bignum* _r2;   // R^2 mod p
    Bignum* _one;  // R mod p: 1 in Montgomery form
    EcPoint* _g;
    String* _why;

    void init(void)
        {
        _p = P256.hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF");
        _n = P256.hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551");
        _np = Bignum.montInv(_p.limb((u32)0));
        Bignum* rr = new Bignum();
        rr.setLimb((u32)8, (u32)1);
        _one = Bignum.mod(rr, _p);
        _r2 = Bignum.mod(Bignum.mul(_one, _one), _p);
        _g = new EcPoint();
        _g.x = toMont(P256.hex("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296"));
        _g.y = toMont(P256.hex("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5"));
        _g.z = Bignum.copyOf(_one);
        }
    String* why(void)
        {
        return _why;
        }

    static Bignum* hex(string s)
        {
        String* h = String.withCString(s);
        Array* b = new Array();
        for (u32 i = (u32)0; i + (u32)1 < h.byteLength(); i = i + (u32)2)
            Bytes.add(b, (P256.nib(h.byteAt(i)) << (u32)4) | P256.nib(h.byteAt(i + (u32)1)));
        return Bignum.fromBytes(b);
        }
    static u32 nib(u8 c)
        {
        if (c >= (u8)'0' && c <= (u8)'9')
            return (u32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f')
            return (u32)(c - (u8)'a') + (u32)10;
        return (u32)(c - (u8)'A') + (u32)10;
        }

    // ── the field, mod p, in Montgomery form ────────────────────────────────
    Bignum* toMont(Bignum* a)
        {
        return Bignum.montMul(Bignum.mod(a, _p), _r2, _p, _np);
        }
    Bignum* fromMont(Bignum* a)
        {
        return Bignum.montMul(a, Bignum.fromU32((u32)1), _p, _np);
        }
    Bignum* mul(Bignum* a, Bignum* b)
        {
        return Bignum.montMul(a, b, _p, _np);
        }
    Bignum* add(Bignum* a, Bignum* b)
        {
        Bignum* r = Bignum.copyOf(a);
        Bignum.addInto(r, b);
        if (Bignum.cmp(r, _p) >= (i32)0)
            Bignum.subInto(r, _p);
        return r;
        }
    Bignum* sub(Bignum* a, Bignum* b)
        {
        Bignum* r = Bignum.copyOf(a);
        if (Bignum.cmp(a, b) < (i32)0)
            Bignum.addInto(r, _p);
        Bignum.subInto(r, b);
        return r;
        }

    // ── points (a = -3) ─────────────────────────────────────────────────────
    EcPoint* dbl(EcPoint* q)
        {
        if (q.z.isZero() || q.y.isZero())
            {
            EcPoint* inf = new EcPoint();
            inf.x = Bignum.copyOf(_one);
            inf.y = Bignum.copyOf(_one);
            inf.z = new Bignum();
            return inf;
            }
        Bignum* delta = mul(q.z, q.z);
        Bignum* gamma = mul(q.y, q.y);
        Bignum* beta = mul(q.x, gamma);
        Bignum* t = mul(sub(q.x, delta), add(q.x, delta));
        Bignum* alpha = add(add(t, t), t);
        Bignum* beta4 = add(beta, beta);
        beta4 = add(beta4, beta4);
        EcPoint* r = new EcPoint();
        r.x = sub(mul(alpha, alpha), add(beta4, beta4));
        Bignum* yz = add(q.y, q.z);
        r.z = sub(sub(mul(yz, yz), gamma), delta);
        Bignum* g2 = mul(gamma, gamma);
        Bignum* g8 = add(g2, g2);
        g8 = add(g8, g8);
        g8 = add(g8, g8);
        r.y = sub(mul(alpha, sub(beta4, r.x)), g8);
        return r;
        }
    EcPoint* addPts(EcPoint* a, EcPoint* b)
        {
        if (a.z.isZero())
            return b;
        if (b.z.isZero())
            return a;
        Bignum* z1z1 = mul(a.z, a.z);
        Bignum* z2z2 = mul(b.z, b.z);
        Bignum* u1 = mul(a.x, z2z2);
        Bignum* u2 = mul(b.x, z1z1);
        Bignum* s1 = mul(mul(a.y, b.z), z2z2);
        Bignum* s2 = mul(mul(b.y, a.z), z1z1);
        Bignum* h = sub(u2, u1);
        Bignum* rr = sub(s2, s1);
        if (h.isZero())
            {
            if (rr.isZero())
                return dbl(a);
            EcPoint* inf = new EcPoint();
            inf.x = Bignum.copyOf(_one);
            inf.y = Bignum.copyOf(_one);
            inf.z = new Bignum();
            return inf;
            }
        Bignum* h2 = add(h, h);
        Bignum* i = mul(h2, h2);
        Bignum* j = mul(h, i);
        Bignum* r = add(rr, rr);
        Bignum* v = mul(u1, i);
        EcPoint* o = new EcPoint();
        o.x = sub(sub(mul(r, r), j), add(v, v));
        Bignum* s1j = mul(s1, j);
        o.y = sub(mul(r, sub(v, o.x)), add(s1j, s1j));
        Bignum* zz = add(a.z, b.z);
        o.z = mul(sub(sub(mul(zz, zz), z1z1), z2z2), h);
        return o;
        }
    // k*G, and its affine x (plain form) in xOut.
    Bignum* baseMulX(Bignum* k)
        {
        EcPoint* r = new EcPoint();
        r.x = Bignum.copyOf(_one);
        r.y = Bignum.copyOf(_one);
        r.z = new Bignum();
        u32 i = k.bitLength();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            r = dbl(r);
            if (k.bitAt(i))
                r = addPts(r, _g);
            }
        if (r.z.isZero())
            return (Bignum*)0;
        // x = X / Z^2: invert Z by Fermat (p is prime), out of Montgomery form.
        Bignum* z = fromMont(r.z);
        Bignum* pm2 = Bignum.copyOf(_p);
        Bignum.subInto(pm2, Bignum.fromU32((u32)2));
        Bignum* zinv = toMont(Bignum.modexp(z, pm2, _p));
        Bignum* zinv2 = mul(zinv, zinv);
        return fromMont(mul(r.x, zinv2));
        }
    // The public point of d, affine (x, y) — for tests.
    Array* publicKey(Bignum* d)
        {
        EcPoint* r = new EcPoint();
        r.x = Bignum.copyOf(_one);
        r.y = Bignum.copyOf(_one);
        r.z = new Bignum();
        u32 i = d.bitLength();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            r = dbl(r);
            if (d.bitAt(i))
                r = addPts(r, _g);
            }
        Bignum* z = fromMont(r.z);
        Bignum* pm2 = Bignum.copyOf(_p);
        Bignum.subInto(pm2, Bignum.fromU32((u32)2));
        Bignum* zinv = toMont(Bignum.modexp(z, pm2, _p));
        Bignum* zinv2 = mul(zinv, zinv);
        Array* out = new Array();
        out.add((Object*)fromMont(mul(r.x, zinv2)).toBytes((u32)32));
        out.add((Object*)fromMont(mul(r.y, mul(zinv2, zinv))).toBytes((u32)32));
        return out;
        }

    // ── RFC 6979 nonce (HMAC-SHA256) ────────────────────────────────────────
    static Array* cat3(Array* a, u32 mid, bool hasMid, Array* b, Array* c)
        {
        Array* o = Bytes.copy(a);
        if (hasMid)
            Bytes.add(o, mid);
        if (b != (Array*)0)
            for (u32 i = (u32)0; i < b.count(); i = i + (u32)1)
                o.add(b.get(i));
        if (c != (Array*)0)
            for (u32 i = (u32)0; i < c.count(); i = i + (u32)1)
                o.add(c.get(i));
        return o;
        }
    Bignum* nonce(Array* x32, Array* h1)
        {
        Bignum* hz = Bignum.fromBytes(h1);
        if (Bignum.cmp(hz, _n) >= (i32)0)
            Bignum.subInto(hz, _n);
        Array* h = hz.toBytes((u32)32);
        Array* v = Bytes.of((u32)32, (u32)1);
        Array* k = Bytes.of((u32)32, (u32)0);
        k = Kdf.hmac(true, k, P256.cat3(v, (u32)0, true, x32, h));
        v = Kdf.hmac(true, k, v);
        k = Kdf.hmac(true, k, P256.cat3(v, (u32)1, true, x32, h));
        v = Kdf.hmac(true, k, v);
        while (true)
            {
            v = Kdf.hmac(true, k, v);
            Bignum* c = Bignum.fromBytes(v);
            if (!c.isZero() && Bignum.cmp(c, _n) < (i32)0)
                return c;
            k = Kdf.hmac(true, k, P256.cat3(v, (u32)0, true, (Array*)0, (Array*)0));
            v = Kdf.hmac(true, k, v);
            }
        return (Bignum*)0;
        }

    // The 64-byte JOSE signature (r || s) of SHA-256(msg) under private key
    // d (32 bytes, big-endian), or null.
    Array* sign(Array* d32, Array* msg)
        {
        Array* h1 = Bytes.sha256(msg);
        Bignum* d = Bignum.fromBytes(d32);
        Bignum* k = nonce(d.toBytes((u32)32), h1);
        Bignum* x = baseMulX(k);
        if (x == (Bignum*)0)
            return (Array*)0;
        Bignum* r = Bignum.mod(x, _n);
        if (r.isZero())
            return (Array*)0;
        Bignum* z = Bignum.fromBytes(h1);
        if (Bignum.cmp(z, _n) >= (i32)0)
            Bignum.subInto(z, _n);
        Bignum* nm2 = Bignum.copyOf(_n);
        Bignum.subInto(nm2, Bignum.fromU32((u32)2));
        Bignum* kinv = Bignum.modexp(k, nm2, _n);
        Bignum* sum = Bignum.modmul(r, d, _n);
        Bignum.addInto(sum, z);
        if (Bignum.cmp(sum, _n) >= (i32)0)
            Bignum.subInto(sum, _n);
        Bignum* s = Bignum.modmul(kinv, sum, _n);
        if (s.isZero())
            return (Array*)0;
        Array* out = r.toBytes((u32)32);
        Array* sb = s.toBytes((u32)32);
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            out.add(sb.get(i));
        return out;
        }

    // The 32-byte private scalar of a P-256 key in PEM: PKCS#8 PrivateKeyInfo
    // ("PRIVATE KEY", what an AuthKey_*.p8 holds) or SEC1 ("EC PRIVATE KEY").
    // Null with why() set when it is neither.
    Array* privateKeyFromPEM(String* text)
        {
        Array* blocks = Pem.blocks(text);
        for (u32 i = (u32)0; i < blocks.count(); i = i + (u32)1)
            {
            PemBlock* b = (PemBlock*)blocks.get(i);
            Array* der = b.der();
            if (b.label().equals(String.withCString("PRIVATE KEY")))
                {
                // SEQ { version, AlgorithmIdentifier, OCTET STRING { ECPrivateKey } }
                DerReader* seq = DerReader.of(der).readConstructed();
                if (seq == (DerReader*)0)
                    break;
                seq.readTLV();
                DerReader* alg = seq.readConstructed();
                if (alg == (DerReader*)0)
                    break;
                Array* oid = alg.readTLV();
                u32 ecPub[7] = {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01};
                if (!Pkcs8.oidIs(oid, ecPub, (u32)7))
                    {
                    _why = String.withCString("the key is not an EC key");
                    return (Array*)0;
                    }
                Array* inner = seq.readTLV();
                if (inner == (Array*)0 || seq.lastTag() != (u32)$04)
                    break;
                der = inner;
                }
            else if (!b.label().equals(String.withCString("EC PRIVATE KEY")))
                continue;
            // ECPrivateKey ::= SEQ { version 1, privateKey OCTET STRING, ... }
            DerReader* ec = DerReader.of(der).readConstructed();
            if (ec == (DerReader*)0)
                break;
            ec.readTLV();
            Array* d = ec.readTLV();
            if (d == (Array*)0 || ec.lastTag() != (u32)$04 || d.count() > (u32)32)
                break;
            while (d.count() < (u32)32)
                d.insert((u32)0, (Object*)Number.withU32((u32)0));
            return d;
            }
        _why = String.withCString("could not parse the .p8 key");
        return (Array*)0;
        }
    }
