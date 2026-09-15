---
title: UXNull
description: "A shared sentinel meaning 'there is explicitly nothing here', distinct from absent, and the toolkit's reference example of the singleton pattern."
---

`UXNull` is a single shared object meaning **"there is explicitly nothing
here"**, which differs from "there is nothing here". It is shaped like
`NSNull`.

```c
#use <UXKit>            // or #import "UXNull.xc"
```

## Overview

A collection stores `Object*`, and `0` is a valid nil. A sentinel is still
needed because *absent* and *present but empty* are different facts, and some
data must express the second:

- a JSON document containing `"middleName": null`, where the key **is** there
- a sparse row whose third column was cleared on purpose
- a cache entry recording "looked, and found nothing" so the lookup is not
  repeated

Stored as `0`, these become indistinguishable from "no such key", "never
set" and "not cached yet". `UXNull.null()` is an object you can put in
a collection, and it stands for the first of each pair.

```c
Array<Object>* row = new Array();
row.add(name);                  // a value
row.add(UXNull.null());         // explicitly empty
// a third column simply never added — absent
```

## Topics

[null](#null) · [isNull](#isnull) · [isNothing](#isnothing)

### null

```c
static UXNull* null(void)
```

The one shared instance, made on first use. Every call returns the same object,
so identity comparison is the test. Nothing is allocated per use and
nothing needs freeing.

### isNull

```c
static bool isNull(Object* o)
```

Whether this reference is *the sentinel*. False for a real nil.

```c
UXNull.isNull(UXNull.null())    // true
UXNull.isNull((Object*)0)       // false  — nil is absent, not explicitly empty
```

Use this when the distinction matters, for example a JSON writer that emits
`null` for the sentinel and omits the key when the value is absent.

### isNothing

```c
static bool isNothing(Object* o)
```

Nil **or** the sentinel: "there is no value here, however it was expressed".

```c
UXNull.isNothing((Object*)0)       // true
UXNull.isNothing(UXNull.null())    // true
UXNull.isNothing(name)             // false
```

Use this when you are about to *use* a value and only need to know there is
none. Most call sites want `isNothing`; `isNull` is for the ones that must
preserve the difference on the way back out.

## The singleton pattern

This class is also the toolkit's reference example of a lazily-made shared
instance:

```c
UXNull* gUXNull;                           // file-scope global

static UXNull* null(void) {
    if (gUXNull == (UXNull*)0) { gUXNull = new UXNull(); }
    return gUXNull;
}
```

Nothing is allocated until something asks; after that every caller gets the same
object. [`UXNotificationCenter.shared`](/compiler/api/uxkit/uxnotificationcenter/)
and [`UXLog.shared`](/compiler/api/uxkit/uxlog/) have the same shape.

The instance is immutable and carries no state, so sharing it across a whole
program costs one allocation and raises no ownership question.

## Example

Round-tripping a row where "cleared" must stay distinct from "missing":

```c
Array<Object>* row = new Array();
row.add(title);
row.add(UXNull.null());      // the user cleared this cell

for (u16 i = 0; i < row.count(); i = i + 1) {
    Object* v = row.get(i);
    if (UXNull.isNull(v))         { Stdio.printf("col %d: cleared\n", i); }
    else if (v == (Object*)0)     { Stdio.printf("col %d: absent\n", i); }
    else                          { Stdio.printf("col %d: a value\n", i); }
}
```

If the cleared cell were stored as `0`, the writer could not tell it from a
column that was never filled in, and the round trip would drop the user's
edit.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXJSON`](/compiler/api/uxkit/uxjson/): where a literal `null` in a document
  becomes this sentinel
- [`UXCache`](/compiler/api/uxkit/uxcache/): a negative result is a value, not
  an absence
- [`UXNotificationCenter`](/compiler/api/uxkit/uxnotificationcenter/): the same
  singleton shape
