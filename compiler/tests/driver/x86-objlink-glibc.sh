#!/bin/bash
# x86-objlink-glibc.sh — an x86-64 object link is the dynamic glibc one, as a
# build from source is; -static gives the static musl one (#296)
#
# `xcc -c` compiles for glibc, the default, but an object link used to give a
# static musl image unless -dynamic was named. Where the tree has libRuntime,
# the -c object was compiled against it and still read the canary guard
# directly, so the glibc object link failed ("undefined symbol reached without
# a GOT load: __xt_stack_guard") and the static one missed the classes it left
# to the library. An xc file's -c object now carries its classes and keeps no
# libRuntime, and its link keeps the runtime in the image.
# Checked with both compilers, on any host: a program with a canary, a program
# of two objects and a lifted par loop, each built from source, linked from
# its objects (also with -dynamic), and linked from its objects with -static.
# Each is a glibc dynamic ELF file with ld-linux as its interpreter, except
# the -static link, which is a static one. On x86-64 Linux each runs and
# prints what the build from source prints.
#
#   bash tests/driver/x86-objlink-glibc.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
RUN=0; [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] && RUN=1
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/guard.xc" <<'XC'
#import "Stdio.xc"
u32 fill(u32 n)
    {
    u8 buf[16];
    u8* p = &buf[0];
    for (u32 i in 0..n)
        p[i] = (u8)(i + (u32)1);
    return (u32)buf[n - (u32)1];
    }
i32 main(void)
    {
    Stdio.printf("guard %u\n", fill((u32)12));
    return (i32)0;
    }
XC
cat > "$W/modA.xc" <<'XC'
#import "Stdio.xc"
u32 sumTo(u32 n)
    {
    u32 v[8];
    u32* p = &v[0];
    u32 s = (u32)0;
    for (u32 i in 0..(u32)8)
        p[i] = n * i;
    for (u32 i in 0..(u32)8)
        s = s + v[i];
    return s;
    }
String* label(void) { return String.withCString("two"); }
XC
cat > "$W/modB.xc" <<'XC'
#import "Stdio.xc"
u32 sumTo(u32 n);
String* label(void);
i32 main(void)
    {
    String* s = label();
    s.appendFormat(" %u", sumTo((u32)3));
    Stdio.printf("%s\n", s.cString());
    return (i32)0;
    }
XC
cat > "$W/lifted.xc" <<'XC'
#import "Stdio.xc"
#define N 1048576
float a[N];
i32 main(void)
    {
    for (u32 i = (u32)0; i < (u32)N; i++)
        a[i] = (float)i * 0.5f;
    Stdio.printf("lifted %.1f\n", (double)a[N - 1]);
    return 0;
    }
XC
want_guard="guard 12"; want_two="two 84"; want_lifted="lifted 524287.5"
# The kind of an image: glibc (dynamic, ld-linux), static, or what file says.
kind() {
    local f; f=$(file -b "$1")
    case "$f" in
        *ELF*x86-64*dynamically\ linked*ld-linux-x86-64*) echo glibc ;;
        *ELF*x86-64*statically\ linked*) echo static ;;
        *) echo "other: $f" ;;
    esac
}
check() {   # name image want-kind want-output
    local k; k=$(kind "$2")
    [ "$k" = "$3" ] || { echo "FAIL x86-objlink-glibc: $1 is '$k' (want $3)"; fail=1; return; }
    [ $RUN = 1 ] || return
    local got; got=$("$2" 2>&1)
    [ "$got" = "$4" ] || { echo "FAIL x86-objlink-glibc: $1 prints '$got' (want '$4')"; fail=1; }
}
for c in "$REF" "$XC"; do
    [ -x "$c" ] || { echo "x86-objlink-glibc: $c not built, skipped"; continue; }
    n=$(basename "$c"); D=$W/$n; mkdir -p "$D"
    for p in guard lifted; do
        eval "want=\$want_$p"
        "$c" -q -O2 -A x86_64 "$W/$p.xc" -o "$D/$p-src" > "$D/e" 2>&1 \
            || { echo "FAIL x86-objlink-glibc: $n $p from source: $(head -c 300 "$D/e")"; fail=1; continue; }
        check "$n $p from source" "$D/$p-src" glibc "$want"
        "$c" -q -O2 -A x86_64 -c "$W/$p.xc" -o "$D/$p.o" > "$D/e" 2>&1 \
            || { echo "FAIL x86-objlink-glibc: $n $p -c: $(head -c 300 "$D/e")"; fail=1; continue; }
        "$c" -q -A x86_64 "$D/$p.o" -o "$D/$p-obj" > "$D/e" 2>&1 \
            || { echo "FAIL x86-objlink-glibc: $n $p object link: $(head -c 300 "$D/e")"; fail=1; continue; }
        check "$n $p object link" "$D/$p-obj" glibc "$want"
        "$c" -q -A x86_64 -dynamic "$D/$p.o" -o "$D/$p-dyn" > "$D/e" 2>&1 \
            || { echo "FAIL x86-objlink-glibc: $n $p -dynamic object link: $(head -c 300 "$D/e")"; fail=1; continue; }
        check "$n $p -dynamic object link" "$D/$p-dyn" glibc "$want"
        "$c" -q -A x86_64 -static "$D/$p.o" -o "$D/$p-static" > "$D/e" 2>&1 \
            || { echo "FAIL x86-objlink-glibc: $n $p -static object link: $(head -c 300 "$D/e")"; fail=1; continue; }
        check "$n $p -static object link" "$D/$p-static" static "$want"
    done
    # Two objects, and the same two files built together from source.
    ok=1
    for m in modA modB; do
        "$c" -q -O2 -A x86_64 -c "$W/$m.xc" -o "$D/$m.o" > "$D/e" 2>&1 \
            || { echo "FAIL x86-objlink-glibc: $n $m -c: $(head -c 300 "$D/e")"; fail=1; ok=0; }
    done
    [ $ok = 1 ] || continue
    if "$c" -q -A x86_64 "$D/modA.o" "$D/modB.o" -o "$D/two" > "$D/e" 2>&1; then
        check "$n two objects" "$D/two" glibc "$want_two"
    else
        echo "FAIL x86-objlink-glibc: $n two objects: $(head -c 300 "$D/e")"; fail=1
    fi
    if "$c" -q -A x86_64 -static "$D/modA.o" "$D/modB.o" -o "$D/two-static" > "$D/e" 2>&1; then
        check "$n two objects -static" "$D/two-static" static "$want_two"
    else
        echo "FAIL x86-objlink-glibc: $n two objects -static: $(head -c 300 "$D/e")"; fail=1
    fi
done
[ $fail = 0 ] && echo "x86-objlink-glibc: ok"
exit $fail
