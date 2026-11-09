#!/bin/bash
# vtbl-check.sh — a checked build checks the vtable pointer before each
# virtual call (#34), in both compilers
#
# Under -fbounds-check=light and -fbounds-check, a call through a vtable first
# checks that the object's vtable pointer lies in the class tables of a loaded
# image. Each image describes its tables' run (a __DATA,__xt_vtbl section in a
# Mach-O file, a PT_XT_VTBL program header in an ELF file, an .xtvt section in
# a PE file), and the check reads it from there.
#
# Here (arm64 macOS): a vtable pointer forged to point into the heap stops the
# program with status 134 and names the call site, in both modes and in a loop
# the compiler devirtualises; a class from an xc library built without checks
# (another image) dispatches without a false stop, as do the program's own
# classes; an unchecked build carries no check. The two compilers write the
# same bytes for each, and for the other 64-bit rows (arm64 Linux, android,
# x86-64 glibc and musl, win64). With XTC_LINUX_HOST set the x86-64 programs
# run there, with XTC_LINUX_ARM64_HOST the arm64 Linux ones, and with wine
# the win64 ones.
#
#   bash tests/driver/vtbl-check.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
_root=$(git rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
ROOT=$(pwd)
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
bad() { echo "FAIL vtbl-check: $*"; fail=1; }

cat > "$W/f.xc" <<'XC'
#import "Stdio.xc"
class Op       { u32 k; void init(u32 x) { k = x; } u32 apply(u32 v) { return v + k; } }
class OpMul : Op { void init(u32 x) { super.init(x); } u32 apply(u32 v) { return v * (k | (u32)1); } }
class OpXor : Op { void init(u32 x) { super.init(x); } u32 apply(u32 v) { return v ^ k; } }
i32 main(i32 argc, u8** argv)
    {
    Op* ops[6];
    for (u32 i = (u32)0; i < (u32)6; i++)
        {
        if ((i % (u32)3) == (u32)0)      ops[i] = new Op(i);
        else if ((i % (u32)3) == (u32)1) ops[i] = new OpMul(i);
        else                             ops[i] = new OpXor(i);
        }
    // A vtable pointer forged to point into the heap: a block of zeros.
    if (argc > 1)
        *(u64**)(pointer)ops[4] = new u64[16];
    u32 acc = (u32)1;
    for (u32 r = (u32)0; r < (u32)3; r++)
        for (u32 i = (u32)0; i < (u32)6; i++)
            acc = ops[i].apply(acc) + r;
    Stdio.printf("acc %u\n", acc);
    return 0;
    }
XC
cat > "$W/lib.xc" <<'XC'
#import "Stdio.xc"
class Shape { u32 k; u32 area(void) { return k * k; } }
class Square : Shape { u32 area(void) { return k * k + (u32)1; } }
class Shapes
    {
    static Shape@ make(u32 x)
        {
        Shape@ s = x > (u32)2 ? (Shape@)new Square() : new Shape();
        s.k = x;
        return s;
        }
    }
XC
cat > "$W/app.xc" <<'XC'
#import "Stdio.xc"
#import <VtLib>
i32 main(i32 argc, u8** argv)
    {
    Shape@ s = Shapes.make((u32)argc + (u32)2);
    Shape@ t = new Shape();
    t.k = (u32)5;
    Stdio.printf("areas %u %u\n", s.area(), t.area());
    return 0;
    }
XC
want_ok="acc 959"
for c in $XC $REF; do
    [ -x "$c" ] || continue
    n=$(basename "$c")
    for m in -fbounds-check=light -fbounds-check; do
        for o in -O0 -O2; do
            "$c" -q $o $m -H . -o "$W/$n$m$o" "$W/f.xc" > "$W/e" 2>&1 || { bad "$n $m $o: build: $(head -c 300 "$W/e")"; continue; }
            got=$("$W/$n$m$o" 2>&1)
            [ "$got" = "$want_ok" ] || bad "$n $m $o: the program's own classes give '$got'"
            "$W/$n$m$o" forge > "$W/r" 2>&1; rc=$?
            { [ $rc = 134 ] && grep -q "a virtual call through a pointer that is not a vtable" "$W/r" \
                && grep -q "at f.xc:20:31" "$W/r"; } \
                || { bad "$n $m $o: a forged vtable pointer ran on (status $rc)"; head -4 "$W/r"; }
        done
    done
    "$c" -q -O2 -H . -o "$W/${n}plain" "$W/f.xc" > "$W/e" 2>&1 || { bad "$n plain build"; continue; }
    nm "$W/${n}plain" 2>/dev/null | grep -q "_xt_check_vtbl" && bad "$n: an unchecked build carries the vtable check"
    [ "$("$W/${n}plain")" = "$want_ok" ] || bad "$n: the unchecked build"
    # The program's tables are a section of their own, checked or not.
    otool -l "$W/${n}plain" 2>/dev/null | grep -q "sectname __xt_vtbl" || bad "$n: no __xt_vtbl section"
    # A class from another image: an xc library built without checks.
    d="$W/lib-$n"; mkdir -p "$d"
    ( cd "$d" && "$ROOT/$c" --emit-lib -q -H "$ROOT" -o libVtLib.dylib "$W/lib.xc" ) > "$W/e" 2>&1 \
        || { bad "$n: the library: $(head -c 300 "$W/e")"; continue; }
    for m in -fbounds-check=light -fbounds-check; do
        ( cd "$d" && "$ROOT/$c" -q -O2 $m -H "$ROOT" -L . -o "app$m" "$W/app.xc" ) > "$W/e" 2>&1 \
            || { bad "$n $m: the library's client: $(head -c 300 "$W/e")"; continue; }
        got=$( cd "$d" && "./app$m" 2>&1 )
        [ "$got" = "areas 10 25" ] || bad "$n $m: the library's classes give '$got'"
    done
done
# The two compilers write the same programs.
for m in -fbounds-check=light -fbounds-check; do
    for o in -O0 -O2; do
        [ -f "$W/xcc$m$o" ] && [ -f "$W/xcc-xc$m$o" ] && { cmp -s "$W/xcc$m$o" "$W/xcc-xc$m$o" \
            || bad "arm64-macos $m $o: the two compilers' programs differ"; }
    done
done
cmp -s "$W/xccplain" "$W/xcc-xcplain" || bad "arm64-macos: the two compilers' unchecked programs differ"

# The other 64-bit rows: the same bytes from both compilers.
for t in arm64-linux arm64-android x86_64 x86_64-linux-musl win64; do
    for m in "" -fbounds-check=light -fbounds-check; do
        for s in r x; do
            c=$REF; [ $s = x ] && c=$XC
            "$c" -q -O2 -A $t $m -H . -o "$W/$s-$t$m" "$W/f.xc" > "$W/e" 2>&1 \
                || bad "$(basename "$c") -A $t $m: $(head -c 300 "$W/e")"
        done
        [ -f "$W/r-$t$m" ] && [ -f "$W/x-$t$m" ] && { cmp -s "$W/r-$t$m" "$W/x-$t$m" \
            || bad "-A $t $m: the two compilers' programs differ"; }
    done
done
msg="arm64 run, other rows compared"

# x86-64 on a Linux host: both libcs, both modes.
H=${XTC_LINUX_HOST:-}
if [ $fail = 0 ] && [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=10"
    for t in x86_64 x86_64-linux-musl; do
        for m in -fbounds-check=light -fbounds-check; do
            scp $SSHO -q "$W/x-$t$m" support/runtime-lib/x86_64-linux/libRuntime.so "$H:" \
                && ssh $SSHO "$H" "mkdir -p vtbl-check && mv x-$t$m libRuntime.so vtbl-check/" \
                || { bad "copy to the Linux host"; break 2; }
            out=$(ssh $SSHO "$H" "cd vtbl-check && LD_LIBRARY_PATH=. ./x-$t$m; echo rc=\$?; LD_LIBRARY_PATH=. ./x-$t$m forge 2>&1; echo rc=\$?; cd && rm -rf vtbl-check")
            case "$out" in
                "$want_ok"*"rc=0"*"not a vtable"*"at f.xc:20:31"*"rc=134") ;;
                *) bad "-A $t $m on the Linux host printed: $out" ;;
            esac
        done
    done
    msg="$msg, x86-64 run"
fi
# arm64 Linux on its host.
H=${XTC_LINUX_ARM64_HOST:-}
if [ $fail = 0 ] && [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=10"
    for m in -fbounds-check=light -fbounds-check; do
        scp $SSHO -q "$W/x-arm64-linux$m" support/runtime-lib/arm64-linux/libRuntime.so "$H:" \
            && ssh $SSHO "$H" "mkdir -p vtbl-check && mv x-arm64-linux$m libRuntime.so vtbl-check/" \
            || { bad "copy to the arm64 Linux host"; break; }
        out=$(ssh $SSHO "$H" "cd vtbl-check && LD_LIBRARY_PATH=. ./x-arm64-linux$m; echo rc=\$?; LD_LIBRARY_PATH=. ./x-arm64-linux$m forge 2>&1; echo rc=\$?; cd && rm -rf vtbl-check")
        case "$out" in
            "$want_ok"*"rc=0"*"not a vtable"*"at f.xc:20:31"*"rc=134") ;;
            *) bad "-A arm64-linux $m on its host printed: $out" ;;
        esac
    done
    msg="$msg, arm64 Linux run"
fi
# win64 under wine (no crash dialogs, the gates' hidden prefix when there is one).
WINE=$(command -v wine64 || command -v wine || true)
if [ $fail = 0 ] && [ -n "$WINE" ]; then
    export WINEDLLOVERRIDES="winedbg.exe=d"
    [ -d "$HOME/.wine-gates" ] && export WINEPREFIX="$HOME/.wine-gates"
    for m in -fbounds-check=light -fbounds-check; do
        cp "$W/x-win64$m" "$W/w.exe"
        got=$("$WINE" "$W/w.exe" 2>/dev/null | tr -d '\r')
        "$WINE" "$W/w.exe" forge > "$W/r" 2>&1; rc=$?
        { [ "$got" = "$want_ok" ] && [ $rc = 134 ] && grep -q "not a vtable" "$W/r"; } \
            || bad "-A win64 $m under wine: '$got', status $rc"
    done
    msg="$msg, win64 run"
fi
[ $fail = 0 ] && echo "vtbl-check: ok ($msg)"
exit $fail
