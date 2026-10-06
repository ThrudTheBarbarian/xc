---
title: Progress
description: "How far a piece of work has got, as a tree: children count in their own units and roll up into their parent's fraction."
---

`Progress` reports how far a piece of work has got, as a tree (`NSProgress` in
shape). **From 0.72.**

```c
#import "Progress.xc"      // not in the Foundation umbrella: import it by name
```

## Overview

```c
Progress* whole = Progress.withTotal((i64)10);       // ten units of work
Progress* files = whole.makeChild((i64)200, (i64)6);  // 200 files, worth 6 of the 10
files.incrementBy((i64)100);                          // half the files
whole.incrementBy((i64)2);                            // 2 units of whole's own work
whole.fractionCompleted();                            // (2 + 0.5 × 6) / 10 = 0.5
```

A progress has a total and a completed count of units in whatever measure suits
it (bytes, files, steps), and may hand a share of its units to child progresses
that count in their own measure. The fraction completed rolls the children up:
a child halfway through contributes half the units it was given. A long
operation reports coarse progress and gives slices to the parts that do the
work; whoever draws a bar reads the root.

A total of 0 or less is **indeterminate**: the work cannot yet say how much
there is. **Cancelling** a progress cancels its children; the work checks
[`isCancelled`](#cancel--iscancelled) and stops.

A progress is for one thread, usually the [run loop](/compiler/api/runloop/)'s:
a worker reports its counts to that thread rather than updating the tree
itself.

:::note[Availability]
Every heap-capable target except xt6502.
:::

## Topics

**Creating** · [withTotal](#withtotal)

**Counting** · [totalUnitCount / setTotalUnitCount](#totalunitcount--settotalunitcount) · [completedUnitCount / setCompletedUnitCount](#completedunitcount--setcompletedunitcount) · [incrementBy](#incrementby)

**Children** · [addChild](#addchild) · [makeChild](#makechild)

**Reading** · [fractionCompleted](#fractioncompleted) · [fractionPerMille](#fractionpermille) · [isIndeterminate](#isindeterminate) · [isFinished](#isfinished)

**Cancelling** · [cancel / isCancelled](#cancel--iscancelled)

---

## Creating

### withTotal
```c
static Progress* withTotal(i64 total)
```
A progress of `total` units, none done. `new Progress()` is indeterminate.

[↑ Topics](#topics)

## Counting

### totalUnitCount / setTotalUnitCount
```c
i64 totalUnitCount(void)
void setTotalUnitCount(i64 n)
```

### completedUnitCount / setCompletedUnitCount
```c
i64 completedUnitCount(void)
void setCompletedUnitCount(i64 n)
```
The units done directly, not counting children.

### incrementBy
```c
void incrementBy(i64 n)
```

[↑ Topics](#topics)

## Children

### addChild
```c
void addChild(Progress* child, i64 units)
```
Hands `units` of this progress's total to `child`, which counts in its own
measure. A child added to a cancelled progress is cancelled.

### makeChild
```c
Progress* makeChild(i64 total, i64 units)
```
A new child of `total` units of its own, standing for `units` of this
progress's.

[↑ Topics](#topics)

## Reading

### fractionCompleted
```c
double fractionCompleted(void)
```
0.0 to 1.0: the progress's own completed units plus each child's fraction
times its units, over the total, kept within 0 and 1. 0 when indeterminate.

### fractionPerMille
```c
u32 fractionPerMille(void)
```
The fraction in thousandths, 0 to 1000, rounded down: for a bar drawn in whole
steps.

### isIndeterminate
```c
bool isIndeterminate(void)
```
Whether the total is not known yet (0 or less).

### isFinished
```c
bool isFinished(void)
```
Whether the fraction has reached 1.

[↑ Topics](#topics)

## Cancelling

### cancel / isCancelled
```c
void cancel(void)
bool isCancelled(void)
```
Marks this progress and every child cancelled; the work is expected to notice
and stop.

[↑ Topics](#topics)
