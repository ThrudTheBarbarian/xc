#!/bin/bash
# elf-arm64-objects.sh — C objects, archives and shared libraries in an
# arm64 Linux link (2026-10-30)
#
# -Wl,x.o and -Wl,lib.a are aarch64 ELF code the port merges into the image
# (its ElfLinkArm64), for a program and for a library. The port used to
# refuse them for arm64 Linux, as for any target it did not name; the
# reference has no ELF object merge and used to leave them out without a
# word, so it now refuses them. A C shared library named with -l<name> is
# needed by both compilers, as an `#import <X>` is: it used to be left out by
# both (on android too), so the program linked and then failed to load.
# With XTC_LINUX_ARM64_HOST set the programs run there and must print what
# the C code computed.
#
#   [XTC_LINUX_ARM64_HOST=<host>] bash tests/driver/elf-arm64-objects.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
CLANG=${CLANG:-$(command -v /opt/homebrew/opt/llvm/bin/clang || command -v clang)}
AR=${AR:-$(command -v /opt/homebrew/opt/llvm/bin/llvm-ar || command -v llvm-ar || command -v ar)}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
# Freestanding C: no headers, so no arm64 Linux sysroot is needed.
printf 'int c_mul(int a, int b) { return a * b; }\n' > "$W/m.c"
printf 'int c_add(int a, int b) { return a + b; }\n' > "$W/a.c"
"$CLANG" --target=aarch64-linux-gnu -ffreestanding -fPIC -O2 -c "$W/m.c" -o "$W/m.o" \
    && "$CLANG" --target=aarch64-linux-gnu -ffreestanding -fPIC -O2 -c "$W/a.c" -o "$W/a.o" \
    && "$AR" rcs "$W/liba.a" "$W/a.o" \
    || { echo "elf-arm64-objects: skipped (no clang for aarch64-linux-gnu)"; exit 0; }
mkdir -p "$W/sl"
printf 'int c_sub(int a, int b) { return a - b; }\n' > "$W/s.c"
"$CLANG" --target=aarch64-linux-gnu -ffreestanding -fPIC -O2 -shared -nostdlib -fuse-ld=lld \
    -Wl,-soname,libcsub.so -o "$W/sl/libcsub.so" "$W/s.c" \
    || { echo "elf-arm64-objects: skipped (no lld for aarch64-linux-gnu)"; exit 0; }
cat > "$W/p.xc" <<'XC'
#import "Stdio.xc"
i32 c_mul(i32 a, i32 b);
i32 c_add(i32 a, i32 b);
i32 main(i32 argc, u8** argv)
{
    Stdio.printf("c says %d %d\n", c_mul(6, argc + 6), c_add(40, argc));
    return 0;
}
XC
"$XC" -q -A arm64-linux -o "$W/p" "$W/p.xc" -Wl,"$W/m.o" -Wl,"$W/liba.a" > "$W/e" 2>&1 \
    || { echo "FAIL elf-arm64-objects: xcc-xc does not link the objects: $(head -c 200 "$W/e")"; fail=1; }
"$XC" -q -A arm64-linux --emit-lib -o "$W/libp.so" "$W/p.xc" -Wl,"$W/m.o" -Wl,"$W/liba.a" > "$W/e" 2>&1 \
    || { echo "FAIL elf-arm64-objects: xcc-xc does not link them into a library: $(head -c 200 "$W/e")"; fail=1; }
"$REF" -q -A arm64-linux -o "$W/r" "$W/p.xc" -Wl,"$W/m.o" > "$W/e" 2>&1 \
    && { echo "FAIL elf-arm64-objects: the reference linked without the objects"; fail=1; }
grep -q 'would silently omit them' "$W/e" \
    || { echo "FAIL elf-arm64-objects: the reference's refusal is not the omission error: $(head -c 200 "$W/e")"; fail=1; }
cat > "$W/q.xc" <<'XC'
#import "Stdio.xc"
i32 c_sub(i32 a, i32 b);
i32 main(i32 argc, u8** argv)
{
    Stdio.printf("c subtracts %d\n", c_sub(50, argc + 6));
    return 0;
}
XC
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -A arm64-linux -L "$W/sl" -lcsub -o "$W/q$s" "$W/q.xc" > "$W/e" 2>&1 \
        || { echo "FAIL elf-arm64-objects: $(basename "$c") -lcsub: $(head -c 200 "$W/e")"; fail=1; continue; }
    strings "$W/q$s" | grep -qx 'libcsub.so' \
        || { echo "FAIL elf-arm64-objects: $(basename "$c") left -lcsub out of the link"; fail=1; }
    "$c" -q -A arm64-linux -L "$W/sl" -lnosuch -o "$W/n$s" "$W/q.xc" > "$W/e" 2>&1 \
        && { echo "FAIL elf-arm64-objects: $(basename "$c") linked a -l that is not there"; fail=1; }
    # The C library's own names are covered by the row's libraries.
    "$c" -q -A arm64-linux -L "$W/sl" -lcsub -lm -lpthread -o "$W/m$s" "$W/q.xc" > "$W/e" 2>&1 \
        || { echo "FAIL elf-arm64-objects: $(basename "$c") -lm -lpthread: $(head -c 200 "$W/e")"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/qr" "$W/qx" || { echo "FAIL elf-arm64-objects: the two -lcsub programs differ"; fail=1; }; }
msg="code"
H=${XTC_LINUX_ARM64_HOST:-}
if [ $fail = 0 ] && [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    scp $SSHO -q "$W/p" "$H:elf-arm64-objects.bin" || { echo "FAIL: copy to the host"; exit 1; }
    out=$(ssh $SSHO "$H" './elf-arm64-objects.bin a; echo "rc=$?"; rm -f elf-arm64-objects.bin')
    [ "$out" = "c says 48 42
rc=0" ] || { echo "FAIL elf-arm64-objects: on the host it printed: $out"; fail=1; }
    ssh $SSHO "$H" 'rm -rf eao && mkdir eao' && scp $SSHO -q "$W/qx" "$W/sl/libcsub.so" "$H:eao/" \
        || { echo "FAIL: copy to the host"; exit 1; }
    out=$(ssh $SSHO "$H" 'cd eao && ./qx a; echo "rc=$?"; cd && rm -rf eao')
    [ "$out" = "c subtracts 42
rc=0" ] || { echo "FAIL elf-arm64-objects: -lcsub on the host printed: $out"; fail=1; }
    msg="code and run"
fi
[ $fail = 0 ] && echo "elf-arm64-objects: ok ($msg)"
exit $fail
