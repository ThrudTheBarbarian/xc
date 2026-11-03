#!/bin/bash
# par-auto-fallback.sh — --par-style=auto never runs slower or wrong than the
# loop as written (2026-11-03: 0.9.2's release benchmarks ran 2-38x slower
# than 0.9.1, and two gave wrong answers).
#
#   1. A loop par-check demotes is built as the loop: its site's block (the
#      ParImpl class, Par.run) is gone from main.
#   2. A two-deep nest of more points than a u32 counts (4097 x 1048576)
#      prints what --par-style=cpu prints: it runs as the loop.
#   3. A small constant loop with no call is not lifted at all.
#
# Both compilers, the same code from each.
#
#   bash tests/driver/par-auto-fallback.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/par-auto-fallback.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0

cat > "$W/demoted.xc" <<'EOF'
#import "Stdio.xc"
#define N 100000
u32 c[N];
i32 main(i32 argc, u8** argv)
    {
    for (u32 i = (u32)0; i < (u32)N; i++) c[(i * (u32)7) % (u32)N] = c[i] + (u32)argc;
    Stdio.printf("%u\n", c[5]);
    return 0;
    }
EOF
cat > "$W/wide.xc" <<'EOF'
#import "Stdio.xc"
#define N 1048576
u32 a[N];
i32 main(i32 argc, u8** argv)
    {
    for (u32 i = (u32)0; i < (u32)N; i++) a[i] = i * (u32)2654435761 + (u32)argc;
    u32 sum = (u32)0;
    for (u32 r = (u32)0; r < (u32)4097; r++)
        for (u32 i = (u32)0; i < (u32)N; i++) sum = sum + a[i];
    Stdio.printf("%u\n", sum);
    return 0;
    }
EOF
cat > "$W/small.xc" <<'EOF'
#import "Stdio.xc"
#define N 4096
float a[N];
i32 main(i32 argc, u8** argv)
    {
    for (u32 i = (u32)0; i < (u32)(N * 2 - N); i++) a[i] = (float)(i % (u32)16);
    Stdio.printf("%.1f\n", (double)a[17]);
    return 0;
    }
EOF

# main's code: from its label to the next function's .globl (local labels,
# Lfoo: on Mach-O, do not end it).
main_of() { awk '/^_?main:$/{p=1;next} /\.globl/{p=0} p' "$1"; }
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    n=$(basename "$c")
    # 1. The demoted block's site is gone.
    "$c" -q -O2 -H . --no-runtime-lib -S -o "$W/demoted.$n.s" "$W/demoted.xc" || { echo "FAIL par-auto-fallback: $n demoted.xc"; fail=1; continue; }
    if main_of "$W/demoted.$n.s" | grep -q 'Par\$run\|ParImpl'; then
        echo "FAIL par-auto-fallback: $n keeps a demoted block's site in main"; fail=1
    fi
    # 2. Wider than a u32: the loop's answer.
    "$c" -q -O2 -H . --no-runtime-lib -o "$W/wide.$n" "$W/wide.xc" && "$c" -q -O2 -H . --no-runtime-lib --par-style=cpu -o "$W/wide.$n.cpu" "$W/wide.xc" \
        || { echo "FAIL par-auto-fallback: $n wide.xc"; fail=1; continue; }
    a=$(XC_PAR_THREADS=2 "$W/wide.$n"); b=$("$W/wide.$n.cpu")
    [ "$a" = "$b" ] || { echo "FAIL par-auto-fallback: $n wide nest prints $a, the loop $b"; fail=1; }
    # 3. Small and call-free: not lifted.
    w=$("$c" -O2 -H . --no-runtime-lib -Wpar-auto -o "$W/small.$n" "$W/small.xc" 2>&1 | grep -c "par-style")
    [ "$w" = 0 ] || { echo "FAIL par-auto-fallback: $n lifted a small loop"; fail=1; }
done
if [ -f "$W/demoted.xcc.s" ] && [ -f "$W/demoted.xcc-xc.s" ] && ! cmp -s "$W/demoted.xcc.s" "$W/demoted.xcc-xc.s"; then
    echo "FAIL par-auto-fallback: the two compilers' code for a demoted loop differs"; fail=1
fi
[ $fail = 0 ] && echo "par-auto-fallback: ok"
exit $fail
