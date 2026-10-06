---
title: Cache
description: "A bounded least-recently-used cache of objects under string keys: past its capacity, the entry used longest ago goes."
---

`Cache` is a bounded least-recently-used cache (`NSCache` in shape): values
stored under string keys, at most [`capacity`](#capacity) of them. A
[`set`](#set) that would go over evicts the entry used least recently, and
every [`get`](#get) and `set` counts as a use. It is what a thumbnail, image or
parsed-resource cache uses to stay bounded. **From the release after 0.71.**

```c
#import "Cache.xc"         // or the Foundation umbrella
```

## Overview

```c
Cache* thumbs = new Cache();
thumbs.setCapacity((i32)64);
thumbs.set("a.png", image);
Image* i = (Image* ?)thumbs.get("a.png");   // null once evicted
```

**Keys** are copied into a [`String`](/compiler/api/string/) the cache owns, so
the caller's buffer may change or go away after the call.

**Storage** is a [`Map`](/compiler/api/map/) from each key to its entry and a
doubly linked list of the entries from most to least recently used, so `get`,
`set` and eviction are all close to O(1).

**Ownership (ARC).** The cache holds a strong reference to each value while it
is cached, and releases it on eviction or removal.

:::note[Availability]
Every heap-capable target, the 6502 included. The default capacity is 16.
:::

## Topics

**Capacity** · [setCapacity](#setcapacity) · [capacity](#capacity) · [count](#count)

**Storing and reading** · [set](#set) · [get](#get) · [contains](#contains)

**Removing** · [remove](#remove) · [removeAll](#removeall)

---

## Capacity

### setCapacity
```c
void setCapacity(i32 n)
```
At most `n` entries (at least 1); evicts down to it now, least recently used
first.

### capacity
```c
i32 capacity(void)
```
The most entries the cache keeps.

### count
```c
i32 count(void)
```
The number of entries.

[↑ Topics](#topics)

## Storing and reading

### set
```c
void set(u8* key, Object* value)
```
Stores `value` under `key`, replacing what was there, and marks it most
recently used; then evicts the least recently used entries past the capacity.

### get
```c
Object* get(u8* key)
```
The value under `key`, or null if absent or evicted; marks it most recently
used.

### contains
```c
bool contains(u8* key)
```
Whether `key` is cached. It does not count as a use.

[↑ Topics](#topics)

## Removing

### remove
```c
void remove(u8* key)
```
Removes the entry under `key`, if any.

### removeAll
```c
void removeAll(void)
```
Empties the cache, releasing every value.

[↑ Topics](#topics)
