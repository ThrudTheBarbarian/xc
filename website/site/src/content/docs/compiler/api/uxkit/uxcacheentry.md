---
title: UXCacheEntry
description: "One row of a UXCache: the key, the value, and the clock stamp that decides which entry is evicted next."
---

`UXCacheEntry` is one row of a [`UXCache`](/compiler/api/uxkit/uxcache/).

```c
#use <UXKit>            // or #import "UXCache.xc"
```

## Overview

```c
class UXCacheEntry : Object {
    u8*     key;
    Object* value;
    i32     touched;     // the cache's clock when this was last used
}
```

[`set`](/compiler/api/uxkit/uxcache/#set) creates one, and eviction discards it.
You reach one only through [`find`](/compiler/api/uxkit/uxcache/#find), which
exists for inspection.

## `touched` is a counter, not a time

The cache keeps a monotonic integer that increments on every
[`get`](/compiler/api/uxkit/uxcache/#get) and
[`set`](/compiler/api/uxkit/uxcache/#set), and stamps the entry with it.
Eviction picks the entry with the **smallest** stamp.

A counter makes the structure testable and deterministic: the same sequence of
calls evicts the same entry on every run and every platform, regardless of
timing. "Recent" means an order of use, not a number of seconds.

`touched` tells you relative age and nothing else. Comparing stamps between two
caches is meaningless, because each has its own clock.

:::note[The counter is an `i32`]
At two billion accesses it would wrap and the ordering would invert. A bounded
cache of tens of entries does not reach that in a session. It is the cost of a
cheap counter, and not a case the design handles.
:::

## The key is a borrowed pointer

```c
u8* key
```

The entry stores the pointer [`set`](/compiler/api/uxkit/uxcache/#set) was
given. It is not copied and not managed.

The string must outlive the entry: use a literal, or copy it first with
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup). A key from a scratch buffer
leaves the cache comparing against bytes that have since changed, and the
symptom is a lookup that misses for no visible reason.

Comparison is **by content**, so a key built at run time matches a literal with
the same characters.

## The value is strong

```c
Object* value
```

The cache owns what it holds, so the value survives until evicted. A cache that
never fills in practice keeps everything alive, so choose a
[`setCapacity`](/compiler/api/uxkit/uxcache/#setcapacity) value instead of
leaving the default 16.

:::caution[Writing these fields bypasses the bookkeeping]
Setting `value` directly skips the re-stamp, so the entry keeps an old
`touched` and becomes the next victim despite having been written most recently.
Setting `key` directly can create two entries that answer to the same string,
and only the first will ever be found.

Use [`set`](/compiler/api/uxkit/uxcache/#set).
:::

## Fields

### key

```c
u8* key         // borrowed; compared by content
```

### value

```c
Object* value   // strong
```

### touched

```c
i32 touched     // the cache's clock at last use; lowest is evicted first
```

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXCache`](/compiler/api/uxkit/uxcache/): the cache these live in
- [`UXKVEntry`](/compiler/api/uxkit/uxkventry/): the persistent equivalent, with
  no clock because nothing is evicted
- [`UXBagEntry`](/compiler/api/uxkit/uxbagentry/): the counted equivalent
