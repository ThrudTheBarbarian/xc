#!/bin/bash
# win64: asm and exe agreement between the two drivers, per fixture, at -O0 and -O3.
# Fixtures run in parallel: -j N or GATE_SHARDS=N (default: the number of CPUs).
# Exits 1 when any fixture differs, or when fewer than MIN_FIXTURES (default 700)
# were compared.
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
J=${GATE_SHARDS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}
while getopts "j:" o; do case $o in j) J=$OPTARG ;; *) echo "usage: $0 [-j N]" >&2; exit 2 ;; esac; done
MIN=${MIN_FIXTURES:-700}
W=$(mktemp -d "${TMPDIR:-/tmp}/winsweep.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT

# One fixture: writes $W/res/<name> holding "a0 a3 e3 bytes" (1 = differs),
# nothing when the reference driver gives no win64 asm for it.
one() {
    f=$1; b=$(basename "$f" .xc); d=$W/f/$b; mkdir -p "$d"
    r=bin/$XC_PLAT/xcc; p=bin/$XC_PLAT/xcc-xc
    $r -q -A win64 -H . -O0 -S -o "$d/r0.s" "$f" >/dev/null 2>&1 && [ -s "$d/r0.s" ] || { rm -rf "$d"; return 0; }
    $p -q -A win64 -H . -O0 -S -o "$d/p0.s" "$f" >/dev/null 2>&1
    a0=0; cmp -s "$d/r0.s" "$d/p0.s" || a0=1
    $r -q -A win64 -H . -S -o "$d/r3.s" "$f" >/dev/null 2>&1
    $p -q -A win64 -H . -S -o "$d/p3.s" "$f" >/dev/null 2>&1
    a3=0; cmp -s "$d/r3.s" "$d/p3.s" || a3=1
    e3=0; n=0
    if [ $a3 = 0 ]; then
        $r -q -A win64 -H . -o "$d/r3.exe" "$f" >/dev/null 2>&1
        $p -q -A win64 -H . -o "$d/p3.exe" "$f" >/dev/null 2>&1
        if [ -s "$d/r3.exe" ] && [ -s "$d/p3.exe" ] && ! cmp -s "$d/r3.exe" "$d/p3.exe"; then
            e3=1; n=$(cmp -l "$d/r3.exe" "$d/p3.exe" | wc -l | tr -d ' ')
        fi
    fi
    echo "$a0 $a3 $e3 $n" > "$W/res/$b"
    rm -rf "$d"
}
export -f one; export W XC_PLAT
mkdir -p "$W/res" "$W/f"
ls tests/fixtures/*.xc | xargs -P "$J" -n 1 bash -c 'one "$0"'

n=0; asm0=0; asm3=0; exe3=0; a0d=(); a3d=(); e3d=()
for r in $(ls "$W/res" | sort); do
    read -r a0 a3 e3 nb < "$W/res/$r"; n=$((n+1))
    [ "$a0" = 1 ] && { asm0=$((asm0+1)); a0d+=("$r"); }
    [ "$a3" = 1 ] && { asm3=$((asm3+1)); a3d+=("$r"); }
    [ "$e3" = 1 ] && { exe3=$((exe3+1)); e3d+=("$r ($nb bytes)"); }
done
echo "--- win64 sweep: fixtures=$n asm-O0-differ=$asm0 asm-O3-differ=$asm3 exe-differ-with-identical-asm=$exe3 ---"
echo "asm -O0 differ:"; [ $asm0 -gt 0 ] && printf '  %s\n' "${a0d[@]}"
echo "asm -O3 differ:"; [ $asm3 -gt 0 ] && printf '  %s\n' "${a3d[@]}"
echo "exe differ (asm identical):"; [ $exe3 -gt 0 ] && printf '  %s\n' "${e3d[@]}"
if [ $n -lt "$MIN" ]; then echo "win-sweep: only $n fixtures compared (need $MIN)" >&2; exit 1; fi
[ $((asm0 + asm3 + exe3)) -eq 0 ]
