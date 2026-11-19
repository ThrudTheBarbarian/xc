#!/bin/bash
# cpp-object-repro.sh — the same C++ source built with -c twice gives the same
# object (#429). Apple's ld, combining xcc's half with clang's, wrote an
# N_OSO debug-map entry naming clang's object in the run's scratch directory,
# with its modification time, so every build differed. The object names it
# without the scratch path, with time 0.
#
#   bash tests/driver/cpp-object-repro.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
XC=${XC:-bin/osx/xcc-xc}; case $XC in /*) ;; *) XC="$ROOT/$XC";; esac
[ "$(uname -s)" = Darwin ] || { echo "cpp-object-repro: skipped (macOS only)"; exit 0; }
command -v clang > /dev/null || { echo "cpp-object-repro: skipped (no clang)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
printf '#include <cstdio>\nstruct A { int v; A(int x) : v(x) {} int twice() const { return v * 2; } };\nint main() { A a(21); std::printf("%%d\\n", a.twice()); return 0; }\n' > "$W/t.cpp"
fail=0
for O in O0 O2; do
    ( cd "$W" && "$XC" -q -$O -H "$ROOT" -c -o a.o t.cpp ) > "$W/e" 2>&1 || { echo "FAIL cpp-object-repro -$O: no object: $(head -c 200 "$W/e")"; fail=1; continue; }
    sleep 1
    ( cd "$W" && "$XC" -q -$O -H "$ROOT" -c -o b.o t.cpp ) > "$W/e" 2>&1 || { echo "FAIL cpp-object-repro -$O: no second object"; fail=1; continue; }
    cmp -s "$W/a.o" "$W/b.o" || { echo "FAIL cpp-object-repro -$O: two builds give different objects"; fail=1; }
    strings -a "$W/a.o" | grep -q "xcc-[A-Za-z0-9]\{6\}" && { echo "FAIL cpp-object-repro -$O: the object names the scratch directory"; fail=1; }
done
[ $fail = 0 ] && echo "cpp-object-repro: ok"
exit $fail
