#!/bin/bash
# cppath.sh — C++ through the C path: `xcc prog.cpp` has clang++ write the
# LLVM IR, xcc reads the functions with a loop (not the ODR copies: templates,
# inline members, the standard library's code), clang compiles the rest, and
# the program links with libc++. Each program gives clang++'s output; with
# --par-style=auto the plain loops over raw pointers become par blocks, on the
# CPU and (on macOS) the GPU. Skipped where there is no clang++. macOS only
# for now (libc++). Self-hosted compiler only.
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
for p in saxpy grid glob; do
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
XC_PAR=gpu XC_PAR_REPORT=1 "$W/glob.par" 2>&1 | grep -q 'items on the GPU' || { echo "FAIL cppath: no C++ loop ran on the GPU"; fail=1; }
# .cc and .cxx are C++ too.
cp "$W/saxpy.cpp" "$W/s2.cc"
"$XC" -q -O2 -H . -o "$W/s2" "$W/s2.cc" > "$W/s2.b" 2>&1 && [ "$("$W/s2")" = "$("$W/saxpy.ref")" ] \
    || { echo "FAIL cppath: a .cc file does not build or run"; head -3 "$W/s2.b"; fail=1; }
# A row from $XC_LANGUAGES: C++ again, under the extension .cu2.
printf '# test row\nc++x | .cu2 | clang++ | -x c++ -O1 -Xclang -disable-llvm-passes -fno-discard-value-names -S -emit-llvm | macos:c++ | loops | clang++\n' > "$W/langs"
cp "$W/saxpy.cpp" "$W/s3.cu2"
XC_LANGUAGES="$W/langs" "$XC" -q -O2 -H . -o "$W/s3" "$W/s3.cu2" > "$W/s3.b" 2>&1 && [ "$("$W/s3")" = "$("$W/saxpy.ref")" ] \
    || { echo "FAIL cppath: a row from XC_LANGUAGES does not build"; head -3 "$W/s3.b"; fail=1; }
[ $fail = 0 ] && echo "--- cppath: pass ---" || echo "--- cppath: FAIL ---"
exit $fail
