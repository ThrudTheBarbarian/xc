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

// Thread.xc — a thread of control inside one xtc process.
// ========================================================
//
// private:docs/Design/threading.md §3.1. The surface is deliberately tiny: one spawn
// primitive and a join handle. A thread body is an ordinary **bound method**
// (`&worker.run`, the `^` fat pointer of private:docs/Design/bound-methods.md), so a
// thread gets a `self` for free and no thread-entry ABI is invented:
//
//     class Worker {
//         Image* img;
//         void run(void) { … paint into img … }
//     }
//
//     Worker* w = new Worker();
//     Thread* t = Thread.spawn(&w.run);
//     …
//     t.join();
//
// A body takes no arguments and returns nothing — arguments travel through the
// receiver's fields, which the `^` already carries. That is what sidesteps a
// variadic thread-entry convention entirely.
//
// ── Two things the caller owns ──────────────────────────────────────────
//
//  1. **The receiver's lifetime.** A `^` never retains its receiver (it cannot:
//     for a widened free function that word is a code address). So the object
//     whose method runs must outlive the thread — keep the `Worker*` in scope,
//     or hold it in a field alongside the `Thread*`. This is the same contract
//     as any stored `^`, not a threading special case.
//
//  2. **Joining or detaching.** A Thread that is neither joined nor detached
//     leaks its OS handle. `dealloc` detaches as a backstop so a dropped Thread
//     does not leak, but the thread then runs to completion unobserved.
//
// ── Shared mutable state ────────────────────────────────────────────────
//
// Two threads touching one object race on its refcount unless the program is
// compiled with atomic ARC. The compiler turns it on automatically when a
// program references `Thread.spawn` — see -fthread-safe-arc in USAGE.md and
// threading.md §4.1 — so this is not something the caller has to remember. Data
// races on the program's OWN state are the caller's to prevent, with Mutex /
// Cond / Sem / Atomic.
//
// ── Availability ────────────────────────────────────────────────────────
//
// arm64 (macOS), x86_64, win64 and arm9 (XTOS). On xt6502 and m68k there is no
// pre-emption to build on, so importing this file is a hard error rather than a
// silently sequential "thread" (§5).
//
// On arm9 a thread is an XTOS thread — its own guarded stack, sharing the
// process's address space, fds and heap — and Mutex/Cond/Sem are built in user
// space over one atomic word plus the kernel's futex pair, so an uncontended
// lock is `ldrex`/`strex` and no syscall at all
// (support/arm9/runtime/xt-threads-xtos.c). One rule there is sharper than on a
// host: a faulting thread takes its whole PROCESS down, deliberately. It held
// shared locks and half-mutated shared state, so a surviving sibling would be
// running on data nobody can vouch for.

#if ARCH_6502
#error "Thread: xt6502 has no pre-emptive scheduler — threads are unsupported on this target (private:docs/Design/threading.md §5)"
#endif
#if ARCH_m68k
#error "Thread: the Atari ST target has no pre-emption — threads are unsupported on this target (private:docs/Design/threading.md §5)"
#endif

// The shape of every thread body: no arguments, no result.
typedef void XTThreadBody(void);

// ── host primitives (support/*/runtime) ─────────────────────────────────
// `code`/`recv` are the two words of the `^`; the runtime's start routine just
// calls code(recv), which IS the bound-method ABI.
pointer _xt_thread_create(pointer code, pointer recv);
i32 _xt_thread_join(pointer handle);
void _xt_thread_detach(pointer handle);
void _xt_thread_yield(void);
void _xt_thread_sleep_ms(u32 ms);
u32 _xt_thread_self_id(void);
i32 _xt_thread_cpu_count(void);

// The calling thread's priority, from the OS where it says (setPriority).
#if OS_windows
pointer GetCurrentThread(void);
i32 SetThreadPriority(pointer thread, i32 priority);
#elif OS_darwin
i32 pthread_set_qos_class_self_np(u32 qos, i32 relative);
#elif ARCH_x86_64 || OS_linux || OS_android
i64 syscall(i64 number);
i32 setpriority(i32 which, u32 who, i32 prio);
#endif

class Thread
    {
    pointer _handle;           // opaque OS handle; 0 once joined/detached
    callback _body void(void); // kept reachable for the lifetime of the thread

    void init(void)
        {
        _handle = (pointer)0;
        }

    // Start `body` on a new thread. Returns the handle, or a Thread whose
    // `isValid()` is false if the OS refused to create one (out of resources) —
    // a null return would make every call site test for two failure shapes.
    static Thread* spawn(callback body void(void))
        {
        Thread* t = new Thread();
        t._body = body;
        t._handle = _xt_thread_create((pointer)body.code, (pointer)body.recv);
        return t;
        }

    // Did the thread actually start?
    bool isValid(void)
        {
        return _handle != (pointer)0;
        }

    // Block until the body returns. True if the thread was joined by this call;
    // false if it had already been joined or detached, or never started. The
    // handle is consumed either way, so a second join is a no-op, not a
    // use-after-free of the OS handle.
    bool join(void)
        {
        if (_handle == (pointer)0)
            return false;
        pointer h = _handle;
        _handle = (pointer)0;
        return _xt_thread_join(h) == (i32)0;
        }

    // Let the thread run unobserved; its resources are reclaimed when it exits.
    void detach(void)
        {
        if (_handle == (pointer)0)
            return;
        pointer h = _handle;
        _handle = (pointer)0;
        _xt_thread_detach(h);
        }

    // A dropped Thread detaches rather than leaking the OS handle. It does NOT
    // join: a destructor that blocks would turn "this object went out of scope"
    // into an unbounded wait, and ARC teardown order is not something to hang a
    // program's liveness on.
    void dealloc(void)
        {
        if (_handle != (pointer)0)
            {
            _xt_thread_detach(_handle);
            _handle = (pointer)0;
            }
        }

    // ── static helpers, valid on any thread ─────────────────────────────
    static void yield(void)
        {
        _xt_thread_yield();
        }
    static void sleepMs(u32 ms)
        {
        _xt_thread_sleep_ms(ms);
        }

    // An opaque identity for the calling thread: two calls on the same thread
    // give the same value, different threads give different values. It is not
    // an index and has no ordering.
    static u32 currentId(void)
        {
        return _xt_thread_self_id();
        }

    // Usable hardware parallelism — the sizing hint for a worker pool.
    static i32 cpuCount(void)
        {
        return _xt_thread_cpu_count();
        }

    // The levels setPriority takes, lowest first. A worker that should not
    // compete with the interface runs at utility or background; one the user
    // is waiting on, at userInitiated. A new thread starts at normal.
    static i32 background(void) { return (i32)-2; }
    static i32 utility(void) { return (i32)-1; }
    static i32 normal(void) { return (i32)0; }
    static i32 userInitiated(void) { return (i32)1; }

    // Set the CALLING thread's priority to one of the levels above; call it
    // first thing in a thread's body. True when the OS took it. macOS and iOS
    // map the levels to their QoS classes (a thread at the default QoS can run
    // some 40% slower than at user-initiated); Linux to the thread's nice value
    // (19, 10, 0, -5: going above normal again usually needs privileges, and is
    // then false); Windows to THREAD_PRIORITY_LOWEST..ABOVE_NORMAL. Elsewhere
    // there is nothing to set and it is false.
    static bool setPriority(i32 level)
        {
        if (level < (i32)-2 || level > (i32)1)
            return false;
#if OS_windows
        return SetThreadPriority(GetCurrentThread(), level) != (i32)0;
#elif OS_darwin
        // QOS_CLASS_BACKGROUND, _UTILITY, _DEFAULT, _USER_INITIATED.
        u32 qos = level == (i32)-2 ? (u32)$09 : level == (i32)-1 ? (u32)$11 : level == (i32)0 ? (u32)$15 : (u32)$19;
        return pthread_set_qos_class_self_np(qos, (i32)0) == (i32)0;
#elif ARCH_x86_64 || OS_linux || OS_android
        // PRIO_PROCESS with a thread id sets that thread alone on Linux; the
        // id is gettid's (186 on x86-64, 178 on arm64).
#if ARCH_x86_64
        u32 tid = (u32)syscall((i64)186);
#else
        u32 tid = (u32)syscall((i64)178);
#endif
        i32 nice = level == (i32)-2 ? (i32)19 : level == (i32)-1 ? (i32)10 : level == (i32)0 ? (i32)0 : (i32)-5;
        return setpriority((i32)0, tid, nice) == (i32)0;
#else
        return false;
#endif
        }
    }
