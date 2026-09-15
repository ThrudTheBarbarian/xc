#!/bin/bash
# win64: asm and exe agreement between the two drivers, per fixture, at -O0 and -O3.
cd "$(dirname "$0")/../.." || exit 1
W=${TMPDIR:-/tmp}/winsweep.$$; mkdir -p "$W"
asm0=0; asm3=0; exe3=0; n=0; a0d=(); a3d=(); e3d=()
for f in tests/fixtures/*.xc; do
    b=$(basename "$f" .xc)
    rm -f "$W"/*
    bin/osx/xcc -q -A win64 -H . -O0 -S -o "$W/r0.s" "$f" >/dev/null 2>&1 || continue
    [ -s "$W/r0.s" ] || continue
    n=$((n+1))
    bin/osx/xcc-xc -q -A win64 -H . -O0 -S -o "$W/p0.s" "$f" >/dev/null 2>&1
    cmp -s "$W/r0.s" "$W/p0.s" || { asm0=$((asm0+1)); a0d+=("$b"); }
    bin/osx/xcc -q -A win64 -H . -S -o "$W/r3.s" "$f" >/dev/null 2>&1
    bin/osx/xcc-xc -q -A win64 -H . -S -o "$W/p3.s" "$f" >/dev/null 2>&1
    cmp -s "$W/r3.s" "$W/p3.s" || { asm3=$((asm3+1)); a3d+=("$b"); }
    bin/osx/xcc -q -A win64 -H . -o "$W/r3.exe" "$f" >/dev/null 2>&1
    bin/osx/xcc-xc -q -A win64 -H . -o "$W/p3.exe" "$f" >/dev/null 2>&1
    if [ -s "$W/r3.exe" ] && [ -s "$W/p3.exe" ] && cmp -s "$W/r3.s" "$W/p3.s"; then
        cmp -s "$W/r3.exe" "$W/p3.exe" || { exe3=$((exe3+1)); e3d+=("$b ($(cmp -l "$W/r3.exe" "$W/p3.exe" | wc -l | tr -d ' ') bytes)"); }
    fi
done
echo "--- win64 sweep: fixtures=$n asm-O0-differ=$asm0 asm-O3-differ=$asm3 exe-differ-with-identical-asm=$exe3 ---"
echo "asm -O0 differ:"; printf '  %s\n' "${a0d[@]}"
echo "asm -O3 differ:"; printf '  %s\n' "${a3d[@]}"
echo "exe differ (asm identical):"; printf '  %s\n' "${e3d[@]}"
rm -rf "$W"
