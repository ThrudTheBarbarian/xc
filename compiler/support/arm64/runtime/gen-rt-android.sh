#!/bin/bash
# xcc runtime library.
#
# Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
#
# This file is part of the xcc runtime library: the code that is combined
# with a program when xcc compiles it. It is free software; you can
# redistribute it and/or modify it under the terms of the GNU General Public
# License as published by the Free Software Foundation, either version 3 of
# the License, or (at your option) any later version.
#
# Under Section 7 of GPL version 3, you are granted additional permissions
# described in the GCC Runtime Library Exception, version 3.1, as published
# by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
# parent.
#
# The effect of that exception is the point: a program compiled by xcc
# contains parts of this file, and the exception is what leaves that program
# under whatever licence its author chooses, including a proprietary one.
#
# This file is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.

# Regenerate rt-android.s. Run from anywhere; needs $ANDROID_HOME with an NDK.
#
# The output is CHECKED IN, exactly as rt-macos.s is, and clang never runs
# during a user compile — XAArm64Assembler assembles this text like any other,
# so the toolchain stays self-hosted. Regenerate when the object layout or the
# runtime contract in src/xtc/support-src/rt.c changes.
#
# It must be the NDK clang, not the host one: Darwin/arm64 passes variadic
# arguments on the stack while AAPCS64 passes them in registers, so a runtime
# generated for macOS would call Android's printf with the wrong ABI.
set -eu
cd "$(dirname "$0")/../../.."          # -> compiler/
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
NDK=$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)
CC=$(echo "$NDK"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android24-clang)
OUT=support/arm64/runtime/rt-android.s

# The flags are not cosmetic:
#   -mbranch-protection=none  BTI/PAC landing pads we neither emit nor need.
#   -mno-outline-atomics      keeps an atomic RMW as an ldaxr/stlxr pair rather
#                             than a call to libgcc's __aarch64_* outline
#                             helpers, which bionic does not export.
#   -fno-asynchronous-unwind-tables / -fno-addrsig
#                             .cfi_* and .addrsig are metadata for a linker we
#                             are not using.
"$CC" -S -O1 -fno-stack-protector -fomit-frame-pointer \
      -fno-asynchronous-unwind-tables -fno-addrsig -mno-outline-atomics \
      -mbranch-protection=none \
      src/xtc/support-src/rt.c -o "$OUT.body"

# Namespace clang's local labels. Every generated runtime file spells them the
# same way — `.LBB0_1`, `.L.str` — and they are all concatenated into ONE
# assembly unit, where a flat symbol table makes the second definition win and
# silently retarget the first file's branches.
sed -i.bak 's/\.L/.Lrt_/g' "$OUT.body" && rm -f "$OUT.body.bak"

{
  cat <<'HDR'
// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// rt-android.s — the self-hosted arm64/Android runtime (ARC/heap/weak +
// print + math + threads + files). GENERATED from src/xtc/support-src/rt.c
// by support/arm64/runtime/gen-rt-android.sh — do not hand-edit; regenerate.
//
// The Android twin of rt-macos.s, and generated the same way: clang runs
// ONCE, here, and never during a user compile — XAArm64Assembler assembles
// this text like any other, which is what keeps `-A android` free of the NDK.
// It must come from the NDK clang rather than the host one because
// Darwin/arm64 passes varargs on the STACK and AAPCS64 passes them in
// registers, so a macOS-generated runtime would hand Android's printf its
// arguments in the wrong places.
//
// Object header = 38 bytes, magic 0x58544F42 at base, refcount u16 at obj-2,
// weak head at obj-10 — the same contract every other target uses. Imports
// (bionic): libc.so for calloc/free/stdio/pthread, libm.so for the _xm_*
// wrappers' tail calls.
HDR
  cat "$OUT.body"
} > "$OUT.tmp"

# Rename, never redirect straight onto $OUT: a run that died half way would
# otherwise leave a TRUNCATED runtime checked in, which assembles and links
# and then fails at whatever it happened to cut off.
mv "$OUT.tmp" "$OUT"
rm -f "$OUT.body"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
