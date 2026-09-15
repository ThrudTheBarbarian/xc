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

// libxt-pic.c — runtime for the Tier-2 PIC (ET_DYN) arm9 path, loaded by the
// XTOS loader. Down to just two primitives that can't (yet) come from libc:
//   • _exit — the XTOS `svc #1` SYS_exit syscall. libc.so doesn't export _exit
//     (newlib has the program provide it; libc's exit()/abort() call it), so it
//     lives here until the loader's libc grows one.
//   • the elapsed-time clock — a monotonic counter. libc's gettimeofday() exists
//     but the kernel doesn't service it yet (returns 0), so a real clock waits on
//     an XTOS time syscall; the counter is the working stand-in.
// Everything else is gone — arm9 Stdio.xc / Math.xc call libc/libm directly now
// (write + snprintf for output/float formatting, srandom/random for the PRNG, the
// libm transcendentals; sqrt is the FSqrt IR op → vsqrt).

#include <stdint.h>

// Process exit via the XTOS `svc #1` SYS_exit syscall (terminates THIS process).
// Was ARM-semihosting SYS_EXIT, which halts the whole emulator — wrong under the
// loader. newlib's exit()/abort() bottom out here (the program owns this stub).
__attribute__((noreturn)) void _exit(int code)
    {
    register long n asm("r7") = 0x101; // SYS_exit
    register long a0 asm("r0") = code;
    asm volatile("svc #1" ::"r"(n), "r"(a0) : "memory");
    for (;;)
        {
        }
    }

// (Float formatting is no longer vended here — arm9 Stdio.xc calls libc snprintf
// + write directly now that an xtc variadic may call a C-ABI variadic.)

// (Math transcendentals are no longer vended here — arm9 Math.xc calls libm.so
// directly, and sqrt is the FSqrt IR op → hardware `vsqrt`.)

// (The PRNG is no longer vended here — arm9 Math.xc calls libc srandom/random
// directly, deterministically seeded via random()'s default seed 1.)

// ── Time (Time.xc) — monotonic counter (Tier-2 will read a real xtos clock) ──
static uint32_t xt_ticks;
void _xt_clk_reset(void)
    {
    xt_ticks = 0;
    }
uint32_t _xt_clk_ticks(void)
    {
    return (xt_ticks += 1000);
    }
void _xt_clk_delay(uint32_t jiffies)
    {
    xt_ticks += jiffies * 1000;
    }

// ── Files (Files.xc) and the command line (Process.xc) ───────────────────────
// Straight to the XTOS syscalls (`svc #1`, number in r7) rather than through
// libc's file layer: `_exit` above already goes that way, the numbers are the
// frozen ABI in the loader's xtsys.h, and a PIC program's libc.so has its own
// view of what a file is. These are the primitives Files.xc / Process.xc are
// written against on every hosted target — same `_xt_` names as the arm64
// host runtime, so the two platform libraries are the same source.
#define XT_SYS_EXIT 0x101
#define XT_SYS_OPEN 0x300
#define XT_SYS_CLOSE 0x301
#define XT_SYS_READ 0x302
#define XT_SYS_WRITE 0x303
#define XT_SYS_LSEEK 0x304
#define XT_SYS_STAT 0x305

// vfs.h's open flags. O_RDONLY is the absence of the others.
#define XT_O_WRONLY 0x0001
#define XT_O_APPEND 0x0008
#define XT_O_CREAT 0x0200
#define XT_O_TRUNC 0x0400

struct xt_stat_abi
    {
    unsigned mode, size, mtime;
    };

static long xt_sc(long n, long a0, long a1, long a2)
    {
    register long r7 asm("r7") = n;
    register long r0 asm("r0") = a0;
    register long r1 asm("r1") = a1;
    register long r2 asm("r2") = a2;
    asm volatile("svc #1" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
    }

// The mode STRING the caller passes is stdio's ("rb", "wb", "ab"), because that
// is what the shared Files.xc hands over; it is translated here rather than
// there, so the library source stays the same on a host that really does have
// fopen.
static int xt_flags_for(const char* mode)
    {
    if (!mode || mode[0] == 'r')
        return 0;
    if (mode[0] == 'a')
        return XT_O_WRONLY | XT_O_CREAT | XT_O_APPEND;
    return XT_O_WRONLY | XT_O_CREAT | XT_O_TRUNC;
    }

int32_t _xt_file_open(const char* path, const char* mode)
    {
    return (int32_t)xt_sc(XT_SYS_OPEN, (long)path, xt_flags_for(mode), 0);
    }
int32_t _xt_file_read(int32_t h, void* buf, uint32_t n)
    {
    return (int32_t)xt_sc(XT_SYS_READ, h, (long)buf, (long)n);
    }
int32_t _xt_file_write(int32_t h, const void* buf, uint32_t n)
    {
    return (int32_t)xt_sc(XT_SYS_WRITE, h, (long)buf, (long)n);
    }
void _xt_file_close(int32_t h)
    {
    xt_sc(XT_SYS_CLOSE, h, 0, 0);
    }

int32_t _xt_file_size(const char* path)
    {
    struct xt_stat_abi st;
    if (xt_sc(XT_SYS_STAT, (long)path, (long)&st, 0) != 0)
        return -1;
    return (int32_t)st.size;
    }

int32_t _xt_file_exists(const char* path)
    {
    struct xt_stat_abi st;
    return xt_sc(XT_SYS_STAT, (long)path, (long)&st, 0) == 0 ? 1 : 0;
    }

// XTOS filenames are case-SENSITIVE, so the exact-spelling question is the
// same question as the plain one. (On macOS it is not, which is why the two
// primitives exist at all.)
int32_t _xt_file_exists_exact(const char* path)
    {
    return _xt_file_exists(path);
    }

// argc/argv, captured at entry. The loader calls the program with them in
// r0/r1 the way any AAPCS function is called, and the xtc `main` takes no
// parameters — so the C stub owns the real `main`, records them, and calls the
// renamed xtc entry. (The arm64 host does the same thing with a constructor;
// there is no constructor protocol here.)
static int xt_argc;
static char** xt_argv;

void _xt_capture_args(int argc, char** argv)
    {
    xt_argc = argc;
    xt_argv = argv;
    }

int32_t _xt_argc(void)
    {
    return (int32_t)xt_argc;
    }

const char* _xt_argv(int32_t i)
    {
    static const char* empty = "";
    if (i < 0 || i >= xt_argc || !xt_argv)
        return empty;
    return xt_argv[i];
    }

void _xt_exit(int32_t code)
    {
    xt_sc(XT_SYS_EXIT, code, 0, 0);
    for (;;)
        {
        }
    }

// ── Threads ──────────────────────────────────────────────────────────────────
// The `_xt_*` threading contract, kept in its own file for the same reason the
// hosted targets keep theirs in one: three runtimes implement it, and a primitive
// present in only some of them fails to link in exactly the others. Everything it
// needs is an XTOS syscall or an A9 exclusive-monitor sequence, so it is a plain
// #include rather than a separate translation unit — the arm9 PIC runtime is
// compiled as ONE file by the driver (src/xtc/main.m).
#include "xt-threads-xtos.c"
