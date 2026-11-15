#!/bin/bash
# scan.sh — par :scan(op acc), running totals as blocks (#144).
# Each case runs a :scan block and the same loop serially in one program and
# compares every element and the final accumulator: inclusive and exclusive
# shapes, every operator, signed and unsigned types, lengths around the 256
# chunks (0, 1, 255, 256, 257) and a long one, an inclusive range, a float +
# under the speed goal (and under accuracy, where it stays serial). Then the
# forms the rewrite refuses, each with its message.
#
#   bash tests/par/scan.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0

# case: name type op n update store(incl|excl) range(..|...)
run_case() {
    local name=$1 ty=$2 op=$3 n=$4 upd=$5 shape=$6 rng=${7:-..}
    local body ser
    if [ "$shape" = incl ]; then
        body="$upd out[i] = acc;"; ser="${upd//acc/r} ref[i] = r;"
    else
        body="out[i] = acc; $upd"; ser="ref[i] = r; ${upd//acc/r}"
    fi
    local hi="n"; [ "$rng" = "..." ] && hi="n - (u32)1"
    cat > "$W/$name.xc" <<XC
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 n = (u32)$n;
    u32 len = n == (u32)0 ? (u32)1 : n;
    $ty* x = new $ty[len];
    $ty* out = new $ty[len];
    $ty* ref = new $ty[len];
    for (u32 i in 0..n) { x[i] = ($ty)((i * (u32)2654435761) % (u32)97) - ($ty)40; out[i] = ($ty)0; ref[i] = ($ty)0; }
    $ty acc = ($ty)3;
    par $name :scan($op acc)
        {
        for (u32 i in (u32)0${rng}$hi)
            {
            $body
            }
        }
    $ty r = ($ty)3;
    if (n > (u32)0)
        for (u32 i in (u32)0${rng}$hi)
            {
            $ser
            }
    u32 bad = (u32)0;
    for (u32 i in 0..n) if (out[i] != ref[i]) bad++;
    Stdio.printf("bad=%u same=%u\n", bad, acc == r ? (u32)1 : (u32)0);
    return 0;
    }
XC
    if ! "$XC" -q -O2 -o "$W/$name" "$W/$name.xc" 2> "$W/$name.err"; then
        echo "  FAIL: $name: build"; sed 's/^/    /' "$W/$name.err" | head -5; fail=1; return
    fi
    local got; got=$("$W/$name" 2>&1)
    if [ "$got" = "bad=0 same=1" ]; then echo "  ok: $name"; else echo "  FAIL: $name: $got"; fail=1; fi
}

run_case add_incl   i64 +   100003 "acc += x[i];"            incl
run_case add_excl   i64 +   100003 "acc += x[i];"            excl
run_case add_long   i32 +   3000017 "acc = acc + x[i];"      incl
run_case add_n0     i64 +   0      "acc += x[i];"            incl
run_case add_n1     i64 +   1      "acc += x[i];"            incl
run_case add_n255   i64 +   255    "acc += x[i];"            excl
run_case add_n256   i64 +   256    "acc += x[i];"            incl
run_case add_n257   u32 +   257    "acc += x[i];"            incl
run_case add_range  i64 +   1000   "acc += x[i];"            incl ...
run_case add_pp     u64 +   5000   "acc++;"                  incl
run_case or_incl    u32 \|  20011  "acc |= x[i] << (i % (u32)20);" incl
run_case and_incl   u64 \&  20011  "acc &= ~((u64)1 << (u64)(i % (u32)60));" excl
run_case xor_incl   i16 ^   20011  "acc ^= x[i];"            incl
run_case min_incl   i32 min 50021  "if (x[i] * (i32)(i % (u32)7) < acc) acc = x[i] * (i32)(i % (u32)7);" incl
run_case max_excl   i64 max 50021  "if (x[i] * (i64)(i % (u32)7) > acc) acc = x[i] * (i64)(i % (u32)7);" excl
run_case min_u8     u8  min 777    "if (x[i] < acc) acc = x[i];" incl

# float +: under the speed goal (the default) parallel, compared with a
# tolerance; under accuracy the loop stays serial and is exact.
cat > "$W/flt.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 n = (u32)200003;
    double* x = new double[n];
    double* out = new double[n];
    double* acc2 = new double[n];
    for (u32 i in 0..n) x[i] = (double)(i % (u32)101) * 0.25;
    double acc = 1.0;
    par :scan(+ acc) { for (u32 i in 0..n) { acc += x[i]; out[i] = acc; } }
    double b = 1.0;
    par :scan(+ b) :goal(accuracy) { for (u32 i in 0..n) { b += x[i]; acc2[i] = b; } }
    double r = 1.0;
    u32 bad = (u32)0;
    u32 inexact = (u32)0;
    for (u32 i in 0..n)
        {
        r += x[i];
        double d = out[i] - r;
        if (d < 0.0) d = 0.0 - d;
        if (d > 1e-6 * r) bad++;
        if (acc2[i] != r) inexact++;
        }
    Stdio.printf("bad=%u inexact=%u\n", bad, inexact);
    return 0;
    }
XC
if "$XC" -q -O2 -o "$W/flt" "$W/flt.xc" 2> "$W/flt.err"; then
    got=$("$W/flt" 2>&1)
    [ "$got" = "bad=0 inexact=0" ] && echo "  ok: float +, speed and accuracy" || { echo "  FAIL: float: $got"; fail=1; }
else
    echo "  FAIL: float: build"; sed 's/^/    /' "$W/flt.err" | head -5; fail=1
fi

# The passes run as blocks, on the CPU, and say nothing.
if XC_PAR_REPORT=1 "$W/add_long" 2>&1 | grep -q "add_long: 256 items on the CPU" \
   && XC_PAR_REPORT=1 "$W/add_long" 2>&1 | grep -q "add_long_offsets: 256 items on the CPU"; then
    echo "  ok: both passes run as blocks on the CPU"
else
    echo "  FAIL: the passes did not run as blocks"; XC_PAR_REPORT=1 "$W/add_long" 2>&1 | sed 's/^/    /' | head -6; fail=1
fi
if grep -q "warning" "$W/add_long.err"; then echo "  FAIL: a :scan warned"; sed 's/^/    /' "$W/add_long.err" | head -3; fail=1; fi

# Refused forms.
refuse() {
    local name=$1 want=$2 body=$3 dec=${4:-":scan(+ acc)"}
    cat > "$W/$name.xc" <<XC
#import "Par.xc"
i32 main(void)
    {
    i64* x = new i64[10];
    i64* out = new i64[10];
    i64* y = new i64[10];
    i64 acc = (i64)0;
    double f = 0.0;
    par $dec { for (u32 i in 0..10) { $body } }
    return (i32)acc + (i32)f;
    }
XC
    if "$XC" -q -o "$W/$name" "$W/$name.xc" > "$W/$name.out" 2>&1; then
        echo "  FAIL: $name: accepted"; fail=1
    elif grep -qF "$want" "$W/$name.out"; then
        echo "  ok: refuses $name"
    else
        echo "  FAIL: $name: wrong message"; sed 's/^/    /' "$W/$name.out" | head -3; fail=1
    fi
}
refuse other_use "may only be updated" "acc += x[i]; out[i] = acc * (i64)2;"
refuse no_store  "with no store it is a :reduce" "acc += x[i];"
refuse no_update "updates its variable" "out[i] = acc;"
refuse out_read  "output array 'out' is only stored" "acc += x[i]; out[i] = acc; y[i] = out[i];"
refuse cond_store "may only be updated" "acc += x[i]; if (x[i] > (i64)0) out[i] = acc;"
refuse break     "no break, return or goto" "acc += x[i]; out[i] = acc; if (x[i] > (i64)5) break;"
refuse wrong_op  "may only be updated" "acc *= x[i]; out[i] = acc;"
refuse with_reduce "combines only with ':goal'" "acc += x[i]; out[i] = acc;" ":scan(+ acc) :reduce(+ acc)"
refuse bad_dec   "wants an operator" "acc += x[i]; out[i] = acc;" ":scan(* acc)"
refuse float_min "a floating-point ':scan' takes only +" "if ((double)x[i] < f) f = (double)x[i]; out[i] = acc;" ":scan(min f)"

[ $fail = 0 ] && echo "--- scan: pass ---" || echo "--- scan: FAIL ---"
exit $fail
