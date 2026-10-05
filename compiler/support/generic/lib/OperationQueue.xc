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
// This library is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// Under Section 7 of the GPL, as an additional permission, you may combine
// this library with your own code and distribute the result under terms of
// your choice; see COPYING.RUNTIME in this directory for the exact terms.
//
// OperationQueue.xc — Operation and OperationQueue: units of work, with
// dependencies, priorities and cancellation, run by queues.
//
//   OperationQueue* q = new OperationQueue();   // up to Thread.cpuCount() at once
//   Operation* load = Operation.withBlock(block void(void) { ... });
//   Operation* show = Operation.withBlock(block void(void) { ... });
//   show.addDependency(load);             // show starts after load finishes
//   q.add(load);
//   q.add(show);
//   q.waitUntilAllFinished();
//
// On a target with threads a queue runs up to setMaxConcurrent() operations
// at once on worker threads it starts as it needs them. On one without
// (xt6502, m68k, wasm32) a queue runs its operations on the caller's thread,
// in dependency and priority order, when the caller waits on it; the result is
// that of a serial queue. OperationQueue.main() runs on RunLoop.main() where
// there is one, and like a queue without threads elsewhere (arm9).
//
// One lock guards every operation and queue: a dependency on another queue
// finishes on that queue's thread, and one lock keeps the two in step simply.
// The first queue or dependency a program makes should be made before it
// starts other threads of its own.

#import "Foundation.xc"

#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
#import "Thread.xc"
#import "Mutex.xc"
#import "Cond.xc"
#endif
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32 || ARCH_arm9)
#import "RunLoop.xc"
#endif

#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
Mutex* _opq_lock = (Mutex*)0;
#endif
Array* _opq_queues = (Array*)0;    // every queue, for draining without threads

void _opqEnter(void)
    {
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
    if (_opq_lock == (Mutex*)0)
        _opq_lock = new Mutex();
    _opq_lock.lock();
#endif
    }

void _opqLeave(void)
    {
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
    _opq_lock.unlock();
#endif
    }

// ── Operation ───────────────────────────────────────────────────────────────

class Operation : Object
    {
    block _work void(void);
    bool _hasWork;
    block _done void(void);
    bool _hasDone;
    Array* _deps;          // Operation@ this one waits on
    Array* _dependents;    // Operation@ waiting on this one; emptied when it finishes
    u32 _waiting;          // dependencies not yet finished
    i32 _priority;
    u8 _state;             // 0 not queued, 1 queued, 2 executing, 3 finished
    bool _cancelled;
    OperationQueue* _queue; // while queued or executing
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
    Cond* _finished;
#endif

    void init(void)
        {
        _deps = new Array();
        _dependents = new Array();
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
        _finished = new Cond();
#endif
        }

    // The three priorities, for setPriority (any i32 between works too).
    static i32 low(void) { return (i32)-4; }
    static i32 normal(void) { return (i32)0; }
    static i32 high(void) { return (i32)4; }

    // An operation whose work is a block.
    static Operation* withBlock(block work void(void))
        {
        Operation* op = new Operation();
        op._work = work;
        op._hasWork = true;
        return op;
        }

    // The work. A subclass overrides it; an operation from withBlock runs its
    // block. A long one should check isCancelled() and return early.
    void main(void)
        {
        if (_hasWork)
            _work();
        }

    // Start only after `op` has finished (or been cancelled). A dependency may
    // be on another queue. One that would make a cycle is refused.
    void addDependency(Operation* op)
        {
        if (op == (Operation*)0 || op == self)
            return;
        _opqEnter();
        if (op._dependsOn(self))
            {
            _opqLeave();
            Log.error("Operation.addDependency: that would make a cycle; not added");
            return;
            }
        if (_state >= (u8)2)
            {
            _opqLeave();
            Log.error("Operation.addDependency: the operation has already started; not added");
            return;
            }
        _deps.add((Object*)op);
        if (op._state != (u8)3)
            {
            op._dependents.add((Object*)self);
            _waiting = _waiting + (u32)1;
            // Queued and ready already: back to waiting.
            if (_state == (u8)1 && _waiting == (u32)1 && !_cancelled)
                _queue._unready(self);
            }
        _opqLeave();
        }

    void removeDependency(Operation* op)
        {
        _opqEnter();
        bool had = false;
        for (u32 i = (u32)0; i < _deps.count(); i = i + (u32)1)
            if (_deps.get(i) == (Object*)op)
                {
                _deps.removeAt(i);
                had = true;
                break;
                }
        if (had && op._state != (u8)3)
            {
            for (u32 i = (u32)0; i < op._dependents.count(); i = i + (u32)1)
                if (op._dependents.get(i) == (Object*)self)
                    {
                    op._dependents.removeAt(i);
                    break;
                    }
            _waiting = _waiting - (u32)1;
            if (_waiting == (u32)0 && _state == (u8)1)
                _queue._makeReady(self);
            }
        _opqLeave();
        }

    Array* dependencies(void)
        {
        _opqEnter();
        Array* out = new Array();
        for (u32 i = (u32)0; i < _deps.count(); i = i + (u32)1)
            out.add(_deps.get(i));
        _opqLeave();
        return out;
        }

    // Runs after main(), on the same thread, before the operation counts as
    // finished.
    void setCompletion(block done void(void))
        {
        _done = done;
        _hasDone = true;
        }

    // Orders the ready operations of one queue: higher first, first come
    // first within one priority. Never overrides a dependency.
    void setPriority(i32 p)
        {
        _priority = p;
        }

    i32 priority(void)
        {
        return _priority;
        }

    // Not started: it never runs main() (its completion still runs) and its
    // dependents go ahead. Running: isCancelled() turns true for main() to see.
    void cancel(void)
        {
        _opqEnter();
        _cancelled = true;
        // Waiting on dependencies: a cancelled operation no longer does.
        if (_state == (u8)1 && _waiting > (u32)0)
            {
            _waiting = (u32)0;
            _queue._makeReady(self);
            }
        _opqLeave();
        }

    bool isCancelled(void)
        {
        _opqEnter();
        bool c = _cancelled;
        _opqLeave();
        return c;
        }

    // Every dependency has finished (or the operation is cancelled).
    bool isReady(void)
        {
        _opqEnter();
        bool r = _waiting == (u32)0 || _cancelled;
        _opqLeave();
        return r;
        }

    bool isExecuting(void)
        {
        _opqEnter();
        bool e = _state == (u8)2;
        _opqLeave();
        return e;
        }

    bool isFinished(void)
        {
        _opqEnter();
        bool f = _state == (u8)3;
        _opqLeave();
        return f;
        }

    // Block until the operation has finished. Without threads, the queues
    // run on this thread until it has.
    void waitUntilFinished(void)
        {
#if ARCH_6502 || ARCH_m68k || ARCH_wasm32
        while (_state != (u8)3 && OperationQueue._drainOne())
            {
            }
#else
        _opqEnter();
        if (_queue != (OperationQueue*)0 && _queue._onCaller)
            {
            _opqLeave();
            while (!isFinished() && OperationQueue._drainOne())
                {
                }
            return;
            }
        while (_state != (u8)3)
            _finished.wait(_opq_lock);
        _opqLeave();
#endif
        }

    // ── inside ───────────────────────────────────────────────────────────────

    // Whether `target` is among this operation's dependencies, however deep.
    // Called with the lock held.
    bool _dependsOn(Operation* target)
        {
        for (u32 i = (u32)0; i < _deps.count(); i = i + (u32)1)
            {
            Operation* d = (Operation*)_deps.get(i);
            if (d == target || d._dependsOn(target))
                return true;
            }
        return false;
        }

    // Run on the queue's behalf: main() unless cancelled, the completion,
    // then finish. Called without the lock.
    void _run(void)
        {
        _opqEnter();
        _state = (u8)2;
        bool skip = _cancelled;
        _opqLeave();
        if (!skip)
            main();
        if (_hasDone)
            _done();
        _opqEnter();
        _state = (u8)3;
        Array* waiting = _dependents;
        _dependents = new Array();
        for (u32 i = (u32)0; i < waiting.count(); i = i + (u32)1)
            {
            Operation* d = (Operation*)waiting.get(i);
            if (d._waiting > (u32)0)
                {
                d._waiting = d._waiting - (u32)1;
                if (d._waiting == (u32)0 && d._state == (u8)1)
                    d._queue._makeReady(d);
                }
            }
        OperationQueue* q = _queue;
        _queue = (OperationQueue*)0;
        q._finished(self);
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
        _finished.broadcast();
#endif
        _opqLeave();
        }
    }

// ── OperationQueue ──────────────────────────────────────────────────────────

OperationQueue* _opq_main = (OperationQueue*)0;

class OperationQueue : Object
    {
    Array* _ready;      // Operation@ ready to run, highest priority first
    Array* _all;        // Operation@ queued or executing
    i32 _max;
    u32 _running;
    u32 _workers;
    u32 _idle;          // workers waiting for work
    bool _suspended;
    bool _onCaller;     // runs on the thread that waits (no threads, or main without a run loop)
    bool _isMain;
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
    Cond* _work;        // an operation became ready, or the queue resumed
    Cond* _drained;     // the queue became empty
#endif

    void init(void)
        {
        _ready = new Array();
        _all = new Array();
#if ARCH_6502 || ARCH_m68k || ARCH_wasm32
        _max = (i32)1;
        _onCaller = true;
#else
        _max = Thread.cpuCount();
        if (_max < (i32)1)
            _max = (i32)1;
        _work = new Cond();
        _drained = new Cond();
#endif
        _opqEnter();
        if (_opq_queues == (Array*)0)
            _opq_queues = new Array();
        _opq_queues.add((Object*)self);
        _opqLeave();
        }

    // A queue that runs one operation at a time, in priority then arrival
    // order.
    static OperationQueue* serial(void)
        {
        OperationQueue* q = new OperationQueue();
        q._max = (i32)1;
        return q;
        }

    // The queue for work that must run on the main thread: each operation is
    // posted to RunLoop.main(). Without a run loop (arm9) or threads, it runs
    // when the program waits on it.
    static OperationQueue* main(void)
        {
        if (_opq_main == (OperationQueue*)0)
            {
            _opq_main = new OperationQueue();
            _opq_main._max = (i32)1;
            _opq_main._isMain = true;
#if ARCH_6502 || ARCH_m68k || ARCH_wasm32 || ARCH_arm9
            _opq_main._onCaller = true;
#endif
            }
        return _opq_main;
        }

    // Queue an operation. An operation goes to one queue, once.
    void add(Operation* op)
        {
        if (op == (Operation*)0)
            return;
        _opqEnter();
        if (op._state != (u8)0)
            {
            _opqLeave();
            Log.error("OperationQueue.add: the operation is already queued or finished; not added");
            return;
            }
        op._state = (u8)1;
        op._queue = self;
        _all.add((Object*)op);
        if (op._waiting == (u32)0)
            _makeReady(op);
        _opqLeave();
        }

    // Queue a block as an operation, and return it.
    Operation* addBlock(block work void(void))
        {
        Operation* op = Operation.withBlock(work);
        add(op);
        return op;
        }

    void addAll(Array* ops, bool wait)
        {
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            add((Operation*)ops.get(i));
        if (wait)
            for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
                ((Operation*)ops.get(i)).waitUntilFinished();
        }

    // How many operations run at once; 1 makes the queue serial.
    void setMaxConcurrent(i32 n)
        {
        _opqEnter();
        _max = n < (i32)1 ? (i32)1 : n;
        if (_isMain || _onCaller)
            _max = (i32)1;
        _wake();
        _opqLeave();
        }

    // The operations queued or running.
    i32 count(void)
        {
        _opqEnter();
        i32 n = (i32)_all.count();
        _opqLeave();
        return n;
        }

    void cancelAll(void)
        {
        _opqEnter();
        Array* ops = new Array();
        for (u32 i = (u32)0; i < _all.count(); i = i + (u32)1)
            ops.add(_all.get(i));
        _opqLeave();
        for (u32 i = (u32)0; i < ops.count(); i = i + (u32)1)
            ((Operation*)ops.get(i)).cancel();
        }

    // Stop starting operations; those running finish.
    void suspend(void)
        {
        _opqEnter();
        _suspended = true;
        _opqLeave();
        }

    void resume(void)
        {
        _opqEnter();
        _suspended = false;
        _wake();
        if (_isMain && !_onCaller)
            for (u32 i = (u32)0; i < _ready.count(); i = i + (u32)1)
                _postMain();
        _opqLeave();
        }

    bool isSuspended(void)
        {
        _opqEnter();
        bool s = _suspended;
        _opqLeave();
        return s;
        }

    // Block until every operation queued so far has finished. Without
    // threads (or for the main queue without a run loop), they run here.
    void waitUntilAllFinished(void)
        {
        if (_onCaller)
            {
            while (count() > (i32)0 && OperationQueue._drainOne())
                {
                }
            return;
            }
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
#if !ARCH_arm9
        // The main queue's operations run on the main run loop; waiting for
        // them on the thread that runs it would never return, so run them.
        if (_isMain)
            {
            while (count() > (i32)0)
                RunLoop.main().runPending();
            return;
            }
#endif
        _opqEnter();
        while (_all.count() > (u32)0)
            _drained.wait(_opq_lock);
        _opqLeave();
#endif
        }

    // ── inside (the lock is held unless said otherwise) ────────────────────────

    // `op` is ready: into the ready list by priority, and something to run it.
    void _makeReady(Operation* op)
        {
        u32 at = _ready.count();
        for (u32 i = (u32)0; i < _ready.count(); i = i + (u32)1)
            if (((Operation*)_ready.get(i))._priority < op._priority)
                {
                at = i;
                break;
                }
        _ready.insert(at, (Object*)op);
        if (_isMain && !_onCaller)
            {
            if (!_suspended)
                _postMain();
            return;
            }
        _wake();
        }

    // `op` was ready and is waiting on a dependency again.
    void _unready(Operation* op)
        {
        for (u32 i = (u32)0; i < _ready.count(); i = i + (u32)1)
            if (_ready.get(i) == (Object*)op)
                {
                _ready.removeAt(i);
                return;
                }
        }

    void _finished(Operation* op)
        {
        for (u32 i = (u32)0; i < _all.count(); i = i + (u32)1)
            if (_all.get(i) == (Object*)op)
                {
                _all.removeAt(i);
                break;
                }
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
        if (_all.count() == (u32)0)
            _drained.broadcast();
#endif
        }

    // The next operation this queue may start now, taken off the ready list,
    // or nil.
    Operation* _take(void)
        {
        if (_suspended || _ready.count() == (u32)0 || (i32)_running >= _max)
            return (Operation*)0;
        Operation* op = (Operation*)_ready.get((u32)0);
        _ready.removeAt((u32)0);
        _running = _running + (u32)1;
        return op;
        }

    // Wake an idle worker, or start one, for work that can start.
    void _wake(void)
        {
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
        if (_onCaller || _isMain)
            return;
        if (_suspended || _ready.count() == (u32)0)
            return;
        if (_idle > (u32)0)
            {
            _work.signal();
            return;
            }
        if ((i32)_workers < _max)
            {
            _workers = _workers + (u32)1;
            Thread* t = Thread.spawn(&self._worker);
            t.detach();
            }
#endif
        }

#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
    // A worker thread: run whatever can start, wait when nothing can.
    void _worker(void)
        {
        _opqEnter();
        while (true)
            {
            Operation* op = _take();
            if (op == (Operation*)0)
                {
                _idle = _idle + (u32)1;
                _work.wait(_opq_lock);
                _idle = _idle - (u32)1;
                continue;
                }
            _opqLeave();
            op._run();
            _opqEnter();
            _running = _running - (u32)1;
            }
        }
#endif

#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32 || ARCH_arm9)
    // One ready operation to the main run loop.
    void _postMain(void)
        {
        RunLoop.main().post(block void(void) { OperationQueue._runMainOne(); });
        }

    static void _runMainOne(void)
        {
        OperationQueue* q = OperationQueue.main();
        _opqEnter();
        Operation* op = q._take();
        _opqLeave();
        if (op == (Operation*)0)
            return;
        op._run();
        _opqEnter();
        q._running = q._running - (u32)1;
        _opqLeave();
        }
#else
    void _postMain(void)
        {
        }
#endif

    // Without threads: run one ready operation from any queue on this
    // thread. False when none can run. Called without the lock.
    static bool _drainOne(void)
        {
        _opqEnter();
        Operation* op = (Operation*)0;
        OperationQueue* from = (OperationQueue*)0;
        for (u32 i = (u32)0; _opq_queues != (Array*)0 && i < _opq_queues.count() && op == (Operation*)0; i = i + (u32)1)
            {
            OperationQueue* q = (OperationQueue*)_opq_queues.get(i);
            if (!q._onCaller)
                continue;
            op = q._take();
            from = q;
            }
        _opqLeave();
        if (op == (Operation*)0)
            return false;
        op._run();
        _opqEnter();
        from._running = from._running - (u32)1;
        _opqLeave();
        return true;
        }
    }
