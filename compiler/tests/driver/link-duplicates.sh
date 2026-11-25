#!/bin/bash
# link-duplicates.sh — how the in-house linkers resolve a name two inputs
# define (#663, #686), on the targets this host can run: arm64 on macOS,
# x86-64 on Linux, win64 under Wine when it is installed, and arm9 under
# qemu when XTC_ARM9_SYSROOT names the arm9 sysroot.
#
#   * A tentative definition (`i32 g;`) yields to an initialised one in either
#     link order: the program reads 5, never 0 (#686).
#   * The same function defined in two objects (the shape every `-c` object
#     and split build has, with the standard library compiled into each)
#     links in either order and the program runs.
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
cat > "$W/dupA.xc" <<'EOF'
#import "Stdio.xc"
i32 twice(i32 x) { return x * 2; }
i32 viaB(i32 x);
i32 main(void) { Stdio.printf("%d %d\n", twice(4), viaB(5)); return 0; }
EOF
cat > "$W/dupB.xc" <<'EOF'
i32 twice(i32 x) { return x * 2; }
i32 viaB(i32 x) { return twice(x) + 1; }
EOF

targets=""
[ "$PLAT" = osx ] && targets="arm64"
[ "$PLAT" = linux ] && targets="x86_64"
if [ "$PLAT" = linux ] && command -v wine > /dev/null 2>&1; then targets="$targets win64"; fi
# arm9 runs under qemu, with the arm9 sysroot (XTC_ARM9_SYSROOT) on -L.
A9SR=${XTC_ARM9_SYSROOT:-}
if [ -n "$A9SR" ] && [ -f "$A9SR/freertos-hosttest.elf" ] && command -v qemu-system-arm > /dev/null 2>&1; then
    targets="$targets arm9"
fi

runit() {   # target program
    case "$1" in
        win64) WINEPREFIX="${WINEPREFIX:-$HOME/.wine-gates}" WINEDLLOVERRIDES="winedbg.exe=d" \
                   timeout 60 wine "$2" 2>/dev/null | tr -d '\r' ;;
        arm9)  printf 'runhost %s\nexit\n' "$2" | \
                   timeout 60 qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
                   -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
                   -kernel "$A9SR/freertos-hosttest.elf" 2>/dev/null | sed -e '1,/XTOS shell/d' | \
                   sed -e ':a' -e 's/^xtos\$ //' -e 'ta' | sed -e '/^bye$/,$d' | grep -v '^\[net\]' | \
                   sed 's/\r$//' | sed -e '/^$/d' ;;
        *)     timeout 30 "$2" ;;
    esac
}

for a in $targets; do
    ext=""; [ "$a" = win64 ] && ext=".exe"; [ "$a" = arm9 ] && ext=".so"
    L=""; [ "$a" = arm9 ] && L="-L $A9SR"
    for c in "$REF" "$XC"; do
        [ -x "$c" ] || continue
        n=$(basename "$c"); d="$W/$a-$n"; mkdir -p "$d"
        for s in tent init dupA dupB; do
            "$c" -q -A "$a" -H . $L -c "$W/$s.xc" -o "$d/$s.o" > "$d/err" 2>&1 \
                || { bad "$a $n: -c $s.xc: $(head -c 200 "$d/err")"; continue 2; }
        done
        for order in "tent init" "init tent"; do
            set -- $order
            if "$c" -q -A "$a" -H . $L "$d/$1.o" "$d/$2.o" -o "$d/t$ext" > "$d/err" 2>&1; then
                out=$(runit "$a" "$d/t$ext")
                [ "$out" = "g=5" ] && ok || bad "$a $n [$order]: a tentative definition beat the initialised one (got '$out', want g=5)"
            else
                bad "$a $n [$order]: link: $(head -c 200 "$d/err")"
            fi
        done
        for order in "dupA dupB" "dupB dupA"; do
            set -- $order
            if "$c" -q -A "$a" -H . $L "$d/$1.o" "$d/$2.o" -o "$d/u$ext" > "$d/err" 2>&1; then
                out=$(runit "$a" "$d/u$ext")
                [ "$out" = "8 11" ] && ok || bad "$a $n [$order]: identical duplicates (got '$out', want '8 11')"
            else
                bad "$a $n [$order]: identical duplicates did not link: $(head -c 200 "$d/err")"
            fi
        done
    done
done
[ -z "$targets" ] && echo "link-duplicates: no target this host runs"
[ $fail = 0 ] && echo "link-duplicates: ok ($pass checks on: $targets)"
exit $fail
