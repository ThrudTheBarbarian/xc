#!/bin/bash
# arm64-linux-objects.sh — separate compilation for the aarch64 ELF rows
# (#33): -c writes an ET_REL object, and a link of objects alone merges them
# (ElfLinkArm64), each module's copy of the standard library folded to one.
# Two xc modules (a class across the boundary, one compiled against the
# other's interface) and two C files (xcc's and clang's halves joined by
# clang -r). The split build of the compiler for an arm64 Linux host rests on
# this. With XTC_LINUX_ARM64_HOST set the programs run there.
#     [XTC_LINUX_ARM64_HOST=<host>] bash tests/driver/arm64-linux-objects.sh
cd "$(dirname "$0")/../.."
XC="${XC:-bin/osx/xcc-xc}"
H=$PWD
W=$(mktemp -d /tmp/a64objs.XXXX)
trap 'rm -rf "$W"' EXIT
rc=0
F=tests/fixtures/sep_a64
"$XC" -q -A arm64-linux -H . --emit-iface -o "$W/Counter.xtc.iface" $F/Counter.xc || { echo "FAIL arm64-linux-objects: Counter interface"; exit 1; }
"$XC" -q -A arm64-linux -H . -c -o "$W/Counter.o" $F/Counter.xc || { echo "FAIL arm64-linux-objects: Counter -c"; exit 1; }
"$XC" -q -A arm64-linux -H . -L "$W" -c -o "$W/main.o" $F/main.xc || { echo "FAIL arm64-linux-objects: main -c"; exit 1; }
for o in Counter.o main.o; do
    m=$(od -An -tx1 -j16 -N4 "$W/$o" | tr -d ' ')
    [ "$m" = 0100b700 ] || { echo "FAIL arm64-linux-objects: $o is not an aarch64 ET_REL ($m)"; rc=1; }
done
"$XC" -q -A arm64-linux -H . -o "$W/prog" "$W/Counter.o" "$W/main.o" || { echo "FAIL arm64-linux-objects: the object link"; exit 1; }
printf 'int add3(int x) { return x + 3; }\n' > "$W/cadd.c"
printf '#include <stdio.h>\nint add3(int);\nint main(void) { printf("c %%d\\n", add3(39)); return 0; }\n' > "$W/cmain.c"
# The C part needs clang and the aarch64 sysroot the C path builds against.
if command -v clang > /dev/null && [ -d /opt/clang/linux/aarch64-linux-gnu/usr/include ]; then
    ( cd "$W" && "$H/$XC" -q -A arm64-linux -H "$H" -c -o cadd.o cadd.c && "$H/$XC" -q -A arm64-linux -H "$H" -c -o cmain.o cmain.c \
      && "$H/$XC" -q -A arm64-linux -H "$H" -o cprog cadd.o cmain.o ) || { echo "FAIL arm64-linux-objects: the C objects"; rc=1; }
fi
if [ -n "${XTC_LINUX_ARM64_HOST:-}" ]; then
    R=/tmp/a64objs-$$
    ssh "$XTC_LINUX_ARM64_HOST" "mkdir -p $R" && scp -q "$W/prog" "$XTC_LINUX_ARM64_HOST:$R/"
    [ -x "$W/cprog" ] && scp -q "$W/cprog" "$XTC_LINUX_ARM64_HOST:$R/"
    out=$(ssh "$XTC_LINUX_ARM64_HOST" "$R/prog; [ -x $R/cprog ] && $R/cprog; rm -rf $R")
    want=$'counter 90\nc 42'
    [ -x "$W/cprog" ] || want='counter 90'
    [ "$out" = "$want" ] || { echo "FAIL arm64-linux-objects: printed '$out', wanted '$want'"; rc=1; }
fi
[ $rc = 0 ] && echo "arm64-linux-objects: ok"
exit $rc
