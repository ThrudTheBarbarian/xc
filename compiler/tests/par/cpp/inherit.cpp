// Multiple and virtual inheritance: a diamond, pointer adjustment between
// bases, virtual calls in a loop, dynamic_cast, and members reached through
// a base reference inside loops.
#include <cstdio>
#include <vector>
#include <memory>

struct Shape { virtual ~Shape() {} virtual double area() const = 0; int id = 0; };
struct Named { virtual ~Named() {} virtual int tag() const { return 1; } char name[8] = "named"; };
struct Rect : Shape, Named { double w, h; Rect(double a, double b) : w(a), h(b) {} double area() const override { return w * h; } int tag() const override { return 2; } };
struct Circle : Shape { double r; explicit Circle(double x) : r(x) {} double area() const override { return 3.25 * r * r; } };

struct Base { int b[16]; Base() { for (int i = 0; i < 16; i++) b[i] = i; } virtual int f() { return b[3]; } };
struct Left : virtual Base { int l = 5; int f() override { return l + b[1]; } };
struct Right : virtual Base { int r = 7; };
struct Diamond : Left, Right { int d[32]; Diamond() { for (int i = 0; i < 32; i++) d[i] = i * r - l; } };

static double totalArea(const std::vector<std::unique_ptr<Shape>>& v)
    {
    double s = 0;
    for (size_t i = 0; i < v.size(); i++) s += v[i]->area();
    return s;
    }

static int tags(Named* const* ns, int n) { int s = 0; for (int i = 0; i < n; i++) s += ns[i]->tag(); return s; }

static int baseSum(Base& b) { int s = 0; for (int i = 0; i < 16; i++) s += b.b[i]; return s; }

int main()
    {
    std::vector<std::unique_ptr<Shape>> v;
    std::vector<Rect*> rects;
    for (int i = 0; i < 200; i++)
        {
        if (i % 3 == 0) v.push_back(std::make_unique<Circle>(i * 0.1));
        else { Rect* r = new Rect(i, 0.5); rects.push_back(r); v.emplace_back(r); }
        }
    std::vector<Named*> ns;
    for (Rect* r : rects) ns.push_back(r);
    int rc = 0;
    for (auto& s : v) if (dynamic_cast<Rect*>(s.get())) rc++;
    Diamond d;
    int ds = 0;
    for (int i = 0; i < 32; i++) ds += d.d[i];
    Base& bb = d;
    std::printf("%.3f %d %d %d %d %d\n", totalArea(v), tags(ns.data(), (int)ns.size()), rc, ds, baseSum(bb), bb.f());
    return 0;
    }
