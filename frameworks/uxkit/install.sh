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
# (UXPlatform): AppKit for arm64, with its Objective-C shim (libUXAppKit.m) built here and bundled
# in; Win32 for win64.  arm9 (GEM) is built and deployed by `make libUXKit.so ARCH=arm9`, which
# needs the GEM loader checkout.  Usage: sh install.sh [target ...]   (default: arm64 win64)
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
home=$(cd "$(dirname "$(command -v "$xcc")")/.." && pwd)
dest=${XCC_3P:-$home/../3p}/uxkit
maj=$(sed -n 's/^#define UXK_MAJOR[[:space:]]*//p' "$here/UXVersion.xc")
min=$(sed -n 's/^#define UXK_MINOR[[:space:]]*//p' "$here/UXVersion.xc")
targets=${*:-arm64 win64}
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
    *) echo "install: no recipe for $t yet"; continue ;;
  esac
  mkdir -p "$dest/$t"
  cp "$work/libUXKit.$ext" "$dest/$t/libUXKit-$maj-$min.$ext"
  ln -sf "libUXKit-$maj-$min.$ext" "$dest/$t/libUXKit.$ext"
  echo "installed: $dest/$t/libUXKit.$ext -> libUXKit-$maj-$min.$ext"
done
echo "done. a client:  #use <UXKit>  ...  app.setDriver(UXPlatform.driver());"
