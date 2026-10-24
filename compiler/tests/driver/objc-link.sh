#!/bin/bash
# objc-link.sh — an object link adds libobjc when an object REFERENCES the
# Objective-C runtime, and only then (bug 068; 2026-10-24). The test was a
# scan of the objects' bytes for "_objc_msgSend", which matched a compiler
# whose own sources hold that text as a string: every split-built xcc linked
# libobjc, and `make install` refused it as an Objective-C build. It reads the
# symbol table now, for an undefined name.
#
#   bash tests/driver/objc-link.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
[ "$(uname -s)" = Darwin ] || { echo "objc-link: macOS only, skipped"; exit 0; }
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# The text alone: a string, never called.
cat > "$W/text.xc" <<'XC'
#import "Stdio.xc"
i32 main(void)
    {
    Stdio.printf("%s\n", "_objc_msgSend _OBJC_CLASS_$_NSObject");
    return 0;
    }
XC
# A real reference: an Objective-C object linked in (plain objc_msgSend
# calls; the selector stubs clang emits by default are ld64's to make).
cat > "$W/probe.m" <<'M'
#import <Foundation/Foundation.h>
int objc_probe(void) { return (int)[[NSString stringWithUTF8String:"four"] length]; }
M
cat > "$W/main.xc" <<'XC'
#import "Stdio.xc"
i32 objc_probe(void);
i32 main(void)
    {
    Stdio.printf("%d\n", objc_probe());
    return 0;
    }
XC
clang -c -fno-objc-msgsend-selector-stubs -o "$W/probe.o" "$W/probe.m" 2>/dev/null || { echo "objc-link: no clang, skipped"; exit 0; }
for XC in ${XC:-bin/osx/xcc bin/osx/xcc-xc}; do
    [ -x "$XC" ] || continue
    d="$W/$(basename "$XC")"; mkdir -p "$d"
    "$XC" -q -H . -c -o "$d/text.o" "$W/text.xc" && "$XC" -q -H . -o "$d/text" "$d/text.o" > "$d/out" 2>&1 \
        || { echo "FAIL $XC: the text-only program did not link"; head -3 "$d/out"; fail=1; continue; }
    otool -L "$d/text" | grep -q libobjc && { echo "FAIL $XC: a string \"_objc_msgSend\" made the link add libobjc"; fail=1; }
    # Bug 068's own shape: a source build with the ObjC object passed through.
    "$XC" -q -H . -framework Foundation -o "$d/p" "$W/main.xc" -Xlinker "$W/probe.o" > "$d/out2" 2>&1 \
        || { echo "FAIL $XC: the program with an ObjC object did not link"; head -3 "$d/out2"; fail=1; continue; }
    otool -L "$d/p" | grep -q libobjc || { echo "FAIL $XC: an ObjC object's link lacks libobjc"; fail=1; }
    got=$("$d/p" 2>&1)
    [ "$got" = "4" ] || { echo "FAIL $XC: the ObjC program gives '$got'"; fail=1; }
done
[ $fail = 0 ] && echo "objc-link: ok"
exit $fail
