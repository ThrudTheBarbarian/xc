//xtc-na: xt6502 — written for 32-byte vectors; main's 527-byte frame is past the 6502's 119-byte SP-frame budget
// vectorize_wide_tails.xc — every vectorised loop shape at trip counts around
// a 32-byte vector, for every lane width, with a sentinel past the bound.
//
// Under -mavx2 a vector is 32 bytes: 8 u32 / f32 lanes, 16 u16, 32 u8. The
// other vectorise fixtures were written for 16-byte vectors, so their trips
// (multiples of 4, plus 3, 5, 7, 63) land the 256-bit epilogue on only a few
// of its cases. These bounds sit on each side of one and two wide vectors for
// each lane width, and each map case leaves a 777 sentinel at [N] that a wrong
// epilogue would overwrite.
//
// The same source runs at the default width too, where it is simply more tail
// cases; the expected output is the same at both widths, which is the check.
#import "Stdio.xc"

u32 a32[80];
u32 b32[80];
u16 a16[80];
u16 b16[80];
u8 a8[80];
u8 b8[80];
float af[80];
float bf[80];

void fill(void)
{
    for (u32 i = (u32)0; i < (u32)80; i = i + (u32)1)
    {
        a32[i] = i * (u32)2654435761;
        b32[i] = (u32)777;
        a16[i] = (u16)(i * (u32)40503);
        b16[i] = (u16)777;
        a8[i] = (u8)(i * (u32)37 + (u32)11);
        b8[i] = (u8)77;
        af[i] = (float)i * 0.5;
        bf[i] = 777.0;
    }
}

// Runtime bounds keep these checking loops scalar, so they cannot share a bug
// with the loops they check.
u32 sum32(u32 n)  { u32 s = (u32)0; for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s * (u32)31 + b32[i]; return s; }
u32 sum16(u32 n)  { u32 s = (u32)0; for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s * (u32)31 + (u32)b16[i]; return s; }
u32 sum8(u32 n)   { u32 s = (u32)0; for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s * (u32)31 + (u32)b8[i]; return s; }
float sumf(u32 n) { float s = 0.0; for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s + bf[i]; return s; }

// u32 map: 8 lanes per wide vector.
#define MAP32(N) \
    fill(); \
    for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1) b32[i] = (a32[i] + (u32)3) * (u32)5; \
    Stdio.printf("map32 n=%d h=%u past=%u\n", N, sum32((u32)N), b32[N]);

// u32 map from an unaligned start.
#define MAP32S(S, N) \
    fill(); \
    for (u32 i = (u32)S; i < (u32)N; i = i + (u32)1) b32[i] = a32[i] ^ (u32)$5A5A5A5A; \
    Stdio.printf("map32 from=%d n=%d h=%u before=%u past=%u\n", S, N, sum32((u32)N), b32[S - 1], b32[N]);

// u32 reductions: sum, max, min.
#define RED32(N) \
    fill(); \
    { u32 s = (u32)0; u32 mx = (u32)0; u32 mn = (u32)$FFFFFFFF; \
      for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1) s = s + a32[i]; \
      for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1) if (a32[i] > mx) mx = a32[i]; \
      for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1) if (a32[i] < mn) mn = a32[i]; \
      Stdio.printf("red32 n=%d sum=%u max=%u min=%u\n", N, s, mx, mn); }

// u32 lane shift and divide by a constant (a multiply-high).
#define DIV32(N) \
    fill(); \
    for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1) b32[i] = (a32[i] >> (u32)3) + a32[i] / (u32)7; \
    Stdio.printf("div32 n=%d h=%u past=%u\n", N, sum32((u32)N), b32[N]);

// u16 map: 16 lanes.
#define MAP16(N) \
    fill(); \
    for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1) b16[i] = a16[i] + (u16)1234; \
    Stdio.printf("map16 n=%d h=%u past=%u\n", N, sum16((u32)N), (u32)b16[N]);

// u8 map and a byte compare-count: 32 lanes.
#define MAP8(N) \
    fill(); \
    for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1) b8[i] = a8[i] + (u8)9; \
    { u32 c = (u32)0; for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1) if (a8[i] == (u8)48) c = c + (u32)1; \
      Stdio.printf("map8 n=%d h=%u past=%u eq48=%u\n", N, sum8((u32)N), (u32)b8[N], c); }

// f32 map: 8 lanes.
#define MAPF(N) \
    fill(); \
    for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1) bf[i] = af[i] * 2.0 + 1.0; \
    Stdio.printf("mapf n=%d s=%d past=%d\n", N, (i32)sumf((u32)N), (i32)bf[N]);

// The shapes the vectoriser recognises on LOCAL arrays: a signed max/min, a
// sum over a divide by a constant (a lane multiply-high and shift), and a
// byte compare-count (a widening ladder).
#define LOCAL(N) \
    { i32 a[N]; u32 u[N]; u8 c[N]; \
      for (i32 i = 0; i < N; i = i + 1) { a[i] = (i * 7919) % 1000 - 500; u[i] = (u32)i * (u32)2654435761; c[i] = (u8)((i * 31 + 1) & 127); } \
      i32 mx = -100000; i32 mn = 100000; u32 q = (u32)0; u32 k = (u32)0; \
      for (i32 i = 0; i < N; i = i + 1) if (a[i] > mx) mx = a[i]; \
      for (i32 i = 0; i < N; i = i + 1) if (a[i] < mn) mn = a[i]; \
      for (u32 i = (u32)0; i < (u32)N; i++) q = q + (u[i] / (u32)7); \
      for (u32 i = (u32)0; i < (u32)N; i++) if (c[i] == (u8)44) k = k + (u32)1; \
      Stdio.printf("local n=%d max=%d min=%d div7=%u eq44=%u\n", N, mx, mn, q, k); }

void main(void)
{
    LOCAL(8)  LOCAL(16) LOCAL(24) LOCAL(64) LOCAL(128) LOCAL(256) LOCAL(4096)
    MAP32(7)  MAP32(8)  MAP32(9)  MAP32(15) MAP32(16) MAP32(17) MAP32(23) MAP32(64) MAP32(71)
    MAP32S(1, 64) MAP32S(3, 40) MAP32S(5, 21)
    RED32(7)  RED32(8)  RED32(9)  RED32(17) RED32(31) RED32(64) RED32(79)
    DIV32(9)  DIV32(16) DIV32(25) DIV32(64)
    MAP16(15) MAP16(16) MAP16(17) MAP16(33) MAP16(64) MAP16(79)
    MAP8(31)  MAP8(32)  MAP8(33)  MAP8(63)  MAP8(64)  MAP8(79)
    MAPF(7)   MAPF(8)   MAPF(9)   MAPF(17)  MAPF(64)
}
