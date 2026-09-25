// RsaKeygen.xc — RSA key generation, in xtc.
// =================================================================
//
// The shipped compiler must be able to sign a package on a machine that has
// never seen another one. "The bootstrap compiler generates it" is not an
// answer a user can act on: for them the bootstrap does not exist.
//
// Two random probable primes, n = p*q, e = 65537, and d = e^-1 mod phi. The
// inverse is the only part that needs care, because this bignum deliberately
// has no general division — see `privateExponent` below.

#import "Foundation.xc"
#import "Files.xc"
#import "Bignum.xc"

// Host primitives — see support/arm64/runtime/libxt.c.
i32 _xt_file_open(u8* path, u8* mode);
i32 _xt_file_read(i32 handle, u8* buf, u32 n);
void _xt_file_close(i32 handle);

class Rsa
    {
    // Real entropy or nothing. A key from a predictable stream is worse than a
    // refusal: it looks like a key, signs like a key, and is forgeable.
    static Array* randomBytes(u32 n)
        {
        Array* out = new Array();
        i32 h = _xt_file_open((u8*)"/dev/urandom", (u8*)"rb");
        if (h < (i32)0)
            return out; // caller refuses
        u8* buf = new u8[n];
        i32 got = _xt_file_read(h, buf, n);
        _xt_file_close(h);
        if (got < (i32)n)
            {
            delete buf;
            return out;
            }
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            out.add((Object*)Number.withU32((u32)buf[i]));
        delete buf;
        return out;
        }

    // The first 54 odd primes: enough to reject ~80% of candidates for the
    // price of a modulo, before a Miller-Rabin round costs a modexp.
    static Array* smallPrimes(void)
        {
        Array* p = new Array();
        u32 v[54];
        v[0] = (u32)3;
        v[1] = (u32)5;
        v[2] = (u32)7;
        v[3] = (u32)11;
        v[4] = (u32)13;
        v[5] = (u32)17;
        v[6] = (u32)19;
        v[7] = (u32)23;
        v[8] = (u32)29;
        v[9] = (u32)31;
        v[10] = (u32)37;
        v[11] = (u32)41;
        v[12] = (u32)43;
        v[13] = (u32)47;
        v[14] = (u32)53;
        v[15] = (u32)59;
        v[16] = (u32)61;
        v[17] = (u32)67;
        v[18] = (u32)71;
        v[19] = (u32)73;
        v[20] = (u32)79;
        v[21] = (u32)83;
        v[22] = (u32)89;
        v[23] = (u32)97;
        v[24] = (u32)101;
        v[25] = (u32)103;
        v[26] = (u32)107;
        v[27] = (u32)109;
        v[28] = (u32)113;
        v[29] = (u32)127;
        v[30] = (u32)131;
        v[31] = (u32)137;
        v[32] = (u32)139;
        v[33] = (u32)149;
        v[34] = (u32)151;
        v[35] = (u32)157;
        v[36] = (u32)163;
        v[37] = (u32)167;
        v[38] = (u32)173;
        v[39] = (u32)179;
        v[40] = (u32)181;
        v[41] = (u32)191;
        v[42] = (u32)193;
        v[43] = (u32)197;
        v[44] = (u32)199;
        v[45] = (u32)211;
        v[46] = (u32)223;
        v[47] = (u32)227;
        v[48] = (u32)229;
        v[49] = (u32)233;
        v[50] = (u32)239;
        v[51] = (u32)241;
        v[52] = (u32)251;
        v[53] = (u32)257;
        for (u32 i = (u32)0; i < (u32)54; i = i + (u32)1)
            p.add((Object*)Number.withU32(v[i]));
        return p;
        }

    // Miller-Rabin. `rounds` independent bases; a composite survives one round
    // with probability at most 1/4, so 24 rounds is far below any chance that
    // matters here.
    static bool isProbablePrime(Bignum* n, u32 rounds)
        {
        if (n.bitLength() < (u32)2)
            return false;
        if (!n.isOdd())
            return false;

        Array* sp = Rsa.smallPrimes();
        for (u32 i = (u32)0; i < sp.count(); i = i + (u32)1)
            {
            u32 q = ((Number*)sp.get(i)).asU32();
            if (Bignum.modSmall(n, q) == (u32)0)
                {
                Bignum* qq = Bignum.fromU32(q);
                return Bignum.cmp(n, qq) == (i32)0; // n IS that small prime
                }
            }

        Bignum* one = Bignum.fromU32((u32)1);
        Bignum* nm1 = Bignum.copyOf(n);
        Bignum.subInto(nm1, one);

        // n-1 = d * 2^s
        Bignum* d = Bignum.copyOf(nm1);
        u32 s = (u32)0;
        while (!d.isOdd())
            {
            d.shrOne();
            s = s + (u32)1;
            }

        for (u32 r = (u32)0; r < rounds; r = r + (u32)1)
            {
            // A base in [2, n-2], taken from the same entropy the key is.
            u32 nbytes = (n.bitLength() + (u32)7) / (u32)8;
            Array* rb = Rsa.randomBytes(nbytes);
            if (rb.count() == (u32)0)
                return false; // no entropy: refuse
            Bignum* a = Bignum.fromBytes(rb);
            a = Bignum.mod(a, nm1);
            if (Bignum.cmp(a, one) <= (i32)0)
                a = Bignum.fromU32((u32)2);

            Bignum* x = Bignum.modexp(a, d, n);
            if (Bignum.cmp(x, one) == (i32)0)
                continue;
            if (Bignum.cmp(x, nm1) == (i32)0)
                continue;
            bool witnessed = true;
            for (u32 k = (u32)1; k < s; k = k + (u32)1)
                {
                x = Bignum.modmul(x, x, n);
                if (Bignum.cmp(x, nm1) == (i32)0)
                    {
                    witnessed = false;
                    break;
                    }
                }
            if (witnessed)
                return false;
            }
        return true;
        }

    // A random probable prime of exactly `bits` bits. The top TWO bits are set
    // so that p*q always has 2*bits bits — otherwise a modulus can come out a
    // bit short and the signature no longer fills the block.
    static Bignum* randomPrime(u32 bits)
        {
        u32 nbytes = bits / (u32)8;
        while (true)
            {
            Array* rb = Rsa.randomBytes(nbytes);
            if (rb.count() == (u32)0)
                return (Bignum*)0;
            rb.set((u32)0, (Object*)Number.withU32(((Number*)rb.get((u32)0)).asU32() | (u32)$C0));
            u32 last = nbytes - (u32)1;
            rb.set(last, (Object*)Number.withU32(((Number*)rb.get(last)).asU32() | (u32)1));
            Bignum* c = Bignum.fromBytes(rb);
            if (Rsa.isProbablePrime(c, (u32)24))
                return c;
            }
        return (Bignum*)0;
        }

    // d = e^-1 mod phi, without a general division.
    //
    // e*d = 1 + k*phi for some k in [1, e-1]. Taking that modulo the SMALL e
    // gives k*phi = -1 (mod e), so k is found by scanning one word — 65537
    // trials at worst, each a single-limb modulo. Then d = (1 + k*phi)/e is a
    // big-by-word divide, which this bignum does have. Extended Euclid would
    // need full division; this needs none.
    static Bignum* privateExponent(Bignum* phi, u32 e)
        {
        u32 phiMod = Bignum.modSmall(phi, e);
        if (phiMod == (u32)0)
            return (Bignum*)0; // gcd(e, phi) != 1
        u32 k = (u32)0;
        u32 want = e - (u32)1; // we need k*phi = e-1 (mod e)
        u64 acc = (u64)0;
        for (u32 t = (u32)1; t < e; t = t + (u32)1)
            {
            acc = (acc + (u64)phiMod) % (u64)e;
            if ((u32)acc == want)
                {
                k = t;
                break;
                }
            }
        if (k == (u32)0)
            return (Bignum*)0;
        Bignum* num = Bignum.mulSmall(phi, k);
        Bignum* one = Bignum.fromU32((u32)1);
        Bignum.addInto(num, one);
        return Bignum.divSmall(num, e);
        }

    // Returns [n, e, d, p, q, dp, dq, qinv] as big-endian byte arrays, or an
    // empty array on failure (no entropy, or a phi that shares a factor with
    // e). Signing needs only the first three.
    static Array* generate(u32 bits)
        {
        u32 half = bits / (u32)2;
        u32 e = (u32)65537;
        while (true)
            {
            Bignum* p = Rsa.randomPrime(half);
            if (p == (Bignum*)0)
                return new Array();
            Bignum* q = Rsa.randomPrime(half);
            if (q == (Bignum*)0)
                return new Array();
            if (Bignum.cmp(p, q) == (i32)0)
                continue;

            Bignum* n = Bignum.mul(p, q);
            Bignum* one = Bignum.fromU32((u32)1);
            Bignum* p1 = Bignum.copyOf(p);
            Bignum.subInto(p1, one);
            Bignum* q1 = Bignum.copyOf(q);
            Bignum.subInto(q1, one);
            Bignum* phi = Bignum.mul(p1, q1);

            Bignum* d = Rsa.privateExponent(phi, e);
            if (d == (Bignum*)0)
                continue; // retry with new primes

            Array* out = new Array();
            out.add((Object*)n.toBytes(bits / (u32)8));
            Array* eb = new Array();
            eb.add((Object*)Number.withU32((u32)1));
            eb.add((Object*)Number.withU32((u32)0));
            eb.add((Object*)Number.withU32((u32)1)); // 0x010001 = 65537
            out.add((Object*)eb);
            out.add((Object*)d.toBytes(bits / (u32)8));
            // The CRT parameters, for a full PKCS#1 key: p, q, d mod (p-1),
            // d mod (q-1) and q^-1 mod p (Fermat: p is prime, so q^(p-2)).
            Bignum* two = Bignum.fromU32((u32)2);
            Bignum* pm2 = Bignum.copyOf(p);
            Bignum.subInto(pm2, two);
            out.add((Object*)p.toBytes(half / (u32)8));
            out.add((Object*)q.toBytes(half / (u32)8));
            out.add((Object*)Bignum.mod(d, p1).toBytes(half / (u32)8));
            out.add((Object*)Bignum.mod(d, q1).toBytes(half / (u32)8));
            out.add((Object*)Bignum.modexp(q, pm2, p).toBytes(half / (u32)8));
            return out;
            }
        return new Array();
        }
    }
