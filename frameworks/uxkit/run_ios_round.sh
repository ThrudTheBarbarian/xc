#!/bin/sh
# run_ios_round.sh -- a rounded panel (setCornerRadius + setBorderRGB) on iOS, in the simulator, read
# back as pixels: the corner cut, the edge, the content inside, the bar inset.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v xcrun >/dev/null || { echo "== ios-round: skipped (no xcrun) =="; exit 0; }
xcrun simctl list devices available 2>/dev/null | grep -q "iPhone" || { echo "== ios-round: skipped (no iPhone simulator) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== ios-round: building the shim + the test for ios-sim =="
xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -fno-objc-msgsend-selector-stubs \
    -c "$here/libUXIos.m" -o "$work/libUXIos.o"
# One in-house link: the ObjC shell object merges in, the frameworks and
# libobjc bind through the SDK's .tbd stubs. No clang link, no stopgap —
# compiler bugs 138/140 (uxkit 027/028/029) closed 2026-09-04.
"$xcc" -A ios-sim -I "$here" "$here/test_ios_round.xc" -Xlinker "$work/libUXIos.o" \
    -lobjc -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -o "$work/UXIosRound" -q

echo "== ios-round: bundling + launching =="
APP="$work/UXIosRound.app"; mkdir "$APP"
cp "$work/UXIosRound" "$APP/"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.compile-xc.ios-round</string>
  <key>CFBundleExecutable</key><string>UXIosRound</string>
  <key>CFBundleName</key><string>UXIosRound</string>
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
out=$(xcrun simctl launch --console-pty "$UDID" com.compile-xc.ios-round 2>&1 | tee /dev/stderr) || true
echo "$out" | grep -q "^PASS" || { echo "== ios-round: FAILED =="; exit 1; }
echo "== ios-round: OK =="
