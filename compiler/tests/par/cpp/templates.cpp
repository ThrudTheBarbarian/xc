// Function and class templates, a variadic one, a specialisation and
// constexpr, each with a loop over its own storage.
#include <cstdio>
#include <cstdint>

template <typename T, int N>
struct Buf
    {
    T v[N];
    void fill(T start, T step) { for (int i = 0; i < N; i++) v[i] = start + step * (T)i; }
    T sum() const { T s = 0; for (int i = 0; i < N; i++) s += v[i]; return s; }
    template <typename F> void apply(F f) { for (int i = 0; i < N; i++) v[i] = f(v[i]); }
    };

template <typename T>
T dot(const T* a, const T* b, int n) { T s = 0; for (int i = 0; i < n; i++) s += a[i] * b[i]; return s; }

template <typename T> struct Scale { static T by(T x) { return x * 2; } };
template <> struct Scale<uint8_t> { static uint8_t by(uint8_t x) { return (uint8_t)(x << 1 | 1); } };

template <typename T, int N>
void scaleAll(Buf<T, N>& b) { for (int i = 0; i < N; i++) b.v[i] = Scale<T>::by(b.v[i]); }

constexpr int tri(int n) { int s = 0; for (int i = 1; i <= n; i++) s += i; return s; }

template <typename... Ts> long total(Ts... xs) { long s = 0; ((s += (long)xs), ...); return s; }

int main()
    {
    Buf<int, 1000> bi; bi.fill(3, 7);
    Buf<double, 512> bd; bd.fill(0.5, 0.25);
    Buf<uint8_t, 300> bu; bu.fill(1, 3);
    scaleAll(bi); scaleAll(bd); scaleAll(bu);
    bi.apply([](int x) { return x % 97; });
    static_assert(tri(10) == 55, "constexpr");
    double a[256], b[256];
    for (int i = 0; i < 256; i++) { a[i] = i * 0.5; b[i] = 256 - i; }
    unsigned bus = 0;
    for (int i = 0; i < 300; i++) bus += bu.v[i];
    std::printf("%d %.3f %u %.3f %ld %d\n", bi.sum(), bd.sum(), bus, dot(a, b, 256), total(1, 2L, 3u, (short)4), tri(20));
    return 0;
    }
