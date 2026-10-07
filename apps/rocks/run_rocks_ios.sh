#!/bin/sh
# run_rocks_ios.sh — the `rocks-ios` gate: Rocks, unchanged, on an
# iPad simulator.  Builds the iOS shim and Rocks for ios-sim (one in-house link, as the UXKit iOS
# gates do), launches it, waits for its window-up line, and checks the window is really on screen:
# the simulator's screenshot must hold the editor's canvas, its blue grid, not a blank launch screen.
# ROCKS_IOS_SHOT=<png> keeps the screenshot.  Skips cleanly without the simulator toolchain.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v xcrun >/dev/null || { echo "== rocks-ios: skipped (no xcrun) =="; exit 0; }
UDID=$(xcrun simctl list devices available | grep -m1 "iPad Pro 11-inch" | grep -oE "[0-9A-F-]{36}")
[ -n "$UDID" ] || UDID=$(xcrun simctl list devices available | grep -m1 "iPad" | grep -oE "[0-9A-F-]{36}")
[ -n "$UDID" ] || { echo "== rocks-ios: skipped (no iPad simulator) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== rocks-ios: building the shim + Rocks for ios-sim =="
xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -fno-objc-msgsend-selector-stubs \
    -c "$ux/libUXIos.m" -o "$work/libUXIos.o"
"$xcc" -A ios-sim -I "$ux" -I "$here/xc" "$here/xc/rocks_main.xc" -Xlinker "$work/libUXIos.o" \
    -lobjc -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -framework UniformTypeIdentifiers -o "$work/Rocks" -q

echo "== rocks-ios: bundling + launching on an iPad =="
APP="$work/Rocks.app"; mkdir "$APP"
cp "$work/Rocks" "$APP/"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.compile-xc.rocks</string>
  <key>CFBundleExecutable</key><string>Rocks</string>
  <key>CFBundleName</key><string>Rocks</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>UIDeviceFamily</key><array><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string>
         <string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string></array>
</dict>
</plist>
PLIST
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl install "$UDID" "$APP"
# Rocks never exits (the platform owns the loop), so launch it in the background and watch its output.
( xcrun simctl launch --console-pty --terminate-running-process "$UDID" com.compile-xc.rocks > "$work/out.txt" 2>&1 & )
for i in $(seq 1 40); do grep -qE "^(PASS|FAIL|SKIP)" "$work/out.txt" 2>/dev/null && break; sleep 1; done
sleep 2
shot=${ROCKS_IOS_SHOT:-$work/shot.png}
xcrun simctl io "$UDID" screenshot "$shot" >/dev/null 2>&1 || true
xcrun simctl terminate "$UDID" com.compile-xc.rocks >/dev/null 2>&1 || true
grep -E "^(PASS|FAIL|SKIP)" "$work/out.txt" | head -2
grep -q "^PASS" "$work/out.txt" || { cat "$work/out.txt" | tail -15; echo "== rocks-ios: FAILED =="; exit 1; }
# on screen: the canvas pane (the middle of the editor) shows the editor's blue grid -- blue well
# above red, which a blank white or black launch screen is not
px=$(magick "$shot" -gravity center -crop 1x1+0+0 -format '%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]' info: 2>/dev/null || echo "?")
echo "screen centre pixel: $px"
r=${px%%,*}; b=${px##*,}
{ [ "$px" != "?" ] && [ $((b - r)) -ge 15 ] && [ "$b" -ge 200 ]; } || { echo "== rocks-ios: FAILED (the editor is not on screen) =="; exit 1; }
echo "== rocks-ios: OK — Rocks runs on an iPad =="
