#!/bin/bash
# web/run.sh — plugins on the web (bundles-and-plugins.md §4, wasm32): a
# signed bundle served over HTTP, loaded by a wasm32 host under Node with
# Plugin.loadAsync. The plugin is a module with its own memory; Spice calls
# go host -> plugin and Fence calls plugin -> host, buffers copied across.
# Consent and trust, a tampered code file and manifest, a missing protocol,
# a plugin passing a pointer outside its memory, the compile-time refusal of
# a member that cannot cross, and both compilers' modules byte for byte.
#     XC=bin/osx/xcc-xc bash tests/bundle/web/run.sh
cd "$(dirname "$0")/../../.."
XC="${XC:-bin/osx/xcc-xc}"
REF="${REF:-$(dirname "$XC")/xcc}"
L=$(mktemp -d /tmp/webplugin.XXXX)
HP=""
trap '[ -n "$HP" ] && { kill $HP; wait $HP; } 2>/dev/null; rm -rf "$L"' EXIT
rc=0
check() { # name, expected text, command...
    local n="$1" want="$2"; shift 2
    "$@" > "$L/out" 2>&1
    if grep -q -- "$want" "$L/out"; then echo "PASS web $n"
    else echo "FAIL web $n (wanted '$want')"; sed 's/^/    /' "$L/out" | head -6; rc=1; fi
}
mkdir -p "$L/site"
bundle() { # dir, source, extra args...
    local d="$1" src="$2"; shift 2
    "$XC" --bundle "$L/site/$d" --bundle-key "$L/key" --bundle-name "$d" -A wasm32 -o "$L/$d.wasm" "$src" "$@" > /dev/null \
        || { echo "FAIL web build $d"; rc=1; }
}
mkdir -p "$L/res"; printf 'signed words' > "$L/res/note.txt"
bundle spice tests/bundle/web/spiceweb.xc --bundle-version 1.1 --resources "$L/res"
"$XC" -q -A wasm32 -H . -o "$L/host" tests/bundle/web/webhost.xc || { echo "FAIL web host build"; exit 1; }

# A tampered code file, and a tampered manifest.
cp -R "$L/site/spice" "$L/site/badcode"; printf x >> "$L/site/badcode/Exec/wasm32/spice.wasm"
cp -R "$L/site/spice" "$L/site/badman"; sed -i.bak 's/"1.1"/"9.9"/' "$L/site/badman/bundle.json"; rm -f "$L/site/badman/bundle.json.bak"
# A plugin that hands the host a pointer outside its own memory.
sed 's/Fence.emit("spice", (u32)5)/Fence.emit((u8*)(u64)0x7FFFFFF0, (u32)64)/' tests/bundle/web/spiceweb.xc > "$L/hostile.xc"
bundle hostile "$L/hostile.xc"
# A host that does not provide Fence.
sed 's/^    Plugin.provide(.*$//' tests/bundle/web/webhost.xc > "$L/bare.xc"
"$XC" -q -A wasm32 -H . -o "$L/bare" "$L/bare.xc"

# The publisher's domain vouches for its keys (/.well-known/xc-bundle-keys at
# the origin the bundle comes from, here 127.0.0.1): a vouched first install,
# a key it does not list, a revoked one, and rotations with and without it.
kid() { python3 -c "import hashlib,sys; print(hashlib.sha256(bytes.fromhex(open(sys.argv[1]).read().strip())).hexdigest())" "$1.pub"; }
dom() { local d="$1" k="$2"; shift 2
    "$XC" --bundle "$L/site/$d" --bundle-key "$L/$k" --bundle-name "$d" --publisher-domain 127.0.0.1 -A wasm32 \
        -o "$L/$d.wasm" tests/bundle/web/spiceweb.xc "$@" > /dev/null || { echo "FAIL web build $d"; rc=1; }; }
dom vouched keyV
dom unlisted keyU
dom revoked keyR
dom rot keyA --bundle-version 1.0
dom rotb keyB --bundle-name rot --bundle-version 1.1 --rotate-from "$L/keyA"
mkdir -p "$L/site/.well-known"
printf '{"keys": ["%s", "%s", "%s"], "revoked": ["%s"]}\n' "$(kid "$L/keyV")" "$(kid "$L/keyR")" "$(kid "$L/keyA")" \
    "$(kid "$L/keyR")" > "$L/site/.well-known/xc-bundle-keys"

PORT=$((8300 + RANDOM % 600))
(cd "$L/site" && exec python3 -m http.server $PORT --bind 127.0.0.1 > "$L/http.log" 2>&1) & HP=$!
for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; perl -e 'select(undef,undef,undef,0.25)'; done
U="http://127.0.0.1:$PORT"
export XCC_PLUGIN_STORE="$L/store"
run() { timeout 30 node "$L/$1.js" "$U/$2" "$3"; }

check "no consent callback"    "refused: spice is not trusted yet"  run host spice none
check "consent refused"        "refused: spice was not trusted"     run host spice no
check "host calls the plugin"  "run -> 17"                          run host spice yes
check "plugin calls the host"  "host emit 5 bytes"                  run host spice none
check "a buffer both ways"     "sum -> 10, first byte now 99"       run host spice none
check "tampered code"          "has changed since it was signed"    run host badcode none
check "tampered manifest"      "the signature does not verify"      run host badman none
check "missing protocol"       "this program does not provide"      run bare spice yes
check "pointer outside memory" "not the caller's memory"            run host hostile yes
check "no bundle there"        "bundle.json: HTTP 404"              run host nothing yes
check "domain vouches"         "asked about vouched (domain '127.0.0.1')" run host vouched yes
check "domain does not list"   "asked about unlisted (domain '')"   run host unlisted yes
check "a revoked key"          "has revoked the key"                run host revoked yes
check "rotation: first"        "run -> 17"                          run host rot yes
check "rotation: not vouched"  "counts only once 127.0.0.1 vouches" run host rotb none
printf '{"keys": ["%s", "%s"], "revoked": []}\n' "$(kid "$L/keyA")" "$(kid "$L/keyB")" > "$L/site/.well-known/xc-bundle-keys"
check "rotation: vouched"      "run -> 17"                          run host rotb none
check "a resource, checked"    "resource: signed words"             run host spice none
cp -R "$L/site/spice" "$L/site/badres"; printf x >> "$L/site/badres/Resources/note.txt"
check "a changed resource"     "resource: none"                     run host badres none

# Offline: the server gone, the verified files kept from the loads above.
kill $HP; wait $HP 2>/dev/null; HP=""
check "offline copy"           "sum -> 10, first byte now 99"       run host spice none
sha() { if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-64; }
kept=$(printf '%s' "$U/spice/Exec/wasm32/spice.wasm" | sha)
[ -f "$XCC_PLUGIN_STORE/cache/$kept" ] || echo "FAIL web: no offline copy of the code was kept"
printf x >> "$XCC_PLUGIN_STORE/cache/$kept"
check "a changed offline copy" "has changed since it was signed"    run host spice none
bad=$(printf '%s' "$U/badcode/Exec/wasm32/spice.wasm" | sha)
check "not kept unchecked"     "no offline copy"                    sh -c "[ -f '$XCC_PLUGIN_STORE/cache/$bad' ] && echo kept || echo 'no offline copy'"

# A member that cannot cross between web modules is refused when compiled.
cat > "$L/obj.xc" <<'XC'
protocol Named :version(1.0) { static void take(String* s); }
class N : Object <Named> { static void take(String* s) { } }
i32 main(void) { return 0; }
XC
check "object member refused"  "'String\*' is neither"              "$XC" -q -A wasm32 -H . -o "$L/obj" "$L/obj.xc"
check "refused by both"        "'String\*' is neither"              "$REF" -q -A wasm32 -H . -o "$L/obj2" "$L/obj.xc"

# Both compilers write the same modules (the plugin, as a plain build).
for f in tests/bundle/web/spiceweb.xc tests/bundle/web/webhost.xc; do
    b=$(basename "$f" .xc)
    "$XC"  -q -A wasm32 -H . -o "$L/x_$b" "$f"; "$REF" -q -A wasm32 -H . -o "$L/r_$b" "$f"
    if cmp -s "$L/x_$b.wasm" "$L/r_$b.wasm"; then echo "PASS web $b: both compilers"
    else echo "FAIL web $b: the compilers' modules differ"; rc=1; fi
done

[ $rc = 0 ] && echo "--- web plugins: pass ---" || echo "--- web plugins: FAIL ---"
exit $rc
