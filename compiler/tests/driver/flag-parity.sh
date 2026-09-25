#!/bin/bash
# flag-parity.sh — the shipped driver takes every option the reference driver takes.
#
# For each option the reference driver (bin/osx/xcc) lists in its --help, and the
# ones it accepts without listing, this runs BOTH drivers on a small program and
# compares what they did: the exit status, and the kind of each file produced.
# xcc-xc (bin/osx/xcc-xc) fails the check when it rejects an option the
# reference accepts, or when the two disagree where they should agree.
#
# Some options do something in xcc-xc that the reference driver parses and then
# drops (-E, -a, --emit-asm-from-ir, --xcc-home, -ll). For those the check
# compares xcc-xc against the reference given the documented equivalent: -a
# against `-o x.s`, and so on. Options another change still has to port are
# listed as PENDING and do not fail the run.
#
# The script also reads the reference's --help and fails if it names an option
# this table does not cover, so an option added there cannot go unported
# without this script saying so.
#
# Usage:  tests/driver/flag-parity.sh [-v]
#   -v    print every check, not just failures
#   REF=<xcc>  XC=<xcc-xc>  override the two drivers
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
REF=${REF:-$ROOT/bin/osx/xcc}
XC=${XC:-$ROOT/bin/osx/xcc-xc}
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

for b in "$REF" "$XC"; do
    [ -x "$b" ] || { echo "flag-parity: $b is not built" >&2; exit 2; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/flag-parity.XXXXXX")
trap 'rm -rf "$T"' EXIT
cd "$T"

cat > hello.xc <<'EOF'
#import "Stdio.xc"
i32 main(void)
{
    Stdio.printf("hello %d\n", 42);
    return 0;
}
EOF
cat > tail.xc <<'EOF'
i32 leaf(i32 a, i32 b)
{
    return a * 3 + b;
}
i32 down(i32 n)
{
    if (n <= 0)
        return 0;
    return leaf(n, down(n - 1));
}
i32 bounce(i32 n)
{
    return down(n);
}
i32 main(void)
{
    return bounce(4);
}
EOF
cat > ret.xc <<'EOF'
#ifndef VAL
#define VAL 3
#endif
i32 main(void)
{
    return VAL;
}
EOF

PASS=0; FAIL=0; PEND=0
COVERED=" "
ok()   { PASS=$((PASS+1)); [ $VERBOSE = 1 ] && echo "ok       $*"; return 0; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL     $*"; }
pend() { PEND=$((PEND+1)); echo "PENDING  $*"; }
cover() { for o in "$@"; do COVERED="$COVERED$o "; done; }

# The kind of every file a run left behind whose name starts with `$1`, one
# per line: `name: <first field of file(1)>`, with any text file just `text`
# (file(1) calls the same interface "JSON data" or "ASCII text" depending on
# how it happens to be laid out). Two runs agree when these match.
kinds() {
    local f k
    for f in "$1"*; do
        [ -e "$f" ] || continue
        k=$(file -b "$f" | cut -d, -f1)
        case $k in *text*|JSON*) k=text ;; esac
        printf '%s: %s\n' "${f#$1}" "$k"
    done
}

# run <driver> <tag> args… — the driver's exit status in $RC, its stdout and
# stderr in <tag>.out / <tag>.err, the files it wrote (named <tag>*) described
# in $KIND. An output path is spelled @OUT@ and becomes <tag>.<ext>.
run() {
    local drv=$1 tag=$2; shift 2
    rm -rf "$tag" "$tag".* "$tag"-*
    local args=() a
    for a in "$@"; do args+=("${a//@OUT@/$tag}"); done
    "$drv" -H "$ROOT" "${args[@]}" > "$tag.stdout" 2> "$tag.stderr"
    RC=$?
    mv "$tag.stdout" "$tag.out.txt"; mv "$tag.stderr" "$tag.err.txt"
    KIND=$(kinds "$tag" | grep -v '\.out\.txt\|\.err\.txt')
}

# Did the reference ACCEPT its command line? It prints a warning and carries
# on for an option it does not know, so a zero exit status is not enough.
ref_accepted() {
    [ $RC = 0 ] && ! grep -q "unknown option" refout.err.txt
}

# same "<label>" args… — both drivers, the same command line: xcc-xc must not
# reject what the reference accepts, and the status and files must agree.
same() {
    local label=$1; shift
    run "$REF" refout "$@"; local rrc=$RC rk=$KIND; local racc=0; ref_accepted && racc=1
    run "$XC" xcout "$@"; local xrc=$RC xk=$KIND
    if grep -q "error: unrecognised option" xcout.err.txt xcout.out.txt && [ $racc = 1 ]; then
        bad "$label: xcc-xc rejects it ($(grep -h "error: unrecognised" xcout.err.txt xcout.out.txt | head -1))"
        return
    fi
    if [ $(( rrc == 0 )) != $(( xrc == 0 )) ]; then
        bad "$label: exit status differs (reference $rrc, xcc-xc $xrc): $(head -c 300 xcout.err.txt xcout.out.txt)"
        return
    fi
    if [ "$rk" != "$xk" ]; then
        bad "$label: output differs — reference [$rk] xcc-xc [$xk]"
        return
    fi
    ok "$label (status $xrc${xk:+, $(echo $xk | tr '\n' ' ')})"
}

# equiv "<label>" "<reference args>" "<xcc-xc args>" — the option does in
# xcc-xc what its help says; the reference drops it, so xcc-xc is compared
# with the reference given the equivalent command line.
equiv() {
    local label=$1 rargs=$2 xargs=$3
    run "$REF" refout $rargs; local rrc=$RC rk=$KIND
    run "$XC" xcout $xargs; local xrc=$RC xk=$KIND
    if grep -q "error: unrecognised option" xcout.err.txt xcout.out.txt; then
        bad "$label: xcc-xc rejects it"; return
    fi
    if [ $(( rrc == 0 )) != $(( xrc == 0 )) ] || [ "$rk" != "$xk" ]; then
        bad "$label: xcc-xc [$xrc: $xk] vs reference '$rargs' [$rrc: $rk]"; return
    fi
    ok "$label (as the reference's '$rargs')"
}

# text "<label>" "<stream>" args… — both drivers print the same text.
text() {
    local label=$1 stream=$2; shift 2
    run "$REF" refout "$@"; local rrc=$RC
    run "$XC" xcout "$@"; local xrc=$RC
    if [ $rrc != $xrc ] || ! cmp -s "refout.$stream.txt" "xcout.$stream.txt"; then
        bad "$label: the two print different text (status $rrc / $xrc)"
        diff "refout.$stream.txt" "xcout.$stream.txt" | head -5
        return
    fi
    ok "$label (identical $stream)"
}

# xcconly "<label>" <expect-status> args… — xcc-xc alone, for an option the
# reference documents but does not implement; `grep` names text that must
# appear in its output.
xcconly() {
    local label=$1 want=$2 needle=$3; shift 3
    run "$XC" xcout "$@"
    if [ $RC != $want ]; then bad "$label: status $RC, expected $want: $(head -c 300 xcout.err.txt)"; return; fi
    if [ -n "$needle" ] && ! grep -q -- "$needle" xcout.out.txt xcout.err.txt; then
        bad "$label: expected '$needle' in the output"; return
    fi
    ok "$label"
}

A="-q -A arm64"

# ── outputs ─────────────────────────────────────────────────────────────
cover -o --output
same "-o"                   $A -o @OUT@ ret.xc
same "--output"             $A --output @OUT@ ret.xc
same "-o x.s"               $A -o @OUT@.s ret.xc
cover -c
same "-c"                   $A -c -o @OUT@.o ret.xc
cover -a --assemble-only --emit-asm-from-ir
equiv "-a"                  "$A -o refout.s ret.xc"  "$A -a -o xcout.s ret.xc"
equiv "--assemble-only"     "$A -o refout.s ret.xc"  "$A --assemble-only -o xcout.s ret.xc"
equiv "--emit-asm-from-ir"  "$A -o refout.s ret.xc"  "$A --emit-asm-from-ir -o xcout.s ret.xc"
cover -E --preprocessed
rm -f pp.xc
same "-E (the build)"       $A -E pp.xc -o @OUT@ ret.xc
if [ -s pp.xc ] && grep -q "i32 main" pp.xc; then ok "-E writes the preprocessed source"
else bad "-E wrote no preprocessed source"; fi
# The reference's front end honours -E when it is run directly; the text it
# writes is what xcc-xc's must be.
"$ROOT/bin/osx/xcc-fe" -H "$ROOT" -q -m arm64 -E fe-pp.xc -o fe.ir ret.xc > /dev/null 2>&1
if cmp -s fe-pp.xc pp.xc; then ok "-E text matches the reference front end's"
else bad "-E text differs from the reference front end's"; fi
rm -f pp.xc
same "--preprocessed"       $A --preprocessed pp.xc -o @OUT@ ret.xc
[ -s pp.xc ] && ok "--preprocessed writes the file" || bad "--preprocessed wrote nothing"
cover --emit-iface
same "--emit-iface"         $A --emit-iface -o @OUT@.json hello.xc
cover --emit-lib
same "--emit-lib (arm64)"   $A --emit-lib -o @OUT@.dylib ret.xc
cover --emit-apk
same "--emit-apk"           -q -A android --emit-apk -o @OUT@.apk ret.xc
cover --emit-ir --emit-ir-opt
same "--emit-ir"            $A --emit-ir -o @OUT@ ret.xc
grep -q "func" xcout.err.txt && ok "--emit-ir prints IR" || bad "--emit-ir printed no IR"
same "--emit-ir-opt"        $A --emit-ir-opt -o @OUT@ ret.xc
grep -q "func" xcout.err.txt && ok "--emit-ir-opt prints IR" || bad "--emit-ir-opt printed no IR"
cover -fdce-trace
same "-fdce-trace"          $A -fdce-trace -o @OUT@ hello.xc
grep -q "xcc: dce: removed" xcout.err.txt && ok "-fdce-trace names removed functions" \
    || bad "-fdce-trace named nothing"

# ── definitions and paths ───────────────────────────────────────────────
cover -D -I --include -L --library-path -H --xcc-home --xtc-home
same "-D name=value"        $A -D VAL=7 -o @OUT@ ret.xc
same "-Dname=value"         $A -DVAL=7 -o @OUT@ ret.xc
same "-Dname"               $A -DVAL -o @OUT@ ret.xc
same "-I"                   $A -I . -o @OUT@ ret.xc
same "--include"            $A --include . -o @OUT@ ret.xc
same "-L"                   $A -L . -o @OUT@ ret.xc
same "-L<dir>"              $A -L. -o @OUT@ ret.xc
same "--library-path"       $A --library-path . -o @OUT@ ret.xc
same "-H"                   $A -o @OUT@ ret.xc
xcconly "--xcc-home"  0 ""  $A --xcc-home "$ROOT" -o @OUT@ ret.xc
xcconly "--xtc-home"  0 ""  $A --xtc-home "$ROOT" -o @OUT@ ret.xc
same "-v"                   -v
same "--version"            --version
cover -h --help -v --version -V --verbose -q --quiet
same "-h"                   -h
same "--help"               --help
same "-V"                   $A -V -o @OUT@ ret.xc
same "--verbose"            $A --verbose -o @OUT@ ret.xc
same "--quiet"              -A arm64 --quiet -o @OUT@ ret.xc

# ── the support root from the environment ──────────────────────────────
# Run from a directory with no support tree beside it, and no -H.
mkdir -p envrun fakehome
envcheck() {
    local label=$1 want=$2; shift 2
    ( cd envrun && env "$@" "$XC" -q -A arm64 -V -o ../x ../ret.xc > ../e.out 2>&1 ); local rc=$?
    if [ $rc = 0 ] && grep -q -- "$want" e.out; then ok "$label"
    else bad "$label: status $rc, '$want' not in: $(grep -m1 'support\|lib/xc' e.out)"; fi
}
cover XCC_HOME XTC_HOME XTC_LDFLAGS
envcheck "XCC_HOME"          "$ROOT/support" XCC_HOME="$ROOT"
envcheck "XTC_HOME"          "$ROOT/support" XTC_HOME="$ROOT"
envcheck "XCC_HOME quoted"   "$ROOT/support" XCC_HOME="\"$ROOT\""
envcheck "XCC_HOME before XTC_HOME" "$ROOT/support" XCC_HOME="$ROOT" XTC_HOME=/nonexistent
ln -s "$ROOT" fakehome/xcc
envcheck "~/xcc"             "fakehome/xcc/support" HOME="$T/fakehome"

# ── targets ─────────────────────────────────────────────────────────────
cover -A --arch
for a in arm64 ios ios-sim android x86_64 win64 wasm32 m68k 6502; do
    case $a in 6502) same "-A $a" -q -A $a -o @OUT@.xex ret.xc ;;
               *)    same "-A $a" -q -A $a -o @OUT@ ret.xc ;; esac
    [ $a = wasm32 ] && { sed s/refout/xcout/g refout.html | cmp -s - xcout.html && ok "-A wasm32: the same starter page" \
                         || bad "-A wasm32: the starter pages differ"; }
done
# arm9 links against a device libc that the source tree does not carry; the
# reference's front end refuses to start without it. xcc-xc still writes the
# assembly, so the check is that it does and that every spelling agrees.
run "$XC" xcout -q -A arm9 -o @OUT@.s ret.xc; cp xcout.s arm9.s 2>/dev/null
[ $RC = 0 ] && ok "-A arm9 (assembly)" || bad "-A arm9: status $RC"
# Other spellings of a target: each must give what the canonical name gives.
for pair in x86-64:x86_64 amd64:x86_64 windows:win64 x86_64-windows:win64 \
            armv7:arm9 armv7-a:arm9 cortex-a9:arm9 wasm:wasm32; do
    al=${pair%%:*}; ca=${pair##*:}
    run "$REF" refout -q -A $al -o @OUT@.s ret.xc
    grep -q "unknown -A architecture" refout.err.txt && { bad "-A $al: the reference does not know it"; continue; }
    run "$XC" xcout -q -A $ca -o @OUT@.s ret.xc; cp xcout.s canon.s 2>/dev/null
    run "$XC" xcout -q -A $al -o @OUT@.s ret.xc
    if [ $RC = 0 ] && cmp -s canon.s xcout.s; then ok "-A $al is -A $ca"
    else bad "-A $al: status $RC, or not what -A $ca writes"; fi
done
same "--arch"               -q --arch x86_64 -o @OUT@ ret.xc
cover 68000 68030
same "-A 68000"             -q -A 68000 -o @OUT@.prg ret.xc
same "-A 68030"             -q -A 68030 -o @OUT@.prg ret.xc

# ── memory layouts ──────────────────────────────────────────────────────
cover -m --memory-model
same "-m xt"                -q -m xt -o @OUT@.xex ret.xc
same "-m xt6502/xt"         -q -m xt6502/xt -o @OUT@.xex ret.xc
same "--memory-model"       -q --memory-model xt -o @OUT@.xex ret.xc
same "-m arm64"             -q -m arm64 -o @OUT@ ret.xc
same "-m x86_64"            -q -m x86_64 -o @OUT@ ret.xc
same "-m win64"             -q -m win64 -o @OUT@ ret.xc
same "-m wasm32"            -q -m wasm32 -o @OUT@ ret.xc
same "-m atarist -A m68k"   -q -m atarist -A m68k -o @OUT@ ret.xc
run "$XC" xcout -q -m arm9 -o @OUT@.s ret.xc
cmp -s arm9.s xcout.s && ok "-m arm9 is -A arm9" || bad "-m arm9: not what -A arm9 writes"
same "-m <no such layout>"  -q -m nosuch -o @OUT@.xex ret.xc
same "-m xl (retired)"      -q -m xl -o @OUT@.xex ret.xc
cp "$ROOT/support/xt6502/layouts/xt.lnk" custom.lnk
# The reference cannot build with a layout given by path: its front end finds
# no platform library for it. xcc-xc builds the same program as -m xt.
xcconly "-m <path.lnk>"      0 "" -q -m custom.lnk -o @OUT@.xex ret.xc
run "$REF" refout -q -m xt -o @OUT@.xex ret.xc
if cmp -s refout.xex xcout.xex; then ok "-m <path.lnk> builds what -m xt builds"
else bad "-m <path.lnk> built something other than -m xt"; fi
xcconly "-m <path without .lnk>" 0 "" -q -m custom -o @OUT@.xex ret.xc
# The split-banked layouts: the reference writes assembly for them that its
# own assembler then rejects; xcc-xc's 6502 back end has no split banking and
# says so rather than emitting the xt program under another name.
xcconly "-m xt-heap (refused, named)" 1 "does not implement" -q -m xt-heap -o @OUT@.xex ret.xc
xcconly "-m xt-test-fallover (refused)" 1 "does not implement" -q -m xt-test-fallover -o @OUT@.xex ret.xc
cover -dl --dump-layout --list-layouts -ll
text "-dl"                  out -dl
text "-dl -m xt"            out -dl -m xt
text "-dl -m xt6502/xt-heap" out -dl -m xt6502/xt-heap
text "--dump-layout -m xt-test-fallover" out --dump-layout -m xt-test-fallover
text "--list-layouts"       err --list-layouts
# The reference reads `-ll` as `-l l`, a library called `l`.
run "$REF" refout --list-layouts; cp refout.err.txt ll-ref.txt
run "$XC" xcout -ll
if [ $RC = 0 ] && cmp -s ll-ref.txt xcout.err.txt; then ok "-ll lists the layouts"
else bad "-ll does not list the layouts"; fi
cover -dp --dump-placement -du --dump-usage
same "-dp"                  -q -A 6502 -dp -o @OUT@.xex ret.xc
same "--dump-placement"     -q -A 6502 --dump-placement -o @OUT@.xex ret.xc
same "-du"                  -q -A 6502 -du -o @OUT@.xex ret.xc
same "--dump-usage"         -q -A 6502 --dump-usage -o @OUT@.xex ret.xc
cover -x-
same "-x-wasm32,return-call" -q -A wasm32 -x-wasm32,return-call -o @OUT@.wat tail.xc
if cmp -s refout.wat xcout.wat && grep -q "return_call" xcout.wat; then
    ok "-x-wasm32,return-call: identical WAT, with return_call"
else bad "-x-wasm32,return-call: WAT differs, or has no return_call"; fi
run "$XC" xcout -q -A wasm32 -o @OUT@.wat tail.xc
grep -q "return_call" xcout.wat && bad "return_call without -x-wasm32,return-call" \
    || ok "no return_call without -x-wasm32,return-call"
same "-x-arm64,foo (no such)" -q -A arm64 -x-arm64,foo -o @OUT@ ret.xc
same "-x-wasm32,foo (no such)" -q -A wasm32 -x-wasm32,foo -o @OUT@ ret.xc

# ── optimisation ────────────────────────────────────────────────────────
cover -O -O0 -O1 -O2 -O3 -Flu --fn-loop-unroll -Fli --fn-leaf-inline -Fmb --fn-min-banked -flto
for o in -O -O0 -O1 -O2 -O3; do same "$o" $A $o -o @OUT@.s hello.xc; done
cmp -s refout.s xcout.s && ok "-O3: identical assembly" || bad "-O3: assembly differs"
same "-O"                   $A -O -o @OUT@.s hello.xc
cmp -s refout.s xcout.s && ok "-O: identical assembly (-O1)" || bad "-O: assembly differs"
same "-Flu"                 $A -Flu 2 -o @OUT@ hello.xc
same "--fn-loop-unroll"     $A --fn-loop-unroll 2 -o @OUT@ hello.xc
same "-Fli 64"              $A -Fli 64 -o @OUT@.s tail.xc
cmp -s refout.s xcout.s && ok "-Fli 64 (the default ceiling): identical assembly" || bad "-Fli 64: assembly differs"
# -Fli 0 inlines nothing, so `leaf` is still called.
run "$XC" xcout $A -Fli 0 -o @OUT@.s tail.xc
grep -q "bl	_leaf\|bl _leaf" xcout.s && ! grep -q "bl	_leaf\|bl _leaf" refout.s \
    && ok "-Fli 0 stops the inliner" || bad "-Fli 0 changed nothing"
same "--fn-leaf-inline"     $A --fn-leaf-inline 10 -o @OUT@ hello.xc
same "-Fmb"                 -q -A 6502 -Fmb 50 -o @OUT@.xex ret.xc
same "--fn-min-banked"      -q -A 6502 --fn-min-banked 50 -o @OUT@.xex ret.xc
same "-flto (source build)" $A -flto -o @OUT@ ret.xc

# ── code-generation and runtime options ─────────────────────────────────
cover -fbounds-check -fauto-cloak= -farc -Q --quit-style -S --xtc-stack -ss --stack-size
cover -fnew-ir --with-ir --self-host --migrate=
same "-fbounds-check"       $A -fbounds-check -o @OUT@ ret.xc
for v in never auto always bogus; do same "-fauto-cloak=$v" $A -fauto-cloak=$v -o @OUT@ ret.xc; done
same "-farc"                $A -farc -o @OUT@ ret.xc
same "-farc=off"            $A -farc=off -o @OUT@ ret.xc
grep -q "retired" xcout.err.txt && ok "-farc warns that it is retired" || bad "-farc does not warn"
same "-Q rts"               -q -A 6502 -Q rts -o @OUT@.xex ret.xc
same "-Q loop"              -q -A 6502 -Q loop -o @OUT@.xex ret.xc
same "--quit-style loop"    -q -A 6502 --quit-style loop -o @OUT@.xex ret.xc
same "-Q bogus"             -q -A 6502 -Q bogus -o @OUT@.xex ret.xc
same "--xtc-stack"          -q -A 6502 --xtc-stack -o @OUT@.xex ret.xc

# ── the xt6502 options, checked for what they do ────────────────────────
# Each is built by both drivers, which must write the same bytes, and run on
# the simulator, whose exit status is main's value.
SIM="$ROOT/bin/osx/xcc-sim-6502"
simrc() { "$SIM" -m xt -d "$1" > /dev/null 2>&1; echo $?; }
# build6502 <tag> args… — both drivers, .xex and .s; they must agree byte for byte.
build6502() {
    local tag=$1; shift
    "$REF" -H "$ROOT" -q -A 6502 "$@" -o "$tag.ref.xex" > /dev/null 2>&1
    "$XC"  -H "$ROOT" -q -A 6502 "$@" -o "$tag.xc.xex"  > /dev/null 2>&1
    "$XC"  -H "$ROOT" -q -A 6502 "$@" -o "$tag.s"       > /dev/null 2>&1
    if [ -s "$tag.xc.xex" ] && cmp -s "$tag.ref.xex" "$tag.xc.xex"; then ok "$tag: the same .xex from both"
    else bad "$tag: the two drivers' .xex differ (or none was written)"; fi
}
cat > many.xc <<'EOF'
u8 tiny(u8 v)
{
    if (v == 0)
        return 0;
    return tiny(v - 1) + 1;
}
i32 big(i32 n)
{
    i32 a[8];
    i32 t = 0;
    for (i32 i = 0; i < 8; i++)
        a[i] = (i32)tiny((u8)(n + i)) * 3 - i;
    for (i32 i = 0; i < 8; i++)
        t = t + a[i] + (a[i] >> 1) - (a[i] & 5);
    return t;
}
i32 main(void)
{
    return big(2) - (i32)tiny(40);
}
EOF
# main returns 3 in ret.xc and 30 in tail.xc; many.xc returns 100.
build6502 quit-default ret.xc
build6502 quit-rts -Q rts ret.xc
build6502 quit-loop -Q loop ret.xc
[ "$(simrc quit-default.xc.xex)" = 3 ] && [ "$(simrc quit-rts.xc.xex)" = 3 ] \
    && ok "-Q rts (the default): main's value is the exit status" || bad "-Q rts: wrong exit status"
[ "$(simrc quit-loop.xc.xex)" = 3 ] && ok "-Q loop: main's value is the exit status" \
    || bad "-Q loop: wrong exit status"
grep -q "^_xt_quit:" quit-loop.s && grep -q "JMP _xt_quit" quit-loop.s \
    && ! grep -q "^_xt_quit:" quit-rts.s && cmp -s quit-default.s quit-rts.s \
    && ok "-Q loop jumps to itself after main; -Q rts is the default and returns" \
    || bad "-Q: the startup is not what the quit style says"

build6502 xtcstack --xtc-stack tail.xc
build6502 hwstack tail.xc
[ "$(simrc xtcstack.xc.xex)" = 30 ] && ok "--xtc-stack: the recursion returns 30" \
    || bad "--xtc-stack: wrong result ($(simrc xtcstack.xc.xex))"
if grep -q "xtc-stack frame push" xtcstack.s && ! grep -q "xtc-stack frame push" hwstack.s \
   && ! grep -A1 "^_xt_main:" xtcstack.s | grep -q "PSH #"; then
    ok "--xtc-stack: functions push their frame on the software stack, and only with the flag"
else bad "--xtc-stack: the prologues are not the software-stack ones"; fi
cat > annot.xc <<'EOF'
i32 soft(i32 v) :xtcStack
{
    if (v <= 0)
        return 0;
    return soft(v - 1) + 2;
}
i32 hard(i32 v) :hwStack
{
    if (v <= 0)
        return 0;
    return hard(v - 1) + soft(v);
}
i32 main(void)
{
    return hard(5);
}
EOF
build6502 annot annot.xc
build6502 annot-flag --xtc-stack annot.xc
[ "$(simrc annot.xc.xex)" = 30 ] && [ "$(simrc annot-flag.xc.xex)" = 30 ] \
    && ok ":xtcStack / :hwStack: the mixed recursion returns 30" || bad ":xtcStack / :hwStack: wrong result"
if grep -A1 "^_soft:" annot.s | grep -q "xtc-stack frame push" \
   && grep -A1 "^_hard:" annot.s | grep -q "PSH #" && grep -A1 "^_hard:" annot-flag.s | grep -q "PSH #" \
   && grep -A1 "^_xt_main:" annot-flag.s | grep -q "xtc-stack frame push"; then
    ok ":xtcStack opts a function in, :hwStack opts one out of --xtc-stack"
else bad ":xtcStack / :hwStack do not choose the prologue"; fi

# -dp against the assembly: every function it lists is in the section it names.
# placecheck <dp-text> <asm> — prints the first function whose place disagrees.
placecheck() {
    awk -v asm="$2" '
        BEGIN {
            where = "main"
            while ((getline line < asm) > 0) {
                if (line ~ /^; --- code bank [0-9]+/) { split(line, parts, " "); where = "bank " parts[5] }
                else if (line ~ /^_[A-Za-z0-9_$]+:$/) { lab = substr(line, 2, length(line) - 2); at[lab] = where }
            }
        }
        /^xcc: bytes used/ { done = 1 }
        !done && /^  (main|irq|vbi|bank [0-9]+) / {
            w = ($1 == "bank") ? "bank " $2 : "main"
            name = ($1 == "bank") ? $5 : $4
            lab = (name == "main") ? "xt_main" : name
            n++
            if (at[lab] != w) { print name " is " w " in -dp, " at[lab] " in the assembly"; exit }
        }
        END { if (n == 0) print "no functions listed" }' "$1"
}
for mb in 0 50; do
    run "$REF" refout -q -A 6502 -Fmb $mb -dp -o @OUT@.xex many.xc
    run "$XC" xcout -q -A 6502 -Fmb $mb -dp -o @OUT@.xex many.xc
    cmp -s refout.err.txt xcout.err.txt && ok "-dp -Fmb $mb: both print the same placement" \
        || { bad "-dp -Fmb $mb: the placements printed differ"; diff refout.err.txt xcout.err.txt | head -5; }
    cp xcout.err.txt dp$mb.txt
    "$XC" -H "$ROOT" -q -A 6502 -Fmb $mb -o many$mb.s many.xc > /dev/null 2>&1
    why=$(placecheck dp$mb.txt many$mb.s)
    [ -z "$why" ] && ok "-dp -Fmb $mb: every function is where the assembly puts it" || bad "-dp -Fmb $mb: $why"
    cmp -s refout.xex xcout.xex && [ "$(simrc xcout.xex)" = 100 ] \
        && ok "-Fmb $mb: the same .xex from both, and it returns 100" || bad "-Fmb $mb: .xex differs or wrong result"
done
grep -q "^  bank [0-9]* .* tiny$" dp0.txt && grep -q "^  main .* tiny (.* instructions, under -Fmb 50)$" dp50.txt \
    && grep -q "^  bank [0-9]* .* big$" dp50.txt \
    && ok "-Fmb 50: the small function moves to main RAM, the large one stays banked" \
    || bad "-Fmb 50 did not move the small function out of its bank"

# -du against the assembly: one line per code bank the assembly fills.
for t in many.xc hello.xc; do
    run "$REF" refout -q -A 6502 -du -o @OUT@.xex $t
    run "$XC" xcout -q -A 6502 -du -o @OUT@.xex $t
    cmp -s refout.err.txt xcout.err.txt && ok "-du ($t): both print the same usage" \
        || { bad "-du ($t): the usage printed differs"; diff refout.err.txt xcout.err.txt | head -5; }
    "$XC" -H "$ROOT" -q -A 6502 -o du.s $t > /dev/null 2>&1
    banks=$(( $(grep -c "^; --- code bank" du.s) + $(grep -c "^ *\.bank " du.s) ))
    lines=$(grep -c "^  code bank [0-9]" xcout.err.txt)
    [ "$banks" = "$lines" ] && grep -q "^  system " xcout.err.txt && grep -q "unused: code banks" xcout.err.txt \
        && ok "-du ($t): $lines code bank(s), as the assembly has" \
        || bad "-du ($t): $lines code bank line(s), the assembly has $banks"
done
run "$XC" xcout -q -A 6502 -du -o @OUT@.s ret.xc
[ $RC = 0 ] && [ -s xcout.s ] && grep -q "^  system " xcout.err.txt \
    && ok "-du with -o x.s: writes the assembly and measures it" || bad "-du with -o x.s"
# -S means "keep the assembly" in xcc-xc; the reference takes it and leaves the
# choice to the output's extension. It is not --xtc-stack's short form, so an
# xt6502 build with -S uses the default convention.
equiv "-S (keep assembly)"  "$A -o refout.s ret.xc"  "$A -S -o xcout.s ret.xc"
"$XC" -H "$ROOT" -q -A 6502 -S -o s6502.s tail.xc > /dev/null 2>&1
"$REF" -H "$ROOT" -q -A 6502 -S -o s6502ref.s tail.xc > /dev/null 2>&1
! grep -q "xtc-stack frame push" s6502.s && cmp -s s6502.s s6502ref.s \
    && ok "-S on xt6502: assembly, with the hardware-stack convention, in both" \
    || bad "-S on xt6502 selected the software-stack convention or the drivers differ"
for v in "-ss 512" "-ss=\$200" "--stack-size 0x200" "--stack-size=512" "-ss 0" "-ss 70000"; do
    same "$v"               $A $v -o @OUT@ ret.xc
done
same "-fnew-ir"             $A -fnew-ir -o @OUT@ ret.xc
same "--with-ir"            $A --with-ir -o @OUT@ ret.xc
same "--self-host"          $A --self-host -o @OUT@ ret.xc
same "--migrate=0.3:0.4"    $A --migrate=0.3:0.4 -o @OUT@ ret.xc

# ── warnings ────────────────────────────────────────────────────────────
cover -Wno- -W -Wanalyze
same "-Wno-escape"          $A -Wno-escape -o @OUT@ ret.xc
same "-Wno-<unknown>"       $A -Wno-nosuchcategory -o @OUT@ ret.xc
# The reference warns "unknown option" for these and carries on: it takes
# the command line, it just does not know the flag.
xcconly "-W"          0 ""  $A -W -o @OUT@ ret.xc
xcconly "-Wanalyze"   0 ""  $A -Wanalyze -o @OUT@ ret.xc

# ── linking ─────────────────────────────────────────────────────────────
cover -l -framework -Xlinker -Wl, --link-libs
same "-lz"                  $A -lz -o @OUT@ hello.xc
same "-framework"           $A -framework CoreFoundation -o @OUT@ hello.xc
printf 'i32 helper(void)\n{\n    return 1;\n}\n' > helper.xc
"$REF" -H "$ROOT" -q -A arm64 -c -o lib.o helper.xc >/dev/null 2>&1
same "-Xlinker <file>"      $A -Xlinker lib.o -o @OUT@ hello.xc
same "-Wl,<file>"           $A -Wl,lib.o -o @OUT@ hello.xc
for t in arm64 ios-sim; do
    same "-Wl,-rpath (-A $t)"   -q -A $t -Wl,-rpath,/tmp/rp -o @OUT@ ret.xc
    if [ "$(otool -l refout 2>/dev/null | grep -A2 LC_RPATH | grep path)" = \
         "$(otool -l xcout 2>/dev/null | grep -A2 LC_RPATH | grep path)" ] \
       && otool -l xcout | grep -q "/tmp/rp"; then ok "-rpath (-A $t): the same LC_RPATH entries"
    else bad "-rpath (-A $t): LC_RPATH entries differ"; fi
done
same "-Xlinker -rpath -Xlinker" $A -Xlinker -rpath -Xlinker /tmp/rp -o @OUT@ ret.xc
cmp -s refout xcout && ok "-Xlinker -rpath: identical executable" || bad "-Xlinker -rpath: executables differ"
same "-Xlinker <flag>"      $A -Xlinker -dead_strip -o @OUT@ ret.xc
grep -q "ignoring unrecognised linker flag '-dead_strip'" xcout.err.txt \
    && ok "-Xlinker <flag>: named and skipped" || bad "-Xlinker <flag>: not reported"
same "-Wl,<flag>"           $A -Wl,--gc-sections -o @OUT@ ret.xc
# Where the reference hands a raw flag to the system toolchain, xcc-xc (which
# never uses one) links in-house, names the flag and skips it.
for t in x86_64 win64; do
    run "$XC" xcout -q -A $t -Wl,--gc-sections -o @OUT@ ret.xc
    if [ $RC = 0 ] && grep -q "ignoring unrecognised linker flag" xcout.err.txt; then
        ok "-Wl,<flag> (-A $t): linked in-house, flag named"
    else bad "-Wl,<flag> (-A $t): status $RC"; fi
done
for t in android wasm32 m68k 6502; do
    case $t in 6502) o=@OUT@.xex ;; *) o=@OUT@ ;; esac
    same "-Wl,<flag> (-A $t)" -q -A $t -Wl,--gc-sections -o $o ret.xc
done
( export XTC_LDFLAGS="-Wl,-rpath,/tmp/envrp"; "$REF" -H "$ROOT" -q -A arm64 -o r ret.xc; \
  "$XC" -H "$ROOT" -q -A arm64 -o x ret.xc ) > /dev/null 2>&1
if [ "$(otool -l r | grep -A2 LC_RPATH | grep path)" = "$(otool -l x | grep -A2 LC_RPATH | grep path)" ] \
   && otool -l x | grep -q /tmp/envrp; then ok "XTC_LDFLAGS: -rpath reaches the link"
else bad "XTC_LDFLAGS: the LC_RPATH entries differ"; fi
( export XTC_LDFLAGS="lib.o"; "$XC" -H "$ROOT" -q -A arm64 -o x hello.xc ) > /dev/null 2>&1 \
    && ok "XTC_LDFLAGS: an object joins the link" || bad "XTC_LDFLAGS: an object did not link"
# --link-libs: the reference passes it to its wasm32 code generator when an app
# imports a .wasm library, and knows no option of that name; xcc-xc takes it.
xcconly "--link-libs (-A wasm32)" 0 "" -q -A wasm32 --link-libs -o @OUT@.wat ret.xc
grep -q "__data_end" xcout.wat && ok "--link-libs: the app exports __data_end" \
    || bad "--link-libs: no link-libs exports"
run "$XC" xcout -q -A wasm32 -o @OUT@.wat ret.xc
grep -q "__data_end" xcout.wat && bad "__data_end exported without --link-libs" \
    || ok "no link-libs exports without --link-libs"
xcconly "--link-libs (-A arm64, refused)" 1 "applies to -A wasm32" -q -A arm64 --link-libs -o @OUT@ ret.xc

# ── code generation, linking and packaging ──────────────────────────────
# caps-diff compares these byte for byte over a fixture sample; here each is
# checked for acceptance, status and output kind on both drivers.
cover -fthread-safe-arc -fno-thread-safe-arc -fmalloc= -falloc= -fpic -fPIC -mpic \
      -mhard-float -mfpu -msoft-float -g --no-self-host --needed --with-lib --lib-name \
      --with-dex
same "-fthread-safe-arc"    -q -fthread-safe-arc -o @OUT@ ret.xc
same "-fno-thread-safe-arc" -q -fno-thread-safe-arc -o @OUT@ ret.xc
same "-fmalloc=system"      -q -A x86_64 -fmalloc=system -o @OUT@ ret.xc
same "-fmalloc=mimalloc"    -q -A x86_64 -fmalloc=mimalloc -o @OUT@ ret.xc
same "-falloc=heap"         -q -falloc=heap -o @OUT@ ret.xc
same "-falloc=bump"         -q -falloc=bump -o @OUT@ ret.xc
same "-fpic (m68k)"         -q -A m68k -fpic -o @OUT@.prg ret.xc
same "-fPIC (m68k)"         -q -A m68k -fPIC -o @OUT@.prg ret.xc
same "-mpic (m68k)"         -q -A m68k -mpic -o @OUT@.prg ret.xc
same "-mhard-float (m68k)"  -q -A 68030 -mhard-float -o @OUT@.prg ret.xc
same "-mfpu (m68k)"         -q -A 68030 -mfpu -o @OUT@.prg ret.xc
same "-msoft-float (m68k)"  -q -A m68k -msoft-float -o @OUT@.prg ret.xc
same "-g"                   -q -g -o @OUT@ ret.xc
same "--no-self-host"       -q --no-self-host -o @OUT@ ret.xc
same "--needed"             -q -A android --needed libfoo.so -o @OUT@ ret.xc
"$XC" -H "$ROOT" -q -A android --emit-lib -o libextra.so ret.xc >/dev/null 2>&1
printf 'dex\n035\0' > classes.dex
same "--with-lib"           -q -A android --emit-apk --with-lib libextra.so -o @OUT@.apk ret.xc
same "--lib-name"           -q -A android --emit-apk --lib-name main -o @OUT@.apk ret.xc
same "--with-dex"           -q -A android --emit-apk --with-dex classes.dex -o @OUT@.apk ret.xc
same "--emit-lib (android)" -q -A android --emit-lib -o @OUT@.so ret.xc
xcconly "--emit-lib (m68k, refused)" 1 "has no shared-library format" -q -A m68k --emit-lib -o @OUT@ ret.xc
xcconly "--emit-lib (6502, refused)" 1 "has no shared-library format" -q -A 6502 --emit-lib -o @OUT@ ret.xc
xcconly "--emit-lib (win64, refused)" 1 "not supported for 'win64'" -q -A win64 --emit-lib -o @OUT@ ret.xc

# Signing needs a developer identity; these are covered by the signing tests.
cover --sign --sign-entitlements --sign-key

# ── every option the reference's --help names is covered here ─────────
"$REF" --help 2>&1 | sed -n 's/^  \(-[^ ]*\(, -[^ ]*\)*\).*/\1/p' | tr ',' '\n' | \
    sed 's/^ *//; s/<.*//; s/\[.*//; s/=.*/=/' | sort -u > helpopts.txt
missing=""
while read -r o; do
    [ -z "$o" ] && continue
    case "$COVERED" in *" $o "*) ;; *) missing="$missing $o" ;; esac
done < helpopts.txt
if [ -n "$missing" ]; then bad "the reference's --help names options this script does not check:$missing"
else ok "every option in the reference's --help is checked ($(wc -l < helpopts.txt | tr -d ' '))"; fi

echo
echo "flag-parity: $PASS passed, $FAIL failed, $PEND pending"
[ $FAIL = 0 ]
