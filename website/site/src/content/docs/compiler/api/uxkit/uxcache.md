---
title: UXCache
description: "A bounded least-recently-used cache: keyed storage with a capacity, evicting the oldest-touched entry when it would overflow. NSCache in shape."
---

`UXCache` is keyed storage that **cannot grow without bound**. Set a capacity,
and when a write would exceed it the least-recently-used entry is evicted.

```c
#use <UXKit>            // or #import "UXCache.xc"
```

## Overview

```c
UXCache* c = new UXCache();
c.setCapacity(3);

c.set((u8*)"a", (Object*)thumbA);
c.set((u8*)"b", (Object*)thumbB);
c.set((u8*)"c", (Object*)thumbC);

c.get((u8*)"a");                  // hit — and now "a" is the most recent
c.set((u8*)"d", (Object*)thumbD); // over capacity: "b" is evicted
```

Thumbnail, decoded-image and parsed-resource caches use it to stay bounded. It
is a pure data structure with no platform code, so it is testable.

The default capacity is **16**.

## What counts as a use

Every [`get`](#get) and every [`set`](#set) marks its entry most-recently-used
by stamping it with a monotonic counter. The victim is always the entry with the
oldest stamp.

```c
c.get((u8*)"a");      // "a" is now newest; something else becomes the victim
```

[`contains`](#contains) **does not** mark recency:

:::tip[Peeking cannot rescue an entry]
`contains` answers "is it here" without touching recency. A loop that checks
what is cached (to decide what still needs fetching, for example) does not
reorder the cache as a side effect.

If you are about to use the value, call `get`. If you only want to know whether
it is present, call `contains`. That way the cache order reflects use, not
inspection.
:::

## Keys

Keys are strings, compared **by content**, so a key built at run time matches a
literal. You need this when the key is a filename or a URL.

:::caution[`set` keeps your key pointer; it does not copy]
The entry stores the `u8*` you pass. A key that lives in a scratch buffer, or
that you free, leaves the cache holding a dangling pointer, and the next lookup
compares against freed bytes.

Pass a literal, or copy first with
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup). The values are held strongly and
need no such care. Only the key does.
:::

Setting an existing key **updates in place**: the value is replaced and the
entry is re-stamped, and no second entry appears. Repeated writes to one key do
not consume capacity.

## A miss is null

```c
Object* v = c.get((u8*)"gone");     // 0
```

As a result there is **no way to cache a null value**: storing `0` is
indistinguishable from not having the key. To remember that a lookup found
nothing, cache a marker object instead of null.
[`UXNull`](/compiler/api/uxkit/uxnull/) exists for this.

## Cost, and what it is sized for

Lookup is a **linear scan**, and each eviction is another scan to find the
oldest entry. There is no hash and no linked list.

For a capacity in the tens, typical of a thumbnail cache, this is faster than
the alternatives and much simpler. It is the wrong shape for thousands of
entries: the scan dominates, and a hash plus an intrusive LRU list would suit
better.

`setCapacity` clamps to a minimum of **1**, so a cache cannot discard
everything. Shrinking the capacity evicts immediately.

## Topics

[setCapacity](#setcapacity) · [set](#set) · [get](#get) · [contains](#contains) · [remove](#remove) · [removeAll](#removeall) · [count](#count) · [find](#find) · [evictToFit](#evicttofit)

### setCapacity

```c
void setCapacity(i32 n)
```

The maximum number of entries. Clamped to at least 1, and evicts down to fit
immediately.

### set

```c
void set(u8* key, Object* value)
```

Store, replacing an existing key in place. Marks most-recently-used, then evicts
if over capacity. See the [caution](#keys) about the key pointer.

### get

```c
Object* get(u8* key)
```

Fetch, or `0`. Marks most-recently-used on a hit.

### contains

```c
bool contains(u8* key)
```

Presence only. Does **not** mark recency. See
[above](#what-counts-as-a-use).

### remove

```c
void remove(u8* key)
```

Drop one entry. A no-op if it is not there.

### removeAll

```c
void removeAll(void)
```

Empty the cache. The cache holds values strongly, so this releases them.

### count

```c
i32 count(void)
```

Entries currently held. Never more than the capacity.

### find

```c
UXCacheEntry* find(u8* key)
```

The [`UXCacheEntry`](/compiler/api/uxkit/uxcacheentry/), or null, **without**
marking recency. The other methods are built on this lookup.

### evictToFit

```c
void evictToFit(void)
```

Evict least-recently-used entries until within capacity. [`set`](#set) and
[`setCapacity`](#setcapacity) call it for you.

## Example

```
cache count=3 a=1 b=0 c=1 d=1
after peek+set: c=0 e=1
miss=0
re-set same key: 3 -> 3 value=E2
after setCapacity(1): count=1
```

Capacity 3, keys `a` `b` `c` inserted in order. Getting `a` made it newest, so
adding `d` evicted `b`. `a` was oldest by insertion but not by use. Then
`contains("c")` did not save `c`, and `e` pushed it out. Re-setting `e` changed
its value without changing the count.

The program is `website/site/examples/uxkit/collections.xc`. The `doc-examples`
gate compiles it, and the listing above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXCacheEntry`](/compiler/api/uxkit/uxcacheentry/): one key/value/stamp row
- [`UXKeyValueStore`](/compiler/api/uxkit/uxkeyvaluestore/): keyed storage that
  *persists* instead of evicting
- [`UXNull`](/compiler/api/uxkit/uxnull/): the marker to cache when the answer
  is "nothing"
