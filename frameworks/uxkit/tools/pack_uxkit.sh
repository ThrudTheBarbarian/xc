#!/bin/sh
# pack_uxkit.sh <version> [outdir] — the xcc-uxkit-<version>.tar.bz2 archive: the installed UXKit
# library (install.sh) for the targets an out-of-tree program can use today, with its version
# contract, UXKit's source and its licence.  Run install.sh with that version's xcc first.
#
#     xcc-uxkit-<version>/3p/uxkit/<target>/...   macOS (arm64), Windows (win64), Linux (x86_64),
#                                                 the web (wasm32), and xc/ (UXAbi.xc, UXVersion.xc)
#     xcc-uxkit-<version>/src/                    the UXKit sources the libraries are built from
#     xcc-uxkit-<version>/README, COPYING, COPYING.LESSER
set -e
ver=$1
[ -n "$ver" ] || { echo "usage: pack_uxkit.sh <version> [outdir]"; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
out=${2:-.}
src=${XCC_3P:-/opt/xcc/3p}/uxkit
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
top="$work/xcc-uxkit-$ver"
mkdir -p "$top/3p/uxkit" "$top/src"
for t in arm64 win64 x86_64 wasm32 xc; do
  [ -d "$src/$t" ] || { echo "pack_uxkit: $src/$t is not installed (run install.sh)"; exit 1; }
  cp -RP "$src/$t" "$top/3p/uxkit/"
done
( cd "$here" && git ls-files -- 'UX*.xc' 'lib*.m' 'lib*.c' '*.h' 'ux_web_*.js' install.sh \
      tools/build_libuxgtk.sh tools/android/UXBridge.java | tar cf - -T - ) | ( cd "$top/src" && tar xf - )
cp "$here/COPYING" "$here/COPYING.LESSER" "$top/"
cat > "$top/README" <<TXT
UXKit $ver — the UI toolkit for xc, as an installed library, for xcc $ver

Put 3p/ beside the versioned xcc install, so that /opt/xcc/3p/uxkit/ sits next to
/opt/xcc/$ver/:

    sudo cp -R 3p /opt/xcc/

A program then names UXKit once and builds with nothing else:

    #use <UXKit>
    ...
    UXApplication* app = new UXApplication();
    app.setDriver(UXPlatform.driver());     // the driver for the target it is built for

    xcc -A arm64  app.xc -o app            # macOS
    xcc -A win64  app.xc -o app.exe        # Windows: ship libUXKit.dll beside it
    xcc -A x86_64 app.xc -o app            # Linux: ship libUXKit.so and libUXGtk.so beside it;
                                            # the machine needs GTK 4
    xcc -A wasm32 app.xc -o app            # the web: ship libUXKit.wasm, libUXKit.json,
                                            # ux_web_page.js and ux_web_browser.js beside it

A program may check the library's version with UXAbi.xc (3p/uxkit/xc/).

UXKit is LGPLv3 (COPYING.LESSER, which builds on COPYING). Its source is in src/;
install.sh there rebuilds and installs the libraries.
TXT
tarball="$out/xcc-uxkit-$ver.tar.bz2"
( cd "$work" && tar cjf - "xcc-uxkit-$ver" ) > "$tarball"
echo "$tarball: $(wc -c < "$tarball" | tr -d ' ') bytes, sha256 $(shasum -a 256 "$tarball" | cut -d' ' -f1)"
