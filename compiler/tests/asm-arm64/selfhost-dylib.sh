#!/bin/bash
# End-to-end self-hosted SHARED-LIBRARY proof (Phase 5): `xtc --self-host
# --emit-lib` builds an arm64/macOS .dylib (MH_DYLIB, export trie, __XTC,__iface
# metadata, ad-hoc signed) with no clang; then a client links against it — also
# self-hosted — via LC_LOAD_DYLIB + @rpath + a per-dylib bind ordinal, and real
# dyld resolves the cross-dylib symbol at run time. macOS/arm64 only; not part of
# make test (it executes signed binaries on Apple Silicon).
set -e
cd "$(dirname "$0")/../.."
XTC=bin/osx/xcc
[ -x "$XTC" ] && [ -x bin/osx/xcc-ln-arm64 ] || { echo "build first: make"; exit 1; }
tmp=$(mktemp -d); fail=0
mkdir -p "$tmp/src" "$tmp/lib"

cat > "$tmp/src/Mathx.xc" <<'XT'
class Mathx {
    static i16 triple(i16 x) { return x * 3; }
}
XT
cat > "$tmp/client.xc" <<'XT'
#use <Mathx>
#import <Stdio.xc>
void main(void) { Stdio.printf("triple(14)=%d\n", Mathx.triple(14)); return; }
XT

# 1. the library, self-hosted (no clang)
"$XTC" -A arm64 --self-host --emit-lib -L support/arm64/lib \
       -o "$tmp/lib/libMathx.dylib" "$tmp/src/Mathx.xc" >/dev/null 2>&1
if otool -hv "$tmp/lib/libMathx.dylib" 2>/dev/null | grep -q DYLIB; then
  echo "  PASS: self-hosted libMathx.dylib built (MH_DYLIB, no clang)"
else echo "  FAIL: dylib not built"; fail=1; fi
codesign -v "$tmp/lib/libMathx.dylib" 2>/dev/null && echo "  PASS: dylib ad-hoc signature validates" || { echo "  FAIL: dylib sig"; fail=1; }
xcrun dyld_info -exports "$tmp/lib/libMathx.dylib" 2>/dev/null | grep -q 'Mathx\$triple' \
  && echo "  PASS: export trie lists _Mathx\$triple" || { echo "  FAIL: export missing"; fail=1; }
otool -s __XTC __iface "$tmp/lib/libMathx.dylib" 2>/dev/null | grep -q iface \
  && echo "  PASS: __XTC,__iface metadata section present" || { echo "  FAIL: no iface section"; fail=1; }

# 2. the client, self-hosted, seeing ONLY the dylib (no source on the path)
"$XTC" -A arm64 --self-host -L "$tmp/lib" -L support/arm64/lib \
       -o "$tmp/client" "$tmp/client.xc" >/dev/null 2>&1
otool -L "$tmp/client" 2>/dev/null | grep -q libMathx \
  && echo "  PASS: client records LC_LOAD_DYLIB @rpath/libMathx.dylib" || { echo "  FAIL: no dylib load cmd"; fail=1; }
xcrun dyld_info -fixups "$tmp/client" 2>/dev/null | grep -q 'libMathx/_Mathx\$triple' \
  && echo "  PASS: _Mathx\$triple binds to libMathx (not libSystem)" || { echo "  FAIL: wrong bind"; fail=1; }

# 3. run it — real dyld loads our dylib and resolves the symbol
out=$("$tmp/client" 2>&1); rc=$?
if [ "$out" = "triple(14)=42" ] && [ "$rc" = 0 ]; then
  echo "  PASS: self-hosted client + self-hosted dylib runs (triple(14)=42)"
else echo "  FAIL: rc=$rc out='$out'"; fail=1; fi

rm -rf "$tmp"; exit $fail
