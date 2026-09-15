#!/bin/sh
# capture.sh — the widget portrait studio (docs "Platform appearance" tabs).
# Legs: web (real canvas backend under headless Chrome), ios (real native
# overlays via the simulator's renderInContext readback), and android (real
# android.widget overlays via the emulator's Bitmap readback).  ~100 captures
# by hand is why this exists.  PNGs land in website/site/public/uxkit/.
#
# usage: sh capture.sh [web|ios|android|gtk|all]   (default all)
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../.."
outdir="$ux/../../website/site/public/uxkit"
mkdir -p "$outdir"
xcc=${XCC:-xcc}
WIDGETS="button checkbox radio label field slider stepper progress segmented popup"
WIDGETS2="breadcrumb combobox datepicker groupbox collection table outline split scroll toolbar tabview nav colorpanel"
leg="${1:-all}"

# One screengrab per platform; the crops mirror showcase_widgets.xc's sheet
# grid EXACTLY (2 cols x 5 rows of 220x60, same order as $WIDGETS — ten cells,
# matching buildSheet()).
crop_sheet() {
  sheet="$1"; plat="$2"; i=0
  for w in $WIDGETS; do
    col=$((i % 2)); row=$((i / 2))
    python3 "$here/pngcrop.py" "$sheet" "$outdir/$w-$plat.png" $((col*220)) $((row*60)) 220 60 \
      && echo "  $plat  $w"
    i=$((i + 1))
  done
}

# Sheet 2 (containers + navigation): 2 cols x 7 rows of 220x90 — thirteen cells,
# matching buildSheet2()'s loop in showcase_widgets.xc. (This said 5 rows while
# the sheet held 12 widgets; the crop loop derives the row arithmetically so
# nothing was mis-cropped, but the comment sent you looking in the wrong place.)
crop_sheet2() {
  sheet="$1"; plat="$2"; i=0
  for w in $WIDGETS2; do
    col=$((i % 2)); row=$((i / 2))
    python3 "$here/pngcrop.py" "$sheet" "$outdir/$w-$plat.png" $((col*220)) $((row*90)) 220 90       && echo "  $plat  $w"
    i=$((i + 1))
  done
}

web_leg() {
  command -v node >/dev/null || { echo "== capture web: skipped (no node) =="; return; }
  CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  [ -x "$CHROME" ] || { echo "== capture web: skipped (no Chrome) =="; return; }
  work=$(mktemp -d)
  echo "== capture web: building the booth =="
  "$xcc" -A wasm32 -I "$ux" -I "$here" -o "$work/showcase_web" "$here/showcase_web.xc" -q 2>/dev/null
  cp "$work/showcase_web.wasm" "$work/showcase_web.js" "$work/" 2>/dev/null || true
  cp "$ux/ux_web_browser.js" "$here/page.html" "$work/"
  cp "$here/assets/aristo2.png" "$here/assets/aristo2-locations.txt" "$work/"
  # exec so $SRV IS the python pid (killing a subshell orphans its child —
  # a stale server kept answering the port with the previous build's wasm).
  pkill -f "http.server 8931" 2>/dev/null || true
  ( cd "$work" && exec python3 -m http.server 8931 ) >/dev/null 2>&1 &
  SRV=$!
  trap 'kill $SRV 2>/dev/null' EXIT
  sleep 1
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
      --screenshot="$outdir/sheet-web.png" --window-size=440,300 \
      --virtual-time-budget=5000 \
      "http://localhost:8931/page.html?v=$$" >/dev/null 2>&1
  kill $SRV 2>/dev/null; trap - EXIT
  crop_sheet "$outdir/sheet-web.png" web
}

ios_leg() {
  command -v xcrun >/dev/null || { echo "== capture ios: skipped (no xcrun) =="; return; }
  work=$(mktemp -d)
  echo "== capture ios: building the booth =="
  xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -fno-objc-msgsend-selector-stubs \
      -c "$ux/libUXIos.m" -o "$work/libUXIos.o"
  # One in-house link, as the iOS GATES do. The stopgap linked the MACOS
  # runtime, which has no _xt_ios_fetch/_free/_log now that the iOS runtime
  # lives in lib/xc/ios — so every capture failed at link with those three
  # undefined. compiler bugs 137-140 made -A ios-sim link in-house; use it.
  "$xcc" -A ios-sim -I "$ux" -I "$here" "$here/showcase_ios.xc" -Xlinker "$work/libUXIos.o" \
      -lobjc -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
      -o "$work/UXCapture" -q
  APP="$work/UXCapture.app"; mkdir "$APP"; cp "$work/UXCapture" "$APP/"
  cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.compile-xc.ux-capture</string>
  <key>CFBundleExecutable</key><string>UXCapture</string>
  <key>CFBundleName</key><string>UXCapture</string>
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
  out=$(xcrun simctl launch --console-pty "$UDID" com.compile-xc.ux-capture 2>&1) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture ios: FAILED =="; echo "$out" | tail -5; return 1; }
  # The simulator shares the host filesystem: the app's /tmp writes ARE /tmp.
  [ -f /tmp/ux-sheet.ppm ] || { echo "== capture ios: no sheet dump =="; return 1; }
  sips -s format png /tmp/ux-sheet.ppm --out "$outdir/sheet-ios.png" >/dev/null 2>&1
  crop_sheet "$outdir/sheet-ios.png" ios
}

android_leg() {
  A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  ADB="$A/platform-tools/adb"
  BT=$(ls -d "$A"/build-tools/* 2>/dev/null | sort -V | tail -1)
  NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
  PLATJAR=$(ls "$A"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)
  { [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== capture android: skipped (no SDK/NDK) =="; return; }
  "$ADB" get-state >/dev/null 2>&1 || { echo "== capture android: skipped (no device) =="; return; }
  work=$(mktemp -d)
  echo "== capture android: building the booth (two-lib APK) =="
  "$xcc" -A android --emit-apk -I "$ux" -I "$here" "$here/showcase_android.xc" -o "$work/xtapp.apk" -q 2>/dev/null
  mkdir -p "$work/lib/arm64-v8a"
  unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
  python3 "$ux/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so >/dev/null
  "$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
      "$ux/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"
  cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.uxcap">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="uxcap" android:debuggable="true">
    <activity android:name="android.app.NativeActivity" android:exported="true">
      <meta-data android:name="android.app.lib_name" android:value="UXAndroid"/>
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF
  "$BT/aapt2" link -I "$PLATJAR" --manifest "$work/AndroidManifest.xml" -o "$work/unaligned.apk"
  cp "$ux/tools/android/classes.dex" "$work/"
  ( cd "$work" && zip -q unaligned.apk classes.dex lib/arm64-v8a/libUXAndroid.so lib/arm64-v8a/libxtapp.so )
  "$BT/zipalign" -f 4 "$work/unaligned.apk" "$work/aligned.apk"
  KS="$ux/tools/android/debug.keystore"
  [ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass uxkit1 -alias ux \
      -dname "CN=uxkit" -keyalg RSA -validity 10000 2>/dev/null
  "$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 \
      --out "$work/uxcap.apk" "$work/aligned.apk" 2>/dev/null
  "$ADB" install -r "$work/uxcap.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxcap >/dev/null 2>&1
    "$ADB" install "$work/uxcap.apk" >/dev/null
  }
  "$ADB" logcat -c
  "$ADB" shell am start -n org.compile_xc.uxcap/android.app.NativeActivity >/dev/null 2>&1
  sleep 6
  "$ADB" logcat -d -s xcapp | grep -q "PASS: sheet shot" || { echo "== capture android: FAILED =="; "$ADB" logcat -d -s xcapp uxkit | tail -8; return 1; }
  # debuggable APK: run-as reaches the app's files dir
  "$ADB" exec-out run-as org.compile_xc.uxcap cat files/ux-sheet.ppm > "$work/sheet.ppm"
  [ -s "$work/sheet.ppm" ] || { echo "== capture android: no sheet dump =="; return 1; }
  # the dump is density-scaled; bring it back to the neutral 440x300 grid
  sips -s format png -z 300 440 "$work/sheet.ppm" --out "$outdir/sheet-android.png" >/dev/null 2>&1
  crop_sheet "$outdir/sheet-android.png" android
}

gtk_leg() {
  pkg-config --exists gtk4 2>/dev/null || { echo "== capture gtk: skipped (no gtk4) =="; return; }
  work=$(mktemp -d)
  echo "== capture gtk: building the booth =="
  cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$ux/libUXGtk.c" \
      $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
  "$xcc" -A arm64 -I "$ux" -I "$here" "$here/showcase_gtk.xc" \
      -Xlinker "$work/libUXGtk.dylib" -o "$work/showcase_gtk" -q 2>/dev/null
  out=$("$work/showcase_gtk" 2>&1 | grep -v Warning) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture gtk: FAILED =="; echo "$out" | tail -3; return 1; }
  [ -f /tmp/ux-sheet-gtk.ppm ] || { echo "== capture gtk: no sheet dump =="; return 1; }
  # GTK draws its own widgets (Adwaita), so this capture IS the Linux look.
  sips -s format png /tmp/ux-sheet-gtk.ppm --out "$outdir/sheet-linux.png" >/dev/null 2>&1
  crop_sheet "$outdir/sheet-linux.png" linux
}

mac_leg() {
  case "$(uname)" in Darwin) ;; *) echo "== capture mac: skipped (not macOS) =="; return ;; esac
  work=$(mktemp -d)
  echo "== capture mac: building the booth =="
  cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
      "$ux/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
  "$xcc" -A arm64 -I "$ux" -I "$here" "$here/showcase_mac.xc" \
      -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/showcase_mac" -q 2>/dev/null
  out=$("$work/showcase_mac" 2>&1 | grep -v Warning) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture mac: FAILED =="; echo "$out" | tail -3; return 1; }
  [ -f /tmp/ux-sheet-mac.ppm ] || { echo "== capture mac: no sheet dump =="; return 1; }
  sips -s format png /tmp/ux-sheet-mac.ppm --out "$outdir/sheet-macos.png" >/dev/null 2>&1
  crop_sheet "$outdir/sheet-macos.png" macos
}

win_leg() {
  command -v wine >/dev/null 2>&1 || { echo "== capture win: skipped (no wine) =="; return; }
  work=$(mktemp -d)
  echo "== capture win: building the booth for win64 =="
  "$xcc" -A win64 -I "$ux" -I "$here" "$here/showcase_win.xc" -o "$work/showcase_win.exe" -q 2>/dev/null
  out=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 60 wine showcase_win.exe 2>/dev/null) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture win: FAILED =="; echo "$out" | tail -3; return 1; }
  [ -f "$work/ux-sheet-win.ppm" ] || { echo "== capture win: no sheet dump =="; return 1; }
  sips -s format png "$work/ux-sheet-win.ppm" --out "$outdir/sheet-windows.png" >/dev/null 2>&1
  crop_sheet "$outdir/sheet-windows.png" windows
}

gem_leg() {
  case "$(uname)" in Darwin) ;; *) echo "== capture gem: skipped (not macOS) =="; return ;; esac
  export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
  [ -d "$UX_GEM_DIR" ] || { echo "== capture gem: skipped (no UX_GEM_DIR) =="; return; }
  echo "== capture gem: building host gemd + the booth =="
  bash "$ux/hostgem/build_gemd.sh" >/dev/null 2>&1 || { echo "== capture gem: gemd build failed =="; return 1; }
  "$xcc" -A arm64 -I "$ux" -I "$here" -L /tmp "$here/showcase_gem.xc" -o /tmp/ux_sheet_gem -q 2>/dev/null
  echo "== capture gem: gemd serve + the client, framebuffer dump =="
  /tmp/xg_hostgemd/host_gemd serve 5 >/tmp/hostgem_gemd.log 2>&1 & GPID=$!
  sleep 1.5
  UX_CLIENT=1 UX_GEM_DIR="$UX_GEM_DIR" DYLD_LIBRARY_PATH=/tmp timeout 9 /tmp/ux_sheet_gem >/tmp/hostgem_sheet.log 2>&1 & CPID=$!
  wait $GPID; kill $CPID 2>/dev/null
  grep -q "window up" /tmp/hostgem_sheet.log || { echo "== capture gem: FAILED (no window) =="; return 1; }
  # AES windows take WORK-AREA coords: the content sits exactly at the
  # requested (80,80); cut the sheet out of the 1280x720 desktop dump.
  sips -s format png /tmp/hostgem_fb.ppm --out /tmp/hostgem_fb.png >/dev/null 2>&1
  python3 "$here/pngcrop.py" /tmp/hostgem_fb.png "$outdir/sheet-gem.png" 80 80 440 300
  crop_sheet "$outdir/sheet-gem.png" gem
}

web_leg2() {
  command -v node >/dev/null || return
  CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  [ -x "$CHROME" ] || return
  work=$(mktemp -d)
  echo "== capture web (sheet 2) =="
  "$xcc" -A wasm32 -I "$ux" -I "$here" -o "$work/showcase_web" "$here/showcase_web2.xc" -q 2>/dev/null
  cp "$ux/ux_web_browser.js" "$here/page.html" "$work/"
  cp "$here/assets/aristo2.png" "$here/assets/aristo2-locations.txt" "$work/"
  pkill -f "http.server 8931" 2>/dev/null || true
  ( cd "$work" && exec python3 -m http.server 8931 ) >/dev/null 2>&1 &
  SRV=$!
  trap 'kill $SRV 2>/dev/null' EXIT
  sleep 1
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
      --screenshot="$outdir/sheet2-web.png" --window-size=440,630 \
      --virtual-time-budget=5000 \
      "http://localhost:8931/page.html?v=$$" >/dev/null 2>&1
  kill $SRV 2>/dev/null; trap - EXIT
  crop_sheet2 "$outdir/sheet2-web.png" web
}

ios_leg2() {
  command -v xcrun >/dev/null || return
  work=$(mktemp -d)
  echo "== capture ios (sheet 2) =="
  xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -fno-objc-msgsend-selector-stubs \
      -c "$ux/libUXIos.m" -o "$work/libUXIos.o"
  # One in-house link, as the iOS GATES do. The stopgap linked the MACOS
  # runtime, which has no _xt_ios_fetch/_free/_log now that the iOS runtime
  # lives in lib/xc/ios — so every capture failed at link with those three
  # undefined. compiler bugs 137-140 made -A ios-sim link in-house; use it.
  "$xcc" -A ios-sim -I "$ux" -I "$here" "$here/showcase_ios2.xc" -Xlinker "$work/libUXIos.o" \
      -lobjc -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
      -o "$work/UXCapture" -q
  APP="$work/UXCapture.app"; mkdir "$APP"; cp "$work/UXCapture" "$APP/"
  cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.compile-xc.ux-capture</string>
  <key>CFBundleExecutable</key><string>UXCapture</string>
  <key>CFBundleName</key><string>UXCapture</string>
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
  out=$(xcrun simctl launch --console-pty "$UDID" com.compile-xc.ux-capture 2>&1) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture ios 2: FAILED =="; echo "$out" | tail -3; return 1; }
  [ -f /tmp/ux-sheet2.ppm ] || { echo "== capture ios 2: no dump =="; return 1; }
  sips -s format png /tmp/ux-sheet2.ppm --out "$outdir/sheet2-ios.png" >/dev/null 2>&1
  crop_sheet2 "$outdir/sheet2-ios.png" ios
}

android_leg2() {
  A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  ADB="$A/platform-tools/adb"
  BT=$(ls -d "$A"/build-tools/* 2>/dev/null | sort -V | tail -1)
  NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
  PLATJAR=$(ls "$A"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)
  { [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || return
  "$ADB" get-state >/dev/null 2>&1 || return
  work=$(mktemp -d)
  echo "== capture android (sheet 2) =="
  "$xcc" -A android --emit-apk -I "$ux" -I "$here" "$here/showcase_android2.xc" -o "$work/xtapp.apk" -q 2>/dev/null
  mkdir -p "$work/lib/arm64-v8a"
  unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
  python3 "$ux/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so >/dev/null
  "$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
      "$ux/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"
  cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.uxcap">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="uxcap" android:debuggable="true">
    <activity android:name="android.app.NativeActivity" android:exported="true">
      <meta-data android:name="android.app.lib_name" android:value="UXAndroid"/>
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF
  "$BT/aapt2" link -I "$PLATJAR" --manifest "$work/AndroidManifest.xml" -o "$work/unaligned.apk"
  cp "$ux/tools/android/classes.dex" "$work/"
  ( cd "$work" && zip -q unaligned.apk classes.dex lib/arm64-v8a/libUXAndroid.so lib/arm64-v8a/libxtapp.so )
  "$BT/zipalign" -f 4 "$work/unaligned.apk" "$work/aligned.apk"
  KS="$ux/tools/android/debug.keystore"
  [ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass uxkit1 -alias ux \
      -dname "CN=uxkit" -keyalg RSA -validity 10000 2>/dev/null
  "$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 \
      --out "$work/uxcap.apk" "$work/aligned.apk" 2>/dev/null
  "$ADB" install -r "$work/uxcap.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxcap >/dev/null 2>&1
    "$ADB" install "$work/uxcap.apk" >/dev/null
  }
  "$ADB" logcat -c
  "$ADB" shell am start -n org.compile_xc.uxcap/android.app.NativeActivity >/dev/null 2>&1
  sleep 6
  "$ADB" logcat -d -s xcapp | grep -q "PASS: sheet shot" || { echo "== capture android 2: FAILED =="; "$ADB" logcat -d -s xcapp uxkit | tail -6; return 1; }
  "$ADB" exec-out run-as org.compile_xc.uxcap cat files/ux-sheet2.ppm > "$work/sheet2.ppm"
  [ -s "$work/sheet2.ppm" ] || { echo "== capture android 2: no dump =="; return 1; }
  sips -s format png -z 630 440 "$work/sheet2.ppm" --out "$outdir/sheet2-android.png" >/dev/null 2>&1
  crop_sheet2 "$outdir/sheet2-android.png" android
}

gtk_leg2() {
  pkg-config --exists gtk4 2>/dev/null || return
  work=$(mktemp -d)
  echo "== capture gtk (sheet 2) =="
  cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$ux/libUXGtk.c" \
      $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
  "$xcc" -A arm64 -I "$ux" -I "$here" "$here/showcase_gtk2.xc" \
      -Xlinker "$work/libUXGtk.dylib" -o "$work/showcase_gtk2" -q 2>/dev/null
  out=$("$work/showcase_gtk2" 2>&1 | grep -v Warning) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture gtk 2: FAILED =="; echo "$out" | tail -3; return 1; }
  sips -s format png /tmp/ux-sheet2-gtk.ppm --out "$outdir/sheet2-linux.png" >/dev/null 2>&1
  crop_sheet2 "$outdir/sheet2-linux.png" linux
}

mac_leg2() {
  case "$(uname)" in Darwin) ;; *) return ;; esac
  work=$(mktemp -d)
  echo "== capture mac (sheet 2) =="
  cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
      "$ux/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
  "$xcc" -A arm64 -I "$ux" -I "$here" "$here/showcase_mac2.xc" \
      -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/showcase_mac2" -q 2>/dev/null
  out=$("$work/showcase_mac2" 2>&1 | grep -v Warning) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture mac 2: FAILED =="; echo "$out" | tail -3; return 1; }
  sips -s format png /tmp/ux-sheet2-mac.ppm --out "$outdir/sheet2-macos.png" >/dev/null 2>&1
  crop_sheet2 "$outdir/sheet2-macos.png" macos
}

win_leg2() {
  command -v wine >/dev/null 2>&1 || return
  work=$(mktemp -d)
  echo "== capture win (sheet 2) =="
  "$xcc" -A win64 -I "$ux" -I "$here" "$here/showcase_win2.xc" -o "$work/showcase_win2.exe" -q 2>/dev/null
  out=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 60 wine showcase_win2.exe 2>/dev/null) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture win 2: FAILED =="; echo "$out" | tail -3; return 1; }
  [ -f "$work/ux-sheet2-win.ppm" ] || { echo "== capture win 2: no dump =="; return 1; }
  sips -s format png "$work/ux-sheet2-win.ppm" --out "$outdir/sheet2-windows.png" >/dev/null 2>&1
  crop_sheet2 "$outdir/sheet2-windows.png" windows
}

gem_leg2() {
  case "$(uname)" in Darwin) ;; *) return ;; esac
  export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
  [ -d "$UX_GEM_DIR" ] || return
  echo "== capture gem (sheet 2) =="
  bash "$ux/hostgem/build_gemd.sh" >/dev/null 2>&1 || return 1
  "$xcc" -A arm64 -I "$ux" -I "$here" -L /tmp "$here/showcase_gem2.xc" -o /tmp/ux_sheet2_gem -q 2>/dev/null
  /tmp/xg_hostgemd/host_gemd serve 5 >/tmp/hostgem_gemd.log 2>&1 & GPID=$!
  sleep 1.5
  UX_CLIENT=1 UX_GEM_DIR="$UX_GEM_DIR" DYLD_LIBRARY_PATH=/tmp timeout 9 /tmp/ux_sheet2_gem >/tmp/hostgem_sheet.log 2>&1 & CPID=$!
  wait $GPID; kill $CPID 2>/dev/null
  grep -q "window up" /tmp/hostgem_sheet.log || { echo "== capture gem 2: FAILED =="; return 1; }
  sips -s format png /tmp/hostgem_fb.ppm --out /tmp/hostgem_fb.png >/dev/null 2>&1
  python3 "$here/pngcrop.py" /tmp/hostgem_fb.png "$outdir/sheet2-gem.png" 80 80 440 630
  crop_sheet2 "$outdir/sheet2-gem.png" gem
}

# ---- the modal portraits: alerts, file choosers, the real NSToolbar ---------
# Only the platforms whose modal surface EXISTS are photographed: gem
# (form_alert + the toolkit panel), mac (NSAlert laid out headless + a real
# NSToolbar's theme frame), win (the driver's MessageBox + the toolkit panel
# under Wine).  gtk/ios/android alertRun are stubs and the pickers elsewhere
# are OS services a headless dump can't see — their docs tabs say so instead.
stage_fp_demo() {
  mkdir -p /tmp/ux_fp_demo/Projects /tmp/ux_fp_demo/Notes
  touch /tmp/ux_fp_demo/README.md /tmp/ux_fp_demo/rocks.xc /tmp/ux_fp_demo/theme.png /tmp/ux_fp_demo/build.sh
}

modal_gem() {
  case "$(uname)" in Darwin) ;; *) return ;; esac
  export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
  [ -d "$UX_GEM_DIR" ] || return
  stage_fp_demo
  echo "== capture gem (modals) =="
  bash "$ux/hostgem/build_gemd.sh" >/dev/null 2>&1 || { echo "== capture gem modals: gemd build failed =="; return 1; }
  for booth in alert_gem fp_gem; do
    "$xcc" -A arm64 -I "$ux" -I "$here" -L /tmp "$here/showcase_$booth.xc" -o "/tmp/ux_$booth" -q 2>/dev/null
    /tmp/xg_hostgemd/host_gemd serve 5 >/tmp/hostgem_gemd.log 2>&1 & GPID=$!
    sleep 1.5
    UX_CLIENT=1 UX_GEM_DIR="$UX_GEM_DIR" DYLD_LIBRARY_PATH=/tmp timeout 9 "/tmp/ux_$booth" >/tmp/hostgem_modal.log 2>&1 & CPID=$!
    wait $GPID; kill $CPID 2>/dev/null
    grep -q "window up" /tmp/hostgem_modal.log || { echo "== capture gem modals: FAILED ($booth) =="; return 1; }
    sips -s format png /tmp/hostgem_fb.ppm --out /tmp/hostgem_fb.png >/dev/null 2>&1
    case $booth in
      alert_gem) python3 "$here/pngcrop.py" /tmp/hostgem_fb.png "$outdir/alert-gem.png" 486 300 304 144 && echo "  gem  alert" ;;
      fp_gem)    python3 "$here/pngcrop.py" /tmp/hostgem_fb.png "$outdir/filechooser-gem.png" 130 46 464 370 && echo "  gem  filechooser" ;;
    esac
  done
}

modal_mac() {
  case "$(uname)" in Darwin) ;; *) return ;; esac
  work=$(mktemp -d)
  echo "== capture mac (modals) =="
  cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
      "$ux/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
  "$xcc" -A arm64 -I "$ux" -I "$here" "$here/showcase_modal_mac.xc" \
      -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/showcase_modal_mac" -q 2>/dev/null
  out=$("$work/showcase_modal_mac" 2>&1 | grep -v Warning) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture mac modals: FAILED =="; echo "$out" | tail -3; return 1; }
  sips -s format png /tmp/ux-alert-mac.ppm --out "$outdir/alert-macos.png" >/dev/null 2>&1 && echo "  mac  alert"
  # the REAL NSToolbar: the theme frame's top band (titlebar + toolbar)
  sips -s format png /tmp/ux-toolbar-mac.ppm --out /tmp/ux-toolbar-mac.png >/dev/null 2>&1
  python3 "$here/pngcrop.py" /tmp/ux-toolbar-mac.png "$outdir/toolbar-macos.png" 0 0 440 64 && echo "  mac  toolbar (real NSToolbar)"
}

modal_ios() {
  command -v xcrun >/dev/null || return
  xcrun simctl list devices available 2>/dev/null | grep -q "iPhone" || return
  work=$(mktemp -d)
  echo "== capture ios (modals) =="
  xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -fno-objc-msgsend-selector-stubs \
      -c "$ux/libUXIos.m" -o "$work/libUXIos.o"
  # One in-house link, as the iOS GATES do. The stopgap linked the MACOS
  # runtime, which has no _xt_ios_fetch/_free/_log now that the iOS runtime
  # lives in lib/xc/ios — so every capture failed at link with those three
  # undefined. compiler bugs 137-140 made -A ios-sim link in-house; use it.
  "$xcc" -A ios-sim -I "$ux" -I "$here" "$here/showcase_alert_ios.xc" -Xlinker "$work/libUXIos.o" \
      -lobjc -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
      -o "$work/UXModalCap" -q
  APP="$work/UXModalCap.app"; mkdir "$APP"; cp "$work/UXModalCap" "$APP/"
  cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.compile-xc.ux-modalcap</string>
  <key>CFBundleExecutable</key><string>UXModalCap</string>
  <key>CFBundleName</key><string>UXModalCap</string>
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
  out=$(xcrun simctl launch --console-pty "$UDID" com.compile-xc.ux-modalcap 2>&1) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture ios modals: FAILED =="; echo "$out" | tail -5; return 1; }
  [ -f /tmp/ux-alert-ios.ppm ] || { echo "== capture ios modals: no dump =="; return 1; }
  sips -s format png /tmp/ux-alert-ios.ppm --out "$outdir/alert-ios.png" >/dev/null 2>&1 && echo "  ios  alert"
}

modal_android() {
  A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  ADB="$A/platform-tools/adb"
  BT=$(ls -d "$A"/build-tools/* 2>/dev/null | sort -V | tail -1)
  NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
  PLATJAR=$(ls "$A"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)
  { [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || return
  "$ADB" get-state >/dev/null 2>&1 || return
  work=$(mktemp -d)
  echo "== capture android (modals) =="
  "$xcc" -A android --emit-apk -I "$ux" -I "$here" "$here/showcase_alert_android.xc" -o "$work/xtapp.apk" -q 2>/dev/null
  mkdir -p "$work/lib/arm64-v8a"
  unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
  python3 "$ux/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so >/dev/null
  "$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
      "$ux/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"
  cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.uxmodal">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="uxmodal" android:debuggable="true">
    <activity android:name="android.app.NativeActivity" android:exported="true">
      <meta-data android:name="android.app.lib_name" android:value="UXAndroid"/>
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF
  "$BT/aapt2" link -I "$PLATJAR" --manifest "$work/AndroidManifest.xml" -o "$work/unaligned.apk"
  cp "$ux/tools/android/classes.dex" "$work/"
  ( cd "$work" && zip -q unaligned.apk classes.dex lib/arm64-v8a/libUXAndroid.so lib/arm64-v8a/libxtapp.so )
  "$BT/zipalign" -f 4 "$work/unaligned.apk" "$work/aligned.apk"
  KS="$ux/tools/android/debug.keystore"
  [ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass uxkit1 -alias ux \
      -dname "CN=uxkit" -keyalg RSA -validity 10000 2>/dev/null
  "$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 \
      --out "$work/uxmodal.apk" "$work/aligned.apk" 2>/dev/null
  "$ADB" install -r "$work/uxmodal.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxmodal >/dev/null 2>&1
    "$ADB" install "$work/uxmodal.apk" >/dev/null
  }
  "$ADB" logcat -c
  "$ADB" shell am start -n org.compile_xc.uxmodal/android.app.NativeActivity >/dev/null 2>&1
  sleep 6
  "$ADB" logcat -d -s xcapp | grep -q "PASS: alert shot" || { echo "== capture android modals: FAILED =="; "$ADB" logcat -d -s xcapp uxkit | tail -8; return 1; }
  "$ADB" exec-out run-as org.compile_xc.uxmodal cat files/ux-alert.ppm > "$work/alert.ppm"
  [ -s "$work/alert.ppm" ] || { echo "== capture android modals: no dump =="; return 1; }
  # density-scaled decor: halve back toward the neutral grid (portrait width ~ its dp size)
  W=$(sed -n 2p "$work/alert.ppm" | cut -d' ' -f1); H=$(sed -n 2p "$work/alert.ppm" | cut -d' ' -f2)
  sips -s format png -z $((H/2)) $((W/2)) "$work/alert.ppm" --out "$outdir/alert-android.png" >/dev/null 2>&1 && echo "  android  alert"
}

modal_gtk() {
  pkg-config --exists gtk4 2>/dev/null || return
  work=$(mktemp -d)
  echo "== capture gtk (modals) =="
  cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$ux/libUXGtk.c" \
      $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
  "$xcc" -A arm64 -I "$ux" -I "$here" "$here/showcase_alert_gtk.xc" \
      -Xlinker "$work/libUXGtk.dylib" -o "$work/showcase_alert_gtk" -q 2>/dev/null
  out=$(timeout 60 "$work/showcase_alert_gtk" 2>&1 | grep -v Warning) || true
  echo "$out" | grep -q "^PASS" || { echo "== capture gtk modals: FAILED =="; echo "$out" | tail -3; return 1; }
  sips -s format png /tmp/ux-alert-gtk.ppm --out "$outdir/alert-linux.png" >/dev/null 2>&1 && echo "  gtk  alert"
}

modal_win() {
  command -v wine >/dev/null || { echo "== capture win modals: skipped (no wine) =="; return; }
  stage_fp_demo
  work=$(mktemp -d)
  echo "== capture win (modals) =="
  for booth in alert_win fp_win; do
    "$xcc" -A win64 -I "$ux" -I "$here" "$here/showcase_$booth.xc" -o "$work/showcase_$booth.exe" -q 2>/dev/null
    out=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 60 wine "showcase_$booth.exe" 2>/dev/null) || true
    echo "$out" | grep -q "^PASS" || { echo "== capture win modals: FAILED ($booth) =="; echo "$out" | tail -3; return 1; }
  done
  sips -s format png "$work/ux-alert-win.ppm" --out "$outdir/alert-windows.png" >/dev/null 2>&1 && echo "  win  alert"
  sips -s format png "$work/ux-fp-win.ppm" --out "$outdir/filechooser-windows.png" >/dev/null 2>&1 && echo "  win  filechooser"
}

[ "$leg" = web ] || [ "$leg" = all ] && { web_leg; web_leg2; }
[ "$leg" = ios ] || [ "$leg" = all ] && { ios_leg; ios_leg2; }
[ "$leg" = android ] || [ "$leg" = all ] && { android_leg; android_leg2; }
[ "$leg" = gtk ] || [ "$leg" = all ] && { gtk_leg; gtk_leg2; }
[ "$leg" = mac ] || [ "$leg" = all ] && { mac_leg; mac_leg2; }
[ "$leg" = win ] || [ "$leg" = all ] && { win_leg; win_leg2; }
[ "$leg" = gem ] || [ "$leg" = all ] && { gem_leg; gem_leg2; }
[ "$leg" = modals ] || [ "$leg" = all ] && { modal_gem; modal_mac; modal_ios; modal_android; modal_gtk; modal_win; }
echo "== capture: done -> $outdir =="
