---
title: UXBinaryHeap
description: "A priority queue: the lowest priority always comes out first, in O(log n). CFBinaryHeap in shape, with an explicit integer key instead of a comparator."
---

`UXBinaryHeap` is a **min-heap**: the item with the lowest priority is always
the one that comes out.

```c
#use <UXKit>            // or #import "UXBinaryHeap.xc"
```

## Overview

```c
UXBinaryHeap* q = new UXBinaryHeap();
q.insert((Object*)repaint, 5);
q.insert((Object*)quit,    1);
q.insert((Object*)save,    3);

q.minimum();          // quit — peek, without removing
q.removeMinimum();    // quit
q.removeMinimum();    // save
```

`insert` and `removeMinimum` are **O(log n)**; `minimum` is O(1). Draining the
whole heap is a sort, which is the usual use when all items arrive before you
need any of them.

## The priority is an integer you choose

There is no comparator callback. Every item carries an explicit `i32`, and
**lower comes out first**.

This is simpler than a callback, and the key can be any ordering you can
compute:

```c
q.insert((Object*)task, deadlineMs);        // earliest deadline first
q.insert((Object*)node, distanceFromStart); // Dijkstra
q.insert((Object*)hit, -score);             // a MAX-heap, by negating
```

Negate the key for a max-heap. "Top N results" is a min-heap over `-score`, with
no second class needed.

:::note[The key is fixed at insert]
There is no decrease-key. An item keeps the priority it was inserted with.

When a priority changes, insert the item again with the new key and ignore the
stale copy when it surfaces (lazy deletion). This costs some memory and spares
the heap from tracking where each item lives.
:::

## Ties are not ordered

Two items with the same priority come out in an unspecified order, which is not
insertion order. The heap is not stable.

When ties must break predictably, put the tiebreak **in the key**: a sequence
number in the low bits, or a priority scaled up with the arrival index added.
This is cheaper than a stable heap and keeps the comparison a single integer.

## Empty is answered, not trapped

```c
UXBinaryHeap* empty = new UXBinaryHeap();
empty.isEmpty();          // true
empty.minimum();          // 0 — null, not a crash
empty.removeMinimum();    // 0
```

A drain loop is preferably `while (!q.isEmpty())`, and a null check also works.

## How it is stored

A complete binary tree flattened into an [`Array`](/compiler/api/array/), with
the standard arithmetic: parent `(i-1)/2`, children `2i+1` and `2i+2`. There are
no pointers, no nodes, and no per-item allocation beyond the
[`UXHeapEntry`](/compiler/api/uxkit/uxheapentry/) that pairs an object with its
key.

:::caution[An item's array index is not its identity]
Sifting moves items on every insert and removal. The index where an item landed
holds only at that moment.

For that reason `items` is not part of the interface. Ordering below the root is
a heap invariant, not a sort. Only [`minimum`](#minimum) is meaningful.
:::

## Topics

[insert](#insert) · [minimum](#minimum) · [removeMinimum](#removeminimum) · [count](#count) · [isEmpty](#isempty) · [removeAll](#removeall)

### insert

```c
void insert(Object* o, i32 pri)
```

Add with a priority. O(log n): appended, then sifted up.

Duplicates are allowed. The same object can be in the heap more than once, which
lazy deletion relies on.

### minimum

```c
Object* minimum(void)
```

The lowest-priority item without removing it. `0` when empty. O(1).

### removeMinimum

```c
Object* removeMinimum(void)
```

Take the lowest-priority item out and return it. `0` when empty. O(log n).

### count

```c
i32 count(void)
```

How many items, counting duplicates separately.

### isEmpty

```c
bool isEmpty(void)
```

### removeAll

```c
void removeAll(void)
```

Drop everything. The heap holds its items **strongly**, so a long-lived queue
calls this to release them.

## Example

```
heap count=4 minimum=quit
drain: quit resize save repaint
max-heap first out: score-90
empty: isEmpty=1 minimum=0
```

`quit resize save repaint` is priorities 1, 2, 3, 5 in order, inserted as 5, 1,
3, 2. The max-heap line uses three negated scores, so `-90` is the minimum and
the highest score comes out first.

The program is `website/site/examples/uxkit/collections.xc`. The `doc-examples`
gate compiles it, and the listing above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXHeapEntry`](/compiler/api/uxkit/uxheapentry/): one item and its priority
- [`UXOperationQueue`](/compiler/api/uxkit/uxoperationqueue/): a queue of work
  to *run*, where this is a queue of things to *order*
- [`UXTimerScheduler`](/compiler/api/uxkit/uxtimerscheduler/): earliest-deadline
  ordering applied to time
