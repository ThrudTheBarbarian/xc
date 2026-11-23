// Large results returned through a hidden pointer (sret): a free function's
// struct, a member function's (the win64 Itanium order puts the result
// before `this`), and std::to_string's string, each made in a loop.
#include <cstdio>
#include <string>

struct Vec4 { double x, y, z, w; };

struct Grid {
    double base;
    explicit Grid(double b) : base(b) {}
    Vec4 corner(int i) const { return Vec4{base * i, base + i, base - i, (double)(i * i)}; }
};

static Vec4 scaled(const Vec4& v, double k) { return Vec4{v.x * k, v.y * k, v.z * k, v.w * k}; }

int main()
    {
    Grid g(1.5);
    Vec4 acc{0, 0, 0, 0};
    for (int i = 0; i < 400; i++)
        {
        Vec4 c = scaled(g.corner(i % 37), 0.5);
        acc.x += c.x; acc.y += c.y; acc.z += c.z; acc.w += c.w;
        }
    size_t len = 0;
    for (int i = 0; i < 300; i++)
        len += std::to_string(i * 7).size();
    std::printf("%.2f %.2f %.2f %.2f %zu\n", acc.x, acc.y, acc.z, acc.w, len);
    return 0;
    }
