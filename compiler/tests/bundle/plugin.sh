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

# loadAsync and p.table(proto) natively: the host calls a protocol the
# plugin provides (tests/bundle/web/, the same sources as on the web).
"$XC" --bundle "$L/sw" --bundle-key "$L/key" --bundle-name sw -o "$L/sw.$EXT" tests/bundle/web/spiceweb.xc > /dev/null
"$XC" -q -H . -o "$L/webhost" tests/bundle/web/webhost.xc
check "loadAsync + table"     "sum -> 10, first byte now 99"     "$L/webhost" "$L/sw" yes

# The manifest claims a protocol the code does not have, signed by the
# publisher's own key: refused from the code's export table, before loading.
"$XC" -q -H . -o "$L/bundletool" tests/bundle/bundletool.xc
"$XC" --bundle "$L/ghost" --bundle-key "$L/key" --bundle-name ghost -o "$L/ghost.$EXT" tests/bundle/spice.xc > /dev/null
sed -i.bak 's/"provides": {}/"provides": {"Ghost": "1.0"}/' "$L/ghost/bundle.json"; rm -f "$L/ghost/bundle.json.bak"
"$L/bundletool" sign "$L/ghost" "$L/key" > /dev/null
check "export table checked"  "says it provides Ghost, but its code has no _XtP_Ghost\$table" "$L/host" "$L/ghost" yes

# A hash-pinned link names the manifest's exact bytes: no prompt; another
# hash is refused.
"$XC" --bundle "$L/pinned" --bundle-key "$L/key" --bundle-name pinned -o "$L/pinned.$EXT" tests/bundle/spice.xc > /dev/null
H=$( (command -v sha256sum > /dev/null && sha256sum || shasum -a 256) < "$L/pinned/bundle.json" | cut -c1-64)
check "pinned link, no prompt" "run -> 17"                      "$L/host" "$L/pinned@sha256:$H" none
check "pinned link, wrong"    "not the bundle the link names"   "$L/host" "$L/pinned@sha256:$(echo $H | tr 0-9a-f 1-9a-f0)" none

# A curated program (--trust key.pub) loads only its publishers' plugins.
"$XC" -q -H . --trust "$L/key.pub" -o "$L/curated" tests/bundle/plughost.xc
check "curated, trusted"      "run -> 17"                       "$L/curated" "$L/spice" yes
check "curated, other key"    "a publisher this program was not built to trust" "$L/curated" "$L/other" yes

# Key rotation: key A hands "rot" over to key B; B's build loads with no
# prompt, A is retired, a forged hand-over is refused, as is a rollback.
rb() { "$XC" --bundle "$L/$1" --bundle-name rot -o "$L/$1.$EXT" tests/bundle/spice.xc "${@:2}" > /dev/null; }
rb rotA --bundle-key "$L/keyA" --bundle-version 1.0
check "rotation: first"       "run -> 17"                       "$L/host" "$L/rotA" yes
rb rotB --bundle-key "$L/keyB" --bundle-version 1.1 --rotate-from "$L/keyA"
check "rotation: handed over" "run -> 17"                       "$L/host" "$L/rotB" none
rb rotA2 --bundle-key "$L/keyA" --bundle-version 1.2
check "rotation: old retired" "refused: rot is not trusted yet" "$L/host" "$L/rotA2" none
rb rotC --bundle-key "$L/keyB" --bundle-version 1.3 --rotate-from "$L/keyA"
sed -i.bak -e 's/"rotation": "f/"rotation": "0/; t' -e 's/"rotation": "./"rotation": "f/' "$L/rotC/bundle.json"
cmp -s "$L/rotC/bundle.json" "$L/rotC/bundle.json.bak" && echo "FAIL plugin rotation: the forgery changed nothing"; rm -f "$L/rotC/bundle.json.bak"
"$L/bundletool" sign "$L/rotC" "$L/keyB" > /dev/null
check "rotation: forged"      "the key rotation does not verify" "$L/host" "$L/rotC" none
rb rotD --bundle-key "$L/keyD" --bundle-version 1.0 --rotate-from "$L/keyB"
check "rotation: no rollback" "older than 1.1"                  "$L/host" "$L/rotD" none

# A plugin that needs a library the system does not provide: refused unless
# it ships in the bundle (--bundle-lib), and then loaded from the copy.
mkdir -p "$L/deplib"
ROOT=$(pwd); XCA="$(cd "$(dirname "$XC")" && pwd)/$(basename "$XC")"
(cd "$L/deplib" && "$XCA" --emit-lib -H "$ROOT" -q -o libSpicelib.$EXT "$ROOT/tests/bundle/Spicelib.xc")
check "undeclared dependency" "which is not a system library"   "$XC" --bundle "$L/dep" --bundle-key "$L/key" -L "$L/deplib" -o "$L/dep.$EXT" tests/bundle/spicedep.xc
"$XC" --bundle "$L/dep" --bundle-key "$L/key" -L "$L/deplib" --bundle-lib "$L/deplib/libSpicelib.$EXT" \
    -o "$L/dep.$EXT" tests/bundle/spicedep.xc > /dev/null
check "a shipped dependency"  "run -> 34"                       "$L/host" "$L/dep" yes

# Developer properties: readonly and writeable values in the signed manifest,
# a user's overrides in the app's Settings, across updates of the bundle.
P="$L/props"; ST="$L/props.settings"
pb() { "$XC" --bundle "$P" --bundle-key "$L/key" --bundle-name props -o "$L/props.$EXT" tests/bundle/spice.xc "$@" > /dev/null; }
"$XC" -q -H . -o "$L/propshost" tests/bundle/propshost.xc
pb --bundle-version 1.0 --property endpoint=https://example.org --setting theme=dark
check "properties read"       "theme: info=dark value=dark writeable=yes overridden=no" "$L/propshost" "$P" "$ST" show theme
check "readonly refused"      "set endpoint -> no, notified 0"  "$L/propshost" "$P" "$ST" set endpoint x
check "a user's value"        "set theme -> yes, notified 1"    "$L/propshost" "$P" "$ST" set theme light
check "kept across runs"      "value=light writeable=yes overridden=yes defaultChanged=no" "$L/propshost" "$P" "$ST" show theme
pb --bundle-version 1.1 --property endpoint=https://example.org --setting theme=blue
check "user wins an update"   "info=blue value=light writeable=yes overridden=yes defaultChanged=yes" "$L/propshost" "$P" "$ST" show theme
pb --bundle-version 1.2 --property endpoint=https://example.org --property theme=red
check "moved to readonly"     "info=red value=red writeable=no overridden=no" "$L/propshost" "$P" "$ST" show theme
pb --bundle-version 1.3 --property endpoint=https://example.org --setting theme=blue
check "writeable again"       "info=blue value=light writeable=yes overridden=yes" "$L/propshost" "$P" "$ST" show theme
check "reset"                 "reset theme, notified 1"         "$L/propshost" "$P" "$ST" reset theme
check "manifest again"        "info=blue value=blue writeable=yes overridden=no" "$L/propshost" "$P" "$ST" show theme
check "user state"            "set note -> yes"                 "$L/propshost" "$P" "$ST" set note hello
check "kept per publisher"    "bundle\.[0-9a-f]\{64\}\.props\.note = hello" cat "$ST"
check "a bad key refused"     "is not a property name"          "$XC" --bundle "$L/pbad" --bundle-key "$L/key" -o "$L/pbad.$EXT" tests/bundle/spice.xc --property a.b=x
check "a key in both refused" "both readonly and writeable"     "$XC" --bundle "$L/pbad" --bundle-key "$L/key" -o "$L/pbad.$EXT" tests/bundle/spice.xc --property k=1 --setting k=2

[ $rc = 0 ] && echo "--- plugin: pass ---" || echo "--- plugin: FAIL ---"
exit $rc
