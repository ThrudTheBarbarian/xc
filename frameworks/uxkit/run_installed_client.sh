#!/bin/sh
# run_installed_client.sh -- the `installed-client` gate: a program outside this tree, built against
# the INSTALLED UXKit (install.sh) the way an external project builds it: `#use <UXKit>` and
# `xcc -A <target> app.xc`, with no -I, no shim and no link flags.  It opens a window through
# UXPlatform and prints PASS.  arm64 runs here (headless), win64 under Wine (hidden, with
# libUXKit.dll beside the exe), wasm32 in headless Chrome (with libUXKit.wasm and the page scripts
# beside app.js), x86_64 on the Linux host (UX_LINUX_HOST) under Xvfb, with libUXKit.so and
# libUXGtk.so beside it.  A target whose library is not installed, or whose runner is absent, is
# skipped.
set -e
here=$(cd "$(dirname "$0")" && pwd)
_root=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
lhost=${UX_LINUX_HOST:-${XTC_LINUX_HOST:-}}
xcc=${XCC:-xcc}
home=$(cd "$(dirname "$(command -v "$xcc")")/.." && pwd)
tp=${XCC_3P:-$home/../3p}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cat > "$work/app.xc" <<'XC'
#import <Stdio.xc>
#use <UXKit>
class App : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        UXView* content = new UXView();
        UXWindow* win = new UXWindow();
        win.open((u8*)"Installed", UXGeom.make((i16)100, (i16)100, (i16)240, (i16)120), content);
        app.addWindow(win);
        UXButton* b = new UXButton();
        b.setTitle((u8*)"OK");
        content.addSubview(b, UXGeom.make((i16)16, (i16)16, (i16)80, (i16)24));
        win.tree.finalise();
        win.displayAll();
        Stdio.printf("PASS: a window from the installed UXKit on %s\n", UXPlatform.displayName());
        app.stop();
        return (i32)0;
        }
    }
void main(void)
    {
    UXApplication* app = new UXApplication();
    app.setHeadless(true);
    app.setDelegate(new App());
    app.run();
    }
XC
fail=0
for t in arm64 win64 x86_64 wasm32; do
  case $t in arm64) lib=libUXKit.dylib; out=app ;; win64) lib=libUXKit.dll; out=app.exe ;;
             x86_64) lib=libUXKit.so; out=app.lin ;; wasm32) lib=libUXKit.wasm; out=app ;; esac
  if [ ! -e "$tp/uxkit/$t/$lib" ]; then echo "  $t: skipped (no $tp/uxkit/$t/$lib)"; continue; fi
  ( cd "$work" && "$xcc" -A $t app.xc -o "$out" -q ) || { echo "  $t: FAIL (build)"; fail=1; continue; }
  case $t in
    arm64) got=$(cd "$work" && timeout 60 "./$out" 2>&1) || true ;;
    win64)
      command -v wine >/dev/null 2>&1 || { echo "  $t: skipped (no wine)"; continue; }
      cp "$tp/uxkit/$t/$lib" "$work/"
      got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d" timeout 120 wine "$out" 2>/dev/null) || true ;;
    x86_64)
      [ -n "$lhost" ] || { echo "  $t: skipped (no UX_LINUX_HOST)"; continue; }
      rdir=$(ssh -o BatchMode=yes "$lhost" 'mktemp -d')
      scp -q "$work/$out" "$tp/uxkit/$t/libUXKit.so" "$tp/uxkit/$t/libUXGtk.so" "$lhost:$rdir/"
      got=$(timeout 120 ssh -o BatchMode=yes "$lhost" "cd $rdir && xvfb-run -a ./$out 2>&1; rm -rf $rdir") || true ;;
    wasm32)
      chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      [ -x "$chrome" ] || { echo "  $t: skipped (no Chrome)"; continue; }
      cp "$tp/uxkit/$t/libUXKit.wasm" "$tp/uxkit/$t/libUXKit.json" "$tp/uxkit/$t/ux_web_browser.js" \
         "$tp/uxkit/$t/ux_web_page.js" "$work/"
      cat > "$work/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<canvas id="ux-canvas" width="400" height="260"></canvas>
<script>
  globalThis.xccConfig = { runLoop: 'worker', workerScript: 'ux_web_browser.js', canvas: '#ux-canvas' };
  const out = [];
  globalThis.xccOut = (s) => { out.push(s); if (/^(PASS|FAIL)/.test(s)) fetch('/result', { method: 'POST', body: out.join('\n') }); };
  setTimeout(() => fetch('/result', { method: 'POST', body: 'TIMEOUT\n' + out.join('\n') }), 20000);
</script>
<script src="ux_web_page.js"></script>
<script src="app.js"></script>
HTML
      port=8983
      ( cd "$work" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 &
      srv=$!
      sleep 1
      ( "$chrome" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/index.html" >/dev/null 2>&1 & )
      for i in $(seq 1 30); do [ -f "$work/result.txt" ] && break; sleep 1; done
      got=$(cat "$work/result.txt" 2>/dev/null)
      kill $srv 2>/dev/null; wait $srv 2>/dev/null || true; pkill -f "user-data-dir=$work/chrome" 2>/dev/null || true ;;
  esac
  if printf '%s\n' "$got" | grep -q '^PASS'; then echo "  $t: $(printf '%s\n' "$got" | grep '^PASS')"; else echo "  $t: FAIL"; printf '%s\n' "$got" | tail -3; fail=1; fi
done
[ $fail = 0 ] || { echo "== installed-client: FAILED =="; exit 1; }
echo "== installed-client: OK =="
