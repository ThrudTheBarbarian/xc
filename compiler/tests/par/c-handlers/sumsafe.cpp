// A loop around a try with two catches (a class hierarchy, an int) and the
// cleanup clang adds: on arm64 macOS xcc compiles sumsafe, handlers and all.
#include <cstdio>
#include <stdexcept>
__attribute__((noinline)) int check(int x) { if (x % 7 == 3) throw std::runtime_error("bad"); if (x % 11 == 5) throw 42; return x * 2; }
__attribute__((noinline)) long sumsafe(int n)
{
    long s = 0;
    for (int i = 0; i < n; i++) {
        try { s += check(i); }
        catch (const std::exception&) { s -= 1; }
        catch (int k) { s += k; }
    }
    return s;
}
int main() { std::printf("%ld\n", sumsafe(100)); return 0; }
