#!/bin/bash
# iface-refused-path.sh — a library whose interface format this compiler does
# not read is named by its full path (Astronomancy, 2026-11-02).
#
# One 3p tree serves every installed compiler, so a library can be found in
# a release's own 3p or in the global one. The refusal named only the file
# ('libUXKit.dylib' carries interface format v1 ...), so it did not say which
# of the two was loaded; it gives the path now.
#
# Checked: a library built here with its interface's "ifaceVersion":2 patched
# to 9 (a newer format, same length) is refused by both compilers when a
# client imports it, and the message names the library's directory; and with
# a readable copy in a later -L directory, the v9 one is skipped with a
# warning naming both and the client builds (owner, 2026-11-02: a found but
# incompatible library is a warning, and the search goes on).
#
#   bash tests/driver/iface-refused-path.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/Adder.xc" <<'XC'
class Adder { i32 base; void init(i32 b) { base = b; } i32 add(i32 x) { return base + x; } }
XC
cat > "$W/use.xc" <<'XC'
#import "Stdio.xc"
#import <Adder>
i32 main(i32 argc, u8** argv)
{
    Adder* a = new Adder(40);
    Stdio.printf("adder %d\n", a.add(argc + 1));
    return 0;
}
XC
for c in "$REF" "$XC"; do
    n=$(basename "$c"); d="$W/lib-$n"; mkdir -p "$d"
    "$c" -q -A arm64-linux --emit-lib -o "$d/libAdder.so" "$W/Adder.xc" > "$W/e" 2>&1 \
        || { echo "FAIL iface-refused-path: $n does not build the library: $(head -c 200 "$W/e")"; fail=1; continue; }
    grep -aq '"ifaceVersion":2' "$d/libAdder.so" \
        || { echo "FAIL iface-refused-path: no \"ifaceVersion\":2 in $n's library"; fail=1; continue; }
    LC_ALL=C perl -pi -e 's/"ifaceVersion":2/"ifaceVersion":9/g' "$d/libAdder.so"
    if "$c" -q -A arm64-linux -L "$d" -o "$W/use" "$W/use.xc" > "$W/e" 2>&1; then
        echo "FAIL iface-refused-path: $n built a client against a v9 interface"; fail=1
    elif ! grep -q "carries interface format v9" "$W/e"; then
        echo "FAIL iface-refused-path: $n refused it, but not for its format: $(head -c 200 "$W/e")"; fail=1
    elif ! grep -qF "$d/libAdder.so" "$W/e"; then
        echo "FAIL iface-refused-path: $n's refusal does not name $d/libAdder.so: $(grep 'interface format' "$W/e" | head -1)"; fail=1
    else
        echo "ok: $n names $d/libAdder.so"
    fi
    # A readable copy further along the search: the unreadable one is skipped
    # with a warning naming both, and the client builds against the good one.
    g="$W/good-$n"; mkdir -p "$g"
    "$c" -q -A arm64-linux --emit-lib -o "$g/libAdder.so" "$W/Adder.xc" > "$W/e" 2>&1 \
        || { echo "FAIL iface-refused-path: $n does not build the second library"; fail=1; continue; }
    if ! "$c" -A arm64-linux -L "$d" -L "$g" -o "$W/use2" "$W/use.xc" > "$W/e" 2>&1; then
        echo "FAIL iface-refused-path: $n did not go on to the readable copy: $(grep -i 'error' "$W/e" | head -1)"; fail=1
    elif ! grep -q "warning:.*'$d/libAdder.so' carries interface format v9.*skipped, using '$g/libAdder.so'" "$W/e"; then
        echo "FAIL iface-refused-path: $n took the readable copy without the warning: $(head -c 300 "$W/e")"; fail=1
    else
        echo "ok: $n skips the v9 copy with a warning and uses $g/libAdder.so"
    fi
done
[ $fail -eq 0 ] && echo "iface-refused-path: ok"
exit $fail
