// vecguard.cpp — the overlap guard's range for a std::vector read anywhere
// (tests/par/vec-guard.sh): out[i] is stored and table[] is read through an
// index that depends on its own contents, which no range bounds. The call
// site takes the table's bytes from the vector itself, [data(), data() +
// size()). Each table is 2 KB (512 elements), which no heap registry knows.
#include <cstdio>
#include <vector>

// A gather from a vector: runs as a block where out and table are apart.
__attribute__((noinline)) void gather(const std::vector<unsigned>& table, std::vector<unsigned>& out)
{
    const unsigned* t = table.data();
    for (size_t i = 0; i < out.size(); i++) /* LOOP-VEC */
        out[i] = t[t[i & 511] & 511] * 3u + (unsigned)i;
}

// The same through a struct shaped like a vector that is not one: its
// bytes are not known, so it stays serial.
struct Fake { unsigned* begin; unsigned* end; unsigned* cap; };
__attribute__((noinline)) void gatherFake(const Fake& table, std::vector<unsigned>& out)
{
    const unsigned* t = table.begin;
    for (size_t i = 0; i < out.size(); i++) /* LOOP-FAKE */
        out[i] = t[t[i & 511] & 511] * 3u + (unsigned)i;
}

static unsigned sum(const std::vector<unsigned>& v)
{
    unsigned s = 0;
    for (unsigned x : v)
        s = s * 31u + x;
    return s;
}

int main()
{
    std::vector<unsigned> table(512);
    for (unsigned i = 0; i < 512; i++)
        table[i] = (i * 389u + 17u) % 512u;
    std::vector<unsigned> out(1u << 20);
    gather(table, out);
    unsigned a = sum(out);
    Fake f = {table.data(), table.data() + 512, table.data() + 512};
    gatherFake(f, out);
    unsigned b = sum(out);
    // One vector as both: the gather reads what earlier items wrote, so
    // only a serial run gives this answer.
    std::vector<unsigned> both(table);
    both.resize(4096);
    gather(both, both);
    unsigned c = sum(both);
    std::printf("%u %u %u\n", a, b, c);
    return 0;
}
