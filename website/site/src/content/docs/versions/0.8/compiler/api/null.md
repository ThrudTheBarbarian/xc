---
title: "Null"
description: "The one shared object that stands for \"nothing here\" in a collection, distinct from an absent entry."
slug: versions/0.8/compiler/api/null
banner:
  content: 'This is the documentation for xc 0.8. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

`Null` is one shared object that means "there is nothing here" (`NSNull` in
shape). A collection stores `Object*`, and a null reference usually means
absent. Sometimes a slot needs an explicit nothing that is still an object: a
sparse row, a JSON `null`, a cleared entry that must keep its place.

```c
#import "Null.xc"          // or the Foundation umbrella
```

## Overview

```c
Array* row = new Array();
row.add(Null.null());                   // a gap that keeps its index
if (Null.isNothing(row.get(0)))    // a null reference or Null.null()
    …
```

There is only ever one instance, so compare with [`isNull`](#isnull) or by
reference. Its [`description`](#description) is `null`.
[`JSON`](/versions/0.8/compiler/api/json/) reads `null` as this object.

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
