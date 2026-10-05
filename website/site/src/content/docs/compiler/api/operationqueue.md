---
title: OperationQueue
description: "Operation and OperationQueue (from 0.7): units of work with dependencies, priorities, cancellation and completion blocks, run by queues on worker threads, serially, or on the main run loop. A complete method reference."
---

**From 0.7.** An `Operation` is a unit of work. An `OperationQueue` runs
operations: several at once on worker threads, one at a time, or on the main
run loop. Operations can depend on each other, across queues, and can be
cancelled.

```c
#import "OperationQueue.xc"
```

## Overview

```c
OperationQueue* q = new OperationQueue();     // up to Thread.cpuCount() at once

Operation* load = Operation.withBlock(block void(void) { … });
Operation* parse = Operation.withBlock(block void(void) { … });
Operation* show = Operation.withBlock(block void(void) { … });
parse.addDependency(load);                    // parse starts after load finishes
show.addDependency(parse);

q.add(load);
q.add(parse);
OperationQueue.main().add(show);              // on the main thread, after parse
q.waitUntilAllFinished();
```

An operation can also be a subclass that overrides [`main`](#main):

```c
class Resize : Operation
{
    void main(void)
    {
        for (u32 i in 0..rows)
        {
            if (isCancelled())
                return;
            … one row …
        }
    }
}
```

**Order.** A queue starts an operation once every dependency has finished. Among
the operations ready at the same moment it starts the highest
[priority](#setpriority) first, and among equal priorities the first added.
Priority never overrides a dependency.

**Cancellation.** An operation cancelled before it starts never runs `main()`;
its completion block still runs, and operations that depend on it go ahead. One
cancelled while it runs sees [`isCancelled`](#iscancelled) turn true, and should
return early.

**Targets.** On a target with threads (arm64, x86-64, Windows, arm9, Android, iOS)
a queue runs up to [`setMaxConcurrent`](#setmaxconcurrent) operations at once, on
worker threads it starts as it needs them. On one without (the 6502, m68k,
wasm32) the same code builds: a queue runs its operations on the thread that
waits for them, in dependency and priority order, with the result of a serial
queue. `OperationQueue.main()` runs on [`RunLoop.main()`](/compiler/api/runloop/)
where there is one, and like a queue without threads elsewhere (arm9).

## Operation

### withBlock

`static Operation* withBlock(block work void(void))` — an operation whose work is
the block.

### main

`void main(void)` — the work. A subclass overrides it; an operation from
`withBlock` runs its block. The queue calls it; a program does not.

### addDependency

`void addDependency(Operation* op)` — start only after `op` has finished (or been
cancelled). `op` may be on another queue. A dependency that would make a cycle,
or one added after the operation has started, is refused with an error and not
added.

### removeDependency

`void removeDependency(Operation* op)`

### dependencies

`Array* dependencies(void)` — the operations this one waits on.

### setCompletion

`void setCompletion(block done void(void))` — runs after `main()`, on the same
thread, before the operation counts as finished.

### setPriority

`void setPriority(i32 p)` — `Operation.low()`, `Operation.normal()` (the default)
or `Operation.high()`; any value between orders too.

### priority

`i32 priority(void)`

### cancel

`void cancel(void)`

### isCancelled

`bool isCancelled(void)`

### isReady

`bool isReady(void)` — every dependency has finished, or the operation is
cancelled.

### isExecuting

`bool isExecuting(void)`

### isFinished

`bool isFinished(void)`

### waitUntilFinished

`void waitUntilFinished(void)` — block until the operation has finished.

## OperationQueue

### new OperationQueue()

A queue that runs up to `Thread.cpuCount()` operations at once.

### serial

`static OperationQueue* serial(void)` — one operation at a time.

### main

`static OperationQueue* main(void)` — the queue for work that must run on the main
thread: each operation is posted to `RunLoop.main()`.

### add

`void add(Operation* op)` — queue an operation. An operation goes to one queue,
once; adding it again is an error, and it is not added.

### addBlock

`Operation* addBlock(block work void(void))` — queue a block, and return its
operation.

### addAll

`void addAll(Array* ops, bool wait)` — queue every operation in `ops`; with `wait`,
return once they have all finished.

### setMaxConcurrent

`void setMaxConcurrent(i32 n)` — how many operations run at once; 1 makes the
queue serial.

### count

`i32 count(void)` — the operations queued or running.

### cancelAll

`void cancelAll(void)` — cancel every operation the queue holds.

### suspend, resume, isSuspended

`void suspend(void)`, `void resume(void)`, `bool isSuspended(void)` — a suspended
queue starts nothing; operations already running finish.

### waitUntilAllFinished

`void waitUntilAllFinished(void)` — block until every operation queued so far has
finished. On the main queue, called from the main thread, it runs them.
