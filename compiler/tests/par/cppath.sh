#!/bin/bash
# cppath.sh — C++ through the C path: `xcc prog.cpp` has clang++ write the
# LLVM IR, xcc reads the functions with a loop (not the ODR copies: templates,
# inline members, the standard library's code), clang compiles the rest, and
# the program links with libc++. Each program gives clang++'s output; with
# --par-style=auto the plain loops over raw pointers become par blocks, on the
# CPU and (on macOS) the GPU. xcc's own link writes the program, unwind
# tables included (exceptions). Skipped where there is no clang++. macOS
# only for now (libc++). Self-hosted compiler only.
#
#   bash tests/par/cppath.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if [ "$(uname -s)" != Darwin ]; then
    echo "--- cppath: skipped (macOS only) ---"
    exit 0
fi
if ! clang++ --version >/dev/null 2>&1; then
    echo "--- cppath: skipped (no clang++) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
# A static function's loop over std::vector::data(), a member function
# called in a loop, and a struct with a constructor.
cat > "$W/saxpy.cpp" <<'C'
#include <cstdio>
#include <vector>
static void saxpy(float a, const float* x, float* y, int n)
    {
    for (int i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
    }
struct Acc
    {
    double sum = 0;
    void add(double v) { sum += v; }
    };
int main()
    {
    int n = 1 << 20;
    std::vector<float> x(n), y(n);
    for (int i = 0; i < n; i++)
        {
        x[i] = (float)i;
        y[i] = 1.0f;
        }
    saxpy(2.0f, x.data(), y.data(), n);
    Acc acc;
    for (int i = 0; i < n; i++)
        acc.add(y[i]);
    std::printf("%f %f\n", y[12345], acc.sum);
    return 0;
    }
C
# A class whose member function loops over its own arrays (`this`), a
# template instantiated twice (an ODR copy: clang's), a namespace, new[] and
# an exception thrown and caught outside any loop.
cat > "$W/grid.cpp" <<'C'
#include <cstdio>
#include <stdexcept>
namespace sim
    {
    class Grid
        {
    public:
        Grid(int n) : n_(n), a_(new double[n]), b_(new double[n]) {}
        ~Grid() { delete[] a_; delete[] b_; }
        void fill();
        void step(double k);
        double total() const;
    private:
        int n_;
        double* a_;
        double* b_;
        };
    void Grid::fill()
        {
        for (int i = 0; i < n_; i++)
            {
            a_[i] = i * 0.25;
            b_[i] = 0;
            }
        }
    void Grid::step(double k)
        {
        double* a = a_;
        double* b = b_;
        int n = n_;
        for (int i = 0; i < n; i++)
            b[i] = k * a[i] + 1.0;
        }
    double Grid::total() const
        {
        double t = 0;
        for (int i = 0; i < n_; i++)
            t += b_[i];
        return t;
        }
    }
template <typename T> T sumOf(const T* p, int n)
    {
    T s = 0;
    for (int i = 0; i < n; i++)
        s += p[i];
    return s;
    }
static int check(int v)
    {
    if (v < 0)
        throw std::runtime_error("negative");
    return v;
    }
// A loop around a call that throws: the exception passes through this
// frame, so it stays clang's (xcc writes no unwind tables).
static int checkAll(const int* v, int n)
    {
    int s = 0;
    for (int i = 0; i < n; i++)
        s += check(v[i]);
    return s;
    }
int main()
    {
    sim::Grid g(1000000);
    g.fill();
    g.step(3.0);
    int iv[100];
    float fv[100];
    for (int i = 0; i < 100; i++)
        {
        iv[i] = i;
        fv[i] = i * 0.5f;
        }
    int caught = 0;
    try
        {
        check(-1);
        }
    catch (const std::exception& e)
        {
        caught = 1;
        }
    iv[50] = -5;
    try
        {
        caught += checkAll(iv, 100);
        }
    catch (const std::exception& e)
        {
        caught += 10;
        }
    iv[50] = 50;
    std::printf("%.1f %d %.1f %d\n", g.total(), sumOf(iv, 100), sumOf(fv, 100), caught);
    return 0;
    }
C
# Global arrays (clang's, paged for a GPU to share), the loops in a
# namespace's function: the blocks can run on the GPU. Heap memory (new[],
# std::vector) stays on the CPU until the outliner gives a block the extent
# of each pointer it reads and writes, as for C.
cat > "$W/glob.cpp" <<'C'
#include <cstdio>
namespace k
    {
    const int N = 4000000;
    float x[N], y[N];
    void run(float a)
        {
        for (int i = 0; i < N; i++)
            y[i] = a * x[i] + y[i];
        }
    }
int main()
    {
    for (int i = 0; i < k::N; i++)
        {
        k::x[i] = i % 1000;
        k::y[i] = 1.0f;
        }
    k::run(2.0f);
    double t = 0;
    for (int i = 0; i < k::N; i++)
        t += k::y[i];
    std::printf("%.1f\n", t);
    return 0;
    }
C
# Reference parameters (`dereferenceable(N)` in the IR): each argument read
# into its own value. The reader once took the next parameter's name as the
# attribute's operand, and `bump(k, a, n)` read k and a from one argument.
cat > "$W/refs.cpp" <<'C'
#include <cstdio>
static void bump(const double& k, double* a, const int& n, long& count)
    {
    for (int i = 0; i < n; i++)
        a[i] = a[i] * k + 0.5;
    count += n;
    }
int main()
    {
    static double a[1000];
    for (int i = 0; i < 1000; i++)
        a[i] = i;
    double k = 3.0;
    int n = 1000;
    long count = 7;
    bump(k, a, n, count);
    double t = 0;
    for (int i = 0; i < 1000; i++)
        t += a[i];
    std::printf("%.1f %ld\n", t, count);
    return 0;
    }
C
# Loops over std::vector by index: v[i] and v.size() are calls in clang's
# own IR; its -O1 passes (the row's) inline them into the loop and hoist the
# vector's begin and end out of it, so the loop becomes a block. The member
# functions stay out of main, and a function template's loop is clang's.
cat > "$W/vec.cpp" <<'C'
#include <cstdio>
#include <vector>
void saxpy(float a, const std::vector<float>& x, std::vector<float>& y)
    {
    for (size_t i = 0; i < y.size(); i++)
        y[i] = a * x[i] + y[i];
    }
struct Field
    {
    std::vector<double> v;
    explicit Field(size_t n) : v(n) {}
    void scale(double k)
        {
        for (size_t i = 0; i < v.size(); i++)
            v[i] = v[i] * k + 1.0;
        }
    };
template <typename T> void fill(std::vector<T>& v, T k)
    {
    for (size_t i = 0; i < v.size(); i++)
        v[i] = k * (T)i;
    }
int main()
    {
    int n = 1 << 20;
    std::vector<float> x(n), y(n, 1.0f);
    fill(x, 1.0f);
    saxpy(2.0f, x, y);
    Field f(1000);
    for (size_t i = 0; i < f.v.size(); i++)
        f.v[i] = (double)i;
    f.scale(0.5);
    double t = 0;
    for (size_t i = 0; i < f.v.size(); i++)
        t += f.v[i];
    std::printf("%f %f %.1f\n", y[12345], y[n - 1], t);
    return 0;
    }
C
# Loops that count with pointers: a range-for over a vector (its iterator)
# and two pointers stepped together to an end pointer. Both are written
# with a counter from 0 and become blocks.
cat > "$W/iter.cpp" <<'C'
#include <cstdio>
#include <vector>
void scale(std::vector<float>& v, float k)
    {
    for (float& e : v)
        e = e * k + 1.0f;
    }
void addp(float* y, const float* x, const float* end)
    {
    for (const float* p = x; p != end; ++p, ++y)
        *y += *p;
    }
int main()
    {
    std::vector<float> v(1 << 20), w(1 << 20, 1.0f);
    for (size_t i = 0; i < v.size(); i++)
        v[i] = (float)(i % 100);
    scale(v, 3.0f);
    addp(w.data(), v.data(), v.data() + v.size());
    double t = 0;
    for (float e : w)
        t += e;
    std::printf("%f %f %f %.1f\n", v[5], w[7], w[(1 << 20) - 1], t);
    return 0;
    }
C
# A member function defined in its class (an ODR copy, linkonce_odr) is
# taken in a whole-program build, its clang copy kept to fall back on; and
# std::transform over doubles (`call noundef double @llvm.fmuladd.f64`).
cat > "$W/odr.cpp" <<'C'
#include <algorithm>
#include <cstdio>
#include <execution>
#include <vector>
struct Field
    {
    std::vector<double> v;
    explicit Field(size_t n) : v(n, 2.0) {}
    void square()
        {
        std::transform(std::execution::par, v.begin(), v.end(), v.begin(), [](double x) { return x * x + 1.0; });
        }
    };
int main()
    {
    Field f(1 << 16);
    f.square();
    double t = 0;
    for (double x : f.v)
        t += x;
    std::printf("%.1f\n", t);
    return 0;
    }
C
# std::array globals: a range-for (clang's passes count its bytes) and an
# index loop become blocks.
cat > "$W/arr.cpp" <<'C'
#include <array>
#include <cstdio>
static std::array<float, 1 << 16> ga;
std::array<double, 4096> gb;
void arr(float k)
    {
    for (auto& e : ga)
        e = e * k + 1.0f;
    }
void brr()
    {
    for (size_t i = 0; i < gb.size(); i++)
        gb[i] = gb[i] * 0.5 + 1.0;
    }
int main()
    {
    for (size_t i = 0; i < ga.size(); i++)
        ga[i] = (float)(i % 5);
    arr(2.0f);
    brr();
    double t = 0;
    for (float x : ga)
        t += x;
    for (double x : gb)
        t += x;
    std::printf("%.1f\n", t);
    return 0;
    }
C
for p in saxpy grid glob refs vec iter arr; do
    clang++ -std=c++17 -O2 -o "$W/$p.ref" "$W/$p.cpp" 2>/dev/null || { echo "FAIL cppath: clang++ cannot build $p"; fail=1; continue; }
    want=$("$W/$p.ref")
    "$XC" -q -O2 -H . -o "$W/$p" "$W/$p.cpp" > "$W/$p.b" 2>&1 || { echo "FAIL cppath: $p does not build"; head -3 "$W/$p.b"; fail=1; continue; }
    [ "$("$W/$p")" = "$want" ] || { echo "FAIL cppath: $p gives $("$W/$p"), clang++'s $want"; fail=1; }
    XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 --par-style=auto -H . -o "$W/$p.par" "$W/$p.cpp" > "$W/$p.pb" 2>&1 || { echo "FAIL cppath: $p does not build with --par-style=auto"; head -3 "$W/$p.pb"; fail=1; continue; }
    for d in cpu gpu; do
        got=$(XC_PAR=$d "$W/$p.par")
        [ "$got" = "$want" ] || { echo "FAIL cppath: $p's blocks ($d) give $got, clang++'s $want"; fail=1; }
    done
done
# The loops that become blocks: saxpy's, Grid::step's and Grid::fill's.
grep -q 'saxpy.*: outlined, a block' "$W/saxpy.pb" || { echo "FAIL cppath: saxpy's loop did not become a block"; grep outline "$W/saxpy.pb" | head -5; fail=1; }
grep -q 'Grid4step.*: outlined, a block' "$W/grid.pb" || { echo "FAIL cppath: Grid::step's loop did not become a block"; grep outline "$W/grid.pb" | head -5; fail=1; }
grep -q 'checkAll.*: outlined' "$W/grid.pb" && { echo "FAIL cppath: checkAll (a throwing call in its loop) was taken by xcc"; fail=1; }
# grid's exception unwinds through tables xcc's own link wrote (Mach-O:
# __unwind_info from clang's __compact_unwind, the personality by a slot of
# the link's).
nm "$W/grid" | grep -q '__xc_got\$___gxx_personality_v0' || { echo "FAIL cppath: grid was not linked by xcc (no personality slot)"; fail=1; }
otool -l "$W/grid" | grep -q 'sectname __unwind_info' || { echo "FAIL cppath: grid has no __unwind_info"; fail=1; }
grep -q 'saxpy.*vector.*: outlined, a block' "$W/vec.pb" || { echo "FAIL cppath: saxpy over std::vector did not become a block"; grep outline "$W/vec.pb" | head -3; fail=1; }
XC_PAR=cpu XC_PAR_REPORT=1 "$W/vec.par" 2>&1 | grep -q 'vec.cpp:5: .* items on the' || { echo "FAIL cppath: saxpy's block over std::vector did not run"; fail=1; }
for f in _Z3arrf _Z3brrv; do
    grep -q "$f.*: outlined, a block" "$W/arr.pb" || { echo "FAIL cppath: $f (a std::array global) did not become a block"; grep outline "$W/arr.pb" | grep -v '^outline: [A-Z]' | head -3; fail=1; }
done
for f in 'scale.*vector' addp; do
    grep -q "$f.*: outlined, a block" "$W/iter.pb" || { echo "FAIL cppath: the pointer loop in $f did not become a block"; grep outline "$W/iter.pb" | head -3; fail=1; }
done
# The C++17 parallel algorithms (-std=c++17 handed to clang): xcc reads a
# build with libc++'s serial backend, where std::transform and
# std::for_each with std::execution::par are plain loops, and makes blocks
# of them; a body it cannot lift (it calls out of the program) keeps the
# library's own parallel backend, from the normal build. A function whose
# loop is std::fill's (its loop only after inlining) is a block too.
cat > "$W/pol.cpp" <<'C'
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <execution>
#include <vector>
void axpy(float a, const std::vector<float>& x, std::vector<float>& y)
    {
    std::transform(std::execution::par, x.begin(), x.end(), y.begin(), y.begin(),
                   [a](float xi, float yi) { return a * xi + yi; });
    }
void halve(std::vector<float>& y)
    {
    std::for_each(std::execution::par, y.begin(), y.end(), [](float& v) { v = v * 0.5f; });
    }
std::atomic<long> calls{0};
void count(std::vector<float>& y)
    {
    std::for_each(std::execution::par, y.begin(), y.end(), [](float& v) { calls.fetch_add(1); v += 1.0f; });
    }
void zero(std::vector<float>& v)
    {
    std::fill(v.begin(), v.end(), 0.25f);
    }
int main()
    {
    std::vector<float> x(1 << 20), y(1 << 20, 1.0f), z(1000);
    for (size_t i = 0; i < x.size(); i++)
        x[i] = (float)(i % 1000);
    axpy(2.0f, x, y);
    halve(y);
    count(y);
    zero(z);
    double t = 0;
    for (float v : y)
        t += v;
    std::printf("%f %f %.1f %ld %f\n", y[12345], y[(1 << 20) - 1], t, calls.load(), z[999]);
    return 0;
    }
C
clang++ -std=c++17 -fexperimental-library -O2 -o "$W/pol.ref" "$W/pol.cpp" 2>/dev/null
if [ -x "$W/pol.ref" ]; then
    XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 -std=c++17 -H . -o "$W/pol" "$W/pol.cpp" > "$W/pol.b" 2>&1 \
        || { echo "FAIL cppath: the parallel algorithms do not build"; grep -v 'ld: warning' "$W/pol.b" | head -3; fail=1; }
    if [ -x "$W/pol" ]; then
        for d in cpu gpu; do
            got=$(XC_PAR=$d "$W/pol")
            [ "$got" = "$("$W/pol.ref")" ] || { echo "FAIL cppath: the parallel algorithms ($d) give $got, clang++'s $("$W/pol.ref")"; fail=1; }
        done
        clang++ -std=c++17 -fexperimental-library -O2 -o "$W/odr.ref" "$W/odr.cpp" 2>/dev/null
        XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 -std=c++17 -H . -o "$W/odr" "$W/odr.cpp" > "$W/odr.b" 2>&1 || { echo "FAIL cppath: odr.cpp does not build"; fail=1; }
        [ -x "$W/odr" ] && [ "$(XC_PAR=cpu "$W/odr")" = "$("$W/odr.ref")" ] || { echo "FAIL cppath: odr.cpp gives $(XC_PAR=cpu "$W/odr" 2>&1), clang++'s $("$W/odr.ref")"; fail=1; }
        grep -q '_ZN5Field6squareEv.*: outlined, a block' "$W/odr.b" || { echo "FAIL cppath: Field::square (a member defined in its class) did not become a block"; grep outline "$W/odr.b" | grep -v '^outline: [A-Z]' | head -3; fail=1; }
        for f in axpy halve zero; do
            grep -q "_Z[0-9]*$f.*: outlined, a block" "$W/pol.b" || { echo "FAIL cppath: $f's algorithm did not become a block"; grep outline "$W/pol.b" | grep -v '^outline: [A-Z]' | head -4; fail=1; }
        done
        grep -q '_Z5count.*: outlined, a block' "$W/pol.b" && { echo "FAIL cppath: count's body (an atomic) became a block"; fail=1; }
    fi
    # An algorithm xcc reads but makes no block of (its body reads a heap
    # array away from [i] while storing at [i]) calls clang's own version,
    # `<name>_xclib`, with libc++'s parallel backend: never slower than
    # clang++. With nothing lifted (--par-style=cpu) every such one does.
    cat > "$W/fb.cpp" <<'C'
#include <algorithm>
#include <cstdio>
#include <execution>
#include <vector>
void spread(const std::vector<float>& in, std::vector<float>& out)
    {
    const float* src = in.data();
    float* base = out.data();
    size_t n = in.size();
    std::for_each(std::execution::par, out.begin(), out.end(), [=](float& o)
        {
        size_t i = (size_t)(&o - base);
        float s = 0.0f;
        for (size_t j = 0; j < n; j += 97)
            s += src[j] * (float)(i % 13);
        o = s;
        });
    }
int main()
    {
    std::vector<float> in(4096), out(4096);
    for (size_t i = 0; i < in.size(); i++)
        in[i] = (float)(i % 31);
    spread(in, out);
    double t = 0;
    for (float v : out)
        t += v;
    std::printf("%.1f %f\n", t, out[1234]);
    return 0;
    }
C
    clang++ -std=c++17 -fexperimental-library -O2 -o "$W/fb.ref" "$W/fb.cpp" 2>/dev/null
    for ps in auto cpu; do
        XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 --par-style=$ps -std=c++17 -H . -o "$W/fb.$ps" "$W/fb.cpp" > "$W/fb.$ps.b" 2>&1 \
            || { echo "FAIL cppath: fb.cpp ($ps) does not build"; grep -v 'ld: warning' "$W/fb.$ps.b" | head -3; fail=1; continue; }
        [ "$("$W/fb.$ps")" = "$("$W/fb.ref")" ] || { echo "FAIL cppath: fb.cpp ($ps) gives $("$W/fb.$ps"), clang++'s $("$W/fb.ref")"; fail=1; }
        nm "$W/fb.$ps" | grep -q '_Z6spread.*_xclib' || { echo "FAIL cppath: fb.cpp ($ps) has no clang version of spread to fall back on"; fail=1; }
    done
fi
XC_PAR=gpu XC_PAR_REPORT=1 "$W/glob.par" 2>&1 | grep -q 'items on the GPU' || { echo "FAIL cppath: no C++ loop ran on the GPU"; fail=1; }
# A global object's constructor, which clang puts in __TEXT,__StaticInit:
# xcc's Mach-O link reads that code section too (#166).
cat > "$W/gctor.cpp" <<'C'
#include <cstdio>
#include <vector>
struct Table { std::vector<int> v; Table() : v(1000) { for (int i = 0; i < 1000; i++) v[i] = i * 3 % 17; } };
static Table table;
static long sum(const std::vector<int>& v) { long s = 0; for (int x : v) s += x; return s; }
int main() { std::printf("%ld\n", sum(table.v)); return 0; }
C
"$XC" -q -O3 -std=c++17 -H . -o "$W/gctor" "$W/gctor.cpp" > "$W/gctor.b" 2>&1 && [ "$("$W/gctor")" = "7991" ] \
    || { echo "FAIL cppath: a global constructor (__StaticInit) does not link or run"; head -3 "$W/gctor.b"; fail=1; }
# .cc and .cxx are C++ too.
cp "$W/saxpy.cpp" "$W/s2.cc"
"$XC" -q -O2 -H . -o "$W/s2" "$W/s2.cc" > "$W/s2.b" 2>&1 && [ "$("$W/s2")" = "$("$W/saxpy.ref")" ] \
    || { echo "FAIL cppath: a .cc file does not build or run"; head -3 "$W/s2.b"; fail=1; }
# A row from $XC_LANGUAGES: C++ again, under the extension .cu2.
printf '# test row\nc++x | .cu2 | clang++ | -x c++ -O1 -Xclang -disable-llvm-passes -fno-discard-value-names -S -emit-llvm | macos:c++ | loops\n' > "$W/langs"
cp "$W/saxpy.cpp" "$W/s3.cu2"
XC_LANGUAGES="$W/langs" "$XC" -q -O2 -H . -o "$W/s3" "$W/s3.cu2" > "$W/s3.b" 2>&1 && [ "$("$W/s3")" = "$("$W/saxpy.ref")" ] \
    || { echo "FAIL cppath: a row from XC_LANGUAGES does not build"; head -3 "$W/s3.b"; fail=1; }
[ $fail = 0 ] && echo "--- cppath: pass ---" || echo "--- cppath: FAIL ---"
exit $fail
