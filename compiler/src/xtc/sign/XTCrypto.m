//
//  XTCrypto.m — see XTCrypto.h.
//

#import "XTCrypto.h"

// ─────────────────────────────────────────────────────────────────────────
//  SHA-1
// ─────────────────────────────────────────────────────────────────────────
typedef struct
    {
    uint32_t h[5];
    uint64_t len;
    uint8_t buf[64];
    uint32_t n;
    } SHA1;
static uint32_t rol32(uint32_t x, int r)
    {
    return (x << r) | (x >> (32 - r));
    }
static void sha1_block(SHA1* c, const uint8_t* p)
    {
    uint32_t w[80];
    for (int i = 0; i < 16; i++)
        w[i] = (p[i * 4] << 24) | (p[i * 4 + 1] << 16) | (p[i * 4 + 2] << 8) | p[i * 4 + 3];
    for (int i = 16; i < 80; i++)
        w[i] = rol32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint32_t a = c->h[0], b = c->h[1], cc = c->h[2], d = c->h[3], e = c->h[4];
    for (int i = 0; i < 80; i++)
        {
        uint32_t f, k;
        if (i < 20)
            {
            f = (b & cc) | (~b & d);
            k = 0x5A827999;
            }
        else if (i < 40)
            {
            f = b ^ cc ^ d;
            k = 0x6ED9EBA1;
            }
        else if (i < 60)
            {
            f = (b & cc) | (b & d) | (cc & d);
            k = 0x8F1BBCDC;
            }
        else
            {
            f = b ^ cc ^ d;
            k = 0xCA62C1D6;
            }
        uint32_t t = rol32(a, 5) + f + e + k + w[i];
        e = d;
        d = cc;
        cc = rol32(b, 30);
        b = a;
        a = t;
        }
    c->h[0] += a;
    c->h[1] += b;
    c->h[2] += cc;
    c->h[3] += d;
    c->h[4] += e;
    }
static void sha1_init(SHA1* c)
    {
    c->h[0] = 0x67452301;
    c->h[1] = 0xEFCDAB89;
    c->h[2] = 0x98BADCFE;
    c->h[3] = 0x10325476;
    c->h[4] = 0xC3D2E1F0;
    c->len = 0;
    c->n = 0;
    }
static void sha1_update(SHA1* c, const uint8_t* p, size_t n)
    {
    c->len += n;
    while (n)
        {
        size_t k = 64 - c->n;
        if (k > n)
            k = n;
        memcpy(c->buf + c->n, p, k);
        c->n += k;
        p += k;
        n -= k;
        if (c->n == 64)
            {
            sha1_block(c, c->buf);
            c->n = 0;
            }
        }
    }
static void sha1_final(SHA1* c, uint8_t out[20])
    {
    uint64_t bits = c->len * 8;
    uint8_t pad = 0x80;
    sha1_update(c, &pad, 1);
    uint8_t z = 0;
    while (c->n != 56)
        sha1_update(c, &z, 1);
    uint8_t lb[8];
    for (int i = 0; i < 8; i++)
        lb[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha1_update(c, lb, 8);
    for (int i = 0; i < 5; i++)
        {
        out[i * 4] = (uint8_t)(c->h[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(c->h[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(c->h[i] >> 8);
        out[i * 4 + 3] = (uint8_t)c->h[i];
        }
    }

// ─────────────────────────────────────────────────────────────────────────
//  SHA-256
// ─────────────────────────────────────────────────────────────────────────
typedef struct
    {
    uint32_t s[8];
    uint64_t len;
    uint8_t buf[64];
    uint32_t n;
    } SHA256C;
static uint32_t ror32(uint32_t x, int r)
    {
    return (x >> r) | (x << (32 - r));
    }
static void sha256_block(SHA256C* c, const uint8_t* p)
    {
    static const uint32_t K[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (p[i * 4] << 24) | (p[i * 4 + 1] << 16) | (p[i * 4 + 2] << 8) | p[i * 4 + 3];
    for (int i = 16; i < 64; i++)
        {
        uint32_t s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3),
                 s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
    uint32_t a = c->s[0], b = c->s[1], cc = c->s[2], d = c->s[3], e = c->s[4], f = c->s[5], g = c->s[6], h = c->s[7];
    for (int i = 0; i < 64; i++)
        {
        uint32_t S1 = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25), ch = (e & f) ^ (~e & g),
                 t1 = h + S1 + ch + K[i] + w[i], S0 = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22), maj = (a & b) ^ (a & cc) ^ (b & cc), t2 = S0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = cc;
        cc = b;
        b = a;
        a = t1 + t2;
        }
    c->s[0] += a;
    c->s[1] += b;
    c->s[2] += cc;
    c->s[3] += d;
    c->s[4] += e;
    c->s[5] += f;
    c->s[6] += g;
    c->s[7] += h;
    }
static void sha256_init(SHA256C* c)
    {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(c->s, iv, sizeof iv);
    c->len = 0;
    c->n = 0;
    }
static void sha256_update(SHA256C* c, const uint8_t* p, size_t n)
    {
    c->len += n;
    while (n)
        {
        size_t k = 64 - c->n;
        if (k > n)
            k = n;
        memcpy(c->buf + c->n, p, k);
        c->n += k;
        p += k;
        n -= k;
        if (c->n == 64)
            {
            sha256_block(c, c->buf);
            c->n = 0;
            }
        }
    }
static void sha256_final(SHA256C* c, uint8_t out[32])
    {
    uint64_t bits = c->len * 8;
    uint8_t pad = 0x80;
    sha256_update(c, &pad, 1);
    uint8_t z = 0;
    while (c->n != 56)
        sha256_update(c, &z, 1);
    uint8_t lb[8];
    for (int i = 0; i < 8; i++)
        lb[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_update(c, lb, 8);
    for (int i = 0; i < 8; i++)
        {
        out[i * 4] = (uint8_t)(c->s[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(c->s[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(c->s[i] >> 8);
        out[i * 4 + 3] = (uint8_t)c->s[i];
        }
    }

// ─────────────────────────────────────────────────────────────────────────
//  Big integers — little-endian uint32_t limbs, fixed capacity.
//  Enough for RSA-4096 (128 limbs) with the Montgomery scratch headroom.
// ─────────────────────────────────────────────────────────────────────────
#define BN_MAX 160
typedef struct
    {
    uint32_t v[BN_MAX];
    int n;
    } BN; // n = significant limbs

static void bn_zero(BN* a)
    {
    memset(a->v, 0, sizeof a->v);
    a->n = 0;
    }
static void bn_trim(BN* a)
    {
    while (a->n > 0 && a->v[a->n - 1] == 0)
        a->n--;
    }

static void bn_from_be(BN* a, const uint8_t* p, size_t len)
    {
    bn_zero(a);
    // Big-endian bytes → little-endian limbs.
    int limb = 0, sh = 0;
    for (ssize_t i = (ssize_t)len - 1; i >= 0; i--)
        {
        a->v[limb] |= (uint32_t)p[i] << sh;
        sh += 8;
        if (sh == 32)
            {
            sh = 0;
            limb++;
            if (limb >= BN_MAX)
                break;
            }
        }
    a->n = (sh ? limb + 1 : limb);
    bn_trim(a);
    }
static void bn_to_be(const BN* a, uint8_t* out, size_t len)
    {
    memset(out, 0, len);
    for (size_t i = 0; i < len; i++)
        {
        int limb = (int)(i / 4), sh = (int)((i % 4) * 8);
        uint32_t w = (limb < a->n) ? a->v[limb] : 0;
        out[len - 1 - i] = (uint8_t)(w >> sh);
        }
    }
// -1/0/1
static int bn_cmp(const BN* a, const BN* b)
    {
    if (a->n != b->n)
        return a->n < b->n ? -1 : 1;
    for (int i = a->n - 1; i >= 0; i--)
        if (a->v[i] != b->v[i])
            return a->v[i] < b->v[i] ? -1 : 1;
    return 0;
    }
// a -= b   (assumes a >= b)
static void bn_sub(BN* a, const BN* b)
    {
    uint64_t borrow = 0;
    for (int i = 0; i < a->n; i++)
        {
        uint64_t bi = (i < b->n) ? b->v[i] : 0;
        uint64_t cur = (uint64_t)a->v[i] - bi - borrow;
        a->v[i] = (uint32_t)cur;
        borrow = (cur >> 63) & 1; // set if it wrapped
        }
    bn_trim(a);
    }
// a <<= 1
static void bn_shl1(BN* a)
    {
    uint32_t carry = 0;
    for (int i = 0; i < a->n; i++)
        {
        uint32_t nc = a->v[i] >> 31;
        a->v[i] = (a->v[i] << 1) | carry;
        carry = nc;
        }
    if (carry)
        a->v[a->n++] = carry;
    }

// n0inv = -n^{-1} mod 2^32  (Montgomery, Dusse-Kaliski via Newton on 32 bits)
static uint32_t mont_n0inv(uint32_t n0)
    {
    uint32_t x = n0; // n0 is odd
    x *= 2 - n0 * x; // each step doubles the correct bits: 2,4,8,16,32
    x *= 2 - n0 * x;
    x *= 2 - n0 * x;
    x *= 2 - n0 * x;
    x *= 2 - n0 * x;
    return (uint32_t)(0u - x); // negate
    }

// CIOS Montgomery multiply: t = a * b * R^{-1} mod m, R = 2^(32*k), k = m->n.
static void mont_mul(BN* out, const BN* a, const BN* b, const BN* m, uint32_t n0inv)
    {
    int k = m->n;
    uint64_t t[BN_MAX + 2];
    memset(t, 0, sizeof(uint64_t) * (k + 2));
    for (int i = 0; i < k; i++)
        {
        uint64_t ai = (i < a->n) ? a->v[i] : 0;
        // t += a_i * b
        uint64_t carry = 0;
        for (int j = 0; j < k; j++)
            {
            uint64_t bj = (j < b->n) ? b->v[j] : 0;
            uint64_t sum = t[j] + ai * bj + carry;
            t[j] = (uint32_t)sum;
            carry = sum >> 32;
            }
        uint64_t hi = t[k] + carry;
        t[k] = (uint32_t)hi;
        t[k + 1] += hi >> 32;
        // m_reduce: u = t0 * n0inv mod 2^32 ; t += u * m ; t >>= 32
        uint32_t u = (uint32_t)((uint32_t)t[0] * n0inv);
        carry = 0;
        for (int j = 0; j < k; j++)
            {
            uint64_t mj = (j < m->n) ? m->v[j] : 0;
            uint64_t sum = t[j] + (uint64_t)u * mj + carry;
            t[j] = (uint32_t)sum;
            carry = sum >> 32;
            }
        hi = t[k] + carry;
        t[k] = (uint32_t)hi;
        t[k + 1] += hi >> 32;
        // shift right one limb
        for (int j = 0; j <= k; j++)
            t[j] = t[j + 1];
        t[k + 1] = 0;
        }
    bn_zero(out);
    for (int i = 0; i < k + 1; i++)
        if (i < BN_MAX)
            {
            out->v[i] = (uint32_t)t[i];
            }
    out->n = k + 1;
    bn_trim(out);
    if (bn_cmp(out, m) >= 0)
        bn_sub(out, m);
    }

// R^2 mod m, computed without division: start at 1, double 2*32*k times mod m.
static void mont_r2(BN* r2, const BN* m)
    {
    BN x;
    bn_zero(&x);
    x.v[0] = 1;
    x.n = 1;
    int bits = 2 * 32 * m->n;
    for (int i = 0; i < bits; i++)
        {
        bn_shl1(&x);
        if (bn_cmp(&x, m) >= 0)
            bn_sub(&x, m);
        }
    *r2 = x;
    }

// result = base^exp mod m  (all big-endian on the ObjC boundary)
static void bn_modexp(BN* result, const BN* base, const BN* exp, const BN* m)
    {
    // needs odd modulus
    if (m->n == 0 || (m->v[0] & 1) == 0)
        {
        bn_zero(result);
        return;
        }
    uint32_t n0inv = mont_n0inv(m->v[0]);
    BN r2;
    mont_r2(&r2, m);
    // baseM = base * R mod m ; x = 1 * R mod m
    BN baseR, x, one;
    bn_zero(&one);
    one.v[0] = 1;
    one.n = 1;
    BN bmod = *base;
    /* reduce base once via mont trick */
    if (bn_cmp(&bmod, m) >= 0)
        {
        // base mod m: subtract m until smaller (base < m^2 always here for our use)
        while (bn_cmp(&bmod, m) >= 0)
            bn_sub(&bmod, m);
        }
    mont_mul(&baseR, &bmod, &r2, m, n0inv);
    mont_mul(&x, &one, &r2, m, n0inv);
    for (int i = exp->n - 1; i >= 0; i--)
        {
        for (int bit = 31; bit >= 0; bit--)
            {
            BN sq;
            mont_mul(&sq, &x, &x, m, n0inv);
            x = sq;
            if ((exp->v[i] >> bit) & 1)
                {
                BN t;
                mont_mul(&t, &x, &baseR, m, n0inv);
                x = t;
                }
            }
        }
    mont_mul(result, &x, &one, m, n0inv); // back out of Montgomery form
    }

// ─────────────────────────────────────────────────────────────────────────
@implementation XTCrypto

+ (NSData*)sha1:(NSData*)data
    {
    SHA1 c;
    sha1_init(&c);
    sha1_update(&c, data.bytes, data.length);
    uint8_t out[20];
    sha1_final(&c, out);
    return [NSData dataWithBytes:out length:20];
    }
+ (NSData*)sha256:(NSData*)data
    {
    SHA256C c;
    sha256_init(&c);
    sha256_update(&c, data.bytes, data.length);
    uint8_t out[32];
    sha256_final(&c, out);
    return [NSData dataWithBytes:out length:32];
    }

// ── key generation ───────────────────────────────────────────────────────
//
// Only the pieces RSA keygen needs beyond what signing already had: a
// schoolbook multiply, small-word multiply/divide, and Miller-Rabin on top of
// the existing modexp. It exists so that making a debug key needs no JDK and
// no `keytool` — the same reason nothing else here shells out.

static void bn_copy(BN* d, const BN* s)
    {
    memcpy(d->v, s->v, sizeof d->v);
    d->n = s->n;
    }

// d = a * b  (schoolbook; operands are half the modulus width, so this is the
// only place two full-size numbers meet and BN_MAX has room for the product)
static void bn_mul(BN* d, const BN* a, const BN* b)
    {
    BN t;
    bn_zero(&t);
    for (int i = 0; i < a->n; i++)
        {
        uint64_t carry = 0;
        for (int j = 0; j < b->n || carry; j++)
            {
            int k = i + j;
            if (k >= BN_MAX)
                break;
            uint64_t cur = (uint64_t)t.v[k] + carry + (uint64_t)a->v[i] * (j < b->n ? b->v[j] : 0);
            t.v[k] = (uint32_t)cur;
            carry = cur >> 32;
            }
        }
    t.n = a->n + b->n + 1;
    if (t.n > BN_MAX)
        t.n = BN_MAX;
    bn_trim(&t);
    bn_copy(d, &t);
    }

// a = a * m + add   (m, add fit in a word)
static void bn_mul_small(BN* a, uint32_t m, uint32_t add)
    {
    uint64_t carry = add;
    for (int i = 0; i < a->n; i++)
        {
        uint64_t cur = (uint64_t)a->v[i] * m + carry;
        a->v[i] = (uint32_t)cur;
        carry = cur >> 32;
        }
    while (carry && a->n < BN_MAX)
        {
        a->v[a->n++] = (uint32_t)carry;
        carry >>= 32;
        }
    bn_trim(a);
    }

// a /= m, returning a % m. The whole reason keygen needs no general division:
// every divisor it meets is a single word.
static uint32_t bn_div_small(BN* a, uint32_t m)
    {
    uint64_t rem = 0;
    for (int i = a->n - 1; i >= 0; i--)
        {
        uint64_t cur = (rem << 32) | a->v[i];
        a->v[i] = (uint32_t)(cur / m);
        rem = cur % m;
        }
    bn_trim(a);
    return (uint32_t)rem;
    }

static uint32_t bn_mod_small(const BN* a, uint32_t m)
    {
    uint64_t rem = 0;
    for (int i = a->n - 1; i >= 0; i--)
        rem = (((rem << 32) | a->v[i]) % m);
    return (uint32_t)rem;
    }

static void bn_sub_small(BN* a, uint32_t m)
    {
    uint64_t borrow = m;
    for (int i = 0; i < a->n && borrow; i++)
        {
        uint64_t cur = (uint64_t)a->v[i] - (borrow & 0xFFFFFFFFu);
        a->v[i] = (uint32_t)cur;
        borrow = (cur >> 63) & 1;
        }
    bn_trim(a);
    }

static void bn_shr1(BN* a)
    {
    for (int i = 0; i < a->n; i++)
        {
        a->v[i] >>= 1;
        if (i + 1 < a->n)
            a->v[i] |= (a->v[i + 1] & 1u) << 31;
        }
    bn_trim(a);
    }

// Bytes from the OS. A key made from a predictable stream is not a key, so a
// missing entropy source is a REFUSAL rather than a fallback to something
// weaker — the failure mode of getting this wrong is silent and permanent.
static BOOL xtRandomBytes(uint8_t* out, size_t n)
    {
    FILE* f = fopen("/dev/urandom", "rb");
    if (!f)
        return NO;
    size_t got = fread(out, 1, n, f);
    fclose(f);
    return got == n;
    }

// The first primes, for trial division — it rejects most candidates far more
// cheaply than a Miller-Rabin round would.
static const uint32_t kSmallPrimes[] = {
    3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101,
    103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167, 173, 179, 181, 191, 193,
    197, 199, 211, 223, 227, 229, 233, 239, 241, 251, 257, 263, 269, 271, 277, 281, 283, 293};

static BOOL bn_probably_prime(const BN* p)
    {
    if (p->n == 0 || !(p->v[0] & 1))
        return NO;
    for (size_t i = 0; i < sizeof kSmallPrimes / sizeof kSmallPrimes[0]; i++)
        if (bn_mod_small(p, kSmallPrimes[i]) == 0)
            return NO;

    // Miller-Rabin. n-1 = 2^s * d.
    BN nm1;
    bn_copy(&nm1, p);
    bn_sub_small(&nm1, 1);
    BN d;
    bn_copy(&d, &nm1);
    int s = 0;
    while (d.n > 0 && !(d.v[0] & 1))
        {
        bn_shr1(&d);
        s++;
        }

    // Fixed small bases: for a 1024-bit candidate that has already survived
    // trial division, these give a failure probability far below the odds of
    // the machine miscomputing them.
    static const uint32_t bases[] = {2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37};
    for (size_t bi = 0; bi < sizeof bases / sizeof bases[0]; bi++)
        {
        BN a;
        bn_zero(&a);
        a.v[0] = bases[bi];
        a.n = 1;
        BN x;
        bn_modexp(&x, &a, &d, p);
        BN one;
        bn_zero(&one);
        one.v[0] = 1;
        one.n = 1;
        if (bn_cmp(&x, &one) == 0 || bn_cmp(&x, &nm1) == 0)
            continue;
        BOOL witnessed = YES;
        for (int r = 1; r < s; r++)
            {
            BN sq;
            bn_modexp(&sq, &x, &(BN){.v = {2}, .n = 1}, p);
            bn_copy(&x, &sq);
            if (bn_cmp(&x, &nm1) == 0)
                {
                witnessed = NO;
                break;
                }
            }
        if (witnessed)
            return NO;
        }
    return YES;
    }

// A random prime of exactly `bits` bits, with the top TWO bits set so that
// p*q always lands in the requested modulus width rather than one bit short.
static BOOL bn_random_prime(BN* out, int bits)
    {
    int bytes = bits / 8;
    uint8_t* buf = malloc((size_t)bytes);
    if (!buf)
        return NO;
    for (int tries = 0; tries < 20000; tries++)
        {
        if (!xtRandomBytes(buf, (size_t)bytes))
            {
            free(buf);
            return NO;
            }
        buf[0] |= 0xC0;      // top two bits
        buf[bytes - 1] |= 1; // odd
        bn_from_be(out, buf, (size_t)bytes);
        if (bn_probably_prime(out))
            {
            free(buf);
            return YES;
            }
        }
    free(buf);
    return NO;
    }

+ (nullable NSDictionary<NSString*, NSData*>*)rsaGenerateKeyOfBits:(int)bits
    {
    if (bits < 512 || bits > 4096 || (bits % 16) != 0)
        return nil;
    const uint32_t E = 65537;
    BN p, q, n, phi;
    for (int attempt = 0; attempt < 64; attempt++)
        {
        if (!bn_random_prime(&p, bits / 2))
            return nil;
        if (!bn_random_prime(&q, bits / 2))
            return nil;
        if (bn_cmp(&p, &q) == 0)
            continue;
        // e must be coprime to p-1 and q-1, or there is no d.
        BN p1;
        bn_copy(&p1, &p);
        bn_sub_small(&p1, 1);
        BN q1;
        bn_copy(&q1, &q);
        bn_sub_small(&q1, 1);
        if (bn_mod_small(&p1, E) == 0 || bn_mod_small(&q1, E) == 0)
            continue;
        bn_mul(&n, &p, &q);
        bn_mul(&phi, &p1, &q1);

        // d = e^{-1} mod phi, WITHOUT a general division.
        //
        // e*d = 1 + k*phi for some k, and reducing that modulo the SMALL e
        // gives k ≡ -phi^{-1} (mod e) — so k fits in a word and can be found by
        // brute force over e. Then d = (1 + k*phi)/e is a big number times a
        // word, divided by a word: both single-limb operations.
        uint32_t phiModE = bn_mod_small(&phi, E);
        uint32_t k = 0;
        for (uint32_t t = 1; t < E; t++)
            {
            if ((uint64_t)phiModE * t % E == E - 1)
                {
                k = t;
                break;
                }
            }
        if (k == 0)
            continue;
        BN d;
        bn_copy(&d, &phi);
        bn_mul_small(&d, k, 1);             // d = k*phi + 1
        uint32_t rem = bn_div_small(&d, E); // d = (k*phi + 1) / e
        if (rem != 0)
            continue; // e did not divide it — retry

        NSUInteger nBytes = (NSUInteger)bits / 8;
        NSMutableData* nOut = [NSMutableData dataWithLength:nBytes];
        NSMutableData* dOut = [NSMutableData dataWithLength:nBytes];
        bn_to_be(&n, nOut.mutableBytes, nBytes);
        bn_to_be(&d, dOut.mutableBytes, nBytes);
        uint8_t eb[3] = {0x01, 0x00, 0x01};
        return @{@"n" : nOut, @"e" : [NSData dataWithBytes:eb length:3], @"d" : dOut};
        }
    return nil;
    }

+ (NSData*)modexpBase:(NSData*)base exponent:(NSData*)exponent modulus:(NSData*)modulus
    {
    if (modulus.length == 0 || modulus.length > BN_MAX * 4)
        return nil;
    BN b, e, m, r;
    bn_from_be(&b, base.bytes, base.length);
    bn_from_be(&e, exponent.bytes, exponent.length);
    bn_from_be(&m, modulus.bytes, modulus.length);
    bn_modexp(&r, &b, &e, &m);
    NSMutableData* out = [NSMutableData dataWithLength:modulus.length];
    bn_to_be(&r, out.mutableBytes, out.length);
    return out;
    }

+ (nullable NSData*)rsaSignPKCS1:(NSData*)digestInfo
                         modulus:(NSData*)modulus
                 privateExponent:(NSData*)privateExponent
    {
    // Strip a possible leading 0x00 on the modulus (DER positive-INTEGER pad)
    // so its length is the true key size in bytes.
    const uint8_t* mp = modulus.bytes;
    NSUInteger mlen = modulus.length;
    while (mlen > 0 && mp[0] == 0x00)
        {
        mp++;
        mlen--;
        }
    if (mlen < digestInfo.length + 11)
        return nil; // PKCS#1 minimum padding
    // EM = 0x00 0x01 PS(0xFF..) 0x00 || T, |EM| = mlen
    NSMutableData* em = [NSMutableData dataWithLength:mlen];
    uint8_t* e = em.mutableBytes;
    e[0] = 0x00;
    e[1] = 0x01;
    NSUInteger psLen = mlen - digestInfo.length - 3;
    memset(e + 2, 0xFF, psLen);
    e[2 + psLen] = 0x00;
    memcpy(e + 3 + psLen, digestInfo.bytes, digestInfo.length);
    NSData* trueMod = [NSData dataWithBytes:mp length:mlen];
    return [self modexpBase:em exponent:privateExponent modulus:trueMod];
    }

@end
