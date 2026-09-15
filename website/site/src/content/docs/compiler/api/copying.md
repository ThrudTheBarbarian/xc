---
title: Copying
description: "Protocol for producing an independent duplicate of an object."
---

`Copying` is the protocol a class adopts to return an independent duplicate of
an instance.

```c
class MyType <Copying> { ... }
```

## Overview

`copy` returns a new object, distinct from the original, that the caller owns.
[`Object`](/compiler/api/object/) has **no default** `copy` for arbitrary
subclasses: a raw byte copy would duplicate strong references without retaining
them, so the first `dealloc` over-releases and the second touches freed memory.
Each type defines how it copies, as Objective-C does with `NSCopying`.

There is **no `mutableCopy`**. Foundation splits types into immutable/mutable
class pairs (`NSString`/`NSMutableString`). xtc has one `String`, one `Array`
and one `Map`, each already mutable, so `copy` and `mutableCopy` would return
the same thing. When porting code from Foundation, treat both `-copy` and
`-mutableCopy` as this one method.

**`copy` is shallow.** The receiver's own storage is duplicated; the objects it
references are not. Copying an [`Array`](/compiler/api/array/) gives a new Array
whose slots point at the same elements. Each element is retained by the new
Array, so both copies own their references independently. For a deep copy, walk
the result and replace each element yourself; the library can't know whether
that is meaningful for your element type.

## Required methods

### copy
```c
Object* copy(void);
```
Return an independent duplicate, `+1` and owned by the caller, like `new`. The
requirement is declared as `Object*` because the protocol slot is typed at the
root (there is no [`Self`](/compiler/api/object/) return type or generic
protocol slot), so call sites downcast:

```c
Array* dup = (Array* ?)original.copy();
```

An implementation may declare its **own** return type, because returns are
covariant. A container should do so: an `Object*` return on a container
collides with the typed-collection erasure convention (where `Object*` means
"one of my elements"), so `Array<String>.copy()` is typed `String*`.

The usual implementation needs nothing from the runtime. Construct a new
instance and assign each field across:

```c
Object* copy(void) {
    MyType* c = new MyType();
    c.x     = x;          // scalar: plain copy
    c.obj   = obj;        // strong ivar: ARC retains on assignment
    c.array = array;      // shared, not duplicated — copy is SHALLOW
    return (Object*)c;
}
```

Assignment to a strong ivar emits the release-old / retain-new pair, so the copy
owns its references independently with no manual refcounting.

## Conforming types

Standard-library classes that conform (each implements `copy`):

- [`String`](/compiler/api/string/)
- [`Array`](/compiler/api/array/)
- [`Map`](/compiler/api/map/)
- [`Set`](/compiler/api/set/)
- [`Data`](/compiler/api/data/)

These own a heap buffer, so they **must** implement `copy` rather than rely on
field assignment. Field assignment would leave two live objects sharing one
`_bytes` or `_slots` buffer.

See also the sibling protocols [`Comparable`](/compiler/api/comparable/) and
[`Hashable`](/compiler/api/hashable/).

## Usage

Conform to `Copying` whenever a caller might need a snapshot that is unaffected
by later changes to the original. The copy is shallow: for a container of
mutable objects, duplicating the container does not duplicate its contents.
