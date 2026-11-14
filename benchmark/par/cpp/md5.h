// md5.h — MD5's 64 steps for the C++ benchmarks (md5, md5_mask): one step as
// a template over its number, the rounds unrolled at compile time over an
// index sequence, the shifts, constants and message order as constexpr
// tables. The same arithmetic as benchmark/par/c/md5.c's macros.
#include <array>
#include <cstdint>
#include <utility>

// Every step inlined into the loop (64 of them make a function clang's
// inliner would otherwise leave out of line, its state in memory).
#if defined(__GNUC__) || defined(__clang__)
#define MD5_INLINE [[gnu::always_inline]] inline
#else
#define MD5_INLINE inline
#endif

namespace md5 {

struct State { uint32_t a, b, c, d; };

constexpr std::array<uint32_t, 64> K = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
constexpr std::array<unsigned, 16> S = {7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21};

constexpr uint32_t rotl(uint32_t x, unsigned c) { return (x << c) | (x >> (32 - c)); }

// The message word step k reads.
constexpr unsigned word(unsigned k)
    {
    return k < 16 ? k : k < 32 ? (5 * k + 1) % 16 : k < 48 ? (3 * k + 5) % 16 : (7 * k) % 16;
    }

template <unsigned k>
MD5_INLINE void step(State& s, const std::array<uint32_t, 16>& m)
    {
    uint32_t f;
    if constexpr (k < 16)
        f = (s.b & s.c) | (~s.b & s.d);
    else if constexpr (k < 32)
        f = (s.b & s.d) | (s.c & ~s.d);
    else if constexpr (k < 48)
        f = s.b ^ s.c ^ s.d;
    else
        f = s.c ^ (s.b | ~s.d);
    uint32_t next = s.b + rotl(s.a + f + m[word(k)] + K[k], S[(k / 16) * 4 + k % 4]);
    s = State{s.d, next, s.b, s.c};
    }

template <unsigned from, unsigned... k>
MD5_INLINE void steps(State& s, const std::array<uint32_t, 16>& m, std::integer_sequence<unsigned, k...>)
    {
    (step<from + k>(s, m), ...);
    }

// Steps [from, to) of one block.
template <unsigned from, unsigned to>
MD5_INLINE void rounds(State& s, const std::array<uint32_t, 16>& m)
    {
    steps<from>(s, m, std::make_integer_sequence<unsigned, to - from>{});
    }

constexpr State init = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476};

inline uint32_t digestSum(const State& s)
    {
    return (s.a + init.a) + (s.b + init.b) + (s.c + init.c) + (s.d + init.d);
    }

}
