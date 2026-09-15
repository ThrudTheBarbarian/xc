---
title: UXOperationQueue
description: "Operations with dependencies, run in a correct order by a deterministic scheduler that detects cycles instead of hanging on them."
---

`UXOperationQueue` holds [`UXOperation`](/compiler/api/uxkit/uxoperation/)s and
runs each one as soon as its dependencies have finished.

```c
#use <UXKit>            // or #import "UXOperationQueue.xc"
```

## Overview

```c
UXOperationQueue* q = new UXOperationQueue();

UXOperation* load  = UXOperation.make(1, &self.doLoad);
UXOperation* parse = UXOperation.make(2, &self.doParse);
UXOperation* draw  = UXOperation.make(3, &self.doDraw);

parse.addDependency(load);
draw.addDependency(parse);

q.addOperation(draw);         // order of addition does not matter
q.addOperation(parse);
q.addOperation(load);

q.run();                      // load, parse, draw
```

It is shaped like `NSOperationQueue`. You declare *what must happen before
what*, and the queue works out an order that satisfies it.

## This layer is the scheduler, not the concurrency

`run()` executes the operations **serially**, in a valid topological order,
with no threads, clock or driver.

The readiness logic (*an operation may run when every dependency has
finished*) is the order-sensitive part, and here it is deterministic and
unit-testable. A threaded backend on XTOS can reuse this logic to run
**independent** operations concurrently. The rule stays the same; only the
number running at once changes.

A dependency graph tested serially stays correct when it runs in parallel.

## The order is deterministic, but not the order you added them

```
added 4, 3, 2, 1 in a diamond  ->  ran 1, 3, 2, 4
```

Each round scans the operations in **array order** and runs every one that is
ready. The result respects dependencies, and operations that became ready
together run in the order they were added.

The dependency order is guaranteed, and the tie-break is stable, so a test
that asserts the exact sequence stays reliable.

If the order of two independent operations matters, express it with a
dependency. A parallel backend will not preserve insertion order.

## Cancellation unblocks dependents

```
chain 10 -> 20 -> 30, with 20 cancelled  ->  ran 10, 30
```

A cancelled operation does not **run**, but it does **finish**, so anything
waiting on it proceeds instead of stalling.

This is usually the behaviour you want: cancelling "fetch the thumbnail"
should not block "lay out the window". When a dependent must not proceed,
cancel it too, because cancellation does not propagate.

[`ranCount`](#rancount) counts only operations that **ran**, so a
cancelled one is finished but absent from the recorded order.

## A cycle is detected, not looped over

```c
x.addDependency(y);
y.addDependency(x);
q.run();
q.isDeadlocked();     // true
```

If a round makes no progress while operations remain, `run()` stops and sets the
flag. Nothing spins, and nothing runs out of order to escape.

```
cycle 100<->200, with 300 downstream:
   order:   ran=0 of 3  deadlocked=1  allFinished=0
```

The flag does **not** tell you which operations formed the cycle.
`isDeadlocked` plus [`allFinished`](#allfinished) says that *something* did not
run; to find out which, walk the operations checking
[`isFinished`](/compiler/api/uxkit/uxoperation/#isfinished). For a graph built
from a fixed pipeline a cycle is a build-time bug, so a check in a test is
usually the right place for it.

:::caution[`isDeadlocked` is reset by every `run()`]
It is cleared at the top of `run()`, so read it after the call you care about.
A second `run()` on a deadlocked queue clears the flag and sets it again. On a
*healthy* queue, a second run clears it and leaves it clear.
:::

## Running twice is harmless

```c
q.run();
q.run();       // nothing re-runs; the order is unchanged
```

Finished operations are skipped, so a second `run()` is a no-op. You can call
`run()` again after adding more operations: the new ones run and the old ones
do not.

An **empty** queue finishes immediately and is not deadlocked, so a pipeline
with nothing to do goes through the same code path.

## Topics

[addOperation](#addoperation) · [run](#run) · [count](#count) · [ranCount](#rancount) · [ranTagAt](#rantagat) · [isDeadlocked](#isdeadlocked) · [allFinished](#allfinished)

### addOperation

```c
void addOperation(UXOperation* o)
```

Adds to the queue. Order of addition does not affect correctness; see
[above](#the-order-is-deterministic-but-not-the-order-you-added-them) for what
it does affect.

Dependencies do **not** have to be in the queue, but an operation waiting on
one that is not, and never finishes, deadlocks the queue. Add the whole graph.

### run

```c
void run(void)
```

Runs everything that can run, repeatedly, until nothing is left or nothing
progresses.

### count

```c
i32 count(void)
```

Operations in the queue, run or not.

### ranCount

```c
i32 ranCount(void)
```

How many operations executed, excluding cancelled ones.

### ranTagAt

```c
i32 ranTagAt(i32 i)
```

The tag of the i-th operation that ran, in execution order. Tests assert
against this, and it is the reason
[`tag`](/compiler/api/uxkit/uxoperation/#tag) exists.

### isDeadlocked

```c
bool isDeadlocked(void)
```

Whether the last `run()` stopped without finishing. See
[above](#a-cycle-is-detected-not-looped-over).

### allFinished

```c
bool allFinished(void)
```

Whether every operation is finished. Cancelled ones count as finished.

## Example

```
diamond, added 4,3,2,1:
   order: 1 3 2 4   ran=4 of 4  deadlocked=0  allFinished=1
chain 10->20->30 with 20 cancelled:
   order: 10 30   ran=2 of 3  deadlocked=0  allFinished=1
  20 finished=1 cancelled=1
cycle 100<->200, with 300 downstream:
   order:   ran=0 of 3  deadlocked=1  allFinished=0
three independent (9 has no block):
   order: 7 8 9   ran=3 of 3  deadlocked=0  allFinished=1
empty queue: order:   ran=0 of 0  deadlocked=0  allFinished=1
```

The program is `website/site/examples/uxkit/operations.xc`; the `doc-examples`
gate compiles it, and this is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXOperation`](/compiler/api/uxkit/uxoperation/): the unit of work
- [`UXTimerScheduler`](/compiler/api/uxkit/uxtimerscheduler/): the other
  deterministic scheduler, ordered by time rather than dependency
- [`UXBinaryHeap`](/compiler/api/uxkit/uxbinaryheap/): ordering by priority,
  where this orders by prerequisite
