#!/bin/sh
# run_installed_client.sh -- the `installed-client` gate: a program outside this tree, built against
# the INSTALLED UXKit (install.sh) the way an external project builds it: `#use <UXKit>` and
# `xcc -A <target> app.xc`, with no -I, no shim and no link flags.  It opens a window through
# UXPlatform and prints PASS.  arm64 runs here (headless), win64 under Wine (hidden, with
# libUXKit.dll beside the exe).  A target whose library is not installed is skipped.
set -e
here=$(cd "$(dirname "$0")" && pwd)
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
    app.setDriver(UXPlatform.driver());
    app.setHeadless(true);
    app.setDelegate(new App());
    app.run();
    }
XC
fail=0
for t in arm64 win64; do
  case $t in arm64) lib=libUXKit.dylib; out=app ;; win64) lib=libUXKit.dll; out=app.exe ;; esac
  if [ ! -e "$tp/uxkit/$t/$lib" ]; then echo "  $t: skipped (no $tp/uxkit/$t/$lib)"; continue; fi
  ( cd "$work" && "$xcc" -A $t app.xc -o "$out" -q ) || { echo "  $t: FAIL (build)"; fail=1; continue; }
  case $t in
    arm64) got=$(cd "$work" && timeout 60 "./$out" 2>&1) || true ;;
    win64)
      command -v wine >/dev/null 2>&1 || { echo "  $t: skipped (no wine)"; continue; }
      cp "$tp/uxkit/$t/$lib" "$work/"
      got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d" timeout 120 wine "$out" 2>/dev/null) || true ;;
  esac
  if printf '%s\n' "$got" | grep -q '^PASS'; then echo "  $t: $(printf '%s\n' "$got" | grep '^PASS')"; else echo "  $t: FAIL"; printf '%s\n' "$got" | tail -3; fail=1; fi
done
[ $fail = 0 ] || { echo "== installed-client: FAILED =="; exit 1; }
echo "== installed-client: OK =="
