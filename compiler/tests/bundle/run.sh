#!/bin/bash
# run.sh — a signed bundle (BundleSign.xc, bundles-and-plugins.md §6 step 5):
# made, verified, then edited, added to, renamed in, linked into, and
# re-signed, each refused with its own reason.
#   XC=bin/osx/xcc-xc bash tests/bundle/run.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
L=$(mktemp -d "${TMPDIR:-/tmp}/bundle.XXXX")
T="$L/bundletool"
"$XC" -q -H . -o "$T" tests/bundle/bundletool.xc > "$L/build" 2>&1 || { echo "FAIL bundle: tool build"; head -3 "$L/build"; exit 1; }
rc=0
expect() {   # expect <label> <wanted substring> <command...>
    local label=$1 want=$2; shift 2
    local got; got=$("$@" 2>&1)
    if [[ "$got" == *"$want"* ]]; then echo "PASS bundle $label"
    else echo "FAIL bundle $label: wanted '$want', got '$got'"; rc=1; fi
}
mkdir -p "$L/res"; echo "icon" > "$L/res/icon.png"; echo "intro" > "$L/res/intro.txt"
printf 'code-for-macos' > "$L/spice.dylib"; printf 'code-for-linux' > "$L/spice.so"
B="$L/spice"
expect make          made     "$T" make "$B" spice macos-arm64 "$L/spice.dylib" "$L/key" "$L/res"
expect verify        verified "$T" verify "$B"
expect "second platform" made "$T" make "$B" spice linux-x86_64 "$L/spice.so" "$L/key"
expect "both platforms" verified "$T" verify "$B"
grep -q '"platforms": \["linux-x86_64", "macos-arm64"\]' "$B/bundle.json" && echo "PASS bundle manifest keeps both" || { echo "FAIL bundle manifest keeps both"; rc=1; }
cp -R "$B" "$L/w1"; printf 'evil' > "$L/w1/Exec/macos-arm64/spice.dylib"
expect "edited code"   "has changed"              "$T" verify "$L/w1"
cp -R "$B" "$L/w2"; echo x > "$L/w2/Exec/macos-arm64/version.dll"
expect "planted file"  "does not list"            "$T" verify "$L/w2"
cp -R "$B" "$L/w3"; mv "$L/w3/Resources/icon.png" "$L/w3/Resources/icon2.png"
expect "renamed file"  "does not list"            "$T" verify "$L/w3"
cp -R "$B" "$L/w4"; rm "$L/w4/Resources/intro.txt"
expect "missing file"  "is missing"               "$T" verify "$L/w4"
cp -R "$B" "$L/w5"; rm "$L/w5/Resources/icon.png"; ln -s ../bundle.json "$L/w5/Resources/icon.png"
expect "symlink"       "link or a special file"   "$T" verify "$L/w5"
cp -R "$B" "$L/w6"; sed -i.bak 's/"version": "1.2"/"version": "9.9"/' "$L/w6/bundle.json"; rm "$L/w6/bundle.json.bak"
expect "edited manifest" "signature does not verify" "$T" verify "$L/w6"
# A tamperer who edits the manifest and re-signs it with THEIR key: the
# signature verifies only against the key in the manifest, which is still
# the publisher's — so it fails; replacing that key too is the re-signed
# copy that trust on first use (step 6) refuses.
expect "re-signed by another key" "re-signed" "$T" sign "$L/w6" "$L/otherkey"
expect "re-signed copy" "signature does not verify" "$T" verify "$L/w6"
cp -R "$B" "$L/w7"; sed -i.bak 's/^  "code": "spice",/  "code": "spice", "code": "evil",/' "$L/w7/bundle.json"; rm "$L/w7/bundle.json.bak"; "$T" sign "$L/w7" "$L/key" > /dev/null
expect "duplicate key" "a key appears twice"      "$T" verify "$L/w7"
[ $rc = 0 ] && rm -rf "$L"
echo "--- bundle: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
