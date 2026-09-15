---
title: UXBag
description: "A counted set: adding a member again bumps its count instead of being ignored, and it drops out at zero. CFBag in shape."
---

`UXBag` is a **multiset**. It is a set in which every member carries a count:
adding the same object again increments the count, removing decrements it, and
the member drops out when the count reaches zero.

```c
#use <UXKit>            // or #import "UXBag.xc"
```

## Overview

```c
UXBag* bag = new UXBag();
bag.add((Object*)red);
bag.add((Object*)red);
bag.add((Object*)green);
bag.addTimes((Object*)blue, 4);

bag.uniqueCount();               // 3  — distinct members
bag.totalCount();                // 7  — sum of counts
bag.countFor((Object*)red);      // 2
```

The class keeps two counts: distinct members and total occurrences. That suits a
histogram of tokens, a reference tally, or "how many of these are selected". A
plain set loses the multiplicity, and a plain array makes you count by hand.

## Removing takes one occurrence

```c
bag.remove((Object*)red);        // count 2 -> 1, still a member
bag.remove((Object*)red);        // count 1 -> 0, member gone
bag.contains((Object*)red);      // false
```

This is the reference-counting shape: `add` and `remove` pair up, and the member
survives until the last add is undone. To drop a member regardless of count,
[`removeAllOf`](#removeallof) removes it in one call and subtracts the whole
count from the total.

Removing something that is not there is a **silent no-op**. There is no error,
and the total does not go negative, so you can unwind a tally without tracking
whether you ever added.

:::note[`addTimes` cannot subtract]
A count of zero or less is ignored, so `addTimes(o, -1)` does nothing. Use
[`remove`](#remove), which drops a member at zero.
:::

## Membership is by identity

```c
Token* red  = Token.named((u8*)"red");
Token* red2 = Token.named((u8*)"red");     // an equal-looking twin
bag.add((Object*)red2);
bag.countFor((Object*)red2);   // 1 — a separate member, not red's third
```

Members are compared with `==`, not with `equals`. This is CFBag's default. A
bag counts **occurrences of the same reference**, so two objects that look alike
stay distinct.

For value semantics ("how many times did this *string* appear"), canonicalise
first: intern the value to one object and count that. Otherwise a histogram
splits across twins without warning.

## Enumerating

```c
for (i32 i = 0; i < bag.uniqueCount(); i = i + 1) {
    Stdio.printf("%s x%d\n",
                 ((Token* ?)bag.memberAt(i)).name, bag.countAt(i));
}
```

[`memberAt`](#memberat) and [`countAt`](#countat) walk the **distinct** members,
so the loop runs `uniqueCount` times whatever the total.

:::caution[Indices are not stable across removals]
Dropping a member closes the gap, so every index after it shifts. Do not hold an
index across a `remove`. When removing during a loop, walk **backwards**, or
collect first and remove after.
:::

## Cost

Every operation that names a member (`add`, `remove`, `contains`, `countFor`) is
a **linear scan** over the distinct members. There is no hash.

That suits a few dozen distinct members, as in a selection tally or a token
histogram. For thousands of distinct things counted in a loop, use a different
structure.

## Topics

[add](#add) · [addTimes](#addtimes) · [remove](#remove) · [removeAllOf](#removeallof) · [removeAll](#removeall) · [contains](#contains) · [countFor](#countfor) · [totalCount](#totalcount) · [uniqueCount](#uniquecount) · [memberAt](#memberat) · [countAt](#countat) · [entryFor](#entryfor)

### add

```c
void add(Object* o)
```

One occurrence. Equivalent to [`addTimes`](#addtimes) with `1`.

### addTimes

```c
void addTimes(Object* o, i32 n)
```

`n` occurrences at once. `n <= 0` does nothing (see the
[note](#removing-takes-one-occurrence)).

### remove

```c
void remove(Object* o)
```

One occurrence. The member drops out at zero. A no-op if absent.

### removeAllOf

```c
void removeAllOf(Object* o)
```

Drop the member whatever its count, subtracting all of it from
[`totalCount`](#totalcount).

### removeAll

```c
void removeAll(void)
```

Empty the bag.

### contains

```c
bool contains(Object* o)
```

Whether the count is non-zero. A member with count zero does not exist.

### countFor

```c
i32 countFor(Object* o)
```

How many occurrences. `0` for a non-member, so no `contains` check is needed
first.

### totalCount

```c
i32 totalCount(void)
```

The sum of every count. Maintained incrementally, so reading it costs nothing.

### uniqueCount

```c
i32 uniqueCount(void)
```

How many **distinct** members. The bound for [`memberAt`](#memberat).

### memberAt

```c
Object* memberAt(i32 i)
```

The i-th distinct member. See the
[caution](#enumerating) on index stability.

### countAt

```c
i32 countAt(i32 i)
```

That member's count.

### entryFor

```c
UXBagEntry* entryFor(Object* o)
```

The [`UXBagEntry`](/compiler/api/uxkit/uxbagentry/) for a member, or null. The
other methods use this lookup. Prefer [`countFor`](#countfor), which answers the
usual question without a null check.

## Example

```
bag: unique=3 total=7
  red x2
  green x1
  blue x4
after one remove: red=1 contains=1
after two:        red=0 contains=0 unique=2
after removeAllOf(blue): unique=1 total=1
identity: red2 count=1 unique=2
remove absent: total=2
```

The program is `website/site/examples/uxkit/collections.xc`. The `doc-examples`
gate compiles it, and the listing above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXBagEntry`](/compiler/api/uxkit/uxbagentry/): one member and its count
- [`UXIndexSet`](/compiler/api/uxkit/uxindexset/): when the things being
  counted are indices rather than objects
- [`UXBinaryHeap`](/compiler/api/uxkit/uxbinaryheap/): the other non-list
  collection, ordered rather than counted
