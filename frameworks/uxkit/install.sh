#!/bin/sh
# install.sh — build libUXKit for each target and install it in the third-party tree, so a program
# outside this tree is `xcc -A <target> app.xc` with `#use <UXKit>` and nothing else:
#
#     <3p>/uxkit/<target>/libUXKit-<major>-<minor>.<ext>   the library
#     <3p>/uxkit/<target>/libUXKit.<ext>                   -> the versioned one
#     <3p>/uxkit/xc/UXAbi.xc, UXVersion.xc                 the version contract a client imports
#
# <3p> is XCC_3P if set, else the 3p directory beside the installed xcc (/opt/xcc/3p for
# /opt/xcc/<version>).  The library for a target is the toolkit with that target's driver
# (UXPlatform):
#
#     arm64    AppKit, with its Objective-C shim (libUXAppKit.m) built here and bundled in
#     win64    Win32
#     wasm32   the web: libUXKit.wasm and its .json, with the page scripts a web app ships beside
#              them (ux_web_browser.js, ux_web_page.js)
#     ios-sim  UIKit, with its shim bundled in, against the simulator's SDK
#     android  Android: libUXKit.so needs the NDK-built shim libUXAndroid.so (installed beside it)
#              and the bridge's classes.dex, which the APK carries too
#
# arm9 (GEM) is built and deployed by `make libUXKit.so ARCH=arm9`, which needs the GEM loader
# checkout.  Usage: sh install.sh [target ...]   (default: arm64 win64 wasm32 ios-sim android)
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
home=$(cd "$(dirname "$(command -v "$xcc")")/.." && pwd)
dest=${XCC_3P:-$home/../3p}/uxkit
maj=$(sed -n 's/^#define UXK_MAJOR[[:space:]]*//p' "$here/UXVersion.xc")
min=$(sed -n 's/^#define UXK_MINOR[[:space:]]*//p' "$here/UXVersion.xc")
targets=${*:-arm64 win64 wasm32 ios-sim android}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$dest/xc"
cp "$here/UXAbi.xc" "$here/UXVersion.xc" "$dest/xc/"

for t in $targets; do
  case $t in
    arm64)
      cc -fobjc-arc -fno-objc-msgsend-selector-stubs -O2 -c "$here/libUXAppKit.m" -o "$work/uxappkit.o"
      ar rcs "$work/libUXAppKitShim.a" "$work/uxappkit.o"
      "$xcc" -A arm64 --emit-lib -I "$here" "$here/UXKit.xc" -o "$work/libUXKit.dylib" -Wl,"$work/libUXAppKitShim.a"
      ext=dylib ;;
    win64)
      "$xcc" -A win64 --emit-lib -I "$here" "$here/UXKit.xc" -o "$work/libUXKit.dll"
      ext=dll ;;
    wasm32)
      "$xcc" -A wasm32 --emit-lib -I "$here" "$here/UXKit.xc" -o "$work/libUXKit.wasm"
      mkdir -p "$dest/$t"
      cp "$work/libUXKit.json" "$here/ux_web_browser.js" "$here/ux_web_page.js" "$dest/$t/"
      ext=wasm ;;
    ios-sim)
      sdk=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null) || { echo "install: no iOS simulator SDK; skipped $t"; continue; }
      xcrun -sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -fno-objc-msgsend-selector-stubs \
          -O2 -c "$here/libUXIos.m" -o "$work/uxios.o"
      ar rcs "$work/libUXIosShim.a" "$work/uxios.o"
      SDKROOT=$sdk "$xcc" -A ios-sim --emit-lib -I "$here" "$here/UXKit.xc" -o "$work/libUXKit.dylib" -Wl,"$work/libUXIosShim.a"
      ext=dylib ;;
    android)
      ndk=$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
      [ -n "$ndk" ] || { echo "install: no Android NDK; skipped $t"; continue; }
      "$ndk/aarch64-linux-android26-clang" -shared -fPIC -O2 -Wl,-soname,libUXAndroid.so "$here/libUXAndroid.c" \
          -llog -landroid -o "$work/libUXAndroid.so"
      "$xcc" -A android --emit-lib -I "$here" "$here/UXKit.xc" --needed libUXAndroid.so -o "$work/libUXKit.so"
      mkdir -p "$dest/$t"
      cp "$work/libUXAndroid.so" "$here/tools/android/classes.dex" "$dest/$t/"
      ext=so ;;
    *) echo "install: no recipe for $t yet"; continue ;;
  esac
  mkdir -p "$dest/$t"
  cp "$work/libUXKit.$ext" "$dest/$t/libUXKit-$maj-$min.$ext"
  ln -sf "libUXKit-$maj-$min.$ext" "$dest/$t/libUXKit.$ext"
  echo "installed: $dest/$t/libUXKit.$ext -> libUXKit-$maj-$min.$ext"
done
echo "done. a client:  #use <UXKit>  ...  app.setDriver(UXPlatform.driver());"
