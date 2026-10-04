#!/bin/sh
# run_lifecycle.sh — the lifecycle gates (appkit-, gtk-, win32-lifecycle): test_lifecycle.xc, one
# source, built for each desktop backend and run three ways: app.stop() from the turn hook,
# UX_AUTOQUIT ending the loop by itself, and headless (UX_HEADLESS, setHeadless).  Each leg skips
# cleanly when its platform is absent.
#   sh run_lifecycle.sh [appkit|gtk|win32|all]
set -u
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
leg=${1:-all}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fails=0
three() { # name, then the command that runs the binary
  name=$1; shift
  f=0
  for mode in stop autoquit headless; do
    case $mode in
      stop)     out=$(env "$@" 2>&1) ;;
      autoquit) out=$(env UX_AUTOQUIT=1500 LIFECYCLE_NOSTOP=1 "$@" 2>&1) ;;
      headless) out=$(env UX_HEADLESS=1 "$@" 2>&1) ;;
    esac
    echo "$out" | grep -a '^  (\|^PASS\|^FAIL' | sed "s/^/  [$mode] /"
    echo "$out" | grep -aq '^PASS' || f=$((f + 1))
  done
  fails=$((fails + f))
  echo "== $name-lifecycle: $([ $f = 0 ] && echo OK || echo FAILED) =="
}
if [ "$leg" = all ] || [ "$leg" = appkit ]; then
  cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
     "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
  "$xcc" -A arm64 -I "$here" "$here/test_lifecycle.xc" -Xlinker "$work/libUXAppKit.dylib" \
     -framework Cocoa -framework OpenGL -o "$work/lc_appkit" -q 2>/dev/null
  three appkit timeout 30 "$work/lc_appkit"
fi
if [ "$leg" = all ] || [ "$leg" = gtk ]; then
  if pkg-config --exists gtk4 2>/dev/null; then
    cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
    "$xcc" -A arm64 -D UX_GTK -I "$here" "$here/test_lifecycle.xc" -Xlinker "$work/libUXGtk.dylib" -o "$work/lc_gtk" -q 2>/dev/null
    three gtk timeout 30 "$work/lc_gtk"
  else
    echo "== gtk-lifecycle: skipped (no gtk4) =="
  fi
fi
if [ "$leg" = all ] || [ "$leg" = win32 ]; then
  if command -v wine >/dev/null 2>&1; then
    "$xcc" -A win64 -I "$here" "$here/test_lifecycle.xc" -o "$work/lc.exe" -q 2>/dev/null
    three win32 WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d" timeout 60 wine "$work/lc.exe"
  else
    echo "== win32-lifecycle: skipped (no wine) =="
  fi
fi
[ $fails = 0 ] || exit 1
