---
title: Codable
description: "Protocol for objects that a Coder can archive and restore: encodeWithCoder and initWithCoder."
---

`Codable` is the protocol a class implements to be archived by a
[`Coder`](/compiler/api/coder/). It is the xc form of Foundation's `NSCoding`.

```c
class Point { ... }        // every class is already Codable through Object
```

## Overview

[`Object`](/compiler/api/object/) adopts `Codable` with two empty methods, so
every class conforms without saying so. A class with state to keep overrides
both methods, calls `super` first, and hands each field to the coder under a
string key:

```c
class Point {
    i32    x;
    i32    y;
    Point* next;

    void encodeWithCoder(Coder* coder) {
        super.encodeWithCoder(coder);
        coder.encodeI32(x, "x");
        coder.encodeI32(y, "y");
        coder.encodeObject(next, "next");
    }

    void initWithCoder(Coder* coder) {
        super.initWithCoder(coder);
        x    = coder.decodeI32("x");
        y    = coder.decodeI32("y");
        next = (Point* ?)coder.decodeObject("next");
    }
}
```

Calling `super` in both methods lets each class in a hierarchy code its own
fields, as in Objective-C.

**`initWithCoder` is not a constructor.** The unarchiver creates each instance
by class name, which runs the class's `init(void)` if it has one, and then
calls `initWithCoder` on that instance. A class that is unarchived therefore
needs an `init(void)` or no `init` at all. Both methods are ordinary virtual
methods.

An object referred to from several places is archived once and comes back as
one object. A cycle is allowed: each instance is registered before its
`initWithCoder` runs, so a reference back to it resolves to the same instance,
even though that instance has not finished decoding.

`String`, `Number`, `Data`, `Array`, `Map` and `Set` do not use these methods.
The coder writes them in a native JSON form; see [`Coder`](/compiler/api/coder/).

:::note[Availability]
Every target except xt6502. On xt6502, `Object` does not adopt `Codable`, and
importing `Codable.xc` or `Coder.xc` is a compile error.
:::

## Required methods

### encodeWithCoder
```c
void encodeWithCoder(Coder* coder);
```
Write this object's state into `coder` with its `encode…` methods. Called
while [`Coder.archive`](/compiler/api/coder/#archive) writes the graph. The
default on `Object` writes nothing.

### initWithCoder
```c
void initWithCoder(Coder* coder);
```
Read the state back with the coder's `decode…` methods. Called on an instance
the unarchiver has just created with `init(void)`. The default on `Object`
reads nothing.

## Cost

`Codable.xc` names `Coder*` without importing `Coder.xc`: the language treats
a pointer to a class as opaque until something needs the class's layout. A
program that never archives compiles and links none of `Coder`. What every
program does carry is the two empty methods on `Object` and their two vtable
entries in each class.

See also [`Coder`](/compiler/api/coder/) and [`Copying`](/compiler/api/copying/).
