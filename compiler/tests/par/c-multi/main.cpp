// A program of three files, C++ and C, each compiled with -c and the objects
// linked by xcc with nothing named: main.cpp and part.cpp each have a static
// helper called scale and string literals of their own, which must stay
// apart (each file's internal names carry its own suffix), and every object
// shares one xcc runtime (libRuntime).
#include <cstdio>
#include <string>
#include <vector>
long partTotal(const std::vector<long>& v);
std::string partName();
extern "C" long cSum(const long* a, long n);
static long scale(long x) { return x * 3; }
int main()
{
    std::vector<long> v(1000);
    for (size_t i = 0; i < v.size(); i++)
        v[i] = scale((long)i);
    std::printf("%s %ld %ld %s\n", partName().c_str(), partTotal(v), cSum(v.data(), (long)v.size()), "main");
    return 0;
}
