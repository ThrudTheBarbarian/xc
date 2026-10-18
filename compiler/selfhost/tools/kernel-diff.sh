#!/bin/bash
# kernel-diff.sh — IR outlining's GPU kernels against the parser's: for each
# par fixture, the Metal kernels a --par-auto build carries (the scan's blocks)
# and those an XC_PAR_PROPOSE=outline build carries (the IR outliner's), how
# many of the scan's the outliner produced byte for byte (block numbers and
# the ops= cost word aside), and whether the outlined program gives its
# expected output on the CPU and with XC_PAR=gpu. Self-hosted compiler only;
# macOS (the Metal form).
#
#   bash selfhost/tools/kernel-diff.sh [pattern]
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
PATTERN=${1:-par_}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/k.py" <<'PY'
import sys, re
def kernels(path):
    data = open(path, 'rb').read()
    out = []
    for m in re.finditer(rb'// xcpar msl[^\x00]*', data):
        t = m.group(0).decode('latin-1')
        t = re.sub(r'\b(red|sh|acc)_\d+\b', r'\1_N', t)
        t = re.sub(r' ops=\d+', '', t)
        out.append(t)
    return out
a = kernels(sys.argv[1]); b = kernels(sys.argv[2])
print("%d %d %d" % (len(a), len(b), sum(1 for k in a if k in b)))
PY
scan=0; outl=0; same=0; bad=0
for f in tests/fixtures/${PATTERN}*.xc; do
    [ -f "${f%.xc}.expected.out" ] || continue
    b=$(basename "$f" .xc)
    "$XC" -q -O3 -H . --par-auto -o "$W/s" "$f" >/dev/null 2>&1 || continue
    XC_PAR_PROPOSE=outline "$XC" -q -O3 -H . -o "$W/o" "$f" >/dev/null 2>&1 || { echo "  $b: the outlined build FAILED"; bad=$((bad + 1)); continue; }
    read ns no nm < <(python3 "$W/k.py" "$W/s" "$W/o")
    cpu=$( (cd "$W" && timeout 60 ./o 2>/dev/null) | cmp -s - "${f%.xc}.expected.out" && echo ok || echo DIFF)
    gpu=$( (cd "$W" && XC_PAR=gpu timeout 60 ./o 2>/dev/null) | grep -v '^par:' | cmp -s - "${f%.xc}.expected.out" && echo ok || echo DIFF)
    [ "$cpu" = ok ] && [ "$gpu" = ok ] || bad=$((bad + 1))
    [ "$no" -gt 0 ] || [ "$ns" -gt 0 ] && echo "  $b: scan $ns, outlined $no, the same $nm; cpu $cpu, gpu $gpu"
    scan=$((scan + ns)); outl=$((outl + no)); same=$((same + nm))
done
echo "--- kernel-diff: the scan's kernels $scan, the outliner's $outl, the same $same; $bad programs wrong ---"
[ $bad = 0 ]
