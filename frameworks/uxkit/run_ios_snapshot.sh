#!/bin/sh
# run_ios_snapshot.sh — the `ios-snapshot` gate: UXWindow.snapshot in the simulator: the GL frame
# (an EAGLContext, painted in the 2-D pass), the 2-D views over it and a native UIButton, whole or a
# region.  Skips cleanly when the simulator toolchain is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v xcrun >/dev/null || { echo "== ios-snapshot: skipped (no xcrun) =="; exit 0; }
xcrun simctl list devices available 2>/dev/null | grep -q "iPhone" || { echo "== ios-snapshot: skipped (no iPhone simulator) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== ios-snapshot: building the shim + the test for ios-sim =="
xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -fno-objc-msgsend-selector-stubs \
    -c "$here/libUXIos.m" -o "$work/libUXIos.o"
# One in-house link: the ObjC shell object merges in, the frameworks and
# libobjc bind through the SDK's .tbd stubs. No clang link, no stopgap —
# compiler bugs 138/140 (uxkit 027/028/029) closed 2026-09-04.
"$xcc" -A ios-sim -I "$here" -D SNAP_IOS "$here/test_snapshot.xc" -Xlinker "$work/libUXIos.o" \
    -lobjc -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -o "$work/UXIosSnapshot" -q

echo "== ios-snapshot: bundling + launching =="
APP="$work/UXIosSnapshot.app"; mkdir "$APP"
cp "$work/UXIosSnapshot" "$APP/"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.compile-xc.ios-snapshot</string>
  <key>CFBundleExecutable</key><string>UXIosSnapshot</string>
  <key>CFBundleName</key><string>UXIosSnapshot</string>
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
out=$(xcrun simctl launch --console-pty "$UDID" com.compile-xc.ios-snapshot 2>&1 | tee /dev/stderr) || true
echo "$out" | grep -q "^PASS" || { echo "== ios-snapshot: FAILED =="; exit 1; }
echo "== ios-snapshot: OK =="
