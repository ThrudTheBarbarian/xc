// Operator overloading on small value types passed and returned by value
// (a 3-vector, a complex number, a 2x2 matrix), summed over arrays.
#include <cstdio>
#include <cmath>

struct V3 { float x, y, z; };
static inline V3 operator+(V3 a, V3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
static inline V3 operator*(V3 a, float k) { return {a.x * k, a.y * k, a.z * k}; }
static inline float dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

struct Cx { double re, im; };
static inline Cx operator*(Cx a, Cx b) { return {a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re}; }
static inline Cx operator+(Cx a, Cx b) { return {a.re + b.re, a.im + b.im}; }
static inline bool operator==(Cx a, Cx b) { return a.re == b.re && a.im == b.im; }

struct M2 { int a, b, c, d; M2 operator*(const M2& o) const { return {a * o.a + b * o.c, a * o.b + b * o.d, c * o.a + d * o.c, c * o.b + d * o.d}; } };

static V3 pts[2048];
static Cx zs[1024];

int main()
    {
    for (int i = 0; i < 2048; i++) pts[i] = V3{(float)i, (float)(i % 13), 1.0f - (float)i * 0.001f};
    V3 acc{0, 0, 0};
    for (int i = 0; i < 2048; i++) acc = acc + pts[i] * 0.5f;
    float d = 0;
    for (int i = 0; i < 2048; i++) d += dot(pts[i], V3{1, 2, 3});
    for (int i = 0; i < 1024; i++) zs[i] = Cx{i * 0.001, -i * 0.002};
    Cx z{0, 0};
    for (int i = 0; i < 1024; i++) z = z * Cx{0.999, 0.001} + zs[i];
    M2 m{1, 1, 1, 0}, r{1, 0, 0, 1};
    for (int i = 0; i < 30; i++) r = r * m;
    int eq = 0;
    for (int i = 0; i < 1024; i++) if (zs[i] == Cx{i * 0.001, -i * 0.002}) eq++;
    std::printf("%.2f %.2f %.2f %.2f %.6f %.6f %d %d\n", acc.x, acc.y, acc.z, d, z.re, z.im, r.b, eq);
    return 0;
    }
