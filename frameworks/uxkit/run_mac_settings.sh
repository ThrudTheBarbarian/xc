#!/bin/sh
# make mac-settings — UXKeyValueStore over NSUserDefaults, written by one process, read by the next.
#
# The suites are named xg.test.* and deleted afterwards, so the run leaves nothing behind in the
# user's real defaults.  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac-settings: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d)
cleanup() {
    for d in xg.test xg.test.ks xg.test.paint xg.test.other test_mac_settings; do
        defaults delete "$d" >/dev/null 2>&1 || true
    done
    rm -rf "$work"
}
trap cleanup EXIT

echo "== mac-settings: building the ObjC shim + the test for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_mac_settings.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_mac_settings" -q 2>/dev/null

# Start from nothing, so a stale suite from an earlier run cannot stand in for a working write.
for d in xg.test xg.test.ks xg.test.paint xg.test.other test_mac_settings; do
    defaults delete "$d" >/dev/null 2>&1 || true
done

echo "== mac-settings: pass 1 (write) =="
UX_SETTINGS_PASS=write "$work/test_mac_settings" 2>&1 | sed 's/^/  /'

echo "== the defaults, as macOS sees them =="
defaults read xg.test.ks 2>/dev/null | sed 's/^/  /' || echo "  (suite not readable)"

echo "== mac-settings: pass 2 (a fresh process reads it back) =="
got=$(UX_SETTINGS_PASS=read "$work/test_mac_settings" 2>&1)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: settings persist in NSUserDefaults$'; then
    echo "== mac-settings: PASS — preferences live in NSUserDefaults =="
else
    echo "== mac-settings: FAIL =="; exit 1
fi
