---
title: UXProgress
description: "Hierarchical progress: a total, some completed units, and child tasks each allocated a share, rolled up exactly in integers."
---

`UXProgress` is a node in a progress tree. It has a total unit count, its own
completed units, and optional **children** each allocated a share of the total.

```c
#use <UXKit>            // or #import "UXProgress.xc"
```

## Overview

```c
UXProgress* job = UXProgress.make(100);

UXProgress* copyFiles = job.addChild(3500, 70);   // 3500 files, worth 70 units
UXProgress* verify    = job.addChild(12,   10);   // 12 steps,   worth 10 units
// 20 units left for the parent's own work

copyFiles.setCompleted(1750);     // half the files
job.percent();                    // 35 — half of 70 is 35 of 100
```

The shape follows `NSProgress`. A long operation reports coarse progress and
delegates slices to sub-tasks that report their own. The tree aggregates.

## Each level counts in its own units

This is what makes the tree composable.

`copyFiles` counts **files** (3500 of them) and knows nothing about the parent.
The parent knows only that this child is worth **70 of its 100 units**. Neither
adopts the other's scale, so a sub-task written for one job works unchanged in
another that values it differently.

```
files 50%:  parent 35%     (the child itself reads 50%)
```

A child that is half done contributes half its allocated units.

## Per mille, because integers

```c
i32 fractionMille(void)     // 0..1000
i32 percent(void)           // 0..100, = fractionMille() / 10
```

The fraction is **per mille** rather than percent so that it stays exact through
nesting. A child at one third contributes exactly at every level. Percent would
lose a third of a percent per level, and a float would give a different answer on
a backend with a different FPU.

`percent()` is a convenience for display. Drive a bar from `fractionMille()` if
the bar has more than a hundred steps.

## Total zero means indeterminate

```c
UXProgress* unknown = UXProgress.make(0);
unknown.isIndeterminate();     // true
unknown.fractionMille();       // 0
```

An unknown amount of work is shown as a spinner rather than a bar. Setting a real
total later switches it. The usual pattern is to start indeterminate while
counting the work, then become determinate once the count is known.

`fractionMille` answers `0` rather than dividing by zero, so an indeterminate
progress is safe to read and to display.

## Everything clamps

```c
UXProgress* over = UXProgress.make(10);
over.setCompleted(999);
over.percent();          // 100, not 9990
```

`fractionMille` clamps to `0`–`1000` whatever the inputs. Over-completing, or
allocating children worth more than the total, gives a bar that reaches full
early and **stays** there rather than running past its end.

An allocation that does not add up therefore shows as "finished too soon", not as
a drawing glitch.

## Topics

[make](#make) · [setTotal](#settotal) · [setCompleted](#setcompleted) · [incrementBy](#incrementby) · [addChild](#addchild) · [fractionMille](#fractionmille) · [percent](#percent) · [isFinished](#isfinished) · [isIndeterminate](#isindeterminate)

### make

```c
static UXProgress* make(i32 total)
```

A progress with a total. `0` makes it
[indeterminate](#total-zero-means-indeterminate).

### setTotal

```c
void setTotal(i32 n)
```

Change the total. Completed units keep their value, so the fraction moves. Use
this when a count turns out larger than estimated.

### setCompleted

```c
void setCompleted(i32 n)
```

The node's **own** completed units, not counting children.

### incrementBy

```c
void incrementBy(i32 n)
```

Add to the completed count. A loop calls this once per item.

### addChild

```c
UXProgress* addChild(i32 childTotal, i32 unitsInParent)
```

Make a sub-task with its own total, worth `unitsInParent` of **this** node's
total. Returns the child, so the usual idiom is one line.

Nesting is unlimited. A child may have children of its own, and each level rolls
up the one below.

### fractionMille

```c
i32 fractionMille(void)
```

Overall completion, `0`–`1000`: own completed units, plus each child's fraction
times its allocation, over the total.

:::note[It is computed, not cached]
Every call walks the whole subtree. For a tree of a handful of nodes the cost is
negligible. Inside a tight loop that also increments it, read it once per update
rather than per item.
:::

### percent

```c
i32 percent(void)
```

### isFinished

```c
bool isFinished(void)
```

`fractionMille() >= 1000`. This is also true for an **over**-allocated tree that
has not finished; see [above](#everything-clamps).

### isIndeterminate

```c
bool isIndeterminate(void)
```

Whether the total is zero or less.

## Example

```
start:       mille=0 pct=0 finished=0
50/200:      mille=250 pct=25 finished=0
+150:        mille=1000 pct=100 finished=1
nothing yet: mille=0 pct=0 finished=0
files 50%:   mille=350 pct=35 finished=0
   (the child itself reads 50%)
+verify:     mille=450 pct=45 finished=0
+own work:   mille=650 pct=65 finished=0
all done:    mille=1000 pct=100 finished=1
indeterminate=1 mille=0
over:        mille=1000 pct=100 finished=1
nested: inner=25% mid=25% outer=25%
```

The program is `website/site/examples/uxkit/progress.xc`. The `doc-examples`
gate compiles it, and the block above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXProgressChild`](/compiler/api/uxkit/uxprogresschild/): the allocation
  link
- [`UXProgressBar`](/compiler/api/uxkit/uxprogressbar/): showing the result
- [`UXOperationQueue`](/compiler/api/uxkit/uxoperationqueue/): the work whose
  progress this reports
