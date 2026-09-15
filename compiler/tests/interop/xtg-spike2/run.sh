#!/bin/sh
# Spike 2 (Xtg multi-host) — the AppKit / Objective-C bridge, the macOS go/no-go.
# AppKit is Objective-C, so it is driven from xtc via objc_msgSend, and receiving
# a callback means registering an xtc function as an ObjC method (IMP) at runtime.
# Because objc_msgSend must be cast per-signature, a real xtc AppKit binding would
# GENERATE those typed wrappers; here they are a thin hand-written C shim
# (objcshim.m). ALL the AppKit choreography is in the xtc program (spike2.xc).
# See Rocks/doc/XTG-MULTIPLATFORM.md §10 (Spike 2).
#
# Gate: drive objc_msgSend to open an NSWindow + NSButton, register a class with a
# callback IMP, and receive the button's target-action into an xtc method. Runs
# native on the dev Mac; headless/deterministic (performClick fires the action
# synchronously — no run loop, no display needed).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
[ "$(uname)" = "Darwin" ] || { echo "== skipped (not macOS) =="; exit 0; }
xtc="$root/bin/osx/xcc"
exp="$(cat "$here/expected.out")"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

clang -O2 -shared -framework Cocoa -install_name "$work/libobjcshim.dylib" \
      -o "$work/libobjcshim.dylib" "$here/objcshim.m"
"$xtc" -H "$root" -A arm64 -L "$work" -o "$work/spike2" "$here/spike2.xc" -q 2>/dev/null
got=$("$work/spike2" 2>/dev/null)
if [ "$got" = "$exp" ]; then echo "== macOS/AppKit (arm64): PASS =="; exit 0
else echo "== macOS/AppKit (arm64): FAIL =="; printf 'want:\n%s\ngot:\n%s\n' "$exp" "$got"; exit 1; fi
