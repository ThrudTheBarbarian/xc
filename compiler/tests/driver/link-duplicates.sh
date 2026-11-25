#!/bin/bash
# link-duplicates.sh — how the in-house linkers resolve a name two inputs
# define (#663, #686), on the targets this host can run: arm64 on macOS,
# x86-64 on Linux, win64 under Wine when it is installed, and arm9 (its
# image read with nm; a program linked from arm9 objects cannot print yet,
# #687) when XTC_ARM9_SYSROOT names the arm9 sysroot.
#
#   * A tentative definition (`i32 g;`) yields to an initialised one in either
#     link order: the program reads 5, never 0 (#686).
#   * One source compiled into two objects (the shape every `-c` object and
#     split build has, with the standard library compiled into each) links in
#     either order and the program runs.
#   * Two modules that each define the same name are refused, in either
#     order, with a message naming the symbol and both objects (#663).
#
# Both drivers, each linking its own objects.
#
#   bash tests/driver/link-duplicates.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0; pass=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
ok()  { pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=1; }

cat > "$W/tent.xc" <<'EOF'
#import "Stdio.xc"
i32 g;
i32 readG(void);
i32 main(void) { Stdio.printf("g=%d\n", readG()); return 0; }
EOF
cat > "$W/init.xc" <<'EOF'
i32 g = 5;
i32 readG(void) { return g; }
EOF
cat > "$W/shared.xc" <<'EOF'
i32 twice(i32 x) { return x * 2; }
EOF
cat > "$W/dupA.xc" <<'EOF'
#import "Stdio.xc"
#import "shared.xc"
i32 viaB(i32 x);
i32 main(void) { Stdio.printf("%d %d\n", twice(4), viaB(5)); return 0; }
EOF
cat > "$W/dupB.xc" <<'EOF'
#import "shared.xc"
i32 viaB(i32 x) { return twice(x) + 1; }
EOF
cat > "$W/dupC.xc" <<'EOF'
i32 twice(i32 x) { return x * 3; }
i32 viaB(i32 x) { return twice(x) + 1; }
EOF

targets=""
[ "$PLAT" = osx ] && targets="arm64"
[ "$PLAT" = linux ] && targets="x86_64"
if [ "$PLAT" = linux ] && command -v wine > /dev/null 2>&1; then targets="$targets win64"; fi
# arm9 links against the arm9 sysroot (XTC_ARM9_SYSROOT) on -L.
A9SR=${XTC_ARM9_SYSROOT:-}
NM=$(command -v llvm-nm || command -v arm-none-eabi-nm || echo "")
if [ -n "$A9SR" ] && [ -d "$A9SR" ] && [ -n "$NM" ]; then
    targets="$targets arm9"
fi

runit() {   # target program
    case "$1" in
        win64) WINEPREFIX="${WINEPREFIX:-$HOME/.wine-gates}" WINEDLLOVERRIDES="winedbg.exe=d" \
                   timeout 60 wine "$2" 2>/dev/null | tr -d '\r' ;;
        *)     timeout 30 "$2" ;;
    esac
}

for a in $targets; do
    ext=""; [ "$a" = win64 ] && ext=".exe"; [ "$a" = arm9 ] && ext=".so"
    L=""; [ "$a" = arm9 ] && L="-L $A9SR"
    for c in "$REF" "$XC"; do
        [ -x "$c" ] || continue
        n=$(basename "$c"); d="$W/$a-$n"; mkdir -p "$d"
        for s in tent init dupA dupB dupC; do
            "$c" -q -A "$a" -H . $L -I "$W" -c "$W/$s.xc" -o "$d/$s.o" > "$d/err" 2>&1 \
                || { bad "$a $n: -c $s.xc: $(head -c 200 "$d/err")"; continue 2; }
        done
        for order in "tent init" "init tent"; do
            set -- $order
            if "$c" -q -A "$a" -H . $L "$d/$1.o" "$d/$2.o" -o "$d/t$ext" > "$d/err" 2>&1; then
                if [ "$a" = arm9 ]; then
                    # A program linked from arm9 objects cannot print yet (#687):
                    # read the image instead — `g` is the initialised definition.
                    addr=$($NM -D "$d/t$ext" 2>/dev/null | awk '$3 == "g" { print $1 }')
                    out=$(python3 - "$d/t$ext" "$addr" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
va = int(sys.argv[2] or '0', 16)
phoff, = struct.unpack_from('<I', b, 28)
phent, phnum = struct.unpack_from('<HH', b, 42)
for i in range(phnum):
    t, off, vaddr, _, filesz, _, _, _ = struct.unpack_from('<8I', b, phoff + i * phent)
    if t == 1 and vaddr <= va < vaddr + filesz:
        print(struct.unpack_from('<i', b, off + va - vaddr)[0]); break
else:
    print('bss')
PY
)
                    [ "$out" = "5" ] && ok || bad "$a $n [$order]: g holds '$out' in the image, not the initialiser 5"
                    continue
                fi
                out=$(runit "$a" "$d/t$ext")
                [ "$out" = "g=5" ] && ok || bad "$a $n [$order]: a tentative definition beat the initialised one (got '$out', want g=5)"
            else
                bad "$a $n [$order]: link: $(head -c 200 "$d/err")"
            fi
        done
        for order in "dupA dupB" "dupB dupA"; do
            [ "$a" = arm9 ] && continue    # needs printf in an object link (#687)
            set -- $order
            if "$c" -q -A "$a" -H . $L "$d/$1.o" "$d/$2.o" -o "$d/u$ext" > "$d/err" 2>&1; then
                out=$(runit "$a" "$d/u$ext")
                [ "$out" = "8 11" ] && ok || bad "$a $n [$order]: one source in two objects (got '$out', want '8 11')"
            else
                bad "$a $n [$order]: one source in two objects did not link: $(head -c 200 "$d/err")"
            fi
        done
        for order in "dupA dupC" "dupC dupA"; do
            set -- $order
            if "$c" -q -A "$a" -H . $L "$d/$1.o" "$d/$2.o" -o "$d/v$ext" > "$d/err" 2>&1; then
                bad "$a $n [$order]: two modules' 'twice' linked"
            elif grep -q "'twice' is defined in both" "$d/err" && grep -q "$1.o" "$d/err" && grep -q "$2.o" "$d/err"; then
                ok
            else
                bad "$a $n [$order]: refused, but not naming the symbol and both objects: $(head -c 300 "$d/err")"
            fi
        done
    done
done
# Both drivers write the same origins table for the same source (#663).
for a in $targets; do
    r="$W/$a-$(basename "$REF")"; x="$W/$a-$(basename "$XC")"
    [ -f "$r/dupA.xtc.origins" ] && [ -f "$x/dupA.xtc.origins" ] || continue
    for s in dupA dupB dupC init; do
        cmp -s "$r/$s.xtc.origins" "$x/$s.xtc.origins" && ok \
            || bad "$a: the two drivers' $s.xtc.origins differ: $(diff "$r/$s.xtc.origins" "$x/$s.xtc.origins" | head -4 | tr '\n' ' ')"
    done
    grep -q "^twice	shared.xc:1$" "$x/dupA.xtc.origins" && ok || bad "$a: dupA.xtc.origins does not place twice at shared.xc:1"
done
[ -z "$targets" ] && echo "link-duplicates: no target this host runs"
[ $fail = 0 ] && echo "link-duplicates: ok ($pass checks on: $targets)"
exit $fail
