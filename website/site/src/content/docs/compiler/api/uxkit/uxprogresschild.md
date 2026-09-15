---
title: UXProgressChild
description: "A sub-task and the share of its parent's total it was allocated: the link that makes a progress tree roll up."
---

`UXProgressChild` attaches a sub-[`UXProgress`](/compiler/api/uxkit/uxprogress/)
to a parent, with a share of the parent's total units.

```c
#use <UXKit>            // or #import "UXProgress.xc"
```

## Overview

```c
class UXProgressChild : Object {
    UXProgress* prog;      // the sub-task
    i32         units;     // how many of the PARENT's units it stands for
}
```

## Units are the parent's, not the child's

```
parent total 100
  child A allocated 70 units   (internally: 3500 files)
  child B allocated 30 units   (internally: 12 steps)
```

The child counts in whatever units suit it (files, bytes, steps), and the
parent does not know them. The parent records **how much of its own total that
child is worth**.

A child that is half done contributes half of its allocated units. Child A at
50% adds 35 to the parent, whatever 50% meant inside it.

This lets a long operation report coarse progress and hand slices to sub-tasks
that report their own, without any of them agreeing on a unit.

## Allocation is a promise the parent makes

Nothing checks that the children's `units` add up to the parent's total. Two
things follow:

- Allocate **less** than the total and the remainder is the parent's own work,
  tracked by its `completed` count. This is the normal case: "I do 20 units
  myself and delegate 80."
- Allocate **more** and the arithmetic overshoots.
  [`fractionMille`](/compiler/api/uxkit/uxprogress/#fractionmille) clamps to
  1000, so a bar driven by it stops at full rather than running past its end.
  It reaches full early and stays there, a visible symptom rather than a
  drawing fault.

Keeping the sum correct is the caller's job. In exchange, the parent does not
re-plan every time a child appears.

## Fractions are per mille

The roll-up reports `0`–`1000` rather than a percentage or a float, so that a
child at one-third contributes exactly, in integers, at every level of the tree.

Percent would lose a third of a percent per level. A float would give a different
answer on a backend with a different FPU. See
[`UXProgress`](/compiler/api/uxkit/uxprogress/) for the arithmetic.

## The child is held strongly

```c
UXProgress* prog
```

A parent owns its children. A sub-task whose progress object had been collected
would silently stop contributing.

The child does **not** point back. A progress tree therefore has no cycle to
break, and a sub-task cannot ask what fraction of the whole it represents. Only
the parent knows that.

## Fields

### prog

```c
UXProgress* prog
```

### units

```c
i32 units
```

The parent's units this child stands for.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXProgress`](/compiler/api/uxkit/uxprogress/): the node, and the roll-up
- [`UXProgressBar`](/compiler/api/uxkit/uxprogressbar/): showing the result
