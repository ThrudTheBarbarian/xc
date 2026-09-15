// rt-freestanding.c — SOURCE for the object runtime of the self-hosted x86-64
// targets, BOTH Linux and Windows. It is compiled to assembly ONCE per target,
// by hand, and the .s files are checked in; a user compile never runs clang.
// Same arrangement as support/arm64/runtime/rt-macos.s, generated from rt.c.
//
// Regenerate BOTH after any edit:
//   clang -S -O1 -masm=intel -target x86_64-unknown-linux-gnu \
//         -fno-stack-protector -fomit-frame-pointer \
//         -fno-asynchronous-unwind-tables -fno-jump-tables \
//         -DXT_SINIT_C_INCLUDED=1 -DXT_NO_WEAK_SEAM=1 \
//         -o support/x86_64/runtime/rtgen-linux.s \
//         src/xtc/support-src/rt-freestanding.c
//   (then re-apply the hand-applied pieces the header of that file lists)
//   clang -S -O1 -masm=intel -target x86_64-windows-gnu -DXT_WIN64 \
//         -fno-stack-protector -fomit-frame-pointer \
//         -fno-asynchronous-unwind-tables -fno-jump-tables \
//         -o support/win64/runtime/rtgen-win64.s \
//         src/xtc/support-src/rt-freestanding.c
//
// One source, two ABIs: the object runtime, allocator, PRNG and clock are
// identical logic, and clang emits System V or Microsoft x64 register usage from
// the target triple. Only the four OS primitives differ, and they are the only
// thing #ifdef'd — everything below that line is shared.
//
// FREESTANDING: no #include at all, because there is no target libc on the build
// host to include from and none in the output. Linux reaches the kernel through
// the raw syscall stubs in sys-linux.s; Windows has no stable syscall ABI, so it
// goes through kernel32.dll, which the PE import table resolves.
//
// The layout constants are the SAME ONES rt.c defines, repeated here because
// the two runtimes are separate translation units with no shared header. If
// you change one, change the other — bug 027's "duplicated contract lists
// drift" is exactly this, and the refcount width is now in both.
#define XT_RC_BYTES 4
#define XT_RC_OFF 36
#define XT_HDR (XT_RC_OFF + XT_RC_BYTES) /* 40 */
#define XT_RC_T uint32_t
#define XT_RC_DYING 0x80000000U

// Object header, matching every other backend: 40 bytes, magic 0x58544F42 at
// base, stride at +4, count at +12, destructor at +20, weak-list head at +28,
// u32 refcount at +36 (i.e. at obj-4) — see the layout note in rt.c.

typedef unsigned char uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t; // long is 32-bit under Windows LLP64
typedef long long int64_t;
typedef int int32_t; // the threading primitives' i32 contract

// ─────────────────── the OS primitives, and only these ───────────────────
#ifdef XT_WIN64
// kernel32.dll. On x86-64 Windows there is a single calling convention, so no
// __stdcall decoration is needed and the names are undecorated.
extern void* GetStdHandle(uint32_t nStdHandle);
extern int WriteFile(void* h, const void* buf, uint32_t n, uint32_t* wrote, void* ovl);
extern void* VirtualAlloc(void* addr, uint64_t size, uint32_t type, uint32_t protect);
extern void GetSystemTimeAsFileTime(uint64_t* ft);
extern void Sleep(uint32_t ms);
extern uint32_t GetCurrentProcessId(void);

// POSIX getpid, which Windows spells GetCurrentProcessId. mingw's libc used to
// bridge the two, so this only became visible when the in-house path stopped
// falling back to mingw — there is no libc there to borrow from. Same reasoning
// as write() below: supply the name the xtc libraries and programs already call.
int getpid(void)
    {
    return (int)GetCurrentProcessId();
    }

// The xtc libraries call write(1, …) directly, so supply it rather than
// rewriting every call site.
long write(int fd, const void* buf, uint64_t count)
    {
    uint32_t wrote = 0;
    // STD_OUTPUT_HANDLE = -11, STD_ERROR_HANDLE = -12.
    WriteFile(GetStdHandle(fd == 2 ? (uint32_t)-12 : (uint32_t)-11),
              buf, (uint32_t)count, &wrote, 0);
    return (long)wrote;
    }
// MEM_COMMIT|MEM_RESERVE = 0x3000, PAGE_READWRITE = 4.
static void* xt_os_alloc(uint64_t bytes)
    {
    return VirtualAlloc(0, bytes, 0x3000, 4);
    }
// FILETIME counts 100ns ticks; the epoch differs from Unix's but every use here
// is a DIFFERENCE, so the offset cancels.
static double xt_now_secs(void)
    {
    uint64_t ft = 0;
    GetSystemTimeAsFileTime(&ft);
    return (double)ft * 1e-7;
    }
static void xt_os_sleep_ns(uint64_t ns)
    {
    Sleep((uint32_t)(ns / 1000000ULL));
    }
#else
// ── from sys-linux.s ──
extern long _sys_mmap(void* addr, uint64_t len, long prot, long flags, long fd, long off);
extern long _sys_clock_gettime(long clockid, void* ts);
extern long _sys_nanosleep(const void* req, void* rem);
extern long write(int fd, const void* buf, uint64_t count);

static void* xt_os_alloc(uint64_t bytes)
    {
    // PROT_READ|PROT_WRITE = 3, MAP_PRIVATE|MAP_ANONYMOUS = 0x22
    long p = _sys_mmap(0, bytes, 3, 0x22, -1, 0);
    if (p < 0 && p > -4096)
        return 0; // syscalls return -errno
    return (void*)p;
    }
// struct timespec is { long tv_sec; long tv_nsec; } on x86-64 Linux.
static double xt_now_secs(void)
    {
    long ts[2];
    _sys_clock_gettime(1 /* CLOCK_MONOTONIC */, ts);
    return (double)ts[0] + (double)ts[1] * 1e-9;
    }
static void xt_os_sleep_ns(uint64_t ns)
    {
    long req[2];
    req[0] = (long)(ns / 1000000000ULL);
    req[1] = (long)(ns % 1000000000ULL);
    _sys_nanosleep(req, 0);
    }
#endif
// ───────────────────── everything below is shared ─────────────────────

// ─────────────────────── the runtime's own locking ───────────────────────
// Defined with the threading primitives at the end of this file. Both are a
// single predictable load-and-branch until the program's first thread exists,
// so a single-threaded program pays almost nothing for them.
//
//   _xt_rt_lock    — the weak-reference intrusive list
//   _xt_alloc_lock — the allocator's arenas and free lists
//
// TWO locks, not one: an allocation while holding the weak lock would deadlock
// on a non-recursive spin lock, and separating them also keeps the common case
// (allocate on one thread, drop a weak reference on another) uncontended.
void _xt_rt_lock(void);
void _xt_rt_unlock(void);
void _xt_alloc_lock(void);
void _xt_alloc_unlock(void);

// ───────────────────────────── allocator ─────────────────────────────
// Bump allocation out of mmap'd arenas, with power-of-two size classes recycled
// through free lists. Freed blocks are reused but arenas are never returned to
// the kernel: a compiler test binary is short-lived, and a coalescing allocator
// would cost more than it saves here. Each block carries its class in an 8-byte
// prefix so _xt_free knows which list to push it onto.
#define NCLASS 28
static void* xt_freelist[NCLASS];
static uint8_t *xt_cur, *xt_end;

static void* xt_bump(uint64_t n)
    {
    if (xt_cur + n > xt_end)
        {
        uint64_t want = n + 0xFFFFFUL;
        want &= ~0xFFFFFUL; // whole megabytes
        if (want < (1UL << 20))
            want = 1UL << 20;
        void* p = xt_os_alloc(want);
        if (!p)
            return 0;
        xt_cur = (uint8_t*)p;
        xt_end = xt_cur + want;
        }
    void* r = xt_cur;
    xt_cur += n;
    return r;
    }

#ifndef XT_WIN64
// On Linux/x86-64 the libc pool (musl) is ALWAYS in the link, so the xtc
// heap delegates to calloc/free: ONE heap for xtc `new`, library malloc and
// any whole-image override (mimalloc as a plain object — blewit's startup
// probe refuses a split heap, and it is right to: a split is cross-allocator
// free() waiting to happen). This restores the pre-in-house contract, where
// the clang-path stub mapped _xtc_* onto calloc. The freelist below survives
// for the win64 build only.
extern void* calloc(uint64_t, uint64_t);
extern void free(void*);
void* _xt_calloc(uint64_t n)
    {
    return calloc(1, n);
    }
void _xt_free(void* q)
    {
    if (q)
        free(q);
    }
#endif
#ifdef XT_WIN64
void* _xt_calloc(uint64_t n)
    {
    uint64_t need = n + 8;
    int c = 0;
    uint64_t sz = 16;
    while (sz < need && c < NCLASS - 1)
        {
        sz <<= 1;
        c++;
        }
    if (sz < need)
        return 0; // larger than the largest class
    // The free-list pop and the bump pointer are shared state the moment a
    // second thread exists: two threads popping the same class would both take
    // the same block. Only the list surgery is locked — the zeroing below is on
    // memory nobody else can reach yet.
    _xt_alloc_lock();
    void* p = xt_freelist[c];
    if (p)
        xt_freelist[c] = *(void**)p;
    else
        p = xt_bump(sz);
    _xt_alloc_unlock();
    if (!p)
        return 0;
    *(uint64_t*)p = (uint64_t)c;
    uint8_t* u = (uint8_t*)p + 8;
    for (uint64_t i = 0; i < n; i++)
        u[i] = 0; // calloc semantics: ARC relies
    return u;     //   on ivars starting zeroed
    }

void _xt_free(void* q)
    {
    if (!q)
        return;
    void* p = (uint8_t*)q - 8;
    uint64_t c = *(uint64_t*)p;
    if (c >= NCLASS)
        return; // not ours / already corrupted
    _xt_alloc_lock();
    *(void**)p = xt_freelist[c];
    xt_freelist[c] = p;
    _xt_alloc_unlock();
    }
#endif // XT_WIN64 (the freelist allocator)

// ───────────────────────────── memset ─────────────────────────────
// The backend lowers XTIROpMemSet to a `call memset`, so one has to exist. The
// destination is volatile so clang cannot recognise the loop as the memset idiom
// and emit a call to the function it is compiling.
void* memset(void* dst, int c, uint64_t n)
    {
    volatile uint8_t* p = (volatile uint8_t*)dst;
    for (uint64_t i = 0; i < n; i++)
        p[i] = (uint8_t)c;
    return dst;
    }

// ───────────── _xt_fmt_f — the ONE fixed form the library calls ─────────────
// Stdio.xc calls this as _xt_fmt_f(buf, 96, "%.*f", prec, v) from emitFloat and
// nowhere else, so `fmt` and `size` are accepted and ignored; a general printf
// would be dead weight in every binary.
//
// It was called `snprintf` until #1177, which was a silent-wrong-answer bug
// rather than a naming quibble: squatting on the libc name meant a program that
// called snprintf normally got THIS instead, and since the format is ignored,
// snprintf(buf, 64, "hello", …) returned 1 and wrote "0". On x86-64 it also
// shadowed the real musl snprintf that the link already had available. The
// private name frees the public one — see support/x86_64/lib/Stdio.xc.
//
// Digits come out by repeated multiply-and-truncate rather than by scaling the
// whole fraction by 10^prec, which would overflow 64 bits well before the 18
// digits emitFloat asks for. That means this TRUNCATES where a real libc
// rounds — which is the right behaviour here, not a shortcut: emitFloat
// deliberately requests prec+8 digits and then cuts the string back to prec,
// because the cross-arch oracle expects truncation (%.3f of 3.566666 is
// "3.566"), so the extra digits absorb the difference.
int _xt_fmt_f(char* buf, uint32_t size, const char* fmt, int prec, double v)
    {
    (void)size;
    (void)fmt;
    char* p = buf;
    if (prec < 0)
        prec = 0;
    if (prec > 24)
        prec = 24; // more digits than a double carries
    if (v < 0.0)
        {
        *p++ = '-';
        v = -v;
        }

    int64_t ip = (int64_t)v; // truncates; v >= 0 here
    double frac = v - (double)ip;

    // Integer digits arrive least-significant first, so build them backwards.
    char tmp[24];
    int n = 0;
    do
        {
        tmp[n++] = (char)('0' + (int)(((uint64_t)ip) % 10ULL));
        ip = (int64_t)(((uint64_t)ip) / 10ULL);
        } while (ip != 0 && n < 24);
    while (n > 0)
        *p++ = tmp[--n];

    if (prec > 0)
        {
        *p++ = '.';
        for (int i = 0; i < prec; i++)
            {
            frac *= 10.0;
            int d = (int)frac;
            if (d > 9)
                d = 9; // rounding drift can reach 10
            if (d < 0)
                d = 0;
            *p++ = (char)('0' + d);
            frac -= (double)d;
            }
        }
    *p = 0; // NUL-terminate, as snprintf does
    return (int)(p - buf);
    }

// ───────────────────────── object runtime (per rt.c) ─────────────────────────
void* _xtc_alloc(uint64_t count, uint64_t stride, void (*dealloc)(void*))
    {
    /* An allocation too large to satisfy returns NULL — it does not quietly
       become a small one. `b > (16UL << 20) -> b = 256` handed back a 256-byte
       block for any request over 16 MB and the caller wrote straight past it.
       A minimum block size is fine; a silent maximum is not. */
    if (count < 1)
        count = 1;
    uint64_t b = count * stride;
    if (b < 256)
        b = 256;
    uint8_t* p = (uint8_t*)_xt_calloc(b + XT_HDR);
    if (!p)
        return 0;
    *(uint32_t*)(p + 0) = 0x58544F42U;
    *(uint64_t*)(p + 4) = stride;
    *(uint64_t*)(p + 12) = count;
    *(void (**)(void*))(p + 20) = dealloc;
    *(void**)(p + 28) = 0;
    *(XT_RC_T*)(p + XT_RC_OFF) = 1;
    return p + XT_HDR;
    }
/* One element is its own width, not eight — an 8x waste that also hit the
   (now removed) ceiling eight times sooner than the element count suggested. */
void* _xtc_new_u8(uint64_t n)
    {
    return _xtc_alloc(n, 1, 0);
    }
void* _xtc_new_i8(uint64_t n)
    {
    return _xtc_alloc(n, 1, 0);
    }
void* _xtc_new_u16(uint64_t n)
    {
    return _xtc_alloc(n, 2, 0);
    }
void* _xtc_new_i16(uint64_t n)
    {
    return _xtc_alloc(n, 2, 0);
    }
void* _xtc_new_u32(uint64_t n)
    {
    return _xtc_alloc(n, 4, 0);
    }
void* _xtc_new_i32(uint64_t n)
    {
    return _xtc_alloc(n, 4, 0);
    }
void* _xtc_new_pointer(uint64_t n)
    {
    return _xtc_alloc(n, 8, 0);
    }
void* _xtc_new_bool(uint64_t n)
    {
    return _xtc_alloc(n, 1, 0);
    }
void* _xtc_new_float(uint64_t n)
    {
    return _xtc_alloc(n, 4, 0);
    }
void* _xtc_new_double(uint64_t n)
    {
    return _xtc_alloc(n, 8, 0);
    }
void* _xtc_new_string(uint64_t n)
    {
    return _xtc_alloc(n, 8, 0);
    }

void _xtc_weak_zero_for(void*);
/* The element count of a `new T[N]` allocation, read from the header the
   allocator wrote (count at base+12, payload at base+XT_HDR). The `.length` of a
   runtime-sized heap array — private:docs/bugs/045 remedy 1. u16 by the language's
   `.length` contract. */
uint16_t _xtc_count(void* o)
    {
    return (uint16_t)*(uint64_t*)((uint8_t*)o - XT_HDR + 12);
    }

void _xtc_dealloc(void* o)
    {
    _xtc_weak_zero_for(o);
    uint8_t* base = (uint8_t*)o - XT_HDR;
    uint64_t stride = *(uint64_t*)(base + 4);
    uint64_t count = *(uint64_t*)(base + 12);
    void (*d)(void*) = *(void (**)(void*))(base + 20);
    if (d)
        {
        // Mark the refcount as "in teardown" so a release inside the destructor
        // cannot re-enter this path.
        *(XT_RC_T*)((uint8_t*)o - XT_RC_BYTES) = XT_RC_DYING;
        for (uint64_t i = 0; i < count; i++)
            d((uint8_t*)o + i * stride);
        }
    _xt_free(base);
    }

#define _XT_WH(o) (*(void***)((uint8_t*)(o) - (XT_HDR - 28)))
// The intrusive list is the one piece of runtime state two threads can splice
// at once (private:docs/Design/threading.md §4.4), so every operation runs under the
// runtime lock. xt_weak_unreg is the unlocked body, so register can unlink and
// relink without dropping the lock in between.
static void xt_weak_unreg(void** slot)
    {
    void*** pp = (void***)slot[-2];
    if (!pp)
        return;
    /* Back-pointer invariant: *pprev == slot for a validly-linked slot. Stale
       union bytes can leave a non-null but bogus pprev; writing through it
       faults (bug 176). Verify before unlinking. */
    if (*pp != slot)
        {
        slot[-2] = 0;
        slot[-1] = 0;
        return;
        }
    void** nx = (void**)slot[-1];
    *pp = nx;
    if (nx)
        nx[-2] = (void*)pp;
    slot[-2] = 0;
    slot[-1] = 0;
    }
void _xtc_weak_unregister(void** slot)
    {
    _xt_rt_lock();
    xt_weak_unreg(slot);
    _xt_rt_unlock();
    }
void _xtc_weak_register(void** slot, void* obj)
    {
    _xt_rt_lock();
    xt_weak_unreg(slot);
    if (!obj || *(uint32_t*)((uint8_t*)obj - XT_HDR) != 0x58544F42U)
        {
        _xt_rt_unlock();
        return;
        }
    void** nx = _XT_WH(obj);
    slot[-2] = (void*)&_XT_WH(obj);
    slot[-1] = (void*)nx;
    if (nx)
        nx[-2] = (void*)&slot[-1];
    _XT_WH(obj) = slot;
    _xt_rt_unlock();
    }
void* _xtc_weak_load(void** slot)
    {
    return *slot;
    }
void _xtc_weak_zero_for(void* obj)
    {
    if (!obj)
        return;
    _xt_rt_lock();
    void** s = _XT_WH(obj);
    while (s)
        {
        void** nx = (void**)s[-1];
        *s = 0;
        s[-2] = 0;
        s[-1] = 0;
        s = nx;
        }
    _XT_WH(obj) = 0;
    _xt_rt_unlock();
    }

// ── console: nothing here ──
// rt.c defines _putc and the _xtc_p* float printers because the macOS/arm9 paths
// need them. On x86-64 the xtc standard library provides both itself — Stdio.xc
// has its own _putc and does float formatting in emitFloat — so defining them
// here would be a duplicate symbol, which the linker now rejects outright rather
// than silently letting one win.

// ───────────────────────────── PRNG ─────────────────────────────
// The xtc libraries call srandom/random directly (they are declared as libc in
// Math.xc). With no libc we supply them: a 64-bit xorshift, masked to the
// 31-bit range POSIX random() promises so callers' modulo arithmetic behaves.
static uint64_t xt_rand_state = 1;
void srandom(uint32_t seed)
    {
    xt_rand_state = seed ? (uint64_t)seed : 1UL;
    }
long random(void)
    {
    uint64_t x = xt_rand_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    xt_rand_state = x;
    return (long)((x >> 17) & 0x7FFFFFFFUL);
    }
void _xt_srand(uint32_t seed)
    {
    srandom(seed);
    }
uint32_t _xt_rand_u32(void)
    {
    return ((uint32_t)random() << 16) ^ (uint32_t)random();
    }
float _xt_rand_f(void)
    {
    return 0.5f + ((float)random() / 2147483648.0f) * 0.5f;
    }
double _xt_rand_d(void)
    {
    return 0.5 + ((double)random() / 2147483648.0) * 0.5;
    }

// ───────────────────────────── clock ─────────────────────────────
static double xt_clk_origin;
void _xt_clk_reset(void)
    {
    xt_clk_origin = xt_now_secs();
    }
uint32_t _xt_clk_ticks(void)
    {
    return (uint32_t)((xt_now_secs() - xt_clk_origin) * 1.0e6);
    }
void _xt_clk_delay(uint32_t jiffies)
    {
    xt_os_sleep_ns((uint64_t)((double)jiffies / 60.0 * 1.0e9));
    }

// ───────────────────────────── banks ─────────────────────────────
static void* xt_bank_regions[3][256];
void* _xtc_bank(uint8_t type, uint8_t idx)
    {
    if (type > 1)
        return 0;
    if (!xt_bank_regions[type][idx])
        xt_bank_regions[type][idx] = _xt_calloc(12288);
    return xt_bank_regions[type][idx];
    }

// ─────────────────────────── threading ───────────────────────────
// private:docs/Design/threading.md Phase 2, for the two freestanding x86-64 targets.
// Same `_xt_*` contract the macOS runtime implements over pthreads
// (support/arm64/runtime/xt-threads.c) — the xtc library classes in
// support/generic/lib/ are identical on every host; only these bodies differ.
//
// Windows gets it nearly free: kernel32 exports threads, SRW locks, condition
// variables, semaphores and TLS. Linux here has no libc at all, so a thread is
// a raw `clone` (the stub in sys-linux.s) and everything that blocks is a futex.

// A retain/release, an allocator push/pop, and the weak list are all shared
// mutable state once a second thread exists. `_xt_threads_active` gates the
// runtime's own locking so a single-threaded program pays a predictable
// load-and-branch instead of a lock.
int _xt_threads_active = 0;
int32_t _xt_threads_multi(void)
    {
    return (int32_t)_xt_threads_active;
    }

// The runtime lock is a test-and-set spinlock rather than an OS mutex: the
// regions it covers are a handful of instructions (a free-list push, a
// list splice), so a blocking primitive would cost more than the wait.
static volatile int xt_rt_spin = 0;
static void xt_spin_lock(volatile int* l)
    {
    while (__atomic_exchange_n(l, 1, __ATOMIC_ACQUIRE))
        {
        while (__atomic_load_n(l, __ATOMIC_RELAXED))
            {
            }
        }
    }
static void xt_spin_unlock(volatile int* l)
    {
    __atomic_store_n(l, 0, __ATOMIC_RELEASE);
    }
void _xt_rt_lock(void)
    {
    if (_xt_threads_active)
        xt_spin_lock(&xt_rt_spin);
    }
void _xt_rt_unlock(void)
    {
    if (_xt_threads_active)
        xt_spin_unlock(&xt_rt_spin);
    }

static volatile int xt_alloc_spin = 0;
void _xt_alloc_lock(void)
    {
    if (_xt_threads_active)
        xt_spin_lock(&xt_alloc_spin);
    }
void _xt_alloc_unlock(void)
    {
    if (_xt_threads_active)
        xt_spin_unlock(&xt_alloc_spin);
    }

#ifdef XT_WIN64
// ── Windows: kernel32 does all of it ──
extern void* CreateThread(void* sa, uint64_t stack, void* start, void* param,
                          uint32_t flags, uint32_t* tid);
extern uint32_t WaitForSingleObject(void* h, uint32_t ms);
extern int CloseHandle(void* h);
extern uint32_t GetCurrentThreadId(void);
extern void GetSystemInfo(void* si);
extern void InitializeSRWLock(void** lock);
extern void AcquireSRWLockExclusive(void** lock);
extern void ReleaseSRWLockExclusive(void** lock);
extern uint8_t TryAcquireSRWLockExclusive(void** lock);
extern void InitializeConditionVariable(void** cv);
extern int SleepConditionVariableSRW(void** cv, void** lock, uint32_t ms, uint32_t flags);
extern void WakeConditionVariable(void** cv);
extern void WakeAllConditionVariable(void** cv);
extern void* CreateSemaphoreA(void* sa, long initial, long maximum, const char* name);
extern int ReleaseSemaphore(void* h, long release, long* prev);
extern uint32_t TlsAlloc(void);
extern void* TlsGetValue(uint32_t idx);
extern int TlsSetValue(uint32_t idx, void* v);
extern void SwitchToThread(void);

void _xt_thread_exiting(void);
typedef struct
    {
    void* code;
    void* recv;
    } xt_start_t;

// CreateThread's start routine takes one pointer and returns a DWORD; the
// bound-method ABI is `code(recv)`, so this is the whole adaptation.
static uint32_t xt_thread_entry(void* p)
    {
    xt_start_t s = *(xt_start_t*)p;
    _xt_free(p);
    if (s.code)
        ((void (*)(void*))s.code)(s.recv);
    _xt_thread_exiting(); // per-thread teardown (xt-thread-exit.c)
    return 0;
    }

void* _xt_thread_create(void* code, void* recv)
    {
    if (!code)
        return 0;
#ifndef XT_WIN64
        // musl guards its allocator (and stdio, and every other lock) with
        // libc.need_locks, which only ITS pthread_create sets — our threads are a
        // raw clone, so without this the first two concurrent callocs race
        // mallocng's metadata and die in __malloc_allzerop. Set the whole
        // "threads exist" cluster before the first clone: threaded (byte 1),
        // need_locks (byte 3), threads_minus_1 (bytes 4..8). Never cleared — a
        // process that has threaded once stays locked, which is the safe side.
        {
        char* lc = _xt_libc_addr();
        lc[1] = 1;
        *(volatile signed char*)(lc + 3) = 1;
        *(int*)(lc + 4) = 1;
        }
#endif
    _xt_threads_active = 1;
    xt_start_t* s = (xt_start_t*)_xt_calloc(sizeof *s);
    if (!s)
        return 0;
    s->code = code;
    s->recv = recv;
    void* h = CreateThread(0, 0, (void*)xt_thread_entry, s, 0, 0);
    if (!h)
        {
        _xt_free(s);
        return 0;
        }
    return h;
    }
int32_t _xt_thread_join(void* h)
    {
    if (!h)
        return -1;
    WaitForSingleObject(h, 0xFFFFFFFFu); // INFINITE
    CloseHandle(h);
    return 0;
    }
void _xt_thread_detach(void* h)
    {
    if (h)
        CloseHandle(h);
    }
void _xt_thread_yield(void)
    {
    SwitchToThread();
    }
void _xt_thread_sleep_ms(uint32_t ms)
    {
    Sleep(ms);
    }
uint32_t _xt_thread_self_id(void)
    {
    return GetCurrentThreadId();
    }
int32_t _xt_thread_cpu_count(void)
    {
    // SYSTEM_INFO's dwNumberOfProcessors sits at offset 32 in the 64-bit
    // layout; the struct is 48 bytes. Reading the one field we want out of a
    // byte buffer avoids declaring the whole thing.
    uint8_t si[64];
    for (int i = 0; i < 64; i++)
        si[i] = 0;
    GetSystemInfo(si);
    uint32_t n = *(uint32_t*)(si + 32);
    return n ? (int32_t)n : 1;
    }

// SRWLock and CONDITION_VARIABLE are each one pointer-sized word, initialised
// by their Initialize* call — no destroy exists, so free is just a free.
void* _xt_mutex_new(void)
    {
    void** m = (void**)_xt_calloc(sizeof(void*));
    if (m)
        InitializeSRWLock(m);
    return m;
    }
void _xt_mutex_free(void* m)
    {
    _xt_free(m);
    }
void _xt_mutex_lock(void* m)
    {
    if (m)
        AcquireSRWLockExclusive((void**)m);
    }
void _xt_mutex_unlock(void* m)
    {
    if (m)
        ReleaseSRWLockExclusive((void**)m);
    }
int32_t _xt_mutex_trylock(void* m)
    {
    return m && TryAcquireSRWLockExclusive((void**)m) ? 1 : 0;
    }

void* _xt_cond_new(void)
    {
    void** c = (void**)_xt_calloc(sizeof(void*));
    if (c)
        InitializeConditionVariable(c);
    return c;
    }
void _xt_cond_free(void* c)
    {
    _xt_free(c);
    }
void _xt_cond_wait(void* c, void* m)
    {
    if (c && m)
        SleepConditionVariableSRW((void**)c, (void**)m, 0xFFFFFFFFu, 0);
    }
void _xt_cond_signal(void* c)
    {
    if (c)
        WakeConditionVariable((void**)c);
    }
void _xt_cond_broadcast(void* c)
    {
    if (c)
        WakeAllConditionVariable((void**)c);
    }

void* _xt_sem_new(int32_t initial)
    {
    return CreateSemaphoreA(0, initial < 0 ? 0 : initial, 0x7FFFFFFF, 0);
    }
void _xt_sem_free(void* s)
    {
    if (s)
        CloseHandle(s);
    }
void _xt_sem_wait(void* s)
    {
    if (s)
        WaitForSingleObject(s, 0xFFFFFFFFu);
    }
void _xt_sem_post(void* s)
    {
    if (s)
        ReleaseSemaphore(s, 1, 0);
    }
int32_t _xt_sem_trywait(void* s)
    {
    return s && WaitForSingleObject(s, 0) == 0 ? 1 : 0; // WAIT_OBJECT_0
    }

uint32_t _xt_tls_new(void)
    {
    return TlsAlloc();
    }
void _xt_tls_set(uint32_t k, void* v)
    {
    TlsSetValue(k, v);
    }
void* _xt_tls_get(uint32_t k)
    {
    return TlsGetValue(k);
    }

#else
// ── Linux: clone + futex, and nothing else ──
extern long _sys_futex(void* uaddr, long op, long val, const void* timeout,
                       void* uaddr2, long val3);
extern long _sys_gettid(void);
extern long _sys_sched_yield(void);
extern long _sys_sched_getaffinity(long pid, uint64_t setsize, void* mask);
extern long _sys_munmap(void* addr, uint64_t len);
// (stack_top, flags, ctid, entry, arg) → tid, or -errno. See sys-linux.s.
extern long _sys_clone_thread(void* stack_top, long flags, void* ctid,
                              void* entry, void* arg, void* tls);
extern long _sys_arch_prctl(long code, void* addr);
extern void* _xt_tcb_get(void); // sys-linux.s: `mov rax, fs:[0]`

#define XT_FUTEX_WAIT 0 // FUTEX_WAIT | FUTEX_PRIVATE_FLAG is 128|0; the
#define XT_FUTEX_WAKE 1 // shared (non-private) ops work across processes
                        // too, and cost nothing extra here.
static void xt_futex_wait(volatile int* addr, int expect)
    {
    _sys_futex((void*)addr, XT_FUTEX_WAIT, expect, 0, 0, 0);
    }
static void xt_futex_wake(volatile int* addr, int n)
    {
    _sys_futex((void*)addr, XT_FUTEX_WAKE, n, 0, 0, 0);
    }

// CLONE_VM|FS|FILES|SIGHAND|THREAD|SYSVSEM|PARENT_SETTID|CHILD_CLEARTID.
// The last two are the pair that makes join possible without a libc:
// PARENT_SETTID writes the new tid into our word before clone returns, and
// CHILD_CLEARTID zeroes that same word and futex-wakes it when the thread
// dies. So joining is "wait until that word reads zero" — and with only
// CHILD_CLEARTID the word starts at zero, so join returns immediately and the
// thread's work is silently unfinished.
// …plus CLONE_SETTLS, which is what gives each thread its own context block
// (see _xt_tls_get). The kernel points `fs` at it before the child's first
// instruction, so a thread-local read is a load rather than a lookup.
#define XT_CLONE_FLAGS 0x3D0F00L
#define XT_STACK_BYTES (1024UL * 1024UL)

// One handle per spawned thread: the tid word the kernel clears, plus the
// stack to reclaim. Kept in the thread's OWN stack mapping would be neater,
// but then join could not read it after the mapping went away.
typedef struct xt_thread_s
    {
    volatile int tid; // kernel zeroes + futex-wakes this on exit
    void* stack;
    uint64_t stackBytes;
    struct xt_thread_s* next; // reap list; see xt_reap_sweep
    void* tcb;                // this thread's context block
    } xt_thread_t;

// ── the per-thread context block ─────────────────────────────────────────
// One pointer-sized slot per key, plus a self-pointer at offset 0 because that
// is where the `fs` register points and reading `fs:[0]` is how a thread finds
// its own block. Allocated per thread at spawn and handed to the kernel through
// CLONE_SETTLS; the process's first thread gets one lazily, via arch_prctl.
//
// This replaces a (tid, key) table walked under a spinlock — which capped the
// program at 64 threads, cost a scan per access, and left a dead thread's row
// behind forever. A slot read is now one instruction.
#define XT_TLS_KEYS 62 // TCB is one 512-byte block: self + 62 slots
typedef struct
    {
    void* self;
    void* slots[XT_TLS_KEYS];
    } xt_tcb_t;
// musl compatibility: `fs` points at this block, and musl members reach their
// per-thread state through __pthread_self() == fs:[0] == the block itself —
// errno_val at byte 52, locale at byte 168 (struct pthread, musl 1.2.5,
// sizeof 200). Two consequences, both load-bearing:
//   * TLS keys START AT 25 (xt_tls_next_key below), so our slots begin at
//     byte 208 — past musl's struct — and neither side can scribble on the
//     other. Keys 0-24 are simply never handed out.
//   * every tcb must carry a non-null LOCALE pointer at byte 168, aimed at
//     __libc's global_locale (byte 56 of the crt's __libc block): musl's
//     __lctrans_cur dereferences it on the first strerror/gettext, which is
//     how a static libpq link found all of this.
#define XT_MUSL_LOCALE_OFF 168
#define XT_MUSL_TSD_OFF 128
#define XT_MUSL_TSD_BYTES 1024 // PTHREAD_KEYS_MAX (128) pointers
#define XT_TLS_FIRST_KEY 25
// crt-linux.s owns __libc and __xt_tls_hdr; they are reached through these
// GETTERS rather than extern data because the generated .s must stay free of
// @GOTPCREL data references — the in-house assembler path has no GOT for .s
// source, and `-fno-pic`'s `mov r, offset sym` is a mnemonic form it does not
// parse either. A call is the one shape that is clean under every model.
extern char* _xt_libc_addr(void);    // &__libc; global_locale at +56
extern char* _xt_tls_hdr_addr(void); // &__xt_tls_hdr; [0..8)=R then image
// `tsd` (byte 128) backs pthread_{set,get}specific — mimalloc registers a
// thread-exit key and faulted on the NULL array. Spawned threads carry the
// array right after the tcb (one allocation); the main thread's is a static
// in the crt. Key DESTRUCTORS never run here — our threads are raw clone,
// not pthreads — so a library's per-thread state leaks at thread exit; a
// bounded pool makes that a non-issue, unbounded churn would not.
static void xt_tcb_musl_init(void* tcb, void* tsd)
    {
    *(void**)((char*)tcb + XT_MUSL_LOCALE_OFF) = (void*)(_xt_libc_addr() + 56);
    *(void**)((char*)tcb + XT_MUSL_TSD_OFF) = tsd;
    }
// Static local-exec TLS (mimalloc's __thread heap pointer): the linker fills
// __xt_tls_hdr — [0..8) = R, the 16-aligned per-thread block size (<= 240,
// a link-time hard error above that), then R image bytes. The block sits at
// [%fs - R, %fs), so every tcb needs R initialised bytes BELOW it. The crt
// copies the image under _xt_main_tcb (a 240-byte pad precedes it, in
// rtgen-linux.s); these two do the same for spawned threads. 248 = the pad a
// tcb allocation reserves; _xt_calloc's blocks are 16-aligned + 8-byte
// header, so tcb = raw + 248 is always 16-aligned, and free recovers the
// raw pointer with plain subtraction.
static void* _xt_tcb_alloc(void)
    {
    uint8_t* raw = (uint8_t*)_xt_calloc(256 + sizeof(xt_tcb_t) + XT_MUSL_TSD_BYTES);
    if (!raw)
        return 0;
    uint8_t* tcb = raw + 256; // calloc is 16-aligned, so the tcb is too
    char* hdr = _xt_tls_hdr_addr();
    uint64_t r = *(uint64_t*)hdr;
    uint8_t* blk = tcb - r;
    for (uint64_t i = 0; i < r; i++)
        blk[i] = (uint8_t)hdr[8 + i];
    xt_tcb_musl_init(tcb, tcb + sizeof(xt_tcb_t)); // tsd rides the same block
    return tcb;
    }
static void _xt_tcb_free(void* tcb)
    {
    if (tcb)
        _xt_free((uint8_t*)tcb - 256);
    }
static void xt_reap_sweep(void);
void _xt_thread_exiting(void);
typedef struct
    {
    void* code;
    void* recv;
    } xt_start_t;

// The clone stub calls this with the starter block; it must never return
// normally — the stub exits the thread when it does.
static void xt_thread_entry(void* p)
    {
    xt_start_t s = *(xt_start_t*)p;
    _xt_free(p);
    if (s.code)
        ((void (*)(void*))s.code)(s.recv);
    // The reason this seam exists at all: threads here are a raw `clone`, so
    // there is no pthread key and no destructor list an allocator could hook.
    _xt_thread_exiting();
    }

void* _xt_thread_create(void* code, void* recv)
    {
    if (!code)
        return 0;
#ifndef XT_WIN64
        // musl guards its allocator (and stdio, and every other lock) with
        // libc.need_locks, which only ITS pthread_create sets — our threads are a
        // raw clone, so without this the first two concurrent callocs race
        // mallocng's metadata and die in __malloc_allzerop. Set the whole
        // "threads exist" cluster before the first clone: threaded (byte 1),
        // need_locks (byte 3), threads_minus_1 (bytes 4..8). Never cleared — a
        // process that has threaded once stays locked, which is the safe side.
        {
        char* lc = _xt_libc_addr();
        lc[1] = 1;
        *(volatile signed char*)(lc + 3) = 1;
        *(int*)(lc + 4) = 1;
        }
#endif
    if (_xt_threads_active)
        xt_reap_sweep(); // return any detached-and-finished stacks
    _xt_threads_active = 1;
    void* stack = xt_os_alloc(XT_STACK_BYTES);
    if (!stack)
        return 0;
    xt_thread_t* h = (xt_thread_t*)_xt_calloc(sizeof *h);
    if (!h)
        return 0;
    h->stack = stack;
    h->stackBytes = XT_STACK_BYTES;
    xt_start_t* s = (xt_start_t*)_xt_calloc(sizeof *s);
    if (!s)
        return 0;
    s->code = code;
    s->recv = recv;
    xt_tcb_t* tcb = (xt_tcb_t*)_xt_tcb_alloc();
    if (!tcb)
        {
        _xt_free(s);
        _xt_free(h);
        return 0;
        }
    tcb->self = tcb; // `fs:[0]` reads this
    h->tcb = tcb;
    uint8_t* top = (uint8_t*)stack + XT_STACK_BYTES;
    top -= (uint64_t)top & 15UL; // 16-byte aligned
    long tid = _sys_clone_thread(top, XT_CLONE_FLAGS, (void*)&h->tid,
                                 (void*)xt_thread_entry, s, tcb);
    if (tid < 0)
        {
        _xt_free(s);
        _xt_tcb_free(tcb);
        _xt_free(h);
        return 0;
        }
    return h;
    }

int32_t _xt_thread_join(void* p)
    {
    if (!p)
        return -1;
    xt_thread_t* h = (xt_thread_t*)p;
    // The kernel writes 0 to h->tid and wakes it when the thread exits. Re-read
    // under the loop: a wake can be spurious, and the exit may have happened
    // before we ever waited.
    for (;;)
        {
        int t = __atomic_load_n(&h->tid, __ATOMIC_ACQUIRE);
        if (t == 0)
            break;
        xt_futex_wait(&h->tid, t);
        }
    if (h->stack)
        _sys_munmap(h->stack, h->stackBytes);
    if (h->tcb)
        _xt_tcb_free(h->tcb);
    _xt_free(h);
    return 0;
    }

// ── the reaper ───────────────────────────────────────────────────────────
// A detached thread's stack cannot be unmapped by the thread itself (it is
// standing on it) and there is no libc here to hang a thread-exit hook on. So
// detach hands the stack to a reap list instead, and the list is swept from
// somewhere the thread is provably gone: `h->tid` is the word the kernel
// ZEROES and futex-wakes when the thread dies (CLONE_CHILD_CLEARTID), so a
// zero there means the stack is nobody's and can be returned.
//
// Swept on every create and on every detach, which is where the memory
// pressure is: a program that detaches N threads over its life holds at most
// the stacks of those still RUNNING, instead of all N. A program that never
// detaches never touches any of this.
static xt_thread_t* xt_reap_head; // singly linked through ->next
static volatile int xt_reap_spin;

static void xt_reap_sweep(void)
    {
    xt_spin_lock(&xt_reap_spin);
    xt_thread_t** pp = &xt_reap_head;
    while (*pp)
        {
        xt_thread_t* h = *pp;
        if (__atomic_load_n(&h->tid, __ATOMIC_ACQUIRE) == 0)
            {
            *pp = h->next; // thread is gone: reclaim
            if (h->stack)
                _sys_munmap(h->stack, h->stackBytes);
            if (h->tcb)
                _xt_tcb_free(h->tcb);
            _xt_free(h);
            }
        else
            {
            pp = &h->next; // still running: leave it
            }
        }
    xt_spin_unlock(&xt_reap_spin);
    }

void _xt_thread_detach(void* p)
    {
    if (!p)
        return;
    xt_thread_t* h = (xt_thread_t*)p;
    // Already dead? Then this is the cheap path and nothing needs listing.
    if (__atomic_load_n(&h->tid, __ATOMIC_ACQUIRE) == 0)
        {
        if (h->stack)
            _sys_munmap(h->stack, h->stackBytes);
        if (h->tcb)
            _xt_tcb_free(h->tcb);
        _xt_free(h);
        return;
        }
    xt_spin_lock(&xt_reap_spin);
    h->next = xt_reap_head;
    xt_reap_head = h;
    xt_spin_unlock(&xt_reap_spin);
    xt_reap_sweep();
    }

void _xt_thread_yield(void)
    {
    _sys_sched_yield();
    }
void _xt_thread_sleep_ms(uint32_t ms)
    {
    xt_os_sleep_ns((uint64_t)ms * 1000000ULL);
    }
uint32_t _xt_thread_self_id(void)
    {
    return (uint32_t)_sys_gettid();
    }
// How many CPUs this process may run on. sched_getaffinity gives the honest
// answer (the cgroup/taskset-restricted set, not the machine's core count) and
// is one syscall with no libc behind it. A failure falls back to 1 rather than
// to a guess — a wrong LARGE number would size a thread pool wrongly.
int32_t _xt_thread_cpu_count(void)
    {
    uint64_t mask[16]; // 1024 CPUs' worth
    for (int i = 0; i < 16; i++)
        mask[i] = 0;
    long n = _sys_sched_getaffinity(0, sizeof mask, mask);
    if (n <= 0)
        return 1;
    int32_t cpus = 0;
    for (uint64_t i = 0; i < (uint64_t)n / 8 && i < 16; i++)
        for (int b = 0; b < 64; b++)
            if (mask[i] & (1ULL << b))
                cpus++;
    return cpus > 0 ? cpus : 1;
    }

// ── mutex: a 3-state futex lock (Drepper's) ──
//   0 = free, 1 = held with no waiters, 2 = held and someone is waiting.
// The uncontended paths are one CAS each and never enter the kernel.
typedef struct
    {
    volatile int state;
    } xt_mutex_t;

void* _xt_mutex_new(void)
    {
    return _xt_calloc(sizeof(xt_mutex_t));
    }
void _xt_mutex_free(void* m)
    {
    _xt_free(m);
    }

void _xt_mutex_lock(void* p)
    {
    if (!p)
        return;
    xt_mutex_t* m = (xt_mutex_t*)p;
    int c = 0;
    if (__atomic_compare_exchange_n(&m->state, &c, 1, 0,
                                    __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
        return;
    if (c != 2)
        c = __atomic_exchange_n(&m->state, 2, __ATOMIC_ACQUIRE);
    while (c != 0)
        {
        xt_futex_wait(&m->state, 2);
        c = __atomic_exchange_n(&m->state, 2, __ATOMIC_ACQUIRE);
        }
    }

void _xt_mutex_unlock(void* p)
    {
    if (!p)
        return;
    xt_mutex_t* m = (xt_mutex_t*)p;
    if (__atomic_fetch_sub(&m->state, 1, __ATOMIC_RELEASE) != 1)
        {
        __atomic_store_n(&m->state, 0, __ATOMIC_RELEASE);
        xt_futex_wake(&m->state, 1);
        }
    }

int32_t _xt_mutex_trylock(void* p)
    {
    if (!p)
        return 0;
    xt_mutex_t* m = (xt_mutex_t*)p;
    int c = 0;
    return __atomic_compare_exchange_n(&m->state, &c, 1, 0,
                                       __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)
               ? 1
               : 0;
    }

// ── condition variable over the same futex ──
// `seq` is bumped by every signal/broadcast; a waiter samples it before
// dropping the mutex and blocks only while it is unchanged, which is what
// closes the window between unlock and wait.
typedef struct
    {
    volatile int seq;
    } xt_cond_t;

void* _xt_cond_new(void)
    {
    return _xt_calloc(sizeof(xt_cond_t));
    }
void _xt_cond_free(void* c)
    {
    _xt_free(c);
    }

void _xt_cond_wait(void* cp, void* mp)
    {
    if (!cp || !mp)
        return;
    xt_cond_t* c = (xt_cond_t*)cp;
    int seq = __atomic_load_n(&c->seq, __ATOMIC_ACQUIRE);
    _xt_mutex_unlock(mp);
    xt_futex_wait(&c->seq, seq);
    _xt_mutex_lock(mp);
    }

void _xt_cond_signal(void* cp)
    {
    if (!cp)
        return;
    xt_cond_t* c = (xt_cond_t*)cp;
    __atomic_fetch_add(&c->seq, 1, __ATOMIC_RELEASE);
    xt_futex_wake(&c->seq, 1);
    }

void _xt_cond_broadcast(void* cp)
    {
    if (!cp)
        return;
    xt_cond_t* c = (xt_cond_t*)cp;
    __atomic_fetch_add(&c->seq, 1, __ATOMIC_RELEASE);
    xt_futex_wake(&c->seq, 0x7FFFFFFF);
    }

// ── counting semaphore, futex-backed ──
typedef struct
    {
    volatile int count;
    } xt_sem_t;

void* _xt_sem_new(int32_t initial)
    {
    xt_sem_t* s = (xt_sem_t*)_xt_calloc(sizeof *s);
    if (s)
        s->count = initial < 0 ? 0 : initial;
    return s;
    }
void _xt_sem_free(void* s)
    {
    _xt_free(s);
    }

void _xt_sem_wait(void* p)
    {
    if (!p)
        return;
    xt_sem_t* s = (xt_sem_t*)p;
    for (;;)
        {
        int c = __atomic_load_n(&s->count, __ATOMIC_ACQUIRE);
        if (c > 0)
            {
            if (__atomic_compare_exchange_n(&s->count, &c, c - 1, 0,
                                            __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
                return;
            continue; // lost the race; look again
            }
        xt_futex_wait(&s->count, 0);
        }
    }

int32_t _xt_sem_trywait(void* p)
    {
    if (!p)
        return 0;
    xt_sem_t* s = (xt_sem_t*)p;
    for (;;)
        {
        int c = __atomic_load_n(&s->count, __ATOMIC_ACQUIRE);
        if (c <= 0)
            return 0;
        if (__atomic_compare_exchange_n(&s->count, &c, c - 1, 0,
                                        __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
            return 1;
        }
    }

void _xt_sem_post(void* p)
    {
    if (!p)
        return;
    xt_sem_t* s = (xt_sem_t*)p;
    __atomic_fetch_add(&s->count, 1, __ATOMIC_RELEASE);
    xt_futex_wake(&s->count, 1);
    }

// ── thread-local storage, off the thread's own context block ─────────────
// A read is `fs:[0]` plus an index — no key lookup, no lock, no syscall, and no
// per-format TLS relocation, because the block is ordinary memory the kernel
// hands the thread a pointer to. The process's FIRST thread has no block until
// it asks for one: arch_prctl installs it lazily, which is safe because that
// thread is by definition alone when it runs this.
//
static uint32_t xt_tls_next_key = XT_TLS_FIRST_KEY; // 0-24 shadow musl's pthread struct
static volatile int xt_tls_keyspin;
// NOT static: crt-linux.s installs it as `fs` before main runs, which is what
// lets every later thread-local access be a plain load with no first-thread
// test. Zero-initialised like any other global, and its self-pointer is written
// by the crt.
xt_tcb_t _xt_main_tcb;

// Every thread has a block by the time any of this runs: the kernel gave the
// spawned ones theirs at clone, and the crt gave the first one its own before
// main. So this is a load, not a lookup — no key, no table, no lock, no
// syscall, and no per-format TLS relocation.
static xt_tcb_t* xt_tcb(void)
    {
    return (xt_tcb_t*)_xt_tcb_get();
    }

uint32_t _xt_tls_new(void)
    {
    xt_spin_lock(&xt_tls_keyspin);
    uint32_t k = xt_tls_next_key < (uint32_t)XT_TLS_KEYS ? xt_tls_next_key++ : 0xFFFFFFFFu;
    xt_spin_unlock(&xt_tls_keyspin);
    return k;
    }

void _xt_tls_set(uint32_t key, void* v)
    {
    if (key >= (uint32_t)XT_TLS_KEYS)
        return;
    xt_tcb()->slots[key] = v;
    }

void* _xt_tls_get(uint32_t key)
    {
    if (key >= (uint32_t)XT_TLS_KEYS)
        return 0;
    return xt_tcb()->slots[key];
    }
#endif // XT_WIN64

// ── atomics (shared) ──
// Sequentially consistent, matching the macOS runtime. These are the `Atomic`
// class's bodies; the ARC refcount is emitted inline by the backend instead.
int32_t _xt_atomic_load_i32(void* p)
    {
    return p ? __atomic_load_n((int32_t*)p, __ATOMIC_SEQ_CST) : 0;
    }
void _xt_atomic_store_i32(void* p, int32_t v)
    {
    if (p)
        __atomic_store_n((int32_t*)p, v, __ATOMIC_SEQ_CST);
    }
int32_t _xt_atomic_add_i32(void* p, int32_t d)
    {
    return p ? __atomic_add_fetch((int32_t*)p, d, __ATOMIC_SEQ_CST) : 0;
    }
int32_t _xt_atomic_xchg_i32(void* p, int32_t v)
    {
    return p ? __atomic_exchange_n((int32_t*)p, v, __ATOMIC_SEQ_CST) : 0;
    }
int32_t _xt_atomic_cas_i32(void* p, int32_t expected, int32_t desired)
    {
    if (!p)
        return 0;
    return __atomic_compare_exchange_n((int32_t*)p, &expected, desired, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)
               ? 1
               : 0;
    }
void* _xt_atomic_load_ptr(void* p)
    {
    return p ? __atomic_load_n((void**)p, __ATOMIC_SEQ_CST) : 0;
    }
void _xt_atomic_store_ptr(void* p, void* v)
    {
    if (p)
        __atomic_store_n((void**)p, v, __ATOMIC_SEQ_CST);
    }
int32_t _xt_atomic_cas_ptr(void* p, void* expected, void* desired)
    {
    if (!p)
        return 0;
    return __atomic_compare_exchange_n((void**)p, &expected, desired, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)
               ? 1
               : 0;
    }

// ── The race-free static-init once ───────────────────────────────────────────
// private:docs/Design/threading.md §9.5. Written entirely over the contract above, so
// the freestanding runtimes get it the same way the hosted ones do.
//
// NOTE for a future regeneration: rtgen-linux.s / rtgen-win64.s are generated
// from THIS file, and both carry `_xtc_sinit_run` as a manually APPENDED tail
// (a full `clang -S` of this file emits instructions the in-house assemblers do
// not all implement). So the BODY is generated with this include suppressed —
// the recipe at the top of this file needs `-DXT_SINIT_C_INCLUDED=1`, without
// which it does not compile at all: xt-sinit.c pulls <stdint.h>, whose LP64
// int64_t collides with the LLP64-safe typedefs above.
//
// If you ever do regenerate the body, expect a LARGE unrelated diff — the
// checked-in .s files came from an older clang, and a current one rewrites
// several hundred lines of register allocation that nothing has validated
// against the in-house assemblers. Prefer appending a single function, as the
// getpid tail in rtgen-win64.s does, over a wholesale regeneration.
#include "../../../support/generic/runtime/xt-sinit.c"

// The per-thread teardown seam — see xt-thread-exit.c. This is the ONLY
// runtime that opts into the weak mi_thread_done call: mimalloc is wired for
// x86-64 only, and this path is the one that drives ld.lld.
// The weak-reference flavour of the seam assumed the x86-64 link ran through
// ld.lld ("only ever compiled on a linker that implements weak undefined
// symbols" — xt-thread-exit.c). The in-house link is the default now, and
// neither its ASSEMBLER path nor the self-hosted linker implements `.weak` /
// @GOTPCREL from .s source — so the seam compiles as a no-op here
// (XT_NO_WEAK_SEAM in the regen recipe). mimalloc still reclaims through the
// pthread key it registers (tsd is wired in the tcb); key DESTRUCTORS do not
// run on raw-clone threads, so a thread's heap leaks at exit — bounded for a
// pool, real for unbounded churn. Re-enable when the in-house/.port linkers
// learn weak-from-source.
#ifndef XT_NO_WEAK_SEAM
#define XT_THREAD_EXIT_MIMALLOC 1
#endif
#include "../../../support/generic/runtime/xt-thread-exit.c"
