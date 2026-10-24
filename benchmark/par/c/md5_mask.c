/* md5_mask: the par benchmark (apps/hashcat/md5_mask.xc, hashcat's mask
   attack: a fixed prefix hashed once per outer item, the last word varied
   in the inner loop) in C, for the C path: built by clang alone, and by xcc
   --par-auto. Prints "<checksum> <best_us> <first_us>". */
#include <stdio.h>
#include "bench_time.h"
#define OUTER (1024 * 1024 * BENCH_SCALE)
#define INNER 64
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

int main(void)
{
    unsigned total = 0;
    long long best = 0, first = 0;
    for (unsigned rep = 0; rep < 8; rep++) {
        total = 0;
        long long t0 = bench_now_us();
        for (unsigned p = bench_zero(); p < OUTER; p++) {
            unsigned m0 = p, m1 = P1, m2 = P2, m3 = P3, m4 = P4, m5 = P5, m6 = P6, m7 = P7;
            unsigned m8 = P8, m9 = P9, m10 = P10, m11 = P11;
            unsigned m13 = 0x80, m14 = 416, m15 = 0;
            unsigned A = 0x67452301, B = 0xefcdab89, C = 0x98badcfe, D = 0x10325476;
            MD5_PREFIX(A, B, C, D);
            for (unsigned j = 0; j < INNER; j++) {
                unsigned m12 = p * INNER + j;
                unsigned a = A, b = B, c = C, d = D;
                MD5_REST(a, b, c, d);
                total = total + (a + 0x67452301) + (b + 0xefcdab89)
                      + (c + 0x98badcfe) + (d + 0x10325476);
            }
        }
        bench_keep(total);
        long long t1 = bench_now_us();
        if (rep == 0) first = t1 - t0;
        if (rep == 0 || t1 - t0 < best) best = t1 - t0;
    }
    printf("%u %lld %lld\n", total, best, first);
    return 0;
}
