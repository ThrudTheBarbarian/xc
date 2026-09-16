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

// Pool.xc — run a range of work across several threads and wait for it.
// =====================================================================
//
// private:docs/Design/threading.md Phase 4 wanted `parallel for x in arr { … }` sugar.
// This is that capability as a library call rather than syntax — the same
// ergonomic pay-off (fan a loop body across cores without writing the thread
// bookkeeping), reachable today, and with nothing new in the parser:
//
//     class Blur {
//         Image* img;
//         void row(i32 y) { … blur one row of img … }
//     }
//
//     Pool.forRange((i32)0, img.height(), &blur.row);   // returns when done
//
// The body is a `^` taking the index, so it can be a bound method (carrying its
// receiver) or a widened free function, exactly like a Thread body.
//
// ── What it guarantees ──────────────────────────────────────────────────
//   * every index in [from, to) is passed to the body exactly once;
//   * forRange does not return until all of them have;
//   * the body runs on SOME thread, and two indices may run at once.
//
// ── What it does not ────────────────────────────────────────────────────
// Nothing is synchronised for you. Bodies that touch shared state need a Mutex
// or an Atomic, and bodies that touch DIFFERENT elements of a shared array need
// nothing at all — which is the case worth arranging for.
//
// The split is contiguous chunks, one per thread, sized by Thread.cpuCount().
// That suits uniform work; for wildly uneven per-index cost, a work queue would
// be better, and this is deliberately not that.

#if ARCH_6502
#error "Pool: xt6502 has no threads (private:docs/Design/threading.md §5)"
#endif
#if ARCH_m68k
#error "Pool: the Atari ST target has no threads (private:docs/Design/threading.md §5)"
#endif

#import "Thread.xc"
#import "Foundation.xc"

// The shape of a parallel-loop body: called once per index.
typedef void XTIndexBody(i32 index);

// One thread's share of the range. A class rather than a closure because a
// thread body IS a bound method — the receiver is where its arguments live.
class XTRangeWorker
    {
    callback body void(i32 index);
    i32 lo;
    i32 hi;

    void init(void)
        {
        }

    // A factory, not a bare `new` at the call site: the call site is a loop
    // (one worker per thread), and `new` inside a loop is a leak warning — a
    // correct one in general, and wrong here only because each worker really is
    // a separate object that the caller keeps. Constructing through a static
    // method is the same idiom String.withCString uses.
    static XTRangeWorker* with(callback body void(i32 index), i32 lo, i32 hi)
        {
        XTRangeWorker* w = new XTRangeWorker();
        w.body = body;
        w.lo = lo;
        w.hi = hi;
        return w;
        }

    void run(void)
        {
        // A `^` reads null once its receiver dies; calling it then dispatches
        // through a dead object. Cheaper here than per index, too.
        if (!body)
            return;
        for (i32 i = lo; i < hi; i++)
            body(i);
        }
    }

    class Pool
    {
    void init(void)
        {
        }

    // Run body(i) for every i in [from, to), across up to `threads` threads.
    // `threads` <= 1 runs the whole range on the calling thread — which is not
    // a degenerate case to apologise for but the right answer for a small
    // range: spawning costs more than the work.
    static void forRangeWithThreads(i32 from, i32 to, callback body void(i32 index), i32 threads)
        {
        if (to <= from)
            return;
        i32 total = to - from;
        if (threads < (i32)1)
            threads = (i32)1;
        if (threads > total)
            threads = total; // never more threads than indices

        if (!body)
            return;
        if (threads == (i32)1)
            {
            for (i32 i = from; i < to; i++)
                body(i);
            return;
            }

        // Chunk sizes differ by at most one, so no thread gets a whole extra
        // index's worth of work more than another.
        i32 base = total / threads;
        i32 extra = total - base * threads;

        Array* workers = new Array();
        Array* handles = new Array();
        i32 next = from;
        for (i32 t = (i32)0; t < threads; t++)
            {
            i32 n = base;
            if (t < extra)
                n = n + (i32)1;
            XTRangeWorker* w = XTRangeWorker.with(body, next, next + n);
            next = w.hi;
            workers.add((Object*)w); // keep the receiver alive: a `^`
                                     // never retains it (see Thread.xc)
            handles.add((Object*)Thread.spawn(&w.run));
            }

        // A thread that never started leaves its chunk undone, and nothing
        // above says so: `Thread.spawn` returns a Thread either way, and a
        // failed one just carries a null handle. Without the fallback below the
        // indices in that chunk are silently skipped and forRange returns as if
        // it had run them — breaking the first guarantee above, quietly, which
        // is the worst way to break it. Not hypothetical: on a kernel with no
        // thread syscalls every spawn fails, and `forRangeWithThreads(0, 3,
        // body, 16)` visited nothing at all.
        //
        // `join()` is the signal, not `isValid()`: a successful join CONSUMES
        // the handle, so isValid() reads false afterwards for started and
        // never-started threads alike, and testing it would re-run every chunk
        // — every index twice.
        for (u16 i = (u16)0; i < handles.count(); i++)
            {
            if (((Thread*)handles.get(i)).join())
                continue;
            // Never started (or already joined): run its chunk here, the same
            // path `threads == 1` takes.
            ((XTRangeWorker*)workers.get((u32)i)).run();
            }
        }

    // The common form: as many threads as the host has cores.
    static void forRange(i32 from, i32 to, callback body void(i32 index))
        {
        forRangeWithThreads(from, to, body, Thread.cpuCount());
        }
    }
