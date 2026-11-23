#!/bin/bash
# c-musl-threads.sh — a C program that starts threads with pthread_create,
# built static for x86_64-linux-musl (#613). musl's pthread_create answered
# ENOSYS because the static runtime never set up musl's thread state, and the
# program then crashed in pthread_join. Four threads each change their own
# thread-locals (initialised and zero-initialised); the program must print
# what clang's build prints. x86-64 Linux only (where a static musl program
# runs); skipped without clang.
#
#   bash tests/par/c-musl-threads.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then echo "--- c-musl-threads: skipped (x86-64 Linux only) ---"; exit 0; fi
XC=${XC:-bin/linux/xcc-xc}
if ! clang --version >/dev/null 2>&1; then echo "--- c-musl-threads: skipped (no clang) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/par/c-musl-threads/threads.c
fail=0
clang -O2 -pthread -o "$W/ref" "$F" || { echo "FAIL c-musl-threads: clang does not build it"; exit 1; }
want=$("$W/ref")
if "$XC" -q -O2 -H . -A x86_64-linux-musl -o "$W/x" "$F" > "$W/b" 2>&1; then
    got=$(timeout 60 "$W/x" 2>&1)
    [ "$got" = "$want" ] || { echo "FAIL c-musl-threads: gives '$got', clang's '$want'"; fail=1; }
else echo "FAIL c-musl-threads: does not build"; grep -v warning "$W/b" | head -3; fail=1; fi
[ $fail = 0 ] && echo "--- c-musl-threads: pass ---" || echo "--- c-musl-threads: FAIL ---"
exit $fail
