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

# Regenerate glue-android.s from android-glue.c. Needs $ANDROID_HOME with an NDK.
#
# Same arrangement as gen-rt-android.sh: clang runs ONCE, here, and the output is
# checked in, so a user compile assembles this text with XAArm64Assembler and
# never needs the NDK. The .c stays checked in too — the clang link path compiles
# it directly — so the two paths cannot drift apart.
set -eu
cd "$(dirname "$0")"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
NDK=$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)
CC=$(echo "$NDK"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android24-clang)
OUT=glue-android.s

# Flags as for the runtime: no BTI/PAC land marks, no LSE (Android's floor is
# armv8-a), no .cfi_*/.addrsig metadata for a linker we are not using.
"$CC" -S -O1 -fno-stack-protector -fomit-frame-pointer \
      -fno-asynchronous-unwind-tables -fno-addrsig -mno-outline-atomics \
      -mbranch-protection=none \
      android-glue.c -o "$OUT.body"

# Namespace clang's local labels. Every generated runtime file spells them the
# same way — `.LBB0_1`, `.L.str` — and they are all concatenated into ONE
# assembly unit, where a flat symbol table makes the second definition win and
# silently retarget the first file's branches.
sed -i.bak 's/\.L/.Lglue_/g' "$OUT.body" && rm -f "$OUT.body.bak"

{
  cat <<'HDR'
// glue-android.s — the NativeActivity entry point, as assembly.
// GENERATED from android-glue.c by gen-glue-android.sh — do not hand-edit.
//
// Checked in so `-A android --emit-apk` needs no NDK clang: XAArm64Assembler
// assembles this like any other text. Read android-glue.c for what it does and
// why it is not the NDK's android_native_app_glue.c.
//
// Exports exactly one symbol, ANativeActivity_onCreate, which is what the
// framework dlsym()s out of the packaged library. Imports (bionic): libc.so for
// pipe/dup2/pthread/stdio, liblog.so for __android_log_write, libandroid.so for
// ANativeActivity_finish.
HDR
  cat "$OUT.body"
} > "$OUT.tmp"

# Rename rather than redirect onto $OUT: a run that died half way would leave a
# TRUNCATED glue checked in, which assembles and links and then fails at
# whatever it happened to cut off.
mv "$OUT.tmp" "$OUT"
rm -f "$OUT.body"
echo "wrote $(pwd)/$OUT ($(wc -l < "$OUT") lines)"
