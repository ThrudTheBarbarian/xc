// Struct layout: bitfields, a union, alignas, a packed struct, nested
// structs and arrays of structs walked in loops; a struct copied whole.
#include <cstdio>
#include <cstdint>
#include <cstring>

struct Bits { unsigned a : 3; unsigned b : 5; unsigned c : 12; int d : 7; };
union Num { float f; uint32_t u; uint8_t b[4]; };
struct alignas(32) Wide { double v[3]; int tag; };
#pragma pack(push, 1)
struct Packed { uint8_t k; uint32_t v; uint16_t w; };
#pragma pack(pop)
struct Inner { short s[3]; char c; };
struct Outer { Inner in[4]; long total; };

static Bits bits[512];
static Wide wides[128];
static Packed packs[256];
static Outer outers[64];

int main()
    {
    for (int i = 0; i < 512; i++) { bits[i].a = i; bits[i].b = i * 3; bits[i].c = i * 7; bits[i].d = (i % 100) - 50; }
    long bs = 0;
    for (int i = 0; i < 512; i++) bs += bits[i].a + bits[i].b * 10 + bits[i].c + bits[i].d;
    uint32_t us = 0;
    for (int i = 0; i < 300; i++) { Num n; n.f = i * 1.25f; us += n.u ^ n.b[1]; }
    for (int i = 0; i < 128; i++) { wides[i].v[0] = i; wides[i].v[1] = i * 0.5; wides[i].v[2] = -i; wides[i].tag = i & 3; }
    double ws = 0;
    for (int i = 0; i < 128; i++) ws += wides[i].v[0] * wides[i].v[1] + wides[i].v[2] * wides[i].tag;
    for (int i = 0; i < 256; i++) { packs[i].k = (uint8_t)i; packs[i].v = (uint32_t)i * 100003u; packs[i].w = (uint16_t)(i * 7); }
    uint64_t ps = 0;
    for (int i = 0; i < 256; i++) ps += packs[i].k + packs[i].v + packs[i].w;
    for (int i = 0; i < 64; i++) { for (int j = 0; j < 4; j++) { for (int k = 0; k < 3; k++) outers[i].in[j].s[k] = (short)(i * j - k); outers[i].in[j].c = (char)(j + 'a'); } outers[i].total = 0; }
    for (int i = 0; i < 64; i++) for (int j = 0; j < 4; j++) outers[i].total += outers[i].in[j].s[0] + outers[i].in[j].s[2] + outers[i].in[j].c;
    Outer copy = outers[63];
    long os = 0;
    for (int i = 0; i < 64; i++) os += outers[i].total;
    std::printf("%ld %u %.2f %llu %ld %ld %zu %zu\n", bs, us, ws, (unsigned long long)ps, os, copy.total, sizeof(Packed), alignof(Wide));
    return 0;
    }
