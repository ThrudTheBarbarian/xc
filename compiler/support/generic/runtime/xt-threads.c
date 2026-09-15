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

// xt-threads.c — the xtc threading primitives, for every target that has a libc.
//
// ONE source, several runtimes. The same `_xt_*` contract has to exist in each
// alternative object runtime a target can be built with, and a primitive
// present in only some of them fails to link in exactly the others. Everybody
// with a libc includes this file, so they cannot drift:
//
//   support/arm64/runtime/libxt.c        #include "../../generic/runtime/xt-threads.c"
//   src/xtc/support-src/rt.c             #include "../../../support/generic/runtime/xt-threads.c"
//   the generated x86-64 / win64 stub     #include "<support>/generic/runtime/xt-threads.c"
//
// (rt.c is only ever compiled in the dev tree, to REGENERATE rt-macos.s, so a
// source-tree-relative path is safe there. The other two are compiled from the
// INSTALLED tree, so their paths stay inside support/.)
//
// Two implementations, chosen by the host: pthreads, or Win32 where there are
// none. The freestanding x86-64 targets — static musl built by the in-house
// toolchain, and the self-hosted PE — have no libc to call at all and carry
// their own bodies in `src/xtc/support-src/rt-freestanding.c` (raw `clone` +
// futex, or kernel32 directly). arm9 waits on the XTOS kernel work
// (private:docs/Design/threading.md §5, threading Phase 3).
//
// The xtc-visible contract is a set of `_xt_*` C names that the library classes
// in support/generic/lib/{Thread,Mutex,Cond,Sem,Atomic,ThreadLocal}.xc declare
// and call. Handles are opaque `pointer`s — no xtc declaration ever names a
// host type.

#ifndef XT_THREADS_C_INCLUDED
#define XT_THREADS_C_INCLUDED

#include <stdint.h>
#include <stdlib.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#include <sched.h>
#include <time.h>
#include <unistd.h>
#endif

// ── Are we multi-threaded yet? ───────────────────────────────────────────
// Set once, before the first extra thread exists, and only ever read after
// that. The runtime's own shared-state locks (currently just the weak-reference
// intrusive list) test it so a single-threaded program pays one predictable
// load-and-branch rather than a mutex round trip on every weak operation.
// `_xt_threads_active` is deliberately not static: rt.c's weak-list code reads
// it, and the two live in different translation units on the clang path.
int _xt_threads_active = 0;

int32_t _xt_threads_multi(void)
    {
    return (int32_t)_xt_threads_active;
    }

// ── Threads ──────────────────────────────────────────────────────────────
// A thread body is an xtc bound method — the `^` fat pointer {recv, code} of
// private:docs/Design/bound-methods.md, whose uniform ABI is `code(recv, args…)`. The
// library class hands the two words across separately, so the entry below is
// just "call the code word with the receiver word": no thread-entry ABI is
// invented, and no argument marshalling exists to get wrong.
typedef struct
    {
    void* code;
    void* recv;
    } xt_start_t;

#if defined(_WIN32)
// ─────────────────────────── Windows ───────────────────────────
// kernel32 has all of it — threads, SRW locks, condition variables, semaphores
// and TLS. Nothing here is emulated.
static CRITICAL_SECTION xt_rt_cs;

void _xt_rt_lock(void)
    {
    if (_xt_threads_active)
        EnterCriticalSection(&xt_rt_cs);
    }
void _xt_rt_unlock(void)
    {
    if (_xt_threads_active)
        LeaveCriticalSection(&xt_rt_cs);
    }

void _xt_thread_exiting(void);
static DWORD WINAPI xt_thread_entry(LPVOID p)
    {
    xt_start_t s = *(xt_start_t*)p;
    free(p);
    if (s.code)
        ((void (*)(void*))s.code)(s.recv);
    _xt_thread_exiting(); // per-thread teardown (xt-thread-exit.c)
    return 0;
    }

void* _xt_thread_create(void* code, void* recv)
    {
    if (!code)
        return 0;
    if (!_xt_threads_active)
        {
        InitializeCriticalSection(&xt_rt_cs); // before a second thread exists
        _xt_threads_active = 1;
        }
    xt_start_t* s = (xt_start_t*)malloc(sizeof *s);
    if (!s)
        return 0;
    s->code = code;
    s->recv = recv;
    HANDLE h = CreateThread(0, 0, xt_thread_entry, s, 0, 0);
    if (!h)
        {
        free(s);
        return 0;
        }
    return (void*)h;
    }

int32_t _xt_thread_join(void* h)
    {
    if (!h)
        return -1;
    WaitForSingleObject((HANDLE)h, INFINITE);
    CloseHandle((HANDLE)h);
    return 0;
    }
void _xt_thread_detach(void* h)
    {
    if (h)
        CloseHandle((HANDLE)h);
    }
void _xt_thread_yield(void)
    {
    SwitchToThread();
    }
void _xt_thread_sleep_ms(uint32_t ms)
    {
    Sleep((DWORD)ms);
    }
uint32_t _xt_thread_self_id(void)
    {
    return (uint32_t)GetCurrentThreadId();
    }

int32_t _xt_thread_cpu_count(void)
    {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return si.dwNumberOfProcessors ? (int32_t)si.dwNumberOfProcessors : 1;
    }

// SRWLOCK and CONDITION_VARIABLE are each one pointer-sized word, initialised
// by their Initialize* call and with no destroy to call — so free is just free.
void* _xt_mutex_new(void)
    {
    SRWLOCK* m = (SRWLOCK*)malloc(sizeof *m);
    if (m)
        InitializeSRWLock(m);
    return m;
    }
void _xt_mutex_free(void* m)
    {
    free(m);
    }
void _xt_mutex_lock(void* m)
    {
    if (m)
        AcquireSRWLockExclusive((SRWLOCK*)m);
    }
void _xt_mutex_unlock(void* m)
    {
    if (m)
        ReleaseSRWLockExclusive((SRWLOCK*)m);
    }
int32_t _xt_mutex_trylock(void* m)
    {
    return m && TryAcquireSRWLockExclusive((SRWLOCK*)m) ? 1 : 0;
    }

void* _xt_cond_new(void)
    {
    CONDITION_VARIABLE* c = (CONDITION_VARIABLE*)malloc(sizeof *c);
    if (c)
        InitializeConditionVariable(c);
    return c;
    }
void _xt_cond_free(void* c)
    {
    free(c);
    }
void _xt_cond_wait(void* c, void* m)
    {
    if (c && m)
        SleepConditionVariableSRW((CONDITION_VARIABLE*)c, (SRWLOCK*)m, INFINITE, 0);
    }
void _xt_cond_signal(void* c)
    {
    if (c)
        WakeConditionVariable((CONDITION_VARIABLE*)c);
    }
void _xt_cond_broadcast(void* c)
    {
    if (c)
        WakeAllConditionVariable((CONDITION_VARIABLE*)c);
    }

void* _xt_sem_new(int32_t initial)
    {
    return (void*)CreateSemaphoreA(0, initial < 0 ? 0 : initial, 0x7FFFFFFF, 0);
    }
void _xt_sem_free(void* s)
    {
    if (s)
        CloseHandle((HANDLE)s);
    }
void _xt_sem_wait(void* s)
    {
    if (s)
        WaitForSingleObject((HANDLE)s, INFINITE);
    }
void _xt_sem_post(void* s)
    {
    if (s)
        ReleaseSemaphore((HANDLE)s, 1, 0);
    }
int32_t _xt_sem_trywait(void* s)
    {
    return s && WaitForSingleObject((HANDLE)s, 0) == WAIT_OBJECT_0 ? 1 : 0;
    }

// Keys are never destroyed — see the POSIX side for why.
uint32_t _xt_tls_new(void)
    {
    return (uint32_t)TlsAlloc();
    }
void _xt_tls_set(uint32_t k, void* v)
    {
    TlsSetValue((DWORD)k, v);
    }
void* _xt_tls_get(uint32_t k)
    {
    return TlsGetValue((DWORD)k);
    }

#else
// ─────────────────────────── POSIX ───────────────────────────
static pthread_mutex_t xt_rt_mtx; // guards runtime-internal shared state

void _xt_rt_lock(void)
    {
    if (_xt_threads_active)
        pthread_mutex_lock(&xt_rt_mtx);
    }
void _xt_rt_unlock(void)
    {
    if (_xt_threads_active)
        pthread_mutex_unlock(&xt_rt_mtx);
    }

void _xt_thread_exiting(void);
static void* xt_thread_entry(void* p)
    {
    xt_start_t s = *(xt_start_t*)p; // copy out, then the starter is ours
    free(p);
    if (s.code)
        ((void (*)(void*))s.code)(s.recv);
    _xt_thread_exiting(); // per-thread teardown (xt-thread-exit.c)
    return 0;
    }

void* _xt_thread_create(void* code, void* recv)
    {
    if (!code)
        return 0;
    if (!_xt_threads_active)
        {
        // First spawn: bring up the runtime lock BEFORE a second thread can
        // exist, so no once-flag / double-checked init is needed here.
        pthread_mutex_init(&xt_rt_mtx, 0);
        _xt_threads_active = 1;
        }
    xt_start_t* s = (xt_start_t*)malloc(sizeof *s);
    if (!s)
        return 0;
    s->code = code;
    s->recv = recv;
    pthread_t* h = (pthread_t*)malloc(sizeof *h);
    if (!h)
        {
        free(s);
        return 0;
        }
    if (pthread_create(h, 0, xt_thread_entry, s) != 0)
        {
        free(s);
        free(h);
        return 0;
        }
    return h;
    }

// Join frees the handle, so a joined Thread's `handle` must be cleared by the
// caller — the library class does that, and a second join returns -1 rather
// than reusing freed memory.
int32_t _xt_thread_join(void* h)
    {
    if (!h)
        return -1;
    void* ret = 0;
    int rc = pthread_join(*(pthread_t*)h, &ret);
    free(h);
    return rc == 0 ? 0 : -1;
    }

void _xt_thread_detach(void* h)
    {
    if (!h)
        return;
    pthread_detach(*(pthread_t*)h);
    free(h);
    }

void _xt_thread_yield(void)
    {
    sched_yield();
    }

void _xt_thread_sleep_ms(uint32_t ms)
    {
    struct timespec req;
    req.tv_sec = (time_t)(ms / 1000u);
    req.tv_nsec = (long)((ms % 1000u) * 1000000u);
    nanosleep(&req, (struct timespec*)0);
    }

// An opaque per-thread identity, not an index: pthread_t is a pointer on macOS,
// so fold it to 32 bits. Equal ids mean the same thread; the value has no other
// meaning and no ordering.
uint32_t _xt_thread_self_id(void)
    {
    uintptr_t t = (uintptr_t)pthread_self();
    return (uint32_t)((t >> 4) ^ (t >> 32));
    }

int32_t _xt_thread_cpu_count(void)
    {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int32_t)n : 1;
    }

// ── Mutex ────────────────────────────────────────────────────────────────
void* _xt_mutex_new(void)
    {
    pthread_mutex_t* m = (pthread_mutex_t*)malloc(sizeof *m);
    if (!m)
        return 0;
    if (pthread_mutex_init(m, 0) != 0)
        {
        free(m);
        return 0;
        }
    return m;
    }
void _xt_mutex_free(void* m)
    {
    if (!m)
        return;
    pthread_mutex_destroy((pthread_mutex_t*)m);
    free(m);
    }
void _xt_mutex_lock(void* m)
    {
    if (m)
        pthread_mutex_lock((pthread_mutex_t*)m);
    }
void _xt_mutex_unlock(void* m)
    {
    if (m)
        pthread_mutex_unlock((pthread_mutex_t*)m);
    }
int32_t _xt_mutex_trylock(void* m)
    {
    if (!m)
        return 0;
    return pthread_mutex_trylock((pthread_mutex_t*)m) == 0 ? 1 : 0;
    }

// ── Condition variable ───────────────────────────────────────────────────
void* _xt_cond_new(void)
    {
    pthread_cond_t* c = (pthread_cond_t*)malloc(sizeof *c);
    if (!c)
        return 0;
    if (pthread_cond_init(c, 0) != 0)
        {
        free(c);
        return 0;
        }
    return c;
    }
void _xt_cond_free(void* c)
    {
    if (!c)
        return;
    pthread_cond_destroy((pthread_cond_t*)c);
    free(c);
    }
void _xt_cond_wait(void* c, void* m)
    {
    if (c && m)
        pthread_cond_wait((pthread_cond_t*)c, (pthread_mutex_t*)m);
    }
void _xt_cond_signal(void* c)
    {
    if (c)
        pthread_cond_signal((pthread_cond_t*)c);
    }
void _xt_cond_broadcast(void* c)
    {
    if (c)
        pthread_cond_broadcast((pthread_cond_t*)c);
    }

// ── Counting semaphore ───────────────────────────────────────────────────
// Built from mutex+cond rather than <semaphore.h>: macOS deprecated unnamed
// POSIX semaphores (sem_init always fails with ENOSYS), and this way the
// semantics are identical on every host that has pthreads.
typedef struct
    {
    pthread_mutex_t m;
    pthread_cond_t c;
    int32_t count;
    } xt_sem_t;

void* _xt_sem_new(int32_t initial)
    {
    xt_sem_t* s = (xt_sem_t*)malloc(sizeof *s);
    if (!s)
        return 0;
    if (pthread_mutex_init(&s->m, 0) != 0)
        {
        free(s);
        return 0;
        }
    if (pthread_cond_init(&s->c, 0) != 0)
        {
        pthread_mutex_destroy(&s->m);
        free(s);
        return 0;
        }
    s->count = initial < 0 ? 0 : initial;
    return s;
    }
void _xt_sem_free(void* p)
    {
    if (!p)
        return;
    xt_sem_t* s = (xt_sem_t*)p;
    pthread_cond_destroy(&s->c);
    pthread_mutex_destroy(&s->m);
    free(s);
    }
void _xt_sem_wait(void* p)
    {
    if (!p)
        return;
    xt_sem_t* s = (xt_sem_t*)p;
    pthread_mutex_lock(&s->m);
    while (s->count <= 0)
        pthread_cond_wait(&s->c, &s->m);
    s->count--;
    pthread_mutex_unlock(&s->m);
    }
int32_t _xt_sem_trywait(void* p)
    {
    if (!p)
        return 0;
    xt_sem_t* s = (xt_sem_t*)p;
    int32_t got = 0;
    pthread_mutex_lock(&s->m);
    if (s->count > 0)
        {
        s->count--;
        got = 1;
        }
    pthread_mutex_unlock(&s->m);
    return got;
    }
void _xt_sem_post(void* p)
    {
    if (!p)
        return;
    xt_sem_t* s = (xt_sem_t*)p;
    pthread_mutex_lock(&s->m);
    s->count++;
    pthread_cond_signal(&s->c);
    pthread_mutex_unlock(&s->m);
    }

// ── Thread-local storage ─────────────────────────────────────────────────
// A key/value API rather than the `thread` storage qualifier of §3.3: TLS as a
// storage class needs Mach-O thread-local relocations the in-house assembler
// and linker do not have, and the actual requirement (per-thread scratch) is
// met by a library class. Keys are never destroyed — a program allocates a
// handful at startup, and pthread_key_delete on a live key is a use-after-free
// waiting to happen.
uint32_t _xt_tls_new(void)
    {
    pthread_key_t k;
    if (pthread_key_create(&k, 0) != 0)
        return 0xFFFFFFFFu;
    return (uint32_t)k;
    }
void _xt_tls_set(uint32_t key, void* v)
    {
    if (key != 0xFFFFFFFFu)
        pthread_setspecific((pthread_key_t)key, v);
    }
void* _xt_tls_get(uint32_t key)
    {
    return key == 0xFFFFFFFFu ? 0 : pthread_getspecific((pthread_key_t)key);
    }

#endif // _WIN32

// ── Atomics (both hosts) ─────────────────────────────────────────────────
// Sequentially consistent, which is stronger than the acquire/release model
// private:docs/Design/threading.md §6 promises — so the promise holds. These are the
// user-facing `Atomic` class's bodies; the ARC refcount does NOT come through
// here (it is emitted inline by each backend under -fthread-safe-arc).
int32_t _xt_atomic_load_i32(void* p)
    {
    return p ? __atomic_load_n((int32_t*)p, __ATOMIC_SEQ_CST) : 0;
    }
void _xt_atomic_store_i32(void* p, int32_t v)
    {
    if (p)
        __atomic_store_n((int32_t*)p, v, __ATOMIC_SEQ_CST);
    }
// Returns the value AFTER the add (so `add(1)` reads like `++x` under a lock).
int32_t _xt_atomic_add_i32(void* p, int32_t d)
    {
    return p ? __atomic_add_fetch((int32_t*)p, d, __ATOMIC_SEQ_CST) : 0;
    }
int32_t _xt_atomic_xchg_i32(void* p, int32_t v)
    {
    return p ? __atomic_exchange_n((int32_t*)p, v, __ATOMIC_SEQ_CST) : 0;
    }
// 1 on success, 0 if the slot did not hold `expected` (strong CAS — no
// spurious failure, so a caller's retry loop only spins on real contention).
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

// The race-free static-init once. Written entirely over the contract above
// (_xt_rt_lock / _xt_thread_self_id / _xt_thread_yield), so every runtime that
// has threads gets it by including it — see xt-sinit.c.
#include "xt-sinit.c"

// The per-thread teardown seam — see xt-thread-exit.c.
#include "xt-thread-exit.c"

#endif // XT_THREADS_C_INCLUDED
