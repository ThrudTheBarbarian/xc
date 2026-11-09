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
# classes, a table in an image that describes no run (one clang linked), a
# program linked by the system linker (--no-self-host), and virtual calls
# into and out of a plugin loaded with Plugin.load; an unchecked build carries
# no check. The two compilers write the
# same bytes for each, and for the other 64-bit rows (arm64 Linux, android,
# x86-64 glibc and musl, win64). With XTC_LINUX_HOST set the x86-64 programs
# run there, with XTC_LINUX_ARM64_HOST the arm64 Linux ones, and with wine
# the win64 ones; with a device or emulator attached, the android ones (the
# in-house link and the NDK's).
#
#   bash tests/driver/vtbl-check.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
_root=$(git rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
# Run from a Mac: it builds dylibs and Mach-O, and runs the x86-64 Linux,
# arm64 Linux, android and win64 rows on their hosts from there. A Linux
# gate host has nothing of its own to add.
[ "$(uname -s)" = Darwin ] || { echo "vtbl-check: skipped (run from macOS; it drives the other hosts)"; exit 0; }
PLAT=osx
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
cat > "$W/nd.xc" <<'XC'
#import "Stdio.xc"
pointer nd_addr(void);
class Op       { u32 k; void init(u32 x) { k = x; } u32 apply(u32 v) { return v + k; } }
class OpMul : Op { void init(u32 x) { super.init(x); } u32 apply(u32 v) { return v * k; } }
i32 main(i32 argc, u8** argv)
    {
    Op* o = argc > 5 ? new Op((u32)4) : (Op*)new OpMul((u32)4);
    u64* t = (u64*)nd_addr();
    if (argc > 1)
        t = new u64[256];
    u64* v = *(u64**)(pointer)o;
    for (u32 i = (u32)0; i < (u32)160; i++)
        t[i] = v[i];
    *(u64**)(pointer)o = t;
    Stdio.printf("copied %u\n", o.apply((u32)4));
    return 0;
    }
XC
cat > "$W/pllib.xc" <<'XC'
#import "Stdio.xc"
class Shape { u32 k; u32 area(void) { return k * k; } }
class Shapes { static u32 twice(Shape@ s) { return s.area() * (u32)2; } }
XC
cat > "$W/tri.xc" <<'XC'
// The plugin: a subclass of the library's Shape, and a call through a Shape
// the host made.
#import <VtLib>
class Tri : Shape { u32 area(void) { return k + (u32)100; } }
class TriTool
    {
    static Shape@ make(u32 x) { Tri@ t = new Tri(); t.k = x; return t; }
    static u32 measure(Shape@ s) { return s.area() + (u32)1; }
    }
XC
cat > "$W/plhost.xc" <<'XC'
// The host: loads the plugin, calls through the Shape it makes and hands it
// one of its own.
#import "Stdio.xc"
#import "Process.xc"
#import "Plugin.xc"
#import <VtLib>
class Hex : Shape { u32 area(void) { return k + (u32)200; } }
typedef Shape@ Make_t(u32 x);
typedef u32 Measure_t(Shape@ s);
bool answerYes(String* name, String* publisher, String* domain, String* keyId) { return true; }
i32 main(void)
{
    Plugin* p = Plugin.load(Process.argument((u32)1), &answerYes);
    if (p == (Plugin*)0) { Stdio.printf("refused: %s\\n", Plugin.lastError().cString()); return 1; }
    Make_t* make = (Make_t*)p.symbol(String.withCString("TriTool$make"));
    Measure_t* measure = (Measure_t*)p.symbol(String.withCString("TriTool$measure"));
    if (make == (Make_t*)0 || measure == (Measure_t*)0) { Stdio.printf("no TriTool\\n"); return 1; }
    Shape@ t = make((u32)3);
    Hex@ h = new Hex();
    h.k = (u32)7;
    Stdio.printf("into %u out %u lib %u\n", t.area(), measure(h), Shapes.twice(t));
    return 0;
}
XC
cat > "$W/mo_a.xc" <<'XC'
class Animal { u32 legs(void) { return (u32)4; } }
class Bird : Animal { u32 legs(void) { return (u32)2; } }
class Zoo { static Animal@ pick(u32 i) { return i > (u32)1 ? (Animal@)new Bird() : new Animal(); } }
XC
cat > "$W/mo_m.xc" <<'XC'
#import "Stdio.xc"
#import <mo_a>
class Fish : Animal { u32 legs(void) { return (u32)0; } }
i32 main(i32 argc, u8** argv)
    {
    Animal@ a = Zoo.pick((u32)argc + (u32)1);
    Animal@ f = new Fish();
    Stdio.printf("%u %u\n", a.legs(), f.legs());
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
    # An image that describes no run (clang made it): a table copied there
    # passes, since nothing in such an image can be shown not to be a vtable;
    # the heap still does not.
    if command -v clang > /dev/null; then
        d="$W/nd-$n"; mkdir -p "$d"
        printf 'void *nd_table[256];\nvoid **nd_addr(void) { return nd_table; }\n' > "$d/nd.c"
        clang -dynamiclib -o "$d/libnd.dylib" "$d/nd.c" -install_name @rpath/libnd.dylib 2> "$W/e" \
            || { bad "clang could not build the C library: $(head -c 200 "$W/e")"; }
        for m in -fbounds-check=light -fbounds-check; do
            ( cd "$d" && "$ROOT/$c" -q -O2 $m -H "$ROOT" -L . -lnd -o "nd$m" "$W/nd.xc" ) > "$W/e" 2>&1 \
                || { bad "$n $m: the C library's client: $(head -c 300 "$W/e")"; continue; }
            got=$( cd "$d" && "./nd$m" 2>&1 )
            [ "$got" = "copied 16" ] || bad "$n $m: a table in an image with no run gives '$got'"
            ( cd "$d" && "./nd$m" forge ) > "$W/r" 2>&1; rc=$?
            [ $rc = 134 ] || bad "$n $m: beside an image with no run, a heap vtable ran on (status $rc)"
        done
    fi
    # Linked by the system linker (--no-self-host): the section survives.
    if command -v clang > /dev/null; then
        "$c" -q -O2 -fbounds-check=light --no-self-host -H . -o "$W/${n}nsh" "$W/f.xc" > "$W/e" 2>&1 \
            || bad "$n --no-self-host: $(head -c 300 "$W/e")"
        [ "$("$W/${n}nsh" 2>&1)" = "$want_ok" ] || bad "$n --no-self-host: the program's own classes"
        "$W/${n}nsh" forge > /dev/null 2>&1; rc=$?
        [ $rc = 134 ] || bad "$n --no-self-host: a forged vtable pointer ran on (status $rc)"
    fi
done
# A plugin (a signed bundle, Plugin.load), host and plugin both checked:
# a virtual call from the host into the plugin's class, from the plugin into
# the host's, and from an unchecked library into the plugin's. --bundle is the
# shipped compiler's. With XTC_LINUX_HOST set, the x86-64 build runs there.
want_pl="into 103 out 208 lib 206"
plugin() { # <dir> <-A target or ""> <lib ext> <plugin ext>
    local d=$1 a=$2 le=$3 pe=$4
    mkdir -p "$d"
    ( cd "$d" && export XCC_PLUGIN_STORE="$d/store" \
      && "$ROOT/$XC" --emit-lib -q $a -H "$ROOT" -o "libVtLib.$le" "$W/pllib.xc" \
      && "$ROOT/$XC" -q -O2 $a -fbounds-check=light -H "$ROOT" -L . --bundle tri --bundle-key key \
             --bundle-version 1.0 --publisher Example --bundle-lib "libVtLib.$le" -o "tri.$pe" "$W/tri.xc" \
      && "$ROOT/$XC" -q -O2 $a -fbounds-check=light -H "$ROOT" -L . -o host "$W/plhost.xc" ) > "$W/e" 2>&1
}
if [ -x "$XC" ] && [ "$PLAT" = osx ]; then
    if plugin "$W/pl" "" dylib dylib; then
        got=$( cd "$W/pl" && XCC_PLUGIN_STORE="$W/pl/store" ./host tri 2>&1 )
        [ "$got" = "$want_pl" ] || bad "plugin: '$got'"
    else
        bad "plugin build: $(head -c 300 "$W/e")"
    fi
fi
H=${XTC_LINUX_HOST:-}
if [ -x "$XC" ] && [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=10"
    if plugin "$W/plx" "-A x86_64" so so; then
        cp support/runtime-lib/x86_64-linux/libRuntime.so "$W/plx/"
        tar -C "$W/plx" -czf "$W/plx.tgz" . && scp $SSHO -q "$W/plx.tgz" "$H:vtbl-plugin.tgz" \
            || bad "plugin: copy to the Linux host"
        got=$(ssh $SSHO "$H" 'mkdir -p vtbl-plugin && cd vtbl-plugin && tar xzf ../vtbl-plugin.tgz && XCC_PLUGIN_STORE=$PWD/store LD_LIBRARY_PATH=. ./host tri 2>&1; cd && rm -rf vtbl-plugin vtbl-plugin.tgz')
        [ "$got" = "$want_pl" ] || bad "plugin on the Linux host: '$got'"
    else
        bad "plugin build for x86-64: $(head -c 300 "$W/e")"
    fi
fi

# Objects compiled apart (-c) and linked: every object carries the standard
# library's classes, so the link gathers many runs into one section and moves
# each vtable once. The port moved a name once per object that defined it,
# and its programs called through the wrong vtable.
for c in $XC $REF; do
    [ -x "$c" ] || continue
    n=$(basename "$c"); d="$W/mo-$n"; mkdir -p "$d"
    for m in "" -fbounds-check=light; do
        ( cd "$d" && "$ROOT/$c" -q -O2 $m -H "$ROOT" --emit-iface -o mo_a.xtc.iface "$W/mo_a.xc" \
          && "$ROOT/$c" -q -O2 $m -H "$ROOT" -c -o mo_a.o "$W/mo_a.xc" \
          && "$ROOT/$c" -q -O2 $m -H "$ROOT" -L . -c -o mo_m.o "$W/mo_m.xc" \
          && "$ROOT/$c" -q $m -H "$ROOT" -o "mo$m" mo_a.o mo_m.o ) > "$W/e" 2>&1 \
            || { bad "$n $m: objects: $(head -c 300 "$W/e")"; continue; }
        got=$( cd "$d" && "./mo$m" 2>&1 )
        [ "$got" = "2 0" ] || bad "$n $m: a program linked from objects gives '$got'"
    done
done
for m in "" -fbounds-check=light; do
    [ -f "$W/mo-xcc/mo$m" ] && [ -f "$W/mo-xcc-xc/mo$m" ] && { cmp -s "$W/mo-xcc/mo$m" "$W/mo-xcc-xc/mo$m" \
        || bad "objects $m: the two compilers' links differ"; }
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
# android on an attached device or emulator: the in-house link, and the NDK's
# (--no-self-host), whose image describes no run, so its own vtables pass as
# pointers into an undescribed image while a heap pointer still stops it.
ADB=$(command -v adb || ls "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/platform-tools/adb 2>/dev/null)
if [ $fail = 0 ] && [ -n "$ADB" ] && "$ADB" get-state > /dev/null 2>&1; then
    for k in in ndk; do
        f=""; [ $k = ndk ] && f=--no-self-host
        "$XC" -q -O2 -A android -fbounds-check=light $f -H . -o "$W/and-$k" "$W/f.xc" > "$W/e" 2>&1 \
            || { bad "-A android $f: $(head -c 300 "$W/e")"; continue; }
        "$ADB" push "$W/and-$k" /data/local/tmp/vtbl-check > /dev/null 2>&1 || { bad "adb push"; continue; }
        out=$("$ADB" shell 'cd /data/local/tmp && ./vtbl-check; echo rc=$?; ./vtbl-check forge 2>&1; echo rc=$?; rm -f vtbl-check' | tr -d '\r')
        case "$out" in
            "$want_ok"*"rc=0"*"not a vtable"*"at f.xc:20:31"*"rc=134") ;;
            *) bad "-A android $f on the device printed: $out" ;;
        esac
    done
    msg="$msg, android run"
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
