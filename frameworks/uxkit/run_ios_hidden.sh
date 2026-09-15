#!/bin/sh
# run_ios_hidden.sh — the `ios-hidden` gate: hidden is inherited by NATIVE
# descendants on iOS.  The fourth copy of a fix that shipped gated on AppKit,
# GTK and Win32 and unverifiable here, because the self-hosted compiler could
# not build ios-sim at all.  It can now, so this closes it.
# Skips cleanly when the simulator toolchain is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v xcrun >/dev/null || { echo "== ios-hidden: skipped (no xcrun) =="; exit 0; }
xcrun simctl list devices available 2>/dev/null | grep -q "iPhone" || { echo "== ios-hidden: skipped (no iPhone simulator) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== ios-hidden: building the shim + the test for ios-sim =="
xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -fno-objc-msgsend-selector-stubs \
    -c "$here/libUXIos.m" -o "$work/libUXIos.o"
# ONE xcc line: the in-house linker handles ios-sim now, so the clang stopgap
# (tools/ios_stopgap_link.sh, and the .s detour around bug 029) is gone -- which
# was that script's stated ambition.  It also fixes the link outright: the
# stopgap pulled in the MACOS runtime, which has no _xt_ios_fetch/_free/_log, so
# every iOS gate failed to link once the runtime split out into lib/xc/ios.
"$xcc" -A ios-sim -I "$here" "$here/test_hiddeninherit_ios.xc" \
    -Xlinker "$work/libUXIos.o" \
    -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -o "$work/UXIosHidden" -q

echo "== ios-hidden: bundling + launching =="
APP="$work/UXIosHidden.app"; mkdir "$APP"
cp "$work/UXIosHidden" "$APP/"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.compile-xc.ios-hidden</string>
  <key>CFBundleExecutable</key><string>UXIosHidden</string>
  <key>CFBundleName</key><string>UXIosHidden</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>UILaunchScreen</key><dict/>
</dict>
</plist>
PLIST

UDID=$(xcrun simctl list devices available | grep -m1 "iPhone 16 Pro (" | grep -oE "[0-9A-F-]{36}")
[ -n "$UDID" ] || UDID=$(xcrun simctl list devices available | grep -m1 "iPhone" | grep -oE "[0-9A-F-]{36}")
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl install "$UDID" "$APP"
out=$(xcrun simctl launch --console-pty "$UDID" com.compile-xc.ios-hidden 2>&1 | tee /dev/stderr) || true
echo "$out" | grep -q "^PASS" || { echo "== ios-hidden: FAILED =="; exit 1; }
echo "== ios-hidden: OK =="
