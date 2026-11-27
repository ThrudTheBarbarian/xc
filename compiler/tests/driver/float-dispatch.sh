#!/bin/bash
# float-dispatch.sh — every version of a float-dispatched program gives the
# same answers.
#
# A program built in one invocation at -O2 has a version of each function
# whose f16 code gains from a higher level, picked at load: on arm64 ARMv8.0
# and FP16 (`$fp16`), on x86-64 SSE2, AVX2 with F16C (`$avx2`) and AVX-512.
# XC_SIMD forces one. This builds every f16, bf16, f8 and f4 fixture that
# applies to this machine once, runs it under each value of XC_SIMD, and
# builds and runs it again at each fixed level (-march=); every run must print
# the fixture's expected output. It also checks that the dispatch is there: an
# f16 multiply-add is cloned, the table names the clone, and a fixed level
# builds one version.
#
# Runs on the machine it is on (arm64 macOS or Linux, x86-64 Linux).
#   [XC=<xcc>] bash tests/driver/float-dispatch.sh
set -u
export LC_ALL=C
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
case "$(uname -m)" in
    arm64|aarch64) CPU=arm64;  LEVELS="base fp16";        FIXED="-march=pi4 -march=pi5 -march=armv8.2-a+fp16+dotprod" ;;
    x86_64|amd64)  CPU=x86_64; LEVELS="base avx2 avx512"; FIXED="-march=x86-64 -march=x86-64-v3 -march=x86-64-v4" ;;
    *) echo "float-dispatch: no float dispatch on $(uname -m)"; exit 0 ;;
esac
fail=0; runs=0
bad() { echo "FAIL float-dispatch: $*"; fail=1; }

# The dispatch is there: a clone, a table naming it, and one version under a
# fixed level.
cat > "$W/mad.xc" <<'XC'
#import "Stdio.xc"
f16 mad(f16 a, f16 b, f16 c) { return a * b + c; }
i32 main(i32 argc, u8** argv)
{
    f16 x = (f16)(1.5 * (f32)argc);
    f16 z = mad(x, (f16)2.25, x);
    Stdio.printf("%x\n", (u32)*(u16*)&z);
    return 0;
}
XC
if [ $CPU = arm64 ]; then
    for row in arm64 arm64-linux android; do
        "$XC" -q -O2 -A $row -S -o "$W/m.s" "$W/mad.xc" || { bad "-A $row does not build"; continue; }
        grep -q '^_main\$fp16:' "$W/m.s" && grep -q 'b __xt_simd_select' "$W/m.s" \
            && grep -qE 'fmul[[:space:]]+h' "$W/m.s" || bad "-A $row: no FP16 clone and table"
        "$XC" -q -O2 -A $row -march=pi4 -S -o "$W/m.s" "$W/mad.xc"
        ! grep -qE 'simd_table|fmul[[:space:]]+h' "$W/m.s" || bad "-A $row -march=pi4 is not one ARMv8.0 version"
        "$XC" -q -O2 -A $row -march=pi5 -S -o "$W/m.s" "$W/mad.xc"
        ! grep -q 'simd_table' "$W/m.s" && grep -qE 'fmul[[:space:]]+h' "$W/m.s" || bad "-A $row -march=pi5 is not one FP16 version"
    done
fi
for row in x86_64 win64; do
    "$XC" -q -O2 -A $row -S -o "$W/m.s" "$W/mad.xc" || { bad "-A $row does not build"; continue; }
    grep -q '^main\$avx2:' "$W/m.s" && grep -q '__xt_simd_table' "$W/m.s" && grep -q vcvtps2ph "$W/m.s" \
        || bad "-A $row: no F16C clone and table"
    "$XC" -q -O2 -A $row -march=x86-64 -S -o "$W/m.s" "$W/mad.xc"
    ! grep -qE 'simd_table|vcvtps2ph' "$W/m.s" || bad "-A $row -march=x86-64 is not one SSE2 version"
done

# Every fixture, every level.
for f in tests/fixtures/f16_*.xc tests/fixtures/f8_*.xc tests/fixtures/f4_*.xc \
         tests/fixtures/par_f16.xc tests/fixtures/par_pack_gpu.xc tests/fixtures/par_f4_cut.xc; do
    name=$(basename "$f" .xc)
    exp=tests/fixtures/$name.expected.out
    [ -f "$exp" ] || continue
    grep -qE "^//xtc-na:.*\b$CPU\b" "$f" && continue
    grep -q "^//xtc-flags: target=" "$f" && ! grep -qE "^//xtc-flags: target=.*\b$CPU\b" "$f" && continue
    "$XC" -q -O2 -o "$W/$name" "$f" || { bad "$name does not build"; continue; }
    for lv in $LEVELS; do
        XC_SIMD=$lv XC_PAR=cpu "$W/$name" > "$W/out" 2>/dev/null
        cmp -s "$W/out" "$exp" || bad "$name under XC_SIMD=$lv differs from $exp"
        runs=$((runs + 1))
    done
    for m in $FIXED; do
        "$XC" -q -O2 $m -o "$W/$name.f" "$f" || { bad "$name $m does not build"; continue; }
        # A fixed level the machine lacks cannot run here.
        XC_PAR=cpu "$W/$name.f" > "$W/out" 2>/dev/null || { [ $? -ge 128 ] && continue; }
        cmp -s "$W/out" "$exp" || bad "$name $m differs from $exp"
        runs=$((runs + 1))
    done
done
[ $fail = 0 ] && echo "PASS float-dispatch ($CPU: $runs runs, levels $LEVELS)"
exit $fail
