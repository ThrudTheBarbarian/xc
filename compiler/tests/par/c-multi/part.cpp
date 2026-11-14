// The C++ part: a static helper of the same name as main.cpp's, other strings.
#include <string>
#include <vector>
static long scale(long x) { return x * 5 + 1; }
long partTotal(const std::vector<long>& v)
{
    long s = 0;
    for (long x : v)
        s += scale(x);
    return s;
}
std::string partName() { return std::string("multi") + "-file"; }
