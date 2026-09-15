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

// crt-android.s — the entry crt for the self-hosted arm64/Android toolchain.
// Prepended (with rt-android.s) to the program's asm by the driver; the linker
// entry symbol is `_start`.
//
// Bionic's contract, taken from the NDK's own crtbegin_dynamic.o: the kernel
// enters at `_start` with sp pointing at the raw argument block (argc, argv[],
// NULL, envp[], NULL, auxv), and everything else — TLS, stdio, atexit, the
// locale — is set up by `__libc_init`, which never returns. Calling `main`
// directly instead would run before any of that exists, and the first `printf`
// would fault a long way from the cause.
//
//   __libc_init(void *raw_args, void (*onexit)(void),
//               int (*slingshot)(int, char **, char **),
//               structors_array_t const *structors)
//
// `structors` is all-null here, and stays that way DELIBERATELY: this image is
// dynamic, so bionic's loader has already walked DT_INIT_ARRAY by the time it
// enters `_start`, and pointing `structors` at the same array would run every
// constructor a second time. (Until bug 124 the writer emitted no
// DT_INIT_ARRAY either, so nothing ran at all — a program's static
// initialisers and designable registrars were silently inert on android.)
// The slingshot is our own
// wrapper rather than `main` itself, so the runtime's argv globals are recorded
// before the program starts — that is what makes Process.arguments() work on
// this path, where there is no C constructor to do it.
.text

.globl _start
.p2align 2
_start:
    mov x29, #0                         // an outermost frame: no caller to unwind to
    mov x30, #0
    mov x0, sp                          // raw args — BEFORE we move sp
    sub sp, sp, #64
    stp xzr, xzr, [sp, #0]              // structors_array_t, zeroed
    stp xzr, xzr, [sp, #16]
    stp xzr, xzr, [sp, #32]
    stp xzr, xzr, [sp, #48]
    mov x1, xzr                         // onexit — bionic's, not ours
    adrp x2, xtc_android_main@PAGE
    add  x2, x2, xtc_android_main@PAGEOFF
    mov x3, sp
    bl __libc_init
    ret                                 // unreachable: __libc_init does not return

// (argc, argv, envp) arrive in x0/x1/x2 exactly as `main` would take them.
.globl xtc_android_main
.p2align 2
xtc_android_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _xt_set_args                     // (argc, argv) already in x0/x1
    bl main
    ldp x29, x30, [sp], #16
    ret
