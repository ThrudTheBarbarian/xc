#!/bin/bash
# sign-diff.sh — the self-hosted signer (xtsign) against xcc-sign, byte for byte.
#
#   bash selfhost/tools/sign-diff.sh
#
# Identity code signing has a deterministic output for a given identity and
# signing time (both tools stamp 2026-01-01T00:00:00Z), so the two signers are
# compared on the FILE: an ad-hoc ios-sim and macOS binary each re-signed
# with a self-signed identity, plain and PKCS#8/3DES-encrypted (the wrap
# `xcc-sign --export-identity` writes). codesign -dvvv must parse the result;
# trust is not checked (a self-signed cert has none — signing.md, "the
# de-risker"). openssl supplies the encrypted vector when present; the xtc
# mkident makes the plain one with no dependency at all.
#
# The identity-making half is compared too. --export-identity: both signers
# export one identity from a throwaway keychain (macOS, `security`), with and
# without a provisioning profile, and must agree on everything but the
# randomly salted key wrap. --fetch-identity / --list-certs / --revoke-cert:
# the port runs against asc-mock.py, a local TLS stand-in for App Store Connect
# that checks the JWT, the CSR and the requests (python3 + openssl); the
# identity it fetches must sign byte for byte like the reference. The option
# and error surface of both is compared message for message.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -x "$BIN/xcc" ] || BIN=bin/linux
WORK=${TMPDIR:-/tmp}/signdiff.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
INCS=(-I selfhost/asm -I selfhost/link)
echo "building xtsign + mkident (xtc → native arm64)…"
# Built as the Makefile builds it: the keychain on macOS, TLS when the tls
# module and Mbed TLS are there (make builds build/tls/tlsshim.o).
HOSTF=(); TLS=0
[ "$(uname)" = Darwin ] && HOSTF+=(-DXT_HAVE_KEYCHAIN=1 -framework Security -framework CoreFoundation)
MB=${MBEDTLS_PREFIX:-/opt/homebrew/opt/mbedtls}/lib
if [ -f build/tls/tlsshim.o ] && [ -f "$MB/libmbedtls.a" ]; then
    TLS=1; HOSTF+=(-DXT_HAVE_TLS=1 -Wl,build/tls/tlsshim.o)
    for l in mbedtls mbedx509 mbedcrypto tfpsacrypto; do HOSTF+=("-Wl,$MB/lib$l.a"); done
fi
"$BIN/xcc" -q -O2 -A arm64 -H . "${HOSTF[@]}" -o "$WORK/xtsign" selfhost/tools/xtsign.xc "${INCS[@]}" > "$WORK/b1.log" 2>&1
"$BIN/xcc" -q -O2 -A arm64 -H . -o "$WORK/mkident" selfhost/tools/mkident.xc "${INCS[@]}" > "$WORK/b2.log" 2>&1
[ -x "$WORK/xtsign" ] && [ -x "$WORK/mkident" ] || { grep -a error "$WORK"/b*.log | head -5; exit 1; }

pass=0; fail=0; skipped=0
declare -a FAILED
"$WORK/mkident" "$WORK/self.pem" "sign-diff self-signed" || { echo "mkident failed"; exit 1; }
IDS=("$WORK/self.pem")
if command -v openssl >/dev/null 2>&1; then
    openssl genrsa -traditional -out "$WORK/ok.pem" 2048 2>/dev/null
    openssl req -x509 -new -key "$WORK/ok.pem" -days 30 -subj "/CN=sign-diff openssl/OU=SIGNDIFF00" -out "$WORK/oc.pem" 2>/dev/null
    openssl pkcs8 -topk8 -v2 des-ede3-cbc -passout pass:signdiff -in "$WORK/ok.pem" -out "$WORK/oke.pem" 2>/dev/null
    cat "$WORK/oc.pem" "$WORK/ok.pem"  > "$WORK/o_plain.pem"
    cat "$WORK/oc.pem" "$WORK/oke.pem" > "$WORK/o_enc.pem"
    IDS+=("$WORK/o_plain.pem" "$WORK/o_enc.pem")
else
    skipped=$((skipped+1))
fi
for arch in ios-sim arm64; do
    if ! "$BIN/xcc" -q -A "$arch" -H . -o "$WORK/hello_$arch" tests/fixtures/hello.xc >/dev/null 2>&1; then
        skipped=$((skipped+1)); continue
    fi
    for id in "${IDS[@]}"; do
        b="$arch/$(basename "$id" .pem)"
        "$BIN/xcc-sign" --identity "$id" --passphrase signdiff --identifier com.compile-xc.hello \
            "$WORK/hello_$arch" "$WORK/ref.signed" >/dev/null 2>&1 || { fail=$((fail+1)); FAILED+=("$b (xcc-sign failed)"); continue; }
        "$WORK/xtsign" --identity "$id" --passphrase signdiff --identifier com.compile-xc.hello \
            "$WORK/hello_$arch" "$WORK/port.signed" >"$WORK/port.err" 2>&1 || { fail=$((fail+1)); FAILED+=("$b ($(head -1 "$WORK/port.err"))"); continue; }
        if ! cmp -s "$WORK/ref.signed" "$WORK/port.signed"; then
            fail=$((fail+1)); FAILED+=("$b ($(cmp -l "$WORK/ref.signed" "$WORK/port.signed" | wc -l | tr -d ' ') bytes)"); continue
        fi
        if command -v codesign >/dev/null 2>&1 && ! codesign -dvvv "$WORK/port.signed" 2>&1 | grep -q 'CodeDirectory v=20400'; then
            fail=$((fail+1)); FAILED+=("$b (codesign cannot parse the signature)"); continue
        fi
        pass=$((pass+1))
    done
done
# ── bundle-mode: the Mac-free app-bundle path, ref signer vs port signer ──
# CodeResources sealing + CD special slots 1 (Info.plist) / 3 (CodeResources) /
# 7 (DER entitlements). Committed fixtures + the self-signed identity — no
# secrets. docs/ios/bundle-signing.md. Both signers must agree byte for byte.
GOLD=tests/ios/bundle-golden
if [ -f "$GOLD/Info.plist" ] && [ -f "$GOLD/entitlements.plist" ] \
   && "$BIN/xcc" -q -A ios-sim -H . -o "$WORK/bexe" tests/fixtures/hello.xc >/dev/null 2>&1; then
    for side in ref port; do
        app="$WORK/${side}b.app"; rm -rf "$app"; mkdir -p "$app"
        cp "$WORK/bexe" "$app/bexe"; cp "$GOLD/Info.plist" "$app/Info.plist"; cp "$GOLD/entitlements.plist" "$app/res.plist"
    done
    "$BIN/xcc-sign" --seal-resources "$WORK/refb.app"  --resource Info.plist --resource res.plist >/dev/null 2>&1
    "$WORK/xtsign"  --seal-resources "$WORK/portb.app" --resource Info.plist --resource res.plist >/dev/null 2>&1
    if cmp -s "$WORK/refb.app/_CodeSignature/CodeResources" "$WORK/portb.app/_CodeSignature/CodeResources"; then
        pass=$((pass+1)); else fail=$((fail+1)); FAILED+=("bundle CodeResources ref!=port"); fi
    for side in ref port; do
        app="$WORK/${side}b.app"; SIGNER="$BIN/xcc-sign"; [ "$side" = port ] && SIGNER="$WORK/xtsign"
        "$SIGNER" --identity "$WORK/self.pem" --identifier com.compile-xc.ios-real \
            --entitlements "$GOLD/entitlements.plist" \
            --info-plist "$app/Info.plist" --code-resources "$app/_CodeSignature/CodeResources" \
            "$app/bexe" >/dev/null 2>&1
    done
    if cmp -s "$WORK/refb.app/bexe" "$WORK/portb.app/bexe"; then
        pass=$((pass+1)); else fail=$((fail+1)); FAILED+=("bundle signed-exe ref!=port ($(cmp -l "$WORK/refb.app/bexe" "$WORK/portb.app/bexe" 2>/dev/null | wc -l | tr -d ' ') bytes)"); fi
    if command -v codesign >/dev/null 2>&1; then
        if codesign -d --verbose=6 "$WORK/portb.app/bexe" 2>&1 | grep -q '\-7='; then
            pass=$((pass+1)); else fail=$((fail+1)); FAILED+=("bundle exe missing DER-entitlements slot 7"); fi
    else skipped=$((skipped+1)); fi

    # DER entitlements with an ARRAY value (keychain-access-groups): the two
    # signers must still agree byte for byte (recursive SEQUENCE encoding).
    if [ -f "$GOLD/entitlements-array.plist" ]; then
        cp "$WORK/bexe" "$WORK/arr_ref"; cp "$WORK/bexe" "$WORK/arr_port"
        "$BIN/xcc-sign" --identity "$WORK/self.pem" --identifier com.compile-xc.ios-real \
            --entitlements "$GOLD/entitlements-array.plist" "$WORK/arr_ref" >/dev/null 2>&1
        "$WORK/xtsign"  --identity "$WORK/self.pem" --identifier com.compile-xc.ios-real \
            --entitlements "$GOLD/entitlements-array.plist" "$WORK/arr_port" >/dev/null 2>&1
        if cmp -s "$WORK/arr_ref" "$WORK/arr_port"; then
            pass=$((pass+1)); else fail=$((fail+1)); FAILED+=("array-entitlements signed-exe ref!=port"); fi
    else skipped=$((skipped+1)); fi
else
    skipped=$((skipped+1))
fi

# ── the option and error surface, message for message ──
# Each case runs through both signers; stdout, stderr and the exit code must
# match. Cases that need a capability the port was built without are skipped.
same() {  # same <label> <args...>
    local label=$1; shift
    "$BIN/xcc-sign" "$@" >"$WORK/r.out" 2>"$WORK/r.err"; local rc1=$?
    "$WORK/xtsign" "$@" >"$WORK/p.out" 2>"$WORK/p.err"; local rc2=$?
    if [ $rc1 -eq $rc2 ] && cmp -s "$WORK/r.out" "$WORK/p.out" && cmp -s "$WORK/r.err" "$WORK/p.err"; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); FAILED+=("cli $label (rc $rc1/$rc2: $(head -1 "$WORK/p.err"))")
    fi
}
same "no arguments"
same "unknown option" --no-such-option
same "option without its value" hello --identity
same "unreadable identity" --identity "$WORK/none.pem" "$WORK/none"
same "seal without resources" --seal-resources "$WORK"
same "seal unreadable resource" --seal-resources "$WORK" --resource none.txt
same "export without -o" --export-identity x --passphrase p
same "export without passphrase" --export-identity x -o "$WORK/x.pem"
if [ "$TLS" = 1 ]; then
    same "fetch without the ASC key" --fetch-identity -o "$WORK/x.pem"
    same "fetch without passphrase" --fetch-identity -o "$WORK/x.pem" --asc-issuer i --asc-key-id k --asc-key "$WORK/none.p8"
    same "fetch with no .p8" --fetch-identity -o "$WORK/x.pem" --asc-issuer i --asc-key-id k --asc-key "$WORK/none.p8" --passphrase p
    same "list without the ASC key" --list-certs
    same "revoke without the ASC key" --revoke-cert X
else
    skipped=$((skipped+1))
fi

# A provisioning profile: a CMS-signed plist whose Entitlements carry every
# plist type, so its re-serialisation is checked against CoreFoundation's.
PROFILE=""
if command -v openssl >/dev/null 2>&1; then
    cat > "$WORK/profile.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Name</key>
  <string>Sign Diff Team Profile</string>
  <key>Entitlements</key>
  <dict>
    <key>keychain-access-groups</key>
    <array>
      <string>SIGNDIFF00.*</string>
      <string>com.apple.token</string>
    </array>
    <key>get-task-allow</key>
    <true/>
    <key>application-identifier</key>
    <string>SIGNDIFF00.com.compile-xc.hello &amp; &lt;more&gt;</string>
    <key>Zeta</key>
    <false/>
    <key>empty-array</key>
    <array/>
    <key>empty-dict</key>
    <dict/>
    <key>count</key>
    <integer>42</integer>
    <key>blob</key>
    <data>
    AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9Q
    </data>
    <key>nested</key>
    <dict>
      <key>b</key>
      <string></string>
      <key>a</key>
      <array><dict><key>x</key><data>AAEC</data></dict></array>
    </dict>
    <key>when</key>
    <date>2026-09-25T10:00:00Z</date>
  </dict>
</dict>
</plist>
PLIST
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/prof.key" -out "$WORK/prof.crt" -days 30 \
        -subj "/CN=sign-diff profile" 2>/dev/null
    openssl cms -sign -nodetach -binary -in "$WORK/profile.plist" -signer "$WORK/prof.crt" \
        -inkey "$WORK/prof.key" -outform DER -out "$WORK/test.mobileprovision" 2>/dev/null \
        && PROFILE="$WORK/test.mobileprovision"
fi

# Everything in two PEM bundles but the key wrap, and the keys unwrapped.
bundles_agree() {  # bundles_agree <a.pem> <b.pem> <passphrase>
    sed '/BEGIN ENC/,/END ENC/d' "$1" > "$WORK/ba.txt"; sed '/BEGIN ENC/,/END ENC/d' "$2" > "$WORK/bb.txt"
    cmp -s "$WORK/ba.txt" "$WORK/bb.txt" || return 1
    sed -n '/BEGIN ENC/,/END ENC/p' "$1" > "$WORK/ka.pem"; sed -n '/BEGIN ENC/,/END ENC/p' "$2" > "$WORK/kb.pem"
    openssl pkcs8 -in "$WORK/ka.pem" -passin "pass:$3" -outform DER -out "$WORK/ka.der" 2>/dev/null || return 1
    openssl pkcs8 -in "$WORK/kb.pem" -passin "pass:$3" -outform DER -out "$WORK/kb.der" 2>/dev/null || return 1
    cmp -s "$WORK/ka.der" "$WORK/kb.der"
}

# ── --export-identity, from a throwaway keychain ──
# The keychain lives in the work directory and is deleted by the EXIT trap on
# every path out. It never joins the search list or becomes the default, it
# has no lock timeout and no lock-on-sleep (a locked keychain would put a
# password prompt in front of the user), and the identity is imported with -A
# so the export needs no permission prompt either. Only a keychain this script
# created is ever opened.
if [ "$(uname)" = Darwin ] && command -v security >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
    KC="$(cd "$WORK" && pwd)/signdiff.keychain"
    trap 'security delete-keychain "$KC" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/kc.key" -out "$WORK/kc.crt" -days 30 \
        -subj "/CN=sign-diff keychain identity/OU=SIGNDIFF00" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$WORK/kc.key" -in "$WORK/kc.crt" -out "$WORK/kc.p12" -passout pass:p12 2>/dev/null
    if security create-keychain -p signdiff "$KC" 2>/dev/null && security set-keychain-settings "$KC" \
       && security unlock-keychain -p signdiff "$KC" \
       && security import "$WORK/kc.p12" -k "$KC" -P p12 -A >/dev/null 2>&1; then
        for tag in plain profile; do
            args=(--export-identity "keychain identity" --passphrase signdiff --keychain "$KC")
            if [ $tag = profile ]; then
                [ -n "$PROFILE" ] || { skipped=$((skipped+1)); continue; }
                args+=(--profile "$PROFILE")
            fi
            "$BIN/xcc-sign" "${args[@]}" -o "$WORK/exp.pem" >"$WORK/r.err" 2>&1
            mv "$WORK/exp.pem" "$WORK/ref-exp.pem" 2>/dev/null
            "$WORK/xtsign" "${args[@]}" -o "$WORK/exp.pem" >"$WORK/p.err" 2>&1
            if ! cmp -s "$WORK/r.err" "$WORK/p.err"; then
                fail=$((fail+1)); FAILED+=("export $tag: messages differ ($(head -1 "$WORK/p.err"))")
            elif ! bundles_agree "$WORK/ref-exp.pem" "$WORK/exp.pem" signdiff; then
                fail=$((fail+1)); FAILED+=("export $tag: the bundles differ")
            elif [ "$(stat -f %Lp "$WORK/exp.pem")" != 600 ]; then
                fail=$((fail+1)); FAILED+=("export $tag: the bundle is not owner-only")
            else
                pass=$((pass+1))
            fi
        done
        # The exported bundles sign alike.
        if "$BIN/xcc" -q -A arm64 -H . -o "$WORK/hexp" tests/fixtures/hello.xc >/dev/null 2>&1; then
            "$BIN/xcc-sign" --identity "$WORK/ref-exp.pem" --passphrase signdiff "$WORK/hexp" "$WORK/exp.ref" >/dev/null 2>&1
            "$WORK/xtsign" --identity "$WORK/exp.pem" --passphrase signdiff "$WORK/hexp" "$WORK/exp.port" >/dev/null 2>&1
            if cmp -s "$WORK/exp.ref" "$WORK/exp.port"; then pass=$((pass+1))
            else fail=$((fail+1)); FAILED+=("export: signing with the exported bundles differs"); fi
        fi
        same "export, no match" --export-identity "no such identity" -o "$WORK/x.pem" --passphrase p --keychain "$KC"
        same "export, empty name" --export-identity "" -o "$WORK/x.pem" --passphrase p --keychain "$KC"
    else
        skipped=$((skipped+1))
    fi
    security delete-keychain "$KC" >/dev/null 2>&1
else
    skipped=$((skipped+1))
fi

# ── Route 1 against a local App Store Connect ──
if [ "$TLS" = 1 ] && command -v python3 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && [ -n "$PROFILE" ]; then
    MK="$WORK/mock"; mkdir -p "$MK"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$MK/ca.key" -out "$MK/ca.crt" -days 30 -subj "/CN=sign-diff mock CA" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout "$MK/server.key" -out "$MK/server.csr" \
        -subj "/CN=api.appstoreconnect.apple.com" 2>/dev/null
    printf 'subjectAltName=DNS:api.appstoreconnect.apple.com,DNS:www.apple.com\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > "$MK/ext"
    openssl x509 -req -in "$MK/server.csr" -CA "$MK/ca.crt" -CAkey "$MK/ca.key" -set_serial 2 -days 30 \
        -out "$MK/server.crt" -extfile "$MK/ext" 2>/dev/null
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$MK/AuthKey_TEST.p8" 2>/dev/null
    openssl pkey -in "$MK/AuthKey_TEST.p8" -pubout -out "$MK/api.pub" 2>/dev/null
    echo SIGNDIFFKID > "$MK/kid"; echo 00000000-1111-2222-3333-444444444444 > "$MK/iss"
    cp "$PROFILE" "$MK/profile.bin"
    python3 selfhost/tools/asc-mock.py "$MK" "$MK/port" & MOCK=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$MK/port" ] && break; sleep 0.25; done
    ASC=(--asc-issuer "$(cat "$MK/iss")" --asc-key-id "$(cat "$MK/kid")" --asc-key "$MK/AuthKey_TEST.p8")
    export XCC_SIGN_HTTPS_CONNECT="127.0.0.1:$(cat "$MK/port" 2>/dev/null)" XCC_SIGN_CA_FILE="$MK/ca.crt"
    route1() {  # route1 <label> <expected rc> <expected output file|-> <args...>
        local label=$1 want=$2 exp=$3; shift 3
        "$WORK/xtsign" "$@" >"$WORK/m.out" 2>&1; local rc=$?
        if [ $rc -ne "$want" ]; then fail=$((fail+1)); FAILED+=("route1 $label: rc $rc ($(head -1 "$WORK/m.out"))")
        elif [ "$exp" != - ] && ! cmp -s "$exp" "$WORK/m.out"; then fail=$((fail+1)); FAILED+=("route1 $label: output differs")
        else pass=$((pass+1)); fi
    }
    printf 'CERT00  DEVELOPMENT                   Mock \303\251 0\nCERT01  DISTRIBUTION                  Mock \303\251 1\nCERT02  IOS_DEVELOPMENT               Mock \303\251 2\n' > "$WORK/list.want"
    printf 'xcc-sign: revoked certificate CERT01\n' > "$WORK/revoke.want"
    printf 'xcc-sign: revoke HTTP 409: {"errors":[{"status":"409","detail":"no such certificate"}]}\n' > "$WORK/revoke-bad.want"
    route1 "--list-certs" 0 "$WORK/list.want" --list-certs "${ASC[@]}"
    route1 "--revoke-cert" 0 "$WORK/revoke.want" --revoke-cert CERT01 "${ASC[@]}"
    route1 "--revoke-cert, refused" 1 "$WORK/revoke-bad.want" --revoke-cert NOPE "${ASC[@]}"
    route1 "--fetch-identity" 0 - --fetch-identity -o "$MK/id.pem" --passphrase signdiff --profile-name Team "${ASC[@]}"
    XCC_SIGN_CA_FILE=$WORK/prof.crt route1 "an untrusted server" 1 - --list-certs "${ASC[@]}"
    kill $MOCK 2>/dev/null; wait $MOCK 2>/dev/null
    unset XCC_SIGN_HTTPS_CONNECT XCC_SIGN_CA_FILE
    if grep -q FAIL "$MK/log" 2>/dev/null || ! grep -q "ok jwt" "$MK/log" 2>/dev/null; then
        fail=$((fail+1)); FAILED+=("route1: the mock refused a request ($(grep FAIL "$MK/log" | head -1))")
    else pass=$((pass+1)); fi
    # The fetched bundle: its key opens with openssl and is the certificate's,
    # its entitlements are CoreFoundation's, and it signs like the reference.
    if [ -s "$MK/id.pem" ]; then
        sed -n '/BEGIN ENC/,/END ENC/p' "$MK/id.pem" > "$MK/k.pem"
        awk '/BEGIN CERT/{n++} n==1{print} /END CERT/{if(n==1)exit}' "$MK/id.pem" > "$MK/leaf.pem"
        if openssl pkcs8 -in "$MK/k.pem" -passin pass:signdiff -out "$MK/k.dec" 2>/dev/null \
           && openssl rsa -in "$MK/k.dec" -check -noout >/dev/null 2>&1 \
           && [ "$(openssl x509 -in "$MK/leaf.pem" -noout -modulus)" = "$(openssl rsa -in "$MK/k.dec" -noout -modulus 2>/dev/null)" ]; then
            pass=$((pass+1)); else fail=$((fail+1)); FAILED+=("route1: the fetched key does not match its certificate"); fi
        if command -v plutil >/dev/null 2>&1; then
            plutil -extract Entitlements xml1 -o "$MK/ent.cf" "$WORK/profile.plist"
            awk '/BEGIN XCC ENT/{f=1;next} /END XCC ENT/{f=0} f' "$MK/id.pem" | openssl base64 -d > "$MK/ent.got"
            if cmp -s "$MK/ent.cf" "$MK/ent.got"; then pass=$((pass+1))
            else fail=$((fail+1)); FAILED+=("route1: the entitlements differ from CoreFoundation's"); fi
        fi
        if "$BIN/xcc" -q -A arm64 -H . -o "$MK/h" tests/fixtures/hello.xc >/dev/null 2>&1; then
            "$BIN/xcc-sign" --identity "$MK/id.pem" --passphrase signdiff "$MK/h" "$MK/h.ref" >/dev/null 2>&1
            "$WORK/xtsign" --identity "$MK/id.pem" --passphrase signdiff "$MK/h" "$MK/h.port" >/dev/null 2>&1
            if cmp -s "$MK/h.ref" "$MK/h.port"; then pass=$((pass+1))
            else fail=$((fail+1)); FAILED+=("route1: signing with the fetched identity differs"); fi
        fi
    else
        fail=$((fail+1)); FAILED+=("route1: no identity was fetched")
    fi
else
    skipped=$((skipped+1))
fi

if [ "${#FAILED[@]}" -gt 0 ]; then echo "--- differing:"; printf '  %s\n' "${FAILED[@]}"; fi
echo "--- sign-diff: pass=$pass fail=$fail skipped=$skipped ---"
[ "$fail" -eq 0 ] || exit 1
# NOTHING COMPARED is not a pass. Every one of these harnesses counts an oracle
# failure — a file the REFERENCE could not build — and skips it, so a broken
# oracle turns the whole sweep into skips and the summary reads pass=0 fail=0.
# Only `fail` was ever checked, so that exited 0 and showed as a clean row in
# all-diff's table. It has now happened twice on ldx86-diff alone, the second
# time hiding 961 uncompared files. private:docs/bugs/239.
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi

