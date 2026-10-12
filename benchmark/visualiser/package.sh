#!/bin/sh
# package.sh <version> — the visualiser archives the benchmarks page offers,
# written to website/downloads/ (which the site deploy publishes):
#
#   xcc-benchviz-<version>-osx.tar.bz2     macOS, built here (run it on a Mac)
#   xcc-benchviz-<version>-linux.tar.bz2   Linux x86-64, with --linux: cross-linked
#                                          here, the GTK shim built on XTC_LINUX_HOST
#   xcc-benchviz-<version>-win64.zip       Windows x86-64, cross-built here
#   xcc-bench-sources-<version>.tar.bz2    the committed benchmark/ tree
#
# Each program archive carries what it loads beside it: libtls (the TLS
# library, for the corpus over https) and, on macOS and Linux, the toolkit's
# shim, with their licences. The programs find them through @loader_path
# (macOS), $ORIGIN (Linux) and the program's directory (Windows). The Windows
# toolkit is xc over Win32, so it has no shim.
#
# --linux needs XTC_LINUX_HOST (build.env), where the GTK shim is built.
#
#   sh package.sh 0.75 [--linux]
set -eu
ver=${1:?usage: package.sh <version> [--linux]}
linux=0
[ "${2:-}" = --linux ] && linux=1
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
[ -f "$root/tools/build-env.sh" ] && . "$root/tools/build-env.sh"
XCC=${XCC:-xcc}
UXKIT="$root/frameworks/uxkit"
TLS=${TLS_DIR:-/opt/xcc/3p/tls}
out="$root/website/downloads"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

common() {
    # $1: the archive's directory
    cp "$here/sample.json" "$1/"
    cp "$root/COPYING" "$1/COPYING"
    cp "$UXKIT/COPYING.LESSER" "$1/COPYING.LESSER"
    cp "$root/frameworks/3p/tls/LICENSE-mbedtls.txt" "$1/"
    sed "s/@VERSION@/$ver/g" "$here/README.dist" > "$1/README"
}

# ---- macOS ----
name="xcc-benchviz-$ver-osx"
d="$work/$name"
mkdir -p "$d"
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -Wno-deprecated-declarations -Wno-enum-conversion \
   -install_name "@rpath/libUXAppKit.dylib" "$UXKIT/libUXAppKit.m" \
   -framework Cocoa -framework OpenGL -o "$d/libUXAppKit.dylib"
# The shim is named by a relative path: xcc records an absolute one as is,
# and a relative one as @rpath/<name>, found beside the program.
( cd "$d" && "$XCC" -A arm64 -I "$UXKIT" -I "$here" -O2 "$here/Visualiser.xc" \
   -Xlinker libUXAppKit.dylib -framework Cocoa -framework OpenGL -o visualiser )
cp "$TLS/arm64/libtls-1-0.dylib" "$d/libtls.dylib"
common "$d"
( cd "$work" && tar cjf "$out/$name.tar.bz2" "$name" )
echo "package: $out/$name.tar.bz2"

# ---- Linux x86-64 ----
if [ $linux = 1 ]; then
name="xcc-benchviz-$ver-linux"
d="$work/$name"
link="$work/link-linux"
mkdir -p "$d" "$link"
sh "$UXKIT/tools/build_libuxgtk.sh" "$link" --with-link-inputs
cp "$TLS/x86_64/libtls-1-0.so" "$link/libtls.so"
# `#use <tls>` finds the library on its own for arm64 only, so the x86-64
# link names its headers and the library.  The link runs inside the link
# directory with a relative -L, because xcc writes each -L path after $ORIGIN
# into the program's search path, and an absolute one would name this machine.
( cd "$link" && "$XCC" -A x86_64 -dynamic -I "$UXKIT" -I "$here" -I "$TLS/xc" -O2 \
   "$here/Visualiser.xc" -L . -lUXGtk -ltls -lgtk-4 -lGL -o "$d/visualiser" )
cp "$link/libUXGtk.so" "$link/libtls.so" "$d/"
common "$d"
( cd "$work" && tar cjf "$out/$name.tar.bz2" "$name" )
echo "package: $out/$name.tar.bz2"
fi

# ---- Windows x86-64 ----
name="xcc-benchviz-$ver-win64"
d="$work/$name"
mkdir -p "$d"
"$XCC" -A win64 -I "$UXKIT" -I "$here" -O2 "$here/Visualiser.xc" -o "$d/visualiser.exe"
cp "$TLS/win64/libtls.dll" "$d/"
common "$d"
rm -f "$out/$name.zip"
( cd "$work" && zip -qr "$out/$name.zip" "$name" )
echo "package: $out/$name.zip"

# ---- the benchmark sources, as committed ----
name="xcc-bench-sources-$ver"
git -C "$root" archive --format=tar --prefix="$name/" HEAD benchmark | bzip2 -9 > "$out/$name.tar.bz2"
echo "package: $out/$name.tar.bz2"
