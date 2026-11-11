// Exceptions: thrown inside loops and caught outside them, rethrown, nested,
// through a template, a custom exception class with members, noexcept
// functions with loops (xcc's to take) beside the throwing ones.
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

struct Bad : std::runtime_error { int at; Bad(int a) : std::runtime_error("bad"), at(a) {} };

template <typename T> T check(T x, T lim) { if (x > lim) throw Bad((int)x); return x; }

static long scan(const std::vector<int>& v, int lim)
    {
    long s = 0;
    for (size_t i = 0; i < v.size(); i++) s += check(v[i], lim);
    return s;
    }

static long sumAll(const int* p, int n) noexcept { long s = 0; for (int i = 0; i < n; i++) s += p[i]; return s; }

static int nested(int k)
    {
    try
        {
        try { if (k % 2) throw std::out_of_range("odd"); throw std::invalid_argument("even"); }
        catch (const std::out_of_range&) { throw; }
        }
    catch (const std::logic_error& e) { return e.what()[0]; }
    return 0;
    }

int main()
    {
    std::vector<int> v(1000);
    for (int i = 0; i < 1000; i++) v[i] = (i * 7) % 500;
    int caught = 0, at = -1;
    long s1 = 0;
    try { s1 = scan(v, 600); } catch (const Bad& b) { caught++; }
    try { scan(v, 400); } catch (const Bad& b) { caught++; at = b.at; }
    int nest = 0;
    for (int k = 0; k < 10; k++) nest += nested(k);
    std::string msg;
    try { throw std::runtime_error(std::string("x") + std::to_string(42)); } catch (const std::exception& e) { msg = e.what(); }
    std::printf("%ld %d %d %d %ld %s\n", s1, caught, at, nest, sumAll(v.data(), 1000), msg.c_str());
    return 0;
    }
