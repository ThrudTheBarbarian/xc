#!/bin/bash
# win64.sh — Plugin.load on Windows (the host named by $XTC_WIN64_HOST, as the
# win64 sweep): bundles and a host cross-built here with -A win64, copied over
# and run there. Consent and trust, a tampered DLL, a manifest whose protocol
# the code lacks (read from its PE export directory before LoadLibraryEx), and
# a dependency shipped in the bundle (--bundle-lib).
#     XC=bin/linux/xcc-xc XTC_WIN64_HOST=<windows host> bash tests/bundle/win64.sh
cd "$(dirname "$0")/../.."
XC="${XC:-bin/osx/xcc-xc}"
WH="${XTC_WIN64_HOST:-}"
[ -n "$WH" ] || { echo "SKIP plugin win64: set XTC_WIN64_HOST to a Windows host reachable over ssh"; exit 0; }
SSHO="-o BatchMode=yes -o LogLevel=ERROR"
L=$(mktemp -d /tmp/plugwin.XXXX)
R="xcplug-$$"
trap 'rm -rf "$L"; ssh $SSHO "$WH" "Remove-Item -Recurse -Force $R -ErrorAction SilentlyContinue" 2>/dev/null' EXIT
rc=0
W="-A win64"
mkdir -p "$L/stage" "$L/deplib"
B="$L/stage"
"$XC" --bundle "$B/spice" --bundle-key "$L/key" --bundle-name spice $W -o "$L/spice.dll" tests/bundle/spice.xc > /dev/null || { echo "FAIL win64 build"; exit 1; }
cp -R "$B/spice" "$B/bad"; printf x >> "$B/bad/Exec/windows-x86_64/spice.dll"
"$XC" -q -H . -o "$L/bundletool" tests/bundle/bundletool.xc
"$XC" --bundle "$B/ghost" --bundle-key "$L/key" --bundle-name ghost $W -o "$L/ghost.dll" tests/bundle/spice.xc > /dev/null
sed -i.bak 's/"provides": {}/"provides": {"Ghost": "1.0"}/' "$B/ghost/bundle.json"; rm -f "$B/ghost/bundle.json.bak"
"$L/bundletool" sign "$B/ghost" "$L/key" > /dev/null
ROOT=$(pwd); XCA="$(cd "$(dirname "$XC")" && pwd)/$(basename "$XC")"
(cd "$L/deplib" && "$XCA" --emit-lib $W -H "$ROOT" -q -o libSpicelib.dll "$ROOT/tests/bundle/Spicelib.xc")
"$XC" --bundle "$B/dep" --bundle-key "$L/key" $W -L "$L/deplib" --bundle-lib "$L/deplib/libSpicelib.dll" \
    -o "$L/dep.dll" tests/bundle/spicedep.xc > /dev/null || { echo "FAIL win64 build dep"; rc=1; }
"$XC" -q $W -H . -o "$B/host.exe" tests/bundle/plughost.xc || { echo "FAIL win64 host build"; exit 1; }
ssh $SSHO "$WH" "Remove-Item -Recurse -Force $R -ErrorAction SilentlyContinue; New-Item -ItemType Directory $R | Out-Null"
scp $SSHO -q -r "$B/"* "$WH:$R/" || { echo "FAIL win64: cannot copy to $WH"; exit 1; }
win() { ssh $SSHO "$WH" "cd $R; \$env:XCC_PLUGIN_STORE=\"\$PWD\\store\"; .\\host.exe $1 $2" 2>&1; }
check() { # name, expected, bundle, answer
    local out; out=$(win "$3" "$4")
    if printf '%s' "$out" | grep -q -- "$2"; then echo "PASS win64 $1"
    else echo "FAIL win64 $1 (wanted '$2')"; printf '%s\n' "$out" | head -4 | sed 's/^/    /'; rc=1; fi
}
check "no consent callback"   "not trusted yet"                  spice none
check "consent given"         "run -> 17"                        spice yes
check "trusted after"         "run -> 17"                        spice none
check "tampered refused"      "has changed since it was signed"  bad yes
check "export table checked"  "its code has no _XtP_Ghost"       ghost yes
check "a shipped dependency"  "run -> 34"                        dep yes
[ $rc = 0 ] && echo "--- plugin win64: pass ---" || echo "--- plugin win64: FAIL ---"
exit $rc
