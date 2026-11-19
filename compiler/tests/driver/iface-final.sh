#!/bin/bash
# iface-final.sh — a final method keeps its "takes no slot" through an
# interface (#393).
#
# A class's own final methods were written to its interface without the flag.
# The module that defines the class left them out of its vtable; a module that
# saw the class through the interface counted them, so every method whose label
# sorts after a final one sat one slot further on there. A virtual call made in
# one module on an object whose table the other built landed on the next method.
#
# K (with a final method sorting first) and a subclass S in another module, built
# as the split build builds the compiler: interfaces first, then one object per
# file against them. K.sum() calls bb() and cc() on an S, through the table S's
# module laid out; S overrides cc(). With each compiler, and the two compilers
# must write the same interface bytes.
#
#   bash tests/driver/iface-final.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
H=$(pwd)
case "$REF" in /*) ;; *) REF="$H/$REF" ;; esac
case "$XC" in /*) ;; *) XC="$H/$XC" ;; esac
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/K.xc" <<'EOF'
#import "Foundation.xc"
class K : Object
    {
    i32 _n;
    final i32 aa(void) { return 1; }
    i32 bb(void) { return 2; }
    i32 cc(void) { return 3; }
    i32 sum(void) { return self.bb() + self.cc(); }
    }
EOF
cat > "$W/S.xc" <<'EOF'
#import <K>
class S : K
    {
    i32 cc(void) { return 30; }
    }
K* makeS(void) { return (K*)new S; }
EOF
cat > "$W/main.xc" <<'EOF'
#import "Stdio.xc"
#import <K>
#import <S>
i32 main(void) { K* k = makeS(); Stdio.printf("%d %d %d %d\n", k.aa(), k.bb(), k.cc(), k.sum()); return 0; }
EOF
fail=0
for X in "$REF" "$XC"; do
    n=$(basename "$X"); D="$W/$n"; mkdir -p "$D/if"
    ok=1
    for f in K S main; do
        ( cd "$W" && "$X" -q -H "$H" -L "$D/if" --emit-iface -o "$D/if/$f.xtc.iface" $f.xc ) > "$D/$f.e" 2>&1 \
            || { echo "FAIL iface-final: $n: no interface for $f: $(head -c 200 "$D/$f.e")"; ok=0; }
        ( cd "$W" && "$X" -q -H "$H" -L "$D/if" -c -o "$D/$f.o" $f.xc ) > "$D/$f.e" 2>&1 \
            || { echo "FAIL iface-final: $n: $f does not compile: $(head -c 200 "$D/$f.e")"; ok=0; }
    done
    if [ $ok = 1 ]; then
        "$X" -q -H "$H" -o "$D/prog" "$D/K.o" "$D/S.o" "$D/main.o" > "$D/link.e" 2>&1 \
            || { echo "FAIL iface-final: $n: no link: $(head -c 200 "$D/link.e")"; ok=0; }
    fi
    if [ $ok = 1 ]; then
        got=$("$D/prog")
        [ "$got" = "1 2 30 32" ] || { echo "FAIL iface-final: $n: prints '$got', want '1 2 30 32'"; fail=1; }
    else
        fail=1
    fi
done
for f in K S main; do
    cmp -s "$W/$(basename "$REF")/if/$f.xtc.iface" "$W/$(basename "$XC")/if/$f.xtc.iface" \
        || { echo "FAIL iface-final: the compilers' interfaces for $f differ"; fail=1; }
done
[ $fail = 0 ] && echo "iface-final: ok"
exit $fail
