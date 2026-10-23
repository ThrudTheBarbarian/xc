#!/bin/sh
# run_posted.sh — the posted-work gate (`posted`): a worker thread posts to RunLoop.main() while the
# UI loop is idle, and every block runs on the UI thread, in order (test_posted.xc).  One leg per
# threaded desktop backend, each skipped when its platform is absent:
#
#   appkit   macOS, [NSApp run] (on UX_MAC_GUI_HOST when set)
#   gtk      GTK 4 on macOS (Homebrew)
#   linux    GTK 4 on Linux: linked here with -A x86_64 -dynamic, run on UX_LINUX_HOST under Xvfb
#   win32    win64 under Wine
#   ios      the iOS simulator (the platform owns the loop)
#   android  a device or emulator on adb (the platform owns the loop; main() runs on another thread)
#
#   sh run_posted.sh [appkit|gtk|linux|win32|ios|android]...     (default: all six)
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/tools/mac_run.sh" # ux_mac_run: here, or on UX_MAC_GUI_HOST
xcc=${XCC:-xcc}
legs=${*:-appkit gtk linux win32 ios android}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0

check() { # leg output
    printf '%s\n' "$2"
    if printf '%s\n' "$2" | grep -q '^PASS'; then
        echo "== posted ($1): PASS =="
    else
        echo "== posted ($1): FAIL =="
        fail=1
    fi
}

for leg in $legs; do
    case "$leg" in
    appkit)
        [ "$(uname)" = Darwin ] || { echo "== posted (appkit): skipped (not macOS) =="; continue; }
        cc -I "$here" -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
            "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
        "$xcc" -A arm64 -I "$here" "$here/test_posted.xc" -Xlinker "$work/libUXAppKit.dylib" \
            -framework Cocoa -framework OpenGL -o "$work/posted_appkit" -q 2>/dev/null
        check appkit "$(ux_mac_run -t 30 UX_AUTOQUIT=10000 "$work/posted_appkit" 2>/dev/null)"
        ;;
    gtk)
        pkg-config --exists gtk4 2>/dev/null || { echo "== posted (gtk): skipped (no gtk4) =="; continue; }
        [ "$(uname)" = Darwin ] || { echo "== posted (gtk): skipped (not macOS) =="; continue; }
        cc -I "$here" -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
            $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib" 2>/dev/null
        "$xcc" -A arm64 -D UX_POSTED_GTK -I "$here" "$here/test_posted.xc" \
            -Xlinker "$work/libUXGtk.dylib" -o "$work/posted_gtk" -q 2>/dev/null
        check gtk "$(ux_mac_run -t 30 UX_AUTOQUIT=10000 "$work/posted_gtk" 2>&1 | grep -v Warning)"
        ;;
    linux)
        host=${UX_LINUX_HOST:-${XTC_LINUX_HOST:-}}
        [ -n "$host" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" true 2>/dev/null \
            || { echo "== posted (linux): skipped (no Linux host) =="; continue; }
        sh "$here/tools/build_libuxgtk.sh" "$work/lib" --with-link-inputs >/dev/null
        "$xcc" -A x86_64 -dynamic -I "$here" "$here/test_posted.xc" -L "$work/lib" -lUXGtk -lgtk-4 \
            -o "$work/posted_linux" -q 2>/dev/null
        rdir=$(ssh -o BatchMode=yes "$host" 'mktemp -d')
        scp -q "$work/lib/libUXGtk.so" "$work/posted_linux" "$host:$rdir/"
        out=$(ssh -o BatchMode=yes "$host" "cd $rdir && LD_LIBRARY_PATH=$rdir UX_AUTOQUIT=10000 \
            timeout 40 xvfb-run -a ./posted_linux 2>&1 | grep -a '^posted:\|^PASS\|^FAIL'") || true
        ssh -o BatchMode=yes "$host" "rm -rf $rdir"
        check linux "$out"
        ;;
    win32)
        command -v wine >/dev/null 2>&1 || { echo "== posted (win32): skipped (wine absent) =="; continue; }
        "$xcc" -A win64 -I "$here" "$here/test_posted.xc" -o "$work/posted.exe" -q 2>/dev/null
        check win32 "$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" UX_AUTOQUIT=10000 \
            timeout 40 wine posted.exe 2>/dev/null | tr -d '\r')"
        ;;
    ios)
        { command -v xcrun >/dev/null && xcrun simctl list devices available 2>/dev/null | grep -q iPhone; } \
            || { echo "== posted (ios): skipped (no iPhone simulator) =="; continue; }
        xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc \
            -fno-objc-msgsend-selector-stubs -c "$here/libUXIos.m" -o "$work/libUXIos.o"
        app="$work/UXPosted.app"; mkdir "$app"
        "$xcc" -A ios-sim -I "$here" "$here/test_posted.xc" -Xlinker "$work/libUXIos.o" -lobjc -framework UIKit \
            -framework Foundation -framework QuartzCore -framework CoreGraphics -o "$app/UXPosted" -q 2>/dev/null
        cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.compile-xc.posted</string>
  <key>CFBundleExecutable</key><string>UXPosted</string>
  <key>CFBundleName</key><string>UXPosted</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>UILaunchScreen</key><dict/>
</dict>
</plist>
PLIST
        udid=$(xcrun simctl list devices available | grep -m1 "iPhone 16 Pro (" | grep -oE "[0-9A-F-]{36}")
        [ -n "$udid" ] || udid=$(xcrun simctl list devices available | grep -m1 "iPhone" | grep -oE "[0-9A-F-]{36}")
        xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" || true
        xcrun simctl bootstatus "$udid" >/dev/null
        xcrun simctl install "$udid" "$app"
        check ios "$(xcrun simctl launch --console-pty "$udid" com.compile-xc.posted 2>&1 | grep -a '^posted:\|^PASS\|^FAIL')"
        ;;
    android)
        A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
        adb="$A/platform-tools/adb"
        ndkbin=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
        { [ -n "$ndkbin" ] && [ -x "$adb" ] && "$adb" get-state >/dev/null 2>&1; } \
            || { echo "== posted (android): skipped (no SDK or device) =="; continue; }
        "$ndkbin/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
            "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
        "$xcc" -A android --emit-apk -I "$here" "$here/test_posted.xc" \
            --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
            --with-dex "$here/tools/android/classes.dex" -o "$work/uxposted.apk" -q 2>/dev/null
        pkg=org.compile_xc.uxposted # xcc names the package after the APK
        "$adb" install -r "$work/uxposted.apk" >/dev/null 2>&1 || {
            "$adb" uninstall "$pkg" >/dev/null 2>&1
            "$adb" install "$work/uxposted.apk" >/dev/null
        }
        "$adb" logcat -c
        "$adb" shell am start -S --activity-clear-task -n "$pkg/android.app.NativeActivity" >/dev/null 2>&1
        sleep 8
        check android "$("$adb" logcat -d -s xcapp uxkit | sed -E 's/^.* (xcapp|uxkit) *: //' | grep -a '^posted:\|^PASS\|^FAIL')"
        ;;
    *) echo "run_posted.sh: unknown leg $leg"; exit 2 ;;
    esac
done
exit $fail
