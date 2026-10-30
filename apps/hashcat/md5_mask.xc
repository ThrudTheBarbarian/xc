// md5_mask — hashcat's MASK-ATTACK MD5 workload in xc. Unlike md5.xc (which
// hashes one short candidate per item), this mirrors `-a 3`: a fixed prefix
// and one sweeping mask position. The MD5 steps before the mask word are
// loop-invariant, so they run once per prefix, not once per candidate -- the
// optimisation behind hashcat's faster optimized kernel.
//
// Each candidate is 52 bytes: m0..m11 the prefix (m0 = the outer index, the
// rest fixed), m12 the mask word (the inner sweep), then MD5 padding. The par
// block runs the outer loop over prefixes; for each it computes steps 0..11
// once, then the inner loop runs steps 12..63 per candidate. `md5_mask -t`
// checks one candidate's full digest against a known value.
#import "Stdio.xc"
#import "Par.xc"

i32 write(i32 fd, u8* buf, i32 len);

void hc_estr(u8* s) { i32 n = 0; while (s[n] != 0) n = n + 1; write(2, s, n); }
void hc_eu64(u64 v)
    {
    u8 buf[24]; i32 start = 24;
    if (v == 0) { start = start - 1; buf[start] = '0'; }
    while (v > 0) { start = start - 1; buf[start] = (u8)('0' + (v % 10)); v = v / 10; }
    write(2, &buf[start], 24 - start);
    }

#if OS_windows
i32 QueryPerformanceCounter(i64* count);
i32 QueryPerformanceFrequency(i64* freq);
#else
i32 clock_gettime(i32 clk, pointer ts);   // the library's signature (ParDevice.xc, RunLoop.xc)
#endif
struct HcSpec { i64 sec; i64 nsec; }
i64 hc_now_us(void)
    {
#if OS_windows
    i64 c = 0; i64 f = 1; QueryPerformanceCounter(&c); QueryPerformanceFrequency(&f);
    return (c / f) * 1000000 + ((c % f) * 1000000) / f;
#else
    HcSpec ts;
#if ARCH_x86_64
    clock_gettime(1, (pointer)&ts);
#else
    clock_gettime(6, (pointer)&ts);
#endif
    return (ts.sec * 1000000) + (ts.nsec / 1000);
#endif
    }

// Prefixes per launch, and mask values per prefix. Total candidates is their
// product; each is one 52-byte MD5.
#define OUTER (1024 * 1024)
#define INNER 64

// The 11 fixed prefix words m1..m11 (m0 is the outer index, m12 the mask).
#define P1  0x6b636168
#define P2  0x74736168
#define P3  0x6d786378
#define P4  0x31323334
#define P5  0x35363738
#define P6  0x61626364
#define P7  0x65666768
#define P8  0x696a6b6c
#define P9  0x6d6e6f70
#define P10 0x71727374
#define P11 0x75767778

// MD5 primitives (as md5.xc).
#define ROTL(x, c)    (((x) << (c)) | ((x) >> (32 - (c))))
#define MD5F(x, y, z) ((z) ^ ((x) & ((y) ^ (z))))
#define MD5G(x, y, z) ((y) ^ ((z) & ((x) ^ (y))))
#define MD5H(x, y, z) ((x) ^ (y) ^ (z))
#define MD5I(x, y, z) ((y) ^ ((x) | ~(z)))
#define FF(a, b, c, d, m, s, k) a = b + ROTL(a + MD5F(b, c, d) + (m) + (k), s)
#define GG(a, b, c, d, m, s, k) a = b + ROTL(a + MD5G(b, c, d) + (m) + (k), s)
#define HH(a, b, c, d, m, s, k) a = b + ROTL(a + MD5H(b, c, d) + (m) + (k), s)
#define II(a, b, c, d, m, s, k) a = b + ROTL(a + MD5I(b, c, d) + (m) + (k), s)

#define MD5_PREFIX(a, b, c, d) \
    FF(a, b, c, d, m0, 7, 0xd76aa478); \
    FF(d, a, b, c, m1, 12, 0xe8c7b756); \
    FF(c, d, a, b, m2, 17, 0x242070db); \
    FF(b, c, d, a, m3, 22, 0xc1bdceee); \
    FF(a, b, c, d, m4, 7, 0xf57c0faf); \
    FF(d, a, b, c, m5, 12, 0x4787c62a); \
    FF(c, d, a, b, m6, 17, 0xa8304613); \
    FF(b, c, d, a, m7, 22, 0xfd469501); \
    FF(a, b, c, d, m8, 7, 0x698098d8); \
    FF(d, a, b, c, m9, 12, 0x8b44f7af); \
    FF(c, d, a, b, m10, 17, 0xffff5bb1); \
    FF(b, c, d, a, m11, 22, 0x895cd7be)

#define MD5_REST(a, b, c, d) \
    FF(a, b, c, d, m12, 7, 0x6b901122); \
    FF(d, a, b, c, m13, 12, 0xfd987193); \
    FF(c, d, a, b, m14, 17, 0xa679438e); \
    FF(b, c, d, a, m15, 22, 0x49b40821); \
    GG(a, b, c, d, m1, 5, 0xf61e2562); \
    GG(d, a, b, c, m6, 9, 0xc040b340); \
    GG(c, d, a, b, m11, 14, 0x265e5a51); \
    GG(b, c, d, a, m0, 20, 0xe9b6c7aa); \
    GG(a, b, c, d, m5, 5, 0xd62f105d); \
    GG(d, a, b, c, m10, 9, 0x02441453); \
    GG(c, d, a, b, m15, 14, 0xd8a1e681); \
    GG(b, c, d, a, m4, 20, 0xe7d3fbc8); \
    GG(a, b, c, d, m9, 5, 0x21e1cde6); \
    GG(d, a, b, c, m14, 9, 0xc33707d6); \
    GG(c, d, a, b, m3, 14, 0xf4d50d87); \
    GG(b, c, d, a, m8, 20, 0x455a14ed); \
    GG(a, b, c, d, m13, 5, 0xa9e3e905); \
    GG(d, a, b, c, m2, 9, 0xfcefa3f8); \
    GG(c, d, a, b, m7, 14, 0x676f02d9); \
    GG(b, c, d, a, m12, 20, 0x8d2a4c8a); \
    HH(a, b, c, d, m5, 4, 0xfffa3942); \
    HH(d, a, b, c, m8, 11, 0x8771f681); \
    HH(c, d, a, b, m11, 16, 0x6d9d6122); \
    HH(b, c, d, a, m14, 23, 0xfde5380c); \
    HH(a, b, c, d, m1, 4, 0xa4beea44); \
    HH(d, a, b, c, m4, 11, 0x4bdecfa9); \
    HH(c, d, a, b, m7, 16, 0xf6bb4b60); \
    HH(b, c, d, a, m10, 23, 0xbebfbc70); \
    HH(a, b, c, d, m13, 4, 0x289b7ec6); \
    HH(d, a, b, c, m0, 11, 0xeaa127fa); \
    HH(c, d, a, b, m3, 16, 0xd4ef3085); \
    HH(b, c, d, a, m6, 23, 0x04881d05); \
    HH(a, b, c, d, m9, 4, 0xd9d4d039); \
    HH(d, a, b, c, m12, 11, 0xe6db99e5); \
    HH(c, d, a, b, m15, 16, 0x1fa27cf8); \
    HH(b, c, d, a, m2, 23, 0xc4ac5665); \
    II(a, b, c, d, m0, 6, 0xf4292244); \
    II(d, a, b, c, m7, 10, 0x432aff97); \
    II(c, d, a, b, m14, 15, 0xab9423a7); \
    II(b, c, d, a, m5, 21, 0xfc93a039); \
    II(a, b, c, d, m12, 6, 0x655b59c3); \
    II(d, a, b, c, m3, 10, 0x8f0ccc92); \
    II(c, d, a, b, m10, 15, 0xffeff47d); \
    II(b, c, d, a, m1, 21, 0x85845dd1); \
    II(a, b, c, d, m8, 6, 0x6fa87e4f); \
    II(d, a, b, c, m15, 10, 0xfe2ce6e0); \
    II(c, d, a, b, m6, 15, 0xa3014314); \
    II(b, c, d, a, m13, 21, 0x4e0811a1); \
    II(a, b, c, d, m4, 6, 0xf7537e82); \
    II(d, a, b, c, m11, 10, 0xbd3af235); \
    II(c, d, a, b, m2, 15, 0x2ad7d2bb); \
    II(b, c, d, a, m9, 21, 0xeb86d391)

#define MD5_FULL(a, b, c, d) \
    FF(a, b, c, d, m0, 7, 0xd76aa478); \
    FF(d, a, b, c, m1, 12, 0xe8c7b756); \
    FF(c, d, a, b, m2, 17, 0x242070db); \
    FF(b, c, d, a, m3, 22, 0xc1bdceee); \
    FF(a, b, c, d, m4, 7, 0xf57c0faf); \
    FF(d, a, b, c, m5, 12, 0x4787c62a); \
    FF(c, d, a, b, m6, 17, 0xa8304613); \
    FF(b, c, d, a, m7, 22, 0xfd469501); \
    FF(a, b, c, d, m8, 7, 0x698098d8); \
    FF(d, a, b, c, m9, 12, 0x8b44f7af); \
    FF(c, d, a, b, m10, 17, 0xffff5bb1); \
    FF(b, c, d, a, m11, 22, 0x895cd7be); \
    FF(a, b, c, d, m12, 7, 0x6b901122); \
    FF(d, a, b, c, m13, 12, 0xfd987193); \
    FF(c, d, a, b, m14, 17, 0xa679438e); \
    FF(b, c, d, a, m15, 22, 0x49b40821); \
    GG(a, b, c, d, m1, 5, 0xf61e2562); \
    GG(d, a, b, c, m6, 9, 0xc040b340); \
    GG(c, d, a, b, m11, 14, 0x265e5a51); \
    GG(b, c, d, a, m0, 20, 0xe9b6c7aa); \
    GG(a, b, c, d, m5, 5, 0xd62f105d); \
    GG(d, a, b, c, m10, 9, 0x02441453); \
    GG(c, d, a, b, m15, 14, 0xd8a1e681); \
    GG(b, c, d, a, m4, 20, 0xe7d3fbc8); \
    GG(a, b, c, d, m9, 5, 0x21e1cde6); \
    GG(d, a, b, c, m14, 9, 0xc33707d6); \
    GG(c, d, a, b, m3, 14, 0xf4d50d87); \
    GG(b, c, d, a, m8, 20, 0x455a14ed); \
    GG(a, b, c, d, m13, 5, 0xa9e3e905); \
    GG(d, a, b, c, m2, 9, 0xfcefa3f8); \
    GG(c, d, a, b, m7, 14, 0x676f02d9); \
    GG(b, c, d, a, m12, 20, 0x8d2a4c8a); \
    HH(a, b, c, d, m5, 4, 0xfffa3942); \
    HH(d, a, b, c, m8, 11, 0x8771f681); \
    HH(c, d, a, b, m11, 16, 0x6d9d6122); \
    HH(b, c, d, a, m14, 23, 0xfde5380c); \
    HH(a, b, c, d, m1, 4, 0xa4beea44); \
    HH(d, a, b, c, m4, 11, 0x4bdecfa9); \
    HH(c, d, a, b, m7, 16, 0xf6bb4b60); \
    HH(b, c, d, a, m10, 23, 0xbebfbc70); \
    HH(a, b, c, d, m13, 4, 0x289b7ec6); \
    HH(d, a, b, c, m0, 11, 0xeaa127fa); \
    HH(c, d, a, b, m3, 16, 0xd4ef3085); \
    HH(b, c, d, a, m6, 23, 0x04881d05); \
    HH(a, b, c, d, m9, 4, 0xd9d4d039); \
    HH(d, a, b, c, m12, 11, 0xe6db99e5); \
    HH(c, d, a, b, m15, 16, 0x1fa27cf8); \
    HH(b, c, d, a, m2, 23, 0xc4ac5665); \
    II(a, b, c, d, m0, 6, 0xf4292244); \
    II(d, a, b, c, m7, 10, 0x432aff97); \
    II(c, d, a, b, m14, 15, 0xab9423a7); \
    II(b, c, d, a, m5, 21, 0xfc93a039); \
    II(a, b, c, d, m12, 6, 0x655b59c3); \
    II(d, a, b, c, m3, 10, 0x8f0ccc92); \
    II(c, d, a, b, m10, 15, 0xffeff47d); \
    II(b, c, d, a, m1, 21, 0x85845dd1); \
    II(a, b, c, d, m8, 6, 0x6fa87e4f); \
    II(d, a, b, c, m15, 10, 0xfe2ce6e0); \
    II(c, d, a, b, m6, 15, 0xa3014314); \
    II(b, c, d, a, m13, 21, 0x4e0811a1); \
    II(a, b, c, d, m4, 6, 0xf7537e82); \
    II(d, a, b, c, m11, 10, 0xbd3af235); \
    II(c, d, a, b, m2, 15, 0x2ad7d2bb); \
    II(b, c, d, a, m9, 21, 0xeb86d391)


// Full MD5 of the candidate (p, mask), 52 bytes, on the CPU, as 32 hex digits.
void md5_mask_hex(u32 p, u32 mask, u8* out)
    {
    u32 m0 = p;   u32 m1 = P1;  u32 m2 = P2;  u32 m3 = P3;
    u32 m4 = P4;  u32 m5 = P5;  u32 m6 = P6;  u32 m7 = P7;
    u32 m8 = P8;  u32 m9 = P9;  u32 m10 = P10; u32 m11 = P11;
    u32 m12 = mask; u32 m13 = 0x80; u32 m14 = 416; u32 m15 = 0;
    u32 a = 0x67452301; u32 b = 0xefcdab89; u32 c = 0x98badcfe; u32 d = 0x10325476;
    MD5_FULL(a, b, c, d);
    a = a + 0x67452301; b = b + 0xefcdab89; c = c + 0x98badcfe; d = d + 0x10325476;
    u32 word[4];
    word[0] = a; word[1] = b; word[2] = c; word[3] = d;
    u8* hexd = "0123456789abcdef";
    u32 o = 0;
    for (u32 wi in 0..4)
        for (u32 bi in 0..4)
            {
            u32 byte = (word[wi] >> (bi * 8)) & 0xff;
            out[o] = hexd[byte >> 4];
            out[o + 1] = hexd[byte & 0xf];
            o = o + 2;
            }
    }

i32 selftest(void)
    {
    u8 got[33];
    got[32] = 0;
    md5_mask_hex(0, 0, got);
    u8* want = "8ac92423f2a00548a06836464f84346e";
    bool ok = true;
    for (u32 j in 0..32)
        if (got[j] != want[j])
            ok = false;
    Stdio.printf("md5_mask(p=0,mask=0) = %s  %s\n", (u8*)got, ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
    }

i32 main(i32 argc, u8** argv)
    {
    if (argc > 1 && argv[1][0] == '-' && argv[1][1] == 't')
        return selftest();

    u32 total = 0;
    i64 best = 0;
    i64 first = 0;
    for (u32 rep in 0..8)
        {
        total = 0;
        i64 t0 = hc_now_us();
        par md5mask :reduce(+ total)
            {
            for (u32 p in 0..OUTER)
                {
                u32 m0 = p;   u32 m1 = P1;  u32 m2 = P2;  u32 m3 = P3;
                u32 m4 = P4;  u32 m5 = P5;  u32 m6 = P6;  u32 m7 = P7;
                u32 m8 = P8;  u32 m9 = P9;  u32 m10 = P10; u32 m11 = P11;
                u32 m13 = 0x80; u32 m14 = 416; u32 m15 = 0;
                // The invariant prefix: steps 0..11, once per outer item.
                u32 A = 0x67452301; u32 B = 0xefcdab89;
                u32 C = 0x98badcfe; u32 D = 0x10325476;
                MD5_PREFIX(A, B, C, D);
                for (u32 j in 0..INNER)
                    {
                    u32 m12 = p * INNER + j;
                    u32 a = A; u32 b = B; u32 c = C; u32 d = D;
                    MD5_REST(a, b, c, d);
                    total = total + (a + 0x67452301) + (b + 0xefcdab89)
                          + (c + 0x98badcfe) + (d + 0x10325476);
                    }
                }
            }
        i64 t1 = hc_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
        }

    Stdio.printf("%u %lld %lld\n", total, best, first);
#if !ARCH_wasm32
    u64 cand = (u64)OUTER * (u64)INNER;
    u64 hs = best > 0 ? (cand * 1000000) / (u64)best : 0;
    hc_estr("md5_mask: "); hc_eu64(hs); hc_estr(" H/s (best run ");
    hc_eu64((u64)best); hc_estr(" us for "); hc_eu64(cand); hc_estr(" candidates)\n");
#endif
    return 0;
    }
