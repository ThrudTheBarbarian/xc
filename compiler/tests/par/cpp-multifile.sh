#!/bin/bash
# cpp-multifile.sh — a C/C++ program of several files: tests/par/c-multi's
# main.cpp, part.cpp and csum.c, built in one command and as each `xcc -c`
# with the objects linked by xcc
# with no framework or library named (each object asks for what it needs:
# LC_LINKER_OPTION on macOS, .deplibs on Linux; every object shares one
# libRuntime), give clang++'s answer. The three files' static helpers share a
# name and stay apart. Skipped without clang++.
#
#   bash tests/par/cpp-multifile.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then
    echo "--- cpp-multifile: skipped (no clang++) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D=tests/par/c-multi
clang -O2 -c -o "$W/csum.ref.o" "$D/csum.c" && clang++ -std=c++17 -O2 -o "$W/ref" "$D/main.cpp" "$D/part.cpp" "$W/csum.ref.o" \
    || { echo "FAIL cpp-multifile: clang++ does not build it"; exit 1; }
want=$("$W/ref")
for f in main.cpp part.cpp csum.c; do
    std=""; case "$f" in *.cpp) std="-std=c++17";; esac
    "$XC" -q -O3 $std -H . -c -o "$W/${f%.*}.o" "$D/$f" > "$W/b.$f" 2>&1 \
        || { echo "FAIL cpp-multifile: $f does not build"; grep -v warning "$W/b.$f" | head -3; exit 1; }
done
"$XC" -q -O3 -H . -o "$W/x" "$W/main.o" "$W/part.o" "$W/csum.o" > "$W/bl" 2>&1 \
    || { echo "FAIL cpp-multifile: the objects do not link"; head -3 "$W/bl"; exit 1; }
fail=0
got=$("$W/x")
[ "$got" = "$want" ] || { echo "FAIL cpp-multifile: the objects' program gives '$got', clang++'s '$want'"; fail=1; }
# The same in one command: `xcc main.cpp part.cpp csum.c -o prog`.
"$XC" -q -O3 -std=c++17 -H . -o "$W/one" "$D/main.cpp" "$D/part.cpp" "$D/csum.c" > "$W/bo" 2>&1 \
    || { echo "FAIL cpp-multifile: the one-command build fails"; grep -v warning "$W/bo" | head -3; fail=1; }
got=$("$W/one" 2>&1)
[ "$got" = "$want" ] || { echo "FAIL cpp-multifile: the one-command program gives '$got', clang++'s '$want'"; fail=1; }
[ $fail = 0 ] && echo "--- cpp-multifile: pass ---" || echo "--- cpp-multifile: FAIL ---"
exit $fail
