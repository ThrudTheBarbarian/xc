---
title: BinaryHeap
description: "A priority queue: members come out smallest priority first, with O(log n) insert and removal."
---

`BinaryHeap` is a priority queue (`CFBinaryHeap` in shape): a binary min-heap
whose member with the smallest priority is always first.
[`insert`](#insert) and [`removeMinimum`](#removeminimum) are O(log n).
**From the release after 0.71.**

```c
#import "BinaryHeap.xc"    // or the Foundation umbrella
```

## Overview

```c
BinaryHeap* q = new BinaryHeap();
q.insert(taskA, (i32)5);
q.insert(taskB, (i32)2);
Object* next = q.removeMinimum();   // taskB
```

**Priorities, not a comparator.** Each member carries an integer priority, lower
coming out first, so the caller orders by any key it likes: a deadline, a
distance, or a negated score for a max-heap. Members of equal priority come out
in no promised order.

**Storage** is two parallel arrays, the members and their priorities, in heap
order (parent `(i-1)/2`, children `2i+1` and `2i+2`), grown by doubling, so an
insert allocates nothing until the arrays are full.

**Ownership (ARC).** The heap holds a strong reference to each member while it
is in the heap. [`removeMinimum`](#removeminimum) hands its reference to the
caller.

:::note[Availability]
Every heap-capable target, the 6502 included.
:::

## Topics

**Adding** · [insert](#insert)

**Reading** · [minimum](#minimum) · [minimumPriority](#minimumpriority) · [count](#count) · [isEmpty](#isempty)

**Removing** · [removeMinimum](#removeminimum) · [removeAll](#removeall)

---

## Adding

### insert
```c
void insert(Object* o, i32 pri)
```
Adds `o` with priority `pri`; lower comes out first. A null `o` is ignored.

[↑ Topics](#topics)

## Reading

### minimum
```c
Object* minimum(void)
```
The member that would come out next, which stays in the heap; null when empty.

### minimumPriority
```c
i32 minimumPriority(void)
```
The priority of [`minimum`](#minimum); 0 when empty.

### count
```c
i32 count(void)
```
The number of members.

### isEmpty
```c
bool isEmpty(void)
```
Whether the heap has no members.

[↑ Topics](#topics)

## Removing

### removeMinimum
```c
Object* removeMinimum(void)
```
Takes out and returns the member with the smallest priority; null when empty.

### removeAll
```c
void removeAll(void)
```
Empties the heap, releasing every member.

[↑ Topics](#topics)
