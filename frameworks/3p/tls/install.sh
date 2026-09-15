#!/bin/sh
# Build + install the general TLS module as a first-class 3p shared library at
# /opt/xcc/3p/tls, per private:docs/Design/third-party-libraries.md. Client preamble is
# then flag-free:  #use <tls>  +  #import "TlsAbi.xc".
#
# ┌─ WORKS incl. VERIFIED TLS as of 2026-08-25 (#45 + #46) ─────────────────────┐
# │ Bundling a heavy C library (Mbed TLS) with globals into a self-host .dylib   │
# │ took three in-house-linker fixes: COMMON symbols get storage (122ed356), the │
# │ dylib writer binds GOT imports of system data globals like ___stack_chk_guard│
# │ (c905fbac), and the object merge 16-ALIGNS bundled __data so SIMD 16-byte     │
# │ literals (mbedtls's constant-time base64 bounds) load correctly (b55e8e82).   │
# │ Verified: `#use <tls>` completes a real VERIFY_REQUIRED handshake (full CA    │
# │ chain) to a live host through the installed libtls — no clang.                │
# └────────────────────────────────────────────────────────────────────────────┘
set -e
cd "$(dirname "$0")"
HERE=$(pwd)
XCC=${XCC:-/opt/xcc/0.4/bin/xcc}
DEST=${DEST:-/opt/xcc/3p/tls}
MB=${MBEDTLS_PREFIX:-/opt/homebrew/opt/mbedtls}
MBLIN="$HERE/mbedtls-linux"
MAJ=1; MIN=0
TMP=$(mktemp -d)

mkdir -p "$DEST/arm64" "$DEST/xc"
cp xc/TlsVersion.xc xc/TlsAbi.xc "$DEST/xc/"

# ── arm64 (macOS): shim + brew static mbedtls, bundled into the dylib ──
cc -c -O2 -I"$MB/include" tlsshim.c -o "$TMP/tlsshim-arm64.o"
ar rcs "$TMP/libtlsshim-arm64.a" "$TMP/tlsshim-arm64.o"
"$XCC" --emit-lib -A arm64 -I xc -o "$TMP/libtls.dylib" xc/tls_lib.xc \
    -Wl,"$TMP/libtlsshim-arm64.a" \
    -Wl,"$MB/lib/libmbedtls.a" -Wl,"$MB/lib/libmbedx509.a" \
    -Wl,"$MB/lib/libmbedcrypto.a" -Wl,"$MB/lib/libtfpsacrypto.a"
cp "$TMP/libtls.dylib" "$DEST/arm64/libtls-$MAJ-$MIN.dylib"
ln -sf "libtls-$MAJ-$MIN.dylib" "$DEST/arm64/libtls.dylib"
echo "installed: $DEST/arm64/libtls.dylib -> libtls-$MAJ-$MIN.dylib"

# ── x86_64 (Linux/musl): shim + vendored static musl mbedtls, if present ──
if [ -f "$MBLIN/libmbedtls.a" ]; then
    mkdir -p "$DEST/x86_64"
    LINCC=${LINUX_CC:-/opt/homebrew/opt/llvm/bin/clang}
    SR=/opt/clang/linux/x86_64-linux-musl
    "$LINCC" --target=x86_64-linux-musl --sysroot="$SR" -c -O2 -I"$MB/include" \
        tlsshim.c -o "$TMP/tlsshim-musl.o"
    ar rcs "$TMP/libtlsshim-musl.a" "$TMP/tlsshim-musl.o"
    # x86_64 build (best-effort — for Linux xtc consumers; needs the musl
    # mbedtls + a working cross link, orthogonal to the macOS host, so a
    # failure here must not abort the arm64 + host install).
    if "$XCC" --emit-lib -A x86_64 -I xc -o "$TMP/libtls.so" xc/tls_lib.xc \
           -Wl,"$TMP/libtlsshim-musl.a" \
           -Wl,"$MBLIN/libmbedtls.a" -Wl,"$MBLIN/libmbedx509.a" \
           -Wl,"$MBLIN/libmbedcrypto.a" -Wl,"$MBLIN/libtfpsacrypto.a"; then
        cp "$TMP/libtls.so" "$DEST/x86_64/libtls-$MAJ-$MIN.so"
        ln -sf "libtls-$MAJ-$MIN.so" "$DEST/x86_64/libtls.so"
        echo "installed: $DEST/x86_64/libtls.so -> libtls-$MAJ-$MIN.so"
    else
        echo "NOTE: x86_64 libtls build failed (Linux consumers) — arm64 + host OK"
    fi
else
    echo "NOTE: no musl Mbed TLS at $MBLIN — skipped x86_64 (arm64 installed)"
fi

rm -rf "$TMP"
echo "done. client preamble:  #use <tls> ; #import \"TlsAbi.xc\" ; tls_require((i32)0)"
