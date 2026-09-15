---
title: UXOperation
description: "A unit of work plus the list of operations that must finish before it may run, and a cancel that finishes without running."
---

`UXOperation` is one piece of work, together with the operations it must wait
for.

```c
#use <UXKit>            // or #import "UXOperationQueue.xc"
```

## Overview

```c
UXOperation* parse = UXOperation.make(2, &self.doParse);
parse.addDependency(load);

void doParse(UXOperation* op) { … }        // the work
```

The callback receives the operation itself, so one method can serve several
operations and tell them apart by [`tag`](#tag).

[`UXOperationQueue`](/compiler/api/uxkit/uxoperationqueue/) runs them.

## The work is a callback, so nothing is owned

```c
callback block void(UXOperation* op)
```

A [callback](/compiler/language/bound-methods/) never owns its receiver. An
operation queued against a window does not keep that window alive, and a queue
holding a hundred pending operations keeps nothing else alive.

In return, **the application must keep the target alive** until the work runs.
An operation whose receiver has died is not an error: the callback reads as
absent and the operation finishes having done nothing. That is correct for
"lay out the window that just closed", and a silent no-op if you expected the
work to run.

A **null block is legal** and does nothing. Use one as a barrier: an
operation others depend on, which exists only as a join point in the graph.

## Ready means every dependency has finished

```c
bool isReady(void)
```

True when nothing is outstanding, and **false once the operation itself has
finished**, so a completed operation is never picked up twice.

Dependencies are a plain list with no cycle check at
[`addDependency`](#adddependency) time. A cycle shows up when the queue stops
making progress and sets
[`isDeadlocked`](/compiler/api/uxkit/uxoperationqueue/#isdeadlocked). Checking
on every add would cost a graph walk per edge, and the queue has to detect the
condition anyway.

## Cancel finishes without running

```c
op.cancel();
op.isCancelled();      // true
// after the queue runs:
op.isFinished();       // ALSO true — it finished without doing the work
```

`execute` skips the block when cancelled, then marks the operation finished
regardless. **Dependents proceed**, so cancelling one step does not block
everything downstream.

```
chain 10 -> 20 -> 30, with 20 cancelled  ->  10 and 30 run
```

Two consequences:

- Cancellation **does not propagate**. If a dependent must not run either,
  cancel it too.
- Cancelling after the operation has run has no useful effect. The state
  is already finished, and `isCancelled` becomes true without anything having
  changed.

There is no un-cancel.

## The tag is for you

```c
i32 tag
```

An integer identity the toolkit never interprets.
[`ranTagAt`](/compiler/api/uxkit/uxoperationqueue/#rantagat) reports it, so a
test uses it to assert the execution order, and one callback uses it to
distinguish the operations it serves.

Use it for a row index, an enum, a request id, or anything you can map back.

## Topics

[make](#make) · [addDependency](#adddependency) · [cancel](#cancel) · [isCancelled](#iscancelled) · [isFinished](#isfinished) · [isReady](#isready) · [execute](#execute)

### make

```c
static UXOperation* make(i32 tag, callback block void(UXOperation* op))
```

An operation with its tag and its work. Pass `0` for the block to make a
barrier.

### addDependency

```c
void addDependency(UXOperation* o)
```

`o` must finish before this operation may run. A null argument is ignored
rather than stored, so a conditional dependency needs no `if`.

Duplicates are stored, not removed. This is harmless: readiness asks whether
*every* entry has finished, and the same operation appearing twice gives the
same answer both times. It costs one extra comparison per check.

### cancel

```c
void cancel(void)
```

Skips the work. See [above](#cancel-finishes-without-running).

### isCancelled

```c
bool isCancelled(void)
```

### isFinished

```c
bool isFinished(void)
```

Whether it has been executed, **including** when it was cancelled.

### isReady

```c
bool isReady(void)
```

Whether every dependency has finished and this one has not.

### execute

```c
void execute(void)
```

Runs the block (unless cancelled), then marks the operation finished. The queue
calls this; call it directly only if you are driving the order yourself.

## Fields

### tag

```c
i32 tag
```

### deps

```c
Array<UXOperation>* deps
```

The dependencies, held **strongly**. An operation keeps its prerequisites
alive, since it cannot become ready without querying them.

## Example

```
diamond, added 4,3,2,1:
   order: 1 3 2 4   ran=4 of 4  deadlocked=0  allFinished=1
chain 10->20->30 with 20 cancelled:
   order: 10 30   ran=2 of 3
  20 finished=1 cancelled=1
three independent (9 has no block):
   order: 7 8 9   ran=3 of 3
```

Tag 9 has a null block: it appears in the order because it *ran*, and it
produced nothing. The program is `website/site/examples/uxkit/operations.xc`;
the `doc-examples` gate compiles it, and this is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXOperationQueue`](/compiler/api/uxkit/uxoperationqueue/): what runs these
- [Bound methods and callbacks](/compiler/language/bound-methods/): why a dead
  target is a silent skip
