// A byte histogram: clang reads `d[i] >> 4` as `lshr i8`, which must
// zero-extend the byte before the shift (bytes of 128 and up indexed far
// past h, on the stack, when it did not).
#include <cstdio>
#include <cstdint>
#include <vector>
static void hist(const uint8_t* d, int n, unsigned* h) { for (int i = 0; i < n; i++) h[d[i] >> 4]++; }
int main()
    {
    std::vector<uint8_t> d(10000); unsigned h[16] = {0};
    for (int i = 0; i < 10000; i++) d[i] = (uint8_t)(i * 31);
    hist(d.data(), 10000, h);
    unsigned m = 0; for (int i = 0; i < 10000; i++) if (d[i] > m) m = d[i];
    for (int i = 0; i < 16; i++) std::printf("%u ", h[i]);
    std::printf("| max %u\n", m);
    return 0;
    }
