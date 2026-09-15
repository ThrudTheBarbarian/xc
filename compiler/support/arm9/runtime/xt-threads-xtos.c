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

// xt-threads-xtos.c — the xtc threading primitives on XTOS (arm9 / Cortex-A9).
//
// The third body of the one `_xt_*` contract. Its siblings are
// support/generic/runtime/xt-threads.c (anything with a libc: pthreads or Win32)
// and src/xtc/support-src/rt-freestanding.c (raw clone+futex, or kernel32). This
// one is included by support/arm9/runtime/libxt-pic.c, so the arm9 PIC runtime
// carries it exactly the way the host runtimes carry theirs.
//
// ── What the kernel gives us, and what we build ──────────────────────────
//
// XTOS provides thread LIFECYCLE and a FUTEX, and nothing else (the XTOS
// loader's kernel/xtsys.h). So Mutex, Cond and Sem are built HERE, in user space, over one
// atomic word plus futex wait/wake:
//
//   * an uncontended lock or unlock is `ldrex`/`strex` and nothing else — no
//     syscall, no ring transition;
//   * the kernel is entered only to block and to wake, which is exactly when a
//     syscall is cheap relative to what it is replacing.
//
// The A9's exclusive monitor is unprivileged, so every atomic below runs at PL0
// with no help from the kernel — the same reason threading.md §4.1 chose
// `ldrex`/`strex` for the ARC refcount over an interrupt-disable bracket.
//
// ── Thread-local storage ─────────────────────────────────────────────────
//
// Each thread reaches its own slot block through TPIDRURW, which the kernel
// saves and restores per thread on every context switch. A `_xt_tls_get` is
// therefore one `mrc` plus an index — no syscall, no table walk, no lock — and
// the block is the same per-thread context block §9.8 describes as the cheap
// route to a future `thread` storage qualifier.
//
// ── The one thing that is NOT here ───────────────────────────────────────
//
// The ARC refcount. It is emitted INLINE by the arm9 back end as an
// `ldrexh`/`strexh` retry loop under -fthread-safe-arc, which the compiler turns
// on for any module that references `_xt_thread_create` (threading.md §4.1,
// §9.2). It is the hot path; this file is not.

#ifndef XT_THREADS_XTOS_C_INCLUDED
#define XT_THREADS_XTOS_C_INCLUDED

#include <stdint.h>
#include <stdlib.h>

// XTOS syscall numbers (the frozen ABI in the XTOS loader's kernel/xtsys.h). Spelled
// out rather than #included: this file is compiled against the xtc support tree,
// which does not have the kernel's headers on its include path.
#define XT_SYS_THREAD_CREATE 0x10E
#define XT_SYS_THREAD_EXIT 0x10F
#define XT_SYS_THREAD_JOIN 0x110
#define XT_SYS_THREAD_DETACH 0x111
#define XT_SYS_THREAD_SELF 0x112
#define XT_SYS_THREAD_TLS 0x113
#define XT_SYS_FUTEX_WAIT 0x114
#define XT_SYS_FUTEX_WAKE 0x115
#define XT_SYS_NANOSLEEP 0x402

static long xt_tsc(long n, long a0, long a1, long a2)
    {
    register long r7 asm("r7") = n;
    register long r0 asm("r0") = a0;
    register long r1 asm("r1") = a1;
    register long r2 asm("r2") = a2;
    asm volatile("svc #1" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
    }

// ── Are we multi-threaded yet? ───────────────────────────────────────────
// Same contract as the host runtimes: set once, before a second thread can
// exist, and only read after. The runtime's own weak-reference list tests it so
// a single-threaded program pays a load-and-branch instead of a lock.
int _xt_threads_active = 0;
int32_t _xt_threads_multi(void)
    {
    return (int32_t)_xt_threads_active;
    }

// ── The A9 exclusive monitor, once ───────────────────────────────────────
static inline void xt_barrier(void)
    {
    asm volatile("dmb ish" ::: "memory");
    }

static uint32_t xt_cas32(volatile uint32_t* p, uint32_t expect, uint32_t want)
    {
    uint32_t old, fail;
    for (;;)
        {
        asm volatile("ldrex %0, [%1]" : "=&r"(old) : "r"(p) : "memory");
        if (old != expect)
            {
            asm volatile("clrex" ::: "memory");
            return old;
            }
        asm volatile("strex %0, %2, [%1]" : "=&r"(fail) : "r"(p), "r"(want) : "memory");
        if (!fail)
            break;
        }
    xt_barrier();
    return old;
    }

static uint32_t xt_swap32(volatile uint32_t* p, uint32_t want)
    {
    uint32_t old, fail;
    do
        {
        asm volatile("ldrex %0, [%1]" : "=&r"(old) : "r"(p) : "memory");
        asm volatile("strex %0, %2, [%1]" : "=&r"(fail) : "r"(p), "r"(want) : "memory");
        } while (fail);
    xt_barrier();
    return old;
    }

static int32_t xt_add32(volatile int32_t* p, int32_t d)
    {
    int32_t old, nv;
    uint32_t fail;
    do
        {
        asm volatile("ldrex %0, [%1]" : "=&r"(old) : "r"(p) : "memory");
        nv = old + d;
        asm volatile("strex %0, %2, [%1]" : "=&r"(fail) : "r"(p), "r"(nv) : "memory");
        } while (fail);
    xt_barrier();
    return nv; // the value AFTER the add, as the class documents
    }

// ── The futex-backed lock every object below is built from ───────────────
// 0 = free, 1 = held, 2 = held with a waiter. The 2 state is what lets unlock
// skip the wake syscall entirely when nobody is waiting, which is the common
// case even in a threaded program.
typedef struct
    {
    volatile uint32_t state;
    } xt_lock_t;

static void xt_lock(xt_lock_t* l)
    {
    if (xt_cas32(&l->state, 0, 1) == 0)
        return; // uncontended: no syscall
    while (xt_swap32(&l->state, 2) != 0)
        xt_tsc(XT_SYS_FUTEX_WAIT, (long)&l->state, 2, -1);
    }

static int xt_trylock(xt_lock_t* l)
    {
    return xt_cas32(&l->state, 0, 1) == 0;
    }

static void xt_unlock(xt_lock_t* l)
    {
    xt_barrier();
    if (xt_swap32(&l->state, 0) == 2)
        xt_tsc(XT_SYS_FUTEX_WAKE, (long)&l->state, 1, 0);
    }

// ── Threads ──────────────────────────────────────────────────────────────
// A thread body is an xtc bound method — the `^` fat pointer {recv, code} whose
// uniform ABI is `code(recv)`. XTOS hands a new thread ONE argument, so the pair
// travels in a heap starter the entry copies out and frees: no thread-entry ABI
// is invented here either.
typedef struct
    {
    void* code;
    void* recv;
    } xt_start_t;

void _xt_thread_exiting(void);
static void xt_thread_entry(void* p)
    {
    xt_start_t s = *(xt_start_t*)p;
    free(p);
    if (s.code)
        ((void (*)(void*))s.code)(s.recv);
    _xt_thread_exiting(); // per-thread teardown (xt-thread-exit.c)
    // returning traps through SYS_thread_exit (loader/test/freertos/xt_vectors.S)
    }

void* _xt_thread_create(void* code, void* recv)
    {
    if (!code)
        return 0;
    _xt_threads_active = 1; // before a second thread can observe anything
    xt_start_t* s = (xt_start_t*)malloc(sizeof *s);
    if (!s)
        return 0;
    s->code = code;
    s->recv = recv;
    long tid = xt_tsc(XT_SYS_THREAD_CREATE, (long)xt_thread_entry, (long)s, 0);
    if (tid <= 0)
        {
        free(s);
        return 0;
        }
    // The handle is the tid, not a pointer: XTOS tids start at 1, so the encoding
    // below never produces 0 and `isValid()` keeps meaning what it means.
    return (void*)(uintptr_t)tid;
    }

int32_t _xt_thread_join(void* h)
    {
    if (!h)
        return -1;
    return xt_tsc(XT_SYS_THREAD_JOIN, (long)(uintptr_t)h, 0, 0) == 0 ? 0 : -1;
    }

void _xt_thread_detach(void* h)
    {
    if (h)
        xt_tsc(XT_SYS_THREAD_DETACH, (long)(uintptr_t)h, 0, 0);
    }

// A zero-length sleep is a scheduler yield on XTOS (vTaskDelay(0) -> taskYIELD),
// which is exactly the hint this call is specified to be.
void _xt_thread_yield(void)
    {
    xt_tsc(XT_SYS_NANOSLEEP, 0, 0, 0);
    }
void _xt_thread_sleep_ms(uint32_t ms)
    {
    xt_tsc(XT_SYS_NANOSLEEP, (long)(ms * 1000u), 0, 0);
    }

uint32_t _xt_thread_self_id(void)
    {
    return (uint32_t)xt_tsc(XT_SYS_THREAD_SELF, 0, 0, 0);
    }

// One A9 core is available to a process today: XTOS's FreeRTOS runs CPU0, and
// CPU1 is dedicated AMP. Pool sizing reads this, so it must be
// honest rather than optimistic — claiming 2 would just add context switches.
int32_t _xt_thread_cpu_count(void)
    {
    return 1;
    }

// ── The runtime's own lock ───────────────────────────────────────────────
static xt_lock_t xt_rt_lock_obj;
void _xt_rt_lock(void)
    {
    if (_xt_threads_active)
        xt_lock(&xt_rt_lock_obj);
    }
void _xt_rt_unlock(void)
    {
    if (_xt_threads_active)
        xt_unlock(&xt_rt_lock_obj);
    }

// ── Mutex ────────────────────────────────────────────────────────────────
void* _xt_mutex_new(void)
    {
    xt_lock_t* m = (xt_lock_t*)malloc(sizeof *m);
    if (m)
        m->state = 0;
    return m;
    }
void _xt_mutex_free(void* m)
    {
    free(m);
    }
void _xt_mutex_lock(void* m)
    {
    if (m)
        xt_lock((xt_lock_t*)m);
    }
void _xt_mutex_unlock(void* m)
    {
    if (m)
        xt_unlock((xt_lock_t*)m);
    }
int32_t _xt_mutex_trylock(void* m)
    {
    return m ? (int32_t)xt_trylock((xt_lock_t*)m) : 0;
    }

// ── Condition variable ───────────────────────────────────────────────────
// A sequence counter plus the futex. wait() reads the sequence, drops the mutex,
// and sleeps until the counter MOVES — so a signal that lands between the drop
// and the sleep is not lost (the sequence has already changed, and futex_wait
// compares before it enqueues, atomically against wake). That is the whole
// reason the kernel's compare-and-enqueue is one step.
typedef struct
    {
    volatile uint32_t seq;
    } xt_cond_t;

void* _xt_cond_new(void)
    {
    xt_cond_t* c = (xt_cond_t*)malloc(sizeof *c);
    if (c)
        c->seq = 0;
    return c;
    }
void _xt_cond_free(void* c)
    {
    free(c);
    }

void _xt_cond_wait(void* cv, void* m)
    {
    if (!cv || !m)
        return;
    xt_cond_t* c = (xt_cond_t*)cv;
    uint32_t seen = c->seq;
    xt_unlock((xt_lock_t*)m);
    xt_tsc(XT_SYS_FUTEX_WAIT, (long)&c->seq, (long)seen, -1);
    xt_lock((xt_lock_t*)m);
    }

void _xt_cond_signal(void* cv)
    {
    if (!cv)
        return;
    xt_cond_t* c = (xt_cond_t*)cv;
    xt_add32((volatile int32_t*)&c->seq, 1);
    xt_tsc(XT_SYS_FUTEX_WAKE, (long)&c->seq, 1, 0);
    }

void _xt_cond_broadcast(void* cv)
    {
    if (!cv)
        return;
    xt_cond_t* c = (xt_cond_t*)cv;
    xt_add32((volatile int32_t*)&c->seq, 1);
    xt_tsc(XT_SYS_FUTEX_WAKE, (long)&c->seq, -1, 0); // -1 = every waiter
    }

// ── Counting semaphore ───────────────────────────────────────────────────
// Straight on the futex: the count IS the futex word, so an uncontended wait or
// post is one atomic and no syscall.
typedef struct
    {
    volatile int32_t count;
    } xt_sem_t;

void* _xt_sem_new(int32_t initial)
    {
    xt_sem_t* s = (xt_sem_t*)malloc(sizeof *s);
    if (s)
        s->count = initial < 0 ? 0 : initial;
    return s;
    }
void _xt_sem_free(void* p)
    {
    free(p);
    }

void _xt_sem_wait(void* p)
    {
    if (!p)
        return;
    xt_sem_t* s = (xt_sem_t*)p;
    for (;;)
        {
        int32_t n = s->count;
        if (n > 0)
            {
            if (xt_cas32((volatile uint32_t*)&s->count, (uint32_t)n, (uint32_t)(n - 1)) == (uint32_t)n)
                return;
            continue; // lost the race; re-read
            }
        xt_tsc(XT_SYS_FUTEX_WAIT, (long)&s->count, 0, -1); // sleep while it is still 0
        }
    }

int32_t _xt_sem_trywait(void* p)
    {
    if (!p)
        return 0;
    xt_sem_t* s = (xt_sem_t*)p;
    for (;;)
        {
        int32_t n = s->count;
        if (n <= 0)
            return 0;
        if (xt_cas32((volatile uint32_t*)&s->count, (uint32_t)n, (uint32_t)(n - 1)) == (uint32_t)n)
            return 1;
        }
    }

void _xt_sem_post(void* p)
    {
    if (!p)
        return;
    xt_sem_t* s = (xt_sem_t*)p;
    xt_add32(&s->count, 1);
    xt_tsc(XT_SYS_FUTEX_WAKE, (long)&s->count, 1, 0);
    }

// ── Thread-local storage ─────────────────────────────────────────────────
// A key/value surface over the per-thread block TPIDRURW points at, which is the
// shape §9.3 settled on for the freestanding runtimes and §9.8 wants a future
// `thread` qualifier to lower to. The block is allocated on a thread's first
// touch rather than at spawn, so a thread that never uses TLS pays nothing and
// no path needs an "am I the first thread?" test.
#define XT_TLS_SLOTS 32

static void** xt_tls_block(void)
    {
    void** b;
    asm volatile("mrc p15,0,%0,c13,c0,2" : "=r"(b));
    if (!b)
        {
        b = (void**)calloc(XT_TLS_SLOTS, sizeof(void*));
        if (!b)
            return 0;
        xt_tsc(XT_SYS_THREAD_TLS, (long)b, 0, 0); // the kernel keeps it across switches
        }
    return b;
    }

static volatile int32_t xt_tls_next = 0;

uint32_t _xt_tls_new(void)
    {
    int32_t k = xt_add32(&xt_tls_next, 1) - 1;
    return k < XT_TLS_SLOTS ? (uint32_t)k : 0xFFFFFFFFu;
    }

void _xt_tls_set(uint32_t key, void* v)
    {
    if (key >= XT_TLS_SLOTS)
        return;
    void** b = xt_tls_block();
    if (b)
        b[key] = v;
    }

void* _xt_tls_get(uint32_t key)
    {
    if (key >= XT_TLS_SLOTS)
        return 0;
    void** b = xt_tls_block();
    return b ? b[key] : 0;
    }

// ── Atomics ──────────────────────────────────────────────────────────────
// The user-facing `Atomic` class's bodies. Sequentially consistent (barriers on
// both sides), which is stronger than the acquire/release model §6 promises, so
// the promise holds.
int32_t _xt_atomic_load_i32(void* p)
    {
    if (!p)
        return 0;
    int32_t v = *(volatile int32_t*)p;
    xt_barrier();
    return v;
    }
void _xt_atomic_store_i32(void* p, int32_t v)
    {
    if (!p)
        return;
    xt_barrier();
    *(volatile int32_t*)p = v;
    xt_barrier();
    }
int32_t _xt_atomic_add_i32(void* p, int32_t d)
    {
    return p ? xt_add32((volatile int32_t*)p, d) : 0;
    }
int32_t _xt_atomic_xchg_i32(void* p, int32_t v)
    {
    return p ? (int32_t)xt_swap32((volatile uint32_t*)p, (uint32_t)v) : 0;
    }
int32_t _xt_atomic_cas_i32(void* p, int32_t expected, int32_t desired)
    {
    if (!p)
        return 0;
    return xt_cas32((volatile uint32_t*)p, (uint32_t)expected, (uint32_t)desired) == (uint32_t)expected ? 1 : 0;
    }
void* _xt_atomic_load_ptr(void* p)
    {
    if (!p)
        return 0;
    void* v = *(void* volatile*)p;
    xt_barrier();
    return v;
    }
void _xt_atomic_store_ptr(void* p, void* v)
    {
    if (!p)
        return;
    xt_barrier();
    *(void* volatile*)p = v;
    xt_barrier();
    }
int32_t _xt_atomic_cas_ptr(void* p, void* expected, void* desired)
    {
    if (!p)
        return 0;
    return xt_cas32((volatile uint32_t*)p, (uint32_t)(uintptr_t)expected,
                    (uint32_t)(uintptr_t)desired) == (uint32_t)(uintptr_t)expected
               ? 1
               : 0;
    }

// The race-free static-init once — same shared body the hosted runtimes use.
#include "../../generic/runtime/xt-sinit.c"

// The per-thread teardown seam — see xt-thread-exit.c.
#include "../../generic/runtime/xt-thread-exit.c"

#endif // XT_THREADS_XTOS_C_INCLUDED
