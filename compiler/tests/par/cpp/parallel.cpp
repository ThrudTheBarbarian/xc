// The standard parallel algorithms (std::execution): for_each, transform,
// reduce and transform_reduce with par and par_unseq, over vectors.
#include <cstdio>
#include <vector>
#include <numeric>
#include <algorithm>
#include <execution>

int main()
    {
    const size_t n = 1 << 16;
    std::vector<float> x(n), y(n);
    for (size_t i = 0; i < n; i++) { x[i] = (float)(i % 1000) * 0.001f; y[i] = 1.0f; }
    std::transform(std::execution::par_unseq, x.begin(), x.end(), y.begin(), y.begin(), [](float a, float b) { return 2.0f * a + b; });
    std::vector<unsigned> u(n);
    std::for_each(std::execution::par, u.begin(), u.end(), [&](unsigned& e) { e = (unsigned)(&e - u.data()) * 2654435761u >> 7; });
    unsigned us = std::reduce(std::execution::par, u.begin(), u.end(), 0u);
    double dot = std::transform_reduce(std::execution::par_unseq, x.begin(), x.end(), y.begin(), 0.0);
    long cnt = std::count_if(std::execution::par, y.begin(), y.end(), [](float v) { return v > 2.0f; });
    std::printf("%u %.3f %ld %.3f\n", us, dot, cnt, (double)y[n / 3]);
    return 0;
    }
