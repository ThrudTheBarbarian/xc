#!/bin/sh
# pack_uxkit.sh <version> [outdir] — the xcc-uxkit-<version>.tar.bz2 archive: the installed UXKit
# library (install.sh) for the targets an out-of-tree program can use today, with its version
# contract, UXKit's source and its licence.  Run install.sh with that version's xcc first.
#
#     xcc-uxkit-<version>/3p/uxkit/<target>/...   macOS (arm64), Windows (win64), Linux (x86_64),
#                                                 the web (wasm32), the Pi 5 (linux-arm64) when
#                                                 installed, and xc/ (UXAbi.xc, UXVersion.xc)
#     xcc-uxkit-<version>/src/                    the UXKit sources the libraries are built from
#     xcc-uxkit-<version>/README, COPYING, COPYING.LESSER
set -e
ver=$1
[ -n "$ver" ] || { echo "usage: pack_uxkit.sh <version> [outdir]"; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
out=${2:-.}
xcc=${XCC:-xcc}
home=$(cd "$(dirname "$(command -v "$xcc")")/.." && pwd)
# The compiler's own third-party tree: XCC_3P, else what `xcc --print-3p-dir` names (0.90 on:
# <prefix>/3p), else the shared tree beside the install (0.89 and earlier, which lack the option).
tp=${XCC_3P:-}
[ -n "$tp" ] || tp=$("$xcc" --print-3p-dir 2>/dev/null) || tp=$home/../3p
src=$tp/uxkit
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
top="$work/xcc-uxkit-$ver"
mkdir -p "$top/3p/uxkit" "$top/src"
for t in arm64 win64 x86_64 wasm32 xc; do
  [ -d "$src/$t" ] || { echo "pack_uxkit: $src/$t is not installed (run install.sh)"; exit 1; }
  cp -RP "$src/$t" "$top/3p/uxkit/"
done
# The Raspberry Pi 5 (-A arm64-linux), when install.sh had a Pi to build its GTK shim on.
pi=0
if [ -d "$src/linux-arm64" ]; then cp -RP "$src/linux-arm64" "$top/3p/uxkit/"; pi=1; fi
( cd "$here" && git ls-files -- 'UX*.xc' 'lib*.m' 'lib*.c' '*.h' 'ux_web_*.js' install.sh \
      tools/build_libuxgtk.sh tools/android/UXBridge.java | tar cf - -T - ) | ( cd "$top/src" && tar xf - )
cp "$here/COPYING" "$here/COPYING.LESSER" "$top/"
# Where the README says to put it: xcc 0.90 and later search their own tree, earlier ones the shared one.
if "$xcc" --print-3p-dir >/dev/null 2>&1; then
  where="Put uxkit/ in xcc $ver's own third-party tree, /opt/xcc/$ver/3p (xcc --print-3p-dir prints it;
a compiler unpacked from its archive does not have the directory yet):

    d=\"\$(xcc --print-3p-dir)\"
    sudo mkdir -p \"\$d\" && sudo cp -R 3p/uxkit \"\$d/\""
else
  where="Put 3p/ beside the versioned xcc install, so that /opt/xcc/3p/uxkit/ sits next to
/opt/xcc/$ver/:

    sudo cp -R 3p /opt/xcc/"
fi
pinote=""
[ $pi = 1 ] && pinote="
    xcc -A arm64-linux app.xc -o app       # Raspberry Pi 5 (64-bit Pi OS): ship libUXKit.so,
                                            # libUXGtk.so and xcc's libRuntime.so beside it; the
                                            # Pi needs GTK 4"
cat > "$top/README" <<TXT
UXKit $ver — the UI toolkit for xc, as an installed library, for xcc $ver

$where

A program then names UXKit once and builds with nothing else:

    #use <UXKit>
    ...
    UXApplication* app = new UXApplication();

    xcc -A arm64  app.xc -o app            # macOS
    xcc -A win64  app.xc -o app.exe        # Windows: ship libUXKit.dll beside it
    xcc -A x86_64 app.xc -o app            # Linux: ship libUXKit.so and libUXGtk.so beside it
                                            # (and, from xcc 0.9.2, xcc's libRuntime.so); the
                                            # machine needs GTK 4$pinote
    xcc -A wasm32 app.xc -o app            # the web: ship libUXKit.wasm, libUXKit.json,
                                            # ux_web_page.js and ux_web_browser.js beside it

A program may check the library's version with UXAbi.xc (3p/uxkit/xc/).

UXKit is LGPLv3 (COPYING.LESSER, which builds on COPYING). Its source is in src/;
install.sh there rebuilds and installs the libraries.
TXT
tarball="$out/xcc-uxkit-$ver.tar.bz2"
( cd "$work" && tar cjf - "xcc-uxkit-$ver" ) > "$tarball"
echo "$tarball: $(wc -c < "$tarball" | tr -d ' ') bytes, sha256 $(shasum -a 256 "$tarball" | cut -d' ' -f1)"
