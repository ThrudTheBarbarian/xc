// rt-files.c — the file and process primitives behind support/generic/lib/
// Files.xc and Process.xc, for the freestanding x86-64 targets (Linux and
// Windows). CI task #81: neither host defined any of them, so a program that
// touched a file failed to LINK (`undefined symbol '_xt_file_size'`), and the
// two fixtures that exercise them were not-applicable there.
//
// A separate source from rt-freestanding.c, and a separate generated .s per
// target, because rtgen-win64.s was NOT produced by the recorded recipe (114
// hunks differ from a fresh run) and regenerating it wholesale would replace
// a runtime that works with one that has not been proven. This file's output
// is small and stands alone; regenerate BOTH after any edit:
//
//   clang -S -O1 -masm=intel -target x86_64-unknown-linux-gnu \
//         -fno-stack-protector -fomit-frame-pointer \
//         -fno-asynchronous-unwind-tables -fno-jump-tables \
//         -o support/x86_64/runtime/rtfiles-linux.s src/xtc/support-src/rt-files.c
//   clang -S -O1 -masm=intel -target x86_64-windows-gnu -DXT_WIN64 \
//         -fno-stack-protector -fomit-frame-pointer \
//         -fno-asynchronous-unwind-tables -fno-jump-tables \
//         -o support/win64/runtime/rtfiles-win64.s src/xtc/support-src/rt-files.c
//
// FREESTANDING: no #include. Linux reaches the kernel through the stubs in
// sys-linux.s; Windows through kernel32.dll, resolved by name from
// support/win64/win32-imports.map. The contract is rt.c's (the arm64 host):
//   open  -> handle >= 0, or -1        read/write -> bytes, or -1
//   size  -> bytes, or -1              exists/exists_exact -> 1 / 0
//   chmod_exec -> 0 on success         mkdir -> 0 on success, else -1
//   argc / argv(i) ("" out of range)   exit(code) never returns

typedef unsigned char uint8_t;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef long long int64_t;
typedef int int32_t;

#ifdef XT_WIN64
extern void* CreateFileA(const char* name, uint32_t access, uint32_t share, void* sec,
                         uint32_t disposition, uint32_t attrs, void* tmpl);
extern int ReadFile(void* h, void* buf, uint32_t n, uint32_t* got, void* ovl);
extern int WriteFile(void* h, const void* buf, uint32_t n, uint32_t* put, void* ovl);
extern int CloseHandle(void* h);
extern int SetFilePointerEx(void* h, int64_t dist, int64_t* newPos, uint32_t whence);
extern int GetFileSizeEx(void* h, int64_t* size);
extern uint32_t GetFileAttributesA(const char* name);
extern int CreateDirectoryA(const char* name, void* sec);
extern char* GetCommandLineA(void);
extern void ExitProcess(uint32_t code);
extern uint32_t GetEnvironmentVariableA(const char* name, char* buf, uint32_t n);

#define XT_MAX_FILES 64
static void* xt_files[XT_MAX_FILES]; // handle i+3 -> HANDLE
#define XT_INVALID_HANDLE ((void*)(int64_t)-1)

static int xt_plus(const char* mode)
    {
    return mode[1] == '+' || (mode[1] && mode[2] == '+');
    }

int32_t _xt_file_open(const char* path, const char* mode)
    {
    uint32_t access, disp;
    int append = 0;
    switch (mode[0])
        {
    case 'r':
        access = 0x80000000u;
        disp = 3;
        break; // GENERIC_READ, OPEN_EXISTING
    case 'w':
        access = 0x40000000u;
        disp = 2;
        break; // GENERIC_WRITE, CREATE_ALWAYS
    case 'a':
        access = 0x40000000u;
        disp = 4;
        append = 1;
        break; // GENERIC_WRITE, OPEN_ALWAYS
    default:
        return -1;
        }
    if (xt_plus(mode))
        access |= 0xC0000000u;
    void* h = CreateFileA(path, access, 1 | 2, 0, disp, 0x80, 0); // share read+write, NORMAL
    if (h == XT_INVALID_HANDLE)
        return -1;
    if (append)
        SetFilePointerEx(h, 0, 0, 2); // FILE_END
    for (int i = 0; i < XT_MAX_FILES; i++)
        if (!xt_files[i])
            {
            xt_files[i] = h;
            return i + 3;
            }
    CloseHandle(h);
    return -1;
    }
static void* xt_handle(int32_t fd)
    {
    if (fd < 3 || fd >= XT_MAX_FILES + 3)
        return 0;
    return xt_files[fd - 3];
    }
int32_t _xt_file_read(int32_t fd, uint8_t* buf, uint32_t n)
    {
    void* h = xt_handle(fd);
    uint32_t got = 0;
    if (!h)
        return -1;
    if (!ReadFile(h, buf, n, &got, 0))
        return -1;
    return (int32_t)got;
    }
int32_t _xt_file_write(int32_t fd, const uint8_t* buf, uint32_t n)
    {
    void* h = xt_handle(fd);
    uint32_t put = 0;
    if (!h)
        return -1;
    if (!WriteFile(h, buf, n, &put, 0))
        return -1;
    return (int32_t)put;
    }
void _xt_file_close(int32_t fd)
    {
    void* h = xt_handle(fd);
    if (!h)
        return;
    CloseHandle(h);
    xt_files[fd - 3] = 0;
    }
int32_t _xt_file_size(const char* path)
    {
    void* h = CreateFileA(path, 0x80000000u, 1 | 2, 0, 3, 0x80, 0);
    if (h == XT_INVALID_HANDLE)
        return -1;
    int64_t sz = -1;
    if (!GetFileSizeEx(h, &sz))
        sz = -1;
    CloseHandle(h);
    return (sz < 0 || sz > 0x7FFFFFFF) ? -1 : (int32_t)sz;
    }
int32_t _xt_file_exists(const char* path)
    {
    return GetFileAttributesA(path) != 0xFFFFFFFFu ? 1 : 0; // INVALID_FILE_ATTRIBUTES
    }
// NTFS is case-preserving and case-insensitive, like macOS: there is no exact
// spelling question the API can answer cheaply, so the plain answer stands.
int32_t _xt_file_exists_exact(const char* path)
    {
    return _xt_file_exists(path);
    }
// no execute bit on Windows
int32_t _xt_file_chmod_exec(const char* path)
    {
    (void)path;
    return 0;
    }
int32_t _xt_mkdir(const char* path)
    {
    return CreateDirectoryA(path, 0) ? 0 : -1;
    }

// argc/argv from the command line, split the way CommandLineToArgvW does for
// the simple cases: spaces separate, double quotes group. Parsed once, into
// a private copy, on the first call.
#define XT_MAX_ARGS 64
static char xt_cmd[4096];
static char* xt_argv_v[XT_MAX_ARGS];
static int xt_argc_v = -1;
static void xt_parse_args(void)
    {
    if (xt_argc_v >= 0)
        return;
    const char* s = GetCommandLineA();
    int n = 0, o = 0;
    while (*s && n < XT_MAX_ARGS && o < (int)sizeof xt_cmd - 1)
        {
        while (*s == ' ' || *s == '\t')
            s++;
        if (!*s)
            break;
        xt_argv_v[n++] = &xt_cmd[o];
        int q = 0;
        while (*s && (q || (*s != ' ' && *s != '\t')) && o < (int)sizeof xt_cmd - 1)
            {
            if (*s == '"')
                {
                q = !q;
                s++;
                continue;
                }
            xt_cmd[o++] = *s++;
            }
        xt_cmd[o++] = 0;
        }
    xt_argc_v = n;
    }
int32_t _xt_argc(void)
    {
    xt_parse_args();
    return xt_argc_v;
    }
const char* _xt_argv(int32_t i)
    {
    static const char* empty = "";
    xt_parse_args();
    if (i < 0 || i >= xt_argc_v)
        return empty;
    return xt_argv_v[i];
    }
// The whole argv table, for the crt to hand `main` (bug 143: crt-win64.s
// called main with whatever rcx/rdx held — "ARGC BAD" under wine).
char** _xt_argv_table(void)
    {
    xt_parse_args();
    return xt_argv_v;
    }
void _xt_exit(int32_t code)
    {
    ExitProcess((uint32_t)code);
    for (;;)
        {
        }
    }

// Platform.env(): the value, or "" when unset — rt.c's contract. A `-c`
// object keeps PlatformCore's reference where a whole program's dead-function
// elimination would have dropped it, so the win64 objlink cases failed at
// link with this undefined (bug 135).
static char xt_env[4096];
const char* _xt_getenv(const char* name)
    {
    uint32_t n = GetEnvironmentVariableA(name, xt_env, sizeof xt_env);
    if (n == 0 || n >= sizeof xt_env)
        return "";
    return xt_env;
    }

#else // ─────────────────────────── Linux ───────────────────────────
extern long _sys_open(const char* path, long flags, long mode);
extern long _sys_read(long fd, void* buf, uint64_t n);
extern long write(int fd, const void* buf, uint64_t n);
extern long _sys_close(long fd);
extern long _sys_lseek(long fd, long off, long whence);
extern long _sys_mkdir(const char* path, long mode);
extern long _sys_chmod(const char* path, long mode);
extern void _sys_exit(long code);

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREAT 0x40
#define O_TRUNC 0x200
#define O_APPEND 0x400

static int xt_plus(const char* mode)
    {
    return mode[1] == '+' || (mode[1] && mode[2] == '+');
    }

int32_t _xt_file_open(const char* path, const char* mode)
    {
    long flags;
    switch (mode[0])
        {
    case 'r':
        flags = xt_plus(mode) ? O_RDWR : O_RDONLY;
        break;
    case 'w':
        flags = (xt_plus(mode) ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC;
        break;
    case 'a':
        flags = (xt_plus(mode) ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND;
        break;
    default:
        return -1;
        }
    long fd = _sys_open(path, flags, 0644);
    return fd < 0 ? -1 : (int32_t)fd;
    }
int32_t _xt_file_read(int32_t fd, uint8_t* buf, uint32_t n)
    {
    long got = _sys_read(fd, buf, n);
    return got < 0 ? -1 : (int32_t)got;
    }
int32_t _xt_file_write(int32_t fd, const uint8_t* buf, uint32_t n)
    {
    long put = write(fd, buf, n);
    return put < 0 ? -1 : (int32_t)put;
    }
void _xt_file_close(int32_t fd)
    {
    _sys_close(fd);
    }
int32_t _xt_file_size(const char* path)
    {
    long fd = _sys_open(path, O_RDONLY, 0);
    if (fd < 0)
        return -1;
    long end = _sys_lseek(fd, 0, 2); // SEEK_END
    _sys_close(fd);
    return (end < 0 || end > 0x7FFFFFFF) ? -1 : (int32_t)end;
    }
int32_t _xt_file_exists(const char* path)
    {
    long fd = _sys_open(path, O_RDONLY, 0);
    if (fd < 0)
        return 0;
    _sys_close(fd);
    return 1;
    }
// Linux filesystems are case-sensitive, so the exact-spelling question is
// the plain one — the same reasoning as XTOS's in libxt-pic.c.
int32_t _xt_file_exists_exact(const char* path)
    {
    return _xt_file_exists(path);
    }
int32_t _xt_file_chmod_exec(const char* path)
    {
    return _sys_chmod(path, 0755) < 0 ? -1 : 0;
    }
int32_t _xt_mkdir(const char* path)
    {
    return _sys_mkdir(path, 0755) < 0 ? -1 : 0;
    }

// Captured by crt-linux.s before it calls main: the kernel hands _start
// argc at [rsp] and argv above it, and the crt stores them here.
int32_t _xt_saved_argc;
char** _xt_saved_argv;
int32_t _xt_argc(void)
    {
    return _xt_saved_argc;
    }
const char* _xt_argv(int32_t i)
    {
    static const char* empty = "";
    if (i < 0 || i >= _xt_saved_argc || !_xt_saved_argv)
        return empty;
    return _xt_saved_argv[i];
    }
void _xt_exit(int32_t code)
    {
    _sys_exit(code);
    for (;;)
        {
        }
    }

// Platform.env() on Linux is sys-linux.s's _xt_getenv (a call into musl's
// getenv, NULL mapped to ""), so it is deliberately NOT here — a second
// definition is a hard link error, not a fallback.
#endif
