#!/bin/sh
# provision-gnustep-linux.sh — build the GNUstep stack the xtc compiler needs to
# run natively on x86-64 Linux, from source, into a home-directory prefix with NO
# root. This is what lets the on-Linux row of the host×target matrix work: once
# xtc runs on Linux, its host-independent writers produce macOS / Linux / Windows
# binaries alike (private:docs/Design/native-toolchain.md §14).
#
# Why from source: Ubuntu's packaged GNUstep is built against the GCC Objective-C
# runtime, which clang's -fobjc-arc cannot use. The compiler needs the modern
# libobjc2 (gnustep-2.x) runtime, which Ubuntu does not package — so libobjc2 and
# gnustep-base are built here with clang.
#
# Prerequisites on the host (the only things that may need a package manager):
#   clang, make, wget, libffi + libxml2 DEV headers, the ICU RUNTIME libs.
#   The ICU -dev headers and pkg-config are NOT required — this script fetches
#   ICU headers into the prefix and installs a tiny pkg-config shim.
#
# Usage:  sh provision-gnustep-linux.sh [PREFIX]      (default PREFIX=$HOME/gnustep)
# Then:   source $PREFIX/share/GNUstep/Makefiles/GNUstep.sh
#         export PATH=$HOME/opt/bin:$PATH LD_LIBRARY_PATH=$PREFIX/lib
#         make CC=clang            # in the xtc checkout
set -e
PREFIX="${1:-$HOME/gnustep}"
OPT="$HOME/opt"
SRC="$HOME/gnustep-src"
JOBS="$(nproc 2>/dev/null || echo 4)"
CMAKE_VER=3.31.6
ICU_REL=78.3          # match the host's ICU runtime major version (see below)

mkdir -p "$PREFIX" "$OPT/bin" "$SRC"
export PATH="$OPT/bin:$PATH"

# ── cmake (prebuilt, no root) ────────────────────────────────────────────────
if ! command -v cmake >/dev/null 2>&1; then
    cd "$OPT"
    wget -q "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VER/cmake-$CMAKE_VER-linux-x86_64.tar.gz"
    tar xzf "cmake-$CMAKE_VER-linux-x86_64.tar.gz"
    ln -sf "$OPT/cmake-$CMAKE_VER-linux-x86_64/bin/cmake" "$OPT/bin/cmake"
fi

# ── pkg-config shim (gnustep-base's ICU detection wants one) ──────────────────
# Answers only the modules gnustep-base queries; the ICU runtime libs live in the
# system lib dir, their -dev symlinks are created into the prefix below.
ICU_SYSLIB="$(dirname "$(ls /usr/lib/*/libicuuc.so.* 2>/dev/null | head -1)")"
cat > "$OPT/bin/pkg-config" <<SHIM
#!/bin/sh
mod=""; for a in "\$@"; do case "\$a" in --*) ;; *) mod="\$mod \$a";; esac; done
set -- \$mod; case "\$1" in
  icu-i18n) c="-I$PREFIX/include"; l="-L$PREFIX/lib -licui18n -licuuc -licudata"; v=$ICU_REL ;;
  icu-uc)   c="-I$PREFIX/include"; l="-L$PREFIX/lib -licuuc -licudata";           v=$ICU_REL ;;
  *) exit 1 ;;
esac
for a in "\$@"; do case "\$a" in
  --exists) exit 0 ;; --modversion) echo "\$v" ;; --cflags) echo "\$c" ;; --libs) echo "\$l" ;;
esac; done
SHIM
chmod +x "$OPT/bin/pkg-config"

# ── ICU: headers into the prefix + -dev symlinks to the system runtime ───────
if [ ! -f "$PREFIX/include/unicode/uregex.h" ]; then
    cd /tmp
    wget -q "https://github.com/unicode-org/icu/releases/download/release-$ICU_REL/icu4c-$ICU_REL-sources.tgz"
    rm -rf icu-src && mkdir icu-src && tar xzf "icu4c-$ICU_REL-sources.tgz" -C icu-src
    mkdir -p "$PREFIX/include/unicode"
    for d in common i18n io; do cp icu-src/icu/source/$d/unicode/*.h "$PREFIX/include/unicode/" 2>/dev/null || true; done
fi
for l in icui18n icuuc icudata; do
    ln -sf "$ICU_SYSLIB/lib$l.so."* "$PREFIX/lib/lib$l.so" 2>/dev/null || \
    ln -sf "$(ls "$ICU_SYSLIB/lib$l.so."* | head -1)" "$PREFIX/lib/lib$l.so"
done

# ── tsl-robin-map (libobjc2's header-only dependency; no git needed) ──────────
if [ ! -f "$PREFIX/include/tsl/robin_map.h" ]; then
    cd /tmp && rm -rf robin-map
    wget -q -O robin-map.tgz https://github.com/Tessil/robin-map/archive/refs/heads/master.tar.gz
    tar xzf robin-map.tgz && mv robin-map-* robin-map
    cmake -S robin-map -B robin-map/build -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
    cmake --install robin-map/build >/dev/null
fi

# The three GNUstep source trees (libobjc2, tools-make, libs-base) must already be
# under $SRC — clone them on a machine that has git and scp them over, or clone
# here if git is available:
for repo in libobjc2 tools-make libs-base; do
    [ -d "$SRC/$repo" ] && continue
    command -v git >/dev/null 2>&1 || { echo "need $SRC/$repo (clone gnustep/$repo)"; exit 1; }
    git clone --depth 1 "https://github.com/gnustep/$repo.git" "$SRC/$repo"
done

# ── libobjc2 (the modern runtime — this is what makes ARC work) ──────────────
cd "$SRC/libobjc2" && rm -rf build && mkdir build && cd build
CC=clang CXX=clang++ cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
    -DGNUSTEP_INSTALL_TYPE=NONE -DTESTS=OFF .. >/dev/null
make -j"$JOBS" >/dev/null && make install >/dev/null

# ── gnustep-make (configured for the ng / libobjc2 runtime) ──────────────────
cd "$SRC/tools-make"
CC=clang CXX=clang++ ./configure --prefix="$PREFIX" --with-library-combo=ng-gnu-gnu \
    CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib" >/dev/null
make install >/dev/null
. "$PREFIX/share/GNUstep/Makefiles/GNUstep.sh"

# ── gnustep-base (Foundation), with ICU for NSRegularExpression ──────────────
cd "$SRC/libs-base"
make distclean >/dev/null 2>&1 || true
CC=clang CXX=clang++ ./configure --prefix="$PREFIX" --disable-tls --disable-xslt \
    CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib" >/dev/null
# The ICU libs must be on the shared-library link line (ld.bfd is order-sensitive,
# so they go into CONFIG_SYSTEM_LIBS, which is appended after the objects), and
# GNUstep's stock +alloc returns id rather than instancetype — which makes every
# `[[self alloc] initWithKind:]` ambiguous across classes. Patch both.
sed -i "s|CONFIG_SYSTEM_LIBS += *-lxml2|CONFIG_SYSTEM_LIBS += -L$PREFIX/lib -licui18n -licuuc -licudata -lxml2|" config.mak base.make
sed -i "s|^+ (id) alloc;|+ (instancetype) alloc;|; s|^+ (id) allocWithZone: (NSZone\\*)z;|+ (instancetype) allocWithZone: (NSZone*)z;|" "$PREFIX/include/Foundation/NSObject.h"
make -j"$JOBS" >/dev/null && make install >/dev/null

echo "GNUstep ready under $PREFIX."
echo "Build xtc with:"
echo "  source $PREFIX/share/GNUstep/Makefiles/GNUstep.sh"
echo "  export PATH=$OPT/bin:\$PATH LD_LIBRARY_PATH=$PREFIX/lib"
echo "  make CC=clang"
