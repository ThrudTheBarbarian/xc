// CAlloc.xc — the heap of a C or C++ program's large blocks (#235).
//
// A lifted loop runs as a block only when par's runtime can tell its arrays
// apart (Par.spanOf, the outliner's guard, ParDevice.bufferOverlap), and it
// can for a block the runtime's registry holds. xc's arrays of 64 KB and more
// are in it; this file puts a C program's malloc'd blocks of that size there
// too.
//
// The C path imports it into the xcc half of a C or C++ program built for
// x86-64 Linux (glibc, dynamic) or macOS; an xc program never has it. The
// link turns it on when an object defines _xc_malloc and none defines an
// allocator of its own: the program's own objects' calls to malloc, calloc,
// realloc, reallocarray, aligned_alloc, posix_memalign, memalign (Linux),
// free, and C++'s operator new and delete (plain and array, sized, nothrow)
// are renamed to the _xc_ functions below; libraries keep theirs.
//
//   - A request of 64 KB or more gets a block on a page of its own, which the
//     runtime's registry holds; a smaller one is the C library's, unknown to
//     par, as before. A C library block that realloc grows stays the C
//     library's.
//   - free and realloc look the pointer up in a table of owned starts: an
//     owned block leaves the registry and is released here, anything else
//     goes to the C library.
//
// Memory a library frees or reallocs (getline's buffer, an ownership
// transfer) reaches the same code. On Linux the link exports _xc_lib_free,
// _xc_lib_realloc and _xc_lib_usable_size from the executable as free,
// realloc and malloc_usable_size (and nothing else), so ELF interposition
// sends every library's calls here. On macOS the blocks come from a malloc
// zone of this file's, registered with libSystem, so a library's free() or
// realloc() of one reaches the zone, and malloc_size() answers for it.
//
// The C library's functions are found once with dlsym(RTLD_NEXT): the first
// definition after the executable's, glibc's or an interposer's loaded before
// it (LD_PRELOAD). Nothing here calls the C allocator by a name the link
// renames. While dlsym runs on Linux (it may allocate and free), an
// allocation uses glibc's internal entry points and a free leaves its block.
//
// The table of owned starts is read on every free that could be one (only a
// page-aligned pointer can), without a lock: open addressing over the starts
// under a sequence count, which a writer makes odd while it changes the table
// and a reader checks did not move. Writers take a spin lock. A table that
// grows is replaced; the old one is never unmapped, so a reader still in it
// reads valid memory and retries.

#if OS_macos || ((ARCH_x86_64 || ARCH_arm64) && LIBC_glibc && !OS_android)

pointer dlsym(pointer handle, u8* name);
pointer mmap(pointer addr, u64 len, i32 prot, i32 flags, i32 fd, i64 off);
i32 munmap(pointer addr, u64 len);
pointer memcpy(pointer dst, pointer src, u64 n);
pointer memset(pointer dst, i32 c, u64 n);
i32 _xt_atomic_load_i32(pointer slot);
void _xt_atomic_store_i32(pointer slot, i32 v);
i32 _xt_atomic_cas_i32(pointer slot, i32 expected, i32 desired);
pointer _xt_atomic_load_ptr(pointer slot);
void _xt_atomic_store_ptr(pointer slot, pointer v);
pointer _xt_thread_create(pointer code, pointer recv);
i32 _xt_thread_join(pointer handle);
void _xt_thread_yield(void);
// The runtime's registry (rt.c, rt-freestanding.c).
void _xtc_simd_register(pointer p, u64 bytes);
pointer _xtc_alloc_aligned(u64 count, u64 stride, pointer dealloc);
void _xtc_dealloc(pointer o);
#if !OS_macos
pointer __libc_malloc(u64 n);
pointer __libc_calloc(u64 n, u64 s);
pointer __libc_realloc(pointer p, u64 n);
pointer __libc_memalign(u64 a, u64 n);
void __libc_free(pointer p);
i32 pthread_atfork(pointer prepare, pointer parent, pointer child);
// glibc's pthread_atfork is a stub in libc_nonshared.a calling this; arm64
// Linux names it directly, as its executable may not import the stub (#326).
i32 __register_atfork(pointer prepare, pointer parent, pointer child, pointer dso);
#else
i32 malloc_zone_register(pointer zone);
#endif

typedef pointer XcMalloc_t(u64 n);
typedef pointer XcCalloc_t(u64 n, u64 s);
typedef pointer XcRealloc_t(pointer p, u64 n);
typedef pointer XcReallocArray_t(pointer p, u64 n, u64 s);
typedef void XcFree_t(pointer p);
typedef pointer XcAligned_t(u64 a, u64 n);
typedef i32 XcPosixMemalign_t(pointer* out, u64 a, u64 n);
typedef u64 XcUsable_t(pointer p);
typedef pointer XcNewNothrow_t(u64 n, pointer tag);
typedef void XcDeleteSized_t(pointer p, u64 n);

// 64 KB, the runtime's own threshold for an aligned array (XT_SIMD_FROM):
// below it par does not choose a GPU, and a page of alignment would be out of
// proportion. 16 KB pages, as the runtime's (Apple Silicon's page size).
u64 _xcLarge(void) { return (u64)65536; }
u64 _xcPage(void) { return (u64)16384; }
u64 _xcRound(u64 n, u64 to) { return (n + to - (u64)1) & ~(to - (u64)1); }

// ── the C library's functions ───────────────────────────────────────────
pointer _xc_fmalloc;
pointer _xc_fcalloc;
pointer _xc_frealloc;
pointer _xc_freallocarray;
pointer _xc_ffree;
pointer _xc_faligned;
pointer _xc_fmemalign;
pointer _xc_fposix;
pointer _xc_fusable;
// C++: operator new and delete (plain and array, sized, nothrow), mangled.
pointer _xc_fnew;
pointer _xc_fnewa;
pointer _xc_fnewnt;
pointer _xc_fnewant;
pointer _xc_fdel;
pointer _xc_fdela;
pointer _xc_fdels;
pointer _xc_fdelas;
i32 _xc_state; // 0 not looked up, 1 looking up, 2 found

bool _xcReady(void)
{
    if (_xt_atomic_load_i32((pointer)&_xc_state) == (i32)2)
        return true;
    if (_xt_atomic_cas_i32((pointer)&_xc_state, (i32)0, (i32)1) == (i32)0)
        return false; // another call is looking them up
    pointer nx = (pointer)((i64)0 - (i64)1); // RTLD_NEXT
    _xc_fmalloc = dlsym(nx, "malloc");
    _xc_fcalloc = dlsym(nx, "calloc");
    _xc_frealloc = dlsym(nx, "realloc");
    _xc_freallocarray = dlsym(nx, "reallocarray");
    _xc_ffree = dlsym(nx, "free");
    _xc_faligned = dlsym(nx, "aligned_alloc");
    _xc_fmemalign = dlsym(nx, "memalign");
    _xc_fposix = dlsym(nx, "posix_memalign");
    _xc_fnew = dlsym(nx, "_Znwm");
    _xc_fnewa = dlsym(nx, "_Znam");
    _xc_fnewnt = dlsym(nx, "_ZnwmRKSt9nothrow_t");
    _xc_fnewant = dlsym(nx, "_ZnamRKSt9nothrow_t");
    _xc_fdel = dlsym(nx, "_ZdlPv");
    _xc_fdela = dlsym(nx, "_ZdaPv");
    _xc_fdels = dlsym(nx, "_ZdlPvm");
    _xc_fdelas = dlsym(nx, "_ZdaPvm");
#if !OS_macos
    _xc_fusable = dlsym(nx, "malloc_usable_size");
    // One of the four missing: glibc's internal ones, so that blocks never
    // pass between two allocators.
    if (_xc_fmalloc == (pointer)0 || _xc_fcalloc == (pointer)0 || _xc_frealloc == (pointer)0
        || _xc_ffree == (pointer)0)
    {
        _xc_fmalloc = (pointer)&__libc_malloc;
        _xc_fcalloc = (pointer)&__libc_calloc;
        _xc_frealloc = (pointer)&__libc_realloc;
        _xc_ffree = (pointer)&__libc_free;
        _xc_faligned = (pointer)0;
        _xc_fposix = (pointer)0;
        _xc_fusable = (pointer)0;
    }
#endif
    _xt_atomic_store_i32((pointer)&_xc_state, (i32)2);
    return true;
}

#if OS_macos
// macOS: no call reaches this file while dlsym runs, so a call that finds
// another thread looking the functions up waits for it.
void _xcWait(void)
{
    while (!_xcReady())
        _xt_thread_yield();
}
#endif

pointer _xcRealMalloc(u64 n)
{
#if !OS_macos
    if (!_xcReady())
        return __libc_malloc(n);
#else
    _xcWait();
#endif
    XcMalloc_t* f = (XcMalloc_t*)_xc_fmalloc;
    return f(n);
}

pointer _xcRealCalloc(u64 n, u64 s)
{
#if !OS_macos
    if (!_xcReady())
        return __libc_calloc(n, s);
#else
    _xcWait();
#endif
    XcCalloc_t* f = (XcCalloc_t*)_xc_fcalloc;
    return f(n, s);
}

pointer _xcRealRealloc(pointer p, u64 n)
{
#if !OS_macos
    if (!_xcReady())
        return __libc_realloc(p, n);
#else
    _xcWait();
#endif
    XcRealloc_t* f = (XcRealloc_t*)_xc_frealloc;
    return f(p, n);
}

// While dlsym runs, a block freed is left as it is: it may be an
// interposer's (one loaded before glibc allocates while it starts), which
// glibc's own free would reject. A few bytes, once.
void _xcRealFree(pointer p)
{
#if !OS_macos
    if (!_xcReady())
        return;
#else
    _xcWait();
#endif
    XcFree_t* f = (XcFree_t*)_xc_ffree;
    f(p);
}

pointer _xcRealAligned(u64 a, u64 n)
{
    if (_xcReady() && _xc_faligned != (pointer)0)
    {
        XcAligned_t* f = (XcAligned_t*)_xc_faligned;
        return f(a, n);
    }
#if !OS_macos
    return __libc_memalign(a, n);
#else
    return (pointer)0;
#endif
}

pointer _xcRealMemalign(u64 a, u64 n)
{
    if (_xcReady() && _xc_fmemalign != (pointer)0)
    {
        XcAligned_t* f = (XcAligned_t*)_xc_fmemalign;
        return f(a, n);
    }
#if !OS_macos
    return __libc_memalign(a, n);
#else
    return (pointer)0;
#endif
}

i32 _xcRealPosix(pointer* out, u64 a, u64 n)
{
    if (_xcReady() && _xc_fposix != (pointer)0)
    {
        XcPosixMemalign_t* f = (XcPosixMemalign_t*)_xc_fposix;
        return f(out, a, n);
    }
    if (a < (u64)8 || (a & (a - (u64)1)) != (u64)0)
        return (i32)22; // EINVAL
    pointer p = _xcRealMemalign(a, n);
    if (p == (pointer)0)
        return (i32)12; // ENOMEM
    out[0] = p;
    return (i32)0;
}

u64 _xcRealUsable(pointer p)
{
    if (p == (pointer)0 || !_xcReady() || _xc_fusable == (pointer)0)
        return (u64)0;
    XcUsable_t* f = (XcUsable_t*)_xc_fusable;
    return f(p);
}

// ── the lock, and the runtime's threads ─────────────────────────────────
i32 _xc_lock;
i32 _xc_threads; // 0, 1 starting, 2 done

void _xcLock(void)
{
    while (_xt_atomic_cas_i32((pointer)&_xc_lock, (i32)0, (i32)1) == (i32)0)
        _xt_thread_yield();
}

void _xcUnlock(void)
{
    _xt_atomic_store_i32((pointer)&_xc_lock, (i32)0);
}

#if !OS_macos
// fork(): the child must not inherit a lock another thread held.
void _xcForkPrepare(void) { _xcLock(); }
void _xcForkParent(void) { _xcUnlock(); }
void _xcForkChild(void) { _xt_atomic_store_i32((pointer)&_xc_lock, (i32)0); }
#endif

void _xcNoop(pointer recv)
{
}

// Once, before the first block is registered: one thread of the runtime's is
// started and joined, which makes the runtime's own lock (which guards the
// registry) a real one: a C program's threads are not the runtime's, so it
// would not otherwise know there are several. On macOS the zone is
// registered; on Linux the lock is made safe across fork.
void _xcZoneRegister(void);
void _xcStart(void)
{
    if (_xt_atomic_load_i32((pointer)&_xc_threads) == (i32)2)
        return;
    if (_xt_atomic_cas_i32((pointer)&_xc_threads, (i32)0, (i32)1) == (i32)0)
    {
        while (_xt_atomic_load_i32((pointer)&_xc_threads) != (i32)2)
            _xt_thread_yield();
        return;
    }
    pointer h = _xt_thread_create((pointer)&_xcNoop, (pointer)0);
    if (h != (pointer)0)
        _xt_thread_join(h);
#if OS_macos
    _xcZoneRegister();
#elif ARCH_arm64
    // No DSO handle: the program's own handlers, never unregistered.
    __register_atfork((pointer)&_xcForkPrepare, (pointer)&_xcForkParent, (pointer)&_xcForkChild, (pointer)0);
#else
    pthread_atfork((pointer)&_xcForkPrepare, (pointer)&_xcForkParent, (pointer)&_xcForkChild);
#endif
    _xt_atomic_store_i32((pointer)&_xc_threads, (i32)2);
}

// ── the table of owned starts ───────────────────────────────────────────
// A table is one mapping: [mask, shift, then (start, size) per slot]. A start
// of 0 is an empty slot.
pointer _xc_tab;
i32 _xc_seq;   // odd while a writer changes the table
u64 _xc_live;  // entries (writers only)

u64 _xcSlot(pointer t, u64 k)
{
    u64* w = (u64*)t;
    return ((k / _xcPage()) * (u64)$9E3779B97F4A7C15) >> w[1];
}

pointer _xcKeyAt(pointer t, u64 i)
{
    return (pointer)((u64)t + (u64)16 + i * (u64)16);
}

// Whether p is an owned start, with its size in size[0]. Lock-free.
bool _xcFind(pointer p, u64* size)
{
    u64 k = (u64)p;
    while (true)
    {
        i32 s1 = _xt_atomic_load_i32((pointer)&_xc_seq);
        if ((s1 & (i32)1) != (i32)0)
        {
            _xt_thread_yield();
            continue;
        }
        pointer t = _xt_atomic_load_ptr((pointer)&_xc_tab);
        bool hit = false;
        u64 z = (u64)0;
        if (t != (pointer)0)
        {
            u64 mask = ((u64*)t)[0];
            u64 i = _xcSlot(t, k);
            for (u64 n = (u64)0; n <= mask; n = n + (u64)1)
            {
                pointer e = _xcKeyAt(t, i);
                u64 key = (u64)_xt_atomic_load_ptr(e);
                if (key == (u64)0)
                    break;
                if (key == k)
                {
                    z = (u64)_xt_atomic_load_ptr((pointer)((u64)e + (u64)8));
                    hit = true;
                    break;
                }
                i = (i + (u64)1) & mask;
            }
        }
        if (_xt_atomic_load_i32((pointer)&_xc_seq) == s1)
        {
            if (hit)
                size[0] = z;
            return hit;
        }
    }
    return false;
}

void _xcWriteBegin(void)
{
    _xt_atomic_store_i32((pointer)&_xc_seq, _xc_seq + (i32)1);
}

void _xcWriteEnd(void)
{
    _xt_atomic_store_i32((pointer)&_xc_seq, _xc_seq + (i32)1);
}

// A table's memory comes straight from the system and is never given back.
pointer _xcTabNew(u64 bits)
{
    u64 slots = (u64)1 << bits;
    u64 bytes = (u64)16 + slots * (u64)16;
#if OS_macos
    pointer m = mmap((pointer)0, bytes, (i32)3, (i32)$1002, (i32)0 - (i32)1, (i64)0);
#else
    pointer m = mmap((pointer)0, bytes, (i32)3, (i32)$22, (i32)0 - (i32)1, (i64)0);
#endif
    if ((i64)m == (i64)0 - (i64)1)
        return (pointer)0;
    u64* w = (u64*)m;
    w[0] = slots - (u64)1;
    w[1] = (u64)64 - bits;
    return m;
}

void _xcPut(pointer t, u64 k, u64 size)
{
    u64 mask = ((u64*)t)[0];
    u64 i = _xcSlot(t, k);
    while (((u64*)_xcKeyAt(t, i))[0] != (u64)0)
        i = (i + (u64)1) & mask;
    pointer e = _xcKeyAt(t, i);
    _xt_atomic_store_ptr((pointer)((u64)e + (u64)8), (pointer)size);
    _xt_atomic_store_ptr(e, (pointer)k);
}

// Under the lock. false when no table could be had.
bool _xcInsert(u64 k, u64 size)
{
    pointer t = _xc_tab;
    if (t == (pointer)0 || (_xc_live + (u64)1) * (u64)2 > ((u64*)t)[0] + (u64)1)
    {
        u64 bits = (u64)10;
        if (t != (pointer)0)
            bits = (u64)65 - ((u64*)t)[1];
        pointer n = _xcTabNew(bits);
        if (n == (pointer)0)
            return false;
        if (t != (pointer)0)
        {
            u64 mask = ((u64*)t)[0];
            for (u64 i = (u64)0; i <= mask; i = i + (u64)1)
            {
                u64* e = (u64*)_xcKeyAt(t, i);
                if (e[0] != (u64)0)
                    _xcPut(n, e[0], e[1]);
            }
        }
        _xcWriteBegin();
        _xt_atomic_store_ptr((pointer)&_xc_tab, n);
        _xcWriteEnd();
        t = n;
    }
    _xcWriteBegin();
    _xcPut(t, k, size);
    _xcWriteEnd();
    _xc_live = _xc_live + (u64)1;
    return true;
}

// Under the lock: k leaves the table (backward-shift deletion, so no slot is
// ever a tombstone). false when k was not in it.
bool _xcRemove(u64 k)
{
    pointer t = _xc_tab;
    if (t == (pointer)0)
        return false;
    u64 mask = ((u64*)t)[0];
    u64 i = _xcSlot(t, k);
    while (((u64*)_xcKeyAt(t, i))[0] != k)
    {
        if (((u64*)_xcKeyAt(t, i))[0] == (u64)0)
            return false;
        i = (i + (u64)1) & mask;
    }
    _xcWriteBegin();
    u64 j = i;
    while (true)
    {
        j = (j + (u64)1) & mask;
        u64* ej = (u64*)_xcKeyAt(t, j);
        u64 kj = ej[0];
        if (kj == (u64)0)
            break;
        u64 h = _xcSlot(t, kj);
        // kj moves into the hole at i when its home slot h is not in (i, j].
        bool mv = false;
        if (i <= j)
            mv = h <= i || h > j;
        else
            mv = h <= i && h > j;
        if (mv)
        {
            pointer ei = _xcKeyAt(t, i);
            _xt_atomic_store_ptr((pointer)((u64)ei + (u64)8), (pointer)ej[1]);
            _xt_atomic_store_ptr(ei, (pointer)kj);
            i = j;
        }
    }
    _xt_atomic_store_ptr(_xcKeyAt(t, i), (pointer)0);
    _xcWriteEnd();
    _xc_live = _xc_live - (u64)1;
    return true;
}

// ── owned blocks ────────────────────────────────────────────────────────
// Only a page-aligned pointer can be an owned start.
bool _xcOwned(pointer p, u64* size)
{
    if (p == (pointer)0 || ((u64)p & (_xcPage() - (u64)1)) != (u64)0)
        return false;
    return _xcFind(p, size);
}

#if OS_macos
// A mapping of its own: no other zone's region holds the block, so libSystem
// asks this file's zone about it, and it comes zeroed. The page before it
// carries the header of a runtime aligned array (count n, no allocator base),
// so _xtc_dealloc takes it out of the registry.
pointer _xcMap(u64 n)
{
    u64 len = _xcPage() + _xcRound(n, _xcPage());
    pointer m = mmap((pointer)0, len, (i32)3, (i32)$1002, (i32)0 - (i32)1, (i64)0);
    if ((i64)m == (i64)0 - (i64)1)
        return (pointer)0;
    pointer p = (pointer)((u64)m + _xcPage());
    u64* h = (u64*)((u64)p - (u64)48);
    h[0] = (u64)0;              // the allocator base: none (free(0))
    h[1] = (u64)1;              // stride
    h[2] = n;                   // count
    h[3] = (u64)0;              // dealloc
    h[4] = (u64)0;              // weak head
    u32* m32 = (u32*)((u64)p - (u64)8);
    m32[0] = (u32)$58544F43;    // XT_MAGIC_ALIGNED
    m32[1] = (u32)1;            // refcount
    _xtc_simd_register(p, _xcRound(n, (u64)4096));
    return p;
}
#endif

// A block of n >= 64 KB bytes on a page of its own, zeroed, in the registry
// and the table; 0 when none could be had (the caller then uses the C
// library's).
pointer _xcTake(u64 n)
{
    if (n > ((u64)1 << (u64)47))
        return (pointer)0;
    _xcReady();
    _xcStart();
    _xcLock();
#if OS_macos
    pointer p = _xcMap(n);
#else
    pointer p = _xtc_alloc_aligned(n, (u64)1, (pointer)0);
#endif
    if (p != (pointer)0 && !_xcInsert((u64)p, n))
    {
        _xtc_dealloc(p);
#if OS_macos
        munmap((pointer)((u64)p - _xcPage()), _xcPage() + _xcRound(n, _xcPage()));
#endif
        p = (pointer)0;
    }
    _xcUnlock();
    return p;
}

// The owned block at p leaves the table and the registry, and its memory goes.
void _xcGive(pointer p, u64 size)
{
    _xcLock();
    bool was = _xcRemove((u64)p);
    if (was)
        _xtc_dealloc(p);
    _xcUnlock();
#if OS_macos
    if (was)
        munmap((pointer)((u64)p - _xcPage()), _xcPage() + _xcRound(size, _xcPage()));
#endif
}

void _xcFree(pointer p)
{
    u64 size = (u64)0;
    if (_xcOwned(p, &size))
        _xcGive(p, size);
    else if (p != (pointer)0)
        _xcRealFree(p);
}

pointer _xcMalloc(u64 n)
{
    if (n >= _xcLarge())
    {
        pointer p = _xcTake(n);
        if (p != (pointer)0)
            return p;
    }
    return _xcRealMalloc(n);
}

// An owned block moved to one of n bytes (owned or the C library's, by
// size); 0 with the old one as it was. n of 0 frees it, as glibc's realloc.
pointer _xcMove(pointer p, u64 size, u64 n)
{
    if (n == (u64)0)
    {
        _xcGive(p, size);
        return (pointer)0;
    }
    pointer q = _xcMalloc(n);
    if (q == (pointer)0)
        return (pointer)0;
    memcpy(q, p, size < n ? size : n);
    _xcGive(p, size);
    return q;
}

// Whether n * s overflows.
bool _xcMulOver(u64 n, u64 s)
{
    return s != (u64)0 && n > ((u64)0 - (u64)1) / s;
}

// ── the program's own calls (the link renames them to these) ─────────────
// Each is `extern`: the module's surface, kept though nothing in it calls
// them, since the calls are renamed only when the program is linked.
extern pointer _xc_malloc(u64 n)
{
    return _xcMalloc(n);
}

extern pointer _xc_calloc(u64 n, u64 s)
{
    if (!_xcMulOver(n, s) && n * s >= _xcLarge())
    {
        pointer p = _xcTake(n * s);
        if (p != (pointer)0)
            return p;
    }
    return _xcRealCalloc(n, s);
}

extern void _xc_free(pointer p)
{
    _xcFree(p);
}

extern pointer _xc_realloc(pointer p, u64 n)
{
    if (p == (pointer)0)
        return _xcMalloc(n);
    u64 size = (u64)0;
    if (_xcOwned(p, &size))
        return _xcMove(p, size, n);
    return _xcRealRealloc(p, n);
}

extern pointer _xc_reallocarray(pointer p, u64 n, u64 s)
{
    if (_xcMulOver(n, s))
    {
        // The C library's reports it (ENOMEM).
        if (_xcReady() && _xc_freallocarray != (pointer)0)
        {
            XcReallocArray_t* f = (XcReallocArray_t*)_xc_freallocarray;
            return f(p, n, s);
        }
        return (pointer)0;
    }
    return _xc_realloc(p, n * s);
}

bool _xcAlignOk(u64 a)
{
    return a != (u64)0 && a <= _xcPage() && (a & (a - (u64)1)) == (u64)0;
}

extern pointer _xc_aligned_alloc(u64 a, u64 n)
{
    if (n >= _xcLarge() && _xcAlignOk(a))
    {
        pointer p = _xcTake(n);
        if (p != (pointer)0)
            return p;
    }
    return _xcRealAligned(a, n);
}

extern i32 _xc_posix_memalign(pointer* out, u64 a, u64 n)
{
    if (n >= _xcLarge() && a >= (u64)8 && _xcAlignOk(a))
    {
        pointer p = _xcTake(n);
        if (p != (pointer)0)
        {
            out[0] = p;
            return (i32)0;
        }
    }
    return _xcRealPosix(out, a, n);
}

// ── C++: the program's own operator new and delete (renamed as above) ───
// A request of 64 KB and more is a block of the heap's; anything else, and a
// failure (which throws, or is 0 for nothrow), is the C++ library's own
// operator. A delete of an owned block releases it here; of any other, it
// goes to the C++ library's. Called only by a program that links one, after
// the start, so a call that finds the lookup running waits for it; each entry
// point waits before it reads the library's operator.
void _xcWaitAll(void)
{
    while (!_xcReady())
        _xt_thread_yield();
}

pointer _xcNewWith(pointer real, u64 n)
{
    _xcWaitAll();
    if (n >= _xcLarge())
    {
        pointer p = _xcTake(n);
        if (p != (pointer)0)
            return p;
    }
    XcMalloc_t* f = (XcMalloc_t*)real;
    return f(n);
}

pointer _xcNewNothrowWith(pointer real, u64 n, pointer tag)
{
    _xcWaitAll();
    if (n >= _xcLarge())
    {
        pointer p = _xcTake(n);
        if (p != (pointer)0)
            return p;
    }
    XcNewNothrow_t* f = (XcNewNothrow_t*)real;
    return f(n, tag);
}

void _xcDeleteWith(pointer real, pointer p)
{
    u64 size = (u64)0;
    if (_xcOwned(p, &size))
    {
        _xcGive(p, size);
        return;
    }
    _xcWaitAll();
    XcFree_t* f = (XcFree_t*)real;
    f(p);
}

void _xcDeleteSizedWith(pointer real, pointer plain, pointer p, u64 n)
{
    u64 size = (u64)0;
    if (_xcOwned(p, &size))
    {
        _xcGive(p, size);
        return;
    }
    _xcWaitAll();
    if (real == (pointer)0)
    {
        XcFree_t* g = (XcFree_t*)plain;
        g(p);
        return;
    }
    XcDeleteSized_t* f = (XcDeleteSized_t*)real;
    f(p, n);
}

extern pointer _xc_Znwm(u64 n)
{
    _xcWaitAll();
    return _xcNewWith(_xc_fnew, n);
}

extern pointer _xc_Znam(u64 n)
{
    _xcWaitAll();
    return _xcNewWith(_xc_fnewa, n);
}

extern pointer _xc_ZnwmRKSt9nothrow_t(u64 n, pointer tag)
{
    _xcWaitAll();
    return _xcNewNothrowWith(_xc_fnewnt, n, tag);
}

extern pointer _xc_ZnamRKSt9nothrow_t(u64 n, pointer tag)
{
    _xcWaitAll();
    return _xcNewNothrowWith(_xc_fnewant, n, tag);
}

extern void _xc_ZdlPv(pointer p)
{
    _xcWaitAll();
    _xcDeleteWith(_xc_fdel, p);
}

extern void _xc_ZdaPv(pointer p)
{
    _xcWaitAll();
    _xcDeleteWith(_xc_fdela, p);
}

extern void _xc_ZdlPvm(pointer p, u64 n)
{
    _xcWaitAll();
    _xcDeleteSizedWith(_xc_fdels, _xc_fdel, p, n);
}

extern void _xc_ZdaPvm(pointer p, u64 n)
{
    _xcWaitAll();
    _xcDeleteSizedWith(_xc_fdelas, _xc_fdela, p, n);
}

#if !OS_macos
extern pointer _xc_memalign(u64 a, u64 n)
{
    if (n >= _xcLarge() && _xcAlignOk(a))
    {
        pointer p = _xcTake(n);
        if (p != (pointer)0)
            return p;
    }
    return _xcRealMemalign(a, n);
}

// ── what every library's calls reach: the link exports these from the
// executable as free, realloc and malloc_usable_size ─────────────────────
extern void _xc_lib_free(pointer p)
{
    _xcFree(p);
}

extern pointer _xc_lib_realloc(pointer p, u64 n)
{
    u64 size = (u64)0;
    if (_xcOwned(p, &size))
        return _xcMove(p, size, n);
    return _xcRealRealloc(p, n);
}

extern u64 _xc_lib_usable_size(pointer p)
{
    u64 size = (u64)0;
    if (_xcOwned(p, &size))
        return size;
    return _xcRealUsable(p);
}
#else
// ── the zone (macOS): what libSystem calls for a block of this file's ───
// malloc_zone_t and its introspection table as words, in the SDK's order.
pointer _xc_zone[24];
pointer _xc_zintro[20];

u64 _xcZSize(pointer z, pointer p)
{
    u64 size = (u64)0;
    if (_xcOwned(p, &size))
        return size;
    return (u64)0;
}
pointer _xcZMalloc(pointer z, u64 n)
{
    return _xcTake(n < _xcLarge() ? _xcLarge() : n);
}
pointer _xcZCalloc(pointer z, u64 n, u64 s)
{
    if (_xcMulOver(n, s))
        return (pointer)0;
    return _xcTake(n * s < _xcLarge() ? _xcLarge() : n * s);
}
pointer _xcZValloc(pointer z, u64 n)
{
    return _xcZMalloc(z, n);
}
void _xcZFree(pointer z, pointer p)
{
    u64 size = (u64)0;
    if (_xcOwned(p, &size))
        _xcGive(p, size);
}
pointer _xcZRealloc(pointer z, pointer p, u64 n)
{
    if (p == (pointer)0)
        return _xcMalloc(n);
    u64 size = (u64)0;
    // libSystem's realloc(p, 0) gives a block of the smallest size.
    if (_xcOwned(p, &size))
        return _xcMove(p, size, n == (u64)0 ? (u64)1 : n);
    return (pointer)0;
}
void _xcZDestroy(pointer z)
{
}
pointer _xcZMemalign(pointer z, u64 a, u64 n)
{
    if (a > _xcPage())
        return (pointer)0;
    return _xcZMalloc(z, n);
}
void _xcZFreeSized(pointer z, pointer p, u64 n)
{
    _xcZFree(z, p);
}
u64 _xcZPressure(pointer z, u64 goal)
{
    return (u64)0;
}
i32 _xcZClaimed(pointer z, pointer p)
{
    u64 size = (u64)0;
    return _xcOwned(p, &size) ? (i32)1 : (i32)0;
}
i32 _xcZEnumerate(u32 task, pointer ctx, u32 type, u64 zone, pointer reader, pointer recorder)
{
    return (i32)0;
}
u64 _xcZGoodSize(pointer z, u64 n)
{
    return _xcRound(n < _xcLarge() ? _xcLarge() : n, _xcPage());
}
i32 _xcZCheck(pointer z)
{
    return (i32)1;
}
void _xcZPrint(pointer z, i32 verbose)
{
}
void _xcZLog(pointer z, pointer address)
{
}
// fork(): libSystem holds every zone's lock across it.
void _xcZForceLock(pointer z)
{
    _xcLock();
}
void _xcZForceUnlock(pointer z)
{
    _xcUnlock();
}
void _xcZReinitLock(pointer z)
{
    _xt_atomic_store_i32((pointer)&_xc_lock, (i32)0);
}
void _xcZStatistics(pointer z, pointer stats)
{
    memset(stats, (i32)0, (u64)32);
}
i32 _xcZLocked(pointer z)
{
    return (i32)0;
}
i32 _xcZFalse(pointer z)
{
    return (i32)0;
}
void _xcZNothing(pointer z)
{
}
void _xcZDischarge(pointer z, pointer memory)
{
}

void _xcZoneRegister(void)
{
    _xc_zintro[0] = (pointer)&_xcZEnumerate;
    _xc_zintro[1] = (pointer)&_xcZGoodSize;
    _xc_zintro[2] = (pointer)&_xcZCheck;
    _xc_zintro[3] = (pointer)&_xcZPrint;
    _xc_zintro[4] = (pointer)&_xcZLog;
    _xc_zintro[5] = (pointer)&_xcZForceLock;
    _xc_zintro[6] = (pointer)&_xcZForceUnlock;
    _xc_zintro[7] = (pointer)&_xcZStatistics;
    _xc_zintro[8] = (pointer)&_xcZLocked;
    _xc_zintro[9] = (pointer)&_xcZFalse;        // enable_discharge_checking
    _xc_zintro[10] = (pointer)&_xcZNothing;     // disable_discharge_checking
    _xc_zintro[11] = (pointer)&_xcZDischarge;
    _xc_zintro[13] = (pointer)&_xcZReinitLock;
    _xc_zone[2] = (pointer)&_xcZSize;
    _xc_zone[3] = (pointer)&_xcZMalloc;
    _xc_zone[4] = (pointer)&_xcZCalloc;
    _xc_zone[5] = (pointer)&_xcZValloc;
    _xc_zone[6] = (pointer)&_xcZFree;
    _xc_zone[7] = (pointer)&_xcZRealloc;
    _xc_zone[8] = (pointer)&_xcZDestroy;
    _xc_zone[9] = (pointer)"xc-large";
    _xc_zone[12] = (pointer)&_xc_zintro[0];
    _xc_zone[13] = (pointer)(u64)10;           // version (unsigned, low word)
    _xc_zone[14] = (pointer)&_xcZMemalign;
    _xc_zone[15] = (pointer)&_xcZFreeSized;
    _xc_zone[16] = (pointer)&_xcZPressure;
    _xc_zone[17] = (pointer)&_xcZClaimed;
    malloc_zone_register((pointer)&_xc_zone[0]);
}
#endif

#endif
