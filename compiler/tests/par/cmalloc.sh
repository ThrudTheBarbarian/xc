#!/bin/bash
# cmalloc.sh — a C program's blocks of 64 KB and more come from xcc's heap
# (CAlloc.xc), so par can tell its arrays apart, and memory still passes
# freely between the program and C libraries (#235).
#
# c-malloc/roundtrip.c: a large buffer getline reallocs, strdup's and
# asprintf's memory, and large blocks a linked library and a dlopen()ed one
# realloc, size and free; it gives clang's answer. On Linux the executable
# exports free, realloc and malloc_usable_size and no other definition.
# c-malloc/stress.c: threads allocating, growing and freeing blocks large and
# small while the main thread's lifted gather runs as a block over two large
# ones; clang's answer with XC_PAR_THREADS of 1 and 16. A program with its own
# allocator keeps it; a program of two C files runs its loop as a block; a
# C++ program's new[] arrays are the heap's too.
# Skipped where there is no clang. Self-hosted compiler only.
#
#   bash tests/par/cmalloc.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version > /dev/null 2>&1; then
    echo "--- cmalloc: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
D=tests/par/c-malloc
fail=0
if [ "$PLAT" = osx ]; then
    LIB=$W/libfree.dylib
    clang -O2 -dynamiclib -install_name @rpath/libfree.dylib -o "$LIB" $D/libfree.c || { echo "FAIL cmalloc: libfree"; exit 1; }
    export DYLD_LIBRARY_PATH=$W
else
    LIB=$W/libfree.so
    clang -O2 -shared -fPIC -Wl,-soname,libfree.so -o "$LIB" $D/libfree.c || { echo "FAIL cmalloc: libfree"; exit 1; }
    export LD_LIBRARY_PATH=$W
fi
# One line of 200000 bytes, longer than roundtrip's 64 KB buffer.
awk 'BEGIN { for (i = 0; i < 200000; i++) printf "%c", 97 + i % 26; printf "\n" }' > "$W/line.txt"
clang -O2 -w -o "$W/rt.ref" $D/roundtrip.c -L"$W" -lfree -Wl,-rpath,"$W" || { echo "FAIL cmalloc: clang does not build roundtrip.c"; exit 1; }
want=$("$W/rt.ref" "$W/line.txt" "$LIB")
"$XC" -q -O2 -H . -o "$W/rt" $D/roundtrip.c -L"$W" -lfree > "$W/rt.b" 2>&1 || { echo "FAIL cmalloc: roundtrip.c does not build"; head -5 "$W/rt.b"; exit 1; }
got=$("$W/rt" "$W/line.txt" "$LIB" 2>&1)
if [ "$got" = "$want" ]; then echo "  ok: roundtrip gives clang's answer"
else echo "  FAIL: roundtrip gives"; echo "$got" | sed 's/^/    /'; echo "  clang's:"; echo "$want" | sed 's/^/    /'; fail=1; fi
# The executable's own dynamic definitions: free, realloc and
# malloc_usable_size, nothing else.
if [ "$PLAT" = linux ] && command -v nm > /dev/null; then
    defs=$(nm -D --defined-only "$W/rt" | awk 'NF == 3 { print $3 }' | sort | tr '\n' ' ')
    [ "$defs" = "free malloc_usable_size realloc " ] && echo "  ok: exports $defs" \
        || { echo "  FAIL: the executable exports '$defs' (want free malloc_usable_size realloc)"; fail=1; }
fi
clang -O2 -w -o "$W/st.ref" $D/stress.c -lpthread || { echo "FAIL cmalloc: clang does not build stress.c"; exit 1; }
want=$("$W/st.ref" 8)
"$XC" -q -O3 -H . -o "$W/st" $D/stress.c > "$W/st.b" 2>&1 || { echo "FAIL cmalloc: stress.c does not build"; head -5 "$W/st.b"; exit 1; }
for t in 1 16; do
    XC_PAR=cpu XC_PAR_THREADS=$t XC_PAR_REPORT=1 "$W/st" 8 > "$W/st.$t" 2>&1
    got=$(grep -v '^par: ' "$W/st.$t" | tail -1)
    [ "$got" = "$want" ] || { echo "  FAIL: stress with XC_PAR_THREADS=$t gives $got, clang's $want"; fail=1; continue; }
    runs=$(grep -c 'stress.c:15: [0-9]* items on' "$W/st.$t")
    [ "$runs" -gt 0 ] && echo "  ok: stress with XC_PAR_THREADS=$t ($got; the gather ran as a block $runs times)" \
        || { echo "  FAIL: stress with XC_PAR_THREADS=$t: the gather never ran as a block"; grep 'stress.c' "$W/st.$t" | head -3; fail=1; }
done
# A program that defines its own malloc, calloc, realloc and free keeps them,
# in one file or as a second object: its blocks are its pool's, nothing is
# renamed, and (Linux) the executable exports nothing. The pool is a global of
# 64 KB and more, which the runtime knows as one block, and its arrays are
# pointers into it (cpool.sh runs it on the GPU too).
# Each with the target's libRuntime, when one is built, and without it.
RL=$( [ "$PLAT" = osx ] && echo support/runtime-lib/arm64-macos/libRuntime.dylib || echo support/runtime-lib/x86_64-linux/libRuntime.so )
links="--no-runtime-lib"
[ -f "$RL" ] && links="libRuntime --no-runtime-lib"
clang -O2 -w -DOWN_HEAP_HERE -o "$W/own.ref" $D/ownmain.c || { echo "FAIL cmalloc: clang does not build ownmain.c"; exit 1; }
wantown=$("$W/own.ref")
clang -O2 -w -o "$W/two.ref" $D/twoloop.c $D/twoalloc.c || { echo "FAIL cmalloc: clang does not build twoloop.c"; exit 1; }
wanttwo=$("$W/two.ref")
for link in $links; do
    opt=""
    [ "$link" = libRuntime ] || opt=$link
    for shape in one two; do
        if [ $shape = one ]; then
            "$XC" -q -O2 -H . $opt -DOWN_HEAP_HERE -o "$W/own.$shape" $D/ownmain.c > "$W/own.b" 2>&1
        else
            "$XC" -q -O2 -H . $opt -o "$W/own.$shape" $D/ownmain.c $D/ownheap.c > "$W/own.b" 2>&1
        fi
        [ $? = 0 ] || { echo "  FAIL: own allocator ($shape, $link) does not build"; head -5 "$W/own.b"; fail=1; continue; }
        mkdir -p "$W/home.$shape.$link"
        got=$(HOME="$W/home.$shape.$link" "$W/own.$shape" 2>&1)
        [ "$got" = "$wantown" ] && echo "  ok: own allocator ($shape object(s), $link) gives clang's answer ($got)" \
            || { echo "  FAIL: own allocator ($shape, $link) gives '$got', clang's '$wantown'"; fail=1; }
        if [ "$PLAT" = linux ] && command -v nm > /dev/null; then
            defs=$(nm -D --defined-only "$W/own.$shape" | awk 'NF == 3 { print $3 }' | tr '\n' ' ')
            [ -z "$defs" ] || { echo "  FAIL: own allocator ($shape, $link): the executable exports '$defs'"; fail=1; }
        fi
    done
    # A program of two C files: one allocates the arrays, the other's lifted
    # loop runs over them as a block.
    if "$XC" -q -O3 -H . $opt -o "$W/two" $D/twoloop.c $D/twoalloc.c > "$W/two.b" 2>&1; then
        XC_PAR=cpu XC_PAR_REPORT=1 "$W/two" > "$W/two.r" 2>&1
        got=$(grep -v '^par: ' "$W/two.r" | tail -1)
        runs=$(grep -c 'twoloop.c:9: [0-9]* items on' "$W/two.r")
        if [ "$got" != "$wanttwo" ]; then echo "  FAIL: two files ($link) give $got, clang's $wanttwo"; fail=1
        elif [ "$runs" != 1 ]; then echo "  FAIL: two files ($link): the loop ran as a block $runs times (want 1)"; grep twoloop "$W/two.r" | head -3; fail=1
        else echo "  ok: two files ($link) give clang's answer ($got), the loop as a block"; fi
    else
        echo "  FAIL: twoloop.c twoalloc.c ($link) do not build"; head -5 "$W/two.b"; fail=1
    fi
done
# C++: operator new and delete go through the heap too. The program's first
# allocation is an operator new, and its loop over new[] arrays runs as a block.
if clang++ --version > /dev/null 2>&1; then
    clang++ -O2 -w -o "$W/cxx.ref" $D/cxxnew.cpp || { echo "FAIL cmalloc: clang++ does not build cxxnew.cpp"; exit 1; }
    wantcxx=$("$W/cxx.ref")
    for link in $links; do
        opt=""
        [ "$link" = libRuntime ] || opt=$link
        if "$XC" -q -O3 -H . $opt -o "$W/cxx" $D/cxxnew.cpp > "$W/cxx.b" 2>&1; then
            XC_PAR=cpu XC_PAR_REPORT=1 "$W/cxx" > "$W/cxx.r" 2>&1
            got=$(grep -v '^par: ' "$W/cxx.r" | tail -1)
            runs=$(grep -c 'cxxnew.cpp:9: [0-9]* items on' "$W/cxx.r")
            if [ "$got" != "$wantcxx" ]; then echo "  FAIL: C++ ($link) gives '$got', clang++'s '$wantcxx'"; fail=1
            elif [ "$runs" != 1 ]; then echo "  FAIL: C++ ($link): the loop ran as a block $runs times (want 1)"; grep cxxnew "$W/cxx.r" | head -3; fail=1
            else echo "  ok: C++ ($link) gives clang++'s answer ($got), the loop over new[] arrays as a block"; fi
        else
            echo "  FAIL: cxxnew.cpp ($link) does not build"; head -5 "$W/cxx.b"; fail=1
        fi
    done
fi
[ $fail = 0 ] && echo "--- cmalloc: pass ---" || echo "--- cmalloc: FAIL ---"
exit $fail
