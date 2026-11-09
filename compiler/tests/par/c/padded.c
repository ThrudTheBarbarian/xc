/* padded: arrays of structs whose fields are not all 4 bytes, on the GPU.
   Each struct keeps the host's layout (padding, a nested struct, 1-, 2-, 4-
   and 8-byte fields); a kernel holds it as words and reads each field from
   its word. blocks.txt allows no block without a GPU form. */
#include <stdio.h>
#include <stdint.h>
#define N 65536
struct tag { uint8_t kind; int16_t dz; };          /* 1 byte of padding */
struct rec { uint8_t a; int8_t b; uint16_t c; int32_t d; float e; int64_t f; struct tag t; };
struct px { uint8_t r, g, b; uint8_t pad; uint16_t w; };
struct rec rs[N];
struct px ps[N];
int main(void)
{
    for (int i = 0; i < N; i++) {
        rs[i].a = (uint8_t)i; rs[i].b = (int8_t)(i % 200 - 100); rs[i].c = (uint16_t)(i * 7);
        rs[i].d = i - 30000; rs[i].e = (float)(i % 64) * 0.5f; rs[i].f = (int64_t)i * 100000;
        rs[i].t.kind = (uint8_t)(i % 7); rs[i].t.dz = (int16_t)(i % 1000 - 500);
        ps[i].r = (uint8_t)i; ps[i].g = (uint8_t)(i >> 3); ps[i].b = (uint8_t)(i * 5); ps[i].pad = 0xAA; ps[i].w = (uint16_t)i;
    }
    for (int i = 0; i < N; i++) {
        rs[i].a = (uint8_t)(rs[i].a + 1);
        rs[i].b = (int8_t)(rs[i].b - 3);
        rs[i].c = (uint16_t)(rs[i].c ^ 0x5555);
        rs[i].d = rs[i].d * 3;
        rs[i].e = rs[i].e + (float)rs[i].b;
        rs[i].t.kind = (uint8_t)(rs[i].t.kind + rs[i].a);
        rs[i].t.dz = (int16_t)(rs[i].t.dz * 2);
    }
    for (int i = 0; i < N; i++)
        rs[i].f += rs[i].d;
    for (int i = 0; i < N; i++) {
        uint8_t y = (uint8_t)((ps[i].r * 77 + ps[i].g * 150 + ps[i].b * 29) >> 8);
        ps[i].r = y; ps[i].g = y; ps[i].b = y;
        ps[i].w = (uint16_t)(ps[i].w + y);
    }
    int64_t s = 0;
    for (int i = 0; i < N; i++) {
        s += rs[i].a + rs[i].b * 3 + rs[i].c + rs[i].d + (int64_t)(rs[i].e * 4.0f) + rs[i].f % 1000003
           + rs[i].t.kind + rs[i].t.dz;
        s += ps[i].r + ps[i].g * 3 + ps[i].b * 5 + ps[i].pad + ps[i].w;
    }
    printf("%lld %zu %zu\n", (long long)s, sizeof(struct rec), sizeof(struct px));
    return 0;
}
