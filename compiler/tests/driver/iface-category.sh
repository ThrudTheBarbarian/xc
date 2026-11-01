#!/bin/bash
# iface-category.sh — a category on an imported class reaches the modules that
# import it (2026-11-01).
#
# A module's interface used to leave out everything it added to a class it
# imported, so a category's methods existed only inside the module that defined
# them: no other file could call them, and one class could not be spread over
# several separately compiled files (selfhost/opt's 41 files are class Opt).
# The interface now carries a `categories` record per extended class with the
# category's `final` and `static` methods: no client can override those, so
# they need no chain slot, and a client calls their symbols directly as the
# defining module does. A category method that CAN be overridden stays private,
# as before (its chain shape is not in the interface).
#
# Checked, with each compiler, through interfaces only (no source imports):
# three layers (K, a category A on it, a category B calling A) and a client
# calling all of them; the two compilers write the same interface bytes; a
# client calling a category's overridable method is refused; and a client that
# imports a category without the class's own module is told to import it.
#
#   bash tests/driver/iface-category.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
H=$(pwd)
# The steps run in the work directory, so the compilers by absolute path.
case "$REF" in /*) ;; *) REF="$H/$REF" ;; esac
case "$XC" in /*) ;; *) XC="$H/$XC" ;; esac
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/K.xc" <<'EOF'
#import "Foundation.xc"
class K : Object
    {
    i32 _n;
    void setN(i32 x) { _n = x; }
    i32 base(i32 x) { return x + _n; }
    }
EOF
cat > "$W/KA.xc" <<'EOF'
#import <K>
class K (A)
    {
    final i32 a(i32 x) { _n = _n + 1; return self.base(x) * 2; }
    static i32 twice(i32 x) { return x * 2; }
    i32 open(i32 x) { return x; }
    }
EOF
cat > "$W/KB.xc" <<'EOF'
#import <K>
#import <KA>
class K (B)
    {
    final i32 b(i32 x) { return self.a(x) + _n * 100 + K.twice(1000); }
    }
EOF
cat > "$W/main.xc" <<'EOF'
#import "Stdio.xc"
#import <K>
#import <KA>
#import <KB>
i32 main(void) { K* k = new K; k.setN(3); Stdio.printf("%d %d %d\n", k.b(5), k.a(1), k.base(2)); return 0; }
EOF
cat > "$W/open.xc" <<'EOF'
#import <K>
#import <KA>
i32 main(void) { K* k = new K; return k.open(1); }
EOF
cat > "$W/nohost.xc" <<'EOF'
#import <KA>
i32 main(void) { return 0; }
EOF
fail=0
for X in "$REF" "$XC"; do
    n=$(basename "$X"); D="$W/$n"; mkdir -p "$D/if"
    ok=1
    for f in K KA KB main; do
        ( cd "$W" && "$X" -q -H "$H" -L "$D/if" --emit-iface -o "$D/if/$f.xtc.iface" $f.xc ) > "$D/$f.e" 2>&1 \
            || { echo "FAIL iface-category: $n: no interface for $f: $(head -c 200 "$D/$f.e")"; ok=0; }
        ( cd "$W" && "$X" -q -H "$H" -L "$D/if" -c -o "$D/$f.o" $f.xc ) > "$D/$f.e" 2>&1 \
            || { echo "FAIL iface-category: $n: $f does not compile: $(head -c 200 "$D/$f.e")"; ok=0; }
    done
    if [ $ok = 1 ]; then
        "$X" -q -H "$H" -o "$D/prog" "$D/K.o" "$D/KA.o" "$D/KB.o" "$D/main.o" > "$D/link.e" 2>&1 \
            || { echo "FAIL iface-category: $n: no link: $(head -c 200 "$D/link.e")"; ok=0; }
    fi
    if [ $ok = 1 ]; then
        got=$("$D/prog")
        [ "$got" = "2418 12 7" ] || { echo "FAIL iface-category: $n: prints '$got', want '2418 12 7'"; fail=1; }
    else
        fail=1
    fi
    ( cd "$W" && "$X" -q -H "$H" -L "$D/if" -c -o "$D/open.o" open.xc ) > "$D/open.e" 2>&1 \
        && { echo "FAIL iface-category: $n: a category's overridable method reached a client"; fail=1; }
    ( cd "$W" && "$X" -q -H "$H" -L "$D/if" -c -o "$D/nohost.o" nohost.xc ) > "$D/nohost.e" 2>&1 \
        && { echo "FAIL iface-category: $n: a category without its class's module was accepted"; fail=1; }
    grep -q "unknown class 'K'" "$D/nohost.e" \
        || { echo "FAIL iface-category: $n: no unknown-class error without K: $(head -c 200 "$D/nohost.e")"; fail=1; }
done
for f in K KA KB main; do
    cmp -s "$W/$(basename "$REF")/if/$f.xtc.iface" "$W/$(basename "$XC")/if/$f.xtc.iface" \
        || { echo "FAIL iface-category: the compilers' interfaces for $f differ"; fail=1; }
done
[ $fail = 0 ] && echo "iface-category: ok"
exit $fail
