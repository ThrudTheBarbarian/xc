#!/bin/bash
# devirt.sh — guarded devirtualisation (OptDevirt / XTIROptDevirtualise): a
# virtual call in a loop whose method has few, small implementations tests
# the receiver's class and calls the matching method directly.
#
#   (a) runA: the receiver does not change in the loop, so the loop is
#       versioned on its class — a copy per class (blocks `_dv<n>_v<k>`) with
#       no indirect call left in it;
#   (b) runB: an array of mixed classes, so the call is split in place — a
#       test chain (`_dv<n>_c<k>`) and the dispatch as the fallback (`_virt`);
#   (c) the four classes there include OpKeep, which inherits OpMul's method:
#       its own vtable is a candidate (`_c3`) and it prints the right value;
#   (d) runD: a method with a loop is not a small leaf: no `_dv` block.
#   (e) runE: (a) with the loop at the function's very entry, where the memory
#       token is the function's own parameter.
#
# Both compilers write the same assembly (arm64 Linux and x86-64 Linux; macOS
# on a Mac), and built for this machine with -O0 (no devirtualisation) and
# -O3 the program prints the same values. x86-64 builds SIMD dispatch
# variants of a function with a loop: there the `$base` variant is read.
#
#   bash tests/driver/devirt.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/devirt.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0

cat > "$W/d.xc" <<'EOF'
#import "Stdio.xc"
#define N 64
class Shape { u32 k; void init(u32 x) { k = x; } u32 score(u32 x) { return k ^ x; } }
class Boxy : Shape { void init(u32 x) { super.init(x); } u32 score(u32 x) { return (k ^ x) + (u32)1; } }
class Op { u32 k; void init(u32 x) { k = x; } u32 apply(u32 v) { return v + k; } }
class OpMul : Op { void init(u32 x) { super.init(x); } u32 apply(u32 v) { return v * (k | (u32)1); } }
class OpXor : Op { void init(u32 x) { super.init(x); } u32 apply(u32 v) { return v ^ k; } }
class OpKeep : OpMul { void init(u32 x) { super.init(x); } }
class Big { u32 k; void init(u32 x) { k = x; } u32 work(u32 v) { u32 t = v; for (u32 j = (u32)0; j < k; j++) t = t * (u32)3 + (u32)1; return t; } }
class Bigger : Big { void init(u32 x) { super.init(x); } u32 work(u32 v) { return v + k; } }

u32 gCalls;

// (a) A store before the loop: the token comes from it.
u32 runA(Shape* s, u32 n)
    {
    gCalls = gCalls + (u32)1;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < n; r++)
        acc = acc + s.score(r);
    return acc;
    }

// (e) The loop at the very entry: the token is the function's own.
u32 runE(Shape* s, u32 n)
    {
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < n; r++)
        acc = acc + s.score(r);
    return acc;
    }

// (b), (c)
u32 runB(Op** ops, u32 n)
    {
    u32 acc = (u32)1;
    for (u32 r = (u32)0; r < n; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = ops[i].apply(acc) + r;
    return acc;
    }

// (d)
u32 runD(Big* b, u32 n)
    {
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < n; r++)
        acc = acc + b.work(r);
    return acc;
    }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    Shape* s1 = new Shape(seed + (u32)5);
    Shape* s2 = new Boxy(seed + (u32)7);
    Op* ops[N];
    for (u32 i = (u32)0; i < (u32)N; i++)
        {
        if ((i % (u32)4) == (u32)0)      ops[i] = new Op(i + seed);
        else if ((i % (u32)4) == (u32)1) ops[i] = new OpMul(i + seed);
        else if ((i % (u32)4) == (u32)2) ops[i] = new OpXor(i + seed);
        else                             ops[i] = new OpKeep(i + seed);
        }
    Big* b1 = new Big(seed + (u32)3);
    Big* b2 = new Bigger(seed + (u32)4);
    Stdio.printf("a %lu %lu\n", runA(s1, (u32)1000), runA(s2, (u32)1000));
    Stdio.printf("e %lu %lu\n", runE(s1, (u32)1000), runE(s2, (u32)1000));
    Stdio.printf("b %lu\n", runB((Op**)ops, (u32)100));
    Stdio.printf("d %lu %lu\n", runD(b1, (u32)100), runD(b2, (u32)100));
    return 0;
    }
EOF
WANT='a 499500 500564
e 499500 500564
b 1051777601
d 404950 5450'

# The body of function $2 in assembly file $1 ($2$base when there is one),
# from its label to the next .globl.
body() {
    local f=$2
    grep -qE "^_?$f\\\$base:\$" "$1" && f="$f\$base"
    awk -v f="$f" '{ l = $0; sub(/^_/, "", l) } l == f ":" { p = 1; next } p && /\.globl/ { exit } p' "$1"
}

TARGETS="arm64-linux x86_64-linux"; [ "$PLAT" = osx ] && TARGETS="arm64-linux x86_64-linux arm64"   # macOS needs its SDK frameworks
for A in $TARGETS; do
    for C in "$REF" "$XC"; do
        n=$(basename "$C")
        if ! "$C" -q -O3 -A "$A" -H . -S -o "$W/d.$A.$n.s" "$W/d.xc" 2> "$W/err"; then
            echo "FAIL $n -A $A: build"; head -5 "$W/err"; fail=1
        fi
    done
    if ! cmp -s "$W/d.$A.xcc.s" "$W/d.$A.xcc-xc.s"; then
        echo "FAIL -A $A: the two compilers write different assembly"; fail=1
    fi
    s="$W/d.$A.xcc-xc.s"
    body "$s" runA > "$W/a"; body "$s" runB > "$W/b"; body "$s" runD > "$W/d"; body "$s" runE > "$W/e"
    # (a) copies exist, and none makes an indirect call.
    nv=$(grep -cE '_dv[0-9]+_v[0-9]+[^:]*:$' "$W/a")
    ind=$(awk '/:$/ { c = ($0 ~ /_dv[0-9]+_v[0-9]+/) } c && /(^|[[:space:]])blr[[:space:]]|call[[:space:]]+(r[0-9a-z]+|qword|\*)/ { n++ } END { print n + 0 }' "$W/a")
    [ "$nv" -ge 2 ] || { echo "FAIL -A $A: runA is not versioned ($nv copy blocks)"; fail=1; }
    [ "$ind" = 0 ] || { echo "FAIL -A $A: $ind indirect calls in runA's class copies"; fail=1; }
    ne=$(grep -cE '_dv[0-9]+_v[0-9]+[^:]*:$' "$W/e")
    [ "$ne" -ge 2 ] || { echo "FAIL -A $A: runE (a loop at the function's entry) is not versioned ($ne copy blocks)"; fail=1; }
    # (b), (c) the test chain over four classes and the fallback.
    grep -qE '_dv[0-9]+_c3:$' "$W/b" || { echo "FAIL -A $A: runB has no test for a fourth class (OpKeep)"; fail=1; }
    grep -qE '_dv[0-9]+_virt:$' "$W/b" || { echo "FAIL -A $A: runB has no fallback dispatch"; fail=1; }
    # (d)
    if grep -qE '_dv[0-9]+_' "$W/d"; then echo "FAIL -A $A: runD was devirtualised"; fail=1; fi
done

# This machine: -O0 (no devirtualisation) and -O3 print the same values.
case "$PLAT-$(uname -m)" in
    osx-arm64)                NATIVE=arm64 ;;
    linux-x86_64)             NATIVE=x86_64-linux ;;
    linux-aarch64|linux-arm64) NATIVE=arm64-linux ;;
    *)                        NATIVE= ;;
esac
if [ -n "$NATIVE" ]; then
    for C in "$REF" "$XC"; do
        n=$(basename "$C")
        for o in O0 O3; do
            "$C" -q -$o -A "$NATIVE" -H . -o "$W/d.$o.$n" "$W/d.xc" 2> "$W/err" || { echo "FAIL $n -$o: build"; head -5 "$W/err"; fail=1; continue; }
            got=$("$W/d.$o.$n")
            [ "$got" = "$WANT" ] || { echo "FAIL $n -$o: printed"; echo "$got"; echo "want"; echo "$WANT"; fail=1; }
        done
    done
fi
[ $fail = 0 ] && echo "devirt: ok"
exit $fail
