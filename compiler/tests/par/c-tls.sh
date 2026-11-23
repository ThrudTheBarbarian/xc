#!/bin/bash
# c-tls.sh — C and C++ thread-local variables (#611). Four threads each
# change their own copy of an initialised and a zero-initialised thread-local
# (and, in C++, one with a constructor and destructor); the main thread's
# copies stay as they were. Each program is built by xcc as a whole, and the
# C one also with -c and a separate link; each must print what clang's build
# prints. arm64 macOS for now: the ELF and PE linkers' thread-local support
# is still to come (#611). Skipped without clang.
#
#   bash tests/par/c-tls.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ "$(uname -s)" != Darwin ]; then echo "--- c-tls: skipped (arm64 macOS only for now, #611) ---"; exit 0; fi
XC=${XC:-bin/osx/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then echo "--- c-tls: skipped (no clang) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
check() { # name, xcc's binary, clang's binary
    local got want
    want=$("$3" 2>&1); got=$("$2" 2>&1)
    [ "$got" = "$want" ] || { echo "FAIL c-tls: $1 gives '$got', clang's '$want'"; fail=1; }
}
C=tests/par/c-tls/threads.c
CXX=tests/par/c-tls/threads.cpp
clang -O2 -o "$W/ref.c" "$C" || { echo "FAIL c-tls: clang does not build threads.c"; exit 1; }
clang++ -std=c++20 -O2 -o "$W/ref.cpp" "$CXX" || { echo "FAIL c-tls: clang++ does not build threads.cpp"; exit 1; }
if "$XC" -q -O2 -H . -o "$W/x.c" "$C" > "$W/b" 2>&1; then check threads.c "$W/x.c" "$W/ref.c"
else echo "FAIL c-tls: threads.c does not build"; grep -v warning "$W/b" | head -3; fail=1; fi
if "$XC" -q -O2 -H . -c -o "$W/t.o" "$C" > "$W/b" 2>&1 && "$XC" -q -o "$W/x.o" "$W/t.o" >> "$W/b" 2>&1; then check "threads.c (-c, then linked)" "$W/x.o" "$W/ref.c"
else echo "FAIL c-tls: threads.c with -c does not build"; grep -v warning "$W/b" | head -3; fail=1; fi
if "$XC" -q -O2 -H . -o "$W/x.cpp" "$CXX" > "$W/b" 2>&1; then check threads.cpp "$W/x.cpp" "$W/ref.cpp"
else echo "FAIL c-tls: threads.cpp does not build"; grep -v warning "$W/b" | head -3; fail=1; fi
[ $fail = 0 ] && echo "--- c-tls: pass ---" || echo "--- c-tls: FAIL ---"
exit $fail
