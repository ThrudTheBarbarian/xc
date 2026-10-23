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

// RunLoop.xc — work handed to one thread, and timers.
//
//     RunLoop* main = RunLoop.main();
//     main.post(block void(void) { … runs on main's thread … });   // any thread
//     main.after((u32)500, block void(void) { … });                // once, in 500 ms
//     Timer* t = main.every((u32)1000, block void(void) { … });    // until t.cancel()
//     main.run();                                                  // until main.stop()
//
// A run loop is a queue of blocks and the thread that runs them. `post` may be
// called from any thread; the blocks run, in the order posted, on whichever
// thread calls `run` (or `runPending`). This is how a worker hands a result
// back: Http.deliverOn(RunLoop.main()) and AsyncFiles.deliverOn(…) post their
// completions here instead of running them on their own threads.
//
// `run` blocks until `stop`. A program that already has a loop of its own —
// a UI toolkit's frame callback — calls `runPending` from it instead, which
// runs what is queued and returns.
//
// Timers fire on the loop's thread too. The timer thread sleeps until the
// next one is due (an EventQueue wait, woken when a timer is added), so a
// timer is late by about a millisecond, and nothing wakes while none is due.
// They run on the host's monotonic clock, so changing the wall clock does not
// move them.
//
// Hosted targets only (arm64, android, x86_64, win64).

#import "Foundation.xc"

#if ARCH_6502 || ARCH_m68k || ARCH_wasm32 || ARCH_arm9
#error "RunLoop: needs threads and a monotonic clock (arm64, android, x86_64 or win64)"
#endif

#import "Thread.xc"
#import "Mutex.xc"
#import "Cond.xc"
#import "Time.xc"
#import "EventQueue.xc"

// Microseconds on the host's monotonic clock. Time.timerValue counts from an
// origin the PROGRAM sets with Time.clearTimer, so a library cannot use it.
#if ARCH_win64
i32 QueryPerformanceCounter(i64* count);
i32 QueryPerformanceFrequency(i64* perSecond);
pointer LoadLibraryA(u8* name);
pointer GetProcAddress(pointer module, u8* name);
typedef u32 _RunLoopTimePeriod_t(u32 ms);
#else
struct _RunLoopTimespec { i64 sec; i64 nsec; }
i32 clock_gettime(i32 clock, pointer ts);
#endif

i64 _runloop_now_us(void)
    {
#if ARCH_win64
    // The performance counter: GetTickCount64 moves in 15.6 ms steps, which
    // no timer could be more precise than.
    i64 c = (i64)0;
    i64 f = (i64)1;
    QueryPerformanceCounter(&c);
    QueryPerformanceFrequency(&f);
    return (c / f) * (i64)1000000 + (c % f) * (i64)1000000 / f;
#else
    _RunLoopTimespec ts;
#if ARCH_x86_64 || PLATFORM_android
    clock_gettime((i32)1, (pointer)&ts);     // CLOCK_MONOTONIC on Linux
#else
    clock_gettime((i32)6, (pointer)&ts);     // CLOCK_MONOTONIC on Darwin
#endif
    return ts.sec * (i64)1000000 + ts.nsec / (i64)1000;
#endif
    }

// A scheduled block. `cancel` stops it; a one-shot timer that has fired is
// finished and cancelling it does nothing.
class Timer
    {
    RunLoop* _loop;
    block _fire void(void);
    i64 _due;          // _runloop_now_us() when it next fires
    i64 _periodUs;     // 0: once
    bool _cancelled;

    void cancel(void)
        {
        _loop._lock.lock();
        _cancelled = true;
        _loop._lock.unlock();
        }

    bool isCancelled(void)
        {
        return _cancelled;
        }
    }

// Created on first use and never released.
RunLoop* _runloop_main = (RunLoop*)0;

class RunLoop
    {
    Mutex* _lock;
    Cond* _posted;         // a block was posted, or stop() was called
    Cond* _timersChanged;  // a timer was added (wakes the timer thread)
    Array* _queue;         // blocks waiting to run, oldest first
    Array* _timers;        // Timer@, live ones
    bool _stopping;
    Thread* _ticker;
    EventQueue* _tickWake;  // the timer thread's sleep; 0 where there is none
    block _wake void(void); // setWakeHook's hook, when _hasWake
    bool _hasWake;

    void init(void)
        {
        _lock = new Mutex();
        _posted = new Cond();
        _timersChanged = new Cond();
        _queue = new Array();
        _timers = new Array();
        _stopping = false;
        _hasWake = false;
        }

    // The process's main run loop: the one a program runs on its main
    // thread, and the usual place for workers to deliver to. The first call
    // should not race another thread's first call.
    static RunLoop* main(void)
        {
        if (_runloop_main == (RunLoop*)0)
            _runloop_main = new RunLoop();
        return _runloop_main;
        }

    // Queue `work` to run on the loop's thread. Any thread may call this.
    void post(block work void(void))
        {
        _RunLoopItem* it = new _RunLoopItem();
        it.work = work;
        _lock.lock();
        _queue.add((Object*)it);
        _posted.signal();
        _lock.unlock();
        _wakeOwner();
        }

    // For a loop whose thread waits somewhere else: a UI event loop, which
    // calls runPending() on its own thread each time round. The hook is
    // called after each post (and each timer firing) from the thread that
    // posted, outside the loop's lock, so it must be safe on any thread; it
    // should do no more than wake that thread (PostMessage on Win32, a posted
    // event on macOS, a GLib context wakeup). Passing hasHook false removes it.
    void setWakeHook(block hook void(void), bool hasHook)
        {
        _lock.lock();
        _wake = hook;
        _hasWake = hasHook;
        _lock.unlock();
        }

    void _wakeOwner(void)
        {
        _lock.lock();
        bool has = _hasWake;
        block w void(void) = _wake;
        _lock.unlock();
        if (has)
            w();
        }

    // Run `work` once, `ms` milliseconds from now.
    Timer* after(u32 ms, block work void(void))
        {
        return _schedule(ms, (u32)0, work);
        }

    // Run `work` every `ms` milliseconds, starting `ms` from now, until the
    // timer is cancelled.
    Timer* every(u32 ms, block work void(void))
        {
        return _schedule(ms, ms, work);
        }

    // Run posted blocks (and timers) until stop() is called. The blocks run
    // on the calling thread.
    void run(void)
        {
        while (true)
            {
            _lock.lock();
            while (_queue.count() == (u32)0 && !_stopping)
                _posted.wait(_lock);
            if (_stopping)
                {
                _stopping = false;
                _lock.unlock();
                return;
                }
            _RunLoopItem* it = (_RunLoopItem*)_queue.get((u32)0);
            _queue.removeAt((u32)0);
            _lock.unlock();
            it.run();
            }
        }

    // Run everything queued at the time of the call and return how many
    // blocks ran. For a program that drives its own loop.
    u32 runPending(void)
        {
        _lock.lock();
        Array* batch = _queue;
        _queue = new Array();
        _lock.unlock();
        for (u32 i = (u32)0; i < batch.count(); i = i + (u32)1)
            ((_RunLoopItem*)batch.get(i)).run();
        return batch.count();
        }

    // Make run() return once the block it is running (if any) finishes. Any
    // thread may call this; a stop with no run() in progress ends the next one
    // at once.
    void stop(void)
        {
        _lock.lock();
        _stopping = true;
        _posted.signal();
        _lock.unlock();
        }

    // ── timers ───────────────────────────────────────────────────────────

    Timer* _schedule(u32 ms, u32 periodMs, block work void(void))
        {
        Timer* t = new Timer();
        t._loop = self;
        t._fire = work;
        t._periodUs = (i64)periodMs * (i64)1000;
        t._due = _runloop_now_us() + (i64)ms * (i64)1000;
        _lock.lock();
        _timers.add((Object*)t);
        if (_ticker == (Thread*)0)
            {
            _tickWake = EventQueue.make();
#if ARCH_win64
            // Windows wakes timed waits on its 15.6 ms tick unless a process
            // asks for 1 ms (winmm; since Windows 10 2004 the request is the
            // process's own): without it a timer was 8 ms late on average.
            pointer winmm = LoadLibraryA("winmm.dll");
            _RunLoopTimePeriod_t* tbp = winmm == (pointer)0 ? (_RunLoopTimePeriod_t*)0
                                        : (_RunLoopTimePeriod_t*)GetProcAddress(winmm, "timeBeginPeriod");
            if (tbp != (_RunLoopTimePeriod_t*)0)
                tbp((u32)1);
#endif
            _ticker = Thread.spawn(&self._tick);
            _ticker.detach();
            }
        _timersChanged.signal();
        _lock.unlock();
        if (_tickWake != (EventQueue*)0)
            _tickWake.wake();      // it may sleep past this one's due time
        return t;
        }

    // The timer thread: asleep while there are no timers, otherwise asleep
    // until the next is due (or one is added), posting each due timer's
    // block to the loop.
    void _tick(void)
        {
        while (true)
            {
            _lock.lock();
            while (_timers.count() == (u32)0)
                _timersChanged.wait(_lock);
            i64 now = _runloop_now_us();
            i64 next = (i64)-1;
            bool fired = false;
            Array* keep = new Array();
            for (u32 i = (u32)0; i < _timers.count(); i = i + (u32)1)
                {
                Timer* t = (Timer*)_timers.get(i);
                if (t._cancelled)
                    continue;
                if (now >= t._due)
                    {
                    _RunLoopItem* it = new _RunLoopItem();
                    it.timer = t;
                    _queue.add((Object*)it);
                    _posted.signal();
                    fired = true;
                    if (t._periodUs == (i64)0)
                        continue;
                    t._due = t._due + t._periodUs;
                    // Far behind (the loop was busy): skip the missed ticks
                    // rather than firing them back to back.
                    if (now >= t._due)
                        t._due = now + t._periodUs;
                    }
                keep.add((Object*)t);
                if (next < (i64)0 || t._due < next)
                    next = t._due;
                }
            _timers = keep;
            _lock.unlock();
            if (fired)
                _wakeOwner();
            if (_tickWake == (EventQueue*)0)
                {
                Time.delayJiffies((u32)1);
                continue;
                }
            if (next < (i64)0)
                continue;          // none left: the wait above sleeps
            i64 left = next - _runloop_now_us();
            if (left > (i64)0)
                {
                // Rounded up: waking a little before the due time would only
                // go round again.
                i64 ms = (left + (i64)999) / (i64)1000;
                _tickWake.wait(ms > (i64)3600000 ? (i32)3600000 : (i32)ms);
                }
            }
        }
    }

// A queued block, or a due timer (whose block runs only if it has not been
// cancelled by the time the loop gets to it).
class _RunLoopItem
    {
    block work void(void);
    Timer* timer;

    void run(void)
        {
        if (timer == (Timer*)0)
            {
            work();
            return;
            }
        if (!timer._cancelled)
            timer._fire();
        }
    }
