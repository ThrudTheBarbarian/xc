#!/bin/sh
# make gtk-settings — UXKeyValueStore over GKeyFiles in XDG config, written by
# one process, read by the next.  UX_GTK_SETTINGS_DIR points the store at a
# temp dir, so the run leaves nothing behind in the user's real config.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
pkg-config --exists gtk4 2>/dev/null || { echo "== gtk-settings: skipped (no gtk4) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export UX_GTK_SETTINGS_DIR="$work/settings"

echo "== gtk-settings: building the shim + the test =="
cc -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
    $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_gtk_settings.xc" \
    -Xlinker "$work/libUXGtk.dylib" -o "$work/gtk_settings" -q 2>/dev/null

echo "== gtk-settings: pass 1 (write) =="
UX_SETTINGS_PASS=write "$work/gtk_settings" 2>&1 | sed 's/^/  /'

echo "== the keyfiles, as the store keeps them =="
for f in "$UX_GTK_SETTINGS_DIR"/*.conf; do
    [ -f "$f" ] && { echo "  -- $(basename "$f")"; sed 's/^/     /' "$f"; }
done

echo "== gtk-settings: pass 2 (a fresh process reads it back) =="
got=$(UX_SETTINGS_PASS=read "$work/gtk_settings" 2>&1)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: settings persist in the keyfile store$'; then
    echo "== gtk-settings: PASS — preferences live in XDG keyfiles =="
else
    echo "== gtk-settings: FAIL =="; exit 1
fi
