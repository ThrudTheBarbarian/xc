#!/bin/bash
# End-to-end self-hosted toolchain proof (Phase 4/6): `xtc --self-host` compiles,
# assembles, links, and signs an arm64/macOS executable entirely in-house — no
# clang, no codesign, no system assembler — and it runs. macOS/arm64 only; not
# part of make test (it needs to execute a signed binary on Apple Silicon).
set -e
cd "$(dirname "$0")/../.."
XTC=bin/osx/xcc
[ -x "$XTC" ] && [ -x bin/osx/xcc-ln-arm64 ] || { echo "build first: make"; exit 1; }
tmp=$(mktemp -d); fail=0
"$XTC" -A arm64 --self-host -L support/arm64/lib -o "$tmp/prog" tests/asm-arm64/selfhost-hello.xc >/dev/null 2>&1
out=$("$tmp/prog"); rc=$?
want=$'Hello, native!\nanswer=42'
if [ "$out" = "$want" ] && [ "$rc" = 0 ]; then
  echo "  PASS: xtc --self-host (compile->assemble->link->sign->run, no external tools)"
else echo "  FAIL: rc=$rc out='$out'"; fail=1; fi
codesign -v "$tmp/prog" 2>/dev/null && echo "  PASS: our ad-hoc signature validates" || { echo "  FAIL: signature"; fail=1; }
# Exit-status parity: an `i32 main` must propagate its return through the crt to
# the process exit code, exactly like clang (the crt used to hardcode exit 0).
echo 'i32 main(void){ return 42; }' > "$tmp/ec.xc"
"$XTC" -A arm64 --self-host -o "$tmp/ec" "$tmp/ec.xc" >/dev/null 2>&1
ecrc=0; "$tmp/ec" || ecrc=$?    # `|| ecrc=$?` so `set -e` ignores the nonzero rc
if [ "$ecrc" = 42 ]; then echo "  PASS: i32 main return propagates to exit status (42)";
else echo "  FAIL: exit status $ecrc (want 42 — crt dropped main's return?)"; fail=1; fi
# only libSystem import should be _write (everything else compiled in + linked in-house)
imps=$(dyld_info -fixups "$tmp/prog" 2>/dev/null | grep -c bind || true)
echo "  INFO: $imps libSystem bind(s) (expect 1: _write)"
# Foreign-dylib link: --self-host resolves a user `-l<name>` to a real
# lib<name>.dylib and binds against it IN-HOUSE — no clang. (clang builds only the
# foreign lib here; xtc links the caller.) Guards the -l/-L wiring on the linker's
# generic Mach-O reader.
cat > "$tmp/fg.c" <<'CEOF'
#include <unistd.h>
long fgreet(void){ write(1, "foreign dylib ok\n", 17); return 0; }
CEOF
clang -arch arm64 -dynamiclib -install_name @rpath/libfg.dylib "$tmp/fg.c" -o "$tmp/libfg.dylib" 2>/dev/null
printf 'i32 main(void) { asm { bl _fgreet } return 0; }\n' > "$tmp/callf.xc"
fnote=$("$XTC" -A arm64 --self-host -L "$tmp" -lfg -o "$tmp/callf" "$tmp/callf.xc" 2>&1 || true)
frun=$("$tmp/callf" 2>&1 || true)
if echo "$fnote" | grep -q 'no clang' && [ "$frun" = "foreign dylib ok" ]; then
  echo "  PASS: --self-host links a foreign -l dylib in-house (no clang)"
else echo "  FAIL: foreign -l dylib (note='$(echo "$fnote" | tail -1)' run='$frun')"; fail=1; fi
# Inline-asm @PAGE/@PAGEOFF to a DATA symbol: xtc re-emits `_g@PAGE` as `_g @ PAGE`
# (spaces around the `@`, its pointer operator); the in-house assembler must
# tolerate that, else `bare` keeps a trailing space, the symbol never resolves,
# and the adrp/add point at 0 → a wild store (was SIGBUS). Exit = the stored byte.
cat > "$tmp/pg.xc" <<'XEOF'
u32 g;
i32 main(void) {
    asm {
        mov w1, #49
        adrp x2, _g@PAGE
        add  x2, x2, _g@PAGEOFF
        str  w1, [x2]
    }
    return (i32)g;
}
XEOF
"$XTC" -A arm64 --self-host -o "$tmp/pg" "$tmp/pg.xc" >/dev/null 2>&1
pgrc=0; "$tmp/pg" || pgrc=$?
if [ "$pgrc" = 49 ]; then echo "  PASS: inline-asm @PAGE/@PAGEOFF to a data symbol (49)";
else echo "  FAIL: @PAGE data store exit $pgrc (want 49 — spaced @ modifier?)"; fail=1; fi
# System-lib link via an SDK .tbd stub, FUNCTIONALLY: modern macOS has no on-disk
# /usr/lib/libz.dylib, so `-lz` resolves to the SDK's libz.tbd; the in-house linker
# reads its install-name + exports, binds _zlibVersion against it, and the call
# returns the version string whose first byte ('1'=49) becomes the exit code —
# proving the bind is functional, not just present. (Skips if no SDK.)
cat > "$tmp/zv.xc" <<'ZEOF'
u32 g;
i32 main(void) {
    asm {
        bl _zlibVersion
        ldrb w1, [x0]
        adrp x2, _g@PAGE
        add  x2, x2, _g@PAGEOFF
        str  w1, [x2]
    }
    return (i32)g;
}
ZEOF
znote=$("$XTC" -A arm64 --self-host -lz -o "$tmp/zv" "$tmp/zv.xc" 2>&1 || true)
if echo "$znote" | grep -q 'no clang'; then
  zrc=0; "$tmp/zv" || zrc=$?
  zclang=0; "$XTC" -A arm64 -lz -o "$tmp/zvc" "$tmp/zv.xc" >/dev/null 2>&1; "$tmp/zvc" || zclang=$?
  if [ "$zrc" = "$zclang" ] && [ "$zrc" -gt 0 ]; then
    echo "  PASS: --self-host binds a system lib via its SDK .tbd stub (-lz → $zrc, == clang)"
  else echo "  FAIL: -lz .tbd functional (self=$zrc clang=$zclang)"; fail=1; fi
else echo "  SKIP: -lz .tbd (no SDK stub found — fell back to clang)"; fi
# Framework link via its SDK .tbd: `-framework CoreFoundation` resolves to
# CoreFoundation.framework/CoreFoundation.tbd and binds a C-API call
# (_CFAllocatorGetDefault) in-house — no clang, no ObjC needed.
printf 'i32 main(void) { asm { bl _CFAllocatorGetDefault } return 0; }\n' > "$tmp/cf.xc"
cfnote=$("$XTC" -A arm64 --self-host -framework CoreFoundation -o "$tmp/cf" "$tmp/cf.xc" 2>&1 || true)
if echo "$cfnote" | grep -q 'no clang'; then
  cfrc=0; "$tmp/cf" || cfrc=$?
  cfload=$(otool -L "$tmp/cf" 2>/dev/null | grep -c 'CoreFoundation' || true)
  if [ "$cfrc" = 0 ] && [ "$cfload" -ge 1 ]; then
    echo "  PASS: --self-host links a -framework via its SDK .tbd (CoreFoundation, in-house)"
  else echo "  FAIL: -framework (rc=$cfrc loads=$cfload)"; fail=1; fi
else echo "  SKIP: -framework (no SDK framework .tbd — fell back to clang)"; fi
# Linker-flag passthrough: -Wl,-rpath reaches the in-house linker (adds LC_RPATH)
# instead of forcing a clang fallback; an unknown flag is ignored, not fatal.
rpnote=$("$XTC" -A arm64 --self-host -Wl,-rpath,/opt/xtctest -Wl,-made_up -o "$tmp/rp" "$tmp/ec.xc" 2>&1 || true)
rphas=$(otool -l "$tmp/rp" 2>/dev/null | grep -c '/opt/xtctest' || true)
if echo "$rpnote" | grep -q 'no clang' && [ "$rphas" -ge 1 ]; then
  echo "  PASS: -Wl,-rpath forwarded to the in-house linker (LC_RPATH, unknown flag ignored)"
else echo "  FAIL: -Wl,-rpath passthrough (rpath=$rphas)"; fail=1; fi
# --no-self-host forces the clang path even when --self-host is also given.
nsnote=$("$XTC" -A arm64 --self-host --no-self-host -o "$tmp/ns" "$tmp/ec.xc" 2>&1 || true)
if echo "$nsnote" | grep -q 'no clang'; then echo "  FAIL: --no-self-host still went in-house"; fail=1;
else echo "  PASS: --no-self-host forces the clang path"; fi
# Static-archive (.a) linking: pull a clang-built static library's members into
# the image (functions + inter-object relocations), fully in-house. inc2 calls
# inc (a BRANCH26 reloc across two .o members), so both must be pulled; the exit
# code (inc2(40)=42) proves the calls resolved.
echo 'long inc(long x){ return x+1; }' > "$tmp/inc.c"
printf 'extern long inc(long);\nlong inc2(long x){ return inc(inc(x)); }\n' > "$tmp/inc2.c"
clang -c -target arm64-apple-macos11 -O2 "$tmp/inc.c" -o "$tmp/inc.o" 2>/dev/null
clang -c -target arm64-apple-macos11 -O2 "$tmp/inc2.c" -o "$tmp/inc2.o" 2>/dev/null
ar rcs "$tmp/libinc.a" "$tmp/inc.o" "$tmp/inc2.o" 2>/dev/null
cat > "$tmp/us.xc" <<'AEOF'
u32 g;
i32 main(void) {
    asm { mov x0, #40
          bl _inc2
          adrp x2, _g@PAGE
          add  x2, x2, _g@PAGEOFF
          str  w0, [x2] }
    return (i32)g;
}
AEOF
usnote=$("$XTC" -A arm64 --self-host -L "$tmp" -linc -o "$tmp/us" "$tmp/us.xc" 2>&1 || true)
usrc=0; "$tmp/us" || usrc=$?
if echo "$usnote" | grep -q 'no clang' && [ "$usrc" = 42 ]; then
  echo "  PASS: --self-host links a static .a (functions + inter-object calls, in-house)"
else echo "  FAIL: static .a link (note='$(echo "$usnote"|tail -1)' rc=$usrc)"; fail=1; fi
# Static .a with a DATA global: bump() increments g_counter (starts 100) — its
# __data section is merged and the adrp/ldr/str @PAGE relocs to _g_counter resolve
# (PAGEOFF12 scaled correctly for the ldr).
echo 'long g_counter = 100; long bump(void){ return ++g_counter; }' > "$tmp/g.c"
clang -c -target arm64-apple-macos11 -O2 "$tmp/g.c" -o "$tmp/g.o" 2>/dev/null
ar rcs "$tmp/libg.a" "$tmp/g.o" 2>/dev/null
cat > "$tmp/ug.xc" <<'GEOF'
u32 r;
i32 main(void) {
    asm { bl _bump
          bl _bump
          adrp x2, _r@PAGE
          add  x2, x2, _r@PAGEOFF
          str  w0, [x2] }
    return (i32)r;
}
GEOF
ugnote=$("$XTC" -A arm64 --self-host -L "$tmp" -lg -o "$tmp/ug" "$tmp/ug.xc" 2>&1 || true)
ugrc=0; "$tmp/ug" || ugrc=$?
if echo "$ugnote" | grep -q 'no clang' && [ "$ugrc" = 102 ]; then
  echo "  PASS: --self-host links a static .a that references a __data global (in-house)"
else echo "  FAIL: static .a data global (note='$(echo "$ugnote"|tail -1)' rc=$ugrc)"; fail=1; fi
# Static .a with a __cstring literal: greet() returns "hi"; the l_.str ref is a
# reloc to a LOCAL symbol (registered per-object to avoid clashes). Read greet()[0].
printf 'const char *greet(void){ return "hi"; }\n' > "$tmp/s.c"
clang -c -target arm64-apple-macos11 -O2 "$tmp/s.c" -o "$tmp/s.o" 2>/dev/null
ar rcs "$tmp/libs.a" "$tmp/s.o" 2>/dev/null
cat > "$tmp/usc.xc" <<'SEOF'
u32 r;
i32 main(void) {
    asm { bl _greet
          ldrb w1, [x0]
          adrp x2, _r@PAGE
          add  x2, x2, _r@PAGEOFF
          str  w1, [x2] }
    return (i32)r;
}
SEOF
scnote=$("$XTC" -A arm64 --self-host -L "$tmp" -ls -o "$tmp/usc" "$tmp/usc.xc" 2>&1 || true)
scrc=0; "$tmp/usc" || scrc=$?
if echo "$scnote" | grep -q 'no clang' && [ "$scrc" = 104 ]; then
  echo "  PASS: --self-host links a static .a with a string literal / local symbol (in-house)"
else echo "  FAIL: static .a string literal (note='$(echo "$scnote"|tail -1)' rc=$scrc)"; fail=1; fi
# Static .a with a function-pointer TABLE: the `.quad _fa/_fb` slots are
# ARM64_RELOC_UNSIGNED data relocs → Pointer64 fixups (patched + rebased).
cat > "$tmp/p.c" <<'PEOF'
long fa(void){ return 10; }
long fb(void){ return 32; }
long (*const tab[2])(void) = { fa, fb };
long callidx(long i){ return tab[i](); }
PEOF
clang -c -target arm64-apple-macos11 -O2 "$tmp/p.c" -o "$tmp/p.o" 2>/dev/null
ar rcs "$tmp/libptb.a" "$tmp/p.o" 2>/dev/null
cat > "$tmp/up.xc" <<'UEOF'
u32 r;
i32 main(void) {
    asm { mov x0, #1
          bl _callidx
          adrp x2, _r@PAGE
          add  x2, x2, _r@PAGEOFF
          str  w0, [x2] }
    return (i32)r;
}
UEOF
upnote=$("$XTC" -A arm64 --self-host -L "$tmp" -lptb -o "$tmp/up" "$tmp/up.xc" 2>&1 || true)
uprc=0; "$tmp/up" || uprc=$?
if echo "$upnote" | grep -q 'no clang' && [ "$uprc" = 32 ]; then
  echo "  PASS: --self-host links a static .a function-pointer table (UNSIGNED data relocs)"
else echo "  FAIL: static .a pointer table (rc=$uprc)"; fail=1; fi
# Static .a with a GOT reference to a global defined in another member: the
# adrp/ldr GOT pair is RELAXED to adrp/add (no GOT entry needed).
echo 'long shared_var = 7;' > "$tmp/gd.c"
printf 'extern long shared_var;\nlong readit(void){ return shared_var * 6; }\n' > "$tmp/gu.c"
clang -c -target arm64-apple-macos11 -O2 "$tmp/gd.c" -o "$tmp/gd.o" 2>/dev/null
clang -c -target arm64-apple-macos11 -O2 "$tmp/gu.c" -o "$tmp/gu.o" 2>/dev/null
ar rcs "$tmp/libgotr.a" "$tmp/gd.o" "$tmp/gu.o" 2>/dev/null
cat > "$tmp/ugd.xc" <<'DEOF'
u32 r;
i32 main(void) {
    asm { bl _readit
          adrp x2, _r@PAGE
          add  x2, x2, _r@PAGEOFF
          str  w0, [x2] }
    return (i32)r;
}
DEOF
gdnote=$("$XTC" -A arm64 --self-host -L "$tmp" -lgotr -o "$tmp/ugd" "$tmp/ugd.xc" 2>&1 || true)
gdrc=0; "$tmp/ugd" || gdrc=$?
if echo "$gdnote" | grep -q 'no clang' && [ "$gdrc" = 42 ]; then
  echo "  PASS: --self-host relaxes a static .a GOT data reference (adrp/ldr -> adrp/add)"
else echo "  FAIL: static .a GOT relaxation (rc=$gdrc)"; fail=1; fi
# Static .a whose GOT reference is a TRUE external data import (libSystem's
# _environ): can't be relaxed, so it gets a real __got slot + bind.
printf 'extern char **environ;\nlong haveenv(void){ return environ != 0 ? 7 : 0; }\n' > "$tmp/ev.c"
clang -c -target arm64-apple-macos11 -O2 "$tmp/ev.c" -o "$tmp/ev.o" 2>/dev/null
ar rcs "$tmp/libev.a" "$tmp/ev.o" 2>/dev/null
cat > "$tmp/uev.xc" <<'VEOF'
u32 r;
i32 main(void) {
    asm { bl _haveenv
          adrp x2, _r@PAGE
          add  x2, x2, _r@PAGEOFF
          str  w0, [x2] }
    return (i32)r;
}
VEOF
evnote=$("$XTC" -A arm64 --self-host -L "$tmp" -lev -o "$tmp/uev" "$tmp/uev.xc" 2>&1 || true)
evrc=0; "$tmp/uev" || evrc=$?
evbind=$(dyld_info -fixups "$tmp/uev" 2>/dev/null | grep -c '_environ' || true)
if echo "$evnote" | grep -q 'no clang' && [ "$evrc" = 7 ] && [ "$evbind" -ge 1 ]; then
  echo "  PASS: --self-host gives a static .a external data import a real __got slot + bind"
else echo "  FAIL: static .a data GOT import (rc=$evrc binds=$evbind)"; fail=1; fi
# Static .a with an ARM64_RELOC_ADDEND pair (`&arr[4]` → sym + 0x20).
cat > "$tmp/ad.c" <<'AAEOF'
long arr[8] = {0,10,20,30,40,50,60,70};
long *p4(void){ return &arr[4]; }
long get4(void){ return *p4(); }
AAEOF
clang -c -target arm64-apple-macos11 -O2 "$tmp/ad.c" -o "$tmp/ad.o" 2>/dev/null
ar rcs "$tmp/libad.a" "$tmp/ad.o" 2>/dev/null
cat > "$tmp/uad.xc" <<'AEOF2'
u32 r;
i32 main(void) {
    asm { bl _get4
          adrp x2, _r@PAGE
          add  x2, x2, _r@PAGEOFF
          str  w0, [x2] }
    return (i32)r;
}
AEOF2
adnote=$("$XTC" -A arm64 --self-host -L "$tmp" -lad -o "$tmp/uad" "$tmp/uad.xc" 2>&1 || true)
adrc=0; "$tmp/uad" || adrc=$?
if echo "$adnote" | grep -q 'no clang' && [ "$adrc" = 40 ]; then
  echo "  PASS: --self-host applies a static .a ARM64_RELOC_ADDEND pair (sym+N)"
else echo "  FAIL: static .a ADDEND (rc=$adrc)"; fail=1; fi
rm -rf "$tmp"; exit $fail
