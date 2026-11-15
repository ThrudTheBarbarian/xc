#!/bin/bash
# pp-if-numbers.sh — #if keeps a number's letters and works in 64 bits
# (#279). tests/fixtures/pp_if_numbers.xc checks 0x10, 10UL, 0x10u, $FF and
# values past 32 bits against defined and undefined names (the corpus runs
# it everywhere); here both compilers build it and print its answer, and
# both refuse `#if 1 2` with "trailing tokens in #if expression".
#
#   bash tests/driver/pp-if-numbers.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
want=$(cat tests/fixtures/pp_if_numbers.expected.out)
printf '#import "Stdio.xc"\n#if 1 2\n#endif\ni32 main(void) { return 0; }\n' > "$W/trail.xc"
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    n=$(basename "$c")
    "$c" -q -H . -o "$W/t.$n" tests/fixtures/pp_if_numbers.xc > "$W/b.$n" 2>&1 || { echo "FAIL $n: no build: $(head -c 300 "$W/b.$n")"; fail=1; continue; }
    got=$("$W/t.$n")
    [ "$got" = "$want" ] || { echo "FAIL $n: '$got', wanted '$want'"; fail=1; }
    if "$c" -q -H . -o "$W/tr.$n" "$W/trail.xc" > "$W/e.$n" 2>&1; then
        echo "FAIL $n: '#if 1 2' built"; fail=1
    elif ! grep -q "trailing tokens in #if expression" "$W/e.$n"; then
        echo "FAIL $n: '#if 1 2' refused without the trailing-tokens message: $(head -c 200 "$W/e.$n")"; fail=1
    fi
done
[ $fail = 0 ] && echo "pp-if-numbers: ok"
exit $fail
