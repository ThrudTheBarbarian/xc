---
title: UXHeapEntry
description: "One item in a UXBinaryHeap: the object, and the integer priority it was inserted with."
---

`UXHeapEntry` pairs an object with its priority inside a
[`UXBinaryHeap`](/compiler/api/uxkit/uxbinaryheap/).

```c
#use <UXKit>            // or #import "UXBinaryHeap.xc"
```

## Overview

```c
class UXHeapEntry : Object {
    Object* obj;     // what was inserted
    i32     pri;     // its key; LOWER comes out first
}
```

[`insert`](/compiler/api/uxkit/uxbinaryheap/#insert) makes an entry, and
[`removeMinimum`](/compiler/api/uxkit/uxbinaryheap/#removeminimum) discards
it and returns `obj`. The public interface never exposes an entry.

## Why the priority is stored beside the object

The alternatives both cost more. A comparator callback adds an indirect call
per comparison, and a heap does O(log n) comparisons per operation. Asking
the object for its own priority requires every insertable type to implement
something.

Storing the key **at insert time** makes each comparison a plain integer
compare. An object can go in twice with different priorities, and it needs
no cooperation: any `Object*` is insertable.

The cost is that the key is a snapshot:

:::note[`pri` is fixed once inserted]
Changing an object after it is in the heap does not change its position,
because the heap compares the stored `pri` and does not ask again.

Do not write `pri` on an entry directly. It does not re-sift, so the heap
invariant breaks and the wrong item comes out as the minimum. Insert again
with the new key instead, and ignore the stale copy when it comes out.
:::

## `obj` is strong

The heap keeps its items alive until they are removed, so a queue of
pending work never fills with nulls.

For the same reason, call
[`removeAll`](/compiler/api/uxkit/uxbinaryheap/#removeall) on a heap you are
abandoning instead of draining.

## Fields

### obj

```c
Object* obj
```

The inserted object, returned by
[`removeMinimum`](/compiler/api/uxkit/uxbinaryheap/#removeminimum).

### pri

```c
i32 pri
```

The ordering key. Lower comes first; negate it for a max-heap.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXBinaryHeap`](/compiler/api/uxkit/uxbinaryheap/): the heap these live in
- [`UXBagEntry`](/compiler/api/uxkit/uxbagentry/): the same
  one-row-of-a-collection shape, counted instead of ordered
