#!/bin/bash
# plugin.sh — Plugin.load end to end (bundles-and-plugins.md §4): a signed
# bundle built with xcc --bundle, loaded by a host that provides Fence; the
# plugin calls back through it. Consent, trust on first use, rollback,
# a tampered bundle, a missing protocol, a bundle with no build here.
#     XC=bin/osx/xcc-xc bash tests/bundle/plugin.sh   (the shipped compiler: --bundle is its flag)
cd "$(dirname "$0")/../.."
XC="${XC:-bin/osx/xcc-xc}"
case "$(uname -s)" in
    Darwin) EXT=dylib; OTHER="-A x86_64"; OEXT=so ;;
    *)      EXT=so;    OTHER="";         OEXT="" ;;
esac
L=$(mktemp -d /tmp/plugin.XXXX)
trap 'rm -rf "$L"' EXIT
rc=0
check() { # name, expected text, command...
    local n="$1" want="$2"; shift 2
    "$@" > "$L/out" 2>&1
    if grep -q -- "$want" "$L/out"; then
        echo "PASS plugin $n"
    else
        echo "FAIL plugin $n (wanted '$want')"; sed 's/^/    /' "$L/out" | head -6; rc=1
    fi
}
export XCC_PLUGIN_STORE="$L/store"
"$XC" --bundle "$L/spice" --bundle-key "$L/key" --bundle-version 1.1 --publisher Example \
    -o "$L/spice.$EXT" tests/bundle/spice.xc > /dev/null || { echo "FAIL plugin build"; exit 1; }
"$XC" -q -H . -o "$L/host" tests/bundle/plughost.xc || { echo "FAIL plugin host build"; exit 1; }

check "no consent callback"   "refused: spice is not trusted yet" "$L/host" "$L/spice" none
check "consent refused"       "refused: spice was not trusted"   "$L/host" "$L/spice" no
check "consent given"         "run -> 17"                        "$L/host" "$L/spice" yes
check "callback into the host" "host emit spice 5"               "$L/host" "$L/spice" yes
check "trusted after"         "run -> 17"                        "$L/host" "$L/spice" none

# An older version, same key: refused (rollback).
"$XC" --bundle "$L/old" --bundle-key "$L/key" --bundle-name spice --bundle-version 1.0 \
    -o "$L/old.$EXT" tests/bundle/spice.xc > /dev/null
check "rollback refused"      "older than 1.1"                   "$L/host" "$L/old" none

# The same name from another key is a different plugin: asked again.
"$XC" --bundle "$L/other" --bundle-key "$L/key2" --bundle-name spice --bundle-version 9.0 \
    -o "$L/other.$EXT" tests/bundle/spice.xc > /dev/null
check "another key is asked"  "refused: spice is not trusted yet" "$L/host" "$L/other" none

# Tampered after signing.
cp -R "$L/spice" "$L/bad"; printf x >> "$L/bad/Exec/"*/spice.$EXT
check "tampered refused"      "refused: .*changed"               "$L/host" "$L/bad" yes

# A bundle with no build for this platform.
if [ -n "$OEXT" ]; then
    "$XC" --bundle "$L/away" --bundle-key "$L/key" --bundle-name spice --bundle-version 1.2 $OTHER \
        -o "$L/away.$OEXT" tests/bundle/spice.xc > /dev/null
    check "no build here"     "has no build for"                 "$L/host" "$L/away" yes
fi

# A host that does not provide Fence.
sed 's/^    Plugin.provide(.*$//' tests/bundle/plughost.xc > "$L/bare.xc"
"$XC" -q -H . -o "$L/bare" "$L/bare.xc"
check "missing protocol"      "this program does not provide"   "$L/bare" "$L/spice" yes

[ $rc = 0 ] && echo "--- plugin: pass ---" || echo "--- plugin: FAIL ---"
exit $rc
