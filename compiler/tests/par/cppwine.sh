#!/bin/bash
# cppwine.sh — C++ for win64, linked by xcc's own PE link, run under Wine:
# an exception thrown through clang's frames and caught (typed, catch-all,
# in the same function), a thread_local (libc++abi keeps its exception
# globals in one), a virtual call, a global object's constructor (__main),
# and a loop xcc lifts into a par block next to a throw; then the C++ corpus
# (tests/par/cpp/) against the mingw toolchain's clang++. The program's
# exception directory and TLS directory are xcc's. Skipped without Wine, a
# clang++, or the mingw root's libc++ (/opt/clang/win64).
#
#   bash tests/par/cppwine.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
ROOT=/opt/clang/win64/x86_64-w64-mingw32
if ! command -v wine >/dev/null 2>&1; then echo "--- cppwine: skipped (no wine) ---"; exit 0; fi
if ! clang++ --version >/dev/null 2>&1; then echo "--- cppwine: skipped (no clang++) ---"; exit 0; fi
if [ ! -f "$ROOT/lib/libc++.a" ] || [ ! -d "$ROOT/include/c++/v1" ]; then echo "--- cppwine: skipped (no mingw libc++ at $ROOT) ---"; exit 0; fi
export WINEPREFIX=${WINEPREFIX:-$HOME/.wine-gates} WINEDLLOVERRIDES="winedbg.exe=d" WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/throw.cpp" <<'C'
#include <cstdio>
#include <stdexcept>
__attribute__((noinline)) int deep(int v) { if (v < 0) throw std::runtime_error("neg"); return v; }
__attribute__((noinline)) void five(int v) { if (v < 0) throw 5; }
int main(int argc, char**)
    {
    int a = 0, b = 0, c = 0, d = 0;
    try { deep(-1); } catch (const std::exception& e) { a = 1; }
    try { five(-1); } catch (int e) { b = e; }
    try { five(-1); } catch (...) { c = 3; }
    try { if (argc > 0) throw 7; } catch (int e) { d = e; }
    std::printf("%d %d %d %d\n", a, b, c, d);
    return 0;
    }
C
cat > "$W/misc.cpp" <<'C'
#include <cstdio>
#include <new>
thread_local int tv = 41;
struct B { virtual int f() = 0; virtual ~B() {} };
struct D : B { int v; D(int x) : v(x) {} int f() override { return v * 3; } };
__attribute__((noinline)) int call(B* b) { return b->f(); }
struct G { int n; G() : n(9) {} };
G g;
alignas(16) static char buf[64];
int main() { tv++; B* b = new (buf) D(7); std::printf("%d %d %d\n", tv, call(b), g.n); return 0; }
C
cat > "$W/lift.cpp" <<'C'
#include <cstdio>
#include <stdexcept>
#include <vector>
__attribute__((noinline)) int deep(int v) { if (v < 0) throw std::runtime_error("neg"); return v * 2; }
void scale(std::vector<float>& v, float k) { for (size_t i = 0; i < v.size(); i++) v[i] = v[i] * k + 1.0f; }
int main() { std::vector<float> v(1 << 16, 2.0f); scale(v, 3.0f); int c = 0; try { deep(-1); } catch (const std::exception& e) { c = 1; } std::printf("%d %f\n", c, v[7]); return 0; }
C
check() { # name, want
    "$XC" -q -O2 -A win64 -H . -o "$W/$1.exe" "$W/$1.cpp" > "$W/$1.b" 2>&1 \
        || { echo "FAIL cppwine: $1 does not build"; grep -v 'warning\|In file\|^ *[0-9]* |\|^ *|' "$W/$1.b" | head -3; fail=1; return; }
    got=$(XC_PAR=cpu timeout 60 wine "$W/$1.exe" 2>/dev/null | tr -d '\r')
    [ "$got" = "$2" ] || { echo "FAIL cppwine: $1 gives '$got', want '$2'"; fail=1; }
}
check throw "1 5 3 7"
check misc "42 21 9"
check lift "1 7.000000"
# The C++ corpus (tests/par/cpp/), each program against the mingw
# toolchain's clang++ where it is there to build the reference.
REF=${ROOT%/x86_64-w64-mingw32}/bin/x86_64-w64-mingw32-clang++
if [ -x "$REF" ]; then
    for f in tests/par/cpp/*.cpp; do
        b=$(basename "$f" .cpp)
        "$REF" -std=c++20 -O2 -w -fexperimental-library -o "$W/c_$b.ref.exe" "$f" > "$W/c_$b.rb" 2>&1 \
            || { echo "FAIL cppwine: corpus $b: the mingw clang++ does not build it"; head -3 "$W/c_$b.rb"; fail=1; continue; }
        "$XC" -q -O3 -std=c++20 -A win64 -H . -o "$W/c_$b.exe" "$f" > "$W/c_$b.b" 2>&1 \
            || { echo "FAIL cppwine: corpus $b does not build"; grep -v 'warning\|In file\|^ *[0-9]* |\|^ *|' "$W/c_$b.b" | head -3; fail=1; continue; }
        want=$(timeout 120 wine "$W/c_$b.ref.exe" 2>/dev/null | tr -d '\r')
        got=$(XC_PAR=cpu timeout 120 wine "$W/c_$b.exe" 2>/dev/null | tr -d '\r')
        [ "$got" = "$want" ] || { echo "FAIL cppwine: corpus $b gives '$got', clang++'s '$want'"; fail=1; }
    done
else
    echo "cppwine: the corpus skipped (no $REF)"
fi
[ $fail = 0 ] && echo "--- cppwine: pass ---" || echo "--- cppwine: FAIL ---"
exit $fail
