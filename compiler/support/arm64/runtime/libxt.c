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

#include <sys/stat.h>
// libxt.c — host runtime support for xtc programs, archived into libxt.a.
//
// Library .xc files (and generated code) call C functions with standardized
// names; the compiler links libxt.a on platforms that need a host runtime.
// The xt6502 target has its own hand-written 6502-asm runtime and links none
// of this. Because libxt.a is a static archive, a program that never
// references a given primitive doesn't pull its object in — the link stays
// quiet for fixtures that don't use it.
//
// First module: real wall-clock time, backing the arm64 Time class
// (support/arm64/lib/Time.xc). The Atari Time class drives the RTCLOK jiffy
// counter; on the host there is none, so these read CLOCK_MONOTONIC.

#include <stdint.h>
#include <time.h>
#include <stdlib.h>

// ── Random ─────────────────────────────────────────────────────────────────
// The arm64 (best-of-breed host) build delegates Math's PRNG to the host's
// optimised libc random() instead of reimplementing the Atari xorshift.
// Seeded deterministically on first use so runs are reproducible.
static int xt_rand_seeded = 0;
static void xt_rand_init(void)
    {
    if (!xt_rand_seeded)
        {
        srandom(1u);
        xt_rand_seeded = 1;
        }
    }
void _xt_srand(uint32_t seed)
    {
    srandom(seed);
    xt_rand_seeded = 1;
    }
uint32_t _xt_rand_u32(void)
    {
    xt_rand_init();
    return ((uint32_t)random() << 16) ^ (uint32_t)random(); // 31-bit → 32-bit
    }
// Math.rand() float / double overload: [0.5, 1.0), the Atari range.
float _xt_rand_f(void)
    {
    xt_rand_init();
    return 0.5f + ((float)random() / ((float)RAND_MAX + 1.0f)) * 0.5f;
    }
double _xt_rand_d(void)
    {
    xt_rand_init();
    return 0.5 + ((double)random() / ((double)RAND_MAX + 1.0)) * 0.5;
    }

// ── Time ─────────────────────────────────────────────────────────────────

static double xt_clk_origin; // set by _xt_clk_reset (Time.clearTimer)

static double xt_now_secs(void)
    {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    }

// Time.clearTimer() — set the elapsed-time origin to "now". Programs must
// call this before timerValue()/secondsSince(), exactly as the Atari port
// needs clearTimer() to zero RTCLOK first.
void _xt_clk_reset(void)
    {
    xt_clk_origin = xt_now_secs();
    }

// Time.timerValue() / ticksSince() / secondsSince() — microseconds elapsed
// since the last _xt_clk_reset(). The u32 tick is microseconds (wraps after
// ~71 min); Time.secondsSince() divides by 1e6 to recover real seconds. The
// unit is host-specific (the Atari uses 1/60 s jiffies) — portable code uses
// secondsSince() for real time and treats the raw tick as opaque.
uint32_t _xt_clk_ticks(void)
    {
    return (uint32_t)((xt_now_secs() - xt_clk_origin) * 1.0e6);
    }

// Time.delayJiffies(jiffies) — wait jiffies * (1/60 s) of real wall time.
void _xt_clk_delay(uint32_t jiffies)
    {
    double s = (double)jiffies / 60.0;
    struct timespec req;
    req.tv_sec = (time_t)s;
    req.tv_nsec = (long)((s - (double)req.tv_sec) * 1.0e9);
    nanosleep(&req, (struct timespec*)0);
    }

// ── Files and process arguments ────────────────────────────────────────────
// Added for the self-hosted compiler work (private:docs/Design/self-hosting.md M4): a
// program written in xtc has to be able to read its input and see its command
// line, and the arm64 FILE class covers console streams only.
//
// Files are handed to xtc as small integer HANDLES rather than FILE*, so no xtc
// declaration has to name a host pointer type. The table is fixed-size: this is
// a compiler driver, not a server, and eight open files is already generous.
#include <stdio.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

#define XT_MAX_FILES 8
static FILE* xt_files[XT_MAX_FILES];

// Mark a file executable (0755). A linker that cannot do this produces an
// output nobody can run, so it belongs with the rest of the file primitives
// rather than in a shell step around them.
int32_t _xt_file_chmod_exec(const char* path)
    {
    return chmod(path, 0755) == 0 ? 1 : 0;
    }

int32_t _xt_file_open(const char* path, const char* mode)
    {
    for (int i = 0; i < XT_MAX_FILES; i++)
        {
        if (xt_files[i])
            continue;
        FILE* f = fopen(path, mode);
        if (!f)
            return -1;
        xt_files[i] = f;
        return i;
        }
    return -1; // table full
    }

int32_t _xt_file_read(int32_t h, uint8_t* buf, uint32_t n)
    {
    if (h < 0 || h >= XT_MAX_FILES || !xt_files[h])
        return -1;
    size_t got = fread(buf, 1, (size_t)n, xt_files[h]);
    return (int32_t)got;
    }

int32_t _xt_file_write(int32_t h, const uint8_t* buf, uint32_t n)
    {
    if (h < 0 || h >= XT_MAX_FILES || !xt_files[h])
        return -1;
    size_t put = fwrite(buf, 1, (size_t)n, xt_files[h]);
    return (int32_t)put;
    }

void _xt_file_close(int32_t h)
    {
    if (h < 0 || h >= XT_MAX_FILES || !xt_files[h])
        return;
    fclose(xt_files[h]);
    xt_files[h] = NULL;
    }

// -1 when the file cannot be opened, so "missing" and "empty" stay distinct.
int32_t _xt_file_size(const char* path)
    {
    FILE* f = fopen(path, "rb");
    if (!f)
        return -1;
    if (fseek(f, 0, SEEK_END) != 0)
        {
        fclose(f);
        return -1;
        }
    long n = ftell(f);
    fclose(f);
    return (n < 0) ? -1 : (int32_t)n;
    }

int32_t _xt_file_exists(const char* path)
    {
    FILE* f = fopen(path, "rb");
    if (!f)
        return 0;
    fclose(f);
    return 1;
    }

// The environment, read-only. A shipped compiler has to find things a user
// names by convention rather than by flag — the signing-key cache under
// $HOME/.xcc first among them — and without this the xtc driver had no way to
// ask, so the path had to be passed on every command line.
//
// Read-only on purpose: setting a variable in a process that is about to write
// a file helps nobody, and the surface stays one function.
const char* _xt_getenv(const char* name)
    {
    const char* v = getenv(name);
    return v ? v : "";
    }

// Create a directory (and tolerate one that already exists). The signing-key
// cache lives under $HOME/.xcc, which on a fresh machine is not there yet — and
// a compiler that can generate a key but not the directory to put it in has
// only moved the failure.
int32_t _xt_mkdir(const char* path)
    {
    if (mkdir(path, 0700) == 0)
        return 1;
    return (errno == EEXIST) ? 1 : 0;
    }

// The process argument vector. An xtc `main` takes no parameters, so argc/argv
// are captured by a constructor — Darwin and glibc both hand (argc, argv, envp)
// to constructors, which is what makes this possible without touching the
// generated entry point.
static int xt_argc;
static char** xt_argv;

__attribute__((constructor)) static void xt_capture_args(int argc, char** argv, char** envp)
    {
    (void)envp;
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

// Terminate with a status. `_exit` rather than `exit` so no atexit handler or
// stdio flush runs twice when a program calls this from deep inside a driver.
void _xt_exit(int32_t code)
    {
    fflush(NULL);
    _exit((int)code);
    }

// Case-sensitive existence test. macOS filesystems are case-PRESERVING but
// case-insensitive, so a plain fopen("Sort.xc") happily opens a file actually
// named sort.xc — and the preprocessor would then import the user's own source
// as the "Sort library". Listing the directory and comparing the name byte for
// byte is the only way to ask the real question.
#include <dirent.h>
int32_t _xt_file_exists_exact(const char* path)
    {
    const char* slash = strrchr(path, '/');
    const char* name = slash ? slash + 1 : path;
    char dir[1024];
    if (slash)
        {
        size_t n = (size_t)(slash - path);
        if (n >= sizeof dir)
            return 0;
        memcpy(dir, path, n);
        dir[n] = 0;
        if (n == 0)
            {
            dir[0] = '/';
            dir[1] = 0;
            }
        }
    else
        {
        dir[0] = '.';
        dir[1] = 0;
        }
    DIR* d = opendir(dir);
    if (!d)
        return 0;
    struct dirent* e;
    int32_t found = 0;
    while ((e = readdir(d)) != 0)
        {
        if (strcmp(e->d_name, name) == 0)
            {
            found = 1;
            break;
            }
        }
    closedir(d);
    return found;
    }

// ── Threading (private:docs/Design/threading.md Phase 2) ──
// Shared verbatim with the self-hosted runtime (src/xtc/support-src/rt.c →
// rt-macos.s), which includes the same file. Two runtimes, one contract: a
// primitive added to only one of them fails to link in exactly the other path.
#include "../../generic/runtime/xt-threads.c"
