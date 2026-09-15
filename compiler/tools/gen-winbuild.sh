#!/bin/sh
# gen-winbuild.sh — generate flags.rsp and shared.rsp for tools/winbuild.bat.
# Run from the repo root on any Unix box (or adapt by hand on Windows). The
# outputs are plain text response files clang-cl reads with @file.
set -e
cd "$(dirname "$0")/.."
INCS=$(find src/xtc src/xta -type d | sed 's|^|-I|' | tr '\n' ' ')
# NOTE: -Xclang -fobjc-arc, NOT -fobjc-arc — clang-cl ignores the latter.
FLAGS="-Xclang -fobjc-arc -fobjc-runtime=gnustep-2.0 -Xclang -fexceptions -Xclang -fobjc-exceptions -fblocks -DGNUSTEP -DGNUSTEP_WITH_DLL -DGNUSTEP_RUNTIME=1 -D_NON_FRAGILE_ABI=1 -DNATIVE_OBJC_EXCEPTIONS \"-DXTC_VERSION=\\\"0.4\\\"\" /MD -Wno-nullability-completeness -Wno-objc-method-access"
printf '%s %s -IC:/GNUstep/x64/Release/include\n' "$FLAGS" "$INCS" > tools/flags.rsp
find src/xtc src/xta -name '*.m' ! -name 'main.m' | sort > tools/shared.rsp
echo "wrote tools/flags.rsp ($(wc -l < tools/shared.rsp) shared sources in tools/shared.rsp)"
