#!/bin/bash
# trunc-index.sh — the par dependence check and narrow indices (#280).
# a[(u8)i] over 1000 items writes each element about four times: the index is
# not k*i + c once it is cut to 8 bits. A written block that does so is
# flagged (par-scatter: its items may write one element), and the same plain
# loop under --par-style=auto stays a loop with the serial answer. A block over (u32)i (the loop variable's own width)
# still runs as a block.
#
#   bash tests/par/trunc-index.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0

cat > "$W/refuse.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 a[256];
    par { for (u32 i in 0..1000) { a[(u8)i] = i; } }
    Stdio.printf("%u\n", a[3]);
    return 0;
    }
XC
"$XC" -o "$W/refuse" "$W/refuse.xc" > "$W/refuse.out" 2>&1
if grep -q "cannot prove two work items never write the same element" "$W/refuse.out"; then
    echo "  ok: a block writing a[(u8)i] is flagged (its items may write one element)"
else
    echo "  FAIL: a block writing a[(u8)i] got no warning"; sed 's/^/    /' "$W/refuse.out" | head -3; fail=1
fi

cat > "$W/auto.xc" <<'XC'
#import "Stdio.xc"
i32 main(void)
    {
    u32 a[256];
    u32 n = (u32)1000;
    for (u32 i in 0..n) { a[(u8)i] = i * (u32)3; }
    u32 s = (u32)0;
    for (u32 k in 0..(u32)256) s = s + a[k];
    Stdio.printf("%u %u\n", a[3], s);
    return 0;
    }
XC
"$XC" -q -O2 -o "$W/auto" "$W/auto.xc" 2>/dev/null && "$XC" -q -O2 --par-style=cpu -o "$W/auto.cpu" "$W/auto.xc" 2>/dev/null \
  && [ "$("$W/auto")" = "$("$W/auto.cpu")" ] && echo "  ok: the plain loop gives the serial answer ($("$W/auto"))" \
  || { echo "  FAIL: auto loop: $("$W/auto" 2>&1) vs serial $("$W/auto.cpu" 2>&1)"; fail=1; }

cat > "$W/wide.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 a[100000];
    par wide { for (u64 i in (u64)0..(u64)100000) { a[(u32)i] = (u32)i * (u32)2; } }
    Stdio.printf("%u\n", a[99999]);
    return 0;
    }
XC
if "$XC" -q -o "$W/wide" "$W/wide.xc" 2> "$W/wide.err" && [ "$(XC_PAR_REPORT=1 "$W/wide" 2>&1 | grep -c 'wide: .* items on')" != 0 ] && [ "$("$W/wide" | tail -1)" = 199998 ]; then
    echo "  ok: a block over a[(u32)i] still runs as a block"
else
    echo "  FAIL: a[(u32)i] block"; sed 's/^/    /' "$W/wide.err" | head -3; XC_PAR_REPORT=1 "$W/wide" 2>&1 | head -3 | sed 's/^/    /'; fail=1
fi

[ $fail = 0 ] && echo "--- trunc-index: pass ---" || echo "--- trunc-index: FAIL ---"
exit $fail
