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

// crt-macos.s — the entry crt for the self-hosted arm64/macOS toolchain (Phase 4).
// Prepended (with rt-macos.s) to the program's asm; the linker entry is
// _xtc_start. The rest of the runtime (putc, ARC/heap, weak, print, math) lives
// in rt-macos.s.
.text

// LC_MAIN entry: call the program's main, then return its value — libSystem
// passes the entry's w0 return to exit(), so `i32 main` propagates its status.
// The backend already leaves a defined w0: an `i32 main` returns its value, and
// a `void main` epilogue emits `mov w0, #0` (C99 fall-off-returns-0), so w0 is
// never garbage here — matching the clang path (i32 main → that code, void → 0).
// The LC_MAIN entry is handed (argc, argv, envp) in x0/x1/x2, exactly as `main`
// would be. Those are saved into the runtime's globals before the call, which is
// what makes Process.arguments() work on this path: a C constructor cannot do it
// here, because the self-hosted link emits no __mod_init_func for dyld to run.
.globl _xtc_start
.align 2
_xtc_start:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl __xt_set_args                    // (argc, argv) are already in x0/x1
    bl _main
    ldp x29, x30, [sp], #16
    ret
