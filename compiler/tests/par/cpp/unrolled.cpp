// A reduction unrolled by hand the way libstdc++ writes std::reduce and
// std::transform_reduce (four elements folded one after another a pass,
// then the rest one at a time): xcc writes it back as one element a pass
// and makes a block of it. Integer and float sums, and a transform.
#include <cstdio>
#include <vector>
template <class It, class T> T red(It first, It last, T init)
    {
    while ((last - first) >= 4)
        {
        T v1 = init + first[0];
        T v2 = v1 + first[1];
        T v3 = v2 + first[2];
        init = v3 + first[3];
        first += 4;
        }
    for (; first != last; ++first) init = init + *first;
    return init;
    }
static unsigned sumU(const std::vector<unsigned>& v) { return red(v.data(), v.data() + v.size(), 0u); }
static double sumD(const std::vector<double>& v) { return red(v.data(), v.data() + v.size(), 0.0); }
template <class It, class T, class F> T tred(It first, It last, T init, F f)
    {
    while ((last - first) >= 4)
        {
        T v1 = init + f(first[0]);
        T v2 = v1 + f(first[1]);
        T v3 = v2 + f(first[2]);
        init = v3 + f(first[3]);
        first += 4;
        }
    for (; first != last; ++first) init = init + f(*first);
    return init;
    }
static long sq(const std::vector<int>& v) { return tred(v.data(), v.data() + v.size(), 0L, [](int x) { return (long)x * x; }); }
int main()
    {
    std::vector<unsigned> u(100003); std::vector<double> d(77777); std::vector<int> w(5003);
    for (size_t i = 0; i < w.size(); i++) w[i] = (int)(i % 211) - 105;
    for (size_t i = 0; i < u.size(); i++) u[i] = (unsigned)(i * 2654435761u >> 9);
    for (size_t i = 0; i < d.size(); i++) d[i] = 1.0 / (double)(i + 1);
    std::printf("%u %.17g %ld\n", sumU(u), sumD(d), sq(w));
    return 0;
    }
