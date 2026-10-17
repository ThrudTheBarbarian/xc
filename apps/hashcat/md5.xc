// md5 — hashcat's MD5 workload in xc. Each item hashes one 8-byte candidate
// through the full MD5 compression (64 rounds over a single 512-bit block),
// the way hashcat's -m 0 kernel does: short candidates, one block, raw
// throughput measured in hashes per second.
//
// The hash runs inside a `par` block, so the device is the compiler's to
// choose: XC_PAR=cpu one CPU thread or all of them, XC_PAR=gpu the GPU
// (Metal, Vulkan or CUDA), the default auto measures both and keeps the
// faster. `md5 -t` runs the RFC 1321 known-answer tests on the CPU; the same
// MD5_ROUNDS drives the test and the kernel, so passing the test proves the
// code the GPU runs.
//
// The benchmark prints "<checksum> <best_us> <first_us>": the sum of every
// candidate's four digest words (exact, so every mode must agree), the best
// of eight runs, and the first run (which carries the one-off cost of a GPU
// building its kernel). A hashes-per-second line goes to stderr.
#import "Stdio.xc"
#import "Par.xc"

// Headline numbers go to stderr, so stdout stays the three-token line the par
// benchmarks share. write() is the libSystem call Stdio itself uses. The
// wasm32 browser build reads stdout only, so it leaves all this out.
#if !ARCH_wasm32
i32 write(i32 fd, u8* buf, i32 len);

void hc_estr(u8* s)
    {
    i32 n = 0;
    while (s[n] != 0)
        n = n + 1;
    write(2, s, n);
    }

void hc_eu64(u64 v)
    {
    u8 buf[24];
    i32 start = 24;
    if (v == 0)
        {
        start = start - 1;
        buf[start] = '0';
        }
    while (v > 0)
        {
        start = start - 1;
        buf[start] = (u8)('0' + (v % 10));
        v = v / 10;
        }
    write(2, &buf[start], 24 - start);
    }
#endif

// A monotonic microsecond clock, measured the same way on every target.
#if ARCH_win64
i32 QueryPerformanceCounter(i64* count);
i32 QueryPerformanceFrequency(i64* freq);
#else
i32 clock_gettime(i32 clk, pointer ts);   // the library's signature (ParDevice.xc, RunLoop.xc)
#endif

struct HcSpec { i64 sec; i64 nsec; }

i64 hc_now_us(void)
    {
#if ARCH_win64
    i64 c = 0;
    i64 f = 1;
    QueryPerformanceCounter(&c);
    QueryPerformanceFrequency(&f);
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

// Candidates per par launch: large enough to saturate a GPU (at 16M the run
// is too short and launch overhead dominates; 64M reaches within a few
// percent of the peak). Each is one full MD5 compression. A serial CPU run
// of this size takes a few seconds per repetition; the default auto run
// picks the GPU and stays fast.
#define BATCH (64 * 1024 * 1024)

// The 32-bit word packed into bytes 4..7 of every candidate, so the input
// looks like an 8-byte password that varies only in its first word.
#define TAG 0x6b636168

// MD5 primitives: left rotate and the four round functions.
#define ROTL(x, c)    (((x) << (c)) | ((x) >> (32 - (c))))
#define MD5F(x, y, z) (((x) & (y)) | (~(x) & (z)))
#define MD5G(x, y, z) (((x) & (z)) | ((y) & ~(z)))
#define MD5H(x, y, z) ((x) ^ (y) ^ (z))
#define MD5I(x, y, z) ((y) ^ ((x) | ~(z)))

// One step: the updated word becomes b + ((a + f(b,c,d) + m + k) rotl s).
#define FF(a, b, c, d, m, s, k) a = b + ROTL(a + MD5F(b, c, d) + (m) + (k), s)
#define GG(a, b, c, d, m, s, k) a = b + ROTL(a + MD5G(b, c, d) + (m) + (k), s)
#define HH(a, b, c, d, m, s, k) a = b + ROTL(a + MD5H(b, c, d) + (m) + (k), s)
#define II(a, b, c, d, m, s, k) a = b + ROTL(a + MD5I(b, c, d) + (m) + (k), s)

// The 64 steps over the message words m0..m15, mutating the working words
// a,b,c,d. The caller sets a,b,c,d to the IV first and adds the IV back
// afterwards.
#define MD5_ROUNDS \
    FF(a, b, c, d, m0,   7, 0xd76aa478); \
    FF(d, a, b, c, m1,  12, 0xe8c7b756); \
    FF(c, d, a, b, m2,  17, 0x242070db); \
    FF(b, c, d, a, m3,  22, 0xc1bdceee); \
    FF(a, b, c, d, m4,   7, 0xf57c0faf); \
    FF(d, a, b, c, m5,  12, 0x4787c62a); \
    FF(c, d, a, b, m6,  17, 0xa8304613); \
    FF(b, c, d, a, m7,  22, 0xfd469501); \
    FF(a, b, c, d, m8,   7, 0x698098d8); \
    FF(d, a, b, c, m9,  12, 0x8b44f7af); \
    FF(c, d, a, b, m10, 17, 0xffff5bb1); \
    FF(b, c, d, a, m11, 22, 0x895cd7be); \
    FF(a, b, c, d, m12,  7, 0x6b901122); \
    FF(d, a, b, c, m13, 12, 0xfd987193); \
    FF(c, d, a, b, m14, 17, 0xa679438e); \
    FF(b, c, d, a, m15, 22, 0x49b40821); \
    GG(a, b, c, d, m1,   5, 0xf61e2562); \
    GG(d, a, b, c, m6,   9, 0xc040b340); \
    GG(c, d, a, b, m11, 14, 0x265e5a51); \
    GG(b, c, d, a, m0,  20, 0xe9b6c7aa); \
    GG(a, b, c, d, m5,   5, 0xd62f105d); \
    GG(d, a, b, c, m10,  9, 0x02441453); \
    GG(c, d, a, b, m15, 14, 0xd8a1e681); \
    GG(b, c, d, a, m4,  20, 0xe7d3fbc8); \
    GG(a, b, c, d, m9,   5, 0x21e1cde6); \
    GG(d, a, b, c, m14,  9, 0xc33707d6); \
    GG(c, d, a, b, m3,  14, 0xf4d50d87); \
    GG(b, c, d, a, m8,  20, 0x455a14ed); \
    GG(a, b, c, d, m13,  5, 0xa9e3e905); \
    GG(d, a, b, c, m2,   9, 0xfcefa3f8); \
    GG(c, d, a, b, m7,  14, 0x676f02d9); \
    GG(b, c, d, a, m12, 20, 0x8d2a4c8a); \
    HH(a, b, c, d, m5,   4, 0xfffa3942); \
    HH(d, a, b, c, m8,  11, 0x8771f681); \
    HH(c, d, a, b, m11, 16, 0x6d9d6122); \
    HH(b, c, d, a, m14, 23, 0xfde5380c); \
    HH(a, b, c, d, m1,   4, 0xa4beea44); \
    HH(d, a, b, c, m4,  11, 0x4bdecfa9); \
    HH(c, d, a, b, m7,  16, 0xf6bb4b60); \
    HH(b, c, d, a, m10, 23, 0xbebfbc70); \
    HH(a, b, c, d, m13,  4, 0x289b7ec6); \
    HH(d, a, b, c, m0,  11, 0xeaa127fa); \
    HH(c, d, a, b, m3,  16, 0xd4ef3085); \
    HH(b, c, d, a, m6,  23, 0x04881d05); \
    HH(a, b, c, d, m9,   4, 0xd9d4d039); \
    HH(d, a, b, c, m12, 11, 0xe6db99e5); \
    HH(c, d, a, b, m15, 16, 0x1fa27cf8); \
    HH(b, c, d, a, m2,  23, 0xc4ac5665); \
    II(a, b, c, d, m0,   6, 0xf4292244); \
    II(d, a, b, c, m7,  10, 0x432aff97); \
    II(c, d, a, b, m14, 15, 0xab9423a7); \
    II(b, c, d, a, m5,  21, 0xfc93a039); \
    II(a, b, c, d, m12,  6, 0x655b59c3); \
    II(d, a, b, c, m3,  10, 0x8f0ccc92); \
    II(c, d, a, b, m10, 15, 0xffeff47d); \
    II(b, c, d, a, m1,  21, 0x85845dd1); \
    II(a, b, c, d, m8,   6, 0x6fa87e4f); \
    II(d, a, b, c, m15, 10, 0xfe2ce6e0); \
    II(c, d, a, b, m6,  15, 0xa3014314); \
    II(b, c, d, a, m13, 21, 0x4e0811a1); \
    II(a, b, c, d, m4,   6, 0xf7537e82); \
    II(d, a, b, c, m11, 10, 0xbd3af235); \
    II(c, d, a, b, m2,  15, 0x2ad7d2bb); \
    II(b, c, d, a, m9,  21, 0xeb86d391)

// MD5 of a message shorter than 56 bytes (one padded block), on the CPU.
// Writes the 32 hex digits of the digest through `out` (no NUL).
void md5_hex(u8* msg, u32 len, u8* out)
    {
    u32 w[16];
    for (u32 i in 0..16)
        w[i] = 0;
    for (u32 i in 0..len)
        w[i >> 2] = w[i >> 2] | ((u32)msg[i] << ((i & 3) * 8));
    w[len >> 2] = w[len >> 2] | ((u32)0x80 << ((len & 3) * 8));
    w[14] = len * 8;

    u32 m0 = w[0];   u32 m1 = w[1];   u32 m2 = w[2];   u32 m3 = w[3];
    u32 m4 = w[4];   u32 m5 = w[5];   u32 m6 = w[6];   u32 m7 = w[7];
    u32 m8 = w[8];   u32 m9 = w[9];   u32 m10 = w[10]; u32 m11 = w[11];
    u32 m12 = w[12]; u32 m13 = w[13]; u32 m14 = w[14]; u32 m15 = w[15];

    u32 a = 0x67452301;
    u32 b = 0xefcdab89;
    u32 c = 0x98badcfe;
    u32 d = 0x10325476;
    MD5_ROUNDS;
    a = a + 0x67452301;
    b = b + 0xefcdab89;
    c = c + 0x98badcfe;
    d = d + 0x10325476;

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
    u8* msgs[4];
    msgs[0] = "";
    msgs[1] = "abc";
    msgs[2] = "message digest";
    msgs[3] = "abcdefghijklmnopqrstuvwxyz";
    u32 lens[4];
    lens[0] = 0; lens[1] = 3; lens[2] = 14; lens[3] = 26;
    u8* want[4];
    want[0] = "d41d8cd98f00b204e9800998ecf8427e";
    want[1] = "900150983cd24fb0d6963f7d28e17f72";
    want[2] = "f96b697d7cb7938d525a2f31aaf161d0";
    want[3] = "c3fcd3d76192e4007dfb496cca67e13b";

    i32 fails = 0;
    for (u32 i in 0..4)
        {
        md5_hex(msgs[i], lens[i], got);
        bool ok = true;
        for (u32 j in 0..32)
            if (got[j] != want[i][j])
                ok = false;
        Stdio.printf("md5(\"%s\") = %s  %s\n", msgs[i], (u8*)got, ok ? "ok" : "FAIL");
        if (!ok)
            fails = fails + 1;
        }
    return fails;
    }

i32 main(i32 argc, u8** argv)
    {
    if (argc > 1 && argv[1][0] == '-' && argv[1][1] == 't')
        return selftest() == 0 ? 0 : 1;

    u32 total = 0;
    i64 best = 0;
    i64 first = 0;
    for (u32 rep in 0..8)
        {
        total = 0;
        i64 t0 = hc_now_us();
        par md5 :reduce(+ total)
            {
            for (u32 i in 0..BATCH)
                {
                // The candidate: word 0 is the item index, word 1 the tag,
                // then MD5 padding for an 8-byte message (0x80, then zeros,
                // then the 64-bit length).
                u32 m0 = i;
                u32 m1 = TAG;
                u32 m2 = 0x80;
                u32 m3 = 0;  u32 m4 = 0;  u32 m5 = 0;
                u32 m6 = 0;  u32 m7 = 0;  u32 m8 = 0;
                u32 m9 = 0;  u32 m10 = 0; u32 m11 = 0;
                u32 m12 = 0; u32 m13 = 0; u32 m14 = 64;
                u32 m15 = 0;

                u32 a = 0x67452301;
                u32 b = 0xefcdab89;
                u32 c = 0x98badcfe;
                u32 d = 0x10325476;
                MD5_ROUNDS;
                total = total + (a + 0x67452301) + (b + 0xefcdab89)
                      + (c + 0x98badcfe) + (d + 0x10325476);
                }
            }
        i64 t1 = hc_now_us();
        if (rep == 0)
            first = t1 - t0;
        if (rep == 0 || t1 - t0 < best)
            best = t1 - t0;
        }

    Stdio.printf("%u %lld %lld\n", total, best, first);
    // Hashes per second from the best run, exact integer division. Skipped on
    // wasm32, where the browser harness reads stdout and there is no stderr.
#if !ARCH_wasm32
    u64 hs = best > 0 ? ((u64)BATCH * 1000000) / (u64)best : 0;
    hc_estr("md5: ");
    hc_eu64(hs);
    hc_estr(" H/s (best run ");
    hc_eu64((u64)best);
    hc_estr(" us for ");
    hc_eu64((u64)BATCH);
    hc_estr(" candidates)\n");
#endif
    return 0;
    }
