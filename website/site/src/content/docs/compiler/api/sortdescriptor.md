---
title: SortDescriptor
description: "Sort records by one key and then the next, in either direction: a stable sort of Maps or of any object through a reader."
---

`SortDescriptor` sorts records by keys (`NSSortDescriptor` in shape). Filter
with a [`Predicate`](/compiler/api/predicate/), then sort with descriptors:
what a table does to its rows. **From 0.72.**

```c
#import "SortDescriptor.xc"   // not in the Foundation umbrella: import it by name
```

## Overview

```c
Array* rows = SortDescriptor.sorted(people, SortDescriptor.list2(
    SortDescriptor.withKey(String.withCString("age"), false),     // oldest first
    SortDescriptor.withKey(String.withCString("name"), true)));   // then by name
```

A descriptor names a key (a dotted path through nested Maps, as a predicate
reads one), a direction, and whether Strings compare ignoring ASCII case. A
list of descriptors sorts by the first and breaks ties with the next.

Values order as a predicate compares them
([`Predicate.compareValues`](/compiler/api/predicate/)): Numbers as numbers,
with Strings that hold numbers; Strings by bytes. A missing or null value, or
one with no order against the other, sorts before every other value when
ascending, and after when descending.

The sort is **stable**: records every descriptor finds equal keep their order.

:::note[Availability]
Every target except xt6502.
:::

## Topics

**Describing** · [withKey](#withkey) · [key / ascending / caseInsensitive](#key--ascending--caseinsensitive) · [reversed](#reversed) · [list1 / list2](#list1--list2)

**Sorting** · [sorted](#sorted) · [sortedWith](#sortedwith) · [compare / compareValues](#compare--comparevalues)

---

## Describing

### withKey
```c
static SortDescriptor* withKey(String* key, bool ascending)
```

### key / ascending / caseInsensitive
```c
String* key;
bool ascending;
bool caseInsensitive;
```
Public fields.

### reversed
```c
SortDescriptor* reversed(void)
```
A copy with the direction turned round: for a column header clicked again.

### list1 / list2
```c
static Array* list1(SortDescriptor* a)
static Array* list2(SortDescriptor* a, SortDescriptor* b)
```
A list of one or two descriptors, for the common cases; any `Array` of
descriptors will do.

[↑ Topics](#topics)

## Sorting

### sorted
```c
static Array* sorted(Array* items, Array* descriptors)
```
A sorted copy of `items` (Maps).

### sortedWith
```c
static Array* sortedWith(Array* items, Array* descriptors, callback read Object*(Object* item, String* key))
```
The same for any objects, reading each key through `read`.

### compare / compareValues
```c
i8 compare(Object* a, Object* b)
i8 compareValues(Object* a, Object* b)
```
How two records, or two values, order under this one descriptor: -1, 0 or 1.

[↑ Topics](#topics)
