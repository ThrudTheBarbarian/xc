// baseline — startup only. See baseline.xc.
#include <cstdio>
#include <cstdint>

int main(int argc, char **argv)
    {
    std::printf("%u 0\n", static_cast<uint32_t>(argc));
    return 0;
    }
