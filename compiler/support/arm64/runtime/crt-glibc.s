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
// crt-glibc.s — program entry for arm64 Linux with glibc (target arm64-linux).
//
// The kernel enters _start with sp at argc, argv[], NULL, envp[] and the
// dynamic loader's finaliser in x0. glibc's contract (csu/libc-start.c):
// __libc_start_main(main, argc, argv, init, fini, rtld_fini, stack_end) sets
// up TLS, stdio and atexit, runs the program's constructors (DT_INIT_ARRAY —
// with init and fini NULL, glibc 2.34 and later run them itself, so they are
// not run here as well), calls main, and exits with its result; it never
// returns. `main` is reached through xtc_glibc_main, which is crt-android.s's
// xtc_android_main: the stack canary first, then the arguments for
// Process.argument, then the program.
//
// Mach-O operand spelling (@PAGE/@PAGEOFF), as the in-house assembler reads
// the whole image in that dialect.
.text
.globl _start
.p2align 2
_start:
    mov x29, #0                         // an outermost frame: no caller to unwind to
    mov x30, #0
    mov x5, x0                          // rtld_fini, from the dynamic loader
    ldr x1, [sp]                        // argc
    add x2, sp, #8                      // argv
    mov x6, sp                          // stack_end
    mov x3, xzr                         // init: glibc runs DT_INIT_ARRAY itself
    mov x4, xzr                         // fini
    adrp x0, xtc_glibc_main@PAGE
    add  x0, x0, xtc_glibc_main@PAGEOFF
    bl __libc_start_main
    brk #0                              // unreachable: __libc_start_main does not return

.globl xtc_glibc_main
.p2align 2
xtc_glibc_main:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x0, x1, [sp, #16]               // argc, argv, envp: kept across the calls
    str x2, [sp, #32]
    bl _xt_stack_guard_init             // the stack canary's guard word, first
    ldp x0, x1, [sp, #16]
    bl _xt_set_args
    ldp x0, x1, [sp, #16]               // reloaded: no callee keeps x0-x2
    ldr x2, [sp, #32]
    bl main
    ldp x29, x30, [sp], #48
    ret
