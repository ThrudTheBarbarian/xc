#!/bin/bash
# opt-level.sh — only -O and -O0 to -O3 are optimisation levels (#283)
#
# The shipped driver took any three-byte -O? and set the level to the byte
# minus '0': -Os was level 67, -Oz 74, -Og 55 and -O/ wrapped to (u32)-1, all
# accepted without a word. Both compilers must accept -O, -O0, -O1, -O2 and
# -O3, and reject every other -O spelling with the same error.
#
#   bash tests/driver/opt-level.sh
#   REF=<xcc>  XC=<xcc-xc>  override the two drivers
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-$ROOT/bin/$PLAT/xcc}
XC=${XC:-$ROOT/bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/p.xc" <<'EOF'
i32 main(void)
{
    return 0;
}
EOF
fail=0
for c in "$REF" "$XC"; do
    n=$(basename "$c")
    for o in -O -O0 -O1 -O2 -O3; do
        "$c" -q -H "$ROOT" $o -o "$W/p.s" "$W/p.xc" > "$W/out" 2>&1
        rc=$?
        [ $rc = 0 ] || { echo "FAIL opt-level: $n $o exits $rc: $(head -c 200 "$W/out")"; fail=1; }
    done
    for o in -Os -Oz -Og -O4 -O9 -O/ -O10 -Ofast; do
        "$c" -q -H "$ROOT" $o -o "$W/p.s" "$W/p.xc" > /dev/null 2> "$W/e"
        rc=$?
        [ $rc = 1 ] || { echo "FAIL opt-level: $n $o exits $rc, not 1"; fail=1; }
        want="xcc: error: unsupported optimisation level '$o' (use -O0, -O1, -O2 or -O3)"
        grep -qxF -- "$want" "$W/e" || { echo "FAIL opt-level: $n $o says: $(head -c 200 "$W/e")"; fail=1; }
    done
done
[ $fail = 0 ] && echo "opt-level: ok"
exit $fail
