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
// by the Free Software Foundation -- see COPYING.RUNTIME in support/.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// rt-xcargs.c — SOURCE for the --xc-* options of a program that uses par.
//
// The start code of a program with a par block calls this before anything
// reads the arguments (the driver adds the call to the crt and links this
// file; -fno-xc-args leaves both out). Every argument that starts `--xc-` is
// taken out and set as the runtime variable it names, overriding the
// environment: `--xc-par=gpu` is XC_PAR=gpu, `--xc-par-report` (no value) is
// XC_PAR_REPORT=1, and `--xc-probe` is short for `--xc-par-probe`. Scanning
// stops at `--`, which stays in the list with everything after it. The
// program sees the rest, so its own argument parsing never meets them.
//
// XC_PAR_SECRET has no option, because a process listing shows the
// arguments. `--xc-help` prints the options and exits 0; an unknown name, or
// the secret, is an error (exit 2).
//
// POSIX targets: `int _xt_xcargs(int argc, char **argv)` compacts argv in
// place (argv[new argc] = NULL) and returns the new count, which the crt hands
// to the runtime's argument store and to main. Windows: `void _xt_xcargs(void)`
// rewrites the process's command line in place, GetCommandLineW's and
// GetCommandLineA's, before the runtime parses it, so argv, Process.arguments()
// and a later GetCommandLineW all see the filtered line.
//
// FREESTANDING: no #include, no C library beyond the few calls declared below,
// and no table of pointers (the in-house links of every target take this file;
// a string table needs no data relocation). Compiled once per target by
// tools/regen-runtimes.py (the xcargs-* rows); the .s files are checked in.

typedef unsigned long xt_xa_size;

// The options: each entry is NAME\thelp\n, NAME being the variable without
// its XC_ prefix; the option is its lower case with '-' for '_'. (No NUL
// inside the string: not every in-house assembler reads an octal escape.) These are the variables the par runtime reads,
// less XC_PAR_SECRET.
static const char xt_xa_table[] =
    "PAR\t" "=cpu|gpu|gpus|all|auto  where every par block runs\n"
    "PAR_THREADS\t" "=<n>  threads a block on the CPU uses\n"
    "PAR_REPORT\t" "[=2]  print where each block ran and what auto measured\n"
    "PAR_FORGET\t" "  remove what auto learned, so it measures again\n"
    "PAR_PROBE\t" "  measure every worker on a block's first run (also --xc-probe)\n"
    "PAR_GPU\t" "=cuda|vulkan  the GPU interface where both exist\n"
    "PAR_VULKAN_DEVICE\t" "=<n>  the Vulkan device, by index\n"
    "PAR_CUDA_DEVICES\t" "=<n,...>  the CUDA cards that take tiles\n"
    "PAR_WORKERS\t" "=cpu,cuda,metal,vulkan,remote  the devices that share tiles\n"
    "PAR_TILES\t" "=0  run each block in one piece\n"
    "PAR_TILE_MB\t" "=<n>  megabytes a tile moves each way\n"
    "PAR_TRACE\t" "[=<file>|<host:port>]  record each run's tiles\n"
    "PAR_PIN\t" "=0  Linux: leave the CPU threads unpinned\n"
    "PAR_REMOTE\t" "=<host[:port],...>|mdns|none  the xcd daemons to use\n"
    "PAR_POOL\t" "=<name>  find the daemons of that pool by mDNS\n"
    "PAR_VERIFY\t" "=0|all  how many remote tiles are checked on the CPU\n"
    "TLS_LIB\t" "=<file>  the TLS library for connections to daemons\n"
    "PAR_VARIANT\t" "=<name>  test: the kernel variant a device runs\n"
    "PAR_VK_FULL\t" "=0  test: leave out Vulkan's full-dispatch form\n"
    "PAR_VULKAN_LOSE\t" "=<n>  test: the Vulkan device reads as lost after n submits\n"
    "PAR_DIE_AFTER\t" "=<n>  test: drop a remote connection after n tiles\n"
    "PAR_MACHINE\t" "=<name>  test: the machine name a daemon gives\n";

static xt_xa_size xt_xa_len(const char* s)
    {
    xt_xa_size n = 0;
    while (s[n])
        n++;
    return n;
    }

// The length of a table field: up to the tab or newline that ends it.
static xt_xa_size xt_xa_field(const char* s)
    {
    xt_xa_size n = 0;
    while (s[n] && s[n] != '\t' && s[n] != '\n')
        n++;
    return n;
    }

static int xt_xa_prefix(const char* s, const char* p)
    {
    while (*p)
        if (*s++ != *p++)
            return 0;
    return 1;
    }

// The variable an option names, from its name (after "--xc-", up to '=' or
// the end): "par-report" -> "XC_PAR_REPORT". 0 when the name holds anything
// but lower-case letters, digits and '-', or is too long.
static int xt_xa_varname(const char* name, xt_xa_size n, char* out, xt_xa_size cap)
    {
    if (n == 5 && xt_xa_prefix(name, "probe"))
        {
        name = "par-probe";
        n = 9;
        }
    if (n == 0 || n + 4 > cap)
        return 0;
    out[0] = 'X';
    out[1] = 'C';
    out[2] = '_';
    for (xt_xa_size i = 0; i < n; i++)
        {
        char c = name[i];
        if (c >= 'a' && c <= 'z')
            out[3 + i] = (char)(c - 'a' + 'A');
        else if ((c >= '0' && c <= '9'))
            out[3 + i] = c;
        else if (c == '-')
            out[3 + i] = '_';
        else
            return 0;
        }
    out[3 + n] = 0;
    return 1;
    }

static int xt_xa_known(const char* var)
    {
    const char* t = xt_xa_table;
    while (*t)
        {
        xt_xa_size n = xt_xa_field(t);
        const char* b = var + 3;
        xt_xa_size i = 0;
        while (i < n && b[i] == t[i])
            i++;
        if (i == n && b[n] == 0)
            return 1;
        t += n + 1;
        t += xt_xa_field(t) + 1;
        }
    return 0;
    }

// ── the OS: write, set a variable, exit ──
#ifdef XT_WIN64
typedef unsigned short xt_xa_wchar;
extern void* GetStdHandle(unsigned int n);
extern int WriteFile(void* h, const void* buf, unsigned int n, unsigned int* done, void* ov);
extern int SetEnvironmentVariableW(const xt_xa_wchar* name, const xt_xa_wchar* value);
extern xt_xa_wchar* GetCommandLineW(void);
extern char* GetCommandLineA(void);
extern void ExitProcess(unsigned int code);
static void xt_xa_write(int fd, const char* s)
    {
    unsigned int done = 0;
    WriteFile(GetStdHandle(fd == 1 ? (unsigned int)-11 : (unsigned int)-12), s, (unsigned int)xt_xa_len(s), &done, 0);
    }
static void xt_xa_exit(int code)
    {
    ExitProcess((unsigned int)code);
    }
#else
extern long write(int fd, const void* buf, xt_xa_size n);
extern int setenv(const char* name, const char* value, int overwrite);
extern void exit(int code);
static void xt_xa_write(int fd, const char* s)
    {
    write(fd, s, xt_xa_len(s));
    }
static void xt_xa_exit(int code)
    {
    exit(code);
    }
#endif

// Appends at most n bytes of s (fewer at its NUL) to buf at o, keeping a NUL
// after them within cap; the new length. Not inlined: a copy of a literal
// peeled at its first byte addresses the literal plus one, and the in-house
// assemblers drop an addend on a page-relative symbol.
__attribute__((noinline)) static xt_xa_size xt_xa_cat(char* buf, xt_xa_size o, xt_xa_size cap,
                                                      const char* s, xt_xa_size n)
    {
    for (xt_xa_size i = 0; i < n && s[i] && o + 1 < cap; i++)
        buf[o++] = s[i];
    buf[o] = 0;
    return o;
    }

static void xt_xa_help(void)
    {
    char line[160];
    xt_xa_write(1, "Options for the par runtime, taken out of the arguments before main.\n"
                "Each sets the variable it names (--xc-par-report is XC_PAR_REPORT=1),\n"
                "overriding the environment. Arguments after -- are left alone.\n\n");
    const char* t = xt_xa_table;
    while (*t)
        {
        xt_xa_size n = xt_xa_field(t);
        const char* help = t + n + 1;
        xt_xa_size h = xt_xa_field(help);
        xt_xa_size o = xt_xa_cat(line, 0, sizeof line, "  --xc-", 7);
        for (xt_xa_size k = 0; k < n && o < sizeof line - 2; k++)
            line[o++] = t[k] == '_' ? '-' : (t[k] >= 'A' && t[k] <= 'Z') ? (char)(t[k] - 'A' + 'a') : t[k];
        for (xt_xa_size k = 0; k < h && o < sizeof line - 2; k++)
            line[o++] = help[k];
        line[o++] = '\n';
        line[o] = 0;
        xt_xa_write(1, line);
        t = help + h + 1;
        }
    xt_xa_write(1, "  --xc-help  this list\n\n"
                "XC_PAR_SECRET has no option: a process listing shows the arguments.\n");
    xt_xa_exit(0);
    }

static void xt_xa_fail(const char* arg, xt_xa_size n, const char* why)
    {
    char buf[256];
    xt_xa_size o = xt_xa_cat(buf, 0, sizeof buf, "xc: ", 4);
    o = xt_xa_cat(buf, o, 120, arg, n);
    o = xt_xa_cat(buf, o, sizeof buf, why, sizeof buf);
    o = xt_xa_cat(buf, o, sizeof buf, "\n", 1);
    xt_xa_write(2, buf);
    xt_xa_exit(2);
    }

static void xt_xa_secret(const char* s, xt_xa_size n, const char* var)
    {
    const char* x = "XC_PAR_SECRET";
    for (xt_xa_size i = 0;; i++)
        {
        if (var[i] != x[i])
            return;
        if (!x[i])
            break;
        }
    xt_xa_fail(s, n, ": refused, a process listing shows the arguments; set XC_PAR_SECRET in the environment");
    }

// One option, as bytes (s, n: the whole argument, "--xc-..."): exits on help
// or an error; else writes the variable's name to var and returns the offset
// of its value in s (n when it has none).
static xt_xa_size xt_xa_parse(const char* s, xt_xa_size n, char* var, xt_xa_size cap)
    {
    xt_xa_size eq = 5;
    while (eq < n && s[eq] != '=')
        eq++;
    if (eq == 9 && xt_xa_prefix(s + 5, "help"))
        xt_xa_help();
    if (!xt_xa_varname(s + 5, eq - 5, var, cap))
        xt_xa_fail(s, eq, ": unknown option (--xc-help lists them)");
    xt_xa_secret(s, eq, var);
    if (!xt_xa_known(var))
        xt_xa_fail(s, eq, ": unknown option (--xc-help lists them)");
    return eq;
    }

#ifndef XT_WIN64
int _xt_xcargs(int argc, char** argv)
    {
    int o = 1;
    int i = 1;
    if (argc < 1 || !argv)
        return argc;
    for (; i < argc; i++)
        {
        char* a = argv[i];
        if (a[0] == '-' && a[1] == '-' && a[2] == 0)
            break;
        if (!xt_xa_prefix(a, "--xc-"))
            {
            argv[o++] = a;
            continue;
            }
        char var[64];
        xt_xa_size n = xt_xa_len(a);
        xt_xa_size eq = xt_xa_parse(a, n, var, sizeof var);
        setenv(var, eq < n ? a + eq + 1 : "1", 1);
        }
    for (; i < argc; i++)
        argv[o++] = argv[i];
    for (int k = o; k < argc; k++)
        argv[k] = 0;
    return o;
    }
#else
// The command line's arguments, split as the runtime splits GetCommandLineA
// (rt-files.c): spaces and tabs separate, double quotes group and are not
// part of the argument. Each is found by its span [start, end) in the line.

// The next argument at or after *pos: its span, or 0 at the end.
static int xt_xa_next_w(const xt_xa_wchar* s, xt_xa_size* pos, xt_xa_size* start, xt_xa_size* end)
    {
    xt_xa_size p = *pos;
    while (s[p] == ' ' || s[p] == '\t')
        p++;
    if (!s[p])
        return 0;
    *start = p;
    int q = 0;
    while (s[p] && (q || (s[p] != ' ' && s[p] != '\t')))
        {
        if (s[p] == '"')
            q = !q;
        p++;
        }
    *end = p;
    *pos = p;
    return 1;
    }
static int xt_xa_next_a(const char* s, xt_xa_size* pos, xt_xa_size* start, xt_xa_size* end)
    {
    xt_xa_size p = *pos;
    while (s[p] == ' ' || s[p] == '\t')
        p++;
    if (!s[p])
        return 0;
    *start = p;
    int q = 0;
    while (s[p] && (q || (s[p] != ' ' && s[p] != '\t')))
        {
        if (s[p] == '"')
            q = !q;
        p++;
        }
    *end = p;
    *pos = p;
    return 1;
    }

// The argument at [b, e) without its quotes, into out (cap units, NUL-ended).
static xt_xa_size xt_xa_unquote_w(const xt_xa_wchar* s, xt_xa_size b, xt_xa_size e, xt_xa_wchar* out, xt_xa_size cap)
    {
    xt_xa_size o = 0;
    for (xt_xa_size k = b; k < e && o + 1 < cap; k++)
        if (s[k] != '"')
            out[o++] = s[k];
    out[o] = 0;
    return o;
    }

#define XT_XA_MAX 256
void _xt_xcargs(void)
    {
    xt_xa_wchar* w = GetCommandLineW();
    char* a = GetCommandLineA();
    if (!w)
        return;
    // Which arguments go, by index (0 is the program).
    unsigned char drop[XT_XA_MAX];
    int count = 0, any = 0;
    xt_xa_size pos = 0, b = 0, e = 0;
    while (count < XT_XA_MAX && xt_xa_next_w(w, &pos, &b, &e))
        {
        drop[count] = 0;
        if (count > 0)
            {
            xt_xa_wchar arg[1024];
            xt_xa_size n = xt_xa_unquote_w(w, b, e, arg, 1024);
            if (n == 2 && arg[0] == '-' && arg[1] == '-')
                {
                count++;
                break;
                }
            if (n >= 5 && arg[0] == '-' && arg[1] == '-' && arg[2] == 'x' && arg[3] == 'c' && arg[4] == '-')
                {
                // The name is ASCII or unknown: bytes for the lookup and the
                // messages, the value kept wide.
                char bytes[128];
                xt_xa_size m = 0;
                while (m < n && m < sizeof bytes - 1 && arg[m] != '=')
                    {
                    bytes[m] = arg[m] < 128 ? (char)arg[m] : '?';
                    m++;
                    }
                bytes[m] = 0;
                char var[64];
                xt_xa_size eq = xt_xa_parse(bytes, m, var, sizeof var);
                xt_xa_wchar wvar[64];
                xt_xa_size k = 0;
                for (; var[k]; k++)
                    wvar[k] = (xt_xa_wchar)var[k];
                wvar[k] = 0;
                static const xt_xa_wchar one[2] = {'1', 0};
                SetEnvironmentVariableW(wvar, eq < n ? arg + eq + 1 : one);
                drop[count] = 1;
                any = 1;
                }
            }
        count++;
        }
    if (!any)
        return;
    // Each dropped argument goes with the blanks before it, in both lines.
    // The ANSI line splits into the same arguments (it is the same line,
    // converted), so the indices agree.
    xt_xa_size r = 0, o = 0;
    int idx = 0;
    pos = 0;
    while (xt_xa_next_w(w, &pos, &b, &e))
        {
        if (!(idx < count && drop[idx]))
            for (xt_xa_size k = r; k < e; k++)
                w[o++] = w[k];
        r = e;
        idx++;
        }
    for (; w[r]; r++)
        w[o++] = w[r];
    w[o] = 0;
    if (!a)
        return;
    r = 0;
    o = 0;
    idx = 0;
    pos = 0;
    while (xt_xa_next_a(a, &pos, &b, &e))
        {
        if (!(idx < count && drop[idx]))
            for (xt_xa_size k = r; k < e; k++)
                a[o++] = a[k];
        r = e;
        idx++;
        }
    for (; a[r]; r++)
        a[o++] = a[r];
    a[o] = 0;
    }
#endif
