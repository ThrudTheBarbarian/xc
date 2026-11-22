#!/bin/bash
# spirv-scalar-global.sh — a par kernel that reads a scalar global through its
# buffer is valid SPIR-V (#563). The read named the buffer's runtime array, not
# its first element; RADV's compiler died on it with a divide error, so a C
# program whose loops over a large global ran as blocks on an AMD GPU got
# SIGFPE. Every kernel the program carries is checked with spirv-val; on an
# x86-64 Linux host the program also runs under the default par style.
# Skipped without spirv-val.
#
#   bash tests/par/spirv-scalar-global.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v spirv-val > /dev/null 2>&1 || { echo "--- spirv-scalar-global: skipped (no spirv-val) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/mix.c" <<'C'
#include <stdio.h>
#define N 1000000
int table[N];
int scale_by = 3;
int main(void)
{
    for (int i = 0; i < N; i++)
        table[i] = i * scale_by;
    long s = 0;
    for (int i = 0; i < N; i++)
        s += table[i];
    printf("%ld\n", s);
    return 0;
}
C
"$XC" -q -O2 -A x86_64 -H . -o "$W/mix" "$W/mix.c" > "$W/b" 2>&1 || { echo "FAIL spirv-scalar-global: does not build"; head -3 "$W/b"; exit 1; }
mkdir -p "$W/spv"
n=$(python3 - "$W/mix" "$W/spv" <<'PY'
import sys, re, struct
d = open(sys.argv[1], 'rb').read(); out = sys.argv[2]; n = 0
for m in re.finditer(rb'spirv=(\d+)', d):
    words = int(m.group(1))
    st = d.rfind(b'//', 0, m.start())
    if st < 0 or b'\0' in d[st:m.start()]: continue
    end = d.index(b'\0', m.start())
    at = ((end - st) + 4) & ~3
    blob = d[st + at: st + at + words * 4]
    if blob[:4] != struct.pack('<I', 0x07230203): continue
    open(f'{out}/{n}.spv', 'wb').write(blob); n += 1
print(n)
PY
)
[ "${n:-0}" -ge 2 ] || { echo "  FAIL: the program carries ${n:-0} SPIR-V kernel(s), want 2"; fail=1; }
for f in "$W"/spv/*.spv; do
    [ -f "$f" ] || continue
    if spirv-val "$f" > "$W/v" 2>&1; then echo "  ok: $(basename "$f") is valid SPIR-V"
    else echo "  FAIL: $(basename "$f"): $(head -1 "$W/v")"; fail=1; fi
done
if [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ]; then
    got=$("$W/mix" 2>&1); rc=$?
    [ "$got" = "1499998500000" ] && echo "  ok: runs under the default par style" || { echo "  FAIL: gives '$got' (exit $rc)"; fail=1; }
fi
echo "--- spirv-scalar-global: $([ $fail = 0 ] && echo pass || echo FAIL) ---"
exit $fail
