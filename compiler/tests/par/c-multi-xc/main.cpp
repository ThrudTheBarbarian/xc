// main.cpp — a C++ file calling an xc file and a C file, built in one
// command (tests/par/cpp-multifile.sh).
#include <cstdio>
#include <vector>
extern "C" int xc_twice(int v);
extern "C" int c_add(int a, int b);
int main()
{
    std::vector<int> v(4096);
    for (size_t i = 0; i < v.size(); i++)
        v[i] = xc_twice((int)(i % 10));
    int s = 0;
    for (int x : v)
        s = c_add(s, x);
    std::printf("%d\n", s);
    return 0;
}
