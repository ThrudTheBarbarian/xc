// Lambdas: captures by value and by reference, a generic lambda, one held
// in std::function, and the standard algorithms driven by them.
#include <cstdio>
#include <vector>
#include <algorithm>
#include <numeric>
#include <functional>

static void each(std::vector<float>& v, const std::function<float(float)>& f) { for (auto& x : v) x = f(x); }

int main()
    {
    std::vector<float> v(5000);
    for (size_t i = 0; i < v.size(); i++) v[i] = (float)(i % 101) * 0.5f;
    float k = 1.5f, add = 2.0f;
    std::transform(v.begin(), v.end(), v.begin(), [k, add](float x) { return x * k + add; });
    int big = 0;
    std::for_each(v.begin(), v.end(), [&big](float x) { if (x > 50.0f) big++; });
    auto sq = [](auto x) { return x * x; };
    double s2 = 0;
    for (float x : v) s2 += sq((double)x);
    each(v, [](float x) { return x - 1.0f; });
    std::vector<int> idx(v.size());
    std::iota(idx.begin(), idx.end(), 0);
    std::sort(idx.begin(), idx.end(), [&](int a, int b) { return v[a] != v[b] ? v[a] > v[b] : a < b; });
    long w = 0;
    for (int i = 0; i < 10; i++) w = w * 31 + idx[i];
    int cnt = (int)std::count_if(v.begin(), v.end(), [](float x) { return x < 10.0f; });
    float mx = *std::max_element(v.begin(), v.end());
    std::printf("%d %.3f %ld %d %.3f %.3f\n", big, s2, w, cnt, mx, std::accumulate(v.begin(), v.end(), 0.0));
    return 0;
    }
