#!/bin/bash
# win64-obj.sh — win64 objects named `.obj`, as Windows tools name them, are
# link inputs (2026-10-24). They were read as source ("unterminated block
# comment"). Each compiler compiles two units with -c to .obj and links them;
# the program runs under wine where there is one.
#
#   bash tests/driver/win64-obj.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
export WINEDLLOVERRIDES="winedbg.exe=d;${WINEDLLOVERRIDES:-}"
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf '#import "Stdio.xc"\nu32 twice(u32 v);\ni32 main(void) { Stdio.printf("%%u\\n", twice((u32)21)); return 0; }\n' > "$W/m.xc"
printf 'u32 twice(u32 v) { return v * (u32)2; }\n' > "$W/t.xc"
for XC in ${XC:-bin/$PLAT/xcc-xc bin/$PLAT/xcc}; do
    [ -x "$XC" ] || continue
    d="$W/$(basename "$XC")"; mkdir -p "$d"
    X=$(cd "$(dirname "$XC")" && pwd)/$(basename "$XC"); R=$(pwd)
    ( cd "$d" && "$X" -q -A win64 -H "$R" -c -o t.obj ../t.xc && "$X" -q -A win64 -H "$R" -c -o m.obj ../m.xc \
        && "$X" -q -A win64 -H "$R" -o p.exe m.obj t.obj ) > "$d/out" 2>&1 \
        || { echo "FAIL $XC: .obj inputs do not link"; head -3 "$d/out"; fail=1; continue; }
    if command -v wine >/dev/null 2>&1; then
        got=$(cd "$d" && WINEDEBUG=-all wine ./p.exe 2>/dev/null | tr -d '\r')
        [ "$got" = "42" ] || { echo "FAIL $XC: the program gives '$got'"; fail=1; }
    fi
done
[ $fail = 0 ] && echo "win64-obj: ok"
exit $fail
