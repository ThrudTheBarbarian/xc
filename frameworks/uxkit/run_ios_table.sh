#!/bin/sh
# run_ios_table.sh — the `ios-table` gate: UXTableView realized as a real UITableView in the
# simulator (rows and cells from the datasource, selection both ways, reload), unattended.  Skips
# cleanly when the simulator toolchain is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v xcrun >/dev/null || { echo "== ios-table: skipped (no xcrun) =="; exit 0; }
xcrun simctl list devices available 2>/dev/null | grep -q "iPhone" || { echo "== ios-table: skipped (no iPhone simulator) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== ios-table: building the shim + the test for ios-sim =="
xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -fno-objc-msgsend-selector-stubs \
    -c "$here/libUXIos.m" -o "$work/libUXIos.o"
# One in-house link: the ObjC shell object merges in, the frameworks and
# libobjc bind through the SDK's .tbd stubs. No clang link, no stopgap —
# compiler bugs 138/140 (uxkit 027/028/029) closed 2026-09-04.
"$xcc" -A ios-sim -I "$here" "$here/test_ios_table.xc" -Xlinker "$work/libUXIos.o" \
    -lobjc -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -o "$work/UXIosTable" -q

echo "== ios-table: bundling + launching =="
APP="$work/UXIosTable.app"; mkdir "$APP"
cp "$work/UXIosTable" "$APP/"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.compile-xc.ios-table</string>
  <key>CFBundleExecutable</key><string>UXIosTable</string>
  <key>CFBundleName</key><string>UXIosTable</string>
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
out=$(xcrun simctl launch --console-pty "$UDID" com.compile-xc.ios-table 2>&1 | tee /dev/stderr) || true
echo "$out" | grep -q "^PASS" || { echo "== ios-table: FAILED =="; exit 1; }
echo "== ios-table: OK =="
