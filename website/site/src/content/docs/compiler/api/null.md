---
title: "Null"
description: "The one shared object that stands for \"nothing here\" in a collection, distinct from an absent entry."
---

`Null` is one shared object that means "there is nothing here" (`NSNull` in
shape). A collection stores `Object*`, and a null reference usually means
absent. Sometimes a slot needs an explicit nothing that is still an object: a
sparse row, a JSON `null`, a cleared entry that must keep its place.
**From 0.72.**

```c
#import "Null.xc"          // or the Foundation umbrella
```

## Overview

```c
Array* row = new Array();
row.add(Null.null());                   // a gap that keeps its index
if (Null.isNothing(row.get((u32)0)))    // a null reference or Null.null()
    …
```

There is only ever one instance, so compare with [`isNull`](#isnull) or by
reference. Its [`description`](#description) is `null`.
[`JSON`](/compiler/api/json/) reads `null` as this object.

:::note[Availability]
Every heap-capable target, the 6502 included.
:::

## Topics

· [null](#null) · [isNull](#isnull) · [isNothing](#isnothing) · [description](#description)

---

### null
```c
static Null* null(void)
```
The shared instance.

### isNull
```c
static bool isNull(Object* o)
```
Whether `o` is the shared instance. A null reference is not.

### isNothing
```c
static bool isNothing(Object* o)
```
Whether `o` is a null reference or the shared instance.

### description
```c
String* description(void)
```
`null`.

[↑ Topics](#topics)
