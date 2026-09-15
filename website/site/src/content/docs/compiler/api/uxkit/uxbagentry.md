---
title: UXBagEntry
description: "One distinct member of a UXBag and how many times it appears."
---

`UXBagEntry` is one row of a [`UXBag`](/compiler/api/uxkit/uxbag/): a member,
and how many occurrences of it the bag holds.

```c
#use <UXKit>            // or #import "UXBag.xc"
```

## Overview

```c
class UXBagEntry : Object {
    Object* obj;        // the member, compared by identity
    i32     count;      // how many occurrences; never stored at zero
}
```

You do not create one. [`add`](/compiler/api/uxkit/uxbag/#add) creates it, and
[`remove`](/compiler/api/uxkit/uxbag/#remove) discards it when the count reaches
zero.

## The zero invariant

A bag never holds an entry whose count is zero: the entry is removed as soon as
its count would reach zero. For that reason
[`contains`](/compiler/api/uxkit/uxbag/#contains) only checks whether an entry
exists, and `uniqueCount` is the number of entries.

Any entry you hold has a count of at least one.

## Reading one

[`countFor`](/compiler/api/uxkit/uxbag/#countfor) answers the usual question
without a null check, and [`memberAt`](/compiler/api/uxkit/uxbag/#memberat) /
[`countAt`](/compiler/api/uxkit/uxbag/#countat) walk the entries by index. The
entry itself is reachable through
[`entryFor`](/compiler/api/uxkit/uxbag/#entryfor), which returns null for a
non-member.

:::caution[Writing `count` bypasses the bag's total]
[`totalCount`](/compiler/api/uxkit/uxbag/#totalcount) is maintained
incrementally as members are added and removed. It is not recomputed. Setting
`count` on an entry directly changes the member's tally without changing the
total, and the two disagree from then on without warning.

Use [`add`](/compiler/api/uxkit/uxbag/#add),
[`addTimes`](/compiler/api/uxkit/uxbag/#addtimes) and
[`remove`](/compiler/api/uxkit/uxbag/#remove), which keep both in step.
:::

## `obj` is a strong reference

The bag **keeps its members alive**. A tally needs this: a histogram whose
entries vanished when the rest of the program released them would count wrong.

A bag you never empty holds everything it was ever given, so call
[`removeAll`](/compiler/api/uxkit/uxbag/#removeall) on a tally you are done
with.

## Fields

### obj

```c
Object* obj
```

The member. Compared with `==`, so two equal-looking objects are two members
(see [identity](/compiler/api/uxkit/uxbag/#membership-is-by-identity)).

### count

```c
i32 count
```

Occurrences. At least one for as long as the entry exists.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXBag`](/compiler/api/uxkit/uxbag/): the bag these belong to
- [`UXCacheEntry`](/compiler/api/uxkit/uxcacheentry/): the same
  one-row-of-a-collection shape, keyed rather than counted
