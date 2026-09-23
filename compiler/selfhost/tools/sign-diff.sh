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
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -x "$BIN/xcc" ] || BIN=bin/linux
WORK=${TMPDIR:-/tmp}/signdiff.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
INCS=(-I selfhost/asm -I selfhost/link)
echo "building xtsign + mkident (xtc → native arm64)…"
"$BIN/xcc" -q -O2 -A arm64 -H . -o "$WORK/xtsign" selfhost/tools/xtsign.xc "${INCS[@]}" > "$WORK/b1.log" 2>&1
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

