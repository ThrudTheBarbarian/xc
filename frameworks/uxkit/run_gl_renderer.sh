#!/bin/sh
# run_gl_renderer.sh — the gl-renderer gates: test_gl_renderer.xc, a GL 3.2-core renderer written
# against UXGL.xc, one source, on AppKit and GTK (-framework OpenGL), the web (WebGL2 in headless
# Chrome), the Linux host (-lGL) and win64 (UXGL's forwarders; Wine on macOS offers only GL 2.1, so
# that leg reports a skip -- real Windows is checked by hand).  Each leg skips when its platform is
# absent.
set -u
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
leg() { # name, output
  echo "$2" | grep -a '^  (\|^PASS\|^FAIL\|^SKIP' | sed "s/^/  [$1] /"
  if echo "$2" | grep -aq '^PASS'; then echo "== gl-renderer-$1: OK =="
  elif echo "$2" | grep -aq '^SKIP'; then echo "== gl-renderer-$1: skipped =="
  else echo "== gl-renderer-$1: FAILED =="; fails=1; fi
}
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
   "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_gl_renderer.xc" -Xlinker "$work/libUXAppKit.dylib" \
   -framework Cocoa -framework OpenGL -o "$work/r_appkit" -q 2>/dev/null
leg appkit "$(timeout 60 "$work/r_appkit" 2>&1)"
if pkg-config --exists gtk4 2>/dev/null; then
  cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
  "$xcc" -A arm64 -D UX_GTK -I "$here" "$here/test_gl_renderer.xc" -Xlinker "$work/libUXGtk.dylib" -framework OpenGL -o "$work/r_gtk" -q 2>/dev/null
  leg gtk "$(timeout 60 "$work/r_gtk" 2>&1)"
fi
if command -v wine >/dev/null 2>&1; then
  "$xcc" -A win64 -I "$here" "$here/test_gl_renderer.xc" -o "$work/r.exe" -q 2>/dev/null
  leg win64 "$(WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d" timeout 60 wine "$work/r.exe" 2>/dev/null)"
fi
leg linux "$(UX_LINUX_LIBS=-lGL sh "$here/run_gtk_linux.sh" test_gl_renderer 2>&1 | sed 's/^== gtk-linux: skipped.*/SKIP: no Linux host/')"
# the web: the page runs the worker build and posts what it printed
wxcc=${XCC_WORKER:-"$here/../../compiler/bin/osx/xcc-xc"}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ] && [ -x "$wxcc" ]; then
  case "$wxcc" in "$here/../../compiler/"*) export XCC_HOME=${XCC_HOME:-"$(cd "$here/../../compiler" && pwd)"} ;; esac
  mkdir "$work/web"
  "$wxcc" -A wasm32 -I "$here" -o "$work/web/test_gl_renderer" "$here/test_gl_renderer.xc" -q 2>/dev/null
  cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$here/tools/web_gl_renderer.html" "$work/web/"
  port=8971
  ( cd "$work/web" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 & SRV=$!
  sleep 1
  ( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/web_gl_renderer.html?v=$$" >/dev/null 2>&1 & )
  for i in $(seq 1 40); do [ -f "$work/web/result.txt" ] && break; sleep 1; done
  leg web "$(cat "$work/web/result.txt" 2>/dev/null || echo 'FAIL: no result from the page')"
  kill $SRV 2>/dev/null; pkill -f "user-data-dir=$work/chrome" 2>/dev/null; sleep 1
fi
exit $fails
