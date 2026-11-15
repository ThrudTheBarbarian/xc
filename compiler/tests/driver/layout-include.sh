#!/bin/bash
# layout-include.sh — a layout that #includes itself is an error, not a stack
# overflow (#298), in both compilers' layout readers: the compile's and the
# memory map -dl draws. A layout whose entry address is $0000 shows it in the
# map (0 used to read as unset).
#
#   bash tests/driver/layout-include.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf '#include "b.lnk"\n[memory]\nmain = $2000-$3FFF\n' > "$W/a.lnk"
printf '#include "a.lnk"\n[entry]\naddress = $0000\n' > "$W/b.lnk"
printf '#include "self.lnk"\n' > "$W/self.lnk"
cp support/xt6502/layouts/xt.lnk "$W/"
printf '#include "xt.lnk"\n[entry]\naddress = $0000\n' > "$W/z.lnk"
printf 'i32 main(void) { return 0; }\n' > "$W/m.xc"
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    n=$(basename "$c")
    for l in a self; do
        ( ulimit -t 20; "$c" -A xt6502 -m "$W/$l.lnk" -dl > "$W/e" 2>&1 ); rc=$?
        [ $rc -gt 128 ] && { echo "FAIL $n: -dl crashed (rc $rc) on the $l.lnk cycle"; fail=1; }
        grep -q "include cycle" "$W/e" || { echo "FAIL $n: -dl on $l.lnk does not name the cycle: $(head -c 200 "$W/e")"; fail=1; }
        ( ulimit -t 20; "$c" -q -A xt6502 -m "$W/$l.lnk" -S -o "$W/o.s" "$W/m.xc" > "$W/e" 2>&1 ); rc=$?
        [ $rc -gt 128 ] && { echo "FAIL $n: the compile crashed (rc $rc) on the $l.lnk cycle"; fail=1; }
        [ $rc = 0 ] && { echo "FAIL $n: a compile with the $l.lnk cycle succeeded"; fail=1; }
    done
    if [ "$c" = "$XC" ]; then
        "$c" -A xt6502 -m "$W/z.lnk" -dl 2>&1 | grep -qF 'Entry: $0000' || { echo "FAIL $n: -dl drops an entry at \$0000"; fail=1; }
    fi
done
[ $fail = 0 ] && echo "layout-include: ok"
exit $fail
