#!/bin/sh
# run_metrics_audit.sh <backend> -- the `metrics-audit` gate: test_metrics_audit.xc on one backend
# (appkit, win32, gtk, web or gem), each stock control at its UXMetrics height checked for drawing
# inside its frame and centred in it.  The backend's known failures are listed in
# expected_metrics_audit.txt; the gate fails on any other failure and names each known one that now
# passes, so the list shrinks as the drivers are fixed.  Skips when the backend cannot run here.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
backend=${1:-appkit}
name="metrics-audit-$backend"
work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
skip() { echo "== $name: skipped ($1) =="; exit 0; }

case "$backend" in
appkit)
    case "$(uname)" in Darwin) ;; *) skip "not macOS" ;; esac
    cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" \
        -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
    "$xcc" -A arm64 -I "$here" -D SNAP_APPKIT "$here/test_metrics_audit.xc" \
        -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/audit" -q 2>/dev/null
    timeout 60 "$work/audit" >"$work/out.txt" 2>&1 || true
    ;;
win32)
    command -v wine >/dev/null 2>&1 || skip "wine absent"
    "$xcc" -A win64 -I "$here" -D SNAP_WIN32 -o "$work/audit.exe" "$here/test_metrics_audit.xc" -q 2>/dev/null
    (cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 60 wine audit.exe >"$work/out.txt" 2>/dev/null) || true
    ;;
gtk)
    # on the Linux host (UX_LINUX_HOST / XTC_LINUX_HOST), through the gtk-linux runner
    UX_LINUX_XCFLAGS="-D SNAP_GTK" sh "$here/run_gtk_linux.sh" test_metrics_audit >"$work/out.txt" 2>&1 || true
    grep -q 'gtk-linux: skipped' "$work/out.txt" && skip "no Linux host with GTK 4"
    ;;
web)
    CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    [ -x "$CHROME" ] || skip "no Chrome"
    "$xcc" -A wasm32 -I "$here" -D SNAP_WEB -o "$work/audit" "$here/test_metrics_audit.xc" -q 2>/dev/null
    grep -q xccPost "$work/audit.js" || skip "this compiler's loader has no xccPost"
    cp "$here/ux_web_browser.js" "$here/ux_web_page.js" "$work/"
    sed -e 's/width="480" height="320"/width="640" height="400"/' -e 's/test_snapshot\.js/audit.js/' \
        "$here/tools/web_snapshot.html" >"$work/page.html"
    port=8969
    ( cd "$work" && exec python3 "$here/tools/coi_server.py" $port ) >/dev/null 2>&1 &
    srv=$!
    cleanup() { kill $srv 2>/dev/null; wait $srv 2>/dev/null || true; pkill -f "user-data-dir=$work/chrome" 2>/dev/null || true; sleep 1; rm -rf "$work" 2>/dev/null; }
    sleep 1
    ( "$CHROME" --headless=new --user-data-dir="$work/chrome" "http://localhost:$port/page.html?v=$$" >/dev/null 2>&1 & )
    for i in $(seq 1 40); do [ -f "$work/result.txt" ] && break; sleep 1; done
    cp "$work/result.txt" "$work/out.txt" 2>/dev/null || echo "FAIL: no result from the page" >"$work/out.txt"
    ;;
gem)
    # a client of a host gemd, as hostgem/run_snapshot.sh
    export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
    [ -d "$UX_GEM_DIR" ] || skip "no GEM tree; set GEM_DIR"
    printf 'DELAY 4000\n' >/tmp/hostgem_script.txt
    bash "$here/hostgem/build_gemd.sh" >/dev/null 2>&1 || { echo "== $name: FAILED (gemd build) =="; exit 1; }
    "$xcc" -A arm64 -I "$here" -L /tmp -D SNAP_GEM "$here/test_metrics_audit.xc" -o "$work/audit" -q 2>/dev/null
    /tmp/xg_hostgemd/host_gemd script 3 >"$work/gemd.log" 2>&1 &
    gpid=$!
    sleep 1.5
    UX_CLIENT=1 DYLD_LIBRARY_PATH=/tmp timeout 15 "$work/audit" >"$work/out.txt" 2>&1 || true
    kill $gpid 2>/dev/null; wait $gpid 2>/dev/null || true
    ;;
*)
    echo "usage: run_metrics_audit.sh appkit|win32|gtk|web|gem"; exit 2 ;;
esac

grep -a '^  ok  \|^  FAIL\|^PASS\|^FAIL' "$work/out.txt" || true
if ! grep -aq '^PASS: audit ran' "$work/out.txt"; then
    tail -20 "$work/out.txt"
    echo "== $name: FAILED (the audit did not run) =="
    exit 1
fi
grep -a '^  FAIL' "$work/out.txt" | awk '{print $2 " " $3}' | sort >"$work/got"
grep "^$backend " "$here/expected_metrics_audit.txt" | cut -d' ' -f2- | sort >"$work/want"
new=$(comm -23 "$work/got" "$work/want")
fixed=$(comm -13 "$work/got" "$work/want")
[ -n "$fixed" ] && printf 'now passing (remove from expected_metrics_audit.txt):\n%s\n' "$fixed"
if [ -n "$new" ]; then
    printf 'new failures:\n%s\n' "$new"
    echo "== $name: FAILED =="
    exit 1
fi
echo "== $name: OK ($(wc -l <"$work/want" | tr -d ' ') known failures) =="
